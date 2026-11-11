#!/usr/bin/env python3
"""Exercise production UIKit assertion owners with controlled nonisolated APIs."""
from pathlib import Path
import hashlib, json, os, subprocess, tempfile
os.umask(0o077)
here = Path(__file__).resolve().parent
root = here.parents[1]
source = root / "Phone/PhoneBackgroundLease.swift"
raw = source.read_bytes()
text = raw.decode()
marker = "final class PhoneIncomingCallbackLease:"
assert text.count(marker) == 1
run = Path(tempfile.mkdtemp(prefix="phone-incoming-callback-lease-"))
prepared = run / "Production.swift"
prepared.write_text(text.replace("import UIKit\n", ""))
compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
commands = [[compiler, "-parse-as-library", "-swift-version", "5", str(prepared), str(here / "Harness.swift"), "-module-cache-path", str(run / "mc"), "-o", str(run / "probe")], [str(run / "probe")]]
steps = []
for i, args in enumerate(commands):
    r = subprocess.run(args, capture_output=True, text=True, timeout=90)
    (run / f"step-{i}.stdout").write_text(r.stdout)
    (run / f"step-{i}.stderr").write_text(r.stderr)
    steps.append({"exitCode": r.returncode})
    if r.returncode: break
stable = raw == source.read_bytes()
result = {"status": "passed" if len(steps) == 2 and steps[-1]["exitCode"] == 0 and stable else "failed", "sourceSHA256": hashlib.sha256(raw).hexdigest(), "sourceStable": stable, "steps": steps, "deviceAudioNetworkAccess": False, "scope": "Production assertion lifetime with synthetic UIKit; not OS scheduling proof"}
(run / "evidence.json").write_text(json.dumps(result, indent=2))
print(json.dumps(dict(result, evidence=str(run / "evidence.json"))))
raise SystemExit(0 if result["status"] == "passed" else 1)
