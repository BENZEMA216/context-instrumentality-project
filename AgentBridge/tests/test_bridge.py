"""Synthetic fixtures only; no device recordings, accounts or user configurations."""

import copy
import hashlib
import io
import json
import math
from pathlib import Path
import sqlite3
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import uuid
import warnings
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bridge
import library


def synthetic_caf(seed=1):
    """Small mono signed-16 PCM CAF; used only for transport/hash tests, not playback validation."""
    pcm = b"".join(struct.pack("<h", int(4000 * math.sin((i + seed) * 0.2))) for i in range(160))
    description = struct.pack(">d4s5I", 16000.0, b"lpcm", 12, 2, 1, 1, 16)
    return (b"caff\x00\x01\x00\x00" + b"desc" + struct.pack(">q", len(description)) + description
            + b"data" + struct.pack(">qI", len(pcm) + 4, 0) + pcm)


def segment(sequence=0, session_id=None, identifier=None, seed=1):
    content = synthetic_caf(seed)
    identifier = identifier or str(uuid.uuid4())
    manifest = {"schemaVersion": 1, "id": identifier, "sessionID": session_id or str(uuid.uuid4()),
                "sequence": sequence, "startedAt": 1700000000000 + sequence * 1000,
                "endedAt": 1700000000010 + sequence * 1000, "sampleRate": 16000.0,
                "frameCount": 160, "fileName": identifier + ".caf", "byteCount": len(content),
                "sha256": hashlib.sha256(content).hexdigest()}
    return {"manifest": manifest, "audioPath": "audio/" + identifier + ".caf"}, content


def envelope(items):
    return {"schemaVersion": 1, "exportID": str(uuid.uuid4()), "exportedAt": 1700000100000,
            "transcriptStatus": "not_generated", "segments": [item[0] for item in items]}


def write_package(path, items, metadata=None, prefix="", extra=None, compression=zipfile.ZIP_STORED):
    metadata = metadata or envelope(items)
    with zipfile.ZipFile(path, "w", compression=compression) as archive:
        if prefix:
            archive.writestr(prefix, b"")
        archive.writestr(prefix + "audio/", b"")
        archive.writestr(prefix + "export.json", library.canonical_json(metadata))
        archive.writestr(prefix + "README.md", "Synthetic export. Only selected segments; no transcript.\n")
        for item, content in items:
            archive.writestr(prefix + item["audioPath"], content)
        for name, content in extra or []:
            archive.writestr(name, content)
    return metadata


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.package = self.root / "selected.zip"
        self.destination = self.root / "library"
        self.items = [segment(0), segment(1)]

    def tearDown(self):
        self.temporary.cleanup()

    def library(self):
        return library.Library(self.destination)

    def expect_rejected(self, code):
        with self.assertRaises(library.BridgeError) as raised:
            library.import_package(self.package, self.destination)
        self.assertEqual(raised.exception.code, code)
        self.assertFalse((self.destination / library.DB_NAME).exists())

    def test_selected_files_only_round_trip_and_source_unchanged(self):
        excluded, _ = segment(99)
        write_package(self.package, self.items)
        before = self.package.read_bytes()
        result = library.import_package(self.package, self.destination)
        self.assertEqual(result["importedSegments"], 2)
        self.assertEqual(self.package.read_bytes(), before)
        records = self.library().list_recordings({})["recordings"]
        self.assertEqual({x["recordingID"] for x in records}, {x[0]["manifest"]["id"] for x in self.items})
        with self.assertRaises(library.BridgeError) as raised:
            self.library().get_recording({"recording_id": excluded["manifest"]["id"]})
        self.assertEqual(raised.exception.code, "not_found")
        for item, content in self.items:
            asset = self.library().get_audio_asset({"recording_id": item["manifest"]["id"]})
            self.assertEqual(Path(asset["localPath"]).read_bytes(), content)
            self.assertEqual(asset["transcriptStatus"], "not_generated")
            self.assertNotIn("data", asset)
            self.assertFalse(asset["audioDecoded"])

    def test_system_zip_single_top_folder(self):
        write_package(self.package, self.items, prefix="Record-for-Agent-" + str(uuid.uuid4()) + "/")
        result = library.import_package(self.package, self.destination)
        self.assertEqual(result["importedSegments"], 2)

    def test_reimport_identical_export_and_overlapping_selection_are_idempotent(self):
        metadata = write_package(self.package, self.items)
        library.import_package(self.package, self.destination)
        again = library.import_package(self.package, self.destination)
        self.assertEqual(again["status"], "unchanged")
        self.assertEqual(again["importedSegments"], 0)
        metadata["exportID"] = str(uuid.uuid4())
        metadata["segments"] = [self.items[0][0]]
        write_package(self.package, self.items[:1], metadata)
        overlap = library.import_package(self.package, self.destination)
        self.assertEqual(overlap["existingSegments"], 1)
        self.assertEqual(len(list((self.destination / "objects").rglob("*.caf"))), 2)
        self.assertEqual(len(self.library().list_recordings({})["recordings"]), 2)

    def test_bad_hash_in_second_member_publishes_nothing(self):
        invalid = copy.deepcopy(self.items)
        invalid[1][0]["manifest"]["sha256"] = "a" * 64
        write_package(self.package, invalid)
        self.expect_rejected("integrity_mismatch")

    def test_manifest_size_mismatch(self):
        self.items[1][0]["manifest"]["byteCount"] += 1
        write_package(self.package, self.items)
        self.expect_rejected("integrity_mismatch")

    def test_wrong_schema_and_fabricated_transcript_rejected(self):
        for key, value in (("schemaVersion", True), ("schemaVersion", 3), ("transcriptStatus", "generated")):
            with self.subTest(key=key, value=value):
                metadata = envelope(self.items)
                metadata[key] = value
                write_package(self.package, self.items, metadata)
                self.expect_rejected("invalid_schema")

    def test_extreme_sample_rates_are_rejected_without_poisoning_catalog(self):
        for rate in (10**400, 1e-320, 0, True):
            with self.subTest(rate=str(rate)):
                items = copy.deepcopy(self.items)
                items[0][0]["manifest"]["sampleRate"] = rate
                write_package(self.package, items)
                self.expect_rejected("invalid_schema")

    def test_zip_crc_corruption_is_rejected_before_any_catalog_write(self):
        write_package(self.package, self.items)
        with zipfile.ZipFile(self.package) as archive:
            info = archive.getinfo(self.items[1][0]["audioPath"])
        data = bytearray(self.package.read_bytes())
        name_length, extra_length = struct.unpack("<HH", data[info.header_offset + 26:info.header_offset + 30])
        content_offset = info.header_offset + 30 + name_length + extra_length
        data[content_offset + info.file_size - 1] ^= 1
        self.package.write_bytes(data)
        self.expect_rejected("invalid_archive")

    def test_uuid_and_audio_path_must_match(self):
        self.items[0][0]["audioPath"] = "audio/../../escaped.caf"
        write_package(self.package, self.items)
        self.expect_rejected("invalid_archive")
        self.assertFalse((self.root / "escaped.caf").exists())

    def test_unselected_audio_and_unsafe_extra_members_rejected(self):
        for path in ("audio/" + str(uuid.uuid4()) + ".caf", "../escape", "/absolute", "audio\\escape", "__MACOSX/resource"):
            with self.subTest(path=path):
                write_package(self.package, self.items, extra=[(path, b"not selected")])
                with self.assertRaises(library.BridgeError):
                    library.import_package(self.package, self.destination)
                self.assertFalse(self.destination.exists())

    def test_multiple_top_level_folders_rejected(self):
        write_package(self.package, self.items, prefix="payload/", extra=[("other/README.md", b"extra")])
        self.expect_rejected("invalid_archive")

    def test_duplicate_zip_entry_rejected(self):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            write_package(self.package, self.items, extra=[("README.md", b"duplicate")])
        self.expect_rejected("invalid_archive")

    def test_zip_symlink_rejected(self):
        write_package(self.package, self.items)
        link = zipfile.ZipInfo("link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(self.package, "a") as archive:
            archive.writestr(link, "/outside")
        self.expect_rejected("invalid_archive")

    def test_duplicate_json_keys_rejected(self):
        with zipfile.ZipFile(self.package, "w") as archive:
            archive.writestr("export.json", '{"schemaVersion":1,"schemaVersion":1}')
            archive.writestr("README.md", "synthetic")
        self.expect_rejected("invalid_json")

    def test_limits_and_compression_bomb(self):
        write_package(self.package, self.items)
        for limits in (library.Limits(max_segments=1), library.Limits(max_archive_bytes=100),
                       library.Limits(max_total_bytes=100), library.Limits(max_metadata_bytes=10),
                       library.Limits(max_readme_bytes=10), library.Limits(max_file_bytes=20)):
            with self.subTest(limits=limits):
                with self.assertRaises(library.BridgeError) as raised:
                    library.import_package(self.package, self.destination, limits)
                self.assertEqual(raised.exception.code, "limit_exceeded")
        huge = b"\0" * (1024 * 1024)
        item, _ = segment()
        item["manifest"]["byteCount"] = len(huge)
        item["manifest"]["sha256"] = hashlib.sha256(huge).hexdigest()
        write_package(self.package, [(item, huge)], compression=zipfile.ZIP_DEFLATED)
        with self.assertRaises(library.BridgeError) as raised:
            library.import_package(self.package, self.destination, library.Limits(max_compression_ratio=200))
        self.assertEqual(raised.exception.code, "limit_exceeded")
        result = library.import_package(self.package, self.destination)
        self.assertEqual(result["importedSegments"], 1)

    def test_conflicting_segment_cannot_publish_other_new_segments(self):
        metadata = write_package(self.package, self.items[:1])
        library.import_package(self.package, self.destination)
        invalid = copy.deepcopy(self.items)
        invalid[0][0]["manifest"]["endedAt"] += 1
        metadata = envelope(invalid)
        write_package(self.package, invalid, metadata)
        with self.assertRaises(library.BridgeError) as raised:
            library.import_package(self.package, self.destination)
        self.assertEqual(raised.exception.code, "conflict")
        self.assertEqual(len(self.library().list_recordings({})["recordings"]), 1)
        self.assertEqual(len(list((self.destination / "objects").rglob("*.caf"))), 1)

    def test_reused_export_id_different_selection_rejected(self):
        metadata = write_package(self.package, self.items)
        library.import_package(self.package, self.destination)
        metadata["segments"] = [self.items[0][0]]
        write_package(self.package, self.items[:1], metadata)
        with self.assertRaises(library.BridgeError) as raised:
            library.import_package(self.package, self.destination)
        self.assertEqual(raised.exception.code, "conflict")

    def test_reused_session_sequence_with_different_uuid_rejected(self):
        write_package(self.package, self.items[:1])
        library.import_package(self.package, self.destination)
        duplicate = segment(0, session_id=self.items[0][0]["manifest"]["sessionID"])
        write_package(self.package, [duplicate])
        with self.assertRaises(library.BridgeError) as raised:
            library.import_package(self.package, self.destination)
        self.assertEqual(raised.exception.code, "conflict")

    def test_transaction_failure_leaves_no_partial_catalog_and_retry_works(self):
        write_package(self.package, self.items[:1])
        library.import_package(self.package, self.destination)
        write_package(self.package, self.items[1:])
        with mock.patch.object(library, "_sync_directory", side_effect=OSError("synthetic interruption")):
            with self.assertRaises(OSError):
                library.import_package(self.package, self.destination)
        self.assertEqual(len(self.library().list_recordings({})["recordings"]), 1)
        recovered = library.import_package(self.package, self.destination)
        self.assertEqual(recovered["importedSegments"], 1)
        self.assertEqual(len(self.library().list_recordings({})["recordings"]), 2)

    def test_root_directory_sync_failure_happens_before_commit(self):
        write_package(self.package, self.items[:1])
        library.import_package(self.package, self.destination)
        write_package(self.package, self.items[1:])
        real_sync = library._sync_directory

        def fail_root(path):
            if path.resolve() == self.destination.resolve():
                raise OSError("synthetic final directory sync failure")
            return real_sync(path)

        with mock.patch.object(library, "_sync_directory", side_effect=fail_root):
            with self.assertRaises(OSError):
                library.import_package(self.package, self.destination)
        self.assertEqual(len(self.library().list_recordings({})["recordings"]), 1)
        self.assertEqual(library.import_package(self.package, self.destination)["importedSegments"], 1)

    def test_process_exit_after_object_publication_can_retry(self):
        write_package(self.package, self.items[:1])
        library.import_package(self.package, self.destination)
        write_package(self.package, self.items[1:])
        script = """
import os, sys
sys.path.insert(0, sys.argv[1])
import library
real_rename = os.rename
def exit_after_rename(source, destination):
    real_rename(source, destination)
    os._exit(73)
library.os.rename = exit_after_rename
library.import_package(sys.argv[2], sys.argv[3])
"""
        result = subprocess.run([sys.executable, "-B", "-c", script, str(Path(library.__file__).parent),
                                 str(self.package), str(self.destination)], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(len(self.library().list_recordings({})["recordings"]), 1)
        identifier = self.items[1][0]["manifest"]["id"]
        recovered_object = self.destination / "objects" / identifier / (identifier + ".caf")
        self.assertEqual(recovered_object.stat().st_nlink, 1)
        self.assertEqual(library.import_package(self.package, self.destination)["importedSegments"], 1)

    def test_corrupt_imported_audio_is_not_returned_as_verified(self):
        write_package(self.package, self.items)
        library.import_package(self.package, self.destination)
        identifier = self.items[0][0]["manifest"]["id"]
        (self.destination / "objects" / identifier / (identifier + ".caf")).write_bytes(b"corrupt")
        with self.assertRaises(library.BridgeError) as raised:
            self.library().get_audio_asset({"recording_id": identifier})
        self.assertEqual(raised.exception.code, "integrity_mismatch")

    def test_imported_audio_symlink_and_path_argument_are_rejected(self):
        write_package(self.package, self.items)
        library.import_package(self.package, self.destination)
        identifier = self.items[0][0]["manifest"]["id"]
        target = self.destination / "objects" / identifier / (identifier + ".caf")
        outside = self.root / "outside.caf"
        outside.write_bytes(target.read_bytes())
        target.unlink()
        target.symlink_to(outside)
        with self.assertRaises(library.BridgeError) as raised:
            self.library().get_audio_asset({"recording_id": identifier})
        self.assertEqual(raised.exception.code, "library_corrupt")
        with self.assertRaises(library.BridgeError) as raised:
            self.library().get_audio_asset({"recording_id": "../../outside.caf"})
        self.assertEqual(raised.exception.code, "invalid_arguments")

    def test_time_filter_and_keyset_pagination(self):
        write_package(self.package, self.items)
        library.import_package(self.package, self.destination)
        first = self.library().list_recordings({"limit": 1})
        second = self.library().list_recordings({"limit": 1, "cursor": first["nextCursor"]})
        self.assertNotEqual(first["recordings"][0]["recordingID"], second["recordings"][0]["recordingID"])
        self.assertIsNone(second["nextCursor"])
        filtered = self.library().list_recordings({"from_ms": 1700000001000, "to_ms": 1700000002000})
        self.assertEqual(len(filtered["recordings"]), 1)
        with self.assertRaises(library.BridgeError) as raised:
            self.library().list_recordings({"cursor": first["nextCursor"], "from_ms": 1})
        self.assertEqual(raised.exception.code, "invalid_cursor")

    def test_central_directory_entry_bomb_rejected_before_zipfile(self):
        write_package(self.package, self.items)
        payload = bytearray(self.package.read_bytes())
        offset = payload.rfind(b"PK\x05\x06")
        payload[offset + 8:offset + 12] = struct.pack("<HH", 65000, 65000)
        self.package.write_bytes(payload)
        with mock.patch.object(zipfile, "ZipFile", side_effect=AssertionError("Must not parse huge directory")):
            self.expect_rejected("limit_exceeded")


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.destination = self.root / "library"
        self.item = segment()
        package = self.root / "selected.zip"
        write_package(package, [self.item])
        library.import_package(package, self.destination)

    def tearDown(self):
        self.temporary.cleanup()

    def init(self, version="2025-11-25"):
        return {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": version, "capabilities": {}, "clientInfo": {"name": "synthetic-harness", "version": "1"}}}

    def frames(self):
        return [self.init(), {"jsonrpc": "2.0", "method": "notifications/initialized"}]

    def run_frames(self, messages):
        source = io.BytesIO(b"".join((library.canonical_json(message) + "\n").encode() for message in messages))
        output = io.BytesIO()
        bridge.serve(str(self.destination), source, output)
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def test_real_subprocess_stdio_handshake_tools_and_no_extra_stdout(self):
        requests = self.frames() + [{"jsonrpc": "2.0", "id": 2, "method": "tools/list"}]
        for index, name in enumerate(("list_recordings", "get_recording", "get_audio_asset", "get_transcript", "search_recordings"), 3):
            arguments = ({} if name == "list_recordings" else {"query": "not generated"} if name == "search_recordings"
                         else {"recording_id": self.item[0]["manifest"]["id"]})
            requests.append({"jsonrpc": "2.0", "id": index, "method": "tools/call", "params": {"name": name, "arguments": arguments}})
        result = subprocess.run([sys.executable, "-B", str(Path(bridge.__file__)), "serve", "--library", str(self.destination)],
                                input="\n".join(library.canonical_json(item) for item in requests) + "\n",
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([item["id"] for item in responses], [1, 2, 3, 4, 5, 6, 7])
        self.assertEqual(responses[0]["result"]["protocolVersion"], "2025-11-25")
        self.assertEqual({tool["name"] for tool in responses[1]["result"]["tools"]},
                         {"list_recordings", "get_recording", "get_audio_asset", "get_transcript", "search_recordings"})
        for response in responses[2:]:
            self.assertFalse(response["result"]["isError"])
        self.assertEqual(responses[-2]["result"]["structuredContent"]["transcriptStatus"], "not_generated")
        self.assertIsNone(responses[-2]["result"]["structuredContent"]["transcript"])
        self.assertEqual(responses[-1]["result"]["structuredContent"]["recordings"], [])

    def test_legacy_version_negotiation(self):
        for offered, expected in (("2025-06-18", "2025-06-18"), ("2099-01-01", "2025-11-25")):
            with self.subTest(offered=offered):
                self.assertEqual(self.run_frames([self.init(offered)])[0]["result"]["protocolVersion"], expected)

    def test_modern_probe_gets_legacy_method_error_for_client_fallback(self):
        response = self.run_frames([{"jsonrpc": "2.0", "id": 0, "method": "server/discover"}])[0]
        self.assertEqual(response["error"]["code"], -32601)

    def test_tools_require_complete_initialization(self):
        messages = [{"jsonrpc": "2.0", "id": 8, "method": "tools/list"}, self.init(),
                    {"jsonrpc": "2.0", "id": 9, "method": "tools/list"}]
        responses = self.run_frames(messages)
        self.assertEqual(responses[0]["error"]["code"], -32000)
        self.assertEqual(responses[2]["error"]["code"], -32000)

    def test_unknown_tools_invalid_path_and_notifications(self):
        messages = self.frames() + [
            {"jsonrpc": "2.0", "method": "notifications/unknown"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "delete_recording"}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_audio_asset", "arguments": {"recording_id": "../outside"}}},
            {"jsonrpc": "2.0", "id": 4, "method": "ping"}]
        responses = self.run_frames(messages)
        self.assertEqual(len(responses), 4)
        self.assertEqual(responses[1]["error"]["code"], -32602)
        self.assertTrue(responses[2]["result"]["isError"])
        self.assertEqual(responses[2]["result"]["structuredContent"]["error"]["code"], "invalid_arguments")
        self.assertEqual(responses[3]["result"], {})

    def test_parse_errors_are_json_and_stream_recovers(self):
        output = io.BytesIO()
        stream = b"not json\n" + b"x" * (bridge.MAX_MESSAGE_BYTES + 10) + b"\n"
        stream += (library.canonical_json(self.init()) + "\n").encode()
        bridge.serve(str(self.destination), io.BytesIO(stream), output)
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([x["error"]["code"] for x in responses[:2]], [-32700, -32700])
        self.assertIn("result", responses[2])

    def test_unpaired_surrogate_id_does_not_terminate_stdio(self):
        responses = self.run_frames([{"jsonrpc": "2.0", "id": "\ud800", "method": "ping"},
                                     {"jsonrpc": "2.0", "id": 2, "method": "ping"}])
        self.assertEqual(responses[0]["id"], "\ud800")
        self.assertEqual(responses[1], {"jsonrpc": "2.0", "id": 2, "result": {}})

    def test_missing_library_does_not_create_files(self):
        missing = self.root / "never-imported"
        server = bridge.MCPServer(str(missing))
        server.handle(self.init())
        server.handle({"jsonrpc": "2.0", "method": "notifications/initialized"})
        response = server.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "list_recordings"}})
        self.assertEqual(response["result"]["structuredContent"]["error"]["code"], "library_not_found")
        self.assertFalse(missing.exists())


if __name__ == "__main__":
    unittest.main()
