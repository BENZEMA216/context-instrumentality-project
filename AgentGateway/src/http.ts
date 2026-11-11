import { visit } from 'jsonc-parser';
import type { z } from 'zod';
import { MAX_BODY_BYTES, type Env } from './models';

export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string) { super(message); }
}
export function json(data: unknown, status = 200, extra?: HeadersInit): Response {
  const headers = new Headers(extra);
  headers.set('Content-Type', 'application/json; charset=utf-8');
  headers.set('Cache-Control', 'no-store');
  headers.set('X-Content-Type-Options', 'nosniff');
  return new Response(JSON.stringify(data), { status, headers });
}
export function failure(error: unknown): Response {
  const known = error instanceof ApiError ? error : new ApiError(500, 'internal_error', 'The service could not complete this request.');
  return json({ error: { code: known.code, message: known.message } }, known.status,
    known.status === 429 ? { 'Retry-After': '60' } : undefined);
}
export function strictJSON(source: string): unknown {
  const objects: Set<string>[] = [];
  let invalid = false, depth = 0;
  visit(source, {
    onObjectBegin() { objects.push(new Set()); if (++depth > 40) invalid = true; },
    onObjectProperty(name) { const keys = objects[objects.length - 1]; if (keys.has(name)) invalid = true; keys.add(name); },
    onObjectEnd() { objects.pop(); depth--; },
    onArrayBegin() { if (++depth > 40) invalid = true; }, onArrayEnd() { depth--; },
    onError() { invalid = true; },
  }, { allowTrailingComma: false, disallowComments: true, allowEmptyContent: false });
  if (invalid) throw new ApiError(400, 'invalid_request', 'Use strict JSON with unique keys and bounded nesting.');
  try { return JSON.parse(source); } catch { throw new ApiError(400, 'invalid_request', 'The request is not valid JSON.'); }
}
export async function readJSON(request: Request, limit = MAX_BODY_BYTES): Promise<unknown> {
  if (!/^application\/json(?:\s*;.*)?$/i.test(request.headers.get('content-type') ?? '')) throw new ApiError(400, 'invalid_request', 'Content-Type must be application/json.');
  const declared = request.headers.get('content-length');
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > limit)) throw new ApiError(413, 'body_too_large', 'The request body is too large.');
  const reader = request.body?.getReader();
  if (!reader) throw new ApiError(400, 'invalid_request', 'A JSON request body is required.');
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) { const item = await reader.read(); if (item.done) break; size += item.value.byteLength;
      if (size > limit) { await reader.cancel(); throw new ApiError(413, 'body_too_large', 'The request body is too large.'); }
      chunks.push(item.value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let position = 0;
  for (const chunk of chunks) { bytes.set(chunk, position); position += chunk.byteLength; }
  try { return strictJSON(new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(bytes)); }
  catch (error) { if (error instanceof ApiError) throw error; throw new ApiError(400, 'invalid_request', 'The request body must be UTF-8 JSON.'); }
}
export function parse<T extends z.ZodType>(schema: T, value: unknown): z.infer<T> {
  const result = schema.safeParse(value);
  if (!result.success) throw new ApiError(400, 'invalid_request', 'Request fields, values or sizes do not match the API contract.');
  return result.data;
}
export function origin(env: Env): string {
  try {
    const url = new URL(env.PUBLIC_ORIGIN);
    if (url.origin !== env.PUBLIC_ORIGIN || (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)))) throw new Error();
    return url.origin;
  } catch { throw new ApiError(503, 'not_configured', 'The service origin has not been configured.'); }
}
export function sameOrigin(request: Request, env: Env, required = false): void {
  const header = request.headers.get('Origin');
  if ((required && !header) || (header && header !== origin(env))) throw new ApiError(403, 'origin_not_allowed', 'Open this request from the service authorization page.');
}
export function method(request: Request, expected: string): void {
  if (request.method !== expected) throw new ApiError(405, 'method_not_allowed', 'This endpoint does not support that HTTP method.');
}
export function randomToken(bytes = 32): string {
  return base64url(crypto.getRandomValues(new Uint8Array(bytes)));
}
export function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}
export async function sha256(value: string): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)))].map(byte => byte.toString(16).padStart(2, '0')).join('');
}
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical((value as Record<string, unknown>)[key])).join(',') + '}';
  return JSON.stringify(value);
}
export async function rateLimit(db: D1DatabaseSession, key: string, maximum: number, now: number, windowMs = 60_000): Promise<void> {
  const bucket = `${await sha256(key)}:${Math.floor(now / windowMs)}`;
  const row = await db.prepare('INSERT INTO rate_limits (id,count,expires_at) VALUES (?,1,?) ON CONFLICT(id) DO UPDATE SET count=count+1 RETURNING count')
    .bind(bucket, now + windowMs * 2).first<{ count: number }>();
  if (!row || row.count > maximum) throw new ApiError(429, 'rate_limited', 'Too many requests. Please wait before trying again.');
  // Indexed expiry cleanup keeps temporary unauthenticated challenges from growing indefinitely.
  await db.prepare('DELETE FROM rate_limits WHERE expires_at<?').bind(now).run();
}
