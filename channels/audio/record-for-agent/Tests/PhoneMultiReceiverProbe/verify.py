#!/usr/bin/env python3
"""Exercise the actual Phone multi-receiver stores with isolated synthetic dependencies.

The actual credential migration, coordinator, per-receiver store, archive builder,
and complete RecordingCore are compiled without source rewriting. The harness uses
an in-memory Keychain byte backend and controlled transports instead of real
Security operations or URLSessions. UIKit background callbacks are a test-only
adapter; network monitoring, retry timers, and background registration are disabled.
All input fixtures and build products remain in a printed temporary directory.
"""

import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def hashes(paths):
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


def main():
    if sys.platform != "darwin":
        raise SystemExit("This probe requires the macOS SDK, Swift, Combine, Network, and Security frameworks.")
    architecture = platform.machine()
    if architecture not in ("arm64", "x86_64"):
        raise SystemExit("Unsupported host architecture: " + architecture)
    run = Path(tempfile.mkdtemp(prefix="wristrecord-phone-multi-receiver-probe-")).resolve()
    core_sources = sorted((ROOT / "Sources/RecordingCore").glob("*.swift"))
    phone_sources = [ROOT / "Phone" / name for name in (
        "BackgroundSessionRestorationGate.swift", "AutomaticReceiverClient.swift", "AutomaticReceiverHealthClient.swift", "AutomaticDeliveryArchiveBuilder.swift",
        "AutomaticReceiverTranscriptClient.swift", "AutomaticReceiverTranscriptBackground.swift", "PhoneReceiverTranscriptReturn.swift",
        "PhoneReceiverDeliveryStore.swift", "PhoneAutomaticDeliveryStore.swift",
    )]
    harness_sources = [HERE / "Harness.swift", HERE / "TranscriptReturnCases.swift", HERE / "RestorationGateCases.swift",
                       HERE / "ArchiveColdRestoreCases.swift", HERE / "HealthCases.swift", HERE / "HealthClientCases.swift"]
    fixture_inputs = sorted([*(HERE / "Fixtures").glob("*.json"), *(HERE / "Fixtures").glob("*.der")])
    inputs = [*phone_sources, *harness_sources, *fixture_inputs, Path(__file__).resolve(), *core_sources]
    before = hashes(inputs)
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    target = ["-target", architecture + "-apple-macosx15.0", "-sdk", sdk, "-swift-version", "5",
              "-module-cache-path", str(run / "module-cache")]
    commands = [
        [compiler, "-emit-module", "-emit-library", "-static", "-parse-as-library", "-module-name", "RecordingCore",
         "-emit-module-path", str(run / "RecordingCore.swiftmodule"), *target, *map(str, core_sources),
         "-o", str(run / "libRecordingCore.a")],
        [compiler, "-parse-as-library", "-module-name", "PhoneMultiReceiverSyntheticProbe", "-strict-concurrency=complete",
         *target, "-I", str(run), "-L", str(run), "-lRecordingCore", *map(str, phone_sources),
         *map(str, harness_sources), "-o", str(run / "probe")],
        [str(run / "probe"), str(run / "report.json"), str(run / "fixtures")],
    ]
    steps = []
    for index, command in enumerate(commands):
        process = subprocess.run(command, capture_output=True, text=True, cwd=run)
        log = run / ("step-%d.log" % index)
        log.write_text(process.stdout + process.stderr)
        steps.append({"index": index, "exitCode": process.returncode, "log": str(log)})
        if process.returncode:
            break
    after = hashes(inputs)
    stable = before == after
    report_path = run / "report.json"
    if report_path.exists():
        report = json.loads(report_path.read_text())
    else:
        report = {"status": "build_failed", "caseCount": 0, "assertionCount": 0,
                  "failures": ["See " + steps[-1]["log"]]}
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    evidence = {
        "sourceStableDuringRun": stable, "inputSHA256Before": before, "inputSHA256After": after,
        "coreSourceCount": len(core_sources), "phoneSources": [str(p.relative_to(ROOT)) for p in phone_sources],
        "commands": commands, "steps": steps, "report": str(report_path),
        "scope": "Actual Phone coordinator, worker, credential migration, archive builder and complete Core; synthetic Keychain bytes and transports; no real network, recordings or chats.",
    }
    evidence_path = run / "evidence.json"
    evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")
    status = report["status"] if stable else "source_changed_during_run"
    summary = {"status": status, "caseCount": report["caseCount"], "assertionCount": report["assertionCount"],
               "sourceStableDuringRun": stable, "report": str(report_path), "evidence": str(evidence_path), "steps": steps}
    (run / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if status == "passed" and steps[-1]["exitCode"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
