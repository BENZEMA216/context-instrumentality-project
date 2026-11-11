#!/usr/bin/env python3
"""Paired HTTPS ingestion and durable, content-free new-recording notifications.

This process owns transport and delivery only. It never chooses an Agent task or
interprets a transcript. Existing MCP clients continue reading the same library.
"""

import argparse
import contextlib
import fcntl
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import os
from pathlib import Path
import re
import socket
from socketserver import ThreadingMixIn
import sqlite3
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid

from bridge import safe_error
from library import (BridgeError, CHUNK, DB_NAME, Limits, canonical_json,
                     canonical_uuid, import_package, parse_json, recording_metadata, validate_manifest)


STATE_DB = "delivery.sqlite3"
HASH = re.compile(r"^[a-f0-9]{64}$")
TOKEN = re.compile(r"^[A-Za-z0-9_-]{43}$")
MAX_EVENTS = 100


def now_ms():
    return int(time.time() * 1000)


def private_directory(path):
    path = Path(path).expanduser().absolute()
    if path.is_symlink():
        raise BridgeError("unsafe_path", "State directories must not be symbolic links.")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_dir() or path.stat().st_mode & 0o077:
        raise BridgeError("unsafe_permissions", "State directories must have mode 0700.")
    return path


def private_file(path):
    path = Path(path).expanduser().absolute()
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_mode & 0o077:
        raise BridgeError("unsafe_permissions", "Credential and state files must be regular private files (0600).")
    return path


def sync_directory(path):
    descriptor = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def hash_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


class DeliveryStore:
    def __init__(self, state, library, receiver_id, limits=None):
        self.root = private_directory(state)
        self.spool = private_directory(self.root / "spool")
        self.library = Path(library).expanduser().absolute()
        self.receiver_id = canonical_uuid(receiver_id, "receiverID")
        self.limits = limits or Limits()
        database = self.root / STATE_DB
        if database.exists() or database.is_symlink():
            private_file(database)
        else:
            descriptor = os.open(str(database), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.close(descriptor)
        self.database = database
        with self.connect() as connection:
            connection.executescript("""
              CREATE TABLE IF NOT EXISTS identity (singleton INTEGER PRIMARY KEY CHECK(singleton=1), receiver_id TEXT NOT NULL, library TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS requests (id TEXT PRIMARY KEY, archive_hash TEXT NOT NULL, receipt_json TEXT, failure_json TEXT);
              CREATE TABLE IF NOT EXISTS versions (recording_id TEXT NOT NULL, fingerprint TEXT NOT NULL, PRIMARY KEY(recording_id, fingerprint));
              CREATE TABLE IF NOT EXISTS events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, event_json TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS deliveries (target TEXT NOT NULL, event_id TEXT NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0, acknowledgement_json TEXT, PRIMARY KEY(target,event_id));
            """)
            connection.execute("INSERT OR IGNORE INTO identity VALUES (1,?,?)", (self.receiver_id, str(self.library)))
            row = connection.execute("SELECT receiver_id,library FROM identity WHERE singleton=1").fetchone()
            if tuple(row) != (self.receiver_id, str(self.library)):
                raise BridgeError("identity_mismatch", "A state directory cannot be reassigned to a different receiver or library.")
        sync_directory(self.root)

    @contextlib.contextmanager
    def connect(self):
        private_file(self.database)
        connection = sqlite3.connect(str(self.database), timeout=30)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA synchronous=FULL")
        try:
            yield connection
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()

    def _prior(self, delivery_id, archive_hash):
        with self.connect() as connection:
            row = connection.execute("SELECT * FROM requests WHERE id=?", (delivery_id,)).fetchone()
        if row is not None and row["archive_hash"] != archive_hash:
            raise BridgeError("delivery_conflict", "This deliveryID already belongs to different archive bytes.")
        if row is not None and row["failure_json"]:
            failure = parse_json(row["failure_json"])["error"]
            raise BridgeError(failure["code"], failure["message"])
        return parse_json(row["receipt_json"]) if row and row["receipt_json"] else None

    def accept(self, source, length, delivery_id, archive_hash):
        with self.upload_lock():
            return self._accept_locked(source, length, delivery_id, archive_hash)

    @contextlib.contextmanager
    def upload_lock(self):
        lock_path = self.root / "upload.lock"
        descriptor = os.open(str(lock_path), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            private_file(lock_path)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            os.close(descriptor)

    def _accept_locked(self, source, length, delivery_id, archive_hash):
        delivery_id = canonical_uuid(delivery_id, "deliveryID")
        if not isinstance(archive_hash, str) or not HASH.fullmatch(archive_hash):
            raise BridgeError("invalid_arguments", "X-Archive-SHA256 must be a lowercase SHA-256 digest.")
        if type(length) is not int or not 0 < length <= self.limits.max_archive_bytes:
            raise BridgeError("limit_exceeded", "The archive length is outside the configured bounds.")
        prior = self._prior(delivery_id, archive_hash)
        temporary = None
        try:
            descriptor, temporary = tempfile.mkstemp(prefix=".upload-", dir=str(self.spool))
            digest = hashlib.sha256()
            with os.fdopen(descriptor, "wb") as output:
                remaining = length
                while remaining:
                    chunk = source.read(min(CHUNK, remaining))
                    if not chunk:
                        raise BridgeError("incomplete_upload", "The archive ended before its Content-Length.")
                    output.write(chunk)
                    digest.update(chunk)
                    remaining -= len(chunk)
                output.flush()
                os.fsync(output.fileno())
            if digest.hexdigest() != archive_hash:
                raise BridgeError("integrity_mismatch", "The received archive does not match X-Archive-SHA256.")
            if prior is not None:
                return prior
            target = self.spool / (delivery_id + ".zip")
            if target.exists() or target.is_symlink():
                private_file(target)
                if hash_file(target) != archive_hash:
                    raise BridgeError("delivery_conflict", "A pending deliveryID already belongs to different archive bytes.")
            else:
                # The upload lock serializes receivers. Atomic rename never leaves
                # the archive hard-linked if the process exits between operations.
                os.rename(temporary, target)
                temporary = None
                sync_directory(self.spool)
            with self.connect() as connection:
                connection.execute("INSERT OR IGNORE INTO requests VALUES (?,?,NULL,NULL)", (delivery_id, archive_hash))
                row = connection.execute("SELECT archive_hash FROM requests WHERE id=?", (delivery_id,)).fetchone()
                if row[0] != archive_hash:
                    raise BridgeError("delivery_conflict", "This deliveryID already belongs to different archive bytes.")
            return self._finish(delivery_id, archive_hash)
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)

    def _members(self, export_id):
        # Read only the exact export that this paired upload successfully imported.
        uri = (self.library / DB_NAME).as_uri() + "?mode=ro"
        connection = sqlite3.connect(uri, uri=True)
        connection.row_factory = sqlite3.Row
        try:
            return connection.execute("""SELECT r.id,r.started_at,r.ended_at,r.manifest_json,t.transcript_json
              FROM export_members m JOIN recordings r ON r.id=m.recording_id
              LEFT JOIN transcripts t ON t.recording_id=r.id WHERE m.export_id=? ORDER BY r.started_at,r.id""", (export_id,)).fetchall()
        finally:
            connection.close()

    def _finish(self, delivery_id, archive_hash):
        prior = self._prior(delivery_id, archive_hash)
        if prior is not None:
            return prior
        package = private_file(self.spool / (delivery_id + ".zip"))
        if hash_file(package) != archive_hash:
            raise BridgeError("integrity_mismatch", "The pending archive changed before recovery.")
        try:
            imported = import_package(package, self.library, self.limits)
        except BridgeError as error:
            if error.code not in {"io_error", "library_error"}:
                with self.connect() as connection:
                    connection.execute("UPDATE requests SET failure_json=? WHERE id=?", (canonical_json(error.payload()), delivery_id))
            raise
        members = self._members(imported["exportID"])
        stored_at = now_ms()
        receipt = {"schemaVersion": 1, "receiverID": self.receiver_id, "deliveryID": delivery_id,
                   "archiveSHA256": archive_hash, "recordingIDs": [row["id"] for row in members], "storedAt": stored_at}
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute("SELECT receipt_json FROM requests WHERE id=?", (delivery_id,)).fetchone()
            if row[0]:
                receipt = parse_json(row[0])
            else:
                self._enqueue_members(connection, members, stored_at)
                connection.execute("UPDATE requests SET receipt_json=? WHERE id=?", (canonical_json(receipt), delivery_id))
        # Receipt and notification outbox are durable together. A crash before this
        # cleanup only leaves the already-acknowledged archive, never loses an event.
        package.unlink()
        sync_directory(self.spool)
        return receipt

    def recover(self):
        with self.upload_lock():
            with self.connect() as connection:
                pending = connection.execute("SELECT id,archive_hash FROM requests WHERE receipt_json IS NULL AND failure_json IS NULL ORDER BY rowid").fetchall()
                finished = connection.execute("SELECT id,archive_hash FROM requests WHERE receipt_json IS NOT NULL OR failure_json IS NOT NULL").fetchall()
            recovered = 0
            for row in pending:
                self._finish(row["id"], row["archive_hash"])
                recovered += 1
            # A process exit after COMMIT can leave a redundant spool copy. Only
            # our own acknowledged/rejected exact-hash copies are eligible here.
            for row in finished:
                path = self.spool / (row["id"] + ".zip")
                if path.exists() or path.is_symlink():
                    private_file(path)
                    if hash_file(path) != row["archive_hash"]:
                        raise BridgeError("integrity_mismatch", "A completed spool archive changed before cleanup.")
                    path.unlink()
            sync_directory(self.spool)
            return recovered

    def authorized_recording_ids(self):
        """Only IDs acknowledged by this paired receiver, never preexisting imports."""
        with self.connect() as connection:
            rows = connection.execute("SELECT receipt_json FROM requests WHERE receipt_json IS NOT NULL").fetchall()
        return sorted({identifier for row in rows for identifier in parse_json(row[0])["recordingIDs"]})

    def _enqueue_members(self, connection, members, available_at):
        changes, revisions = [], []
        for row in members:
            if not row["transcript_json"]:
                continue  # Audio is durable, but the Agent is notified when it can read text.
            manifest = validate_manifest(parse_json(row["manifest_json"]), self.limits.max_file_bytes)
            revision = hashlib.sha256((manifest["sha256"] + ":" + row["transcript_json"]).encode()).hexdigest()
            inserted = connection.execute("INSERT OR IGNORE INTO versions VALUES (?,?)", (row["id"], revision)).rowcount
            if inserted:
                revisions.append(row["id"] + ":" + revision)
                changes.append({"recordingID": row["id"], **recording_metadata(manifest), "transcriptStatus": "ready"})
        if not changes:
            return 0
        event_id = str(uuid.uuid5(uuid.UUID(self.receiver_id), "\n".join(sorted(revisions))))
        event = {"schemaVersion": 1, "type": "recordings.available", "eventID": event_id,
                 "receiverID": self.receiver_id, "availableAt": available_at, "recordings": changes,
                 "source": {"mcpServer": "record-for-agent", "recordingTool": "get_recording", "transcriptTool": "get_transcript"}}
        connection.execute("INSERT INTO events(id,event_json) VALUES (?,?)", (event_id, canonical_json(event)))
        return len(changes)

    def enqueue_available(self, identifiers):
        """Publish ready IDs after a local ASR worker imports matching transcripts."""
        if not isinstance(identifiers, (list, tuple)) or not identifiers or len(identifiers) > 500:
            raise BridgeError("invalid_arguments", "Supply between 1 and 500 acknowledged recording IDs.")
        identifiers = sorted({canonical_uuid(identifier) for identifier in identifiers})
        if not set(identifiers).issubset(self.authorized_recording_ids()):
            raise BridgeError("not_authorized", "Only recordings acknowledged by this receiver can generate automatic events.")
        connection = sqlite3.connect((self.library / DB_NAME).as_uri() + "?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        try:
            members = connection.execute("""SELECT r.id,r.started_at,r.ended_at,r.manifest_json,t.transcript_json
              FROM recordings r LEFT JOIN transcripts t ON t.recording_id=r.id WHERE r.id IN (""" + ",".join("?" * len(identifiers)) + ") ORDER BY r.started_at,r.id", identifiers).fetchall()
        finally:
            connection.close()
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            return self._enqueue_members(connection, members, now_ms())

    def pending(self, target, limit=MAX_EVENTS, at=None):
        if not isinstance(target, str) or not target or len(target) > 256:
            raise BridgeError("invalid_arguments", "An explicit bounded client target is required.")
        if type(limit) is not int or not 1 <= limit <= MAX_EVENTS:
            raise BridgeError("invalid_arguments", "The event limit must be between 1 and 100.")
        at = now_ms() if at is None else at
        with self.connect() as connection:
            rows = connection.execute("""SELECT e.event_json FROM events e LEFT JOIN deliveries d ON d.event_id=e.id AND d.target=?
              WHERE d.status IS NULL OR (d.status='retry' AND d.next_attempt<=?) ORDER BY e.sequence LIMIT ?""", (target, at, limit)).fetchall()
        return [parse_json(row[0]) for row in rows]

    def claim(self, target, event_id):
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute("INSERT OR IGNORE INTO deliveries VALUES (?,?,'retry',0,0,NULL)", (target, event_id))
            return connection.execute("""UPDATE deliveries SET status='sending',attempts=attempts+1
              WHERE target=? AND event_id=? AND status='retry' AND next_attempt<=?""", (target, event_id, now_ms())).rowcount == 1

    def accepted(self, target, event_id, acknowledgement):
        with self.connect() as connection:
            connection.execute("UPDATE deliveries SET status='accepted',acknowledgement_json=? WHERE target=? AND event_id=? AND status='sending'",
                               (canonical_json(acknowledgement), target, event_id))

    def failed(self, target, event_id, uncertain=False):
        with self.connect() as connection:
            row = connection.execute("SELECT attempts FROM deliveries WHERE target=? AND event_id=?", (target, event_id)).fetchone()
            delay = min(3600, 2 ** min(row[0], 10) * 15)
            # Neither public client API documents exactly-once starts. An ambiguous
            # send is retained for reconciliation instead of silently starting twice.
            connection.execute("UPDATE deliveries SET status=?,next_attempt=? WHERE target=? AND event_id=? AND status='sending'",
                               ("uncertain" if uncertain else "retry", now_ms() + delay * 1000, target, event_id))

    def status(self):
        with self.connect() as connection:
            receipts = connection.execute("SELECT COUNT(*) FROM requests WHERE receipt_json IS NOT NULL").fetchone()[0]
            pending = connection.execute("SELECT COUNT(*) FROM requests WHERE receipt_json IS NULL AND failure_json IS NULL").fetchone()[0]
            rejected = connection.execute("SELECT COUNT(*) FROM requests WHERE failure_json IS NOT NULL").fetchone()[0]
            events = connection.execute("SELECT COUNT(*) FROM events").fetchone()[0]
            deliveries = [dict(row) for row in connection.execute("SELECT target,status,COUNT(*) AS count FROM deliveries GROUP BY target,status")]
        return {"receiverID": self.receiver_id, "durableReceipts": receipts, "pendingImports": pending, "rejectedImports": rejected, "events": events, "deliveries": deliveries}


def receiver_handler(store, token, on_import=None):
    if not TOKEN.fullmatch(token):
        raise BridgeError("invalid_token", "The receiver token must contain at least 256 bits of URL-safe random data.")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def setup(self):
            super().setup()
            self.connection.settimeout(60)

        def log_message(self, *_):
            pass  # HTTP metadata may contain secrets; do not record request lines.

        def reply(self, status, data):
            content = (canonical_json(data) + "\n").encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(content)
            self.close_connection = True

        def do_POST(self):
            if self.path == "/v1/transcripts/query":
                self.transcript_query()
                return
            try:
                if self.path != "/v1/imports":
                    self.reply(404, {"error": {"code": "not_found", "message": "Unknown receiver route."}})
                    return
                if (len(self.headers.get_all("Authorization", [])) != 1 or
                        not hmac.compare_digest(self.headers.get("Authorization", "").encode("utf-8"), ("Bearer " + token).encode("ascii"))):
                    self.reply(401, {"error": {"code": "unauthorized", "message": "Pair this device before uploading."}})
                    return
                if self.headers.get("Origin") is not None or self.headers.get("Transfer-Encoding") is not None:
                    raise BridgeError("invalid_arguments", "Browser requests and transfer encodings are not supported.")
                for field in ("Content-Length", "X-Delivery-ID", "X-Archive-SHA256", "Content-Type"):
                    if len(self.headers.get_all(field, [])) != 1:
                        raise BridgeError("invalid_arguments", "A required upload header is missing or repeated.")
                if self.headers["Content-Type"].lower() != "application/zip":
                    raise BridgeError("invalid_arguments", "Content-Type must be application/zip.")
                value = self.headers["Content-Length"]
                if not re.fullmatch(r"[0-9]{1,12}", value):
                    raise BridgeError("invalid_arguments", "Content-Length must be a bounded integer.")
                receipt = store.accept(self.rfile, int(value), self.headers["X-Delivery-ID"], self.headers["X-Archive-SHA256"])
                if on_import is not None:
                    on_import()
                self.reply(200, receipt)
            except (BridgeError, OSError, sqlite3.Error, ValueError) as error:
                error = safe_error(error)
                status = {"delivery_conflict": 409, "limit_exceeded": 413, "invalid_arguments": 400,
                          "invalid_schema": 422, "integrity_mismatch": 422}.get(error.code, 503)
                self.reply(status, error.payload())

        def transcript_query(self):
            # A separate, read-only route. Existing imports keep their original
            # request/receipt contract and never wait for ASR completion.
            from automatic_transcripts import MAX_QUERY_BYTES, query_transcripts
            try:
                if (len(self.headers.get_all("Authorization", [])) != 1 or
                        not hmac.compare_digest(self.headers.get("Authorization", "").encode("utf-8"), ("Bearer " + token).encode("ascii"))):
                    self.reply(401, {"error": {"code": "unauthorized", "message": "Pair this device before querying."}})
                    return
                if self.headers.get("Origin") is not None or self.headers.get("Transfer-Encoding") is not None:
                    raise BridgeError("invalid_arguments", "Invalid transcript request.")
                if (len(self.headers.get_all("Content-Length", [])) != 1 or
                        len(self.headers.get_all("Content-Type", [])) != 1 or
                        self.headers["Content-Type"].lower() != "application/json"):
                    raise BridgeError("invalid_arguments", "Invalid transcript request.")
                length = self.headers["Content-Length"]
                if not re.fullmatch(r"[0-9]{1,12}", length) or not 0 < int(length) <= MAX_QUERY_BYTES:
                    raise BridgeError("limit_exceeded", "Invalid transcript request length.")
                self.connection.settimeout(10)
                raw = self.rfile.read(int(length))
                if len(raw) != int(length):
                    raise BridgeError("invalid_arguments", "Incomplete transcript request.")
                self.reply(200, query_transcripts(store, parse_json(raw)))
            except BridgeError as error:
                # Never return request values, database diagnostics or ASR errors.
                code, status = {
                    "transcript_not_authorized": ("transcript_not_authorized", 403),
                    "limit_exceeded": ("limit_exceeded", 413),
                    "invalid_json": ("invalid_arguments", 400),
                    "invalid_arguments": ("invalid_arguments", 400),
                }.get(error.code, ("transcript_unavailable", 503))
                self.reply(status, {"error": {"code": code, "message": "The transcript query could not be completed."}})
            except (OSError, sqlite3.Error, ValueError, UnicodeError):
                try:
                    self.reply(503, {"error": {"code": "transcript_unavailable", "message": "The transcript query could not be completed."}})
                except OSError:
                    self.close_connection = True

        def do_GET(self):
            if self.path != "/v1/status":
                self.reply(405, {"error": {"code": "method_not_allowed", "message": "This endpoint only accepts paired uploads."}})
                return
            if (len(self.headers.get_all("Authorization", [])) != 1 or
                    not hmac.compare_digest(self.headers.get("Authorization", "").encode("utf-8"), ("Bearer " + token).encode("ascii"))):
                self.reply(401, {"error": {"code": "unauthorized", "message": "Pair this device before checking the receiver."}})
                return
            if self.headers.get("Origin") is not None or self.headers.get("Transfer-Encoding") is not None:
                self.reply(400, {"error": {"code": "invalid_arguments", "message": "Invalid receiver status request."}})
                return
            # Connectivity and paired identity only: never inspect the library,
            # delivery database, recordings or transcripts, and never trigger work.
            # A ready response is not a durable import receipt.
            self.reply(200, {"schemaVersion": 1, "receiverID": store.receiver_id, "status": "ready"})

    return Handler


class HTTPSReceiverServer(ThreadingMixIn, HTTPServer):
    # TLS handshakes and slow clients must not hold the accept loop. Bound the
    # number of workers; archive publication remains serialized by upload_lock.
    daemon_threads = True

    def __init__(self, address, handler, tls_context):
        self.tls_context = tls_context
        self.connection_slots = threading.BoundedSemaphore(4)
        super().__init__(address, handler)

    def process_request(self, connection, address):
        if not self.connection_slots.acquire(blocking=False):
            self.shutdown_request(connection)
            return
        try:
            super().process_request(connection, address)
        except BaseException:
            self.connection_slots.release()
            connection.close()
            raise

    def process_request_thread(self, connection, address):
        try:
            connection.settimeout(10)
            secured = self.tls_context.wrap_socket(connection, server_side=True)
            super().process_request_thread(secured, address)
        except OSError:
            connection.close()  # Failed/abandoned TLS handshake, no request logged.
        finally:
            self.connection_slots.release()


def event_message(events):
    """Fixed notification, with no transcript content or prescribed downstream task."""
    return "这些是新到达的录音，可通过已连接的 record-for-agent 读取。\n" + canonical_json({"events": events})


class BackgroundTranscription:
    """Runs one acknowledged recording at a time without blocking HTTPS receipts."""
    def __init__(self, store, executable, interval=30):
        from automatic_transcription import TranscriptionWorker
        if type(interval) is not int or interval < 1:
            raise BridgeError("invalid_arguments", "The transcription interval must be positive.")
        self.store = store
        self.interval = interval
        self.stopped = threading.Event()
        self.work_available = threading.Event()
        self.worker = TranscriptionWorker(store.root / "transcription", store.library, executable,
                                          on_ready=store.enqueue_available, runner=self.run_process)
        self.thread = threading.Thread(target=self.run, name="record-for-agent-transcription", daemon=True)

    def run_process(self, command, **options):
        timeout = options.pop("timeout")
        options.pop("check", None)
        process = subprocess.Popen(command, **options)
        deadline = time.monotonic() + timeout
        try:
            while not self.stopped.is_set():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                try:
                    stdout, stderr = process.communicate(timeout=min(1, remaining))
                    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
                except subprocess.TimeoutExpired:
                    pass
            raise subprocess.SubprocessError("Local transcription service stopped.")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            for stream in (process.stdout, process.stderr):
                if stream:
                    stream.close()

    def run(self):
        while not self.stopped.is_set():
            # Clear before scanning: an import committed during the scan retains
            # its wakeup, including when no job was eligible at the scan boundary.
            self.work_available.clear()
            if self.stopped.is_set():
                break
            try:
                results = self.worker.run_once(self.store.authorized_recording_ids(), max_jobs=1)
                # Report only status counts. Content, local paths and IDs never enter
                # process logs. The transcript remains in the authorized MCP library.
                if results:
                    counts = {status: sum(row.get("status") == status for row in results)
                              for status in sorted({row.get("status", "unknown") for row in results})}
                    print(canonical_json({"transcription": counts}), flush=True)
                    # The interval is an idle/retry poll, not a per-segment tax.
                    # A retry has a durable future retry_at; the next pass can
                    # therefore process other eligible recordings immediately.
                    if any(row.get("status") in {"ready", "no_speech", "retry"} for row in results):
                        continue
            except (BridgeError, OSError, sqlite3.Error) as error:
                print(canonical_json({"transcriptionError": safe_error(error).code}), file=sys.stderr, flush=True)
            if not self.stopped.is_set():
                self.work_available.wait(self.interval)

    def wake(self):
        self.work_available.set()

    def start(self):
        self.thread.start()

    def stop(self):
        self.stopped.set()
        self.wake()
        self.thread.join(timeout=5)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True)
    parser.add_argument("--library", required=True)
    parser.add_argument("--receiver-id", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    receiver = commands.add_parser("receive", help="Start an explicitly configured HTTPS receiver; never installs a background service.")
    receiver.add_argument("--host", default="127.0.0.1")
    receiver.add_argument("--port", type=int, default=8766)
    receiver.add_argument("--token-file", required=True)
    receiver.add_argument("--cert", required=True)
    receiver.add_argument("--key", required=True)
    receiver.add_argument("--transcriber", help="Optional compiled local Apple ASR helper; only acknowledged IDs are enrolled.")
    receiver.add_argument("--transcription-interval", type=int, default=30)
    commands.add_parser("status", help="Show counts only, without recording content.")
    dispatch = commands.add_parser("dispatch", help="Deliver notifications only to an explicitly configured existing client target.")
    dispatch.add_argument("--client-config", required=True)
    dispatch.add_argument("--once", action="store_true")
    dispatch.add_argument("--interval", type=int, help="Explicit seconds between delivery windows; no recurring schedule is assumed.")
    args = parser.parse_args(argv)
    try:
        store = DeliveryStore(args.state, args.library, args.receiver_id)
        if args.command == "status":
            print(canonical_json(store.status()))
            return 0
        if args.command == "dispatch":
            from delivery_clients import configured_client, dispatch_once
            client = configured_client(parse_json(private_file(args.client_config).read_bytes()))
            if not args.once and (args.interval is None or args.interval < 1):
                raise BridgeError("invalid_arguments", "Choose --once or an explicit positive --interval; no notification schedule is assumed.")
            while True:
                print(canonical_json(dispatch_once(store, client)), flush=True)
                if args.once:
                    return 0
                time.sleep(args.interval)
        token = private_file(args.token_file).read_text().strip()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(str(private_file(args.cert)), str(private_file(args.key)))
        store.recover()
        worker = BackgroundTranscription(store, args.transcriber, args.transcription_interval) if args.transcriber else None
        server = HTTPSReceiverServer((args.host, args.port),
                                    receiver_handler(store, token, on_import=worker.wake if worker else None), context)
        print(canonical_json({"status": "listening", "transport": "https", "receiverID": store.receiver_id,
                              "host": args.host, "port": server.server_port}), flush=True)
        try:
            if worker:
                worker.start()
            server.serve_forever()
        finally:
            server.server_close()
            if worker:
                worker.stop()
    except (BridgeError, OSError, sqlite3.Error, ValueError) as error:
        print(canonical_json(safe_error(error).payload()), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
