# Build 97 production UI probe

`python3 Tests/PhoneRedesignUIProbe/verify.py` compiles the production annual Record view, three-step Sync view, native provider forms, secure computer pairing form, and brand asset catalog. A separate simulator-only bundle uses metadata-only, in-memory stores; there is no recording repository, cloud account, WatchConnectivity transport, notification permission, credential store, or audio reader.

Tests cover date entry and period drill-down; conservative archive labels; same-page service switching and re-opening without grant calls; disabled services; destination-specific Agent instructions; explicit directory recovery that stays paused; dark mode and maximum Dynamic Type on iPhone SE. Two additional keyboard cases check both name and secure-payload editing above the software keyboard at normal and maximum Dynamic Type. Real provider execution is verified separately by the production worker probe. The old PhoneAutomaticDeliveryUIProbe retains pre-97 layout selectors and evidence; it is not the acceptance suite for this redesign.

The harness counter values and fixture URLs are synthetic. Passing this suite does not prove device installation, OAuth, cloud upload or full-day archival. Input hashes and xcresult evidence are emitted per run.
