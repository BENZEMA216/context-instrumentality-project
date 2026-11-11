import OAuthProvider, { OAuthError, type OAuthResourceContext } from '@cloudflare/workers-oauth-provider';
import { challenge, login, authenticateDevice, logout } from './auth';
import { approve, authorize, listConnections, lookup, poll, revoke } from './authorization';
import { ApiError, failure, json, method, origin, parse, rateLimit, readJSON, sameOrigin } from './http';
import { handleMcp } from './mcp';
import { emptySchema, uuid, SCOPES, type AuthProps, type Env } from './models';
import { currentConnection, deleteRecording, recordingRevision, upload } from './store';

async function nativeRoutes(request: Request, env: Env): Promise<Response> {
  const path = new URL(request.url).pathname, now = Date.now();
  const db = env.DB.withSession('first-primary');
  sameOrigin(request, env);
  if (path === '/authorize') return authorize(request, env, db, now);
  if (path === '/authorize/poll') return poll(request, env, db, now);
  if (path === '/health') { method(request, 'GET'); return json({ service: 'record-for-agent', status: 'ok' }); }
  if (path === '/v1/auth/challenge') { method(request, 'POST'); return json(await challenge(request, env, db, now)); }
  if (path === '/v1/auth/apple') { method(request, 'POST'); return json(await login(request, env, db, now)); }
  if (!path.startsWith('/v1/')) throw new ApiError(404, 'not_found', 'Endpoint not found.');
  const session = await authenticateDevice(request, env, db, now);
  await rateLimit(db, 'device:' + session.tokenHash, 120, now);
  if (path === '/v1/recordings') { method(request, 'PUT'); return json(await upload(request, env, db, session, now)); }
  const revisionPath = /^\/v1\/recordings\/([^/]+)\/revision$/.exec(path);
  if (revisionPath) { method(request, 'GET'); return json(await recordingRevision(db, session, parse(uuid, revisionPath[1]))); }
  if (path.startsWith('/v1/recordings/')) { method(request, 'DELETE'); return json(await deleteRecording(db, session, parse(uuid, path.slice('/v1/recordings/'.length)), now)); }
  if (path === '/v1/authorizations/lookup') { method(request, 'POST'); return json(await lookup(request, db, session, now)); }
  if (path === '/v1/authorizations/approve') { method(request, 'POST'); return json(await approve(request, db, session, now)); }
  if (path === '/v1/authorizations') { method(request, 'GET'); return json(await listConnections(db, session)); }
  if (path === '/v1/authorizations/revoke') { method(request, 'POST'); return json(await revoke(request, db, session, now)); }
  if (path === '/v1/auth/logout') { method(request, 'POST'); parse(emptySchema, await readJSON(request, 4096)); await logout(session, db, now); return json({ status: 'revoked' }); }
  throw new ApiError(404, 'not_found', 'Endpoint not found.');
}
export function createProvider(env: Env) {
  const publicOrigin = origin(env);
  return new OAuthProvider<Env>({
    apiRoute: '/mcp',
    apiHandler: { async fetch(request, boundEnv, context) {
      try {
        if (new URL(request.url).pathname !== '/mcp') throw new ApiError(404, 'not_found', 'Endpoint not found.');
        const ctx = context as OAuthResourceContext<AuthProps>;
        if (!ctx.props?.ownerID || !ctx.props.connectionID || ctx.auth.userId !== ctx.props.ownerID || !ctx.auth.clientId) throw new ApiError(403, 'authorization_revoked', 'The authorization is incomplete.');
        await rateLimit(boundEnv.DB.withSession('first-primary'), 'mcp:' + ctx.props.connectionID, 120, Date.now());
        return await handleMcp(request, boundEnv, ctx.props, ctx.auth.scope, ctx.auth.clientId);
      } catch (error) { return failure(error); }
    } },
    defaultHandler: { async fetch(request, boundEnv) { try { return await nativeRoutes(request, boundEnv); } catch (error) { return failure(error); } } },
    authorizeEndpoint: '/authorize', tokenEndpoint: '/oauth/token', clientRegistrationEndpoint: '/oauth/register',
    accessTokenTTL: 3600, refreshTokenTTL: 30 * 24 * 3600, scopesSupported: [...SCOPES], requiredScopes: [...SCOPES],
    resourceMetadata: { resource: `${publicOrigin}/mcp`, authorization_servers: [publicOrigin], resource_name: 'Record for Agent private transcript library' },
    onError: () => undefined,
    clientIdMetadataDocumentEnabled: true, allowPrivateUseRedirectUris: true,
    async tokenExchangeCallback(options) {
      const props = options.props as Partial<AuthProps>;
      try {
        if (!props.ownerID || !props.connectionID || props.ownerID !== options.userId) throw new ApiError(403, 'authorization_revoked', 'Invalid authorization.');
        const connection = await currentConnection(options.env.DB.withSession('first-primary'), props.ownerID, props.connectionID, options.clientId);
        const scopes: string[] = JSON.parse(connection.scope_json);
        if (options.requestedScope.some(scope => !scopes.includes(scope))) throw new ApiError(403, 'scope_mismatch', 'Invalid authorization scope.');
      } catch (error) {
        if (error instanceof ApiError && error.status === 403) throw new OAuthError('invalid_grant', { description: 'This connection was revoked or is no longer available.' });
        throw new OAuthError('temporarily_unavailable', { description: 'Authorization storage is temporarily unavailable.' });
      }
    },
  });
}
async function boundedOAuthRequest(request: Request, env: Env): Promise<Request> {
  const path = new URL(request.url).pathname;
  if (!['/oauth/token', '/oauth/register'].includes(path) || request.method !== 'POST') return request;
  sameOrigin(request, env);
  const db = env.DB.withSession('first-primary'), now = Date.now();
  await rateLimit(db, 'oauth:' + path + ':' + (request.headers.get('CF-Connecting-IP') ?? 'local'), path === '/oauth/register' ? 10 : 60, now);
  if (path === '/oauth/register') await rateLimit(db, 'registrations:global', 200, now, 24 * 3600000);
  const reader = request.body?.getReader();
  if (!reader) return request;
  const chunks: Uint8Array[] = []; let size = 0;
  try {
    while (true) { const item = await reader.read(); if (item.done) break; size += item.value.byteLength;
      if (size > 32768) { await reader.cancel(); throw new ApiError(413, 'body_too_large', 'The OAuth request is too large.'); } chunks.push(item.value);
    }
  } finally { reader.releaseLock(); }
  const body = new Uint8Array(size); let offset = 0; for (const item of chunks) { body.set(item, offset); offset += item.byteLength; }
  return new Request(request, { body });
}
export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    try {
      if (new URL(request.url).origin !== origin(env)) throw new ApiError(400, 'invalid_request', 'Use the configured service origin.');
      if (!env.APPLE_APP_ID || env.APPLE_APP_ID.startsWith('CONFIGURE_') || !env.CLOUDKIT_CONTAINER || env.CLOUDKIT_CONTAINER.startsWith('CONFIGURE_')) throw new ApiError(503, 'not_configured', 'The Apple app and CloudKit container must be configured.');
      const result = await createProvider(env).fetch(await boundedOAuthRequest(request, env), env, ctx);
      const response = new Response(result.body, result);
      response.headers.set('Cache-Control', 'no-store');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      response.headers.set('Referrer-Policy', 'no-referrer');
      return response;
    } catch (error) { return failure(error); }
  },
} satisfies ExportedHandler<Env>;
