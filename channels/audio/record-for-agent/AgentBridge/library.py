"""Validated, explicit ZIP import and a read-only recording catalog (stdlib only)."""

import base64
import contextlib
from datetime import datetime, timedelta, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import struct
import tempfile
import time
import uuid
import zipfile
from dataclasses import dataclass
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


MIB = 1024 * 1024
CHUNK = 1024 * 1024
DB_NAME = "library.sqlite3"
MANIFEST_FIELDS = {"schemaVersion", "id", "sessionID", "sequence", "startedAt",
                   "endedAt", "sampleRate", "frameCount", "fileName", "byteCount", "sha256"}
CAPTURE_FIELDS = {"timeZoneIdentifier", "location", "recordingGroup"}
LOCATION_FIELDS = {"latitude", "longitude", "horizontalAccuracy", "capturedAt"}
EXPORT_FIELDS = {"schemaVersion", "exportID", "exportedAt", "transcriptStatus", "segments"}
TRANSCRIPT_FIELDS = {"schemaVersion", "segmentID", "audioSHA256", "locale", "engine", "createdAt", "text", "spans"}
MAX_TIMESTAMP = 253402300799999
MAX_TRANSCRIPT_TEXT_BYTES = 256 * 1024
MAX_TRANSCRIPT_SPANS = 10000
MAX_SPAN_TEXT_BYTES = 8 * 1024


class BridgeError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message

    def payload(self):
        return {"error": {"code": self.code, "message": self.message}}


@dataclass(frozen=True)
class Limits:
    max_segments: int = 500
    max_archive_bytes: int = 512 * MIB
    max_total_bytes: int = 512 * MIB
    max_file_bytes: int = 128 * MIB
    max_metadata_bytes: int = 4 * MIB
    max_readme_bytes: int = 256 * 1024
    max_compression_ratio: int = 2000

    def __post_init__(self):
        for value in self.__dict__.values():
            if type(value) is not int or value <= 0:
                raise BridgeError("invalid_arguments", "All import limits must be positive integers.")


def canonical_json(value):
    # ASCII escaping also round-trips an unpaired surrogate in a JSON-RPC ID
    # without crashing the UTF-8 transport encoder.
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"), allow_nan=False)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise BridgeError("invalid_json", "Duplicate JSON keys are not accepted.")
        result[key] = value
    return result


def parse_json(data):
    try:
        if isinstance(data, bytes):
            data = data.decode("utf-8")
        return json.loads(data, object_pairs_hook=_pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Non-finite number")))
    except (ValueError, UnicodeError, RecursionError) as error:
        raise BridgeError("invalid_json", "Expected bounded UTF-8 JSON with finite numbers.") from error


def canonical_uuid(value, field="id"):
    if not isinstance(value, str):
        raise BridgeError("invalid_schema", "%s must be a UUID string." % field)
    try:
        normalized = str(uuid.UUID(value))
    except (ValueError, AttributeError) as error:
        raise BridgeError("invalid_schema", "%s must be a UUID string." % field) from error
    if value.lower() != normalized:
        raise BridgeError("invalid_schema", "%s must use the hyphenated UUID form." % field)
    return normalized


def _integer(value, field, minimum=0, maximum=MAX_TIMESTAMP):
    if type(value) is not int or not minimum <= value <= maximum:
        raise BridgeError("invalid_schema", "%s is outside its integer range." % field)
    return value


def validate_manifest(value, max_file_bytes):
    if (not isinstance(value, dict) or not MANIFEST_FIELDS <= set(value)
            or set(value) - MANIFEST_FIELDS - CAPTURE_FIELDS):
        raise BridgeError("invalid_schema", "Manifest fields do not match schema version 1.")
    result = dict(value)
    _integer(result["schemaVersion"], "manifest.schemaVersion", 1, 1)
    result["id"] = canonical_uuid(result["id"])
    result["sessionID"] = canonical_uuid(result["sessionID"], "sessionID")
    _integer(result["sequence"], "sequence", 0, 2**31 - 1)
    _integer(result["startedAt"], "startedAt")
    _integer(result["endedAt"], "endedAt")
    if result["endedAt"] < result["startedAt"]:
        raise BridgeError("invalid_schema", "endedAt must not precede startedAt.")
    rate = result["sampleRate"]
    # Range comparison precedes float conversion: a huge JSON integer must not
    # overflow math.isfinite(), and a subnormal rate must not yield infinite duration.
    if type(rate) not in (int, float) or not 1 <= rate <= 384000 or not math.isfinite(rate):
        raise BridgeError("invalid_schema", "sampleRate must be finite and between 1 and 384000 Hz.")
    result["sampleRate"] = float(rate)
    _integer(result["frameCount"], "frameCount", 1, 2**63 - 1)
    _integer(result["byteCount"], "byteCount", 1, max_file_bytes)
    if result["fileName"] != result["id"] + ".caf":
        raise BridgeError("invalid_schema", "fileName must be the lowercase segment UUID followed by .caf.")
    if not isinstance(result["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", result["sha256"]):
        raise BridgeError("invalid_schema", "sha256 must be 64 lowercase hexadecimal characters.")
    if "timeZoneIdentifier" in result:
        _recorded_zone(result["timeZoneIdentifier"])
    if "location" in result:
        _validate_location(result["location"])
    if "recordingGroup" in result:
        result["recordingGroup"] = validate_recording_group(result["recordingGroup"], result["sequence"])
        grouped_audio_name(result)
    # Every accepted version must remain readable in the recorded local calendar.
    # A UTC year-9999 value can overflow after applying a positive zone offset.
    recording_metadata(result)
    # Do not insert absent optional fields: historical manifest identity is immutable.
    return result


def validate_recording_group(value, sequence):
    if not isinstance(value, dict) or set(value) != {"id", "startedAt", "utcOffsetMinutes", "firstSequence"}:
        raise BridgeError("invalid_schema", "Recording group fields do not match the capture schema.")
    return {
        "id": canonical_uuid(value["id"], "recordingGroup.id"),
        "startedAt": _integer(value["startedAt"], "recordingGroup.startedAt"),
        "utcOffsetMinutes": _integer(value["utcOffsetMinutes"], "recordingGroup.utcOffsetMinutes", -1080, 1080),
        "firstSequence": _integer(value["firstSequence"], "recordingGroup.firstSequence", 0, sequence),
    }


def grouped_audio_name(manifest):
    group = manifest.get("recordingGroup")
    if group is None:
        return None
    zone = timezone(timedelta(minutes=group["utcOffsetMinutes"]))

    def timestamp(milliseconds):
        try:
            local = (datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(milliseconds=milliseconds)).astimezone(zone)
        except OverflowError as error:
            raise BridgeError("invalid_schema", "Recording time is outside the local calendar range.") from error
        return local.isoformat(timespec="seconds")[:19].replace("T", "_").replace(":", "-") + local.strftime("%z")

    part = manifest["sequence"] - group["firstSequence"] + 1
    return (f'{timestamp(group["startedAt"])}_{group["id"]}',
            f'{timestamp(manifest["startedAt"])}_part{part:03d}_{manifest["id"]}.caf')


def _recorded_zone(identifier):
    if (not isinstance(identifier, str) or len(identifier) > 128
            or not re.fullmatch(r"[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*", identifier)
            or identifier == "localtime"):
        raise BridgeError("invalid_schema", "timeZoneIdentifier must name a known IANA time zone.")
    try:
        return ZoneInfo(identifier)
    except (ZoneInfoNotFoundError, ValueError) as error:
        raise BridgeError("invalid_schema", "timeZoneIdentifier must name a known IANA time zone.") from error


def _validate_location(location):
    if not isinstance(location, dict) or set(location) != LOCATION_FIELDS:
        raise BridgeError("invalid_schema", "Location requires latitude, longitude, horizontalAccuracy and capturedAt.")
    for key, minimum, maximum in (("latitude", -90, 90), ("longitude", -180, 180), ("horizontalAccuracy", 0, 100000)):
        value = location[key]
        if type(value) not in (int, float) or not minimum <= value <= maximum or not math.isfinite(value):
            raise BridgeError("invalid_schema", "location.%s is outside its finite numeric range." % key)
    _integer(location["capturedAt"], "location.capturedAt")


def _iso8601(milliseconds, zone):
    _integer(milliseconds, "timestamp")
    try:
        instant = datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(milliseconds=milliseconds)
        return instant.astimezone(zone).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    except (OverflowError, ValueError) as error:
        raise BridgeError("invalid_schema", "Timestamp is outside the supported local calendar range.") from error


def recording_metadata(manifest):
    """Derive human-readable times without claiming an unknown historical time zone."""
    identifier = manifest.get("timeZoneIdentifier", "UTC")
    zone = _recorded_zone(identifier)
    result = {"startedAt": manifest["startedAt"], "endedAt": manifest["endedAt"],
              "startedAtISO8601": _iso8601(manifest["startedAt"], zone),
              "endedAtISO8601": _iso8601(manifest["endedAt"], zone),
              "timeZoneIdentifier": identifier,
              "timeZoneSource": "recorded" if "timeZoneIdentifier" in manifest else "utc_fallback"}
    if "location" in manifest:
        _validate_location(manifest["location"])
        result["location"] = dict(manifest["location"], capturedAtISO8601=_iso8601(manifest["location"]["capturedAt"], zone))
    return result


def _validate_recording_metadata(value, manifest):
    expected = recording_metadata(manifest)
    if not isinstance(value, dict) or set(value) != set(expected):
        raise BridgeError("invalid_schema", "Recording metadata fields must match the source manifest.")
    for key in ("startedAt", "endedAt"):
        _integer(value[key], "metadata." + key)
    if "location" in value:
        location = value["location"]
        if not isinstance(location, dict) or set(location) != LOCATION_FIELDS | {"capturedAtISO8601"}:
            raise BridgeError("invalid_schema", "Recording metadata location fields are invalid.")
        _validate_location({key: location[key] for key in LOCATION_FIELDS})
    if value != expected:
        raise BridgeError("integrity_mismatch", "Recording metadata must preserve the source times, time zone and location.")
    return expected


def _text(value, field, maximum):
    if not isinstance(value, str) or not value.strip() or "\x00" in value:
        raise BridgeError("invalid_schema", "%s must be nonblank text without NUL characters." % field)
    try:
        size = len(value.encode("utf-8"))
    except UnicodeEncodeError as error:
        raise BridgeError("invalid_schema", "%s must contain valid Unicode text." % field) from error
    if size > maximum:
        raise BridgeError("limit_exceeded", "%s exceeds its UTF-8 byte limit." % field)
    return value


def validate_transcript(value, manifest):
    if not isinstance(value, dict) or set(value) != TRANSCRIPT_FIELDS:
        raise BridgeError("invalid_schema", "Transcript fields do not match schema version 1.")
    result = dict(value)
    _integer(result["schemaVersion"], "transcript.schemaVersion", 1, 1)
    result["segmentID"] = canonical_uuid(result["segmentID"], "transcript.segmentID")
    if result["segmentID"] != manifest["id"] or result["audioSHA256"] != manifest["sha256"]:
        raise BridgeError("integrity_mismatch", "Transcript must belong to this segment ID and audio SHA-256.")
    for key in ("locale", "engine"):
        _text(result[key], "transcript." + key, 128)
    _integer(result["createdAt"], "transcript.createdAt")
    _text(result["text"], "transcript.text", MAX_TRANSCRIPT_TEXT_BYTES)
    if not isinstance(result["spans"], list):
        raise BridgeError("invalid_schema", "transcript.spans must be an array.")
    if len(result["spans"]) > MAX_TRANSCRIPT_SPANS:
        raise BridgeError("limit_exceeded", "Transcript contains too many spans.")
    duration, spans = manifest["frameCount"] / manifest["sampleRate"], []
    for span in result["spans"]:
        if not isinstance(span, dict) or set(span) != {"start", "end", "text"}:
            raise BridgeError("invalid_schema", "Each transcript span requires only start, end and text.")
        for key in ("start", "end"):
            number = span[key]
            if type(number) not in (int, float) or not 0 <= number <= duration or not math.isfinite(number):
                raise BridgeError("invalid_schema", "Transcript span times must be finite seconds within the audio duration.")
        if span["end"] < span["start"]:
            raise BridgeError("invalid_schema", "Transcript span end must not precede its start.")
        _text(span["text"], "transcript.spans.text", MAX_SPAN_TEXT_BYTES)
        spans.append({"start": float(span["start"]), "end": float(span["end"]), "text": span["text"]})
    result["spans"] = spans
    return result


def _transcript_status(count, total):
    return "not_generated" if count == 0 else "ready" if count == total else "partial"


def validate_export(value, limits):
    if not isinstance(value, dict) or set(value) != EXPORT_FIELDS:
        raise BridgeError("invalid_schema", "Export fields do not match the supported envelope schema.")
    version = _integer(value["schemaVersion"], "schemaVersion", 1, 3)
    export_id = canonical_uuid(value["exportID"], "exportID")
    _integer(value["exportedAt"], "exportedAt")
    if version == 1 and value["transcriptStatus"] != "not_generated":
        raise BridgeError("invalid_schema", "Version 1 exports must explicitly declare no generated transcript.")
    segments = value["segments"]
    if not isinstance(segments, list) or not 1 <= len(segments) <= limits.max_segments:
        raise BridgeError("limit_exceeded", "Export must contain 1 to %d selected segments." % limits.max_segments)
    ids, positions, normalized, transcript_count = set(), set(), [], 0
    for segment in segments:
        base = {"manifest", "audioPath", "metadata"} if version == 3 else {"manifest", "audioPath"}
        allowed = (base, base | {"transcript"}) if version >= 2 else (base,)
        if not isinstance(segment, dict) or set(segment) not in allowed:
            raise BridgeError("invalid_schema", "Each selected segment needs manifest and audioPath; v2/v3 allow a transcript and v3 requires metadata.")
        manifest = validate_manifest(segment["manifest"], limits.max_file_bytes)
        expected = "audio/" + manifest["fileName"]
        if segment["audioPath"] != expected:
            raise BridgeError("invalid_schema", "audioPath does not match the selected segment UUID.")
        position = (manifest["sessionID"], manifest["sequence"])
        if manifest["id"] in ids or position in positions:
            raise BridgeError("invalid_schema", "Selected segment IDs and session sequences must be unique.")
        ids.add(manifest["id"])
        positions.add(position)
        item = {"manifest": manifest, "audioPath": expected}
        if version == 3:
            item["metadata"] = _validate_recording_metadata(segment["metadata"], manifest)
        if "transcript" in segment:
            item["transcript"] = validate_transcript(segment["transcript"], manifest)
            transcript_count += 1
        normalized.append(item)
    status = _transcript_status(transcript_count, len(segments))
    if value["transcriptStatus"] != status:
        raise BridgeError("invalid_schema", "transcriptStatus must match the number of included, valid transcripts.")
    return {"schemaVersion": version, "exportID": export_id, "exportedAt": value["exportedAt"],
            "transcriptStatus": status, "segments": sorted(normalized, key=lambda item: item["manifest"]["id"])}


def _preflight_zip(source, limits):
    """Bound the central directory before zipfile constructs its entry objects."""
    size = os.fstat(source.fileno()).st_size
    if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
        raise BridgeError("invalid_archive", "The source must be a regular ZIP file.")
    if size > limits.max_archive_bytes:
        raise BridgeError("limit_exceeded", "ZIP exceeds the archive size limit.")
    source.seek(max(0, size - 65557))
    tail = source.read(65557)
    offset = tail.rfind(b"PK\x05\x06")
    if offset < 0 or offset + 22 > len(tail):
        raise BridgeError("invalid_archive", "Missing ZIP end-of-directory record.")
    _, disk, directory_disk, disk_count, count, directory_size, directory_offset, comment = struct.unpack(
        "<4s4H2LH", tail[offset:offset + 22])
    if offset + 22 + comment != len(tail) or disk != 0 or directory_disk != 0 or disk_count != count:
        raise BridgeError("invalid_archive", "Split or malformed ZIP archives are not supported.")
    end_offset = size - len(tail) + offset
    if count == 65535 or directory_size == 0xffffffff or directory_offset == 0xffffffff:
        # ZIP64 is permitted, but its counts/sizes must still fit the configured limits.
        if end_offset < 20:
            raise BridgeError("invalid_archive", "Invalid ZIP64 locator.")
        source.seek(end_offset - 20)
        locator = source.read(20)
        signature, zip64_disk, zip64_offset, disks = struct.unpack("<4sLQL", locator)
        if signature != b"PK\x06\x07" or zip64_disk != 0 or disks != 1:
            raise BridgeError("invalid_archive", "Invalid ZIP64 locator.")
        source.seek(zip64_offset)
        record = source.read(56)
        if len(record) != 56:
            raise BridgeError("invalid_archive", "Invalid ZIP64 directory.")
        signature, record_size, _, _, disk, directory_disk, disk_count, count, directory_size, directory_offset = struct.unpack(
            "<4sQ2H2L4Q", record)
        if signature != b"PK\x06\x06" or record_size < 44 or disk != 0 or directory_disk != 0 or disk_count != count:
            raise BridgeError("invalid_archive", "Invalid ZIP64 directory.")
        end_offset = zip64_offset
    if count > limits.max_segments + 4 or directory_size > (limits.max_segments + 4) * 2048:
        raise BridgeError("limit_exceeded", "ZIP has too many members or an oversized central directory.")
    if directory_offset + directory_size != end_offset:
        raise BridgeError("invalid_archive", "ZIP central directory boundaries are inconsistent.")
    source.seek(0)


def _zip_inventory(archive, limits):
    entries = archive.infolist()
    if len(entries) > limits.max_segments + 4:
        raise BridgeError("limit_exceeded", "ZIP has too many members.")
    names, total = {}, 0
    for info in entries:
        name = info.orig_filename
        if (name != info.filename or "\x00" in name or "\\" in name or name.startswith("/")
                or len(name) > 300 or any(part in ("", ".", "..") for part in name.rstrip("/").split("/"))):
            raise BridgeError("invalid_archive", "ZIP contains an unsafe member path.")
        if name in names:
            raise BridgeError("invalid_archive", "ZIP contains duplicate member names.")
        mode = stat.S_IFMT(info.external_attr >> 16)
        if mode not in (0, stat.S_IFDIR if info.is_dir() else stat.S_IFREG):
            raise BridgeError("invalid_archive", "ZIP links and special files are not accepted.")
        if info.flag_bits & 1 or info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            raise BridgeError("invalid_archive", "Encrypted or unsupported ZIP compression is not accepted.")
        if info.is_dir() and info.file_size:
            raise BridgeError("invalid_archive", "ZIP directory entries must be empty.")
        if info.file_size > limits.max_file_bytes:
            raise BridgeError("limit_exceeded", "A ZIP member exceeds the file size limit.")
        if info.file_size > max(info.compress_size, 1) * limits.max_compression_ratio:
            raise BridgeError("limit_exceeded", "A ZIP member exceeds the compression expansion limit.")
        total += info.file_size
        if total > limits.max_total_bytes:
            raise BridgeError("limit_exceeded", "ZIP exceeds the total expanded size limit.")
        names[name] = info
    exports = [name for name in names if name == "export.json" or re.fullmatch(r"[A-Za-z0-9_-]+/export\.json", name)]
    if len(exports) != 1:
        raise BridgeError("invalid_archive", "Expected one export.json, at the root or inside one top-level folder.")
    prefix = exports[0][:-len("export.json")]
    members = {}
    for name, info in names.items():
        if prefix and not name.startswith(prefix):
            raise BridgeError("invalid_archive", "All ZIP members must share the single top-level folder.")
        relative = name[len(prefix):]
        if info.is_dir():
            if relative not in ("", "audio/"):
                raise BridgeError("invalid_archive", "Unexpected directory in export ZIP.")
        else:
            members[relative] = info
    return members


def _stream_member(archive, info, maximum, destination=None):
    digest, count, parts = hashlib.sha256(), 0, []
    with archive.open(info) as incoming:
        while True:
            chunk = incoming.read(min(CHUNK, maximum - count + 1))
            if not chunk:
                break
            count += len(chunk)
            if count > maximum:
                raise BridgeError("limit_exceeded", "Expanded member exceeded its allowed size.")
            digest.update(chunk)
            if destination is None:
                parts.append(chunk)
            else:
                destination.write(chunk)
    if count != info.file_size:
        raise BridgeError("invalid_archive", "Expanded size does not match ZIP metadata.")
    return count, digest.hexdigest(), b"".join(parts) if destination is None else None


def _stage_export(package, staging, limits):
    try:
        with open(package, "rb") as source:
            _preflight_zip(source, limits)
            with zipfile.ZipFile(source) as archive:
                members = _zip_inventory(archive, limits)
                if "export.json" not in members or "README.md" not in members:
                    raise BridgeError("invalid_archive", "Both export.json and README.md are required.")
                _, _, metadata = _stream_member(archive, members["export.json"], limits.max_metadata_bytes)
                envelope = validate_export(parse_json(metadata), limits)
                expected = {"export.json", "README.md"} | {item["audioPath"] for item in envelope["segments"]}
                if set(members) != expected:
                    raise BridgeError("invalid_archive", "ZIP members must exactly match the explicitly selected audio files.")
                _, _, readme = _stream_member(archive, members["README.md"], limits.max_readme_bytes)
                try:
                    readme.decode("utf-8")
                except UnicodeDecodeError as error:
                    raise BridgeError("invalid_archive", "README.md must be UTF-8 text.") from error
                for item in envelope["segments"]:
                    manifest = item["manifest"]
                    info = members[item["audioPath"]]
                    if info.file_size != manifest["byteCount"]:
                        raise BridgeError("integrity_mismatch", "Audio size differs from its selected manifest.")
                    target = staging / manifest["fileName"]
                    with open(target, "xb") as output:
                        os.chmod(target, 0o600)
                        count, sha256, _ = _stream_member(archive, info, manifest["byteCount"], output)
                        output.flush()
                        os.fsync(output.fileno())
                    if count != manifest["byteCount"] or sha256 != manifest["sha256"]:
                        raise BridgeError("integrity_mismatch", "Audio SHA-256 differs from its selected manifest.")
                return envelope
    except (zipfile.BadZipFile, zipfile.LargeZipFile, EOFError, RuntimeError, struct.error, NotImplementedError) as error:
        raise BridgeError("invalid_archive", "ZIP data is invalid or unsupported.") from error


def _regular_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise BridgeError("library_corrupt", "Library files must be regular files without links.")


def _directory(path):
    if not stat.S_ISDIR(path.lstat().st_mode):
        raise BridgeError("library_corrupt", "Library directories must not be symbolic links.")


def _sync_directory(path):
    descriptor = os.open(str(path), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _verify_object(path, manifest):
    _directory(path.parent)
    _regular_file(path)
    descriptor = os.open(str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    digest, count = hashlib.sha256(), 0
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size != manifest["byteCount"]:
            raise BridgeError("integrity_mismatch", "Imported audio file size or file type changed.")
        while True:
            chunk = source.read(CHUNK)
            if not chunk:
                break
            count += len(chunk)
            if count > manifest["byteCount"]:
                raise BridgeError("integrity_mismatch", "Imported audio file grew during validation.")
            digest.update(chunk)
    if count != manifest["byteCount"] or digest.hexdigest() != manifest["sha256"]:
        raise BridgeError("integrity_mismatch", "Imported audio no longer matches its SHA-256 manifest.")


def _connect(root, writable=False):
    path = root / DB_NAME
    if not path.exists() and not writable:
        raise BridgeError("library_not_found", "Import a selected recording ZIP into this library first.")
    if path.exists() or path.is_symlink():
        _regular_file(path)
    _directory(root)
    connection = sqlite3.connect(str(path) if writable else path.as_uri() + "?mode=ro", uri=not writable,
                                 timeout=5, isolation_level=None)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys=ON")
    if writable:
        os.chmod(path, 0o600)
        connection.execute("PRAGMA synchronous=FULL")
    else:
        connection.execute("PRAGMA query_only=ON")
    return connection


SCHEMA = (
    "CREATE TABLE recordings (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, sequence INTEGER NOT NULL, "
    "started_at INTEGER NOT NULL, ended_at INTEGER NOT NULL, manifest_json TEXT NOT NULL, "
    "UNIQUE(session_id, sequence))",
    "CREATE TABLE exports (id TEXT PRIMARY KEY, digest TEXT NOT NULL, imported_at INTEGER NOT NULL)",
    "CREATE TABLE export_members (export_id TEXT NOT NULL REFERENCES exports(id), "
    "recording_id TEXT NOT NULL REFERENCES recordings(id), PRIMARY KEY(export_id, recording_id))",
    "CREATE INDEX recording_order ON recordings(started_at, id)",
)
TRANSCRIPT_SCHEMA = (
    "CREATE TABLE transcripts (recording_id TEXT PRIMARY KEY REFERENCES recordings(id), "
    "transcript_json TEXT NOT NULL, search_text TEXT NOT NULL)",
)


def _schema(connection, create=False):
    version = connection.execute("PRAGMA user_version").fetchone()[0]
    if version == 0 and create:
        if connection.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchone():
            raise BridgeError("library_corrupt", "This database is not an empty Record for Agent library.")
        for statement in SCHEMA:
            connection.execute(statement)
        version = 1
    if version == 1 and create:
        # The caller's BEGIN IMMEDIATE covers DDL, data and user_version together.
        for statement in TRANSCRIPT_SCHEMA:
            connection.execute(statement)
        connection.execute("PRAGMA user_version=2")
        version = 2
    elif version not in (1, 2):
        raise BridgeError("library_corrupt", "Unsupported library schema version.")
    return version


def import_package(package, library, limits=None):
    """Validate every archive member before publishing any recording catalog rows."""
    limits = limits or Limits()
    root = Path(library).expanduser().absolute()
    # The caller chooses the library, never archive content. Refuse existing symlink roots.
    if root.exists() or root.is_symlink():
        _directory(root)
    root.parent.mkdir(parents=True, exist_ok=True)
    root = root.parent.resolve() / root.name
    with tempfile.TemporaryDirectory(prefix=".recordforagent-import-", dir=str(root.parent)) as temporary:
        staging = Path(temporary)
        envelope = _stage_export(Path(package).expanduser(), staging, limits)
        # No catalog or object writes occur until all entries, CRCs, sizes and hashes pass.
        root.mkdir(mode=0o700, exist_ok=True)
        _directory(root)
        objects = root / "objects"
        objects.mkdir(mode=0o700, exist_ok=True)
        _directory(objects)
        connection = _connect(root, writable=True)
        digest = hashlib.sha256(canonical_json(envelope).encode("utf-8")).hexdigest()
        try:
            connection.execute("BEGIN IMMEDIATE")
            _schema(connection, create=True)
            prior = connection.execute("SELECT digest FROM exports WHERE id=?", (envelope["exportID"],)).fetchone()
            if prior and prior[0] != digest:
                raise BridgeError("conflict", "An existing export ID has different metadata or a different selection.")
            additions, transcript_additions, transcript_count = [], [], 0
            for item in envelope["segments"]:
                manifest = item["manifest"]
                existing = connection.execute("SELECT manifest_json FROM recordings WHERE id=?", (manifest["id"],)).fetchone()
                if existing and existing[0] != canonical_json(manifest):
                    raise BridgeError("conflict", "An existing segment ID has different content or metadata.")
                position = connection.execute("SELECT id FROM recordings WHERE session_id=? AND sequence=?",
                                              (manifest["sessionID"], manifest["sequence"])).fetchone()
                if position and position[0] != manifest["id"]:
                    raise BridgeError("conflict", "A session sequence already belongs to a different segment ID.")
                if existing:
                    _verify_object(objects / manifest["id"] / manifest["fileName"], manifest)
                else:
                    additions.append(manifest)
                prior_transcript = connection.execute("SELECT transcript_json, search_text FROM transcripts WHERE recording_id=?",
                                                      (manifest["id"],)).fetchone()
                if prior_transcript:
                    _transcript_from_row(prior_transcript, manifest)
                transcript = item.get("transcript")
                if prior_transcript and transcript and prior_transcript[0] != canonical_json(transcript):
                    raise BridgeError("conflict", "An existing segment has a different transcript; replacement is not supported.")
                if transcript and not prior_transcript:
                    transcript_additions.append((manifest["id"], canonical_json(transcript), transcript["text"].casefold()))
                if prior_transcript or transcript:
                    transcript_count += 1
            for manifest in additions:
                target_directory = objects / manifest["id"]
                target = target_directory / manifest["fileName"]
                if target_directory.exists() or target_directory.is_symlink():
                    # A process killed before commit may leave an unreferenced complete object.
                    _verify_object(target, manifest)
                else:
                    # Atomic directory rename leaves no link/unlink crash window.
                    # Existing nonempty object directories cannot be overwritten.
                    temporary_name = tempfile.mkdtemp(prefix=".import-", dir=str(objects))
                    try:
                        staged_object = Path(temporary_name) / manifest["fileName"]
                        with open(staged_object, "xb") as output:
                            os.chmod(staged_object, 0o600)
                            with open(staging / manifest["fileName"], "rb") as incoming:
                                shutil.copyfileobj(incoming, output, CHUNK)
                            output.flush()
                            os.fsync(output.fileno())
                        _sync_directory(Path(temporary_name))
                        os.rename(temporary_name, target_directory)
                    finally:
                        if os.path.exists(temporary_name):
                            shutil.rmtree(temporary_name)
                connection.execute("INSERT INTO recordings VALUES (?,?,?,?,?,?)", (manifest["id"], manifest["sessionID"],
                                   manifest["sequence"], manifest["startedAt"], manifest["endedAt"], canonical_json(manifest)))
            connection.executemany("INSERT INTO transcripts VALUES (?,?,?)", transcript_additions)
            _sync_directory(objects)
            if not prior:
                connection.execute("INSERT INTO exports VALUES (?,?,?)", (envelope["exportID"], digest, int(time.time() * 1000)))
                connection.executemany("INSERT INTO export_members VALUES (?,?)",
                                       [(envelope["exportID"], item["manifest"]["id"]) for item in envelope["segments"]])
            # Finish our fallible directory durability operations before publication.
            # SQLite synchronous=FULL performs its own commit/journal synchronization.
            _sync_directory(root)
            connection.execute("COMMIT")
            return {"ok": True, "exportID": envelope["exportID"], "status": "unchanged" if prior else "imported",
                    "importedSegments": len(additions), "existingSegments": len(envelope["segments"]) - len(additions),
                    "selectedSegments": len(envelope["segments"]), "importedTranscripts": len(transcript_additions),
                    "readyTranscripts": transcript_count,
                    "transcriptStatus": _transcript_status(transcript_count, len(envelope["segments"])),
                    "exportedTranscriptStatus": envelope["transcriptStatus"]}
        finally:
            if connection.in_transaction:
                connection.execute("ROLLBACK")
            connection.close()
            # An interrupted transaction may leave verified, unreferenced objects.
            # Never delete them here after releasing the DB lock: another importer
            # could already have reused them. MCP reads only committed catalog rows.


def _decode_cursor(cursor, from_ms, to_ms):
    if not isinstance(cursor, str) or len(cursor) > 1024:
        raise BridgeError("invalid_cursor", "Cursor must be the bounded string returned by list_recordings.")
    try:
        value = parse_json(base64.b64decode(cursor.encode("ascii"), altchars=b"-_", validate=True))
        if (not isinstance(value, dict) or set(value) != {"v", "after", "from_ms", "to_ms"}
                or type(value["v"]) is not int or value["v"] != 1):
            raise ValueError()
        if value["from_ms"] != from_ms or value["to_ms"] != to_ms:
            raise ValueError()
        after = value["after"]
        if not isinstance(after, list) or len(after) != 2:
            raise ValueError()
        _integer(after[0], "cursor timestamp")
        return after[0], canonical_uuid(after[1])
    except (BridgeError, ValueError, UnicodeError, TypeError) as error:
        raise BridgeError("invalid_cursor", "Cursor is invalid or its time filters have changed.") from error


def _manifest_from_row(row):
    manifest = validate_manifest(parse_json(row["manifest_json"]), 2**63 - 1)
    if (manifest["id"], manifest["sessionID"], manifest["sequence"], manifest["startedAt"], manifest["endedAt"]) != (
            row["id"], row["session_id"], row["sequence"], row["started_at"], row["ended_at"]):
        raise BridgeError("library_corrupt", "Catalog metadata does not match its manifest.")
    return manifest


def _recording_query(connection):
    if connection.execute("PRAGMA user_version").fetchone()[0] == 1:
        # Serving an existing v1 library remains strictly read-only; migrate only on import.
        return "SELECT recordings.*, NULL AS transcript_json, NULL AS search_text FROM recordings"
    return ("SELECT recordings.*, transcripts.transcript_json, transcripts.search_text FROM recordings "
            "LEFT JOIN transcripts ON recordings.id=transcripts.recording_id")


def _transcript_from_row(row, manifest):
    if row["transcript_json"] is None:
        return None
    transcript = validate_transcript(parse_json(row["transcript_json"]), manifest)
    if transcript["text"].casefold() != row["search_text"]:
        raise BridgeError("library_corrupt", "Transcript search text does not match the stored transcript.")
    return transcript


def _summary_from_row(row):
    manifest = _manifest_from_row(row)
    transcript = _transcript_from_row(row, manifest)
    return {"recordingID": manifest["id"], "sessionID": manifest["sessionID"],
            "sequence": manifest["sequence"], **recording_metadata(manifest),
            "durationSeconds": manifest["frameCount"] / manifest["sampleRate"],
            "byteCount": manifest["byteCount"], "transcriptStatus": "ready" if transcript else "not_generated"}


class Library:
    def __init__(self, root):
        self.root = Path(root).expanduser().absolute()

    @contextlib.contextmanager
    def _read(self):
        if not self.root.exists():
            raise BridgeError("library_not_found", "Import a selected recording ZIP into this library first.")
        _directory(self.root)
        _directory(self.root / "objects")
        connection = _connect(self.root)
        try:
            connection.execute("BEGIN")
            _schema(connection)
            yield connection
        finally:
            if connection.in_transaction:
                connection.execute("ROLLBACK")
            connection.close()

    def list_recordings(self, arguments):
        if set(arguments) - {"from_ms", "to_ms", "cursor", "limit"}:
            raise BridgeError("invalid_arguments", "Unknown list_recordings argument.")
        limit = arguments.get("limit", 25)
        if type(limit) is not int or not 1 <= limit <= 100:
            raise BridgeError("invalid_arguments", "limit must be an integer from 1 to 100.")
        from_ms, to_ms = arguments.get("from_ms"), arguments.get("to_ms")
        for value in (from_ms, to_ms):
            if value is not None and (type(value) is not int or not 0 <= value <= MAX_TIMESTAMP):
                raise BridgeError("invalid_arguments", "Time filters must be nonnegative Unix milliseconds.")
        if from_ms is not None and to_ms is not None and from_ms >= to_ms:
            raise BridgeError("invalid_arguments", "from_ms must be earlier than to_ms.")
        where, parameters = [], []
        if from_ms is not None:
            where.append("started_at>=?")
            parameters.append(from_ms)
        if to_ms is not None:
            where.append("started_at<?")
            parameters.append(to_ms)
        if "cursor" in arguments:
            timestamp, identifier = _decode_cursor(arguments["cursor"], from_ms, to_ms)
            where.append("(started_at>? OR (started_at=? AND id>?))")
            parameters.extend([timestamp, timestamp, identifier])
        with self._read() as connection:
            sql = _recording_query(connection) + (" WHERE " + " AND ".join(where) if where else "")
            rows = connection.execute(sql + " ORDER BY started_at, id LIMIT ?", parameters + [limit + 1]).fetchall()
        recordings = [_summary_from_row(row) for row in rows[:limit]]
        result = {"recordings": recordings, "selectionScope": "authorized_imported_segments_only", "nextCursor": None}
        if len(rows) > limit:
            last = rows[limit - 1]
            token = {"v": 1, "after": [last["started_at"], last["id"]], "from_ms": from_ms, "to_ms": to_ms}
            result["nextCursor"] = base64.urlsafe_b64encode(canonical_json(token).encode("utf-8")).decode("ascii")
        return result

    def _get(self, arguments):
        if set(arguments) != {"recording_id"}:
            raise BridgeError("invalid_arguments", "Exactly one recording_id UUID is required.")
        try:
            identifier = canonical_uuid(arguments["recording_id"], "recording_id")
        except BridgeError as error:
            raise BridgeError("invalid_arguments", error.message) from error
        with self._read() as connection:
            row = connection.execute(_recording_query(connection) + " WHERE id=?", (identifier,)).fetchone()
        if row is None:
            raise BridgeError("not_found", "This recording is not in the explicitly imported selection.")
        manifest = _manifest_from_row(row)
        return manifest, _transcript_from_row(row, manifest)

    def get_recording(self, arguments):
        manifest, transcript = self._get(arguments)
        return {"recordingID": manifest["id"], "manifest": manifest, **recording_metadata(manifest),
                "durationSeconds": manifest["frameCount"] / manifest["sampleRate"],
                "transcriptStatus": "ready" if transcript else "not_generated", "selectionScope": "authorized_imported_segments_only",
                "integrity": "verified_at_import; use get_audio_asset to recheck current bytes"}

    def get_transcript(self, arguments):
        manifest, transcript = self._get(arguments)
        return {"recordingID": manifest["id"], "audioSHA256": manifest["sha256"], **recording_metadata(manifest),
                "transcriptStatus": "ready" if transcript else "not_generated", "transcript": transcript,
                "selectionScope": "authorized_imported_segments_only"}

    def search_recordings(self, arguments):
        if set(arguments) - {"query", "limit", "cursor"} or "query" not in arguments:
            raise BridgeError("invalid_arguments", "Search requires query and accepts only limit and cursor.")
        try:
            query = _text(arguments["query"], "query", 1024).strip().casefold()
        except BridgeError as error:
            raise BridgeError("invalid_arguments", error.message) from error
        limit = arguments.get("limit", 25)
        if type(limit) is not int or not 1 <= limit <= 100:
            raise BridgeError("invalid_arguments", "limit must be an integer from 1 to 100.")
        query_digest = hashlib.sha256(query.encode("utf-8")).hexdigest()
        where, parameters = ["instr(search_text, ?) > 0"], [query]
        if "cursor" in arguments:
            cursor = arguments["cursor"]
            try:
                if not isinstance(cursor, str) or len(cursor) > 1024:
                    raise ValueError()
                value = parse_json(base64.b64decode(cursor.encode("ascii"), altchars=b"-_", validate=True))
                if (not isinstance(value, dict) or set(value) != {"v", "after", "querySHA256"}
                        or type(value["v"]) is not int or value["v"] != 1 or value["querySHA256"] != query_digest):
                    raise ValueError()
                after = value["after"]
                if not isinstance(after, list) or len(after) != 2:
                    raise ValueError()
                timestamp, identifier = _integer(after[0], "cursor timestamp"), canonical_uuid(after[1])
            except (BridgeError, ValueError, UnicodeError, TypeError) as error:
                raise BridgeError("invalid_cursor", "Search cursor is invalid or its query has changed.") from error
            where.append("(started_at>? OR (started_at=? AND id>?))")
            parameters.extend([timestamp, timestamp, identifier])
        with self._read() as connection:
            if connection.execute("PRAGMA user_version").fetchone()[0] == 1:
                rows = []
            else:
                rows = connection.execute(_recording_query(connection) + " WHERE " + " AND ".join(where)
                                          + " ORDER BY started_at, id LIMIT ?", parameters + [limit + 1]).fetchall()
        result = {"recordings": [_summary_from_row(row) for row in rows[:limit]], "nextCursor": None,
                  "selectionScope": "authorized_imported_segments_only", "searchMode": "transcript_literal_casefold"}
        if len(rows) > limit:
            last = rows[limit - 1]
            token = {"v": 1, "after": [last["started_at"], last["id"]], "querySHA256": query_digest}
            result["nextCursor"] = base64.urlsafe_b64encode(canonical_json(token).encode("utf-8")).decode("ascii")
        return result

    def get_audio_asset(self, arguments):
        manifest, transcript = self._get(arguments)
        objects = self.root / "objects"
        _directory(objects)
        path = objects / manifest["id"] / manifest["fileName"]
        _verify_object(path, manifest)
        return {"recordingID": manifest["id"], "localPath": str(path), "mimeType": "audio/x-caf", **recording_metadata(manifest),
                "byteCount": manifest["byteCount"], "sha256": manifest["sha256"], "integrity": "verified_now",
                "transcriptStatus": "ready" if transcript else "not_generated", "audioDecoded": False,
                "note": "Local CAF file reference only. No audio bytes or transcript are returned."}
