"""Import owner-only observations of committed recordings from one selected iCloud Drive library."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

from .__main__ import data_dir
from .contract import data_file
from .imports import stable_id
from .recording_sync import save_receipt, selected_ids
from .store import Store, StoreError


CONNECTOR = "record-for-agent.icloud"


class ObservationError(ValueError):
    def __init__(self, code, returncode):
        super().__init__(code)
        self.returncode = returncode


def observe(root, library_id, command, scope=None, request_metadata=False):
    # Run the standalone producer reader with its own validated sibling library.py,
    # whether this Hub runs from a checkout or an installed wheel.
    reader = data_file("channels/audio/record-for-agent/AgentBridge/icloud_drive_library.py")
    fetch = ["--request-metadata"] if request_metadata else []
    call = subprocess.run([sys.executable, "-E", "-s", str(reader), "--library-root", str(root),
                           "--library-id", library_id, *fetch, command], input=json.dumps(scope),
                          text=True, capture_output=True, check=False)
    try:
        result = json.loads(call.stdout)
    except ValueError:
        raise ObservationError("icloud_reader_failed", 1) from None
    if call.returncode or result.get("libraryID") != library_id:
        raise ObservationError(result.get("error", {}).get("code", "library_identity_changed"), call.returncode or 1)
    return result


def initialize_baseline(root, library_id, baseline, request_metadata=False):
    # Publish a complete immutable baseline. A second install cannot replace it.
    started = time.time_ns() // 1_000_000
    result = observe(root, library_id, "directory-baseline", request_metadata=request_metadata)
    with tempfile.NamedTemporaryFile(dir=baseline.parent, delete=False) as handle:
        tmp = Path(handle.name)
        try:
            handle.write(json.dumps({"libraryID": library_id, "startedAt": started,
                                     "segments": result["segments"]}).encode("utf-8"))
            handle.flush()
            os.fsync(handle.fileno())
            os.link(tmp, baseline)
        finally:
            tmp.unlink(missing_ok=True)
    return {"baselineCount": len(result["segments"]), "startedAt": started}


def sync(root, library_id, store, selection, baseline=None, request_metadata=False):
    result = observe(root, library_id, "hub-metadata", {"selection": selection, "baseline": baseline}, request_metadata)
    counts = {key: result[key] for key in ("absentSelected", "pending", "rejected")}
    if request_metadata:
        counts["metadataRequestsAccepted"] = result["metadataRequestsAccepted"]
    counts.update(created=0, updated=0, unchanged=0, preserved=0)
    for row in result["segments"]:
        sid, manifest = row["segmentID"], row["manifest"]
        event = {
            "id": stable_id(CONNECTOR, library_id, sid), "source": "voice", "kind": "cloud_audio_commit",
            "t_start": manifest["startedAt"], "t_end": manifest["endedAt"], "t_observed": row["committedAt"],
            "tz": manifest.get("timeZoneIdentifier", "UTC"),
            "tz_source": "recorded" if "timeZoneIdentifier" in manifest else "utc_fallback",
            "context": {key: manifest[key] for key in ("sessionID", "sequence", "sampleRate", "frameCount", "byteCount")},
            "content": {"transcript_commit_observed": row["transcriptCommitted"]},
            "privacy": {"tier": "local_only"},
            "provenance": {"connector": CONNECTOR, "source_id": library_id + "/" + sid, "original_id": sid,
                           "source_hash": row["audioSHA256"], "manifest_sha256": row["manifestSHA256"],
                           "library_id": library_id, "evidence": "committed_manifest_and_audio_entry",
                           "provider_upload_status": "not_established", "audio_content_verified": False},
        }
        counts[save_receipt(store, event, "transcript_commit_observed")] += 1
    return counts


def main(argv=None):
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--library-root", required=True, type=Path)
    cli.add_argument("--library-id", required=True, type=uuid.UUID)
    cli.add_argument("--selection", type=Path, help="JSON file of explicit original segment UUIDs")
    cli.add_argument("--baseline", type=Path, help="Pinned baseline for future source UUIDs")
    cli.add_argument("--data-dir", type=Path, default=data_dir())
    cli.add_argument("--request-metadata", action="store_true", help="Fetch evicted marker or selected commit and manifest JSON only")
    action = cli.add_mutually_exclusive_group()
    action.add_argument("--initialize-baseline", action="store_true")
    action.add_argument("--launchd-plist", action="store_true")
    args = cli.parse_args(argv)
    library_id = str(args.library_id)
    if not (args.selection or args.baseline) or args.initialize_baseline and not args.baseline:
        cli.error("Choose a selection or a baseline. Initialization requires --baseline.")
    os.umask(0o077)
    if args.launchd_plist:
        cmd = [sys.executable, "-I", "-m", "hub.icloud_sync", "--library-root", str(args.library_root.absolute()),
               "--library-id", library_id, "--data-dir", str(args.data_dir.absolute())]
        if args.request_metadata:
            cmd += ["--request-metadata"]
        if args.selection:
            cmd += ["--selection", str(args.selection.absolute())]
        if args.baseline:
            cmd += ["--baseline", str(args.baseline.absolute())]
        sys.stdout.buffer.write(plistlib.dumps({"Label": "dev.context-hub.icloud-recordings",
            "ProgramArguments": cmd, "RunAtLoad": True, "StartInterval": 60, "Umask": 0o077,
            "ProcessType": "Background", "LimitLoadToSessionType": "Aqua"}))
        return 0
    try:
        if args.initialize_baseline:
            counts = initialize_baseline(args.library_root, library_id, args.baseline, args.request_metadata)
        else:
            database = args.data_dir / "local.sqlite3"
            if not database.is_file():
                raise ValueError("Hub database unavailable")
            baseline = json.loads(args.baseline.read_text("utf-8")) if args.baseline else None
            counts = sync(args.library_root, library_id, Store(database), selected_ids(args.selection), baseline, args.request_metadata)
    except ObservationError as error:
        print(json.dumps({"status": "pending" if error.returncode == 2 else "rejected", "code": str(error)}))
        return error.returncode
    except (OSError, ValueError, TypeError, sqlite3.Error, StoreError):
        print("iCloud recording sync failed. Check the pinned library, baseline and local Hub.", file=sys.stderr)
        return 1
    print(json.dumps(counts))
    return 1 if counts.get("rejected") else 0


if __name__ == "__main__":
    sys.exit(main())
