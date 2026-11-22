"""Synthetic local files only: no iCloud account, device, recording, or download."""

import copy
from contextlib import redirect_stdout
import ctypes
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import icloud_drive_library as cloud


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def export_digest(artifacts):
    return digest("".join("%s\t%s\t%d\t%s\n" % (item["kind"], item["sha256"], item["byteCount"], item["relativePath"])
        for item in sorted(artifacts, key=lambda item: item["kind"] + "-" + item["sha256"])).encode())


class Fixture:
    def __init__(self, root, sid=None):
        self.root = root
        self.library = "fb71d968-f38b-4f88-b35b-cccb32b0c4aa"
        self.sid = sid or str(uuid.uuid4())
        self.audio = b"SYNTHETIC AUDIO NEVER OPENED BY READER"
        self.manifest = {"schemaVersion": 1, "id": self.sid.upper(), "sessionID": str(uuid.uuid4()).upper(),
            "sequence": 0, "startedAt": 1700000000000, "endedAt": 1700000010000,
            "sampleRate": 16000, "frameCount": 160000, "fileName": self.sid + ".caf",
            "byteCount": len(self.audio), "sha256": digest(self.audio), "timeZoneIdentifier": "Asia/Shanghai"}
        self.write("library.json", encoded({"schemaVersion": 1, "libraryID": self.library.upper(), "format": cloud.FORMAT}))
        (root / "commits").mkdir(exist_ok=True)

    def write(self, relative, data):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def commit(self, text=None, *, at=1700000200000, audio_present=False, transcript_override=None, audio_path=None):
        raw_manifest = encoded(self.manifest)
        objects = [("audio", self.audio, "audio", ".caf"), ("manifest", raw_manifest, "manifests", ".json")]
        if text is not None:
            transcript = {"schemaVersion": 1, "segmentID": self.sid.upper(), "audioSHA256": self.manifest["sha256"],
                "locale": "zh-CN", "engine": "synthetic-only", "createdAt": at, "text": text,
                "spans": [{"start": 0, "end": 10, "text": text}]}
            transcript.update(transcript_override or {})
            objects += [("transcriptJSON", encoded(transcript), "transcripts", ".json"),
                        ("transcriptText", (text + "\n").encode(), "transcripts", ".txt")]
        artifacts = []
        for kind, data, folder, suffix in objects:
            sha = digest(data)
            relative = audio_path if kind == "audio" and audio_path else folder + "/" + self.sid + "/" + sha + suffix
            artifacts.append({"kind": kind, "sha256": sha, "byteCount": len(data), "relativePath": relative})
            if kind != "audio" or audio_present:
                self.write(relative, data)
        artifacts.sort(key=lambda item: item["kind"] + "-" + item["sha256"])
        commit = {"schemaVersion": 1, "libraryID": self.library.upper(), "segmentID": self.sid.upper(),
            "audioSHA256": self.manifest["sha256"], "manifestSHA256": digest(raw_manifest), "committedAt": at,
            "artifacts": artifacts, "exportDigest": export_digest(artifacts)}
        if text is not None:
            commit["transcriptVersionSHA256"] = next(item["sha256"] for item in artifacts if item["kind"] == "transcriptJSON")
        path = self.write("commits/" + self.sid + "/" + commit["exportDigest"] + ".json", encoded(commit))
        return commit, path


class ICloudDriveLibraryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "selected-library"
        self.root.mkdir()
        self.fixture = Fixture(self.root)
        self.reader = cloud.ICloudDriveLibrary(self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def rejected(self, operation, code, *, pending=False):
        with self.assertRaises(cloud.ICloudDriveError) as caught:
            operation()
        self.assertEqual(caught.exception.code, code)
        self.assertEqual(caught.exception.pending, pending)

    def test_grouped_audio_coexists_with_legacy_and_binds_recorded_path(self):
        self.fixture.commit(audio_present=True)
        grouped = Fixture(self.root)
        group_id = str(uuid.uuid4())
        grouped.manifest["recordingGroup"] = {"id": group_id.upper(), "startedAt": 1700000000000,
            "utcOffsetMinutes": 480, "firstSequence": 0}
        path = "audio/2023-11-15_06-13-20+0800_" + group_id + "/2023-11-15_06-13-20+0800_part001_" + grouped.sid + ".caf"
        _, commit = grouped.commit(audio_present=True, audio_path=path)
        rows = {row["segmentID"]: row for row in self.reader.list_segments()["segments"]}
        self.assertEqual(set(rows), {self.fixture.sid, grouped.sid})
        self.assertEqual(rows[grouped.sid]["manifest"]["recordingGroup"]["id"], group_id)
        self.assertEqual(next(item["relativePath"] for item in rows[grouped.sid]["artifacts"] if item["kind"] == "audio"), path)
        commit.unlink()
        grouped.commit(audio_present=True, audio_path=path.replace("part001", "part002"))
        self.rejected(self.reader.list_segments, "artifact_path_binding_mismatch")

    def test_late_transcript_is_a_new_commit_without_expanding_source_identity(self):
        self.fixture.commit()
        initial = self.reader.list_segments()
        self.assertEqual(initial["segments"][0]["transcriptStatus"], "not_committed")
        self.rejected(lambda: self.reader.read_transcript(self.fixture.sid), "transcript_not_committed", pending=True)
        commit, _ = self.fixture.commit("迟到的合成转写")
        result = self.reader.read_transcript(self.fixture.sid)
        self.assertEqual(result["content"]["text"], "迟到的合成转写")
        self.assertEqual(result["contentVersionSHA256"], commit["transcriptVersionSHA256"])
        after = self.reader.list_segments()
        self.assertEqual(initial["segments"][0]["source"], after["segments"][0]["source"])
        self.assertEqual(after["segments"][0]["committedVersionCount"], 2)
        self.assertFalse(result["sourceCatalogComplete"])
        self.assertFalse(result["cloudSyncComplete"])
        self.assertFalse(result["completeSession"])

    def test_available_transcript_does_not_open_or_download_audio(self):
        commit, _ = self.fixture.commit("合成正文", audio_present=True)
        actual_open = cloud.os.open
        opened = []

        def guarded_open(path, *args, **kwargs):
            self.assertFalse(str(path).endswith(".caf"), "CAF must never be opened")
            opened.append(str(path))
            return actual_open(path, *args, **kwargs)

        with mock.patch.object(cloud.os, "open", side_effect=guarded_open):
            rows = self.reader.list_segments()
            result = self.reader.read_transcript(self.fixture.sid, format="text")
        self.assertTrue(opened)
        self.assertEqual(result["content"], "合成正文\n")
        self.assertEqual(result["audioBytesRead"], 0)
        self.assertEqual(rows["segments"][0]["manifest"]["sha256"], commit["audioSHA256"])
        audio = next(item for item in commit["artifacts"] if item["kind"] == "audio")
        (self.root / audio["relativePath"]).unlink()
        result = self.reader.read_transcript(self.fixture.sid)
        self.assertEqual(result["status"], "available")
        self.assertEqual(result["audioAvailability"]["status"], "pending")

    def test_commit_arriving_before_transcript_pair_stays_pending(self):
        commit, _ = self.fixture.commit("合成正文")
        text = next(item for item in commit["artifacts"] if item["kind"] == "transcriptText")
        path = self.root / text["relativePath"]
        original = path.read_bytes()
        path.unlink()
        self.assertEqual(self.reader.list_segments()["status"], "pending")
        self.rejected(lambda: self.reader.read_transcript(self.fixture.sid), "artifact_not_available", pending=True)
        path.write_bytes(original)
        self.assertEqual(self.reader.read_transcript(self.fixture.sid)["status"], "available")

    def test_dataless_metadata_refused_before_content_open(self):
        commit, _ = self.fixture.commit("合成正文")
        transcript = next(item for item in commit["artifacts"] if item["kind"] == "transcriptJSON")
        blocked = self.root / transcript["relativePath"]
        actual_open = cloud.os.open

        def guarded_open(path, *args, **kwargs):
            self.assertNotEqual(str(path), blocked.name)
            return actual_open(path, *args, **kwargs)

        with mock.patch.object(cloud, "local_sync_state", side_effect=lambda path, _: "not_downloaded" if path == blocked else "local"), \
                mock.patch.object(cloud.os, "open", side_effect=guarded_open):
            self.rejected(lambda: self.reader.read_transcript(self.fixture.sid), "icloud_not_downloaded", pending=True)

    def test_full_transcript_digest_mismatch_is_rejected_not_truncated(self):
        commit, _ = self.fixture.commit("SYNTHETIC")
        artifact = next(item for item in commit["artifacts"] if item["kind"] == "transcriptJSON")
        path = self.root / artifact["relativePath"]
        path.write_bytes(path.read_bytes().replace(b"SYNTHETIC", b"TAMPERED!"))
        self.rejected(lambda: self.reader.read_transcript(self.fixture.sid), "artifact_digest_mismatch")

    def test_commit_digest_and_source_identity_are_checked(self):
        commit, path = self.fixture.commit("合成正文")
        changed = copy.deepcopy(commit)
        changed["artifacts"][0]["byteCount"] += 1
        path.write_bytes(encoded(changed))
        self.rejected(self.reader.list_segments, "commit_digest_mismatch")
        path.write_bytes(encoded(commit))
        self.fixture.manifest["sha256"] = "d" * 64
        _, different = self.fixture.commit("另一份合成正文", at=1700000200001)
        # Bind the synthetic replacement audio descriptor to its altered source.
        value = json.loads(different.read_bytes())
        audio = next(item for item in value["artifacts"] if item["kind"] == "audio")
        audio["sha256"] = "d" * 64
        audio["relativePath"] = "audio/" + self.fixture.sid + "/" + "d" * 64 + ".caf"
        value["exportDigest"] = export_digest(value["artifacts"])
        different.unlink()
        self.fixture.write("commits/" + self.fixture.sid + "/" + value["exportDigest"] + ".json", encoded(value))
        self.rejected(self.reader.list_segments, "conflicting_source_identity")

    def test_malicious_relative_path_never_opens_external_file(self):
        commit, path = self.fixture.commit("合成正文")
        artifact = next(item for item in commit["artifacts"] if item["kind"] == "transcriptJSON")
        for malicious in ["../../outside.json", "/tmp/outside.json", "transcripts//bad.json", "transcripts/../bad.json", "transcripts\\bad.json"]:
            with self.subTest(path=malicious):
                changed = copy.deepcopy(commit)
                next(item for item in changed["artifacts"] if item["kind"] == "transcriptJSON")["relativePath"] = malicious
                path.write_bytes(encoded(changed))
                with self.assertRaises(cloud.ICloudDriveError):
                    self.reader.read_transcript(self.fixture.sid)
        self.assertTrue((self.root / artifact["relativePath"]).is_file())

    def test_symlinks_in_commits_artifacts_and_directories_are_rejected(self):
        commit, commit_path = self.fixture.commit("合成正文", audio_present=True)
        paths = [commit_path, *(self.root / item["relativePath"] for item in commit["artifacts"])]
        outside = Path(self.temporary.name) / "outside"
        outside.write_bytes(b"NEVER READ")
        for path in paths:
            with self.subTest(path=path.name):
                original = path.read_bytes()
                path.unlink()
                path.symlink_to(outside)
                try:
                    self.rejected(lambda: self.reader.read_transcript(self.fixture.sid), "unsafe_artifact")
                finally:
                    path.unlink()
                    path.write_bytes(original)
        source = self.root / "transcripts" / self.fixture.sid
        moved = self.root / "moved-transcripts"
        source.rename(moved)
        source.symlink_to(moved, target_is_directory=True)
        self.rejected(lambda: self.reader.read_transcript(self.fixture.sid), "unsafe_directory")

    def test_unresolved_icloud_conflict_is_rejected(self):
        self.fixture.commit("合成正文")
        with mock.patch.object(cloud, "local_sync_state", side_effect=lambda path, _: "conflict" if path.name == "library.json" else "local"):
            self.rejected(self.reader.list_segments, "icloud_unresolved_conflict")

    def test_json_and_text_must_describe_same_exact_transcript(self):
        self.fixture.commit("合成正文", transcript_override={"text": "different text"})
        self.rejected(lambda: self.reader.read_transcript(self.fixture.sid), "transcript_text_mismatch")

    def test_transcript_must_bind_to_source_manifest(self):
        self.fixture.commit("合成正文", transcript_override={"audioSHA256": "d" * 64})
        self.rejected(lambda: self.reader.read_transcript(self.fixture.sid), "invalid_transcript_source_or_content")

    def test_marker_identity_is_pinned_for_reader_lifetime(self):
        self.fixture.commit("合成正文")
        self.reader.list_segments()
        self.fixture.write("library.json", encoded({"schemaVersion": 1, "libraryID": str(uuid.uuid4()), "format": cloud.FORMAT}))
        self.rejected(self.reader.list_segments, "library_identity_changed")

    def test_explicit_library_identity_mismatch_is_rejected(self):
        self.fixture.commit("合成正文")
        reader = cloud.ICloudDriveLibrary(self.root, str(uuid.uuid4()))
        self.rejected(reader.list_segments, "library_identity_changed")

    def test_incomplete_commit_and_empty_catalog_are_pending(self):
        self.rejected(self.reader.list_segments, "no_committed_segments", pending=True)
        _, path = self.fixture.commit("合成正文")
        self.fixture.write(str(path.relative_to(self.root).parent / ".pending-commit"), b"{}")
        self.rejected(self.reader.list_segments, "commit_not_finished", pending=True)

    def test_late_catalog_change_invalidates_pagination(self):
        self.fixture.commit("one")
        second = Fixture(self.root)
        second.commit("two")
        first = self.reader.list_segments(limit=1)
        self.assertIsNotNone(first["nextCursor"])
        self.fixture.commit("new version", at=1700000200001)
        self.rejected(lambda: self.reader.list_segments(limit=1, cursor=first["nextCursor"]), "cursor_invalidated")

    def test_newest_missing_transcript_does_not_silently_fall_back(self):
        old, _ = self.fixture.commit("old")
        new, _ = self.fixture.commit("new", at=1700000200001)
        artifact = next(item for item in new["artifacts"] if item["kind"] == "transcriptJSON")
        (self.root / artifact["relativePath"]).unlink()
        self.rejected(lambda: self.reader.read_transcript(self.fixture.sid), "artifact_not_available", pending=True)
        result = self.reader.read_transcript(self.fixture.sid, content_version_sha256=old["transcriptVersionSHA256"])
        self.assertEqual(result["content"]["text"], "old")

    def test_equal_time_conflicting_transcript_versions_require_explicit_version(self):
        old, _ = self.fixture.commit("old")
        self.fixture.commit("new")
        self.rejected(lambda: self.reader.read_transcript(self.fixture.sid), "conflicting_transcript_versions")
        self.assertEqual(self.reader.read_transcript(self.fixture.sid,
            content_version_sha256=old["transcriptVersionSHA256"])["content"]["text"], "old")

    def test_early_manifest_requires_explicit_selection_and_upgrades_on_audio_entry(self):
        chosen, strict, later = self.fixture, Fixture(self.root), Fixture(self.root)
        commit, _ = chosen.commit("not-disclosed")
        strict.commit()
        before = self.reader.directory_baseline()
        later.commit(at=1700000300000)
        baseline = {"libraryID": chosen.library, "segments": before["segments"], "startedAt": 1700000210000}
        selected = [chosen.sid, strict.sid]
        self.rejected(lambda: self.reader.hub_metadata(selected, baseline, early_selection=[later.sid]),
                      "early_selection_outside_selection")
        self.assertEqual(self.reader.hub_metadata(selected, baseline)["pending"], 3)
        observed_reads = []
        original = self.reader._read
        def metadata_only(fd, path, **kwargs):
            self.assertFalse(path.startswith(("audio/", "transcripts/")))
            observed_reads.append(path)
            return original(fd, path, **kwargs)
        with mock.patch.object(self.reader, "_read", side_effect=metadata_only):
            result = self.reader.hub_metadata(selected, baseline, early_selection=[chosen.sid])
            self.assertEqual(result["pending"], 2)
            self.assertEqual(result["audioBytesRead"], 0)
            self.assertEqual(len(result["segments"]), 1)
            row = result["segments"][0]
            self.assertEqual((row["segmentID"], row["evidence"], row["audioEntryObserved"], row["audioAvailability"]),
                             (chosen.sid, "commit_and_manifest_verified", False, "not_observed"))
            self.assertEqual(row["manifestSHA256"], digest(encoded(chosen.manifest)))
            self.assertEqual(row["audioSHA256"], chosen.manifest["sha256"])
            self.assertEqual(row["exportDigest"], commit["exportDigest"])
            self.assertNotIn("not-disclosed", json.dumps(result))
            audio = next(a for a in commit["artifacts"] if a["kind"] == "audio")
            chosen.write(audio["relativePath"], chosen.audio)
            full = self.reader.hub_metadata(selected, early_selection=[chosen.sid])["segments"][0]
            self.assertTrue(full["audioEntryObserved"])
            self.assertEqual(full["evidence"], "committed_manifest_and_audio_entry")
            self.assertEqual(full["audioAvailability"], "locally_present")
            self.assertEqual((full["segmentID"], full["manifestSHA256"]), (row["segmentID"], row["manifestSHA256"]))
        self.assertTrue(observed_reads)

    def test_early_manifest_rejects_invalid_chain_and_an_unseen_evicted_parent(self):
        source = self.fixture
        commit, _ = source.commit()
        artifact = next(a for a in commit["artifacts"] if a["kind"] == "audio")
        audio = source.write(artifact["relativePath"], b"wrong size")
        def observe():
            return self.reader.hub_metadata([source.sid], early_selection=[source.sid])
        self.assertEqual(observe()["rejected"], 1)
        audio.unlink()
        audio.symlink_to(self.root / "absent")
        self.assertEqual(observe()["rejected"], 1)
        audio.unlink()
        real_sync = self.reader._sync
        def block_parent(path, value):
            if path == audio.parent:
                raise cloud.ICloudDriveError("icloud_not_downloaded", pending=True)
            return real_sync(path, value)
        with mock.patch.object(self.reader, "_sync", side_effect=block_parent):
            for result in (observe(), self.reader.hub_metadata([source.sid])):
                self.assertEqual((result["segments"], result["pending"]), ([], 1))
        manifest = next(a for a in commit["artifacts"] if a["kind"] == "manifest")
        file = self.root / manifest["relativePath"]
        data = file.read_bytes()
        file.write_bytes(b"x" * len(data))
        self.assertEqual(observe()["rejected"], 1)
        file.write_bytes(data)
        real_availability = self.reader._availability
        def replace_after_read(fd, audio_artifact):
            replacement = file.with_suffix(".tmp")
            replacement.write_bytes(data)
            replacement.replace(file)
            return real_availability(fd, audio_artifact)
        with mock.patch.object(self.reader, "_availability", side_effect=replace_after_read):
            result = observe()
            self.assertEqual((result["segments"], result["pending"]), ([], 1))

    def test_early_selection_cli_is_scoped_and_optional(self):
        self.fixture.commit()
        for early in (False, True):
            scope = {"selection": [self.fixture.sid]}
            if early:
                scope["earlySelection"] = [self.fixture.sid]
            output = io.StringIO()
            with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(scope))), redirect_stdout(output):
                code = cloud.main(["--library-root", str(self.root), "--library-id", self.fixture.library, "hub-metadata"])
            result = json.loads(output.getvalue())
            self.assertEqual(code, 0)
            self.assertEqual((len(result["segments"]), result["pending"]), (1, 0) if early else (0, 1))

    def test_cli_returns_one_pending_json_for_unsynced_root(self):
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            code = cloud.main(["--library-root", str(self.root / "not-synced"), "list"])
        self.assertEqual(code, 2)
        self.assertEqual(len(stdout.getvalue().splitlines()), 1)
        result = json.loads(stdout.getvalue())
        self.assertEqual(result["status"], "pending")
        self.assertFalse(result["cloudSyncComplete"])

    def test_operation_leaves_selected_library_bytes_and_names_unchanged(self):
        self.fixture.commit("合成正文", audio_present=True)
        before = {str(path.relative_to(self.root)): path.read_bytes() for path in self.root.rglob("*") if path.is_file()}
        self.reader.list_segments()
        self.reader.read_transcript(self.fixture.sid)
        after = {str(path.relative_to(self.root)): path.read_bytes() for path in self.root.rglob("*") if path.is_file()}
        self.assertEqual(before, after)

    def test_phone_local_identity_cache_cannot_authorize_tampered_mac_content(self):
        commit, path = self.fixture.commit("SYNTHETIC")
        commit["localFileIdentities"] = {"untrusted-phone-cache": {"inode": 42, "sha256": "a" * 64}}
        path.write_bytes(encoded(commit))
        self.assertEqual(self.reader.read_transcript(self.fixture.sid)["content"]["text"], "SYNTHETIC")
        artifact = next(item for item in commit["artifacts"] if item["kind"] == "transcriptJSON")
        target = self.root / artifact["relativePath"]
        target.write_bytes(target.read_bytes().replace(b"SYNTHETIC", b"TAMPERED!"))
        self.rejected(lambda: self.reader.read_transcript(self.fixture.sid), "artifact_digest_mismatch")

    def test_parent_swapped_to_symlink_during_content_read_is_rejected(self):
        commit, _ = self.fixture.commit("SYNTHETIC")
        artifact = next(item for item in commit["artifacts"] if item["kind"] == "transcriptJSON")
        target = self.root / artifact["relativePath"]
        inode = target.stat().st_ino
        actual_read = cloud.os.read
        swapped = False

        def racing_read(descriptor, size):
            nonlocal swapped
            result = actual_read(descriptor, size)
            if result and not swapped and os.fstat(descriptor).st_ino == inode:
                swapped = True
                parent = target.parent
                moved = parent.with_name("moved-synthetic-transcripts")
                parent.rename(moved)
                parent.symlink_to(moved, target_is_directory=True)
            return result

        with mock.patch.object(cloud.os, "read", side_effect=racing_read):
            self.rejected(lambda: self.reader.read_transcript(self.fixture.sid), "unsafe_directory")
        self.assertTrue(swapped)

    @unittest.skipUnless(sys.platform == "darwin", "Mac thread materialization policy")
    def test_no_download_thread_policy_covers_reads_and_is_restored_on_failure(self):
        commit, _ = self.fixture.commit("SYNTHETIC")
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        libc.getiopolicy_np.argtypes = [ctypes.c_int, ctypes.c_int]
        libc.getiopolicy_np.restype = ctypes.c_int
        prior = libc.getiopolicy_np(3, 1)
        actual_open = cloud.os.open
        opens = []

        def guarded_open(path, *args, **kwargs):
            opens.append(str(path))
            self.assertEqual(libc.getiopolicy_np(3, 1), 1)
            return actual_open(path, *args, **kwargs)

        with mock.patch.object(cloud.os, "open", side_effect=guarded_open):
            self.reader.read_transcript(self.fixture.sid)
        self.assertTrue(opens)
        self.assertEqual(libc.getiopolicy_np(3, 1), prior)
        artifact = next(item for item in commit["artifacts"] if item["kind"] == "transcriptJSON")
        target = self.root / artifact["relativePath"]
        target.write_bytes(target.read_bytes().replace(b"SYNTHETIC", b"TAMPERED!"))
        self.rejected(lambda: self.reader.read_transcript(self.fixture.sid), "artifact_digest_mismatch")
        self.assertEqual(libc.getiopolicy_np(3, 1), prior)

    def test_oversized_text_is_explicitly_rejected_without_partial_content(self):
        commit, _ = self.fixture.commit("SYNTHETIC")
        artifact = next(item for item in commit["artifacts"] if item["kind"] == "transcriptJSON")
        target = self.root / artifact["relativePath"]
        with target.open("wb") as stream:
            stream.truncate(cloud.MAX_METADATA + 1)
        self.rejected(lambda: self.reader.read_transcript(self.fixture.sid), "artifact_too_large")

    @unittest.skipUnless(sys.platform == "darwin", "Mac no-download policy")
    def test_unavailable_no_download_policy_refuses_before_opening_files(self):
        self.fixture.commit("SYNTHETIC")
        native = mock.MagicMock()
        native.getiopolicy_np.return_value = 0
        native.setiopolicy_np.return_value = -1
        with mock.patch.object(cloud.ctypes, "CDLL", return_value=native), mock.patch.object(cloud.os, "open") as opened:
            self.rejected(self.reader.list_segments, "no_download_policy_unavailable", pending=True)
        opened.assert_not_called()

    def test_standalone_cli_reads_explicit_library_without_service_or_pythonpath(self):
        self.fixture.commit("合成CLI正文")
        script = Path(__file__).resolve().parents[2] / "scripts" / "read-icloud-drive-library.py"
        environment = {key: value for key, value in os.environ.items() if key != "PYTHONPATH"}
        process = subprocess.run([sys.executable, "-B", str(script), "--library-root", str(self.root),
            "--library-id", self.fixture.library, "read-transcript", self.fixture.sid, "--format", "text"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, check=False, timeout=10)
        self.assertEqual(process.returncode, 0, process.stderr.decode())
        self.assertEqual(process.stderr, b"")
        result = json.loads(process.stdout)
        self.assertEqual(result["content"], "合成CLI正文\n")
        self.assertEqual(result["audioBytesRead"], 0)


if __name__ == "__main__":
    unittest.main()
