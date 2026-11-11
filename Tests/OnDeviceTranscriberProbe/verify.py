#!/usr/bin/env python3
"""Compile actual production transcription coordination; run synthetic closures only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def private_write(path, data):
    path.write_bytes(data)
    path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reuse-core-build", required=True, type=Path)
    parser.add_argument("--transcriber-source", type=Path, default=ROOT / "Phone/OnDeviceTranscriber.swift")
    parser.add_argument("--build-helper", action="store_true", help="Compile the real helper into the private output only; never run it.")
    parser.add_argument("--output-parent", type=Path)
    options = parser.parse_args()
    run = Path(tempfile.mkdtemp(prefix="wristrecord-transcriber-probe-", dir=options.output_parent)).resolve()
    run.chmod(0o700)
    core = sorted((ROOT / "Sources/RecordingCore").glob("*.swift"))
    core_build = options.reuse_core_build.resolve()
    expected = json.loads((core_build / "evidence.json").read_text())["inputSHA256After"]
    if not all(expected.get(str(p.relative_to(ROOT))) == sha(p) for p in core):
        raise SystemExit("RecordingCore sources differ from evidenced reusable module.")
    artifacts = [core_build / "RecordingCore.swiftmodule", core_build / "libRecordingCore.a"]
    if not all(p.is_file() for p in artifacts):
        raise SystemExit("Missing evidenced reusable Core module or library.")
    inputs = [options.transcriber_source, HERE / "Harness.swift", HERE / "verify.py", ROOT / "Tools/TranscribeOnDevice.swift", *core]
    before = {str(p): sha(p) for p in inputs}
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    target = ["-target", platform.machine() + "-apple-macosx15.0", "-sdk", sdk, "-swift-version", "5",
              "-strict-concurrency=complete", "-warnings-as-errors", "-module-cache-path", str(run / "module-cache"),
              "-I", str(core_build), "-L", str(core_build), "-lRecordingCore"]
    commands = [[compiler, "-parse-as-library", "-module-name", "OnDeviceTranscriberProbe", *target,
                 str(options.transcriber_source), str(HERE / "Harness.swift"), "-o", str(run / "probe")],
                [str(run / "probe")]]
    if options.build_helper:
        commands.append([compiler, "-parse-as-library", "-module-name", "WristRecordTranscribe", *target,
                         str(options.transcriber_source), str(ROOT / "Tools/TranscribeOnDevice.swift"),
                         "-o", str(run / "transcribe-on-device")])
    steps = []
    deadline = time.monotonic() + 60
    report = {"status": "not_run"}
    for index, command in enumerate(commands):
        try:
            process = subprocess.run(command, capture_output=True, timeout=max(1, deadline - time.monotonic()))
            private_write(run / ("step-%d.stdout" % index), process.stdout)
            private_write(run / ("step-%d.stderr" % index), process.stderr)
            steps.append({"index": index, "exitCode": process.returncode})
            if index == 1:
                report = json.loads(process.stdout)
            if process.returncode:
                break
        except subprocess.TimeoutExpired:
            steps.append({"index": index, "category": "timeout"})
            report = {"status": "timeout"}
            break
    after = {str(p): sha(p) for p in inputs}
    evidence = {"scope": "actual_production_coordinator_no_source_transformations_synthetic_closures_only",
                "inputSHA256Before": before, "inputSHA256After": after,
                "sourceStable": before == after, "commands": commands, "steps": steps, "report": report,
                "reusedCoreArtifactSHA256": {str(p): sha(p) for p in artifacts},
                "builtArtifactSHA256": {p.name: sha(p) for p in [run / "probe", run / "transcribe-on-device"] if p.exists()},
                "helperExecuted": False, "audioOrModelsUsed": False}
    private_write(run / "evidence.json", (json.dumps(evidence, indent=2) + "\n").encode())
    summary = {key: value for key, value in report.items() if key != "failures"}
    summary["failureCount"] = len(report.get("failures", []))
    print(json.dumps({"evidence": str(run / "evidence.json"), "sourceStable": before == after,
                      "steps": steps, "report": summary}, indent=2))
    return 0 if report.get("status") == "passed" and before == after and all(s.get("exitCode") == 0 for s in steps) else 1


if __name__ == "__main__":
    raise SystemExit(main())
