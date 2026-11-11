import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from 'jose';
import {
  CHALLENGE_TTL_MS, DEVICE_TTL_MS, appleLoginSchema, emptySchema, validText,
  type ChallengeResponse, type DeviceSession, type Env, type LoginResponse,
} from './models';
import { ApiError, canonical, method, parse, randomToken, rateLimit, readJSON, sameOrigin, sha256 } from './http';

const APPLE_ISSUER = 'https://appleid.apple.com';
// Neither the request nor a token header can choose a remote key source.
const appleKeys = createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys'));
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;

interface ChallengeRow { id: string; nonce_hash: string; expires_at: number; consumed_at: number | null; }
interface SessionRow { owner_id: string; token_hash: string; fingerprint: string; expires_at: number; }

function unauthenticated(): ApiError {
  return new ApiError(401, 'unauthenticated', 'A valid, current device session is required.');
}

function invalidAppleLogin(): ApiError {
  return new ApiError(401, 'invalid_apple_identity', 'The Apple sign-in or its challenge is invalid or expired.');
}

function appID(env: Env): string {
  const value = env.APPLE_APP_ID;
  if (typeof value !== 'string' || !validText(value, 255) || value !== value.trim() || value.startsWith('CONFIGURE_')) {
    throw new ApiError(503, 'not_configured', 'Apple sign-in has not been configured.');
  }
  return value;
}

async function limitAuthentication(request: Request, db: D1DatabaseSession, operation: string, maximum: number, now: number): Promise<void> {
  // Cloudflare supplies this header at its edge. Never trust X-Forwarded-For.
  const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  await rateLimit(db, `auth:${operation}:${ip}`, maximum, now);
  await rateLimit(db, `auth:${operation}:global`, 1000, now, 24 * 3600000);
  await db.prepare('DELETE FROM auth_challenges WHERE expires_at<=?').bind(now).run();
}

export async function challenge(request: Request, env: Env, db: D1DatabaseSession, now: number): Promise<ChallengeResponse> {
  method(request, 'POST');
  sameOrigin(request, env);
  await limitAuthentication(request, db, 'challenge', 20, now);
  parse(emptySchema, await readJSON(request, 1024));
  const challengeID = crypto.randomUUID();
  const nonce = randomToken(32);
  const expiresAt = now + CHALLENGE_TTL_MS;
  await db.prepare('INSERT INTO auth_challenges (id,nonce_hash,expires_at,consumed_at) VALUES (?,?,?,NULL)')
    .bind(challengeID, await sha256(nonce), expiresAt).run();
  return { challengeID, nonce, expiresAt };
}

export async function login(
  request: Request, env: Env, db: D1DatabaseSession, now: number,
  // A direct dependency-injection seam for synthetic JWT tests only. HTTP callers
  // never supply this argument, and no request/environment field selects keys.
  testKeyResolver?: JWTVerifyGetKey,
): Promise<LoginResponse> {
  method(request, 'POST');
  sameOrigin(request, env);
  const audience = appID(env);
  await limitAuthentication(request, db, 'login', 10, now);
  const input = parse(appleLoginSchema, await readJSON(request, 32 * 1024));
  const pending = await db.prepare('SELECT id,nonce_hash,expires_at,consumed_at FROM auth_challenges WHERE id=?')
    .bind(input.challengeID).first<ChallengeRow>();
  if (!pending || pending.consumed_at !== null || pending.expires_at <= now) throw invalidAppleLogin();

  let subject: string;
  try {
    const { payload } = await jwtVerify(input.identityToken, testKeyResolver ?? appleKeys, {
      issuer: APPLE_ISSUER, audience, algorithms: ['RS256', 'ES256'],
      requiredClaims: ['exp', 'iat', 'sub', 'nonce'], maxTokenAge: CHALLENGE_TTL_MS / 1000,
      currentDate: new Date(now), clockTolerance: 0,
    });
    const issuedAt = payload.iat, expiresAt = payload.exp;
    if (typeof issuedAt !== 'number' || !Number.isSafeInteger(issuedAt)
      || typeof expiresAt !== 'number' || !Number.isSafeInteger(expiresAt)
      || issuedAt < Math.floor((pending.expires_at - CHALLENGE_TTL_MS) / 1000)
      || expiresAt <= issuedAt || typeof payload.sub !== 'string' || !validText(payload.sub, 255)
      || typeof payload.nonce !== 'string' || !TOKEN_PATTERN.test(payload.nonce)
      || await sha256(payload.nonce) !== pending.nonce_hash) throw invalidAppleLogin();
    subject = payload.sub;
  } catch {
    // Do not return JWT contents, key errors, claims, or account identifiers.
    throw invalidAppleLogin();
  }

  // Verification happens before consumption. Concurrent replays can verify, but
  // only one can consume the challenge and proceed to issue a device session.
  const consumed = await db.prepare('UPDATE auth_challenges SET consumed_at=? WHERE id=? AND consumed_at IS NULL AND expires_at>? RETURNING id')
    .bind(now, input.challengeID, now).first<{ id: string }>();
  if (!consumed) throw invalidAppleLogin();

  const subjectHash = await sha256(canonical([APPLE_ISSUER, audience, subject]));
  const owner = await db.prepare('INSERT INTO owners (id,apple_subject_hash,created_at) VALUES (?,?,?) ON CONFLICT(apple_subject_hash) DO UPDATE SET apple_subject_hash=excluded.apple_subject_hash RETURNING id')
    .bind(crypto.randomUUID(), subjectHash, now).first<{ id: string }>();
  if (!owner) throw new ApiError(500, 'internal_error', 'The service could not create a device session.');
  const deviceToken = randomToken(32);
  const expiresAt = now + DEVICE_TTL_MS;
  await db.prepare('INSERT INTO device_sessions (token_hash,owner_id,fingerprint,created_at,expires_at,revoked_at) VALUES (?,?,?,?,?,NULL)')
    .bind(await sha256(deviceToken), owner.id, input.cloudKitAccountFingerprint, now, expiresAt).run();
  return { ownerID: owner.id, deviceToken, expiresAt, cloudKitAccountFingerprint: input.cloudKitAccountFingerprint };
}

export async function authenticateDevice(request: Request, env: Env, _db: D1DatabaseSession, now: number): Promise<DeviceSession> {
  const match = /^Bearer ([A-Za-z0-9_-]{43})$/i.exec(request.headers.get('Authorization') ?? '');
  if (!match) throw unauthenticated();
  const tokenHash = await sha256(match[1]);
  // Start a fresh primary read even if a caller accidentally supplies a session
  // pinned to a replica. Revocation and expiry are checked for every request.
  const primary = env.DB.withSession('first-primary');
  const row = await primary.prepare('SELECT owner_id,token_hash,fingerprint,expires_at FROM device_sessions WHERE token_hash=? AND revoked_at IS NULL AND expires_at>?')
    .bind(tokenHash, now).first<SessionRow>();
  if (!row) throw unauthenticated();
  return { ownerID: row.owner_id, tokenHash: row.token_hash, cloudKitAccountFingerprint: row.fingerprint, expiresAt: row.expires_at };
}

export async function logout(session: DeviceSession, db: D1DatabaseSession, now: number): Promise<void> {
  await db.prepare('UPDATE device_sessions SET revoked_at=COALESCE(revoked_at,?) WHERE token_hash=? AND owner_id=? AND fingerprint=?')
    .bind(now, session.tokenHash, session.ownerID, session.cloudKitAccountFingerprint).run();
}
