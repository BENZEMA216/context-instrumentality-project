#!/usr/bin/env python3
"""Compile the unchanged production Store background handoff in an offline shell.

Only the MainActor property shell and dependency APIs are synthetic. The tested
performBackgroundSync and discoverBackgroundSources bodies are copied verbatim.
No audio content, filesystem recording catalogue, device or network is accessed.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    os.umask(0o077)
    run = Path(tempfile.mkdtemp(prefix="phone-store-handoff-proof-")).resolve()
    source = ROOT / "Phone/PhoneStore.swift"
    cancellation = ROOT / "Phone/PhoneBackgroundLease.swift"
    inputs = [source, cancellation, HERE / "Harness.swift", Path(__file__).resolve()]
    before = {str(p.relative_to(ROOT)): digest(p) for p in inputs}
    text = source.read_text()
    start, end = "    func performBackgroundSync(", "    func expireBackgroundSync() {"
    if text.count(start) != 1 or text.count(end) != 1:
        raise RuntimeError("Store background handoff boundaries changed; inspect before testing.")
    methods = text[text.index(start):text.index(end)]
    foreground_start, foreground_end = "    func didBecomeActive() {", "    func didEnterBackground() {"
    if text.count(foreground_start) != 1 or text.count(foreground_end) != 1:
        raise RuntimeError("Store foreground observation boundary changed.")
    methods += text[text.index(foreground_start):text.index(foreground_end)]
    if methods.count("private func discoverBackgroundSources(") != 1:
        raise RuntimeError("Expected one actual production metadata discovery helper.")
    lease = cancellation.read_text()
    if lease.count("import UIKit\n") != 1 or lease.count("/// Finite execution time") != 1:
        raise RuntimeError("Production cancellation extraction boundary changed.")
    cancel_text = lease.split("/// Finite execution time", 1)[0].replace("import UIKit\n", "")
    harness = (HERE / "Harness.swift").read_text()
    marker = "// PRODUCTION_STORE_BACKGROUND_METHODS"
    if harness.count(marker) != 1:
        raise RuntimeError("Harness must have exactly one method insertion point.")
    prepared = run / "Probe.swift"
    prepared.write_text(cancel_text + "\n" + harness.replace(marker, methods))
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    commands = [[compiler, "-parse-as-library", "-swift-version", "5", str(prepared),
                 "-module-cache-path", str(run / "module-cache"), "-o", str(run / "probe")],
                [str(run / "probe")]]
    steps = []
    for index, command in enumerate(commands):
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        out, err = run / f"step-{index}.stdout", run / f"step-{index}.stderr"
        out.write_text(result.stdout)
        err.write_text(result.stderr)
        steps.append(dict(exitCode=result.returncode, stdout=str(out), stderr=str(err)))
        if result.returncode:
            break
    after = {str(p.relative_to(ROOT)): digest(p) for p in inputs}
    stable = before == after
    status = "passed" if steps[-1]["exitCode"] == 0 and len(steps) == 2 and stable else "failed"
    evidence = dict(status=status, sourceStableDuringRun=stable, inputSHA256Before=before,
                    inputSHA256After=after, preparedSHA256=digest(prepared), steps=steps,
                    result=(run / "step-1.stdout").read_text().strip() if len(steps) == 2 else None,
                    deviceAccess=False, audioAccess=False, networkAccess=False,
                    scope="Actual Store background orchestration and cancellation; synthetic metadata repository and workers, not real worker, OS scheduling, audio or cloud proof.")
    proof = run / "proof.json"
    proof.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(dict(status=status, sourceStableDuringRun=stable, result=evidence["result"], proof=str(proof))))
    return 0 if status == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
