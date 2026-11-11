# Phone receiver and transcript-return synthetic probe

Run `python3 Tests/PhoneMultiReceiverProbe/verify.py` serially with other Swift or
Xcode builds. It compiles the actual credential vault, per-receiver worker,
coordinator, archive builder, transcript-return client/loop and full RecordingCore.
The report and all synthetic fixtures are written to a new temporary directory.

The new ASR cases use the production HTTPS client with URLProtocol responses.
They check fixed POST routing, bearer confinement, redirect rejection, bounded
stream collection, native cancellation, complete receipt/source/scope echoes,
UTF-8 content hash/size and the actual SegmentTranscript validator. A bad second
item cannot save a valid first item. The real TLS pin helper is reused by the
client; URLProtocol does not prove a live receiver certificate or phone network.

The generated `swift-query-request.json` and `swift-query-manifest.json` fixtures
contain only synthetic sources and capabilities. They use the actual
TransportCodec and specifically verify integer millisecond receipt round-trips
at 1792876029274 and neighboring current-scale values.
The checked-in synthetic `Fixtures` include that real Swift request, its source
manifest, and the actual Python endpoint's canonical response from an isolated
receiver store. The suite validates the response again with the production Swift
validator; these are synthetic contract fixtures, not user receipts or speech.

The return loop runs separately from audio uploads. It queries at most four
already delivered, locally received, authorized sources in a round, with a
twelve-second absolute budget checked during selection, after awaits and before
commits. Selection cancellation reaches its detached IO task. A grant-bound
durable cursor gives later sources a turn even when earlier pending statuses
become due again; a 140-pending-plus-tail-ready case restarts after each batch.
Newer sources are initially preferred by the actual worker. Ready local text
does not require another request. Network errors and pending/retry statuses wait
before another attempt; no_speech waits longer and never creates an empty text
file or claims a complete recording period.

Scope, durable delivery receipt, original manifest and local reception are
checked again before committing. TranscriptRepository.saveIfAbsent uses the
same lock and atomic write as ordinary local saves, so a concurrent valid local
version wins. Original audio, Watch ACKs and delivery receipts are untouched.
The origin/version marker is durable before writing returned text. Actual-worker
cases verify that this exact version does not send another audio ZIP back to its
origin, while another authorized receiver and a changed local text version keep
the existing delivery behavior. The Drive callback uses its own existing grant;
the receiver never uploads to Drive itself.

UIKit and the operating system still control real background execution. A local
retry hint or a requested BGProcessing wake is not proof of continuous execution.
No test reads real Keychain entries, makes a real network request, accesses a
device, transcribes real audio, downloads a model or messages another app.

For an isolated negative control, `RFA_PROBE_CASE_FILTER` can select a case by
name. With no filter the complete suite runs.

`receiver_connection_status` exercises the production status projection without
changing the grant. A controlled timeout exposes the persisted unfinished
delivery; the same delivery's late, validated receipt clears that failure and
preserves its storage time. Neither saved pairing, an enabled automatic setting,
an empty queue nor a past receipt claims current reachability.

The controlled in-flight retry case waits for the real durable backoff, then
leaves the second sender unresolved. The warning and actual failure time remain
visible during retry; repeated status reads cannot start another sender. A valid
receipt alone clears transfer failure. The separate legacy delivery-record time
still follows `job.updatedAt`, including retry registration; `lastTransferAt`
retains the actual result time. Stale attempt errors cannot replace that result.

REC-35 `receiver_health` cases distinguish saved pairing, a dated status-only
observation and receipt-verified transfer results. Metadata-only workers cover
paused checks, concurrency deduplication, cancellation, retirement, same-grant
restoration, foreign/corrupt history and repair. Prepared inert archive bytes and
synthetic metadata cover persistent transfer failure, a successful probe that cannot clear it,
HTTP 200/mismatched receipts, exact late receipt recovery, synchronous upload
failure and vanished native-task recovery. Raw synthetic error messages cannot
enter persisted status or delivery errors. These cases start after archive
preparation and run the actual worker's fingerprint, registration, retry,
receipt-validation and persistence paths; they do not prove ZIP construction.
The existing broader generated-CAF cases still exercise the real archive builder
and its OS `NSFileCoordinator` service without a replacement implementation.

Review regressions additionally cover neutral legacy status responses (including
restoration of the old `unsupportedProbe` failure encoding), re-pair guidance
that remains attached to blocked work after an unrelated receipt and relaunch,
local upload errors with exact-delivery receipt recovery, and retained dated
summaries when their ledger binding no longer exists. Natural page checks have
a 30-second minimum interval, including a cancelled first request; explicit
checks bypass that interval and still deduplicate an in-flight request. No timer
is introduced. These cases use the production worker and fixed synthetic clocks.

The production health HTTP client runs through isolated URLProtocol responses:
exact authenticated GET `/v1/status`, no request body, disabled cache, receiver
identity/schema validation, HTTP/transport categories, changed URL/redirect and
response size rejection, finite timeout, cancellation, and no retry or polling.
No synthetic health case opens a network socket or queries transcripts. These
tests do not prove live Bonjour resolution, TLS trust, local-network permission,
firewall behavior or real iPhone-to-Mac reachability.

Background restoration cases also compile the production Foundation restoration
gate and the receiver's native invalidation/persistence barrier. A cold store
loads credentials and its ledger without constructing a URLSession. UIKit first
arms an event token and stores its handler; foreground or a live, at-most-120s
processing parent can separately restore unfinished native tasks. Native delegate
ingress captures that token under a lock before an actor hop or persistence wait.
A matching normal drain preserves a running upload. An unclaimed or old-token
drain requires cancelling only that exact session and waiting for native
invalidation plus ordered receipt persistence. It never completes a later handler
from a cached old drain. The tests retain duplicate handlers, defer unknown-scope
cancellation until registration finishes, preserve receipts and pairing identity,
and ensure pause during handoff does not recreate a transport. They do not claim
that iOS grants execution continuously or verify a real device relaunch.


Native transcript queries (35): actual `ReceiverTranscriptBackgroundQueue` and `PhoneReceiverTranscriptReturn` run against a retained synthetic native-task owner. Each immutable receiver grant has a separate `.transcript-query.<grantEpoch>` URLSession and at most one file-backed POST, at most four exact receipts, a 32 KiB request and 4 MiB response. Real WC execution leases may register/recover that owner within the existing 12-second preparation budget; no fake BGProcessing permission is created. Paused/retired grants cancel only that owner and wait for native invalidation.

`AutomaticDelivery/<grantEpoch>/transcript-queries/native-query-state.json` contains only scope, receipts/manifests, nonce/task binding, request/response hashes and byte counts, and durable retry dates. `*.request.json` contains the existing query capability JSON, never the bearer token or transcript text. `*.response.json` may contain private transcript text: do not collect or print it for diagnostics. Files are 0600 and directories 0700 with first-unlock protection on iOS; writes synchronize the exclusive temporary file, rename, then synchronize its parent. Strict source/hash validation and atomic `saveIfAbsent` remain shared with foreground queries.

The native task carries the same paired bearer, pinned leaf/hostname/port and exact POST route. Cold recovery also checks original URL/method, nonce header/description, body digest header and expected byte count before adopting or resuming a suspended task. Headers are task identity evidence only, not server authentication. Background URLSession automatically follows redirects and does not call the redirect veto delegate: exact final URL checks forbid committing a redirected result but do not claim to prevent every network redirect. The paired Mac query handler must continue to return directly without redirects. `earliestBeginDate` is an OS scheduling hint, never a precise wakeup or latency guarantee; user force-quit/system restrictions still apply.

New actual-code regressions cover cold WC/finite and expired leases, registration-before-resume, pending-before-UIKit completion, a held next-registration worker, process relaunch, suspended pre-resume crashes, exact task ownership, expiry, pause/revocation, wrong TLS and stale nonces, durable retry, response replay and persistence failure, link rejection/private modes, strict preservation of newer local text, and finite progress past 140 pending sources. The TLS fixture is a synthetic self-signed public certificate with no private key in the repository; verification uses a fixed fixture-valid date and disables network trust fetching. Central handoff diagnostics use a random process nonce and monotonic owner/wave counters; no raw identifiers, credentials, handoff UUIDs, URLs or transcript text. `completion_called` is emitted after the actual UIKit closure returns.

Native query scheduling (36) additionally distinguishes cleanup from an interrupted
request: invalidating an empty session preserves the existing failure counter and
retry date. A future attempt whose exact authorized items are all `no_speech` may
yield to an authorized source that the actual transcript repository still lacks,
when its identity is new or its exact non-no-speech entry is already due. Its
immutable grant, nonce, due date and complete request digest must match;
native invalidation and ordered callbacks finish before a replacement can be
registered. Intentional supersession preserves real network backoff and never
creates a new failure. A pending owner, a candidate whose known due date is still
future, existing local text, changed authorization, pause and stale tickets do not
gain this exception. The preparation worker returns
after requesting supersession instead of waiting on its own native drain.

Failure diagnostics correlate the same random process/query counters as registration
and contain only fixed error-code/phase classifications plus bounded elapsed/due
seconds. They never include `NSError` descriptions or userInfo.

The production native-query configuration retains a 30-second request timeout and
uses the finite seven-day Foundation resource window (604800 seconds), documented
by [Apple](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforresource).
The current no-speech and capped network retry plans wait up to one hour; the
resource budget must leave time for that scheduled start and connectivity before
the bounded response transfers. A real `URLSessionConfiguration` returned by the
same factory used in the production client is inspected directly, without creating
a URLSession or network task. Actual-queue cases cover one-hour and one-day future
dates, durable task ownership beyond the former 120-second limit, and an inherited
failure count of 30 without clearing its real retry date. A genuine synthetic
timeout still takes the existing one-hour capped backoff.

This changes no persisted schema or session identifier and does not cancel retained
native tasks. Tests do not establish which policy an already retained system task
uses after an application upgrade, guarantee a start at earliestBeginDate, or prove
a successful background response on a real phone. Those remain device acceptance
checks after installation.
