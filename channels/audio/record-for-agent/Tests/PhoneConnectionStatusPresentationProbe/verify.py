#!/usr/bin/env python3
"""Compile the production status projections into a local, inert Swift harness."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def main():
    os.umask(0o077)
    run = Path(tempfile.mkdtemp(prefix="record-for-agent-connection-presentation79-"))
    os.chmod(run, 0o700)
    views = [ROOT / "Phone/GoogleDriveLibraryView.swift", ROOT / "Phone/ICloudDriveLibraryView.swift"]
    harness = HERE / "Harness.swift"
    core = ROOT / "Sources/RecordingCore/GoogleDriveLibraryLedger.swift"
    inputs = [*views, core, harness, Path(__file__).resolve()]
    before = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    blocks = []
    for path, provider in zip(views, ["GOOGLE", "ICLOUD"]):
        text = path.read_text()
        begin, end = "// BEGIN " + provider + " CONNECTION PRESENTATION", "// END " + provider + " CONNECTION PRESENTATION"
        if text.count(begin) != 1 or text.count(end) != 1:
            raise RuntimeError("Production presentation boundary is ambiguous")
        blocks.append(text.split(begin, 1)[1].split(end, 1)[0])
    source = harness.read_text()
    marker = "// INSERT PRODUCTION PRESENTATION HERE"
    if source.count(marker) != 1:
        raise RuntimeError("Harness insertion boundary is ambiguous")
    generated = run / "ProductionPresentationProbe.swift"
    core_text = core.read_text()
    reason = core_text[core_text.index("public enum GoogleDriveAPIReason"):
                       core_text.index("public enum GoogleDriveLibraryError")]
    generated.write_text(source.replace(marker, reason + "\n" + "\n".join(blocks)))
    executable = run / "presentation-probe"
    command = ["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(run / "module-cache"), str(generated), "-o", str(executable)]
    build = subprocess.run(command, capture_output=True)
    (run / "build.stdout").write_bytes(build.stdout)
    (run / "build.stderr").write_bytes(build.stderr)
    execution = subprocess.run([str(executable)], capture_output=True) if build.returncode == 0 else None
    if execution:
        (run / "probe.stdout").write_bytes(execution.stdout)
        (run / "probe.stderr").write_bytes(execution.stderr)
    after = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    summary = {"buildExitCode": build.returncode,
               "probeExitCode": execution.returncode if execution else None,
               "sourceStableDuringRun": before == after, "inputSHA256": before,
               "scope": "Production presentation projections with inert stores; no cloud, audio, device, UI or network access",
               "result": json.loads(execution.stdout) if execution and execution.returncode == 0 else None}
    (run / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"summaryPath": str(run / "summary.json"), "buildExitCode": summary["buildExitCode"],
                      "probeExitCode": summary["probeExitCode"], "sourceStableDuringRun": before == after,
                      "result": summary["result"]}))
    if build.returncode:
        print(build.stderr.decode(errors="replace")[-3000:])
    return 0 if build.returncode == 0 and execution and execution.returncode == 0 and before == after else 1


if __name__ == "__main__":
    raise SystemExit(main())
