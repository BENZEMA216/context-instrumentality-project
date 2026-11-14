# Drive revoke / cold-launch stop intent regression

The OS path monitor is also an inert adapter, so the current production Library
can initialize without observing the Mac's real network. This probe verifies
revocation transactions; request/path policy is tested separately by
`PhoneGoogleDriveNetworkProbe`.

This offline macOS probe compiles the entire production `GoogleDriveLibrary.swift`, including its actual initializer, revoke/reauthorization methods, schedule admission and atomic metadata writer. Only the UIKit import is removed; inert opportunity notifications, OS scheduling and an injected OAuth storage/browser replace device services. URLProtocol accepts only a synthetic account response, and rejects every other request. It never reads the real Keychain, sends Google traffic, accesses devices, or creates/reads recording content.

```sh
python3 Tests/PhoneGoogleDriveRevocationProbe/verify.py
```

`--reuse-core-build` may reference the original successful PhoneGoogleDriveProbe Core build only when every Core source hash and compiler/SDK/target/flags match. The complete Phone Library is always recompiled. Run output includes the exact command, source hashes, Core provenance, private synthetic JSON and test report.

The key regression injects a failure after a temporary ledger has been written and synchronized but immediately before its rename. It checks that the old enabled ledger is unchanged, no credential or remote revoke is touched, and a newly constructed Library still denies resume, continue, a genuine background opportunity and token refresh. Other cases cover stop-fence write failure, explicit retry, same-account reauthorization, failed credential/final-ledger commit and invalid stop metadata.

The negative control removes only the independent stop-intent write from a private compiled Library copy:

```sh
python3 Tests/PhoneGoogleDriveRevocationProbe/verify.py --without-stop-fence-control --case-filter 'first ledger rename fails'
```

It must fail on cold-launch admission. Production source is not modified by the negative control. A fence-write failure is reported honestly as an unsaved stop: this process denies access, but no software can promise a cross-process stop when all durable writes fail. Explicit same-account reauthorization removes a valid stop intent only after the replacement credential and the paused ledger have both committed; it never automatically resumes uploads.
