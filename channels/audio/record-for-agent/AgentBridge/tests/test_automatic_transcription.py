"""Synthetic automatic receive -> local ASR -> existing MCP catalog integration."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

from test_bridge import segment, write_package
from test_transcripts import transcript_for, version2
from automatic_transcription import TranscriptionWorker
from library import BridgeError, Library, canonical_json, import_package


class AutomaticTranscriptionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.catalog = self.root / "library"
        self.state = self.root / "asr"
        self.items = [segment(0), segment(1)]
        self.package = self.root / "received.zip"
        write_package(self.package, self.items)
        import_package(self.package, self.catalog)
        self.executable = self.root / "transcriber"
        self.executable.write_text("#!/bin/sh\nexit 1\n")
        self.executable.chmod(0o700)
        self.calls = []
        self.notifications = []
        self.worker = self.make_worker()

    def tearDown(self):
        self.temporary.cleanup()

    def make_worker(self, runner=None, callback=None):
        return TranscriptionWorker(self.state, self.catalog, self.executable,
                                   callback or self.notifications.extend,
                                   runner=runner or self.successful_runner)

    def identifier(self, index=0):
        return self.items[index][0]["manifest"]["id"]

    def successful_runner(self, command, **kwargs):
        self.calls.append(command)
        root = Path(command[2])
        manifest = json.loads(next((root / "manifests").glob("*.json")).read_text())
        transcript = transcript_for({"manifest": manifest}, "这是自动同步的合成测试录音。")
        (root / "transcripts").mkdir()
        (root / "transcripts" / (manifest["id"] + ".json")).write_text(canonical_json(transcript))
        return subprocess.CompletedProcess(command, 0, stdout=b'{"event":"summary","succeeded":1}\n', stderr=b"")

    def get(self, index=0):
        return Library(self.catalog).get_transcript({"recording_id": self.identifier(index)})

    def test_authorized_audio_becomes_readable_without_enrolling_other_imports(self):
        identifier = self.identifier()
        before = Library(self.catalog).get_audio_asset({"recording_id": identifier})
        results = self.worker.run_once([identifier], now_ms=1_700_000_000_000)
        self.assertEqual(results, [{"recordingID": identifier, "status": "ready"}])
        self.assertEqual(self.get()["transcriptStatus"], "ready")
        self.assertEqual(self.get(1)["transcriptStatus"], "not_generated")
        self.assertEqual(self.notifications, [identifier])
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(hashlib.sha256(Path(before["localPath"]).read_bytes()).hexdigest(), before["sha256"])
        self.assertFalse((self.state / "work").exists())
        self.assertEqual(self.make_worker().run_once([identifier]), [])
        self.assertEqual(len(self.calls), 1)

    def test_model_unavailable_retries_after_restart_without_publishing_empty_text(self):
        def unavailable(command, **kwargs):
            self.calls.append(command)
            return subprocess.CompletedProcess(command, 2, stdout=b'{"event":"model","status":"notInstalled"}\n', stderr=b"")
        now = 1_700_000_000_000
        result = self.make_worker(runner=unavailable).run_once([self.identifier()], now_ms=now)
        self.assertEqual(result[0]["status"], "retry")
        self.assertEqual(self.get()["transcriptStatus"], "not_generated")
        self.assertEqual(self.notifications, [])
        restarted = self.make_worker()
        self.assertEqual(restarted.run_once([self.identifier()], now_ms=now + 1), [])
        self.assertEqual(restarted.run_once([self.identifier()], now_ms=now + 60_001)[0]["status"], "ready")
        self.assertEqual(len(self.calls), 2)

    def test_notification_failure_retries_after_transcript_commit_without_retranscribing(self):
        def unavailable(ids):
            raise BridgeError("outbox_unavailable", "Synthetic write interruption.")
        now = 1_700_000_000_000
        result = self.make_worker(callback=unavailable).run_once([self.identifier()], now_ms=now)
        self.assertEqual(result[0]["error"], "outbox_unavailable")
        self.assertEqual(self.get()["transcriptStatus"], "ready")
        self.assertEqual(len(self.calls), 1)
        restarted = self.make_worker()
        self.assertEqual(restarted.run_once([self.identifier()], now_ms=now + 60_001)[0]["status"], "ready")
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.notifications, [self.identifier()])

    def test_no_speech_is_terminal_until_an_actual_transcript_arrives(self):
        def silence(command, **kwargs):
            self.calls.append(command)
            output = canonical_json({"event": "segment", "id": self.identifier(), "status": "noSpeech"}).encode()
            return subprocess.CompletedProcess(command, 0, stdout=output, stderr=b"")
        now = 1_700_000_000_000
        worker = self.make_worker(runner=silence)
        self.assertEqual(worker.run_once([self.identifier()], now_ms=now)[0]["status"], "no_speech")
        self.assertEqual(self.make_worker().run_once([self.identifier()], now_ms=now + 7_200_000), [])
        self.assertEqual(self.notifications, [])
        self.items[0][0]["transcript"] = transcript_for(self.items[0][0])
        write_package(self.package, self.items, version2(self.items))
        import_package(self.package, self.catalog)
        self.assertEqual(self.make_worker().run_once([self.identifier()], now_ms=now + 7_200_001)[0]["status"], "ready")
        self.assertEqual(len(self.calls), 1)

    def test_changed_audio_is_not_sent_to_transcriber_or_notified(self):
        asset = Library(self.catalog).get_audio_asset({"recording_id": self.identifier()})
        Path(asset["localPath"]).write_bytes(b"corrupted fixture")
        result = self.worker.run_once([self.identifier()])
        self.assertEqual(result[0]["error"], "integrity_mismatch")
        self.assertEqual(self.calls, [])
        self.assertEqual(self.notifications, [])

    def test_wrong_transcript_identity_does_not_enter_catalog(self):
        def invalid(command, **kwargs):
            result = self.successful_runner(command, **kwargs)
            path = next((Path(command[2]) / "transcripts").glob("*.json"))
            value = json.loads(path.read_text())
            value["audioSHA256"] = "0" * 64
            path.write_text(canonical_json(value))
            return result
        result = self.make_worker(runner=invalid).run_once([self.identifier()])
        self.assertEqual(result[0]["error"], "integrity_mismatch")
        self.assertEqual(self.get()["transcriptStatus"], "not_generated")
        self.assertEqual(self.notifications, [])

    def test_simultaneous_phone_transcript_is_preserved(self):
        expected = transcript_for(self.items[0][0], "手机已生成的合成文字。")
        def racing(command, **kwargs):
            result = self.successful_runner(command, **kwargs)
            self.items[0][0]["transcript"] = expected
            write_package(self.package, self.items, version2(self.items))
            import_package(self.package, self.catalog)
            return result
        self.assertEqual(self.make_worker(runner=racing).run_once([self.identifier()])[0]["status"], "ready")
        self.assertEqual(self.get()["transcript"], expected)
        self.assertEqual(self.notifications, [self.identifier()])

    def test_timeout_preserves_audio_and_schedules_retry(self):
        def timeout(command, **kwargs):
            raise subprocess.TimeoutExpired(command, 210)
        result = self.make_worker(runner=timeout).run_once([self.identifier()])
        self.assertEqual(result[0]["error"], "TimeoutExpired")
        self.assertEqual(self.get()["transcriptStatus"], "not_generated")
        self.assertEqual(self.notifications, [])
        self.assertFalse((self.state / "work").exists())

    def test_missing_first_recording_does_not_starve_later_healthy_recording(self):
        unknown = str(uuid.uuid4())
        results = self.worker.run_once([unknown, self.identifier()], max_jobs=1)
        self.assertEqual(results[0]["status"], "unavailable")
        self.assertEqual(results[1]["status"], "ready")
        self.assertEqual(self.notifications, [self.identifier()])
        self.assertEqual(len(self.calls), 1)

    def test_missing_native_output_keeps_retry_and_persists_only_fixed_failure_categories(self):
        identifier = self.identifier()
        cases = [
            (3, [{"event": "model", "status": "ready"},
                 {"event": "segment", "id": identifier, "status": "started"},
                 {"event": "segment", "id": identifier, "status": "invalidSpan_4"}],
             "rc=3|model=ready|segment=invalid_span|error=none"),
            (3, [{"event": "segment", "id": identifier, "status": "invalidAudio"}],
             "rc=3|model=none|segment=invalid_audio|error=none"),
            (2, [{"event": "model", "status": "notInstalled"}],
             "rc=2|model=not_installed|segment=none|error=none"),
            (1, [{"event": "error", "status": "error_NSURLErrorDomain_-1009"}],
             "rc=1|model=none|segment=none|error=framework_error"),
            (3, [{"event": "model", "status": "ready"},
                 {"event": "segment", "id": identifier, "status": "started"},
                 {"event": "segment", "id": identifier, "status": "cancelled"}],
             "rc=3|model=ready|segment=cancelled|error=none"),
        ]
        for index, (returncode, records, expected) in enumerate(cases):
            with self.subTest(expected=expected):
                output = b"\n".join(canonical_json(record).encode() for record in records)
                def failing(command, **kwargs):
                    self.calls.append(command)
                    return subprocess.CompletedProcess(command, returncode, stdout=output, stderr=b"")
                now = 1_700_000_000_000 + index * 7_200_000
                worker = self.make_worker(runner=failing)
                result = worker.run_once([identifier], now_ms=now)
                self.assertEqual(result, [{"recordingID": identifier, "status": "retry",
                                           "error": "transcription_pending"}])
                with worker._connection() as connection:
                    job = connection.execute("SELECT * FROM jobs WHERE recording_id=?", (identifier,)).fetchone()
                self.assertEqual(job["last_error"], "transcription_pending|" + expected)
                self.assertEqual(job["attempts"], index + 1)
                self.assertEqual(job["retry_at"], now + 60_000 * (2 ** index))
                self.assertEqual(self.get()["transcriptStatus"], "not_generated")
                self.assertEqual(self.notifications, [])
                self.assertFalse((self.state / "work").exists())

    def test_native_diagnostics_cannot_turn_nonzero_or_other_source_no_speech_into_success(self):
        identifier = self.identifier()
        for index, (returncode, source, expected) in enumerate([
            (3, identifier, "rc=3|model=none|segment=no_speech|error=none"),
            (0, self.identifier(1), "rc=0|model=none|segment=none|error=none"),
        ]):
            with self.subTest(returncode=returncode, source=source):
                output = canonical_json({"event": "segment", "id": source, "status": "noSpeech"}).encode()
                def failing(command, **kwargs):
                    return subprocess.CompletedProcess(command, returncode, stdout=output, stderr=b"")
                worker = self.make_worker(runner=failing)
                result = worker.run_once([identifier], now_ms=1_700_000_000_000 + index * 7_200_000)
                self.assertEqual(result[0]["status"], "retry")
                self.assertEqual(result[0]["error"], "transcription_pending")
                with worker._connection() as connection:
                    job = connection.execute("SELECT * FROM jobs WHERE recording_id=?", (identifier,)).fetchone()
                self.assertEqual(job["last_error"], "transcription_pending|" + expected)
                self.assertEqual(self.get()["transcriptStatus"], "not_generated")
                self.assertEqual(self.notifications, [])

    def test_native_diagnostics_never_persist_untrusted_output_or_stderr(self):
        canary = "PRIVATE_NATIVE_OUTPUT_https://example.invalid/private/audio.caf_秘密正文"
        records = [
            {"event": "model", "status": {"private": canary}},
            {"event": "segment", "id": self.identifier(), "status": canary},
            {"event": "segment", "id": self.identifier(1), "status": "invalidAudio"},
            {"event": "error", "status": "error_" + canary},
        ]
        output = b"not-json " + canary.encode() + b"\n" + b"\n".join(
            canonical_json(record).encode() for record in records)
        def failing(command, **kwargs):
            return subprocess.CompletedProcess(command, 255, stdout=output, stderr=canary.encode())
        worker = self.make_worker(runner=failing)
        result = worker.run_once([self.identifier()], now_ms=1_700_000_000_000)
        with worker._connection() as connection:
            job = connection.execute("SELECT * FROM jobs WHERE recording_id=?", (self.identifier(),)).fetchone()
        self.assertEqual(job["last_error"],
                         "transcription_pending|rc=other|model=other|segment=other|error=framework_error")
        self.assertNotIn(canary, canonical_json(result))
        self.assertNotIn(canary.encode(), worker.db.read_bytes())
        self.assertFalse((self.state / "work").exists())

    def test_valid_output_with_failed_native_exit_keeps_original_public_error(self):
        def failing(command, **kwargs):
            result = self.successful_runner(command, **kwargs)
            return subprocess.CompletedProcess(command, -15, stdout=result.stdout, stderr=b"not retained")
        worker = self.make_worker(runner=failing)
        result = worker.run_once([self.identifier()], now_ms=1_700_000_000_000)
        self.assertEqual(result[0]["error"], "transcription_failed")
        with worker._connection() as connection:
            job = connection.execute("SELECT * FROM jobs WHERE recording_id=?", (self.identifier(),)).fetchone()
        self.assertEqual(job["last_error"],
                         "transcription_failed|rc=signal_term|model=none|segment=none|error=none")
        self.assertEqual(self.get()["transcriptStatus"], "not_generated")
        self.assertEqual(self.notifications, [])


if __name__ == "__main__":
    unittest.main()
