#!/usr/bin/env python3
"""Package an allowlisted bridge distribution, never recordings, accounts or pairing keys."""

import argparse
import hashlib
import json
from pathlib import Path
import stat
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE_ROOT = "RecordForAgent-AgentBridge"
FILES = (
    "AgentBridge/bridge.py", "AgentBridge/library.py", "AgentBridge/automatic.py",
    "AgentBridge/automatic_transcription.py", "AgentBridge/delivery_clients.py",
    "AgentBridge/setup_receiver.py", "AgentBridge/README.md",
    "AgentBridge/icloud_drive_library.py", "AgentBridge/phone_drive_mcp_server.py",
    "AgentBridge/drive_mcp_server.py", "AgentBridge/drive_sync.py",
    "AgentBridge/examples/agent-onboarding.txt", "AgentBridge/examples/codex.toml",
    "AgentBridge/examples/workbuddy.json", "docs/agent-onboarding.md", "docs/automatic-delivery.md",
    "scripts/install-auto-receiver.py", "scripts/build-auto-transcriber.sh",
    "scripts/diagnose-agent-bridge.py", "scripts/package-agent-bridge.py", "Phone/OnDeviceTranscriber.swift",
    "scripts/read-icloud-drive-library.py", "docs/icloud-drive.md", "docs/google-drive-phone-mcp.md",
    "Tools/TranscribeOnDevice.swift",
)


def source_files(root):
    paths = [root / name for name in FILES]
    paths += sorted((root / "Sources/RecordingCore").glob("*.swift"))
    if not (root / "Sources/RecordingCore").is_dir() or len(paths) == len(FILES):
        raise ValueError("RecordingCore sources are missing")
    for path in paths:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or path.resolve() != path.absolute():
            raise ValueError("Distribution source must be a regular, non-linked file: " + path.name)
    return paths


def package(root, output, transcriber=None):
    root = root.resolve(strict=True)
    output = output.expanduser().absolute()
    entries = [(str(path.relative_to(root)), path.read_bytes(), 0o644) for path in source_files(root)]
    runtime = None
    if transcriber is not None:
        transcriber = transcriber.expanduser().absolute()
        if transcriber.is_symlink():
            raise ValueError("Transcriber must not be a symlink")
        # Normalize macOS's /var -> /private/var parent alias while rejecting a
        # linked executable itself, as source_files does after resolving root.
        transcriber = transcriber.resolve(strict=True)
        info = transcriber.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("Transcriber must be a regular, non-linked executable")
        if not info.st_mode & 0o111:
            raise ValueError("Transcriber is not executable")
        # This distribution deliberately promises one verified architecture only.
        probe = subprocess.run(["/usr/bin/lipo", "-archs", str(transcriber)],
                               capture_output=True, text=True, timeout=15)
        if probe.returncode or probe.stdout.strip() != "arm64":
            raise ValueError("Prebuilt runtime must be a macOS arm64 Mach-O executable")
        data = transcriber.read_bytes()
        entries.append(("Runtime/transcribe-on-device", data, 0o700))
        runtime = {"path": "Runtime/transcribe-on-device", "architecture": "arm64", "requiresMacOS": "26+",
                   "sha256": hashlib.sha256(data).hexdigest(), "notarization": "not_notarized",
                   "securityPolicy": "Do not bypass macOS security prompts or remove quarantine automatically."}
    manifest = {
        "schemaVersion": 1, "package": PACKAGE_ROOT, "pythonMinimum": "3.9",
        "containsUserData": False, "prebuiltTranscriber": runtime,
        "files": [{"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                  for name, data, _ in entries],
    }
    entries.append(("PACKAGE-MANIFEST.json", (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode(), 0o644))
    output.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation avoids replacing a package the user may already be sharing.
    created = False
    try:
        with output.open("xb") as destination:
            created = True
            with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for name, data, mode in entries:
                    item = zipfile.ZipInfo(PACKAGE_ROOT + "/" + name, date_time=(2026, 10, 19, 0, 0, 0))
                    item.create_system = 3
                    item.external_attr = (stat.S_IFREG | mode) << 16
                    item.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(item, data)
        output.chmod(0o600)
    except BaseException:
        if created:
            output.unlink(missing_ok=True)
        raise
    return {"path": str(output), "bytes": output.stat().st_size,
            "sha256": hashlib.sha256(output.read_bytes()).hexdigest(), "fileCount": len(entries),
            "containsUserData": False, "prebuiltTranscriber": runtime}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--transcriber", type=Path, help="Optional existing arm64 helper; never compiled or executed by this script.")
    args = parser.parse_args()
    print(json.dumps(package(ROOT, args.output, args.transcriber), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
