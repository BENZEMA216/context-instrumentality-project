# Record for Agent Gateway

A local implementation of a private, owner-authorized transcript service. It is **not deployed**. The checked-in Worker configuration deliberately contains resource IDs and Apple/container placeholders. No real recording, transcript, Apple token, or personal MCP configuration is part of this directory.

The existing watch → iPhone delivery and durable acknowledgement remain separate. This service stores a second, explicitly shared **transcript cache**. It does not store or serve CAF audio, prove that a CloudKit save happened, perform ASR, or start an agent in the background.

## User flow and trust boundary

1. The iPhone signs in with Apple. It first obtains a five-minute challenge and sets `ASAuthorizationAppleIDRequest.nonce` to the **exact returned nonce string**. The server verifies Apple's signature, issuer, configured app audience, timestamps, and nonce, then atomically consumes the challenge.
2. The server derives an owner from the verified Apple subject and app audience. A caller cannot choose an owner ID. A random device bearer token lasts 30 days; only its SHA-256 is stored. The phone must keep it in Keychain, bound to this gateway origin and the current CloudKit account fingerprint.
3. The phone explicitly uploads selected, already-transcribed segments whose local CloudKit ledger has a saved receipt. The server binds them to that owner's fingerprint and configured container. **The fingerprint, record name, environment, and saved time are client-reported metadata, not independent CloudKit attestation.** They do not establish user identity.
4. Codex/another compatible host connects to `https://<configured-origin>/mcp` with OAuth. The authorization page displays the client name, CIMD domain if any, callback host, requested scopes, and a ten-character code.
5. The signed-in phone looks up that code, shows the same client details, and approves an explicit set of recording IDs. The original browser completes its browser-bound consent transaction and the official OAuth provider issues a PKCE-bound authorization code. The client exchanges that code for tokens.
6. Each MCP HTTP request and each tool call rechecks the current connection in primary D1 and filters by owner, fingerprint, selected recording, and scopes. Newly uploaded recordings do **not** automatically join an existing selection. The user may authorize a fresh connection with a different selection.
7. The phone can revoke a whole connection or selected recording memberships. A revoked connection blocks even an unexpired access token immediately; refresh is rejected. A client that already copied a transcript still has that copy.

Sign in with Apple and iCloud are separate identities: this implementation does not claim that their accounts are intrinsically identical. The signed-in app supplies the current CloudKit fingerprint; uploads and connection grants stay bound to that exact fingerprint. A changed account requires a newly bound device session and fresh consent.

## Implementation

- `@cloudflare/workers-oauth-provider` **1.2.3** handles OAuth discovery, client registration/CIMD, consent cookies, PKCE, token issuance/refresh, and resource audience validation. The service does not implement its own OAuth token protocol. Private-use redirect URIs support native clients; consent prominently shows their destination.
- `@modelcontextprotocol/server` **2.3.1** handles Streamable HTTP for the modern **2026-07-28** protocol and stateless **2025-11-25** legacy clients. The local integration suite exercises both. This does not establish that every hosted agent product exposes connector installation to every account.
- D1 holds hashed Apple subjects, hashed device sessions, recording metadata/transcripts, explicit grants, tombstones, and temporary authorization state. KV is the official OAuth provider's storage. There are no Durable Objects, R2 buckets, external ASR calls, or background jobs.
- OAuth access tokens last one hour; refresh tokens last 30 days. Native device tokens last 30 days. Native logout revokes that device session; existing agent grants are independently managed in the connection list.
- Transcript replacement requires `expectedRevision` matching the current revision. The original recording manifest/audio hash and CloudKit source identity cannot be rebound. Re-uploading identical data is idempotent. Optimistic updates and change-event triggers execute atomically in D1.
- Cursors are HMAC-authenticated with a per-connection secret and bound to the tool/query. Change pages return deletion/revocation tombstones, never withdrawn transcript text. Full connection revocation returns an authorization error instead of a final change page.

## Native REST contract

All timestamps are integer Unix milliseconds. JSON bodies require `Content-Type: application/json`, unique object keys, bounded nesting, and valid UTF-8. All `/v1` routes except challenge and Apple login require `Authorization: Bearer <deviceToken>`.

| Method | Path | Request / result |
| --- | --- | --- |
| POST | `/v1/auth/challenge` | `{}` → `{challengeID, nonce, expiresAt}` |
| POST | `/v1/auth/apple` | `{challengeID, identityToken, cloudKitAccountFingerprint}` → `{ownerID, deviceToken, expiresAt, cloudKitAccountFingerprint}` |
| PUT | `/v1/recordings` | `{manifest, transcript, clientReportedCloudKit, expectedRevision?}` → `{recordingID, revision, status: stored\|unchanged, transcriptStatus: ready, cachedAt, cloudMetadataVerification: client_reported}` |
| GET | `/v1/recordings/{id}/revision` | → `{recordingID, revision, deleted}`; unknown or foreign recording is 404 |
| DELETE | `/v1/recordings/{id}` | → `{recordingID, revision, status: deleted}`; removes cached transcript/search text and creates a tombstone |
| POST | `/v1/authorizations/lookup` | `{code}` → `{authorizationID, clientID, clientName, clientURI, clientDomain, redirectHost, redirectIsLoopback, requestedScopes, expiresAt}` |
| POST | `/v1/authorizations/approve` | `{authorizationID, recordingIDs, scopes}` → connection |
| GET | `/v1/authorizations` | → `{connections: [...]}` (latest 200 for this owner and fingerprint) |
| POST | `/v1/authorizations/revoke` | `{connectionID, recordingIDs?}` → updated connection; omission revokes the entire connection |
| POST | `/v1/auth/logout` | `{}` → `{status: revoked}` |

A connection is `{connectionID, clientID, clientName, recordingIDs, scopes, status, createdAt, revokedAt}`. `models.ts` defines the precise manifest/transcript shape and bounds. A deleted recording ID cannot be restored by uploading it again. Deletion here affects the gateway transcript cache; the iPhone and CloudKit originals have their own lifecycle. Non-text recording metadata and a tombstone remain so consumers can remove stale copies.

Custom REST errors are `{error:{code,message}}`. Common codes: `invalid_request` (400), `unauthenticated` / `invalid_apple_identity` (401), `scope_mismatch` / `authorization_revoked` (403), `not_found` (404), `conflict` (409), `body_too_large` (413), `rate_limited` (429), `not_configured` (503). OAuth protocol endpoints retain standard OAuth error envelopes.

To update a transcript after a phone restart, read `/revision`, then submit its revision only after the user explicitly chooses to synchronize the updated transcript. A 409 means the client should refresh the revision and resolve the change; do not silently keep overwriting.

## Read-only MCP tools

| Tool | Required scope | Behavior |
| --- | --- | --- |
| `get_profile` | Valid connection | Owner/connection IDs and effective scopes; no Apple subject or audio access |
| `list_recordings` | `recordings:read` | Selected recording metadata, paginated |
| `get_transcript` | `transcripts:read` | One selected transcript with segment/hash provenance |
| `search_recordings` | Both scopes | Literal NFC-normalized, lowercase substring search over selected transcripts |
| `list_changes` | `recordings:read` | Incremental selected-recording updates and deletion/revocation tombstones |

Every tool is annotated read-only. Transcript text is untrusted source content, not agent instructions. No tool accepts an owner ID. There is no audio download tool, vector search, scheduling, or push notification/wakeup guarantee.

## Security and resource bounds

Browser consent uses the provider's one-use, browser-bound consent handle plus a separate HttpOnly/Secure/SameSite cookie and required same-origin polling. The page escapes client-controlled text, forbids framing, uses nonce-based CSP, and shows the redirect destination. Native requests with an Origin header must match the configured origin; ordinary native requests have no Origin. No wildcard CORS is enabled.

Limits include 1 MiB native upload bodies, 256 KiB transcript text, 10,000 bounded spans, 64 KiB MCP requests, 32 KiB OAuth requests, 500 explicitly selected IDs, and 100 records per page. Per-minute IP/device/connection rate limits are complemented by daily global caps of 200 dynamic registrations, 200 browser authorization starts, and 1,000 requests per Apple-auth operation. These caps are abuse bounds, **not a promise of zero cloud cost**. Cloudflare plan quotas, existing account usage, retention, and billing settings must be checked before any deployment. The Worker has observability disabled and this application does not log tokens or transcript text.

The backend validates Apple identity at login and expires device sessions. The phone must also observe Apple credential/account changes and explicitly log out/rebind. Apple server-to-server account-revocation notifications and a complete account-erasure workflow are not included in this MVP.

## Local verification

```sh
npm ci --ignore-scripts
npm run typecheck
npm test
npm audit --omit=dev
npx wrangler deploy --dry-run --outdir /tmp/record-for-agent-gateway-bundle
```

`vitest.config.ts` explicitly sets `remoteBindings: false` and uses synthetic configuration plus isolated local D1/KV. The suite uses generated signing keys only through a direct function parameter in tests; no HTTP request, environment flag, token header, or debug route can select test keys in production. Tests do not read private phone data or contact Apple to sign in.

## Remaining integration gates

Before deployment, configure an actual HTTPS origin, the **exact installed app bundle ID** as `APPLE_APP_ID`, and its entitled CloudKit container. Provision D1/KV only under explicit deployment authorization, apply the included migration to the intended database, and use the approved account/plan. The source intentionally does not contain those account IDs or resource credentials.

Real-device Sign in with Apple, the app's CloudKit entitlement/account state, and current hosted Codex/WorkBuddy connector availability are separate gates. A passing local MCP test does not establish any of them. In particular, CloudKit private-database access requires the proper Apple developer capabilities; a local Personal Team build is not evidence of a working cloud library.

Official references: [Apple identity verification](https://developer.apple.com/documentation/signinwithapple/verifying-a-user), [Cloudflare OAuth provider](https://github.com/cloudflare/workers-oauth-provider), [MCP TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk), [Codex MCP transports](https://developers.openai.com/codex/mcp), [OpenAI plugin authentication](https://developers.openai.com/plugins/build/auth), [WorkBuddy connector authentication](https://open.workbuddy.cn/docs/connector).
