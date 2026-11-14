# On-device transcription task regression

This probe compiles `Phone/OnDeviceTranscriber.swift` directly and calls the same
`collectAnalyzerResults` function used by its real Speech producer and consumer.
It does not construct a Speech analyzer, read audio, install models, or access a
device, account, recording library, or database.

Controlled cleanup suspends after cancelling the peer, exposing the error race.
The cases preserve a consumer `invalidSpan` (including its index), a producer
`noSpeech`, and a framework error (including its code). They also cover a backend
cancellation arriving before its real error, explicit parent cancellation, and
both successful streams completing without cleanup. Each runs twenty times.

Run while other Swift builds are idle:

```sh
python3 Tests/OnDeviceTranscriberProbe/verify.py --reuse-core-build /absolute/path/to/evidenced/core/build --build-helper
```

The Core source hashes must match the reusable build. The real production file
is compiled without transformations. `--build-helper` compiles the actual Mac
CLI into the new private output directory and never executes it. This proves
coordination and compilation, not Apple model behavior or a private recording's
recognition result. A real source still requires separately authorized testing.

The same production range validator is exercised at an exact frame end, one
frame beyond it, a negative start and a nonfinite SDK range. Rejected SDK ranges
carry a fixed numeric diagnostic whitelist (exact CMTime rationals, finite
seconds and source frame metadata), preserving strict transcript bounds and
never carrying recognized text.

An exact rational endpoint regression covers the real 819200/48000 source end
reported by Speech on a 16000-unit grid as 273067/16000. Only the exact nearest
grid endpoint, with a positive remainder no larger than half one SDK grid unit,
may map back to source duration. Integer overflow fails closed. A 48 kHz endpoint
one frame beyond its exact source end, the next 16 kHz grid point, negative or
nonfinite ranges and a start beyond the normalized end remain rejected. The
normalized span must pass the unmodified Core transcript validator.
