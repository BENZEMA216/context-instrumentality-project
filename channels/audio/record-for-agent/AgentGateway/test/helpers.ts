import { env } from 'cloudflare:workers';
import { createExecutionContext, waitOnExecutionContext } from 'cloudflare:test';
import worker from '../src/index';
import { randomToken, sha256 } from '../src/http';
import type { DeviceSession, Env, UploadRequest } from '../src/models';
export const testEnv = env as unknown as Env;
export const db = () => env.DB.withSession('first-primary');
export const NOW = 1792252800000;
export function sample(id = '10000000-0000-4000-8000-000000000001', sequence = 0, fingerprint = 'a'.repeat(64)): UploadRequest {
  return { manifest: { schemaVersion: 1, id, sessionID: '20000000-0000-4000-8000-000000000001', sequence, startedAt: NOW + sequence * 10000, endedAt: NOW + sequence * 10000 + 1000, sampleRate: 16000, frameCount: 16000, fileName: `${id}.caf`, byteCount: 32000, sha256: 'b'.repeat(64) },
    transcript: { schemaVersion: 1, segmentID: id, audioSHA256: 'b'.repeat(64), locale: 'zh-CN', engine: 'synthetic-test', createdAt: NOW + 10000, text: `合成测试 transcript ${sequence} APPLE`, spans: [{ start: 0, end: 1, text: '合成测试' }] },
    clientReportedCloudKit: { accountFingerprint: fingerprint, containerIdentifier: env.CLOUDKIT_CONTAINER, environment: 'development', recordName: id, savedAt: NOW + 10000 } };
}
export async function device(fingerprint = 'a'.repeat(64)): Promise<DeviceSession & { token: string }> {
  const ownerID = crypto.randomUUID(), token = randomToken(), tokenHash = await sha256(token);
  await db().prepare('INSERT INTO owners(id,apple_subject_hash,created_at) VALUES (?,?,?)').bind(ownerID, await sha256(ownerID), NOW).run();
  const expiresAt = Date.now() + 3600000;
  await db().prepare('INSERT INTO device_sessions(token_hash,owner_id,fingerprint,created_at,expires_at) VALUES (?,?,?,?,?)').bind(tokenHash, ownerID, fingerprint, NOW, expiresAt).run();
  return { ownerID, tokenHash, cloudKitAccountFingerprint: fingerprint, expiresAt, token };
}
export function request(path: string, body?: unknown, token?: string, method = body === undefined ? 'GET' : 'POST', headers: Record<string, string> = {}): Request {
  return new Request(`https://gateway.test${path}`, { method, headers: { ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });
}
export async function call(req: Request): Promise<Response> { const context = createExecutionContext(); const response = await worker.fetch(req, testEnv, context); await waitOnExecutionContext(context); return response; }
export async function data(response: Response): Promise<any> { const raw = await response.text(); if (response.headers.get('Content-Type')?.includes('text/event-stream')) { const line = raw.split('\n').find(value => value.startsWith('data: ')); return JSON.parse(line!.slice(6)); } return JSON.parse(raw); }
