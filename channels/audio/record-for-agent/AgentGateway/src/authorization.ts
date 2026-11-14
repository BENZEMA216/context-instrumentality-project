import { z } from 'zod';
import { ApiError, canonical, json, method, origin, parse, randomToken, rateLimit, readJSON, sameOrigin, sha256 } from './http';
import { AUTHORIZATION_TTL_MS, SCOPES, approveSchema, revokeSchema, uuid, type AuthorizationLookupResponse, type ConnectionRow, type DeviceSession, type Env } from './models';
import { connectionResponse, currentConnection } from './store';

interface PendingRow { id: string; browser_hash: string; consent_handle: string; details_json: string; requested_scope_json: string; client_id: string; status: string; expires_at: number; connection_id: string | null; owner_id: string | null; approved_scope_json: string | null; }
const escape = (value: string) => value.replace(/[&<>"']/g, char => `&#${char.charCodeAt(0)};`);
const cookieName = (id: string) => `__Host-record-agent-${id}`;
function cookie(request: Request, name: string): string | undefined { return request.headers.get('Cookie')?.split(';').map(item => item.trim()).find(item => item.startsWith(name + '='))?.slice(name.length + 1); }
function displayCode(): string { const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'; return Array.from(crypto.getRandomValues(new Uint8Array(10)), byte => alphabet[byte % alphabet.length]).join(''); }
function normalizeCode(code: string): string { return code.replace(/[ -]/g, '').toUpperCase(); }
export async function authorize(request: Request, env: Env, db: D1DatabaseSession, now: number): Promise<Response> {
  method(request, 'GET');
  await rateLimit(db, 'authorize:' + (request.headers.get('CF-Connecting-IP') ?? 'local'), 20, now);
  await rateLimit(db, 'authorize:global', 200, now, 24 * 3600000);
  const oauth = env.OAUTH_PROVIDER;
  const auth = await oauth.parseAuthRequest(request);
  if (!auth.scope?.length || auth.scope.some(scope => !(SCOPES as readonly string[]).includes(scope))) throw new ApiError(400, 'invalid_request', 'Request only recordings:read and transcripts:read scopes.');
  const description = await oauth.describeConsent(auth);
  const consent = await oauth.beginConsent(auth);
  const id = crypto.randomUUID(), browserProof = randomToken(), code = displayCode();
  const details: AuthorizationLookupResponse = { authorizationID: id, clientID: auth.clientId, clientName: description.clientName,
    clientURI: description.clientUri ?? null, clientDomain: description.clientDomain ?? null,
    redirectHost: description.redirectHost, redirectIsLoopback: description.redirectIsLoopback,
    requestedScopes: auth.scope, expiresAt: now + AUTHORIZATION_TTL_MS };
  await db.prepare('INSERT INTO authorization_requests(id,code_hash,browser_hash,consent_handle,details_json,requested_scope_json,client_id,status,expires_at,created_at) VALUES (?,?,?,?,?,?,?,\'pending\',?,?)')
    .bind(id, await sha256(code), await sha256(browserProof), consent.handle, canonical(details), canonical(auth.scope), auth.clientId, details.expiresAt, now).run();
  await db.prepare('DELETE FROM authorization_requests WHERE expires_at<?').bind(now - AUTHORIZATION_TTL_MS).run();
  const nonce = randomToken();
  consent.headers.append('Set-Cookie', `${cookieName(id)}=${browserProof}; Secure; HttpOnly; SameSite=Strict; Path=/; Max-Age=600`);
  consent.headers.set('Content-Type', 'text/html; charset=utf-8');
  consent.headers.set('Cache-Control', 'no-store');
  consent.headers.set('Referrer-Policy', 'no-referrer');
  consent.headers.set('Content-Security-Policy', `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'`);
  const html = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>授权录音库</title>
<style nonce="${nonce}">body{max-width:640px;margin:10vh auto;padding:24px;font:17px/1.65 system-ui;background:#f7f6f2;color:#202522}h1{font-size:30px}code{display:block;font-size:32px;letter-spacing:.12em;background:#fff;padding:18px;border-radius:12px}small{color:#536158}button{padding:10px 20px}li{overflow-wrap:anywhere}</style>
<h1>连接你的录音库</h1><p><strong>${escape(description.clientName)}</strong> 请求访问你选择的录音。</p>
<p>${description.clientDomain ? `客户端域名：<strong>${escape(description.clientDomain)}</strong>` : '客户端名称由其自行登记，未经身份认证。'}</p>
<p>授权结果将返回：<strong>${escape(description.redirectHost)}</strong></p>
${description.redirectIsLoopback ? '<p>这是你电脑上的本地应用。仅在你刚从该应用发起连接时继续。</p>' : ''}
<ul>${auth.scope.map(scope => `<li>${escape(scope)}</li>`).join('')}</ul>
<p>打开 iPhone 的 Record for Agent，在 Agent 连接页输入此代码，核对客户端并选择录音：</p>
<code>${code.slice(0, 5)} ${code.slice(5)}</code><p id="state">等待你在 iPhone 上批准，10 分钟后失效。</p><button id="cancel">取消</button>
<p><small>仅共享所选录音的元数据和转写。原音频保留在你的 CloudKit 私有库。你可以在 iPhone 撤销访问；已被 Agent 读取的内容无法远程收回。</small></p>
<script nonce="${nonce}">const id=${JSON.stringify(id)};let ended=false;async function check(cancel=false){if(ended)return;try{const r=await fetch('/authorize/poll',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({authorizationID:id,cancel})});const d=await r.json();if(!r.ok)throw Error(d.error?.message||'授权未完成');if(d.redirectTo){ended=true;location.assign(d.redirectTo);return}document.getElementById('state').textContent='等待你在 iPhone 上批准…';setTimeout(()=>check(),2000)}catch(e){ended=true;document.getElementById('state').textContent=e.message;}}document.getElementById('cancel').onclick=()=>check(true);check();</script></html>`;
  return new Response(html, { headers: consent.headers });
}
export async function poll(request: Request, env: Env, db: D1DatabaseSession, now: number): Promise<Response> {
  method(request, 'POST'); sameOrigin(request, env, true);
  const value = parse(z.object({ authorizationID: uuid, cancel: z.boolean().default(false) }).strict(), await readJSON(request, 4096));
  const row = await db.prepare('SELECT * FROM authorization_requests WHERE id=?').bind(value.authorizationID).first<PendingRow>();
  const proof = cookie(request, cookieName(value.authorizationID));
  if (!row || !proof || row.browser_hash !== await sha256(proof) || row.expires_at <= now) throw new ApiError(403, 'authorization_expired', 'Authorization expired or belongs to another browser. Start again.');
  await rateLimit(db, 'poll:' + row.id, 45, now);
  if (value.cancel) {
    const changed = await db.prepare('UPDATE authorization_requests SET status=\'denied\' WHERE id=? AND status IN (\'pending\',\'approved\') RETURNING connection_id').bind(row.id).first<{ connection_id: string | null }>();
    if (!changed) throw new ApiError(409, 'conflict', 'This authorization has already been used.');
    if (changed.connection_id) await db.prepare('UPDATE connections SET status=\'revoked\',revoked_at=? WHERE id=?').bind(now, changed.connection_id).run();
    const denied = await env.OAUTH_PROVIDER.denyConsent(request, row.consent_handle);
    const location = denied.headers.get('Location');
    denied.headers.append('Set-Cookie', `${cookieName(row.id)}=; Secure; HttpOnly; SameSite=Strict; Path=/; Max-Age=0`);
    return json({ redirectTo: location }, 200, denied.headers);
  }
  if (row.status === 'pending') return json({ status: 'pending' });
  if (row.status !== 'approved' || !row.connection_id || !row.owner_id || !row.approved_scope_json) throw new ApiError(409, 'conflict', 'This authorization has already been used.');
  const claimed = await db.prepare('UPDATE authorization_requests SET status=\'completing\' WHERE id=? AND status=\'approved\' RETURNING id').bind(row.id).first();
  if (!claimed) throw new ApiError(409, 'conflict', 'This authorization has already been used.');
  try {
    await currentConnection(db, row.owner_id, row.connection_id, row.client_id);
    const approved = await env.OAUTH_PROVIDER.approveConsent(request, row.consent_handle, { scope: JSON.parse(row.approved_scope_json) });
    const result = await env.OAUTH_PROVIDER.completeAuthorization({ request: approved.request, userId: row.owner_id,
      metadata: { connectionID: row.connection_id }, scope: JSON.parse(row.approved_scope_json), props: { ownerID: row.owner_id, connectionID: row.connection_id }, revokeExistingGrants: false });
    await db.prepare('UPDATE authorization_requests SET status=\'complete\' WHERE id=?').bind(row.id).run();
    approved.headers.append('Set-Cookie', `${cookieName(row.id)}=; Secure; HttpOnly; SameSite=Strict; Path=/; Max-Age=0`);
    return json({ redirectTo: result.redirectTo }, 200, approved.headers);
  } catch (error) {
    await db.batch([db.prepare('UPDATE authorization_requests SET status=\'failed\' WHERE id=?').bind(row.id), db.prepare('UPDATE connections SET status=\'revoked\',revoked_at=? WHERE id=?').bind(now, row.connection_id)]);
    throw error;
  }
}
export async function lookup(request: Request, db: D1DatabaseSession, session: DeviceSession, now: number): Promise<AuthorizationLookupResponse> {
  const value = parse(z.object({ code: z.string().min(1).max(32) }).strict(), await readJSON(request, 4096));
  await rateLimit(db, 'lookup:' + session.ownerID, 20, now);
  const normalized = normalizeCode(value.code);
  if (!/^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{10}$/.test(normalized)) throw new ApiError(404, 'not_found', 'No pending authorization matches this code.');
  const row = await db.prepare('SELECT details_json FROM authorization_requests WHERE code_hash=? AND status=\'pending\' AND expires_at>?').bind(await sha256(normalized), now).first<{ details_json: string }>();
  if (!row) throw new ApiError(404, 'not_found', 'No pending authorization matches this code.');
  return JSON.parse(row.details_json);
}
export async function approve(request: Request, db: D1DatabaseSession, session: DeviceSession, now: number) {
  const value = parse(approveSchema, await readJSON(request, 32768));
  const pending = await db.prepare('SELECT * FROM authorization_requests WHERE id=? AND status=\'pending\' AND expires_at>?').bind(value.authorizationID, now).first<PendingRow>();
  if (!pending) throw new ApiError(404, 'not_found', 'This authorization is no longer pending.');
  const requested: string[] = JSON.parse(pending.requested_scope_json);
  if (value.scopes.some(scope => !requested.includes(scope))) throw new ApiError(403, 'scope_mismatch', 'Scopes exceed the authorization request.');
  const selectedJSON = JSON.stringify(value.recordingIDs);
  const owned = await db.prepare('SELECT COUNT(*) AS count FROM recordings WHERE owner_id=? AND fingerprint=? AND deleted_at IS NULL AND id IN (SELECT value FROM json_each(?))').bind(session.ownerID, session.cloudKitAccountFingerprint, selectedJSON).first<{ count: number }>();
  if (owned?.count !== value.recordingIDs.length) throw new ApiError(403, 'scope_mismatch', 'Select only available recordings in the current account.');
  const id = crypto.randomUUID(), details: AuthorizationLookupResponse = JSON.parse(pending.details_json);
  await db.batch([
    db.prepare('INSERT INTO connections(id,owner_id,fingerprint,client_id,client_name,scope_json,status,created_at,cursor_key) VALUES (?,?,?,?,?,?,\'revoked\',?,?)').bind(id, session.ownerID, session.cloudKitAccountFingerprint, pending.client_id, details.clientName, canonical(value.scopes), now, randomToken()),
    db.prepare('INSERT INTO connection_recordings(connection_id,owner_id,recording_id) SELECT ?,owner_id,id FROM recordings WHERE owner_id=? AND fingerprint=? AND deleted_at IS NULL AND id IN (SELECT value FROM json_each(?))').bind(id, session.ownerID, session.cloudKitAccountFingerprint, selectedJSON),
    db.prepare('UPDATE authorization_requests SET status=\'approved\',connection_id=?,owner_id=?,approved_scope_json=? WHERE id=? AND status=\'pending\' AND expires_at>? AND (SELECT COUNT(*) FROM connection_recordings WHERE connection_id=?)=?').bind(id, session.ownerID, canonical(value.scopes), pending.id, now, id, value.recordingIDs.length),
    db.prepare('UPDATE connections SET status=\'active\' WHERE id=? AND EXISTS(SELECT 1 FROM authorization_requests WHERE connection_id=? AND status=\'approved\')').bind(id, id),
  ]);
  const result = await db.prepare('SELECT * FROM connections WHERE id=?').bind(id).first<ConnectionRow>();
  if (!result || result.status !== 'active') throw new ApiError(409, 'conflict', 'This authorization was already approved or expired.');
  return connectionResponse(db, result);
}
export async function listConnections(db: D1DatabaseSession, session: DeviceSession) {
  const rows = await db.prepare('SELECT * FROM connections WHERE owner_id=? AND fingerprint=? ORDER BY created_at DESC LIMIT 200').bind(session.ownerID, session.cloudKitAccountFingerprint).all<ConnectionRow>();
  return { connections: await Promise.all(rows.results.map(row => connectionResponse(db, row))) };
}
export async function revoke(request: Request, db: D1DatabaseSession, session: DeviceSession, now: number) {
  const value = parse(revokeSchema, await readJSON(request, 32768));
  const row = await db.prepare('SELECT * FROM connections WHERE id=? AND owner_id=? AND fingerprint=?').bind(value.connectionID, session.ownerID, session.cloudKitAccountFingerprint).first<ConnectionRow>();
  if (!row) throw new ApiError(404, 'not_found', 'The connection does not exist in the current account.');
  if (value.recordingIDs) {
    const owned = await db.prepare('SELECT COUNT(*) AS count FROM connection_recordings WHERE connection_id=? AND owner_id=? AND recording_id IN (SELECT value FROM json_each(?))').bind(row.id, session.ownerID, JSON.stringify(value.recordingIDs)).first<{ count: number }>();
    if (owned?.count !== value.recordingIDs.length) throw new ApiError(403, 'scope_mismatch', 'A recording is outside this connection.');
    await db.prepare('UPDATE connection_recordings SET revoked_at=? WHERE connection_id=? AND owner_id=? AND revoked_at IS NULL AND recording_id IN (SELECT value FROM json_each(?))').bind(now, row.id, session.ownerID, JSON.stringify(value.recordingIDs)).run();
  } else await db.prepare('UPDATE connections SET status=\'revoked\',revoked_at=COALESCE(revoked_at,?) WHERE id=? AND owner_id=?').bind(now, row.id, session.ownerID).run();
  const updated = await db.prepare('SELECT * FROM connections WHERE id=?').bind(row.id).first<ConnectionRow>();
  return connectionResponse(db, updated!);
}
