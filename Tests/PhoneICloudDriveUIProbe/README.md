# Native cloud connection UI probe

This independent simulator app compiles the production
`Phone/GoogleDriveLibraryView.swift`, `Phone/ICloudDriveLibraryView.swift` and
`Phone/RecordDesign.swift` unchanged, linked to the real `RecordingCore` package.
It puts the real DESIGN13 connection rows in a native `List`, then opens their
actual detail sheets. Only the two library stores are replaced by in-memory
`ObservableObject` fixtures that count actions and expose synthetic state.

There are no recordings, repositories, bookmarks, credentials, providers,
network requests or audio files. No physical-device command is used. The real
folder picker is compiled but never presented by these tests.

```sh
python3 -B Tests/PhoneICloudDriveUIProbe/verify.py --build-only
python3 -B Tests/PhoneICloudDriveUIProbe/verify.py
```

The default is the dedicated **Record for Agent iCloud Drive UI Probe** simulator.
`--simulator` accepts only an available simulator UUID. Only the separate probe
app and test runner are installed with local ad-hoc signing; nothing is erased.
`--derived-data` may reuse its build cache; repeat `--only-test` to select focused
methods. Source hashes before and after execution must agree.

The scenarios exercise the production controls:

- Opening paused rows shows details without resuming or changing either grant.
- An explicit toggle continues only the retained scope.
- Completed rows and details hide recording/file counts and pending notices.
- Unfinished work has a notice and an explanatory status alert.
- iCloud check calls only resume, without opening disconnect confirmation.
- Cancelling either provider's disconnect preserves scope and enabled state;
  one subsequent iCloud check still works.
- Google needs an explicit scope selection followed by an explicit enable tap;
  selecting scope alone does not authorize it.
- Cancelling the iCloud scope dialog leaves the grant unchosen; selecting a
  scope explicitly authorizes it.
- Only confirming iCloud disconnect changes its connection state.
- Cancelling either provider's resume alert leaves both existing grants paused
  and performs no upload/resume call. The standard alert keeps Cancel visible
  on a small screen instead of relying on an outside-popover tap.
- Original-account Google reconnect and original-directory iCloud reselection
  also use standard alerts with a directly visible, hittable Cancel button.
  Focused cases tap that actual button, require the existing detail controls
  and modal-layer count to return, and verify zero authentication, directory
  connection, authorization or upload calls with both grants unchanged.
- Directory identity recovery has a separate, visible native confirmation.
  Confirming invokes recovery once and leaves saving paused; Cancel discards
  the pending candidate without enabling saving or changing the grant. These
  two UI cases use in-memory candidates; the real worker probe separately
  verifies marker, directory identity, persistence and time-of-check changes.
- Revocation-pending, missing revocation credentials and a mismatched iCloud
  directory show the actual blocker and available recovery without silently
  reconnecting, resuming, replacing the directory or expanding scope.

The cancellation helper waits for the dialog action and native confirmation
sheet to disappear and for the dismissal-region count to return to the baseline
observed immediately before presenting the confirmation, after any scrolling.
Scrolling can expand the sheet and change these system layers. The underlying
detail presentation retains its own
`PopoverDismissRegion` nodes, so requiring zero would be incorrect. Exit state
and baseline are attached. It does not retry a subsequent check tap to hide
missed actions. Toggle tests tap the actual inner native Switch once, then check
its value and exact call counts; the broad SwiftUI wrapper includes an inert
label area. Native confirmation queries use their first matching node because
the system may expose nested buttons for one action. Fixtures expose call
counters only at home, read after dismissing the detail sheet.

Each run saves its complete log, command, source SHA-256 map, `.xcresult`, test
counts and summary to a new private temporary directory. Screenshots and
accessibility trees contain only the synthetic app and are exported under
`attachments/`. The runner prints only a compact final result. This verifies
native SwiftUI behavior on the selected simulator, not cloud transfer,
production grant persistence, real devices or installation of a release.

## Preserved pre-DESIGN13 regression evidence

The previous single-List-row card regression remains in its original private
artifacts. These are historical results for a different layout, not results from
the current nine tests:

- `/var/folders/jx/2fl_kv0d25zglzk1cgq8db2c0000gn/T/wristrecord-icloud-drive-ui-probe-w1fqp0nk/summary.json`:
  first full run, two passed and one locator failure.
- `/var/folders/jx/2fl_kv0d25zglzk1cgq8db2c0000gn/T/wristrecord-icloud-drive-ui-probe-c9nrs34c/summary.json`:
  second full run, two passed and one cancellation/follow-up timing failure.
- `/var/folders/jx/2fl_kv0d25zglzk1cgq8db2c0000gn/T/wristrecord-icloud-drive-ui-probe-1s38hx9v/summary.json`:
  private snapshot with only the two borderless styles removed; the same check
  isolation test failed precisely because disconnect confirmation appeared.
- `/var/folders/jx/2fl_kv0d25zglzk1cgq8db2c0000gn/T/wristrecord-icloud-drive-ui-probe-olg692su/evidence-summary.json`:
  one focused cancellation test passed after waiting for system overlays to exit;
  the two original full-run failures remain recorded. No final full 3/3 run was
  claimed.

Those snapshots bind production iCloud View SHA-256
`b48fbaad09d7b7643d1b7b9573fcf1918c2d1a72f7188da25cf81ae105dcf150`.
The negative was a reconstruction of former automatic-button behavior, not a
byte-identical build 44. It never modified production source. The current
`--reconstruct-automatic-buttons` option rejects execution because moving the
buttons into a detail ScrollView changes the premise of that negative control.

## DESIGN13 recorded result

Production inputs were unchanged across these simulator test runs:

| Run suffix | Actual result | Scope |
| --- | --- | --- |
| `eqj4konp` | 6 passed, 3 failed | Full nine scenarios; cancellation helper waited for the wrong system layers, and a broad Switch wrapper tap missed its inner control. |
| `vd3tlc8q` | 2 passed, 1 failed | Focused three; native toggle and iCloud scope cancellation passed, while the remaining case missed its initial detail presentation. |
| `kgva3vkd` | 0 passed, 1 failed | Focused cancellation; Google passed, but scrolling iCloud to large detent invalidated a baseline recorded before scrolling. |
| `l0xhtnrz` | 1 passed, 0 failed | Final cancellation case after recording the baseline after scrolling; exact grants/calls and one follow-up check passed. |

All nine scenarios have passing evidence for the same three production input
hashes. The latest test source was not rerun as a full suite, and no single-run
9/9 claim is made. The one missed initial row presentation remains in the raw
history; its root cause was not established. The final helper taps the visible
provider title once, inside the real Button, instead of its broad AX wrapper's
center. No action retry was added.

Private aggregate:
`/var/folders/jx/2fl_kv0d25zglzk1cgq8db2c0000gn/T/wristrecord-cloud-drive-ui-probe-l0xhtnrz/evidence-summary.json`.
Its screenshot index links exported synthetic screenshots and text attachments.
The earlier `1c0dadb4` run was a compiler failure before tests, fixed by adding
main-actor isolation to the production status initializers; it is retained and
excluded from the same-input scenario aggregation. `_4flcmyv` was cancelled
before test execution to avoid sharing a simulator with the home-page probe.
