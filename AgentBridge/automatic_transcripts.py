"""Bounded, read-only ASR return for exact durable receiver receipts.

The bearer authenticates the existing receiver. Historical Phone pairing/grant
identifiers were never registered here: scope is a caller-side generation fence,
not an independently authenticated grant. No audio, ASR work or Drive writes occur.
"""

import contextlib
import hashlib
import re
import sqlite3
import time

from library import (BridgeError, DB_NAME, Library, MAX_TIMESTAMP, _manifest_from_row,
                     _regular_file, canonical_json, canonical_uuid, parse_json,
                     validate_transcript)


MAX_QUERY_BYTES = 32 * 1024
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
MAX_QUERY_ITEMS = 4
QUERY_SECONDS = 10
HASH = re.compile(r"^[a-f0-9]{64}$")
SCOPE_FIELDS = {"receiverID", "pairingID", "grantEpoch", "sourceInstallationID"}
RECEIPT_FIELDS = {"schemaVersion", "receiverID", "deliveryID", "archiveSHA256", "recordingIDs", "storedAt"}
SOURCE_FIELDS = {"segmentID", "sessionID", "sequence", "audioSHA256"}


def _invalid():
    raise BridgeError("invalid_arguments", "The transcript query does not match its bounded schema.")


def _denied():
    raise BridgeError("transcript_not_authorized", "The supplied transcript capability could not be verified.")


def _unavailable():
    raise BridgeError("transcript_unavailable", "The transcript query is temporarily unavailable.")


def _object(value, fields):
    if not isinstance(value, dict) or set(value) != fields:
        _invalid()


def _uuid(value):
    try:
        return canonical_uuid(value)
    except BridgeError:
        _invalid()


def _receipt(value):
    _object(value, RECEIPT_FIELDS)
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        _invalid()
    if not isinstance(value["archiveSHA256"], str) or not HASH.fullmatch(value["archiveSHA256"]):
        _invalid()
    ids = value["recordingIDs"]
    if not isinstance(ids, list) or not 1 <= len(ids) <= 500:
        _invalid()
    ids = [_uuid(identifier) for identifier in ids]
    if len(set(ids)) != len(ids):
        _invalid()
    if type(value["storedAt"]) is not int or not 0 <= value["storedAt"] <= MAX_TIMESTAMP:
        _invalid()
    return dict(value, receiverID=_uuid(value["receiverID"]),
                deliveryID=_uuid(value["deliveryID"]), recordingIDs=ids)


def _request(value):
    _object(value, {"schemaVersion", "scope", "items"})
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        _invalid()
    _object(value["scope"], SCOPE_FIELDS)
    scope = {key: _uuid(value["scope"][key]) for key in SCOPE_FIELDS}
    if not isinstance(value["items"], list) or not 1 <= len(value["items"]) <= MAX_QUERY_ITEMS:
        _invalid()
    items, deliveries, sources = [], set(), set()
    for item in value["items"]:
        _object(item, {"receipt", "source"})
        receipt = _receipt(item["receipt"])
        _object(item["source"], SOURCE_FIELDS)
        source = dict(item["source"])
        source["segmentID"] = _uuid(source["segmentID"])
        source["sessionID"] = _uuid(source["sessionID"])
        if type(source["sequence"]) is not int or not 0 <= source["sequence"] <= 2 ** 63 - 1:
            _invalid()
        if not isinstance(source["audioSHA256"], str) or not HASH.fullmatch(source["audioSHA256"]):
            _invalid()
        if receipt["deliveryID"] in deliveries or source["segmentID"] in sources:
            _invalid()
        deliveries.add(receipt["deliveryID"]); sources.add(source["segmentID"])
        items.append((receipt, source))
    return scope, items


@contextlib.contextmanager
def _read(path, check):
    _regular_file(path)
    connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only=ON")
    connection.set_progress_handler(lambda: 0 if check() else 1, 1000)
    try:
        connection.execute("BEGIN")
        yield connection
    finally:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        connection.close()


def query_transcripts(store, request, *, cancelled=None, deadline=None):
    """All capabilities/identities are checked before any transcript body read.

    Caller cancellation/deadline is checked between bounded operations. A client
    disconnect never starts/persists a worker; this request only reads snapshots.
    """
    scope, items = _request(request)
    if len(canonical_json(request).encode("utf-8")) > MAX_QUERY_BYTES:
        _invalid()
    end = time.monotonic() + QUERY_SECONDS if deadline is None else deadline

    def check():
        if (cancelled is not None and cancelled()) or time.monotonic() >= end:
            raise BridgeError("transcript_query_interrupted", "The transcript query was interrupted.")
        return True

    try:
        check()
        if scope["receiverID"] != store.receiver_id:
            _denied()
        with _read(store.database, check) as receiver, Library(store.library)._read() as catalog:
            catalog.execute("PRAGMA busy_timeout=2000")
            catalog.set_progress_handler(lambda: 0 if check() else 1, 1000)
            identity = receiver.execute("SELECT receiver_id,library FROM identity WHERE singleton=1").fetchone()
            if identity is None or tuple(identity) != (store.receiver_id, str(store.library)):
                _denied()
            manifests = []
            # Metadata-only authorization pass over the WHOLE batch. Do not call
            # _members/get_recording: their joins already select transcript_json.
            for receipt, source in items:
                check()
                if receipt["receiverID"] != store.receiver_id:
                    _denied()
                row = receiver.execute("SELECT archive_hash,receipt_json,failure_json FROM requests WHERE id=?",
                                       (receipt["deliveryID"],)).fetchone()
                if row is None or row["receipt_json"] is None or row["failure_json"] is not None:
                    _denied()
                try:
                    stored_receipt = _receipt(parse_json(row["receipt_json"]))
                except BridgeError:
                    _denied()
                if row["archive_hash"] != receipt["archiveSHA256"] or stored_receipt != receipt:
                    _denied()
                members = [row[0] for row in catalog.execute(
                    "SELECT recording_id FROM export_members WHERE export_id=?", (receipt["deliveryID"],))]
                if len(members) != len(receipt["recordingIDs"]) or set(members) != set(receipt["recordingIDs"]):
                    _denied()
                if source["segmentID"] not in members:
                    _denied()
                row = catalog.execute("SELECT * FROM recordings WHERE id=?", (source["segmentID"],)).fetchone()
                if row is None:
                    _denied()
                try:
                    manifest = _manifest_from_row(row)
                except BridgeError:
                    _denied()
                expected = {"segmentID": manifest["id"], "sessionID": manifest["sessionID"],
                            "sequence": manifest["sequence"], "audioSHA256": manifest["sha256"]}
                if source != expected:
                    _denied()
                manifests.append(manifest)
            check()
            result = {"schemaVersion": 1, "scope": dict(request["scope"]), "items": []}
            for (receipt, source), manifest in zip(items, manifests):
                check()
                item = {"receipt": receipt, "source": source, "status": "pending",
                        "transcriptJSON": None, "transcriptSHA256": None, "transcriptByteCount": None}
                try:
                    tables = {row[0] for row in catalog.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                    size = catalog.execute("SELECT length(CAST(transcript_json AS BLOB)) FROM transcripts WHERE recording_id=?",
                                           (source["segmentID"],)).fetchone() if "transcripts" in tables else None
                    if size is not None and size[0] > MAX_RESPONSE_BYTES:
                        item.update(status="unavailable", reason="transcript_too_large")
                        result["items"].append(item)
                        continue
                    row = catalog.execute("SELECT transcript_json,search_text FROM transcripts WHERE recording_id=?",
                                          (source["segmentID"],)).fetchone() if "transcripts" in tables else None
                    if row is not None:
                        transcript = validate_transcript(parse_json(row["transcript_json"]), manifest)
                        if transcript["text"].casefold() != row["search_text"]:
                            raise BridgeError("library_corrupt", "Invalid transcript search data.")
                        raw = canonical_json(transcript).encode("utf-8")
                        item.update(status="ready", transcriptJSON=raw.decode("utf-8"),
                                    transcriptSHA256=hashlib.sha256(raw).hexdigest(), transcriptByteCount=len(raw))
                    else:
                        item.update(_asr_state(store, source, check))
                except (BridgeError, OSError, sqlite3.Error, ValueError):
                    check()
                    item["status"] = "unavailable"
                result["items"].append(item)
                # Measure the final wire form, including nested-string escaping
                # and reply's newline. Oversized text is never partially returned.
                if len((canonical_json(result) + "\n").encode("utf-8")) > MAX_RESPONSE_BYTES:
                    item.update(status="unavailable", transcriptJSON=None, transcriptSHA256=None,
                                transcriptByteCount=None, reason="transcript_too_large")
            check()
            if len((canonical_json(result) + "\n").encode("utf-8")) > MAX_RESPONSE_BYTES:
                _unavailable()
            return result
    except BridgeError:
        raise
    except (OSError, sqlite3.Error, ValueError):
        _unavailable()


def _asr_state(store, source, check):
    path = store.root / "transcription" / "transcription.sqlite3"
    if not path.exists():
        return {"status": "pending"}
    with _read(path, check) as connection:
        row = connection.execute("SELECT audio_hash,status,updated_at FROM jobs WHERE recording_id=?",
                                 (source["segmentID"],)).fetchone()
    if row is None:
        return {"status": "pending"}
    if row["audio_hash"] != source["audioSHA256"]:
        return {"status": "unavailable"}
    status = {"running": "pending", "retry": "retry", "no_speech": "no_speech"}.get(row["status"], "unavailable")
    value = {"status": status}
    if type(row["updated_at"]) is int and 0 <= row["updated_at"] <= MAX_TIMESTAMP:
        value["asrUpdatedAt"] = row["updated_at"]
    return value
