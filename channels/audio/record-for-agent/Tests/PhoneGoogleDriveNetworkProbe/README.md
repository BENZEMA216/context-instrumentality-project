# Google Drive network preference regression

Run `TMPDIR=/tmp python3 Tests/PhoneGoogleDriveNetworkProbe/verify.py`.
If the enclosing sandbox rejects Swift's compiler-plugin nested sandbox, add
`--compiler-plugin-no-sandbox`; this changes only compiler-plugin execution.

The probe compiles the actual HTTP transport, path monitor and exact native
session adapter extracted from production. `URLProtocol` intercepts every
request. The only body is a generated `{}` JSON fixture in a private `/tmp`
directory. Preferences use an in-memory `UserDefaults` substitute. It does not
read audio, use credentials, access devices or send Google/network requests.

The 18 cases cover 12 token/metadata/session/body request-policy combinations,
one same-request recovery snapshot, and four native-policy cases: legacy tasks
prevent session migration while healthy peers still start over Wi-Fi;
completed metadataIncomplete records likewise permit healthy Wi-Fi peers;
fully drained queues migrate; and preference changes preserve submitted request
policy and attempt/session identity. Core permission/path-transition cases are in
`GoogleDriveNetworkPolicyTests`. The additional cancellation interleaving holds
native invalidation, cancels the migration, and proves no policy/rebuild occurs
until a later eligible opportunity; retired-session prepare/create are rejected.

`SessionInterleavingSupport.swift` supplies callback-controlled native lifetimes.
The main `PhoneGoogleDriveProbe` also uses it with the real coordinator to test
`start → migration waiting → handoffForPendingEvents → invalidation callback`,
at both enumeration and invalidation waits. These checks count session factories
and policy writes, and remove the synthetic source before start to reject any
unexpected staging. No delay is treated as proof that an await was reached.

This is local macOS SDK and synthetic adapter evidence. iOS background-daemon
restoration, physical Wi-Fi/cellular switching, UI interaction and real uploads
remain unverified. A legacy native queue keeps its Wi-Fi-only configuration
until tasks and durable records finish; it is never cancelled to apply a new
network preference. New requests in that legacy session retain the Wi-Fi ceiling
even if the user permits cellular, so incomplete metadata does not block healthy
peers on an available non-cellular connection.
