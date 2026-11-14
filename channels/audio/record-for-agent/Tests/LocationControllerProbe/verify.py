#!/usr/bin/env python3
"""Compile the actual location controller and Core with synthetic dependencies on macOS.

Run with: python3 Tests/LocationControllerProbe/verify.py
All build products, logs, reports, and source hashes remain in a printed temporary
directory. The harness injects its driver, clock, and all four preference closures;
it never constructs the system location driver or reads/writes real UserDefaults.
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
CONTROL = ROOT / "Watch/RecordingLocationManager.swift"


def hashes(paths):
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


def main():
    if sys.platform != "darwin":
        raise SystemExit("This probe needs the macOS SDK, Swift compiler, Combine, and CoreLocation.")
    architecture = platform.machine()
    if architecture not in ("arm64", "x86_64"):
        raise SystemExit("Unsupported host architecture: " + architecture)
    run = Path(tempfile.mkdtemp(prefix="wristrecord-location-controller-probe-")).resolve()
    core_sources = sorted((ROOT / "Sources/RecordingCore").glob("*.swift"))
    if not core_sources:
        raise SystemExit("RecordingCore sources are missing.")
    inputs = [CONTROL, HERE / "Harness.swift", Path(__file__).resolve(), *core_sources]
    before = hashes(inputs)
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    target = ["-target", architecture + "-apple-macosx15.0", "-sdk", sdk, "-swift-version", "5",
              "-module-cache-path", str(run / "module-cache")]
    commands = [
        [compiler, "-emit-module", "-emit-library", "-static", "-parse-as-library", "-module-name", "RecordingCore",
         "-emit-module-path", str(run / "RecordingCore.swiftmodule"), *target, *map(str, core_sources),
         "-o", str(run / "libRecordingCore.a")],
        [compiler, "-parse-as-library", "-module-name", "RecordingLocationSyntheticProbe", "-strict-concurrency=complete",
         *target, "-I", str(run), "-L", str(run), "-lRecordingCore", str(CONTROL), str(HERE / "Harness.swift"),
         "-o", str(run / "probe")],
        [str(run / "probe"), str(run / "report.json")],
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
    evidence = {
        "controller": str(CONTROL), "controllerSHA256": before[str(CONTROL.relative_to(ROOT))],
        "sourceStableDuringRun": stable, "inputSHA256Before": before, "inputSHA256After": after,
        "coreSourceCount": len(core_sources), "commands": commands, "steps": steps,
        "report": str(run / "report.json"),
        "scope": "Actual controller and complete Core; synthetic driver, clock, preference and introduction storage; timers disabled.",
    }
    evidence_path = run / "evidence.json"
    evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")
    report_path = run / "report.json"
    if report_path.exists():
        report = json.loads(report_path.read_text())
    else:
        report = {"status": "build_failed", "caseCount": 0, "assertionCount": 0,
                  "failures": ["See " + steps[-1]["log"]]}
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    status = report["status"] if stable else "source_changed_during_run"
    summary = {"status": status, "caseCount": report["caseCount"], "assertionCount": report["assertionCount"],
               "sourceStableDuringRun": stable, "controllerSHA256": evidence["controllerSHA256"],
               "report": str(report_path), "evidence": str(evidence_path), "steps": steps}
    (run / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if status == "passed" and steps[-1]["exitCode"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
