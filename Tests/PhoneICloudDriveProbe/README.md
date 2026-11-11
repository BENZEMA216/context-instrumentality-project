# Phone iCloud Drive offline probe

Candidate 103 reserves up to eight of the existing 32 metadata permits for
explicit provider-pending observations older than one minute. A durable pending
cursor and alternating class turn retain ordinary historical checks across cold
opportunities. This selects work only; it creates no timer or audio access and
does not confirm upload. The 40-source regression seeds 24 stale pending audio
observations behind positives, removes synthetic source audio, and clears those
observations in three cold opportunities. Fresh negatives must not consume the
reservation repeatedly or break existing complete-rotation regressions.
Final candidate checks: typed 66 assertions (a subset), full synthetic 703.

Candidate 102 adds bounded, path-free writer-repair diagnostics: attempts,
locally committed repairs, deferrals and conflicts, plus the last outcome/time.
Outcome 0 means an attempt began, 1 means the local export ledger committed,
2 means revalidation remained deferred, and 3 means content/identity conflict.
A started attempt without a terminal event may have been interrupted; it is
not proof that work is still running. No outcome is a provider upload receipt.
Counters saturate at one million, remain optional in legacy caches and never
authorize retries or cleanup. The typed probe checks read-only noninterference,
successful repairs, cold-load preservation and a tampered export's conflict.

Run on a Mac with Xcode selected:

```sh
python3 Tests/PhoneICloudDriveProbe/verify.py
```

For only original-directory recovery, add `--recovery-only`; for D4 scheduler
regressions use `--continuation-only`, and for D8 observations use `--typed-only`.
The review follow-ups can be selected with `--legacy-export-only` and
`--source-isolation-only`; the default run includes both. Use
`--output-dir /absolute/new/private/path` to retain the frozen source, native
compiler output, executable output, and before/after source hashes.

If the execution environment cannot use the macOS file-coordination service,
run `--synthetic-coordination` as a separate logic check. This opt-in mode replaces
only the Phone coordinator's two calls with direct accessors for the generated
temporary files. Its output and `proof.json` explicitly record
`syntheticCoordination: true`; it does not validate system coordination, daemon
availability, provider URL substitutions or access grants. Run the default
command as well and report any system-coordination failure separately. The
default probe continues to use the real `NSFileCoordinator`.

The probe freezes and compiles the production `RecordingCore` source and
`Phone/ICloudDriveLibrary.swift`. It replaces only UIKit application state and
the existing device-local `GoogleDriveLocalFiles` writer with documented harness
shims in a new private directory. The Phone actor, bookmark/grant orchestration,
stop-intent queue, directory identity logic, `NSFileCoordinator`, and Core export
writer remain production code, with system coordination replaced only in the
explicit opt-in mode described above.

All source bytes and destinations are newly generated synthetic temporary files.
Injected `ICloudDriveFolderAccess` supplies fake bookmarks, access counters,
provider identity and upload flags. No actual iCloud account, iCloud folder,
private recording, device, provisioning profile or cloud/network API is used.
The `.system` folder validator is also checked against an ordinary temporary
local directory to verify that it rejects an unconfirmed iCloud destination.

Coverage includes selection without export, separate explicit authorization,
first export, repeat resume without reopening missing local audio, late text
reusing the unchanged exported audio, pending versus positively confirmed cloud
status, stale bookmarks, directory identity changes, missing committed markers,
cancellation before processing, balanced security scopes, reconnect before the
first marker, independent durable pause/disconnect intents across cold launch,
MainActor pause/disconnect immediately followed by background suspension,
foreground recovery after a cancelled initial state publish, concurrent stop
intent ordering, and keeping marker/commit uploads pending independently of
material files. Cold-process checks wait for the tiny stop-intent write to land;
they do not claim durability after arbitrary immediate process termination.

Original-directory recovery exercises the production worker and the bounded
Core marker reader against actual synthetic files. A same-identity reselection
can refresh a stale bookmark without changing the grant. A changed identity and
valid original marker produce only an in-memory candidate; selection or cancel
cannot mutate the saved grant, and a separate confirmation must recheck the
candidate, marker and current saved grant before committing a paused binding.
An exact copied marker in a different directory cannot silently inherit the
grant. The checks include candidate identity/marker changes, a newer durable
disconnect, pending recovery of an enabled grant, atomic-state write failure,
and scope balancing. Recovery runs with both synthetic source and exported audio
removed, so neither is required for a successful binding recovery.

The marker cases separately exercise a missing library, missing marker, wrong
library, invalid JSON, symlink, hard link, FIFO and a marker over 4 KiB. These use
the real reader; only a temporary `EAGAIN` is injected through the documented
folder-access seam. Its diagnostic must retain the typed errno, and a new
explicit opportunity must retry successfully without changing the old grant.
Missing committed markers remain unresolved and are never recreated. A pending
candidate prevents passive exports and provider refreshes. Diagnostic flags are
checked alongside the actual unmodified marker and grant bytes; they are not
treated as independent proof of file-access behavior.

The foreground scheduling regressions also count metadata checks: identical
snapshots and reordered manifests do not restart work, repeated busy resumption
coalesces, genuine additions and late text arriving during an in-flight provider
check receive one follow-up, a receive-ID-only change is not lost, and foreground
state restoration does not repeat the cloud scan. The UI phase reports provider
metadata checks separately from writing files. Transcript discovery uses Core's
single atomic batch API and retains all source/ledger validation.


The foreground sync regression uses the actual scheduler with eight synthetic
sources and blocks target validation immediately after two durable local
exports. Against the `4229741` Phone source the UI still reports zero local
exports and zero provider confirmations, no provider callback has run, and the
published archive still has zero local artifacts. The sliced scheduler instead
publishes two audio exports, seven confirmed files and six sources still waiting
for local export before the next source can proceed. Pause at that boundary
prevents a third write; resuming drains all remaining slices. A separate
24-source case proves that a permanent export conflict becomes idle, healthy
peers progress, transcript coverage reaches all 24 sources, and a corrupt
transcript warning from an earlier slice remains visible.

Production foreground sync now admits two export/repair attempts per command,
uses the existing bounded transcript selection, checks provider metadata before
historical transcript inspection, and publishes the completed slice. One
opportunity retains its discovery snapshot and attempted-source set; a changed
snapshot, transcript notification or later foreground opportunity starts a new
pass. Failed sources do not create an automatic retry loop. Missing provider
observations for older local exports join the new export cohort after a pause
clears the cache. The background 18-second parent lease, three two-source batches
and shared 32-query limit remain unchanged. This is a work-count bound, not a
hard latency guarantee: first repository enumeration and one synchronous
coordinator/provider call can still take longer. All source/target/marker and
identity checks, replay fences and unchecked-path gates remain required.

Sync evidence adds optional, path-free per-artifact local export/check times,
existing typed provider result, and current/unchecked/replay/context/not-local
gate categories. Historical observations remain explanatory and cannot promote
an artifact to provider-uploaded. Run only these focused regressions with
`--foreground-slices-only`; the default run includes them and the older suites.

Every synchronization round checks at most 32 provider metadata items. The
library marker receives the first available permit once per invalidated cohort;
the remaining permits rotate across audio, manifests, text and per-source commits.
A completed marker check is not repeated in every continuation slice: even a
slow marker cannot monopolize the remaining cohort. Ordinary inspections without
an invalidated cohort still check the marker first, within the same cap.
The durable next-path cursor and completed observations survive cancellation.
Background delivery uses a genuine parent execution lease, waits at most 18
seconds, and continues at most three two-job batches while exports remain.
Within each batch, the pending export and any already-pending transcript payload lead
optional text discovery for new audio, historical transcript discovery and
provider status checks. Cold full repository
discovery follows pending ledger exports; already supplied source metadata admits
new arrivals first. Cold background metadata discovery checks cancellation between
files and reads each receipt through a bounded metadata reader, avoiding the
whole-receipt repository lock shared with Google preflight. Post-authorization sources use newest-first order, alternating
with a durable historical source cursor; export/repair fairness remains separate.
Synthetic <=15-second cancelled rounds with 703 historical pending sources prove
one committed export, newest-source priority, and historical progress over cold
restarts despite continuous recent arrivals. Fixed round counts record distinct
progressed sources and first progress phase (0 none, 1 export, 2 strict provider
confirmation), with background attribution and round start/end timestamps. The round sequence
is process-local and counts sync rounds, including foreground rounds; it is never
an OS lease count.
These local-export advances do not assert that iCloud uploaded the source.
Overlapping callers share that six-source and 32-provider-query budget. It
leaves unobserved upload status unknown and never treats exporting as uploading.
Provider-change notifications conservatively fence all prior confirmations until
rechecked. Each cohort has a durable unchecked set and cursor; notifications
received during it coalesce into one successor generation and never restart its
tail. While a successor is pending, prior positives remain historical-only. Each
active-app continuation checks at most 32 paths and yields; a one-second soft
slice also yields after a slow accessor completes. It automatically schedules the
next slice while active, without another notification or user action. Background
execution still requires a real parent lease and shares its existing limits.
Discovery can accept the same pending invalidation inside its sync command,
before export or publication, so a continuous signal stream cannot starve new
sources or late transcripts.

Newly exported paths receive up to eight reserved positions, with historical
paths retaining the rest of the batch. The recent priority set is bounded to 32;
paths not selected for a priority batch join historical rotation. A persisted
class turn also prevents slow fresh accessors from consuming every short slice.
Marker, commit and artifact checks retain exact identity and stable-stat gates.
There is no full-library `lstat` sweep on each continuation. Deletion/replacement
is classified when its path is selected; the unchecked/replay fence prevents an
unobserved historical positive from being published in the meantime.

The durable unchecked set contains only expected paths and shares the existing
100,000-entry / 16 MiB cache limits. Negative replies complete coverage without
claiming upload success. Zero permits, cancellation and target failure preserve
unfinished work; cold restart resumes the cursor. Actual scheduler regressions
cover 61/3001 files from one signal, notification storms, slow accessors, yield,
background cancellation, restart and new/history fairness. Source audio is
removed before metadata-only continuation checks.

Interrupted-export regressions cancel at the real `checkingCloud` phase, after
the export and its provider cache are durable but before metadata cleanup. They
cover new audio and late text with both indexed and legacy ledgers. A legacy
unknown commit index remains unknown; only commits actually in the durable index
enter confirmation timestamps, unchecked paths or priority paths. Cold load must
retain exact historical observations, confirmation times, repair cursor and
unchecked tail, then resume only the unfinished paths. This prevents new invalid
caches; it cannot recover history already discarded by an older broken cache.

Source-warning regressions run the real scheduler with corrupt transcripts or a
changed source manifest/receipt alongside more than 32 healthy exported paths. Source
findings remain durable and visible through metadata-only continuation and cold
load. They do not stop a healthy monitor or suppress healthy file evidence. A
consumed corrupt-transcript notification does not spin discovery indefinitely;
the next real save/discovery opportunity can retry that source. Provider/folder
failure, changed identity, pause and disconnect still stop the remaining tail
and prevent current positive publication. Cold coordinator tests read current
disk metadata without a supplied older snapshot: existing-ID replacements are
isolated while their original grant binding remains unchanged. Exact metadata
restoration clears only the affected finding. Duplicate IDs and malformed
replacements remain blocking failures. A queued provider callback after a
blocking failure retains invalidation but cannot itself start another attempt;
the next authorized retry must recheck the previous positive observations.

Typed observations separate explicit false, missing resource keys, resource
read errors, non-ubiquitous files, invalid files and identity changes. Older Bool
negative caches migrate to unknown, not explicit false; typed negatives override
old Bool positives. First and latest positive confirmation times survive negative
rechecks. Query-start outcomes, notification count and first gather are separate
path-free monitor diagnostics. Neither status export nor monitor diagnostics
start provider work. These tests establish local scheduling/classification logic,
not Apple provider upload latency or device acceptance.

The typed regression also changes a synthetic manifest's ctime inside the
provider callback. Read-only inspection must retain `file_changed_during_check`
and the identity mismatch bits without accepting upload. A single subsequent
normal notification, with another racing ctime change, must drain the existing
automatic repair/metadata continuation without a second provider event. The
source audio is absent, and the existing tampered-audio tests still prohibit
overwriting or confirming changed content. This scenario already passes on the
101 production worker; it is added coverage, not a demonstrated device bug fix.
Historical transcript discovery uses a bounded rotating pass; its completed
coverage survives later rotations and cold startup, while new IDs and read
failures still prevent a false complete result. An identity mismatch remains
unconfirmed and is distinguished from a provider reporting upload pending.
Late transcript notifications prioritize their exact source within the bounded
metadata pass. Notifications remain pending until that source is inspected;
an additional same-source notification during a busy scan is retained separately
from the older completion. This notification queue is process-local: the probe
does not claim that a save followed by arbitrary process termination preserves
the targeted notification. Cold processes continue the persisted fair scan.

An explicit foreground cloud-status inspection also works while saving is
paused. It verifies the retained target and marker and reads at most 32 provider
metadata items, with no discovery, transcript scan, synchronization, export or
audio hash. Repeated paused checks continue the persisted fair metadata cursor.
The production-worker checks remove both the synthetic source and its exported
audio, retain a queued undiscovered source, and require success/failure to leave
the exact grant and stop-intent bytes unchanged. An enabled grant likewise
remains enabled after a failed read-only inspection. Inspection completion never
schedules a follow-up synchronization; it is independent of automatic saving.
The background regression moves all synthetic source audio aside and verifies
both the first late transcript and a second version delivered while provider
metadata is blocked, with the original shared execution limits.
Synthetic coverage also verifies cold background startup without a lease,
incremental continuation, parent expiry during a blocked provider callback,
independent overlapping system and UIKit leases, and recovery in the same worker
after state or stop-intent metadata becomes readable again. A synchronous file
provider call itself cannot be forcibly interrupted; the expired caller returns
and the cancellation gate prevents subsequent provider work or commits.

Cold progress-first exports and identity repairs recheck each selected source's
current manifest and durable receipt before coordination, inside its accessor,
and before recording the export. These bounded metadata reads do not open or
hash source audio. Synthetic regressions change a manifest while retaining its
audio hash, remove a receipt, or replace its hash; each source is isolated while
a healthy peer exports in the same two-job opportunity. The quarantine survives
restart and resumes when matching metadata is restored. A repair also refuses a
withdrawn receipt and later succeeds with the source audio absent. Corrupt
already-pending transcript metadata is inspected once per round, remains an
individual text issue, and allows both source audios to export.

The proof records source hashes before/after and fails if they change. This is
local logic evidence, not proof of real provider identifier stability, iOS
security-scoped bookmark behavior, CloudKit capability, iCloud upload timing,
another device's download, or end-to-end Agent access. Those need a separately
authorized small real-device trial. No simulator/device app is installed.
