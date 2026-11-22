"""Ingest selected, acknowledged Mac recordings as private metadata in the local Hub."""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import sys
import uuid

from .__main__ import data_dir
from .imports import recording_source, stable_id
from .store import Store, StoreError, _json


def selected_ids(path):
    if path is None:
        return []
    values = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(values, list) or not values:
        raise ValueError("The selection must be a nonempty JSON array of segment UUIDs.")
    return sorted({str(uuid.UUID(v)) for v in values})


def read_receipts(state, library, receiver_id, selection, since):
    """Read committed receipt members and matching catalog rows in one read-only snapshot."""
    if not selection and since is None:
        raise ValueError("Choose recording IDs, a receipt start time, or both.")
    producer = recording_source()
    uri = (state.resolve() / "delivery.sqlite3").as_uri() + "?mode=ro"
    with closing(sqlite3.connect(uri, uri=True, timeout=15)) as conn:
        conn.row_factory = sqlite3.Row
        conn.execute("ATTACH DATABASE ? AS catalog", ((library.resolve() / "library.sqlite3").as_uri() + "?mode=ro",))
        conn.execute("PRAGMA query_only=ON")
        conn.execute("BEGIN")
        identity = conn.execute("SELECT receiver_id,library FROM identity WHERE singleton=1").fetchone()
        if (identity is None or identity["receiver_id"] != receiver_id
                or Path(identity["library"]).resolve() != library.resolve()):
            raise ValueError("Delivery state and recording library belong to different receivers.")
        version = conn.execute("PRAGMA catalog.user_version").fetchone()[0]
        if version not in (1, 2):
            raise ValueError("Unsupported recording library version.")
        has_transcript = ("EXISTS(SELECT 1 FROM catalog.transcripts t WHERE t.recording_id=r.id)"
                          if version == 2 else "0")
        query = """
            WITH selected AS (SELECT value AS id FROM json_each(:selection)), receipts AS (
                SELECT id,archive_hash,CAST(receipt_json AS TEXT) AS receipt
                FROM requests WHERE receipt_json IS NOT NULL AND failure_json IS NULL
            ), members AS (
                SELECT lower(j.value) AS segment, MIN(json_extract(receipt,'$.storedAt')) AS observed
                FROM receipts, json_each(receipt,'$.recordingIDs') j
                WHERE json_extract(receipt,'$.schemaVersion')=1 AND j.type='text'
                  AND json_extract(receipt,'$.receiverID')=:receiver
                  AND json_extract(receipt,'$.deliveryID')=receipts.id
                  AND json_extract(receipt,'$.archiveSHA256')=receipts.archive_hash
                  AND json_type(receipt,'$.storedAt')='integer' AND json_extract(receipt,'$.storedAt')>=0
                  AND (lower(j.value) IN (SELECT id FROM selected) OR json_extract(receipt,'$.storedAt')>=:since)
                GROUP BY lower(j.value)
            )
            SELECT r.id,r.session_id,r.sequence,r.started_at,r.ended_at,
                   json_remove(CAST(r.manifest_json AS TEXT),'$.location','$.recordingGroup') AS manifest_json,
                   m.observed, """ + has_transcript + """ AS has_transcript
            FROM members m JOIN catalog.recordings r ON r.id=m.segment
            WHERE EXISTS(SELECT 1 FROM catalog.export_members em JOIN catalog.exports e ON e.id=em.export_id
                         WHERE em.recording_id=r.id)
              AND (r.id IN (SELECT id FROM selected) OR
                   (SELECT MIN(e.imported_at) FROM catalog.export_members em JOIN catalog.exports e
                    ON e.id=em.export_id WHERE em.recording_id=r.id)>=:since)
            ORDER BY r.id"""
        params = {"receiver": receiver_id, "selection": json.dumps(selection), "since": since}
        for row in conn.execute(query, params):
            manifest = producer._manifest_from_row(row)
            yield {
                "id": stable_id("record-for-agent", manifest["id"]),
                "source": "voice", "kind": "audio_segment",
                "t_start": manifest["startedAt"], "t_end": manifest["endedAt"], "t_observed": row["observed"],
                "tz": manifest.get("timeZoneIdentifier", "UTC"),
                "tz_source": "recorded" if "timeZoneIdentifier" in manifest else "utc_fallback",
                "context": {k: manifest[k] for k in ("sessionID", "sequence", "sampleRate", "frameCount", "byteCount")},
                "content": {"source_transcript_available": bool(row["has_transcript"])},
                "privacy": {"tier": "local_only"},
                "provenance": {"connector": "record-for-agent", "source_id": manifest["id"],
                               "source_hash": manifest["sha256"], "locator": "receiver-library#segment=" + manifest["id"]},
            }


def save_receipt(store, event, transcript_flag="source_transcript_available"):
    # Compare metadata in SQLite. Existing user-authored text need never leave the database.
    old = {**event, "content": {transcript_flag: False}}
    with store._transaction(False) as conn:
        existing = conn.execute("""
            SELECT revision, event=? AS same, event=? AS initial
            FROM raw_events WHERE source='voice' AND connector=? AND source_id=?""",
            (_json(event), _json(old), event["provenance"]["connector"], event["provenance"]["source_id"])).fetchone()
    if existing is None:
        store.put_raw(event)
        return "created"
    if existing["same"]:
        return "unchanged"
    # Enrich only the exact metadata record this bridge previously inserted. A deletion,
    # explicit import, redaction, privacy change or manual edit always takes precedence.
    if existing["revision"] == 1 and existing["initial"] and event["content"][transcript_flag]:
        store.put_raw(event, expected_revision=1)
        return "updated"
    return "preserved"


def sync(state, library, receiver_id, store, selection, since=None):
    counts = dict(created=0, updated=0, unchanged=0, preserved=0)
    for event in read_receipts(state, library, receiver_id, selection, since):
        counts[save_receipt(store, event)] += 1
    return counts


def main(argv=None):
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--receiver-state", required=True, type=Path)
    cli.add_argument("--library", required=True, type=Path)
    cli.add_argument("--receiver-id", required=True, help="Pin the paired Mac receiver UUID")
    cli.add_argument("--selection", type=Path, help="Owner-selected JSON array of segment UUIDs")
    cli.add_argument("--since-ms", type=int, help="Also accept successful receiver receipts at or after this Unix millisecond")
    cli.add_argument("--data-dir", type=Path, default=data_dir(), help="Existing local Hub directory")
    cli.add_argument("--launchd-plist", action="store_true", help="Print a macOS LaunchAgent for the same scope")
    args = cli.parse_args(argv)
    try:
        receiver_id = str(uuid.UUID(args.receiver_id))
    except ValueError:
        cli.error("--receiver-id must be a UUID.")
    if args.selection is None and args.since_ms is None:
        cli.error("Choose --selection or --since-ms.")
    if args.since_ms is not None and args.since_ms < 0:
        cli.error("--since-ms must be nonnegative.")
    if args.launchd_plist:
        cmd = [sys.executable, "-I", "-m", "hub.recording_sync", "--receiver-state", str(args.receiver_state.resolve()),
               "--library", str(args.library.resolve()), "--receiver-id", receiver_id, "--data-dir", str(args.data_dir.resolve())]
        if args.selection is not None:
            cmd += ["--selection", str(args.selection.resolve())]
        if args.since_ms is not None:
            cmd += ["--since-ms", str(args.since_ms)]
        sys.stdout.buffer.write(plistlib.dumps({"Label": "dev.context-hub.recording-receipts",
            "ProgramArguments": cmd, "RunAtLoad": True, "StartInterval": 60, "Umask": 0o077,
            "ProcessType": "Background", "LimitLoadToSessionType": "Aqua"}))
        return 0
    try:
        os.umask(0o077)
        database = args.data_dir / "local.sqlite3"
        if not database.is_file():
            raise ValueError("Start the local Hub in the selected directory first.")
        counts = sync(args.receiver_state, args.library, receiver_id, Store(database), selected_ids(args.selection), args.since_ms)
    except (OSError, ValueError, TypeError, sqlite3.Error, StoreError, recording_source().BridgeError) as error:
        print(f"Recording sync failed ({type(error).__name__}). Committed rows are safe to retry.", file=sys.stderr)
        return 1
    print(json.dumps(counts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
