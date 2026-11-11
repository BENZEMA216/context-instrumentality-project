import { expect, test } from 'vitest';
import { env } from 'cloudflare:workers';
import { base64url, canonical, randomToken, sha256, strictJSON } from '../src/http';
import { upload, currentConnection } from '../src/store';
import { listChanges, listRecordings, getTranscript } from '../src/mcp';
import { revoke } from '../src/authorization';
import { PROTOCOL_VERSION_META_KEY, CLIENT_INFO_META_KEY, CLIENT_CAPABILITIES_META_KEY, SERVER_INFO_META_KEY } from '@modelcontextprotocol/server';
import { call, data, db, device, NOW, request, sample, testEnv } from './helpers';
import type { ConnectionRow, DeviceSession } from '../src/models';

async function seedConnection(session: DeviceSession, recordingIDs: string[], scopes = ['recordings:read', 'transcripts:read']) {
  const id = crypto.randomUUID();
  await db().prepare('INSERT INTO connections(id,owner_id,fingerprint,client_id,client_name,scope_json,status,created_at,cursor_key) VALUES (?,?,?,?,?,?,\'active\',?,?)').bind(id, session.ownerID, session.cloudKitAccountFingerprint, 'test-client', 'Synthetic client', canonical(scopes), NOW, randomToken()).run();
  for (const recordingID of recordingIDs) await db().prepare('INSERT INTO connection_recordings(connection_id,owner_id,recording_id) VALUES (?,?,?)').bind(id, session.ownerID, recordingID).run();
  return currentConnection(db(), session.ownerID, id);
}
async function put(session: DeviceSession, value = sample()) { return upload(request('/v1/recordings', value, undefined, 'PUT'), testEnv, db(), session, NOW); }
async function connect(session: DeviceSession & { token: string }, ids: string[], options: { scopes?: string[]; clientName?: string } = {}) {
  const scopes = options.scopes ?? ['recordings:read', 'transcripts:read'];
  const registered = await call(request('/oauth/register', { client_name: options.clientName ?? 'Synthetic Codex', redirect_uris: ['http://127.0.0.1:54321/callback'], token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'] }));
  expect(registered.status).toBe(201); const client = await data(registered);
  const verifier = randomToken(48), challenge = base64url(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))));
  const params = new URLSearchParams({ client_id: client.client_id, redirect_uri: 'http://127.0.0.1:54321/callback', response_type: 'code', scope: scopes.join(' '), code_challenge: challenge, code_challenge_method: 'S256', state: 'synthetic-state', resource: 'https://gateway.test/mcp' });
  const page = await call(request('/authorize?' + params));
  expect(page.status).toBe(200);
  const cookies = page.headers.getSetCookie().map(value => value.split(';')[0]).join('; ');
  const html = await page.text(), code = html.match(/<code>([^<]+)<\/code>/)![1];
  const lookup = await call(request('/v1/authorizations/lookup', { code }, session.token));
  expect(lookup.status).toBe(200); const pending = await data(lookup);
  const approved = await call(request('/v1/authorizations/approve', { authorizationID: pending.authorizationID, recordingIDs: ids, scopes }, session.token));
  expect(approved.status).toBe(200); const connection = await data(approved);
  return { client, verifier, cookies, html, pending, connection };
}
async function finish(authorization: Awaited<ReturnType<typeof connect>>) {
  const poll = await call(request('/authorize/poll', { authorizationID: authorization.pending.authorizationID }, undefined, 'POST', { Cookie: authorization.cookies, Origin: env.PUBLIC_ORIGIN }));
  expect(poll.status).toBe(200); const redirect = new URL((await data(poll)).redirectTo);
  expect(redirect.searchParams.get('state')).toBe('synthetic-state');
  const response = await call(new Request('https://gateway.test/oauth/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'authorization_code', client_id: authorization.client.client_id, code: redirect.searchParams.get('code')!, redirect_uri: 'http://127.0.0.1:54321/callback', code_verifier: authorization.verifier, resource: 'https://gateway.test/mcp' }) }));
  expect(response.status).toBe(200); return data(response);
}
async function mcp(token: string, method: string, params: unknown = {}, modern = false) {
  const payload = { jsonrpc: '2.0', id: 1, method, params: { ...(params as object), ...(modern ? { _meta: { [PROTOCOL_VERSION_META_KEY]: '2026-07-28', [CLIENT_INFO_META_KEY]: { name: 'synthetic-client', version: '1' }, [CLIENT_CAPABILITIES_META_KEY]: {} } } : {}) } };
  return call(request('/mcp', payload, token, 'POST', { Accept: 'application/json, text/event-stream', 'MCP-Protocol-Version': modern ? '2026-07-28' : '2025-11-25', ...(modern ? { 'Mcp-Method': method, ...(method === 'tools/call' ? { 'Mcp-Name': (params as { name: string }).name } : {}) } : {}) }));
}
test('strict JSON and bounded request schemas reject duplicates, hidden owners, wrong media and invalid spans', async () => {
  expect(() => strictJSON('{"a":1,"a":2}')).toThrow(); expect(() => strictJSON('{"a":1,}')).toThrow();
  const session = await device();
  for (const value of [{ ...sample(), ownerID: session.ownerID }, { ...sample(), transcript: { ...sample().transcript, spans: [{ start: 0, end: 2, text: 'out of range' }] } }, { ...sample(), transcript: { ...sample().transcript, audioSHA256: 'c'.repeat(64) } }])
    await expect(put(session, value)).rejects.toMatchObject({ status: 400 });
  const wrongType = await call(new Request('https://gateway.test/v1/recordings', { method: 'PUT', headers: { Authorization: `Bearer ${session.token}`, 'Content-Type': 'text/plain' }, body: '{}' }));
  expect(wrongType.status).toBe(400);
  const huge = await call(request('/v1/recordings', { payload: 'x'.repeat(1024 * 1024) }, session.token, 'PUT'));
  expect(huge.status).toBe(413);
});
test('upload is idempotent, account bound and audio immutable; transcript replacements require current revision', async () => {
  const session = await device(); const first = await put(session); expect(first.revision).toBe(1);
  expect((await put(session)).status).toBe('unchanged');
  const revision = await data(await call(request('/v1/recordings/' + sample().manifest.id + '/revision', undefined, session.token))); expect(revision).toEqual({ recordingID: sample().manifest.id, revision: 1, deleted: false });
  const changed = sample(); changed.transcript.text = 'updated synthetic text';
  await expect(put(session, changed)).rejects.toMatchObject({ status: 409 });
  const updated = await put(session, { ...changed, expectedRevision: 1 }); expect(updated.revision).toBe(2);
  await expect(put(session, { ...sample(), expectedRevision: 1 })).rejects.toMatchObject({ status: 409 });
  const wrongFingerprint = { ...sample(), clientReportedCloudKit: { ...sample().clientReportedCloudKit, accountFingerprint: 'c'.repeat(64) } };
  await expect(put(session, wrongFingerprint)).rejects.toMatchObject({ status: 403 });
  const wrongAudio = sample(); wrongAudio.manifest.sha256 = wrongAudio.transcript.audioSHA256 = 'd'.repeat(64);
  await expect(put(session, { ...wrongAudio, expectedRevision: 2 })).rejects.toMatchObject({ status: 409 });
  expect((await db().prepare('SELECT kind FROM recording_changes ORDER BY sequence').all()).results.map(row => row.kind)).toEqual(['created', 'updated']);
});
test('each query isolates owner and selected recordings; HMAC cursors bind connection and search', async () => {
  const a = await device(), b = await device('c'.repeat(64));
  const one = sample(), two = sample('10000000-0000-4000-8000-000000000002', 1), three = sample('10000000-0000-4000-8000-000000000003', 2);
  await put(a, one); await put(a, two); await put(a, three);
  const bValue = sample(one.manifest.id, 0, b.cloudKitAccountFingerprint); bValue.transcript.text = 'owner B only'; await put(b, bValue);
  const ca = await seedConnection(a, [one.manifest.id, two.manifest.id]), cb = await seedConnection(b, [one.manifest.id]);
  const page = await listRecordings(db(), ca, { limit: 1 }); expect(page.recordings).toHaveLength(1); expect(page.nextCursor).toBeTruthy();
  expect((await listRecordings(db(), ca, { limit: 1, cursor: page.nextCursor! })).recordings[0].id).toBe(one.manifest.id);
  await expect(listRecordings(db(), cb, { limit: 1, cursor: page.nextCursor! })).rejects.toMatchObject({ code: 'invalid_cursor' });
  await expect(listRecordings(db(), ca, { limit: 1, cursor: page.nextCursor! }, 'APPLE')).rejects.toMatchObject({ code: 'invalid_cursor' });
  await expect(getTranscript(db(), ca, three.manifest.id)).rejects.toMatchObject({ status: 404 });
  expect((await listRecordings(db(), ca, { limit: 10 }, 'apple')).recordings).toHaveLength(2);
  const profile = await getTranscript(db(), cb, one.manifest.id); expect(profile.recordingID).toBe(one.manifest.id); expect(profile.transcript.text).toBe('owner B only');
});
test('partial revoke emits only a tombstone and full revoke immediately blocks current authorization', async () => {
  const session = await device(); await put(session); const connection = await seedConnection(session, [sample().manifest.id]);
  const initial = await listChanges(db(), connection, { limit: 100 }); expect(initial.changes.map(row => row.kind)).toEqual(['created']);
  await revoke(request('/unused', { connectionID: connection.id, recordingIDs: [sample().manifest.id] }), db(), session, NOW + 100);
  expect((await listRecordings(db(), connection, { limit: 100 })).recordings).toEqual([]);
  await expect(getTranscript(db(), connection, sample().manifest.id)).rejects.toMatchObject({ status: 404 });
  const changes = await listChanges(db(), connection, { limit: 100, cursor: initial.nextCursor }); expect(changes.changes.map(row => row.kind)).toEqual(['revoked']);
  expect(JSON.stringify(changes)).not.toContain('合成');
  await revoke(request('/unused', { connectionID: connection.id }), db(), session, NOW + 200);
  await expect(currentConnection(db(), session.ownerID, connection.id)).rejects.toMatchObject({ status: 403 });
});
test('OAuth metadata and browser consent prove PKCE connection without granting unselected data', async () => {
  const a = await device(); await put(a);
  const unauthorized = await call(request('/mcp', { jsonrpc: '2.0', id: 1, method: 'tools/list' }));
  expect(unauthorized.status).toBe(401); expect(unauthorized.headers.get('WWW-Authenticate')).toContain('oauth-protected-resource');
  const metadata = await data(await call(request('/.well-known/oauth-authorization-server')));
  expect(metadata.code_challenge_methods_supported).toEqual(['S256']);
  const authorization = await connect(a, [sample().manifest.id], { clientName: '<script>alert(1)</script>' });
  expect(authorization.html).not.toContain('<script>alert(1)</script>'); expect(authorization.html).toContain('&#60;script&#62;');
  const missingProof = await call(request('/authorize/poll', { authorizationID: authorization.pending.authorizationID }, undefined, 'POST', { Origin: env.PUBLIC_ORIGIN }));
  expect(missingProof.status).toBe(403);
  const tokens = await finish(authorization); expect(tokens.access_token).toBeTruthy(); expect(tokens.refresh_token).toBeTruthy();
  const initialized = await data(await mcp(tokens.access_token, 'initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'test', version: '1' } }));
  expect(initialized.result.protocolVersion).toBe('2025-11-25');
  const tools = await data(await mcp(tokens.access_token, 'tools/list')); expect(tools.result.tools.map((tool: any) => tool.name).sort()).toEqual(['get_profile', 'get_transcript', 'list_changes', 'list_recordings', 'search_recordings']);
  const transcript = await data(await mcp(tokens.access_token, 'tools/call', { name: 'get_transcript', arguments: { recordingID: sample().manifest.id } }));
  expect(JSON.parse(transcript.result.content[0].text).transcript.text).toContain('合成测试');
  const modern = await data(await mcp(tokens.access_token, 'server/discover', {}, true)); expect(modern, JSON.stringify(modern)).toHaveProperty('result'); expect(modern.result._meta[SERVER_INFO_META_KEY].name).toBe('record-for-agent'); expect(modern.result.supportedVersions).toContain('2026-07-28');
  const modernRead = await data(await mcp(tokens.access_token, 'tools/call', { name: 'get_transcript', arguments: { recordingID: sample().manifest.id } }, true)); expect(modernRead.result.content[0].text).toContain('合成测试');
  const wrongOrigin = await call(request('/mcp', { jsonrpc: '2.0', id: 1, method: 'tools/list' }, tokens.access_token, 'POST', { Origin: 'https://evil.example' })); expect(wrongOrigin.status).toBe(403);
  await call(request('/v1/authorizations/revoke', { connectionID: authorization.connection.connectionID }, a.token));
  expect((await mcp(tokens.access_token, 'tools/list')).status).toBe(403);
  const refreshed = await call(new Request('https://gateway.test/oauth/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'refresh_token', client_id: authorization.client.client_id, refresh_token: tokens.refresh_token, resource: 'https://gateway.test/mcp' }) }));
  expect(refreshed.status).toBe(400); expect((await data(refreshed)).error).toBe('invalid_grant');
});
test('native approval refuses another owner recording, excessive scope and replay', async () => {
  const a = await device(), b = await device('c'.repeat(64)); await put(a);
  const authorization = await connect(a, [sample().manifest.id]);
  const replay = await call(request('/v1/authorizations/approve', { authorizationID: authorization.pending.authorizationID, recordingIDs: [sample().manifest.id], scopes: ['recordings:read'] }, b.token));
  expect(replay.status).toBe(404);
  const revokeForeign = await call(request('/v1/authorizations/revoke', { connectionID: authorization.connection.connectionID }, b.token)); expect(revokeForeign.status).toBe(404);
});
test('scope reduction is enforced at tool execution and no audio tool is exposed', async () => {
  const a = await device(); await put(a); const authorization = await connect(a, [sample().manifest.id], { scopes: ['recordings:read'] }); const tokens = await finish(authorization);
  const response = await data(await mcp(tokens.access_token, 'tools/call', { name: 'get_transcript', arguments: { recordingID: sample().manifest.id } }));
  expect(response.result.isError).toBe(true); expect(JSON.parse(response.result.content[0].text).error.code).toBe('scope_mismatch');
});

test('deleting cached transcript is owner scoped, removes text and emits a deletion tombstone', async () => {
  const a = await device(), b = await device(); await put(a); const connection = await seedConnection(a, [sample().manifest.id]);
  const initial = await listChanges(db(), connection, { limit: 100 });
  expect((await call(request('/v1/recordings/' + sample().manifest.id, undefined, b.token, 'DELETE'))).status).toBe(404);
  expect((await call(request('/v1/recordings/' + sample().manifest.id + '/revision', undefined, b.token))).status).toBe(404);
  const deleted = await data(await call(request('/v1/recordings/' + sample().manifest.id, undefined, a.token, 'DELETE'))); expect(deleted.status).toBe('deleted');
  const revision = await data(await call(request('/v1/recordings/' + sample().manifest.id + '/revision', undefined, a.token))); expect(revision.deleted).toBe(true); expect(revision.revision).toBe(2);
  expect((await listChanges(db(), connection, { limit: 100, cursor: initial.nextCursor })).changes.map(row => row.kind)).toEqual(['deleted']);
  await expect(getTranscript(db(), connection, sample().manifest.id)).rejects.toMatchObject({ status: 404 });
  const row = await db().prepare('SELECT transcript_json,search_text FROM recordings WHERE owner_id=? AND id=?').bind(a.ownerID, sample().manifest.id).first(); expect(row).toEqual({ transcript_json: '{}', search_text: '' });
  await expect(put(a)).rejects.toMatchObject({ status: 409 });
});

test('a pending approval rejects foreign recordings and scopes outside the browser request', async () => {
  const a = await device(), b = await device(); await put(a);
  const id = crypto.randomUUID();
  await db().prepare('INSERT INTO authorization_requests(id,code_hash,browser_hash,consent_handle,details_json,requested_scope_json,client_id,status,expires_at,created_at) VALUES (?,?,?,?,?,?,?,\'pending\',?,?)')
    .bind(id, await sha256(id), 'synthetic', 'synthetic', canonical({ clientName: 'Synthetic' }), canonical(['recordings:read']), 'test-client', Date.now() + 60000, NOW).run();
  const foreign = await call(request('/v1/authorizations/approve', { authorizationID: id, recordingIDs: [sample().manifest.id], scopes: ['recordings:read'] }, b.token)); expect(foreign.status).toBe(403);
  const expanded = await call(request('/v1/authorizations/approve', { authorizationID: id, recordingIDs: [sample().manifest.id], scopes: ['recordings:read', 'transcripts:read'] }, a.token)); expect(expanded.status).toBe(403);
  expect((await db().prepare('SELECT COUNT(*) AS count FROM connections').first<{ count: number }>())!.count).toBe(0);
});

test('PKCE rejects the wrong verifier; browser approval cannot be replayed', async () => {
  const a = await device(); await put(a); const authorization = await connect(a, [sample().manifest.id]);
  const pollBody = { authorizationID: authorization.pending.authorizationID };
  const pollHeaders = { Cookie: authorization.cookies, Origin: env.PUBLIC_ORIGIN };
  const finished = await data(await call(request('/authorize/poll', pollBody, undefined, 'POST', pollHeaders)));
  const code = new URL(finished.redirectTo).searchParams.get('code')!;
  const bad = await call(new Request('https://gateway.test/oauth/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'authorization_code', client_id: authorization.client.client_id, code, redirect_uri: 'http://127.0.0.1:54321/callback', code_verifier: randomToken(48), resource: 'https://gateway.test/mcp' }) }));
  expect(bad.status).toBe(400); expect((await data(bad)).error).toBe('invalid_grant');
  expect((await call(request('/authorize/poll', pollBody, undefined, 'POST', pollHeaders))).status).toBe(409);
});

test('browser cancellation revokes its approved connection and does not produce an access code', async () => {
  const a = await device(); await put(a); const authorization = await connect(a, [sample().manifest.id]);
  const response = await call(request('/authorize/poll', { authorizationID: authorization.pending.authorizationID, cancel: true }, undefined, 'POST', { Cookie: authorization.cookies, Origin: env.PUBLIC_ORIGIN }));
  expect(response.status).toBe(200); const redirect = new URL((await data(response)).redirectTo); expect(redirect.searchParams.get('error')).toBe('access_denied'); expect(redirect.searchParams.has('code')).toBe(false);
  await expect(currentConnection(db(), a.ownerID, authorization.connection.connectionID)).rejects.toMatchObject({ status: 403 });
});

test('concurrent transcript replacements use compare-and-swap and create a single change', async () => {
  const a = await device(); await put(a); const first = sample(), second = sample(); first.transcript.text = 'revision A'; second.transcript.text = 'revision B';
  const results = await Promise.allSettled([put(a, { ...first, expectedRevision: 1 }), put(a, { ...second, expectedRevision: 1 })]);
  expect(results.filter(result => result.status === 'fulfilled')).toHaveLength(1); expect(results.filter(result => result.status === 'rejected')).toHaveLength(1);
  expect((await db().prepare('SELECT COUNT(*) AS count FROM recording_changes WHERE kind=\'updated\'').first<{ count: number }>())!.count).toBe(1);
});
