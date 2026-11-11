# Direct Drive client synthetic probe

Run `python3 Tests/PhoneGoogleDriveProbe/verify.py` on macOS, serially with the
repository's other Swift/Xcode builds. It writes its build, fixtures, hashes and
JSON report to a fresh temporary directory.

The probe compiles the actual `GoogleDriveHTTP.swift`, `GoogleDriveClient.swift`,
`GoogleDriveOAuth.swift`'s production token exchange, `GoogleDriveSyncProgress.swift`,
`GoogleDriveExecutionBudget.swift` and complete `RecordingCore`. Only the token provider and official HTTPS replies
are synthetic. URLProtocol intercepts every request; there is no Google network,
OAuth login, Keychain access, real recording, device operation, scheduler, or
cloud mutation.

REC-32 adds disk-backed resumable reconstruction, invalid/rolled-back/jumped
offsets, query and mid-chunk 404/410 expiry, and exact audio receipts after native
recovery, cancellation rotation, item failures and concurrent callbacks. Invalid
session offsets use durable item backoff; they cannot stop healthy peers or turn
HTTP 200 into a receipt.

The fault-report cases compile `GoogleDriveFaultReports.swift` and the exact
Foundation-only presentation/share models extracted from `GoogleDriveLibrary.swift`.
The library source is included in the before/after input hashes. These cases use
small private temporary JSON fixtures to check immediate freezing, same-request
recovery evidence, restart interruption, bounds, persistence failures, safe file
handling, clock rollback and the distinction between protocol status and network
errors. Controlled errors remain excluded from natural-fault archives. Sharing UI
is covered separately by the simulator-only `PhoneAutomaticDeliveryUIProbe`.

Error classification cases exercise actual HTTP, Client and token-exchange
boundaries. Account 403/429/5xx retain their HTTP status; only 401 needs sign-in.
Token 429/5xx/403 and an unproven 400 remain HTTP errors; only 401 or 400 with the
exact OAuth `invalid_grant` error proves failed authorization. Successful refresh
keeps the original account/client/refresh token and still rejects wider scope.
The native OAuth object delegates to this same exchange; its UIKit login and
Keychain implementation are excluded on macOS, not mocked as tested platform UI.

The revocation/reauthorization cases also compile the production Foundation-only
credential-revocation transaction and ledger transition. They use an in-memory
credential store and intercepted replies to verify that a timeout preserves a
revocation-only token for explicit retry, that this token cannot refresh or
upload, that a late response cannot delete a newer login, and that reconnecting
the same account preserves the folder/scope while leaving sync paused. These
cases do not use the real Keychain, Google's consent UI or a live revocation.
At account, file and token awaits, synthetic cancellation and timeout errors are
tested under actual Swift task cancellation, parent cancellation, and deadline
expiry. They must become `CancellationError`, which the unchanged library handles
without ordinary failure backoff. On a still-live task, those same URL errors
remain visible to the caller. These are regression proofs, not evidence that a
particular signed-device stall was caused by any of these errors.

Account diagnostics distinguish `token_access` (credential lookup, including any
refresh within the token provider) from `account_get` (the strict Drive account
identity GET). Both are fixed labels without tokens, account IDs or URLs. The
actual Client emits them at initial validation, a token change inside an API
request, and the final token check before native handoff. Successful token
lookups restore the caller's phase; failed awaits retain the precise boundary.
Held token-provider and actual URLProtocol reply cases exercise task cancellation,
finite lease expiry and a live network error at all three boundaries, then await
the operation's completion before asserting that no file bytes or native handoff
started. Their check closure matches the library's task-cancellation plus lease
checks. The native-handoff prerequisite catch also rechecks that same boundary
after a failed await, consistently with ordinary requests; a live network error
is still rethrown unchanged. These diagnostics narrow a future device stall; they do not fix or
identify the underlying network wait seen in Build 36.

Cases cover official route restrictions and the actual redirect-denial delegate,
resumable chunk ranges, persisting a session before bytes, server-confirmed
resumption, expired sessions, deterministic 409 readback, a pause arriving while
an upload response is pending, changed identity after access-token refresh, and
reconstruction after the server stored bytes but its final response was lost.

The discovery/status cases use the production progress state and actual
`TranscriptRepository` with isolated malformed, mismatched and repaired JSON.
They verify that partial scans or pending artifacts cannot claim completion,
derived issues remain visible while original audio can upload, successful
request recovery clears only the old operation error, only failed transcripts
retry after their delay, ordinary recordings with no transcript do not create
an empty retry loop, and a new discovery event survives an older IO snapshot.
The UIKit library/scheduler is checked by the signed app build, not this probe.

Worker diagnostic cases execute the actual Foundation-only attribution state
and serial writer from `GoogleDriveSyncProgress.swift`. Injected local metadata
writes cover a blocked report failure, a failed health publication, coalescing
and later successful publication without erasing either failure. They check
legacy optional-field decoding, the eight-observation/16KiB report bound,
failure attribution across rounds, finished-round grants and cancellation
signals without turning cancellation into a network error. These are diagnostic
regressions, not proof that UIKit granted a particular device round, that a
historical failure caused a current stall, or that any upload completed.
`worker-health.json` is process-local publication health; if all writes fail,
only the separate fixed OSLog failure attempt remains, not a guaranteed fresh
health file. New device acceptance must require the new build, revision 2,
freshness and matching worker/health process and publication sequence; the
frozen build-73 reader is intentionally unchanged.

Execution cases use the production budget and real client with a virtual
monotonic clock advancing four seconds per synthetic reply. They reproduce five
prerequisite GETs crossing 19 seconds: foreground work continues to a verified
upload, ordinary background work cancels before transmission, and a real
BGProcessing parent can verify an upload within its fixed 120-second budget.
The handoff case waits for an unchanged 19-second ordinary round to finish, then
uses at most one processing round with the parent's original absolute deadline.
Existing processing and identity work do not gain a follow-up round; cancelled
or expired parents cannot start one. Lifecycle signals neither shorten a real
processing grant to 19 seconds nor renew it. They also check that every
request uses no more than the remaining round time, entering the background
shortens a round without renewing it, and expiration during an awaited chunk
prevents the next chunk or metadata request while retaining its durable session,
including expiration of a processing parent.
The UIKit lease's real application notifications and OS expiration callback
still require signed-device lifecycle acceptance.

Priority cases model 281 authorized jobs with transcript filenames at positions
264–281. Only canonical top-level UUID filenames become hints, and only their
intersection with authorized jobs can move discovery forward. Consumed hints do
not repeatedly displace unfinished hints; explicit transcript saves still have
priority. Actual malformed JSON remains an issue and creates no derived upload.
The production upload selector prioritizes validated transcript bundles as
manifest, JSON, TXT, then owes an audio turn after three verified small files.
That counter survives ordinary discovery and round boundaries; only durable
verified receipts advance it. Audio turns resume an existing session first,
then the transcript's source audio, and otherwise follow ordinary ordering.
Late text with an already saved manifest exercises the same audio priority
without skipping an ordinary pending manifest's cleanup turn. Receipt failures,
repeated callbacks, and sorting cannot change existing file/session identities.

Core unit tests independently cover OAuth configuration/callback/state/PKCE
parameters, authorization scope, immutable account binding, late transcript
versions, and refusing missing checksum/size/private permissions. These tests do
not prove that Google accepts the configured iOS client, that the signed app's
callback/refresh works, or that any Agent can read its user's Drive. Those need
explicit signed-device and per-Agent acceptance checks.

P-59 upload correlation uses the first 16 lowercase hex characters of SHA-256
of `lowercase segment UUID|artifact kind|manifest.sha256`, plus the fixed kind.
The transport/fault archive and worker report write schema 2 (worker revision 4);
worker health remains schema 1/revision 3. Sync evidence writes schema 2. Old
records remain readable, but missing job correlation cannot prove upload recovery.
Strict ledger verification stores the key; HTTP 200 and another job's receipt
remain insufficient. Shared refresh freezes its initiator or is explicitly shared.

Correlation regressions cover shared-refresh waiters, transport retention and
legacy decoding, delayed callbacks during a different job, bounded private worker
evidence, and native callback attribution. `PhoneGoogleDriveRecoveryProbe` adds
resumable query/create/chunk/readback traversal and natural -1001 followed by a
later execution opportunity's exact receipt, including an unrelated-job negative
case. All inputs are synthetic. If the enclosing managed sandbox rejects Swift's
nested macro-plugin sandbox, both runners accept `--compiler-plugin-no-sandbox`;
this changes only the compiler plugin invocation, not the enclosing sandbox.

P-60 executes the production progress-first phase boundary with 703 synthetic
sources and a fixed 13-second lease. A strict metadata readback commits at
second 12 before snapshot cancellation at second 13; a discovery-first negative
control reaches no remote receipt. The selected synthetic audio file is removed
before readback. These timings use a controlled clock, not device throughput.
The actual source-snapshot method is also extracted unchanged: cancellation
retains its durable cursor and admitted ledger prefix, process reconstruction
continues it, and a receipt arriving during suspension is revisited. Metadata
aliases and failed cursor persistence cannot invent admissions. Worker revision
5 records only durable strict verification as per-execution progress, retaining
P-56 attribution and P-59 upload correlation; registration is not a receipt.

REC-38 migration handoff regressions run the actual coordinator and native
adapter with callback-controlled session lifetimes. They hold enumeration or
invalidation, start `handoffForPendingEvents`, release one old invalidation,
and require no replacement session or network-policy marker from that retired
adapter. The coordinator alone creates the next adapter. For a failing offline
negative control, use `--legacy-migration-close-control --case-filter
'REC-38 migration handoff during invalidation'`; this omits only the final
post-invalidation lifetime check in a private compiled copy, leaving production
files untouched. The regression must then reject the abandoned replacement.
