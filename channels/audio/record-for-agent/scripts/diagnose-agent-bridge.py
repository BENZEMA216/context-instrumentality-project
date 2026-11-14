#!/usr/bin/env python3
"""Read local bridge metadata and counts; never print credentials or recording content."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import sqlite3
import subprocess
import sys

LABEL = "dev.benzema.record-for-agent.receiver"


def database_counts(path, queries):
    if not path.exists():
        return {"exists": False}
    if path.is_symlink() or not path.is_file():
        return {"exists": True, "error": "unsafe_database_path"}
    try:
        with sqlite3.connect(path.absolute().as_uri() + "?mode=ro", uri=True, timeout=5) as db:
            db.execute("PRAGMA query_only=ON")
            tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            result = {"exists": True}
            for name, table, query in queries:
                result[name] = db.execute(query).fetchone()[0] if table in tables else None
            return result
    except (OSError, sqlite3.Error) as error:
        return {"exists": True, "error": type(error).__name__}


def inspect_paths(home, library, state):
    result = {
        "python": {"executable": sys.executable, "version": list(sys.version_info[:3]),
                   "supported": sys.version_info >= (3, 9)},
        "library": {"path": str(library), **database_counts(library / "library.sqlite3", [
            ("recordings", "recordings", "SELECT count(*) FROM recordings"),
            ("readyTranscripts", "transcripts", "SELECT count(*) FROM transcripts")])},
        "delivery": {"path": str(state), **database_counts(state / "delivery.sqlite3", [
            ("durableReceipts", "requests", "SELECT count(*) FROM requests WHERE receipt_json IS NOT NULL"),
            ("readyEvents", "events", "SELECT count(*) FROM events"),
            ("deliveryTargetsWithEvents", "deliveries", "SELECT count(DISTINCT target) FROM deliveries")])},
        "transcription": database_counts(state / "transcription/transcription.sqlite3", [
            ("jobs", "jobs", "SELECT count(*) FROM jobs"),
            ("ready", "jobs", "SELECT count(*) FROM jobs WHERE status='ready'"),
            ("retry", "jobs", "SELECT count(*) FROM jobs WHERE status='retry'"),
            ("running", "jobs", "SELECT count(*) FROM jobs WHERE status='running'"),
            ("noSpeech", "jobs", "SELECT count(*) FROM jobs WHERE status='no_speech'")]),
        "pairingFilesPresent": {name: (state / name).is_file() for name in
                                ("receiver.json", "pairing.json", "receiver-token", "receiver.crt", "receiver.key")},
        "clientConfigFilesPresent": {name: (home / name).is_file() for name in
                                     (".codex/config.toml", ".workbuddy-ai/mcp.json", ".workbuddy-ai/.mcp.json")},
        "launchAgent": {"label": LABEL},
        "proofLimit": "Local counts and launch metadata only; not phone delivery or actual Agent tool execution.",
    }
    plist_path = home / "Library/LaunchAgents" / (LABEL + ".plist")
    result["launchAgent"]["plistExists"] = plist_path.is_file()
    if plist_path.is_file() and not plist_path.is_symlink():
        try:
            config = plistlib.loads(plist_path.read_bytes())
            args = config.get("ProgramArguments", [])
            # Allowlist operational paths. Never echo full argv, EnvironmentVariables,
            # token paths' contents, a pairing document, or a service log.
            result["launchAgent"]["configuredPaths"] = {
                flag: args[args.index(flag) + 1]
                for flag in ("--state", "--library", "--transcriber")
                if flag in args and args.index(flag) + 1 < len(args)
            }
        except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
            result["launchAgent"]["error"] = type(error).__name__
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    base = Path.home() / "Library/Application Support/RecordForAgent"
    parser.add_argument("--library", type=Path, default=base / "Library")
    parser.add_argument("--state", type=Path, default=base / "AutomaticDelivery")
    args = parser.parse_args()
    result = inspect_paths(Path.home(), args.library.expanduser().absolute(), args.state.expanduser().absolute())
    if sys.platform == "darwin":
        try:
            process = subprocess.run(["/bin/launchctl", "print", "gui/%d/%s" % (os.getuid(), LABEL)],
                                     capture_output=True, text=True, timeout=10)
            result["launchAgent"]["loaded"] = process.returncode == 0
            for name in ("state", "pid", "last exit code"):
                match = re.search(r"^\s*" + re.escape(name) + r" = ([a-zA-Z0-9_-]+)\s*$", process.stdout, re.M)
                if match:
                    result["launchAgent"][name] = match.group(1)
        except (OSError, subprocess.SubprocessError) as error:
            result["launchAgent"]["probeError"] = type(error).__name__
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
