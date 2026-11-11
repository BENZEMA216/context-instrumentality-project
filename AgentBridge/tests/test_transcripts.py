"""Synthetic transcript imports, v1 migration, immutable revisions and real text search."""

import base64
import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import uuid
import zipfile

from test_bridge import envelope, segment, write_package
import bridge
import library


def transcript_for(item, text="今天讨论 Agent 的连接；Straße 与 iCloud。"):
    manifest = item["manifest"]
    return {"schemaVersion": 1, "segmentID": manifest["id"], "audioSHA256": manifest["sha256"],
            "locale": "zh-CN", "engine": "synthetic-fixture", "createdAt": 1700000200000,
            "text": text, "spans": [{"start": 0, "end": manifest["frameCount"] / manifest["sampleRate"], "text": text}]}


def version2(items):
    result = envelope(items)
    result["schemaVersion"] = 2
    count = sum("transcript" in item for item, _ in items)
    result["transcriptStatus"] = "not_generated" if not count else "ready" if count == len(items) else "partial"
    return result


class TranscriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.package = self.root / "selected.zip"
        self.destination = self.root / "library"
        self.items = [segment(0), segment(1), segment(2)]

    def tearDown(self):
        self.temporary.cleanup()

    def add_transcript(self, index=0, text=None):
        item = self.items[index][0]
        item["transcript"] = transcript_for(item) if text is None else transcript_for(item, text)
        return item["transcript"]

    def import_v2(self, metadata=None):
        metadata = metadata or version2(self.items)
        write_package(self.package, self.items, metadata)
        return library.import_package(self.package, self.destination)

    def get(self, index=0):
        return library.Library(self.destination).get_transcript({"recording_id": self.items[index][0]["manifest"]["id"]})

    def make_v1_catalog(self):
        metadata = write_package(self.package, self.items)
        library.import_package(self.package, self.destination)
        with sqlite3.connect(str(self.destination / library.DB_NAME)) as connection:
            connection.execute("DROP TABLE transcripts")
            connection.execute("PRAGMA user_version=1")
        return metadata

    def test_v2_roundtrip_real_status_and_no_local_paths_in_text_apis(self):
        expected = self.add_transcript()
        before = copy.deepcopy(expected)
        result = self.import_v2()
        self.assertEqual(result["transcriptStatus"], "partial")
        self.assertEqual(result["readyTranscripts"], 1)
        self.assertEqual(result["importedTranscripts"], 1)
        returned = self.get()
        self.assertEqual(returned["transcript"], before)
        self.assertEqual(returned["transcriptStatus"], "ready")
        self.assertEqual(self.get(1)["transcriptStatus"], "not_generated")
        self.assertIsNone(self.get(1)["transcript"])
        catalog = library.Library(self.destination)
        listed = catalog.list_recordings({})
        self.assertEqual([x["transcriptStatus"] for x in listed["recordings"]], ["ready", "not_generated", "not_generated"])
        metadata = catalog.get_recording({"recording_id": returned["recordingID"]})
        self.assertEqual(metadata["transcriptStatus"], "ready")
        self.assertNotIn(str(self.destination), json.dumps([returned, metadata, listed]))
        self.assertNotIn("localPath", json.dumps([returned, metadata, listed]))
        audio = catalog.get_audio_asset({"recording_id": returned["recordingID"]})
        self.assertTrue(Path(audio["localPath"]).is_file())
        self.assertEqual(audio["transcriptStatus"], "ready")

    def test_full_text_only_empty_spans_is_valid(self):
        self.add_transcript()["spans"] = []
        self.import_v2()
        self.assertEqual(self.get()["transcript"]["spans"], [])

    def test_export_status_must_match_actual_transcript_count(self):
        for included in (0, 1, 3):
            items = copy.deepcopy(self.items)
            for item, _ in items[:included]:
                item["transcript"] = transcript_for(item)
            valid = version2(items)
            for wrong in ({"not_generated", "partial", "ready"} - {valid["transcriptStatus"]}):
                with self.subTest(included=included, status=wrong):
                    invalid = copy.deepcopy(valid)
                    invalid["transcriptStatus"] = wrong
                    with self.assertRaises(library.BridgeError) as raised:
                        library.validate_export(invalid, library.Limits())
                    self.assertEqual(raised.exception.code, "invalid_schema")

    def test_v1_must_not_include_transcripts(self):
        self.add_transcript()
        with self.assertRaises(library.BridgeError):
            library.validate_export(envelope(self.items), library.Limits())

    def test_transcript_identity_hash_and_required_fields_are_checked_before_writes(self):
        mutations = [("segmentID", str(uuid.uuid4()), "integrity_mismatch"),
                     ("audioSHA256", "0" * 64, "integrity_mismatch"),
                     ("schemaVersion", True, "invalid_schema"), ("text", " \n\t", "invalid_schema"),
                     ("text", "\ud800", "invalid_schema"), ("text", "bad\0text", "invalid_schema"),
                     ("locale", "", "invalid_schema"), ("engine", "\n", "invalid_schema"),
                     ("createdAt", 1.5, "invalid_schema"), ("createdAt", -1, "invalid_schema"),
                     ("spans", None, "invalid_schema"), ("text", "字" * 90000, "limit_exceeded")]
        for key, value, code in mutations:
            with self.subTest(key=key, value=str(value)[:30]):
                items = copy.deepcopy(self.items)
                items[0][0]["transcript"] = transcript_for(items[0][0])
                items[0][0]["transcript"][key] = value
                write_package(self.package, items, version2(items))
                with self.assertRaises(library.BridgeError) as raised:
                    library.import_package(self.package, self.destination)
                self.assertEqual(raised.exception.code, code)
                self.assertFalse(self.destination.exists())

    def test_transcript_null_missing_or_extra_fields_are_rejected(self):
        good = self.add_transcript()
        candidates = [None, {key: value for key, value in good.items() if key != "locale"}, dict(good, unknown=True)]
        for candidate in candidates:
            with self.subTest(candidate=candidate):
                self.items[0][0]["transcript"] = candidate
                with self.assertRaises(library.BridgeError):
                    library.validate_export(version2(self.items), library.Limits())

    def test_span_bounds_types_nonfinite_and_text_limits(self):
        good = self.add_transcript()
        bad_spans = [{"start": -0.01, "end": 0.01, "text": "x"},
                     {"start": 0, "end": 0.0100001, "text": "x"},
                     {"start": 0.005, "end": 0.004, "text": "x"},
                     {"start": True, "end": 0.01, "text": "x"},
                     {"start": 0, "end": 10**400, "text": "x"},
                     {"start": float("nan"), "end": 0.01, "text": "x"},
                     {"start": 0, "end": float("inf"), "text": "x"},
                     {"start": 0, "end": 0.01, "text": " "},
                     {"start": 0, "end": 0.01, "text": "x", "extra": 1},
                     {"start": 0, "end": 0.01, "text": "x" * (library.MAX_SPAN_TEXT_BYTES + 1)}]
        for span in bad_spans:
            with self.subTest(span=str(span)[:100]):
                good["spans"] = [span]
                with self.assertRaises(library.BridgeError):
                    library.validate_export(version2(self.items), library.Limits())
        good["spans"] = [{"start": 0, "end": 0, "text": "x"}] * (library.MAX_TRANSCRIPT_SPANS + 1)
        with self.assertRaises(library.BridgeError) as raised:
            library.validate_export(version2(self.items), library.Limits())
        self.assertEqual(raised.exception.code, "limit_exceeded")

    def test_deep_duplicate_json_key_and_non_utf8_are_rejected(self):
        self.add_transcript()
        serialized = library.canonical_json(version2(self.items))
        duplicate = serialized.replace('"engine":"synthetic-fixture"', '"engine":"synthetic-fixture","engine":"other"')
        for encoded in (duplicate.encode("utf-8"), serialized.encode("utf-16")):
            with self.subTest(encoding=encoded[:10]):
                with zipfile.ZipFile(self.package, "w") as archive:
                    archive.writestr("export.json", encoded)
                    archive.writestr("README.md", "Synthetic only")
                    for item, content in self.items:
                        archive.writestr(item["audioPath"], content)
                with self.assertRaises(library.BridgeError) as raised:
                    library.import_package(self.package, self.destination)
                self.assertEqual(raised.exception.code, "invalid_json")
                self.assertFalse(self.destination.exists())

    def test_read_v1_library_does_not_migrate_or_modify_it(self):
        self.make_v1_catalog()
        path = self.destination / library.DB_NAME
        before = hashlib.sha256(path.read_bytes()).digest()
        self.assertIsNone(self.get()["transcript"])
        self.assertEqual(library.Library(self.destination).search_recordings({"query": "iCloud"})["recordings"], [])
        self.assertEqual(len(library.Library(self.destination).list_recordings({})["recordings"]), 3)
        self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), before)
        with sqlite3.connect(str(path)) as connection:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 1)

    def test_new_export_can_add_transcript_and_old_export_does_not_remove_it(self):
        original = self.make_v1_catalog()
        object_paths = sorted((self.destination / "objects").rglob("*.caf"))
        objects_before = [(path, path.stat().st_mtime_ns, path.read_bytes()) for path in object_paths]
        self.add_transcript()
        result = self.import_v2()
        self.assertEqual(result["importedSegments"], 0)
        self.assertEqual(result["importedTranscripts"], 1)
        self.assertEqual(self.get()["transcriptStatus"], "ready")
        self.assertEqual(objects_before, [(path, path.stat().st_mtime_ns, path.read_bytes()) for path in object_paths])
        old_items = [(dict(item, **{}) , content) for item, content in self.items]
        for item, _ in old_items:
            item.pop("transcript", None)
        # Original metadata held references to the input dictionaries; use its original v1 shape.
        original["segments"] = [item for item, _ in old_items]
        write_package(self.package, old_items, original)
        result = library.import_package(self.package, self.destination)
        self.assertEqual(result["status"], "unchanged")
        self.assertEqual(result["exportedTranscriptStatus"], "not_generated")
        self.assertEqual(result["transcriptStatus"], "partial")
        self.assertEqual(self.get()["transcriptStatus"], "ready")

    def test_same_export_id_cannot_gain_or_change_transcript(self):
        original = self.make_v1_catalog()
        self.add_transcript()
        changed = version2(self.items)
        changed["exportID"] = original["exportID"]
        with self.assertRaises(library.BridgeError) as raised:
            self.import_v2(changed)
        self.assertEqual(raised.exception.code, "conflict")
        with sqlite3.connect(str(self.destination / library.DB_NAME)) as connection:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 1)
            self.assertIsNone(connection.execute("SELECT name FROM sqlite_master WHERE name='transcripts'").fetchone())

    def test_different_export_id_cannot_replace_existing_transcript_or_publish_sibling(self):
        self.add_transcript()
        self.import_v2()
        original = copy.deepcopy(self.get()["transcript"])
        self.items[0][0]["transcript"]["text"] = "changed"
        self.add_transcript(1)
        with self.assertRaises(library.BridgeError) as raised:
            self.import_v2()
        self.assertEqual(raised.exception.code, "conflict")
        self.assertEqual(self.get()["transcript"], original)
        self.assertIsNone(self.get(1)["transcript"])

    def test_identical_transcript_reimport_is_idempotent(self):
        self.add_transcript()
        metadata = version2(self.items)
        self.import_v2(metadata)
        repeated = self.import_v2(metadata)
        self.assertEqual(repeated["status"], "unchanged")
        self.assertEqual(repeated["importedTranscripts"], 0)
        metadata["exportID"] = str(uuid.uuid4())
        self.assertEqual(self.import_v2(metadata)["importedTranscripts"], 0)

    def test_migration_and_transcripts_roll_back_on_commit_preparation_failure(self):
        self.make_v1_catalog()
        self.add_transcript()
        write_package(self.package, self.items, version2(self.items))
        with mock.patch.object(library, "_sync_directory", side_effect=OSError("synthetic interruption")):
            with self.assertRaises(OSError):
                library.import_package(self.package, self.destination)
        with sqlite3.connect(str(self.destination / library.DB_NAME)) as connection:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 1)
            self.assertIsNone(connection.execute("SELECT name FROM sqlite_master WHERE name='transcripts'").fetchone())
            self.assertEqual(connection.execute("SELECT count(*) FROM exports").fetchone()[0], 1)
        self.assertIsNone(self.get()["transcript"])
        self.assertEqual(library.import_package(self.package, self.destination)["importedTranscripts"], 1)

    def test_search_actual_text_unicode_literal_and_query_bound_pagination(self):
        self.add_transcript(0, "今天讨论 Agent 的连接，Straße，100%_完成。")
        self.add_transcript(1, "第二段 agent 连接。")
        self.import_v2()
        catalog = library.Library(self.destination)
        first = catalog.search_recordings({"query": "AGENT", "limit": 1})
        second = catalog.search_recordings({"query": "agent", "limit": 1, "cursor": first["nextCursor"]})
        self.assertEqual(len(first["recordings"]), 1)
        self.assertEqual(len(second["recordings"]), 1)
        self.assertNotEqual(first["recordings"][0]["recordingID"], second["recordings"][0]["recordingID"])
        self.assertIsNone(second["nextCursor"])
        for query, expected in (("连接", 2), ("STRASSE", 1), ("%_", 1), ("synthetic-fixture", 0), ("nonexistent", 0)):
            with self.subTest(query=query):
                self.assertEqual(len(catalog.search_recordings({"query": query})["recordings"]), expected)
        for arguments in ({"query": "different", "cursor": first["nextCursor"]},
                          {"query": "agent", "cursor": catalog.list_recordings({"limit": 1})["nextCursor"]}):
            with self.assertRaises(library.BridgeError) as raised:
                catalog.search_recordings(arguments)
            self.assertEqual(raised.exception.code, "invalid_cursor")
        with self.assertRaises(library.BridgeError):
            catalog.list_recordings({"cursor": first["nextCursor"]})

    def test_search_rejects_invalid_arguments_and_cursor(self):
        self.import_v2()
        catalog = library.Library(self.destination)
        for arguments in ({}, {"query": " "}, {"query": "\0"}, {"query": "\ud800"}, {"query": "字" * 400},
                          {"query": "x", "limit": True}, {"query": "x", "limit": 101}, {"query": "x", "unknown": 1}):
            with self.subTest(arguments=str(arguments)[:100]):
                with self.assertRaises(library.BridgeError) as raised:
                    catalog.search_recordings(arguments)
                self.assertEqual(raised.exception.code, "invalid_arguments")
        for cursor in (None, False, "%invalid", "x" * 1025, base64.urlsafe_b64encode(b"{}").decode()):
            with self.assertRaises(library.BridgeError) as raised:
                catalog.search_recordings({"query": "x", "cursor": cursor})
            self.assertEqual(raised.exception.code, "invalid_cursor")

    def test_stored_transcript_hash_or_search_text_tampering_is_rejected(self):
        self.add_transcript()
        self.import_v2()
        with sqlite3.connect(str(self.destination / library.DB_NAME)) as connection:
            connection.execute("UPDATE transcripts SET search_text='tampered'")
        with self.assertRaises(library.BridgeError) as raised:
            self.get()
        self.assertEqual(raised.exception.code, "library_corrupt")

    def test_v2_stdio_transcript_and_search_match_source(self):
        expected = copy.deepcopy(self.add_transcript())
        self.import_v2()
        messages = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "synthetic", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "get_transcript", "arguments": {
                "recording_id": self.items[0][0]["manifest"]["id"]}}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "search_recordings", "arguments": {"query": "连接"}}}]
        result = subprocess.run([sys.executable, "-B", bridge.__file__, "serve", "--library", str(self.destination)],
                                input="\n".join(library.canonical_json(message) for message in messages) + "\n",
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(responses[1]["result"]["structuredContent"]["transcript"], expected)
        self.assertEqual(len(responses[2]["result"]["structuredContent"]["recordings"]), 1)
        self.assertNotIn("localPath", result.stdout)


if __name__ == "__main__":
    unittest.main()
