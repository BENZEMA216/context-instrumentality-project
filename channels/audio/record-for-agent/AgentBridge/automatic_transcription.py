"""Local, restartable ASR for explicitly delivered recordings; never generates summaries.

The caller supplies IDs from the authenticated receiver's durable receipts. Existing
manually imported recordings are not discovered or enrolled by this worker.
"""

import contextlib
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import time
import uuid
import zipfile

from library import (BridgeError, Library, canonical_json, canonical_uuid,
                     import_package, parse_json, validate_transcript,
                     _directory, _regular_file, _sync_directory)


_NATIVE_STATUSES = {
    "unsupportedOS": "unsupported_os", "deviceUnavailable": "device_unavailable",
    "unsupportedLocale": "unsupported_locale", "notInstalled": "not_installed",
    "downloading": "downloading", "ready": "ready", "started": "started",
    "existing_valid": "existing_valid", "succeeded": "succeeded", "noSpeech": "no_speech",
    "cancelled": "cancelled", "invalidManifest": "invalid_manifest", "timeout": "timeout",
    "sourceChanged": "source_changed", "transcriptValidationFailed": "transcript_validation_failed",
    "modelNotInstalled": "model_not_installed", "modelDownloading": "model_downloading",
    "modelPreparationFailed": "model_preparation_failed", "busy": "busy",
    "invalidAudio": "invalid_audio", "audioMismatch": "audio_mismatch",
}
_NATIVE_EXIT_CODES = {0: "0", 1: "1", 2: "2", 3: "3", -6: "signal_abort",
                      -9: "signal_kill", -11: "signal_segv", -15: "signal_term"}


def _native_status(value):
    if not isinstance(value, str):
        return "other"
    if value in _NATIVE_STATUSES:
        return _NATIVE_STATUSES[value]
    if value.startswith("invalidSpan_"):
        index = value[len("invalidSpan_"):]
        if index and index.isascii() and index.isdigit():
            return "invalid_span"
    if value.startswith("error_"):
        return "framework_error"
    return "other"


def _native_diagnostic(returncode, segments, models, errors):
    """Return fixed ASCII categories only, never helper text, paths, domains or codes."""
    def category(values):
        categories = {_native_status(value) for value in values}
        return next(iter(categories)) if len(categories) == 1 else ("conflicting" if categories else "none")
    terminal = [value for value in segments if value != "started"]
    code = _NATIVE_EXIT_CODES.get(returncode, "other") if type(returncode) is int else "other"
    return "rc={}|model={}|segment={}|error={}".format(
        code, category(models), category(terminal or segments), category(errors))


class _NativeTranscriptionFailure(BridgeError):
    def __init__(self, code, message, diagnostic):
        super().__init__(code, message)
        self.diagnostic = diagnostic


class TranscriptionWorker:
    def __init__(self, state, library, executable, on_ready, *, runner=None):
        self.state = Path(state).expanduser().absolute()
        self.library = Library(library)
        self.executable = Path(executable).expanduser().absolute()
        self.on_ready = on_ready
        self.runner = runner or subprocess.run
        if self.state.exists() or self.state.is_symlink():
            _directory(self.state)
        self.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.state, 0o700)
        self.db = self.state / "transcription.sqlite3"
        if self.db.exists() or self.db.is_symlink():
            _regular_file(self.db)
        with self._connection() as connection:
            connection.execute("CREATE TABLE IF NOT EXISTS jobs ("
                               "recording_id TEXT PRIMARY KEY, audio_hash TEXT NOT NULL, "
                               "status TEXT NOT NULL, attempts INTEGER NOT NULL, "
                               "retry_at INTEGER NOT NULL, last_error TEXT, updated_at INTEGER NOT NULL)")
        _sync_directory(self.state)

    @contextlib.contextmanager
    def _connection(self):
        if self.db.exists() or self.db.is_symlink():
            _regular_file(self.db)
        connection = sqlite3.connect(str(self.db), timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA synchronous=FULL")
        os.chmod(self.db, 0o600)
        try:
            yield connection
            connection.commit()
        finally:
            connection.close()

    def _update(self, identifier, digest, status, attempts, now, error=None):
        delay = min(3_600_000, 60_000 * (2 ** min(max(0, attempts - 1), 6)))
        retry_at = now + delay if status == "retry" else 0
        with self._connection() as connection:
            connection.execute("INSERT INTO jobs VALUES (?, ?, ?, ?, ?, ?, ?) "
                               "ON CONFLICT(recording_id) DO UPDATE SET audio_hash=excluded.audio_hash, "
                               "status=excluded.status, attempts=excluded.attempts, retry_at=excluded.retry_at, "
                               "last_error=excluded.last_error, updated_at=excluded.updated_at",
                               (identifier, digest, status, attempts, retry_at, error, now))

    def run_once(self, authorized_recording_ids, *, max_jobs=1, now_ms=None):
        """Process only caller-authorized IDs, with durable retries and an exclusive worker lock."""
        if type(max_jobs) is not int or not 1 <= max_jobs <= 100:
            raise BridgeError("invalid_arguments", "max_jobs must be between 1 and 100.")
        identifiers = list(dict.fromkeys(canonical_uuid(value) for value in authorized_recording_ids))
        now = int(time.time() * 1000) if now_ms is None else now_ms
        lock_path = self.state / "worker.lock"
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(lock_path, flags, 0o600)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return [{"status": "busy"}]
            # A terminated process may leave an input snapshot, never a published result.
            # Only our own reserved workspace directory is cleaned after the worker lock.
            work = self.state / "work"
            if work.exists() or work.is_symlink():
                _directory(work)
                shutil.rmtree(work)
            results = []
            started_jobs = 0
            for identifier in identifiers:
                if started_jobs >= max_jobs:
                    break
                try:
                    manifest = self.library.get_recording({"recording_id": identifier})["manifest"]
                    with self._connection() as connection:
                        job = connection.execute("SELECT * FROM jobs WHERE recording_id=?", (identifier,)).fetchone()
                    if job and job["audio_hash"] != manifest["sha256"]:
                        raise BridgeError("integrity_mismatch", "A queued recording changed its audio identity.")
                    if job and (job["status"] == "ready" or (job["status"] == "retry" and job["retry_at"] > now)):
                        continue
                    current = self.library.get_transcript({"recording_id": identifier})
                    # A later phone-generated transcript can supersede a local no-speech result.
                    if job and job["status"] == "no_speech" and current["transcriptStatus"] != "ready":
                        continue
                except (BridgeError, OSError, sqlite3.Error) as error:
                    # A missing/corrupt catalog entry must not starve later healthy
                    # IDs. Without a validated manifest, don't invent an ASR job or
                    # consume this pass's processing budget.
                    code = error.code if isinstance(error, BridgeError) else type(error).__name__
                    results.append({"recordingID": identifier, "status": "unavailable", "error": code})
                    continue
                started_jobs += 1
                attempts = (job["attempts"] if job else 0) + 1
                self._update(identifier, manifest["sha256"], "running", attempts, now)
                try:
                    if current["transcriptStatus"] != "ready":
                        result = self._transcribe(manifest, work)
                        if result == "no_speech":
                            self._update(identifier, manifest["sha256"], result, attempts, now)
                            results.append({"recordingID": identifier, "status": result})
                            continue
                    # The callback must durably enqueue before returning. If it fails,
                    # a retry sees the existing transcript and retries only this callback.
                    self.on_ready([identifier])
                    self._update(identifier, manifest["sha256"], "ready", attempts, now)
                    results.append({"recordingID": identifier, "status": "ready"})
                except (BridgeError, OSError, subprocess.SubprocessError) as error:
                    code = error.code if isinstance(error, BridgeError) else type(error).__name__
                    # Diagnostics remain local to the existing private job row. Public
                    # error codes and all retry/success decisions remain unchanged.
                    local_error = code + "|" + error.diagnostic if isinstance(error, _NativeTranscriptionFailure) else code
                    self._update(identifier, manifest["sha256"], "retry", attempts, now, local_error)
                    results.append({"recordingID": identifier, "status": "retry", "error": code})
                finally:
                    if work.exists():
                        shutil.rmtree(work)
            return results
        finally:
            os.close(descriptor)

    def _transcribe(self, manifest, work):
        _regular_file(self.executable)
        if not os.access(self.executable, os.X_OK):
            raise BridgeError("transcriber_unavailable", "The local transcriber is not executable.")
        asset = self.library.get_audio_asset({"recording_id": manifest["id"]})
        work.mkdir(mode=0o700)
        (work / "manifests").mkdir(mode=0o700)
        (work / "audio").mkdir(mode=0o700)
        metadata_path = work / "manifests" / (manifest["id"] + ".json")
        metadata_path.write_text(canonical_json(manifest), encoding="utf-8")
        os.chmod(metadata_path, 0o600)
        audio_path = work / "audio" / manifest["fileName"]
        shutil.copyfile(asset["localPath"], audio_path)
        os.chmod(audio_path, 0o600)
        digest = hashlib.sha256()
        with audio_path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        if audio_path.stat().st_size != manifest["byteCount"] or digest.hexdigest() != manifest["sha256"]:
            raise BridgeError("integrity_mismatch", "The private ASR snapshot does not match the recording.")
        timeout = min(3600, max(180, int(manifest["frameCount"] / manifest["sampleRate"] * 3 + 60)))
        result = self.runner([str(self.executable), "transcribe", str(work), "--limit", "1",
                              "--timeout-seconds", str(timeout)],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             timeout=timeout + 30, check=False)
        # The native helper emits metadata only; do not surface framework stderr or
        # arbitrary paths to the Agent or HTTP response.
        statuses = []
        model_statuses = []
        error_statuses = []
        output = result.stdout or b""
        if len(output) > 256 * 1024:
            raise BridgeError("transcriber_output_invalid", "The local transcriber output exceeded its bound.")
        for line in output.splitlines():
            try:
                record = parse_json(line)
                if isinstance(record, dict) and record.get("event") == "segment" and record.get("id") == manifest["id"]:
                    statuses.append(record.get("status"))
                elif isinstance(record, dict) and record.get("event") == "model":
                    model_statuses.append(record.get("status"))
                elif isinstance(record, dict) and record.get("event") == "error":
                    error_statuses.append(record.get("status"))
            except BridgeError:
                continue
        transcript_path = work / "transcripts" / (manifest["id"] + ".json")
        if not transcript_path.exists():
            if result.returncode == 0 and "noSpeech" in statuses:
                return "no_speech"
            raise _NativeTranscriptionFailure(
                "transcription_pending", "The local transcriber did not produce a validated transcript.",
                _native_diagnostic(result.returncode, statuses, model_statuses, error_statuses))
        _regular_file(transcript_path)
        if transcript_path.stat().st_size > 4 * 1024 * 1024:
            raise BridgeError("limit_exceeded", "The local transcript exceeds its size limit.")
        if result.returncode != 0:
            raise _NativeTranscriptionFailure(
                "transcription_failed", "The local transcriber failed; original audio is retained.",
                _native_diagnostic(result.returncode, statuses, model_statuses, error_statuses))
        transcript = validate_transcript(parse_json(transcript_path.read_bytes()), manifest)
        # Another uploader may have added a valid transcript while ASR ran. Keep it;
        # the importer's immutable transcript rule must never be bypassed.
        if self.library.get_transcript({"recording_id": manifest["id"]})["transcriptStatus"] == "ready":
            return "ready"
        version = hashlib.sha256(canonical_json(transcript).encode("utf-8")).hexdigest()
        export_id = str(uuid.uuid5(uuid.NAMESPACE_URL, "record-for-agent:local-asr:" + manifest["id"] + ":" + version))
        envelope = {"schemaVersion": 2, "exportID": export_id, "exportedAt": transcript["createdAt"],
                    "transcriptStatus": "ready", "segments": [{"manifest": manifest,
                    "audioPath": "audio/" + manifest["fileName"], "transcript": transcript}]}
        package = work / "transcribed.zip"
        with zipfile.ZipFile(package, "x", compression=zipfile.ZIP_STORED) as archive:
            archive.writestr("export.json", canonical_json(envelope))
            archive.writestr("README.md", "Automatically transcribed on this Mac. Only the authenticated delivered segment is included.\n")
            archive.write(audio_path, "audio/" + manifest["fileName"])
        os.chmod(package, 0o600)
        try:
            import_package(package, self.library.root)
        except BridgeError as error:
            if error.code != "conflict" or self.library.get_transcript({"recording_id": manifest["id"]})["transcriptStatus"] != "ready":
                raise
        return "ready"
