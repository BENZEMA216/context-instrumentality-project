"""Synthetic examples use the real native export contracts; no user library is read."""
import base64
import hashlib
import json
from pathlib import Path
import tempfile
import threading
import unittest
import uuid
from zipfile import ZipFile
from unittest import mock

from hub import contract
from hub.agent import HubClient
from hub.imports import import_file, recording_source
from hub.server import HubHTTP
from hub.store import Store


class NativeImportTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.store = Store(self.root / "test.sqlite3")
        http = HubHTTP(("127.0.0.1", 0), self.store, "owner-test", "agent-test")
        self.http = http
        self.client = HubClient(f"http://127.0.0.1:{http.server_port}", "owner-test")
        thread = threading.Thread(target=http.serve_forever, kwargs={"poll_interval": 0.01})
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    @staticmethod
    def item():
        return {"id": "id-not-a-uuid-in-legacy", "title": "Synthetic", "application": "test.local",
                "firstCopiedAt": "2026-07-01T09:00:00Z", "lastCopiedAt": "2026-07-01T09:00:01Z",
                "numberOfCopies": 2, "contents": [{"type": "public.utf8-plain-text", "text": "offline check"},
                                                   {"type": "public.png", "base64": "aW1hZ2U="}]}

    def test_snapshot_retry_edit_conflict_private_marker_and_opt_in(self):
        item = self.item()
        hidden = {**item, "id": "private-id", "contents": [{"type": "org.nspasteboard.ConcealedType",
                                                           "text": "withheld-fixture"}]}
        data = {"schemaVersion": 1, "revision": 3, "deviceID": "test-mac",
                "updatedAt": "2026-07-01T09:00:02Z", "items": [item, hidden]}
        path = self.write("clipboard.json", data)
        result = import_file(self.client, path, "clipcontext")
        self.assertEqual((result["created"], result["skipped"]), (1, 1))
        self.assertEqual(import_file(self.client, path, "clipcontext")["unchanged"], 1)
        data.update(revision=4, updatedAt="2026-07-01T09:00:05Z")
        self.write("clipboard.json", data)
        self.assertEqual(import_file(self.client, path, "clipcontext")["unchanged"], 1)
        row, = self.store.list_raw()
        self.assertEqual(row["provenance"]["snapshot_revision"], 3)
        self.assertEqual(row["device_id"], "test-mac")
        self.assertEqual(row["content"]["text"], "offline check")
        self.assertNotIn("base64", str(row))
        self.assertEqual(self.store.list_raw(agent=True), [])
        with self.assertRaisesRegex(ValueError, "update-existing"):
            import_file(self.client, path, "clipcontext", "shareable")
        self.assertEqual(import_file(self.client, path, "clipcontext", "shareable", update_existing=True)["updated"], 1)
        self.assertEqual(self.store.list_raw(agent=True)[0]["context"]["app_bundle"], "test.local")
        self.assertNotIn("withheld-fixture", str(self.store.list_raw()))

    def test_raw_manifest_checksum_path_sequence_and_reuse(self):
        device = "test-mac"
        event = {**self.item(), "id": str(uuid.uuid4()), "sequence": 1}
        event["contents"][0]["base64"] = base64.b64encode(b"offline check").decode()
        updated = event["lastCopiedAt"]
        chunk = {"schemaVersion": 1, "revision": 1, "deviceID": device, "updatedAt": updated, "items": [event]}
        part = self.write("chunks/00000000.json", chunk)
        desc = {"key": "00000000", "file": "chunks/00000000.json", "revision": 1, "itemCount": 1,
                "sha256": hashlib.sha256(part.read_bytes()).hexdigest()}
        archive = {"schemaVersion": 2, "archiveType": "raw", "archiveID": str(uuid.uuid4()), "deviceID": device,
                   "revision": 1, "itemCount": 1, "updatedAt": updated, "chunks": [desc]}
        manifest = self.write("manifest.json", archive)
        self.assertEqual(import_file(self.client, manifest, "clipcontext")["created"], 1)
        row, = self.store.list_raw()
        self.assertEqual(row["provenance"]["original_id"], event["id"])
        self.assertIn(archive["archiveID"], row["provenance"]["source_id"])
        self.assertEqual(row["context"]["sequence"], 1)
        part.write_bytes(part.read_bytes() + b" ")
        with self.assertRaisesRegex(ValueError, "checksum"):
            import_file(self.client, manifest, "clipcontext")
        desc["file"] = "../another/export.json"
        self.write("manifest.json", archive)
        with self.assertRaisesRegex(ValueError, "descriptor"):
            import_file(self.client, manifest, "clipcontext")

    def test_record_for_agent_selected_zip_and_digest_bound_spans(self):
        audio = b"SYNTHETIC audio bytes"
        identifier = str(uuid.uuid4())
        session = str(uuid.uuid4())
        sha = hashlib.sha256(audio).hexdigest()
        fname = identifier + ".caf"
        manifest = {"schemaVersion": 1, "id": identifier, "sessionID": session, "sequence": 0,
                    "startedAt": 1000, "endedAt": 3000, "sampleRate": 16000, "frameCount": 32000,
                    "byteCount": len(audio), "sha256": sha, "fileName": fname}
        tr = {"schemaVersion": 1, "segmentID": identifier, "audioSHA256": sha, "locale": "zh-CN",
              "engine": "synthetic", "createdAt": 5000, "text": "合成语音",
              "spans": [{"start": 0.1, "end": 1.0, "text": "合成语音"}]}
        entry = {"manifest": manifest, "audioPath": "audio/" + fname, "transcript": tr,
                 "metadata": recording_source().recording_metadata(manifest)}
        export = {"schemaVersion": 3, "exportID": str(uuid.uuid4()), "exportedAt": 6000,
                  "transcriptStatus": "ready", "segments": [entry]}
        def write_zip(payload):
            zpath = self.root / "selected.zip"
            with ZipFile(zpath, "w") as z:
                z.writestr("selected/export.json", json.dumps(export))
                z.writestr("selected/README.md", "Synthetic archive")
                z.writestr("selected/audio/" + fname, payload)
            return zpath
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            import_file(self.client, write_zip(b"X" * len(audio)), "record-for-agent")
        self.assertEqual(self.store.list_raw(), [])
        self.assertEqual(import_file(self.client, write_zip(audio), "record-for-agent")["created"], 1)
        row, = self.store.list_raw()
        self.assertEqual(row["content"]["spans"], tr["spans"])
        self.assertTrue(row["provenance"]["audio_bytes_verified"])
        self.assertEqual(row["provenance"]["source_hash"], sha)
        tr["audioSHA256"] = "f" * 64
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            import_file(self.client, self.write("export.json", export), "record-for-agent")
        del entry["transcript"]
        export["transcriptStatus"] = "not_generated"
        import_file(self.client, self.write("export.json", export), "record-for-agent", update_existing=True)
        metadata = self.store.list_raw()[0]["content"]
        self.assertEqual(metadata["transcript_status"], "not_generated")
        self.assertNotIn("text", metadata)

    def test_generic_withheld_fields_never_enter_raw(self):
        event = {"id": "generic", "source": "voice", "kind": "transcript_segment", "t_start": 10,
                 "t_end": 11, "t_observed": 12, "privacy": {"tier": "shareable"},
                 "provenance": {"connector": "fixture", "source_id": "a"},
                 "context": {"refresh_token": "do-not-store", "withheld_fields": ["custom_value"],
                             "custom_value": "do-not-store"},
                 "content": {"text": "retain this", "excerpts": [{"text": "do-not-store", "withheld": True}]}}
        hidden = {**event, "id": "excluded", "content": {"withheld": True, "text": "do-not-store"}}
        result = import_file(self.client, self.write("events.json", [event, hidden]), "context-event")
        self.assertEqual(result["skipped"], 1)
        row, = self.store.list_raw()
        self.assertEqual(row["content"]["text"], "retain this")
        self.assertNotIn("do-not-store", str(row))

    def test_legacy_source_identity_scoped_to_exporting_device(self):
        base = {"schemaVersion": 1, "revision": 1, "deviceID": "device-one",
                "updatedAt": "2026-07-01T09:00:02Z", "items": [self.item()]}
        for device in ("device-one", "device-two"):
            path = self.write("clipboard.json", {**base, "deviceID": device})
            self.assertEqual(import_file(self.client, path, "clipcontext")["created"], 1)
        rows = self.store.list_raw()
        self.assertEqual(len({row["provenance"]["source_id"] for row in rows}), 2)
        self.assertEqual(len({row["provenance"]["original_id"] for row in rows}), 1)

    def test_loopback_tunnel_probes_cloud_before_any_record_or_token(self):
        self.http.mode = "cloud"
        event = {"id": "tunnel-private", "source": "window", "kind": "focus", "t_start": 5, "t_end": 10,
                 "t_observed": 11, "provenance": {"connector": "fixture", "source_id": "x"},
                 "privacy": {"tier": "local_only"}, "content": {"text": "never send this fixture"}}
        path = self.write("events.json", [event])
        with mock.patch.object(self.client.http, "open", wraps=self.client.http.open) as trace:
            with self.assertRaisesRegex(ValueError, "local mode"):
                import_file(self.client, path, "context-event")
            with self.assertRaisesRegex(ValueError, "local mode"):
                self.client.request("POST", "/api/raw", event)
        for call in trace.call_args_list:
            req = call.args[0]
            self.assertEqual((req.method, req.selector, req.data), ("GET", "/health", None))
            self.assertNotIn("Authorization", dict(req.header_items()))
        self.assertEqual(trace.call_count, 2)
        self.assertEqual(self.store.list_raw(), [])

    def test_resolver_checkout_target_and_prefix(self):
        package = self.root / "target" / "hub"
        package.mkdir(parents=True)
        relative = Path("schema/context-event.schema.json")
        share = Path("share/context-instrumentality-project") / relative.name
        paths = (package.parent / relative, package.parent / share, self.root / "venv" / share)
        for path in paths:
            path.parent.mkdir(parents=True)
            path.write_text("fixture", encoding="utf-8")
        with mock.patch.object(contract, "__file__", str(package / "contract.py")), \
                mock.patch.object(contract.sysconfig, "get_path", return_value=str(self.root / "venv")):
            for expected in paths:
                self.assertEqual(contract.data_file(relative).resolve(), expected.resolve())
                expected.unlink()
            with self.assertRaises(FileNotFoundError):
                contract.data_file(relative)

    def test_mixed_remote_payload_rejected_before_any_send(self):
        conn = HubClient("https://never-connect.invalid", "owner-test")
        event = {"id": "one", "source": "browser", "kind": "page_read", "t_start": 10, "t_end": 10,
                 "t_observed": 11, "provenance": {"connector": "fixture", "source_id": "a"},
                 "privacy": {"tier": "shareable"}}
        path = self.write("events.json", [event, {**event, "id": "two", "privacy": {"tier": "local_only"}}])
        with self.assertRaisesRegex(ValueError, "local_only"):
            import_file(conn, path, "context-event")
        with self.assertRaisesRegex(ValueError, "local_only"):
            import_file(self.client, path, "context-event", mode="cloud")
        with self.assertRaisesRegex(ValueError, "local_only"):
            import_file(conn, self.root / "never-read.zip", "record-for-agent")
        self.assertEqual(self.store.list_raw(), [])


if __name__ == "__main__":
    unittest.main()
