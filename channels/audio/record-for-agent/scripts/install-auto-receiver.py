#!/usr/bin/env python3
"""Install the explicitly requested per-user Mac receiver, without binding Agent chats."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "AgentBridge"))
from automatic import private_directory, private_file
from setup_receiver import prepare, write_private


def install(args):
    state = private_directory(Path(args.state).expanduser().resolve())
    library = Path(args.library).expanduser().resolve(strict=True)
    python = Path(args.python).expanduser().resolve(strict=True)
    transcriber = Path(args.transcriber).expanduser().resolve(strict=True)
    identity = json.loads(private_file(state / "receiver.json").read_text())
    # Validate the existing secret/certificate/key as a set. Never create or rotate
    # pairing credentials as a side effect of installing a background receiver.
    prepare(state, identity["endpoint"])
    from urllib.parse import urlsplit
    port = urlsplit(identity["endpoint"]).port
    label = "dev.benzema.record-for-agent.receiver"
    agents = Path.home() / "Library/LaunchAgents"
    agents.mkdir(exist_ok=True)
    target = agents / (label + ".plist")
    domain = "gui/" + str(os.getuid())
    loaded = subprocess.run(["/bin/launchctl", "print", domain + "/" + label],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if loaded:
        # An on-disk plist does not prove the loaded service uses those arguments.
        # Do not claim success or change files for an unverified running instance.
        raise RuntimeError("Receiver label is already loaded; verify or explicitly stop it before reinstalling.")
    for name in ("receiver.stdout.log", "receiver.stderr.log"):
        path = state / name
        if path.exists() or path.is_symlink():
            private_file(path)
        else:
            write_private(path, b"")
    configuration = {
        "Label": label,
        "ProgramArguments": [str(python), "-B", "-u", str(REPO / "AgentBridge/automatic.py"),
            "--state", str(state), "--library", str(library), "--receiver-id", identity["receiverID"],
            "receive", "--host", args.host, "--port", str(port),
            "--token-file", str(state / "receiver-token"), "--cert", str(state / "receiver.crt"),
            "--key", str(state / "receiver.key"), "--transcriber", str(transcriber)],
        "WorkingDirectory": str(REPO / "AgentBridge"),
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 30,
        "ProcessType": "Background",
        "LimitLoadToSessionType": "Aqua",
        "Umask": 0o077,
        "EnvironmentVariables": {"PYTHONDONTWRITEBYTECODE": "1"},
        "StandardOutPath": str(state / "receiver.stdout.log"),
        "StandardErrorPath": str(state / "receiver.stderr.log"),
    }
    encoded = plistlib.dumps(configuration, sort_keys=True)
    if target.exists() or target.is_symlink():
        private_file(target)
        if target.read_bytes() != encoded:
            raise ValueError("Existing launch configuration differs; it was not replaced.")
    else:
        write_private(target, encoded)
    result = subprocess.run(["/bin/launchctl", "bootstrap", domain, str(target)], capture_output=True)
    if result.returncode:
        raise RuntimeError("LaunchAgent bootstrap failed (exit %d)." % result.returncode)
    print(json.dumps({"status": "loaded", "label": label, "receiverID": identity["receiverID"],
                      "endpoint": identity["endpoint"], "agentChatTargets": 0, "launchAgent": str(target)}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True)
    parser.add_argument("--library", required=True)
    parser.add_argument("--python", default="/usr/bin/python3")
    parser.add_argument("--transcriber", required=True)
    parser.add_argument("--host", required=True, help="Explicit interface, e.g. 0.0.0.0 for paired LAN access.")
    install(parser.parse_args())
