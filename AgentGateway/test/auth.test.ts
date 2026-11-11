import { env as workerEnv } from 'cloudflare:workers';
import { generateKeyPair, SignJWT, type JWTVerifyGetKey } from 'jose';
import { beforeAll, describe, expect, it } from 'vitest';
import { authenticateDevice, challenge, login, logout } from '../src/auth';
import { canonical, sha256 } from '../src/http';
import { CHALLENGE_TTL_MS, DEVICE_TTL_MS, type ChallengeResponse, type Env, type LoginResponse } from '../src/models';

const env = workerEnv as unknown as Env;
const NOW = 1_800_000_000_000;
const ISSUER = 'https://appleid.apple.com';
const AUDIENCE = 'com.example.record-for-agent';
const FINGERPRINT = 'a'.repeat(64);
const configured = () => ({ ...env, APPLE_APP_ID: AUDIENCE, PUBLIC_ORIGIN: 'https://gateway.example' });
const db = () => env.DB.withSession('first-primary');
type Keys = Awaited<ReturnType<typeof generateKeyPair>>;
let rsa: Keys, ec: Keys;
const resolver: JWTVerifyGetKey = async header => header.alg === 'ES256' ? ec.publicKey : rsa.publicKey;

beforeAll(async () => {
  rsa = await generateKeyPair('RS256');
  ec = await generateKeyPair('ES256');
});

function post(body: unknown, ip = '198.51.100.9'): Request {
  return new Request('https://gateway.example/auth', {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': ip }, body: JSON.stringify(body),
  });
}
function bearer(token: string): Request {
  return new Request('https://gateway.example/api', { headers: { Authorization: `Bearer ${token}` } });
}
async function pending(now = NOW): Promise<ChallengeResponse> {
  return challenge(post({}), configured(), db(), now);
}
async function token(nonce: string, overrides: Record<string, unknown> = {}, alg: 'RS256' | 'ES256' = 'RS256'): Promise<string> {
  return new SignJWT({ iss: ISSUER, aud: AUDIENCE, sub: 'synthetic-apple-subject', nonce,
    iat: Math.floor(NOW / 1000), exp: Math.floor(NOW / 1000) + 600, ...overrides })
    .setProtectedHeader({ alg, kid: 'synthetic-key' }).sign(alg === 'ES256' ? ec.privateKey : rsa.privateKey);
}
async function signedIn(fingerprint = FINGERPRINT, subject = 'synthetic-apple-subject'): Promise<LoginResponse> {
  const issued = await pending();
  return login(post({ challengeID: issued.challengeID, identityToken: await token(issued.nonce, { sub: subject }),
    cloudKitAccountFingerprint: fingerprint }), configured(), db(), NOW, resolver);
}

describe('Apple challenge and device authentication', () => {
  it('returns a fresh five-minute challenge and persists only its nonce hash', async () => {
    const first = await pending(), second = await pending();
    expect(first.expiresAt).toBe(NOW + CHALLENGE_TTL_MS);
    expect(first.nonce).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(first.nonce).not.toBe(second.nonce);
    expect(first.challengeID).not.toBe(second.challengeID);
    const stored = await db().prepare('SELECT * FROM auth_challenges WHERE id=?').bind(first.challengeID).first();
    expect(stored).toEqual({ id: first.challengeID, nonce_hash: await sha256(first.nonce), expires_at: first.expiresAt, consumed_at: null });
    expect(JSON.stringify(stored)).not.toContain(first.nonce);
  });

  it('binds a 30-day hashed device token and an opaque owner to the verified Apple subject', async () => {
    const result = await signedIn();
    expect(result.deviceToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(result.expiresAt).toBe(NOW + DEVICE_TTL_MS);
    expect(result.cloudKitAccountFingerprint).toBe(FINGERPRINT);
    const owner = await db().prepare('SELECT * FROM owners').first();
    expect(owner).toEqual({ id: result.ownerID, apple_subject_hash: await sha256(canonical([ISSUER, AUDIENCE, 'synthetic-apple-subject'])), created_at: NOW });
    const stored = await db().prepare('SELECT * FROM device_sessions').first();
    expect(stored).toEqual({ token_hash: await sha256(result.deviceToken), owner_id: result.ownerID, fingerprint: FINGERPRINT,
      created_at: NOW, expires_at: result.expiresAt, revoked_at: null });
    expect(JSON.stringify({ owner, stored })).not.toContain(result.deviceToken);
    expect(JSON.stringify({ owner, stored })).not.toContain('synthetic-apple-subject');
    expect(await authenticateDevice(bearer(result.deviceToken), configured(), db(), NOW)).toEqual({
      ownerID: result.ownerID, tokenHash: await sha256(result.deviceToken), cloudKitAccountFingerprint: FINGERPRINT, expiresAt: result.expiresAt,
    });
  });

  it('supports ES256 as well as RS256 using a synthetic injected resolver', async () => {
    const issued = await pending();
    const result = await login(post({ challengeID: issued.challengeID, identityToken: await token(issued.nonce, {}, 'ES256'),
      cloudKitAccountFingerprint: FINGERPRINT }), configured(), db(), NOW, resolver);
    expect((await authenticateDevice(bearer(result.deviceToken), configured(), db(), NOW)).ownerID).toBe(result.ownerID);
  });

  it.each([
    ['wrong issuer', { iss: 'https://attacker.invalid' }],
    ['wrong audience', { aud: 'com.other.app' }],
    ['expired token', { exp: NOW / 1000 }],
    ['future issued-at', { iat: NOW / 1000 + 1 }],
    ['old issued-at', { iat: NOW / 1000 - 301 }],
    ['fractional issued-at', { iat: NOW / 1000 - 0.5 }],
    ['fractional expiry', { exp: NOW / 1000 + 600.5 }],
    ['empty subject', { sub: '' }],
    ['missing issued-at', { iat: undefined }],
    ['missing expiry', { exp: undefined }],
    ['missing subject', { sub: undefined }],
    ['missing nonce', { nonce: undefined }],
    ['wrong nonce', { nonce: 'b'.repeat(43) }],
  ])('rejects %s without consuming the challenge or creating a session', async (_name, overrides) => {
    const issued = await pending();
    await expect(login(post({ challengeID: issued.challengeID, identityToken: await token(issued.nonce, overrides),
      cloudKitAccountFingerprint: FINGERPRINT }), configured(), db(), NOW, resolver)).rejects.toMatchObject({ status: 401, code: 'invalid_apple_identity' });
    expect(await db().prepare('SELECT consumed_at FROM auth_challenges WHERE id=?').bind(issued.challengeID).first()).toEqual({ consumed_at: null });
    expect(await db().prepare('SELECT COUNT(*) AS count FROM device_sessions').first()).toEqual({ count: 0 });
  });

  it('requires the original Apple nonce rather than its SHA-256 string', async () => {
    const issued = await pending();
    await expect(login(post({ challengeID: issued.challengeID, identityToken: await token(await sha256(issued.nonce)),
      cloudKitAccountFingerprint: FINGERPRINT }), configured(), db(), NOW, resolver)).rejects.toMatchObject({ status: 401 });
  });

  it('rejects an otherwise valid token signed by an untrusted key', async () => {
    const issued = await pending();
    const other = await generateKeyPair('RS256');
    await expect(login(post({ challengeID: issued.challengeID, identityToken: await token(issued.nonce),
      cloudKitAccountFingerprint: FINGERPRINT }), configured(), db(), NOW, async () => other.publicKey)).rejects.toMatchObject({ status: 401 });
  });

  it('rejects non-allowlisted signing algorithms', async () => {
    const issued = await pending();
    const secret = crypto.getRandomValues(new Uint8Array(32));
    const identityToken = await new SignJWT({ iss: ISSUER, aud: AUDIENCE, sub: 'synthetic-apple-subject', nonce: issued.nonce,
      iat: NOW / 1000, exp: NOW / 1000 + 600 }).setProtectedHeader({ alg: 'HS256' }).sign(secret);
    await expect(login(post({ challengeID: issued.challengeID, identityToken, cloudKitAccountFingerprint: FINGERPRINT }),
      configured(), db(), NOW, async () => secret)).rejects.toMatchObject({ status: 401 });
  });

  it('atomically consumes a challenge once even for concurrent verified replays', async () => {
    const issued = await pending();
    const input = { challengeID: issued.challengeID, identityToken: await token(issued.nonce), cloudKitAccountFingerprint: FINGERPRINT };
    const outcomes = await Promise.allSettled([login(post(input), configured(), db(), NOW, resolver), login(post(input), configured(), db(), NOW, resolver)]);
    expect(outcomes.filter(result => result.status === 'fulfilled')).toHaveLength(1);
    expect(outcomes.filter(result => result.status === 'rejected')).toHaveLength(1);
    expect(await db().prepare('SELECT COUNT(*) AS count FROM device_sessions').first()).toEqual({ count: 1 });
    await expect(login(post(input), configured(), db(), NOW, resolver)).rejects.toMatchObject({ status: 401 });
  });

  it('rejects expired challenges and removes expired challenge rows', async () => {
    const issued = await pending();
    await expect(login(post({ challengeID: issued.challengeID, identityToken: await token(issued.nonce), cloudKitAccountFingerprint: FINGERPRINT }),
      configured(), db(), issued.expiresAt, resolver)).rejects.toMatchObject({ status: 401 });
    expect(await db().prepare('SELECT id FROM auth_challenges WHERE id=?').bind(issued.challengeID).first()).toBeNull();
  });

  it('keeps the same verified owner across devices and separates different subjects', async () => {
    const first = await signedIn(), second = await signedIn('b'.repeat(64)), other = await signedIn(FINGERPRINT, 'other-synthetic-subject');
    expect(first.ownerID).toBe(second.ownerID);
    expect(first.deviceToken).not.toBe(second.deviceToken);
    expect(first.ownerID).not.toBe(other.ownerID);
    expect((await authenticateDevice(bearer(second.deviceToken), configured(), db(), NOW)).cloudKitAccountFingerprint).toBe('b'.repeat(64));
  });

  it('rejects client-supplied ownership and key-source fields', async () => {
    const issued = await pending();
    const identityToken = await token(issued.nonce);
    for (const extra of [{ ownerID: crypto.randomUUID() }, { sub: 'chosen-owner' }, { jwksURL: 'https://attacker.invalid' }]) {
      await expect(login(post({ challengeID: issued.challengeID, identityToken, cloudKitAccountFingerprint: FINGERPRINT, ...extra }),
        configured(), db(), NOW, resolver)).rejects.toMatchObject({ status: 400 });
    }
  });

  it('accepts only a valid Bearer header, never query strings or cookies', async () => {
    const result = await signedIn();
    for (const request of [
      new Request(`https://gateway.example/api?deviceToken=${result.deviceToken}`),
      new Request('https://gateway.example/api', { headers: { Cookie: `deviceToken=${result.deviceToken}` } }),
      new Request('https://gateway.example/api', { headers: { Authorization: `Basic ${result.deviceToken}` } }),
      bearer('z'.repeat(43)), bearer('short'),
    ]) await expect(authenticateDevice(request, configured(), db(), NOW)).rejects.toMatchObject({ status: 401, code: 'unauthenticated' });
  });

  it('revokes only the current session and checks expiry at its exact boundary', async () => {
    const first = await signedIn(), second = await signedIn();
    const session = await authenticateDevice(bearer(first.deviceToken), configured(), db(), NOW);
    await logout(session, db(), NOW + 1000);
    await logout(session, db(), NOW + 2000);
    expect(await db().prepare('SELECT revoked_at FROM device_sessions WHERE token_hash=?').bind(session.tokenHash).first()).toEqual({ revoked_at: NOW + 1000 });
    await expect(authenticateDevice(bearer(first.deviceToken), configured(), db(), NOW + 2000)).rejects.toMatchObject({ status: 401, code: 'unauthenticated' });
    expect((await authenticateDevice(bearer(second.deviceToken), configured(), db(), second.expiresAt - 1)).ownerID).toBe(second.ownerID);
    await expect(authenticateDevice(bearer(second.deviceToken), configured(), db(), second.expiresAt)).rejects.toMatchObject({ status: 401, code: 'unauthenticated' });
  });

  it('limits challenge creation per source IP and clears old rate buckets', async () => {
    for (let count = 0; count < 20; count++) await pending();
    await expect(pending()).rejects.toMatchObject({ status: 429 });
    await expect(challenge(post({}, '198.51.100.10'), configured(), db(), NOW)).resolves.toHaveProperty('nonce');
    await pending(NOW + 180_000);
    expect(await db().prepare('SELECT COUNT(*) AS count FROM rate_limits WHERE expires_at<?').bind(NOW + 180_000).first()).toEqual({ count: 0 });
  });

  it('limits failed login attempts before expensive JWT verification', async () => {
    const input = { challengeID: crypto.randomUUID(), identityToken: 'invalid-token', cloudKitAccountFingerprint: FINGERPRINT };
    for (let count = 0; count < 10; count++) await expect(login(post(input), configured(), db(), NOW, resolver)).rejects.toMatchObject({ status: 401 });
    await expect(login(post(input), configured(), db(), NOW, resolver)).rejects.toMatchObject({ status: 429 });
  });

  it('rejects an unconfigured Apple app ID before any JWT exchange', async () => {
    await expect(login(post({}), { ...configured(), APPLE_APP_ID: 'CONFIGURE_APP_BUNDLE_ID_BEFORE_DEPLOYMENT' }, db(), NOW, resolver))
      .rejects.toMatchObject({ status: 503, code: 'not_configured' });
  });
});
