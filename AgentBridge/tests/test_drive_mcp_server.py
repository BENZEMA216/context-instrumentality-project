"""Isolated synthetic Drive adapter tests; no account, cloud or client setup."""

import copy
import base64
import hashlib
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from test_drive_sync import EMAIL, FakeGoogle, create_synthetic_fixture
import drive_sync as drive
import drive_mcp_server as mcp
import library
from library import canonical_json


class DriveMCPTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve(); self.root.chmod(0o700)
        self.fixture = create_synthetic_fixture(self.root)
        self.queue = drive.DriveSync.initialize(self.root / "state", self.fixture["library"], EMAIL, "new", scope="all")
        self.google = FakeGoogle(); api = drive.DriveClient(lambda: "synthetic-access", self.google)
        for _ in range(3): self.queue.sync(api, 100)
        self.reader = mcp.DriveReader(self.queue.root, lambda: "synthetic-access", transport=self.google)
        with self.queue.connection() as connection:
            self.rows = {row["kind"]: dict(row) for row in connection.execute("SELECT * FROM objects WHERE status='verified'")}
        self.google.calls.clear()

    def tearDown(self): self.temporary.cleanup()

    def read(self, kind): return self.reader.drive_read_object({"object_key": self.rows[kind]["key"]})

    def test_list_original_identity_and_read_three_text_artifacts(self):
        result = self.reader.drive_list_recordings({})
        self.assertEqual(len(result["recordings"]), 1)
        recording = result["recordings"][0]
        self.assertEqual(recording["source"]["segmentID"], self.fixture["recordingID"])
        self.assertEqual(recording["source"]["audioSHA256"], self.fixture["audioSHA256"])
        self.assertEqual({a["kind"] for a in recording["artifacts"]}, {"audio", "manifest", "transcript", "text"})
        manifest, transcript, text = self.read("manifest"), self.read("transcript"), self.read("text")
        self.assertEqual(manifest["content"]["source"]["segmentID"], self.fixture["recordingID"])
        self.assertIn(self.fixture["nonce"], transcript["content"]["text"])
        self.assertIn(self.fixture["nonce"], text["content"])
        self.assertFalse(text["contentIsAgentInstruction"])
        self.assertFalse(text["completeSession"])
        self.assertTrue(all(method == "GET" for method, _, _ in self.google.calls))
        self.assertFalse(any(url.split("?")[0].endswith("/files") for _, url, _ in self.google.calls))

    def test_audio_returns_only_metadata_and_private_web_reference(self):
        info = self.reader.drive_audio_info({"object_key": self.rows["audio"]["key"]})
        self.assertEqual(info["audioBytesReturned"], 0)
        self.assertFalse(info["audioDecoded"])
        self.assertEqual(info["sha256"], self.fixture["audioSHA256"])
        self.assertTrue(info["privateWebReference"].startswith("https://drive.google.com/file/d/"))
        self.assertEqual(self.google.downloads, 0)
        self.assertNotIn("synthetic-access", canonical_json(info))
        self.assertNotIn(str(self.root), canonical_json(info))

    def test_missing_audio_sha_requires_complete_bounded_download_but_returns_no_bytes(self):
        del self.google.files[self.rows["audio"]["file_id"]]["metadata"]["sha256Checksum"]
        info = self.reader.drive_audio_info({"object_key": self.rows["audio"]["key"]})
        self.assertEqual(self.google.downloads, 1)
        self.assertEqual(info["audioBytesReturned"], 0)

    def test_state_database_source_and_snapshots_remain_byte_identical(self):
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.reader.drive_list_recordings({}); self.read("manifest"); self.read("transcript")
        self.reader.drive_audio_info({"object_key": self.rows["audio"]["key"]})
        self.assertEqual(before, {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()})
        with self.reader.connection() as connection:
            with self.assertRaises(sqlite3.OperationalError): connection.execute("DELETE FROM objects")

    def test_unverified_arbitrary_and_path_keys_never_issue_media_request(self):
        for key in ("../../token.json", "https://evil.invalid", "' OR 1=1 --", "unknown", self.rows["changes"]["key"]):
            with self.subTest(key=key):
                with self.assertRaises(drive.DriveError): self.reader.drive_read_object({"object_key": key})
        with self.queue.connection() as connection:
            connection.execute("UPDATE objects SET status='pending' WHERE key=?", (self.rows["text"]["key"],))
        with self.assertRaises(drive.DriveError): self.read("text")
        self.assertFalse(self.google.calls)

    def test_wrong_account_stops_before_file_access(self):
        self.google.email = "other@example.invalid"
        with self.assertRaises(drive.DriveError) as raised: self.read("text")
        self.assertEqual(raised.exception.code, "account_mismatch")
        self.assertEqual(len(self.google.calls), 1)

    def test_shared_folder_or_file_moved_or_shared_after_publication_rejected(self):
        folder = self.queue.configuration["folderID"]
        self.google.shared.add(folder)
        with self.assertRaises(drive.DriveError): self.reader.drive_list_recordings({})
        self.assertEqual(self.google.downloads, 0)
        self.google.shared.clear()
        file_id = self.rows["text"]["file_id"]
        self.google.shared.add(file_id)
        with self.assertRaises(drive.DriveError): self.read("text")
        self.assertEqual(self.google.downloads, 0)
        self.google.shared.clear()
        self.google.files[file_id]["metadata"]["parents"] = ["unselectedFolder"]
        with self.assertRaises(drive.DriveError): self.read("text")
        self.assertEqual(self.google.downloads, 0)

    def test_sharing_changed_during_download_cannot_produce_success(self):
        original = self.google.request
        def change_after(*args, **kwargs):
            reply = original(*args, **kwargs)
            if "alt=media" in args[1]: self.google.shared.add(self.rows["text"]["file_id"])
            return reply
        with mock.patch.object(self.google, "request", side_effect=change_after):
            with self.assertRaises(drive.DriveError) as raised: self.read("text")
        self.assertEqual(raised.exception.code, "destination_not_private_owned")

    def test_download_bytes_hash_is_checked_even_when_remote_metadata_lies(self):
        file_id = self.rows["text"]["file_id"]
        old = self.google.files[file_id]["data"]
        self.google.files[file_id]["data"] = b"X" * len(old)
        with self.assertRaises(drive.DriveError) as raised: self.read("text")
        self.assertEqual(raised.exception.code, "remote_integrity_mismatch")

    def test_download_oversize_and_selected_maximum_fail_closed(self):
        file_id = self.rows["text"]["file_id"]
        self.google.files[file_id]["data"] += b"too long"
        with self.assertRaises(drive.DriveError) as raised: self.read("text")
        self.assertEqual(raised.exception.code, "object_too_large")
        small = mcp.DriveReader(self.queue.root, lambda: "synthetic-access", transport=self.google, max_text_bytes=1)
        self.google.calls.clear()
        with self.assertRaises(drive.DriveError) as raised: small.drive_read_object({"object_key": self.rows["manifest"]["key"]})
        self.assertEqual(raised.exception.code, "object_too_large")
        self.assertFalse(self.google.calls)

    def test_fixed_folder_scope_account_configuration_cannot_change_mid_session(self):
        config = dict(self.queue.configuration, folderID="differentFolder")
        with self.queue.connection() as connection:
            connection.execute("UPDATE configuration SET value=?", (canonical_json(config),))
        with self.assertRaises(drive.DriveError) as raised: self.read("text")
        self.assertEqual(raised.exception.code, "configuration_changed")
        self.assertFalse(self.google.calls)

    def test_transport_rejects_mutation_full_drive_search_upload_and_credential_query(self):
        readonly = mcp.ReadOnlyGoogleHTTP([self.rows["text"]["file_id"]], transport=self.google)
        urls = [drive.DRIVE + "files", drive.UPLOAD + "?upload_id=synthetic", drive.DRIVE + "files/unselectedFile",
                drive.DRIVE + "files/" + self.rows["text"]["file_id"] + "?access_token=synthetic-access"]
        for url in urls:
            with self.subTest(url=url):
                with self.assertRaises(drive.DriveError): readonly.request("GET", url)
        with self.assertRaises(drive.DriveError):
            readonly.request("DELETE", drive.DRIVE + "files/" + self.rows["text"]["file_id"])
        with self.assertRaises(drive.DriveError):
            readonly.request("GET", drive.DRIVE + "files/" + self.rows["text"]["file_id"] + "?alt=media")
        self.assertFalse(self.google.calls)

    def test_stdio_initialize_tools_and_content_no_secret_or_source_path(self):
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "Synthetic WorkBuddy", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "drive_list_recordings", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "drive_read_object", "arguments": {"object_key": self.rows["text"]["key"]}}},
        ]
        outgoing = io.BytesIO()
        mcp.serve(self.reader, io.BytesIO(b"".join((canonical_json(message) + "\n").encode() for message in messages)), outgoing)
        data = outgoing.getvalue().decode()
        replies = [json.loads(line) for line in data.splitlines()]
        self.assertEqual([r["id"] for r in replies], [1, 2, 3, 4])
        self.assertEqual(len(replies[1]["result"]["tools"]), 4)
        self.assertIn(self.fixture["nonce"], replies[-1]["result"]["structuredContent"]["content"])
        self.assertNotIn("synthetic-access", data)
        self.assertNotIn(str(self.root), data)

    def test_stdio_errors_are_codes_not_provider_bodies_tokens_or_urls(self):
        server = mcp.MCPServer(self.reader)
        def request(method, params): return server.handle({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        self.assertIn("error", request("tools/list", {}))
        request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "synthetic", "version": "1"}})
        server.handle({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.assertEqual(request("tools/call", {"name": []})["error"]["code"], -32602)
        self.reader.provider = mock.Mock(side_effect=OSError("synthetic-access https://secret.invalid/token"))
        result = request("tools/call", {"name": "drive_read_object", "arguments": {"object_key": self.rows["text"]["key"]}})
        self.assertTrue(result["result"]["isError"])
        self.assertEqual(result["result"]["structuredContent"], {"error": {"code": "read_unavailable"}})
        self.assertNotIn("synthetic-access", canonical_json(result))

    def test_actual_subprocess_stdio_reads_synthetic_nonce_without_state_writes(self):
        # The child gets only this test's in-memory Google world. It executes the
        # production reader/stdio dispatcher without credentials or real HTTP.
        script = """
import base64, json, sys
from test_drive_sync import FakeGoogle
from drive_mcp_server import DriveReader, serve
world = json.loads(sys.stdin.buffer.readline())
google = FakeGoogle()
google.files = {key: {'metadata': value['metadata'], 'data': base64.b64decode(value['data']) if value['data'] is not None else None} for key, value in world.items()}
serve(DriveReader(sys.argv[1], lambda: 'synthetic-access', transport=google))
"""
        world = {key: {"metadata": value["metadata"], "data": base64.b64encode(value["data"]).decode() if value["data"] is not None else None} for key, value in self.google.files.items()}
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "Synthetic subprocess WorkBuddy", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "drive_read_object", "arguments": {"object_key": self.rows["text"]["key"]}}},
        ]
        before = self.queue.database.read_bytes()
        result = subprocess.run([sys.executable, "-B", "-c", script, str(self.queue.root)],
            input=(canonical_json(world) + "\n" + "".join(canonical_json(message) + "\n" for message in messages)),
            capture_output=True, text=True, timeout=10,
            env={"PYTHONPATH": str(Path(__file__).resolve().parent) + ":" + str(Path(__file__).resolve().parents[1]), "PYTHONDONTWRITEBYTECODE": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([reply["id"] for reply in replies], [1, 2])
        self.assertIn(self.fixture["nonce"], replies[-1]["result"]["structuredContent"]["content"])
        self.assertEqual(self.queue.database.read_bytes(), before)
        self.assertNotIn("synthetic-access", result.stdout)

    def test_pagination_cursor_is_bound_to_this_library(self):
        from test_bridge import segment, write_package
        from test_transcripts import transcript_for, version2
        import library
        item = segment(1, seed=61)
        item[0]["transcript"] = transcript_for(item[0], "Second synthetic MCP segment")
        package = self.root / "extra.zip"
        write_package(package, [item], version2([item]))
        library.import_package(package, self.fixture["library"])
        for _ in range(3): self.queue.sync(drive.DriveClient(lambda: "synthetic-access", self.google), 100)
        first = self.reader.drive_list_recordings({"limit": 1})
        self.assertIsNotNone(first["nextCursor"])
        second = self.reader.drive_list_recordings({"limit": 1, "cursor": first["nextCursor"]})
        self.assertIsNone(second["nextCursor"])
        self.assertNotEqual(first["recordings"][0]["recordingID"], second["recordings"][0]["recordingID"])
        foreign = base64.urlsafe_b64encode(canonical_json({"libraryID": "other", "afterSequence": 0}).encode()).decode()
        with self.assertRaises(drive.DriveError): self.reader.drive_list_recordings({"cursor": foreign})

    def test_pagination_includes_earlier_admitted_audio_verified_after_first_page(self):
        from test_bridge import segment, write_package
        from test_transcripts import transcript_for, version2
        import library
        items = [segment(1, seed=71), segment(2, seed=73)]
        for item, _ in items: item["transcript"] = transcript_for(item, "Synthetic later publication")
        package = self.root / "extra.zip"
        write_package(package, items, version2(items)); library.import_package(package, self.fixture["library"])
        # Reproduce a publisher that has admitted A but has not receipted it
        # while B/C succeed. No production state or remote account is touched.
        with self.queue.connection() as connection:
            connection.execute("UPDATE objects SET status='pending',retry_at=9999999999 WHERE key=?", (self.rows["audio"]["key"],))
            connection.execute("DELETE FROM changes WHERE object_key=?", (self.rows["audio"]["key"],))
        api = drive.DriveClient(lambda: "synthetic-access", self.google)
        for _ in range(3): self.queue.sync(api, 100)
        first = self.reader.drive_list_recordings({"limit": 1})
        self.assertNotEqual(first["recordings"][0]["recordingID"], self.fixture["recordingID"])
        self.assertIsNotNone(first["nextCursor"])
        with self.queue.connection() as connection:
            connection.execute("UPDATE objects SET retry_at=0 WHERE key=?", (self.rows["audio"]["key"],))
        self.queue.sync(api, 100)
        later = self.reader.drive_list_recordings({"limit": 25, "cursor": first["nextCursor"]})
        self.assertEqual(len(later["recordings"]), 2)
        self.assertIn(self.fixture["recordingID"], [r["recordingID"] for r in later["recordings"]])

    def test_listing_many_transcript_versions_keeps_audio_and_bounded_newest_references(self):
        template = self.rows["text"]
        with self.queue.connection() as connection:
            for index in range(60):
                key = "text:" + self.fixture["recordingID"] + ":" + ("%064x" % index)
                connection.execute("INSERT INTO objects(key,recording_id,kind,local_name,name,mime,size,sha256,md5,source_json,file_id,status) VALUES (?,?,?,?,?,?,?,?,?,?,?,'verified')",
                    (key, template["recording_id"], "text", hashlib.sha256(key.encode()).hexdigest(), "synthetic-version-%d.txt" % index,
                     template["mime"], template["size"], template["sha256"], template["md5"], template["source_json"], "syntheticVersion%d" % index))
        recording = self.reader.drive_list_recordings({})["recordings"][0]
        self.assertEqual(len(recording["artifacts"]), 32)
        self.assertTrue(recording["olderArtifactReferencesOmitted"])
        self.assertEqual(recording["artifacts"][0]["kind"], "audio")
        self.assertEqual(recording["artifacts"][1]["objectKey"].rsplit(":", 1)[1], "%064x" % 59)

    def test_incremental_resume_reports_late_transcripts_after_audio_was_consumed(self):
        # A NEW queue sees the audio before its transcript exists. This avoids
        # fabricating a feed state: each event is committed by the real publisher.
        source = Path(self.fixture["library"])
        with sqlite3.connect(str(source / library.DB_NAME)) as connection:
            original = connection.execute("SELECT * FROM transcripts").fetchone()
            columns = [r[1] for r in connection.execute("PRAGMA table_info(transcripts)")]
            connection.execute("DELETE FROM transcripts")
        late = drive.DriveSync.initialize(self.root / "late-state", source, EMAIL, "new", scope="all")
        api = drive.DriveClient(lambda: "synthetic-access", self.google)
        for _ in range(3): late.sync(api, 100)
        reader = mcp.DriveReader(late.root, lambda: "synthetic-access", transport=self.google)
        first = reader.drive_list_changes({})
        self.assertEqual({event["kind"] for event in first["changes"]}, {"audio", "manifest"})
        self.assertFalse(first["hasMore"])
        self.assertIsNone(first["nextCursor"])
        self.assertIsNotNone(first["resumeCursor"])
        empty = reader.drive_list_changes({"cursor": first["resumeCursor"]})
        self.assertEqual(empty["changes"], [])
        self.assertEqual(empty["resumeCursor"], first["resumeCursor"])
        with sqlite3.connect(str(source / library.DB_NAME)) as connection:
            connection.execute("INSERT INTO transcripts(" + ",".join(columns) + ") VALUES (" + ",".join("?" for _ in original) + ")", original)
        late = drive.DriveSync(late.root)
        for _ in range(3): late.sync(api, 100)
        resumed = reader.drive_list_changes({"cursor": empty["resumeCursor"]})
        self.assertEqual({event["kind"] for event in resumed["changes"]}, {"manifest", "transcript", "text"})
        self.assertTrue(all(event["source"]["segmentID"] == self.fixture["recordingID"] for event in resumed["changes"]))
        self.assertTrue(all(event["publicationSequence"] > first["afterChangeSequence"] for event in resumed["changes"]))
        transcript_key = next(event["objectKey"] for event in resumed["changes"] if event["kind"] == "transcript")
        self.assertIn(self.fixture["nonce"], reader.drive_read_object({"object_key": transcript_key})["content"]["text"])
        self.assertEqual(len({event["objectKey"] for event in first["changes"] + resumed["changes"] if event["kind"] == "audio"}), 1)

    def test_changes_pagination_always_returns_durable_resume_and_cursor_types_are_separate(self):
        seen, cursor = [], None
        for _ in range(5):
            page = self.reader.drive_list_changes({"limit": 1, **({"cursor": cursor} if cursor else {})})
            seen.extend(event["publicationSequence"] for event in page["changes"])
            self.assertIsNotNone(page["resumeCursor"])
            cursor = page["resumeCursor"]
            if not page["hasMore"]: break
        self.assertEqual(len(seen), 4)
        self.assertEqual(len(set(seen)), 4)
        empty = self.reader.drive_list_changes({"cursor": cursor})
        self.assertEqual(empty["changes"], [])
        self.assertEqual(empty["resumeCursor"], cursor)
        with self.assertRaises(drive.DriveError): self.reader.drive_list_recordings({"cursor": cursor})
        snapshot = base64.urlsafe_b64encode(canonical_json({"libraryID": self.reader.library_id, "afterSequence": 0}).encode()).decode()
        with self.assertRaises(drive.DriveError): self.reader.drive_list_changes({"cursor": snapshot})
        oversized = base64.urlsafe_b64encode(canonical_json({"libraryID": self.reader.library_id, "afterChangeSequence": 2**64}).encode()).decode()
        with self.assertRaises(drive.DriveError): self.reader.drive_list_changes({"cursor": oversized})

    def test_bad_arguments_cursor_and_permissions_rejected(self):
        for arguments in ({"limit": True}, {"limit": 26}, {"cursor": "../../token.json"}, {"folder_id": "unselected"}):
            with self.subTest(arguments=arguments):
                with self.assertRaises(drive.DriveError): self.reader.drive_list_recordings(arguments)
        for arguments in ({"object_key": self.rows["text"]["key"], "max_bytes": 999999999}, {"file_id": self.rows["text"]["file_id"]}):
            with self.assertRaises(drive.DriveError): self.reader.drive_read_object(arguments)
        self.queue.database.chmod(0o644)
        with self.assertRaises(drive.DriveError): self.read("text")


if __name__ == "__main__": unittest.main()
