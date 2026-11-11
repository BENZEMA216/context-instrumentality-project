#!/usr/bin/env python3
"""Run the production Watch integrity mailbox with real Core on synthetic files.

No device, app container, microphone, network, or private recording is accessed.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def main():
    run = Path(tempfile.mkdtemp(prefix="wristrecord-watch-integrity-probe-"))
    core = sorted((ROOT / "Sources/RecordingCore").glob("*.swift"))
    coordinator = ROOT / "Watch/WatchIntegrityAuditCoordinator.swift"
    inputs = [*core, coordinator, HERE / "Harness.swift", Path(__file__).resolve(),
              ROOT / "scripts/verify-recording-integrity.py"]
    before = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    target = ["-target", platform.machine() + "-apple-macosx15.0", "-sdk", sdk,
              "-swift-version", "5", "-module-cache-path", str(run / "module-cache")]
    commands = [
        [compiler, "-emit-module", "-emit-library", "-static", "-parse-as-library", "-module-name", "RecordingCore",
         "-emit-module-path", str(run / "RecordingCore.swiftmodule"), *target, *map(str, core),
         "-o", str(run / "libRecordingCore.a")],
        [compiler, "-parse-as-library", "-module-name", "WatchIntegrityAuditProbe", *target,
         "-I", str(run), "-L", str(run), "-lRecordingCore", str(coordinator), str(HERE / "Harness.swift"),
         "-o", str(run / "probe")],
        [str(run / "probe"), str(run / "report.json"), str(run / "fixtures")],
    ]
    steps = []
    for index, command in enumerate(commands):
        process = subprocess.run(command, capture_output=True, text=True, cwd=run, timeout=180)
        log = run / f"step-{index}.log"
        log.write_text(process.stdout + process.stderr)
        steps.append({"actualExitCode": process.returncode, "log": str(log), "command": command})
        if process.returncode:
            break
    after = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    report = json.loads((run / "report.json").read_text()) if (run / "report.json").exists() else {}
    interop = {"checkedCompleteReports": 0, "failures": []}
    if steps[-1]["actualExitCode"] == 0:
        specification = importlib.util.spec_from_file_location("watch_integrity_host_validator", ROOT / "scripts/verify-recording-integrity.py")
        host = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(host)
        for path in sorted((run / "fixtures").glob("*/WristRecordIntegrity/reports/*.json")):
            value = json.loads(path.read_bytes())
            if value.get("status") != "complete":
                continue
            request = json.loads((path.parent.parent / "requests" / path.name).read_bytes())
            try:
                host.validate_report(value, request, value["appBundleID"])
                interop["checkedCompleteReports"] += 1
            except Exception as error:
                interop["failures"].append({"report": str(path), "error": str(error)})
    evidence = {"sourceStableDuringRun": before == after, "inputSHA256": before, "afterSHA256": after,
                "steps": steps, "report": report, "hostValidatorInterop": interop,
                "scope": "Production Watch mailbox coordinator + actual RecordingCore on synthetic local files; no watchOS scheduling, hardware, installation, microphone, private audio or device readback proof."}
    (run / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    passed = (before == after and steps[-1]["actualExitCode"] == 0 and report.get("status") == "passed"
              and interop["checkedCompleteReports"] > 0 and not interop["failures"])
    print(json.dumps({"status": "passed" if passed else "failed", "caseCount": report.get("caseCount", 0),
                      "assertionCount": report.get("assertionCount", 0), "steps": steps, "hostValidatorInterop": interop,
                      "evidence": str(run / "evidence.json")}, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
