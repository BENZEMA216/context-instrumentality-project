# Connection status presentation probe

Run `python3 -B Tests/PhoneConnectionStatusPresentationProbe/verify.py` from the repository root.

This compiles the marked status projections directly from the production Google Drive and iCloud Drive views into an inert local Swift harness. It checks status priority, consistent list/detail wording, the distinction between connection and synchronization, preserved error details, disabled-action reasons, and the distinction between locally written files and provider upload confirmation.

The probe does not instantiate the real libraries, access credentials or files, open an app, use a device, or connect to a provider. It does not prove cloud synchronization. The production SwiftUI confirmation flows are covered separately by `Tests/PhoneICloudDriveUIProbe`.

The private temporary result directory contains the exact generated source, compiler output, assertion output, and input hashes. A run fails if its production inputs change while it is executing.
