"""Synthetic capture metadata, legacy identity and readable time contracts."""

import copy
from datetime import datetime
import io
import hashlib
from pathlib import Path
import sqlite3
import tempfile
import unittest
import uuid

from test_bridge import envelope, segment, write_package
from test_transcripts import transcript_for, version2
from automatic import DeliveryStore
import bridge
import library


def version3(items):
    result = version2(items)
    result["schemaVersion"] = 3
    for item in result["segments"]:
        item["metadata"] = library.recording_metadata(item["manifest"])
    return result


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.destination = self.root / "library"
        self.package = self.root / "selected.zip"
        self.items = [segment()]

    def tearDown(self):
        self.temporary.cleanup()

    def import_items(self, metadata=None):
        write_package(self.package, self.items, metadata)
        return library.import_package(self.package, self.destination)

    def captured_context(self):
        manifest = self.items[0][0]["manifest"]
        manifest["timeZoneIdentifier"] = "Asia/Shanghai"
        manifest["location"] = {"latitude": 31.2304, "longitude": 121.4737,
                                "horizontalAccuracy": 12.0, "capturedAt": manifest["startedAt"] - 2000}
        return manifest

    def test_legacy_v1_v2_import_remains_idempotent_and_never_invents_context(self):
        manifest = copy.deepcopy(self.items[0][0]["manifest"])
        original = envelope(self.items)
        self.import_items(original)
        self.assertEqual(self.import_items(original)["importedSegments"], 0)
        item = self.items[0][0]
        item["transcript"] = transcript_for(item)
        self.import_items(version2(self.items))
        # v3 adds a derived envelope only, leaving the existing immutable manifest intact.
        self.assertEqual(self.import_items(version3(self.items))["importedSegments"], 0)
        catalog = library.Library(self.destination)
        result = catalog.get_recording({"recording_id": manifest["id"]})
        self.assertEqual(result["manifest"], manifest)
        self.assertEqual(result["startedAtISO8601"], "2023-11-14T22:13:20.000Z")
        self.assertEqual(result["endedAtISO8601"], "2023-11-14T22:13:20.010Z")
        self.assertEqual(result["timeZoneIdentifier"], "UTC")
        self.assertEqual(result["timeZoneSource"], "utc_fallback")
        self.assertNotIn("location", result)
        with sqlite3.connect(self.destination / library.DB_NAME) as connection:
            stored = library.parse_json(connection.execute("SELECT manifest_json FROM recordings").fetchone()[0])
        self.assertEqual(stored, manifest)

    def test_v3_mcp_tools_and_notification_preserve_original_context(self):
        manifest = self.captured_context()
        self.items[0][0]["transcript"] = transcript_for(self.items[0][0], "synthetic context")
        write_package(self.package, self.items, version3(self.items))
        store = DeliveryStore(self.root / "state", self.destination, str(uuid.uuid4()))
        raw = self.package.read_bytes()
        receipt = store.accept(io.BytesIO(raw), len(raw), str(uuid.uuid4()), hashlib.sha256(raw).hexdigest())
        self.assertEqual(receipt["recordingIDs"], [manifest["id"]])
        server = bridge.MCPServer(self.destination)
        server.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "synthetic", "version": "1"}}})
        server.handle({"jsonrpc": "2.0", "method": "notifications/initialized"})
        for name in ("list_recordings", "get_recording", "get_transcript", "get_audio_asset", "search_recordings"):
            arguments = {} if name == "list_recordings" else {"query": "context"} if name == "search_recordings" else {"recording_id": manifest["id"]}
            response = server.handle({"jsonrpc": "2.0", "id": name, "method": "tools/call", "params": {"name": name, "arguments": arguments}})
            value = response["result"]["structuredContent"]
            if "recordings" in value:
                value = value["recordings"][0]
            self.assertEqual(value["startedAt"], manifest["startedAt"])
            self.assertEqual(value["endedAt"], manifest["endedAt"])
            self.assertEqual(value["startedAtISO8601"], "2023-11-15T06:13:20.000+08:00")
            self.assertEqual(value["endedAtISO8601"], "2023-11-15T06:13:20.010+08:00")
            self.assertEqual(value["timeZoneSource"], "recorded")
            self.assertEqual(value["location"]["capturedAtISO8601"], "2023-11-15T06:13:18.000+08:00")
            self.assertEqual(value["location"]["latitude"], 31.2304)
        event = store.pending("synthetic-target")[0]
        self.assertEqual(event["recordings"][0]["startedAtISO8601"], "2023-11-15T06:13:20.000+08:00")
        self.assertEqual(event["recordings"][0]["location"]["horizontalAccuracy"], 12)
        self.assertNotIn("synthetic context", library.canonical_json(event))
        self.assertEqual(store.enqueue_available([manifest["id"]]), 0)

    def test_dst_boundaries_use_independent_offsets_and_preserve_milliseconds(self):
        manifest = self.items[0][0]["manifest"]
        manifest.update(timeZoneIdentifier="America/New_York", startedAt=1730611800123, endedAt=1730615400456)
        metadata = library.recording_metadata(manifest)
        self.assertEqual(metadata["startedAtISO8601"], "2024-11-03T01:30:00.123-04:00")
        self.assertEqual(metadata["endedAtISO8601"], "2024-11-03T01:30:00.456-05:00")
        for field in ("startedAt", "endedAt"):
            self.assertEqual(round(datetime.fromisoformat(metadata[field + "ISO8601"]).timestamp() * 1000), manifest[field])

    def test_invalid_optional_capture_fields_and_unknown_fields_are_rejected(self):
        original = self.captured_context()
        invalid = []
        for zone in (None, "", "Not/AZone", "../etc/localtime", "localtime", "a" * 129):
            candidate = copy.deepcopy(original)
            candidate["timeZoneIdentifier"] = zone
            invalid.append(candidate)
        for field, value in (("latitude", 91), ("longitude", -181), ("latitude", True),
                             ("longitude", float("inf")), ("horizontalAccuracy", -1),
                             ("horizontalAccuracy", 100001), ("capturedAt", -1), ("capturedAt", True)):
            candidate = copy.deepcopy(original)
            candidate["location"][field] = value
            invalid.append(candidate)
        for value in (None, {}, dict(original["location"], address="invented")):
            candidate = copy.deepcopy(original)
            candidate["location"] = value
            invalid.append(candidate)
        invalid.append(dict(original, newUnknownField="unexpected"))
        for candidate in invalid:
            with self.subTest(candidate=candidate), self.assertRaises(library.BridgeError):
                library.validate_manifest(candidate, library.Limits().max_file_bytes)

    def test_v3_derived_metadata_cannot_override_original_time_zone_or_location(self):
        self.captured_context()
        valid = version3(self.items)
        variants = []
        for field, value in (("startedAt", 1700000000001), ("startedAtISO8601", "2023-11-15T06:13:20.000"),
                             ("endedAtISO8601", "2023-11-15T06:13:20.001+08:00"),
                             ("timeZoneSource", "utc_fallback"), ("timeZoneIdentifier", "UTC")):
            candidate = copy.deepcopy(valid)
            candidate["segments"][0]["metadata"][field] = value
            variants.append(candidate)
        for field, value in (("latitude", 0), ("capturedAtISO8601", "2023-11-15T06:13:19.000+08:00")):
            candidate = copy.deepcopy(valid)
            candidate["segments"][0]["metadata"]["location"][field] = value
            variants.append(candidate)
        missing = copy.deepcopy(valid)
        del missing["segments"][0]["metadata"]
        variants.append(missing)
        for candidate in variants:
            with self.subTest(metadata=candidate), self.assertRaises(library.BridgeError):
                library.validate_export(candidate, library.Limits())

    def test_existing_context_cannot_be_backfilled_or_replaced(self):
        self.import_items()
        self.captured_context()
        with self.assertRaises(library.BridgeError) as raised:
            self.import_items(version3(self.items))
        self.assertEqual(raised.exception.code, "conflict")
        result = library.Library(self.destination).get_recording({"recording_id": self.items[0][0]["manifest"]["id"]})
        self.assertNotIn("location", result)
        self.assertEqual(result["timeZoneSource"], "utc_fallback")

    def test_all_export_versions_reject_local_calendar_overflow_before_import(self):
        for version in (1, 2):
            for field in ("startedAt", "location"):
                with self.subTest(version=version, field=field):
                    items = [segment()]
                    manifest = items[0][0]["manifest"]
                    manifest["timeZoneIdentifier"] = "Asia/Shanghai"
                    if field == "startedAt":
                        manifest["startedAt"] = manifest["endedAt"] = library.MAX_TIMESTAMP
                    else:
                        manifest["location"] = {"latitude": 0, "longitude": 0, "horizontalAccuracy": 5,
                                                "capturedAt": library.MAX_TIMESTAMP}
                    metadata = envelope(items) if version == 1 else version2(items)
                    write_package(self.package, items, metadata)
                    with self.assertRaises(library.BridgeError):
                        library.import_package(self.package, self.destination)
                    self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
