# Native record and sync UI probe

> Build 97 migration: this is the archived pre-97 layout probe. Its fixed home/calendar selectors and doubles target build 96; do not use the commands below as current UI acceptance. Use `Tests/PhoneRedesignUIProbe/verify.py` for the new annual calendar, inline cloud setup and secure computer pairing, plus `Tests/PhoneICloudDriveUIProbe/verify.py` for standalone provider confirmations. Prior status-query evidence remains historical; this release does not claim those legacy cases were rerun.

This separate simulator app compiles the production `Phone/PhoneViews.swift`,
`Phone/AutomaticDeliveryView.swift` and `Phone/RecordDesign.swift` directly.
It links the real `RecordingCore` package, including `RecordingActivity`.
The production `RecordingReminderView` declaration is extracted verbatim into
a temporary Swift file; its production notification store is excluded.

The DESIGN13 Sync-home checks compile the real home, connection catalog,
receiver details and shared connection-row layout. Their Google Drive and
iCloud Drive rows are synthetic stand-ins with fixed state, so these home
checks establish navigation and layout only. The separate
`Tests/PhoneICloudDriveUIProbe` compiles the actual two cloud View files and
checks their scope, pause, recovery and disconnect actions with in-memory
stores. Neither probe authenticates a provider or accesses a real cloud.

Every store in `HarnessApp.swift` is an in-memory synthetic double. The fixture
contains metadata for 137 segments, three recording periods, receipt-confirmed
segment IDs and zero, one or two independent receiver workers. It creates no
audio files, repositories, credentials, Keychain state, WatchConnectivity,
network services, draft files or notification requests. An explicit reminder
toggle changes only the synthetic reminder store. A pairing submission and
receiver removal change only in-memory test state.

Pairing uses a synthetic JSON decoder and non-authenticating fixture tokens.
The edit-preservation check proves that the real view receives complete JSON;
production credential validation is covered by the separate multi-receiver probe.

Run from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 Tests/PhoneAutomaticDeliveryUIProbe/verify.py --build-only
```

`--build-only` builds the separate app and test bundle without installing or
launching them. For native UI tests, the default is the dedicated **Record for
Agent UI Probe** simulator using iPhone SE (3rd generation) and iOS 26.4.
An existing available simulator can be selected explicitly:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 Tests/PhoneAutomaticDeliveryUIProbe/verify.py \
  --simulator F97DA2B9-7ECA-44E1-A365-D207E896A8A3
```

The runner rejects identifiers that are not available simulators, never erases
a simulator, and never invokes physical-device tools. The separate probe bundle
is the only app installed. The app and test runner use local ad-hoc signatures
(`CODE_SIGN_IDENTITY=-`); no developer account or physical-device signing is used.
Explicit signing also refreshes resource seals when reusing build products.
`--derived-data <prior-run>/DerivedData` reuses a prior
compilation cache. Repeat `--only-test` for a focused run, for example the initial
native screenshot and state-semantics set:

```sh
python3 Tests/PhoneAutomaticDeliveryUIProbe/verify.py \
  --simulator F97DA2B9-7ECA-44E1-A365-D207E896A8A3 \
  --only-test AutomaticDeliveryUIProbeTests/ProbeUITests/testRecordEmptyScreenshot \
  --only-test AutomaticDeliveryUIProbeTests/ProbeUITests/testRecordLibraryReadFailureScreenshot \
  --only-test AutomaticDeliveryUIProbeTests/ProbeUITests/testRecordPopulatedAndCalendarScreenshot \
  --only-test AutomaticDeliveryUIProbeTests/ProbeUITests/testRecordStaleScreenshot \
  --only-test AutomaticDeliveryUIProbeTests/ProbeUITests/testCloudSyncHomeShowsConnectionsWithoutTotals \
  --only-test AutomaticDeliveryUIProbeTests/ProbeUITests/testRecordAndSyncDarkAccessibilityScreenshots
```

The record-home and status-sheet regression set uses the actual production
views with independently scheduled request acknowledgements and watch reports:

- `testRecordUnknownAndStaleEmptyDoNotInventZeroDuration` covers absent and
  stale snapshots with no saved segments, unknown calendar status, and absent
  history when no report exists.
- `testRecordFreshRecordingWaitsForFirstSavedSegment` preserves the recording
  state while waiting for the first saved segment; no zero-duration summary is
  invented.
- `testRecordCalendarSelectionControlsOnlySelectedDayPeriods` checks collapsed
  periods, date-specific empty/populated results, the return-to-today action,
  the nine-week rolling window with today at the right, and absent future dates.
- `testRecordCrossDayPeriodRangeMatchesSelectionInListAndDetail` keeps one
  synthetic session across midnight and verifies that the list and detail use
  the selected local day's range, while audio duration excludes paused gaps.
- `testRecordStatusFreshFailuresAndStaleFailuresStayDistinct` distinguishes
  current pause/interruption/failure guidance from an outdated failure report.
- `testRecordStatusRefreshAcceptsNewReportButNotEarlyACK` and
  `testRecordStatusRefreshRejectsNewerButStillStaleReport` require a newer,
  reachable, fresh report before a refresh succeeds.
- `testRecordStatusRefreshTimeoutPreservesSavedAudioAndCaptureState` covers
  no-response requests, including a fresh baseline that must not
  satisfy its own refresh.
- `testRecordStatusUnsupportedWatchAndMissingReportAreExplicitFailures`
  checks unsupported old Watch, absent-report and stale-report outcomes.
- `testRecordHomePullRefreshWaitsForReportAndShowsResult` pulls the production
  home scroll view and checks success feedback and the completed async-wait
  trace, with no query cancellation. XCTest waits for native refresh animation
  quiescence; the trace and saved UI recording retain the waiting phase.
- `testRecordHomePullRefreshShowsFailuresWithoutChangingSavedState` checks
  visible unsupported-Watch and timeout feedback while saved duration and the
  previously known recording state stay unchanged.
- `testRecordHomeLeavingPageCancelsOwnedRefresh` uses a synthetic timed native
  tab transition while refresh is busy to exercise the production page's
  disappearance. It checks owned-query cancellation and a later independent
  query; this is not evidence of a user tab tap during the waiting phase.
- `testRecordStatusCloseReopenCancelsPreviousRefreshTimeout` dismisses an
  in-flight request and verifies its old deadline cannot end a new request.
- `testRecordStatusSwipeDismissCancelsRequestBeforeReopening` uses a native
  simulator touch drag on the sheet heading, then checks cancellation and a
  new query independently of the dismissed query's deadline. This is simulator
  gesture evidence, not a claim about iPhone Mirroring mouse gestures.
- `testRecordStatusUnrelatedLateReportCannotSatisfyTimedOutQuery` observes
  a query timeout and then an unrelated fresh report. The report may update
  current state, but cannot change the completed query into a success.

For example, run the timeout, late-report and presentation-lifecycle checks:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 Tests/PhoneAutomaticDeliveryUIProbe/verify.py \
  --simulator F97DA2B9-7ECA-44E1-A365-D207E896A8A3 \
  --only-test AutomaticDeliveryUIProbeTests/ProbeUITests/testRecordStatusRefreshTimeoutPreservesSavedAudioAndCaptureState \
  --only-test AutomaticDeliveryUIProbeTests/ProbeUITests/testRecordStatusUnrelatedLateReportCannotSatisfyTimedOutQuery \
  --only-test AutomaticDeliveryUIProbeTests/ProbeUITests/testRecordStatusCloseReopenCancelsPreviousRefreshTimeout
```

The screenshot set hides the probe control strip and uses the actual production
TabView and NavigationStack. Attachments include:

- `v4-record-empty-light`, `v4-record-library-read-failure-light`, `v4-record-populated-light`,
  `v4-record-calendar-and-periods-light`, `record-periods-above-bottom-navigation`,
  `record-stale-dark`, `record-status-collapsed-dark`, `record-status-history-dark`.
- `v4-sync-0-receivers-light`, `v4-sync-1-receivers-light`,
  `v4-sync-2-receivers-light`.
- `v4-record-populated-dark-ax5`, `v4-record-calendar-dark-ax5`,
  `v4-sync-two-receivers-dark-ax5`.

Interaction tests additionally cover the following production UI paths:

- Prepare/send/receipt churn preserves card and pairing-field frames.
- Pause/resume, management details and connection information; disconnect
  cancellation, failure, and successful removal of only the selected receiver.
- Draft review requires explicit full-library consent, secure payload text is
  absent from the accessibility tree, and typing disables draft replacement.
- Typed name and secure payload survive background fixture updates. The secure
  field is blurred with Done, focused again and given the final JSON suffix; the
  real view must recognize the resulting valid fixture. The name stays exact,
  the accessibility tree stays masked, and screenshots capture both stages.
- A first library read failure shows unknown duration and explicit failure copy,
  without a perpetual loading label or unconfirmed recording statistics.
- Reminder controls, reached through Settings, render and update only synthetic
  settings.
- REC-35 connection management separates saved pairing, a dated read-only
  connection check and the latest transfer result. Synthetic timeout and
  successful-check/failed-transfer states verify visible recovery guidance,
  separate timestamps and an explicit check button that does not send audio.
  Production worker and HTTP-client behavior are verified by
  `Tests/PhoneMultiReceiverProbe`, not these in-memory UI doubles.
- Both pairing fields remain completely below the navigation bar and at least
  4 pt above the real software keyboard and its prediction/Passwords strip,
  at normal size and maximum accessibility text size in dark mode. Each field
  opens its own keyboard from a fresh launch, with no repair scroll after focus.

Fixture launch environment variables are internal to the isolated harness:
`PROBE_RECEIVERS=0|1|2`,
`PROBE_RECORD_STATE=empty|recorded|stale|unknown|unknown-saved|stale-empty|recording-empty|paused|interrupted|failed|stale-interrupted|cross-day-period`,
`PROBE_CLOUDS=0` (hide both synthetic cloud connections),
`PROBE_LIBRARY_FAILED=1`, `PROBE_CONTROLS=0`, `PROBE_LARGE_TYPE=1`,
`PROBE_DARK=1`, `PROBE_DRAFT=1`,
and `PROBE_FAIL_REMOVAL=1`. They do not affect the production app.
`PROBE_RECEIVER_HEALTH=timeout|reachable-transfer-failed` selects the REC-35
metadata-only connection fixtures; when omitted, current reachability remains
unknown in the synthetic store.

`PROBE_RECORD_STATE` defaults to `recorded`. `empty`, `unknown`, `stale-empty`
and `recording-empty` have no segment metadata. `cross-day-period` has two
synthetic metadata entries in one session: yesterday at 09:00–09:20 and a
23:58–00:02 segment crossing into today. Other states have the same 137
synthetic saved segments. `unknown` and `unknown-saved` omit the watch snapshot.
States beginning with `stale` use a report timestamp ten minutes in the past.

`PROBE_SYNC_RESPONSE` controls the synthetic status-only `requestStatus()`
schedule. This environment name remains for existing test selectors; the
production refresh action does not call `requestSync()`:

| Value | Synthetic events after the request |
| --- | --- |
| `report` (default) | Correlated fresh paused report at 0.25 seconds. |
| `unreachable-then-recovery` | Initial unavailable failure at 0.25 seconds; ten seconds later one automatic attempt for the same logical intent uses a fresh generation and succeeds 0.25 seconds later. Cancelling the owner revokes the scheduled attempt. |
| `ack-then-report` | An early event does not complete the query; correlated fresh paused report at 4 seconds. |
| `delayed-report` | Correlated fresh paused report at 6.5 seconds, retaining the pending phase in diagnostic UI recordings. |
| `unsupported` / `ack-only` | Unsupported old Watch outcome at 0.25 seconds; no fallback to sync. |
| `no-report` / `stale-report` | Explicit absent/stale-report failure at 0.25 seconds. |
| `no-response` | No report; terminal timeout at 8 seconds. |
| `newer-stale-then-report` | Unrelated report one second newer than the stale baseline at 0.25 seconds; correlated fresh paused report at 4 seconds. |
| `late-report` | Terminal timeout at 8 seconds; unrelated fresh paused report at 10 seconds does not satisfy the query. |

The production status sheet displays Store-owned pending, success and error state.
A correlated automatic success therefore clears the initial unavailable error
without another tap. Dismissal cancels only the sheet's own logical query intent,
including an armed terminal failure; an unrelated home-page owner is preserved.
The synthetic `waitForStatusRequest(intentID:)` and `requestStatusAndWait()`
follow the production intent and attempt-generation lifetime. The home page owns
its async query independently of cancellation of SwiftUI's refresh action and
revokes its own intent when the page disappears, even after the first attempt ends.
Actual production Connectivity/Store recovery and read-only boundaries are
covered separately by `PhoneBackgroundSyncProbe --case-prefix status_recovery_`;
these UI fixtures establish presentation behavior, not real connection recovery.
`PROBE_STATUS_TRACE=1` exposes synthetic request, wait, completion and
cancellation counters. `PROBE_LEAVE_HOME_DURING_STATUS=1` performs one timed
native tab transition to exercise disappearance while XCTest is waiting for
native refresh animation quiescence. Neither switch exists in the production app.
Synthetic reports change only connection state and the report timestamp; they never add
segments, receipts or audio duration. These fixtures perform no network or
watch communication and write no audio files.

Each run writes its generated project, build/test log, `.xcresult` bundle and
`summary.json` to the printed temporary directory. Screenshots, final
accessibility trees, frame deltas and keyboard measurements are attachments in
the result bundle. The summary compares input SHA-256 hashes before and after
the run, including all production view files, reminder source and activity
calculation source. A changing source file makes the run fail even if XCTest
passes.

Passing tests establish the actual SwiftUI view behavior with these synthetic
fixtures on the selected simulator. They do not establish real delivery,
recording, notification authorization/scheduling, physical-device behavior,
background transport, queue recovery or end-to-end receipt correctness.
