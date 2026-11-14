"""Synthetic receipt-bound ASR return; no user state, audio or cloud access."""

import contextlib
import copy
import hashlib
import http.client
from http.server import HTTPServer
import io
import json
from pathlib import Path
import sqlite3
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock
import uuid

from test_bridge import segment, write_package
from test_transcripts import transcript_for, version2
import automatic
import automatic_transcripts as returned
import library


class TranscriptReturnTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.store = automatic.DeliveryStore(self.root / "state", self.root / "library", str(uuid.uuid4()))
        self.scope = {key: str(uuid.uuid4()) for key in returned.SCOPE_FIELDS}
        self.scope["receiverID"] = self.store.receiver_id
        self.entries = []

    def tearDown(self):
        self.temporary.cleanup()

    def delivered(self, sequence=0, ready=True, matching_export=True):
        item, content = segment(sequence)
        if ready:
            item["transcript"] = transcript_for(item, "合成私有文本，emoji: 🌙。")
        delivery = str(uuid.uuid4())
        envelope = version2([(item, content)])
        envelope["exportID"] = delivery if matching_export else str(uuid.uuid4())
        path = self.root / (delivery + ".zip")
        write_package(path, [(item, content)], envelope)
        raw = path.read_bytes()
        receipt = self.store.accept(io.BytesIO(raw), len(raw), delivery, hashlib.sha256(raw).hexdigest())
        manifest = item["manifest"]
        entry = {"receipt": receipt, "source": {"segmentID": manifest["id"],
            "sessionID": manifest["sessionID"], "sequence": manifest["sequence"], "audioSHA256": manifest["sha256"]}}
        self.entries.append(entry)
        return entry

    def request(self, entries=None):
        return {"schemaVersion": 1, "scope": copy.deepcopy(self.scope),
                "items": copy.deepcopy(self.entries if entries is None else entries)}

    def query(self, request=None, **options):
        return returned.query_transcripts(self.store, self.request() if request is None else request, **options)

    def asr(self, entry, status, audio_hash=None):
        path = self.store.root / "transcription"
        path.mkdir(mode=0o700, exist_ok=True)
        with sqlite3.connect(path / "transcription.sqlite3") as connection:
            connection.execute("CREATE TABLE IF NOT EXISTS jobs(recording_id TEXT PRIMARY KEY,audio_hash TEXT,status TEXT,updated_at INTEGER)")
            connection.execute("INSERT OR REPLACE INTO jobs VALUES(?,?,?,?)", (entry["source"]["segmentID"],
                audio_hash or entry["source"]["audioSHA256"], status, 1_700_000_000_123))

    @contextlib.contextmanager
    def traced_body_reads(self):
        statements = []
        original = library._connect
        def connect(*args, **kwargs):
            connection = original(*args, **kwargs)
            connection.set_trace_callback(statements.append)
            return connection
        with mock.patch.object(library, "_connect", side_effect=connect):
            yield statements

    def assert_no_body_reads(self, statements):
        self.assertFalse(any("SELECT transcript_json,search_text" in value for value in statements), statements)

    def test_ready_returns_exact_bound_canonical_bytes_without_audio_or_location(self):
        entry = self.delivered()
        with mock.patch.object(library.Library, "get_audio_asset", side_effect=AssertionError("No CAF reads")):
            result = self.query()
        self.assertEqual(result["scope"], self.scope)
        item = result["items"][0]
        self.assertEqual(item["status"], "ready")
        self.assertEqual(item["source"], entry["source"])
        raw = item["transcriptJSON"].encode("utf-8")
        self.assertEqual(len(raw), item["transcriptByteCount"])
        self.assertEqual(hashlib.sha256(raw).hexdigest(), item["transcriptSHA256"])
        value = json.loads(raw)
        self.assertEqual(value["text"], "合成私有文本，emoji: 🌙。")
        self.assertEqual(value["segmentID"], entry["source"]["segmentID"])
        self.assertNotIn("localPath", library.canonical_json(result))
        self.assertNotIn("location", library.canonical_json(result))

    def test_swift_uuid_case_is_semantic_but_scope_is_exact_echo(self):
        self.delivered()
        request = self.request()
        request["scope"] = {key: value.upper() for key, value in request["scope"].items()}
        entry = request["items"][0]
        for key in ["receiverID", "deliveryID"]:
            entry["receipt"][key] = entry["receipt"][key].upper()
        entry["receipt"]["recordingIDs"] = [value.upper() for value in entry["receipt"]["recordingIDs"]]
        for key in ["segmentID", "sessionID"]:
            entry["source"][key] = entry["source"][key].upper()
        self.assertEqual(self.query(request)["scope"], request["scope"])
        self.assertEqual(self.query(request)["items"][0]["status"], "ready")

    def test_four_sources_are_bounded_and_keep_request_order(self):
        for index in range(4):
            self.delivered(index)
        result = self.query()
        self.assertEqual([x["source"] for x in result["items"]], [x["source"] for x in self.entries])
        self.assertTrue(all(x["status"] == "ready" for x in result["items"]))

    def test_missing_running_retry_and_no_speech_never_invent_body(self):
        entries = [self.delivered(i, False) for i in range(4)]
        for entry, state in zip(entries[1:], ["running", "retry", "no_speech"]):
            self.asr(entry, state)
        result = self.query()["items"]
        self.assertEqual([x["status"] for x in result], ["pending", "pending", "retry", "no_speech"])
        for item in result:
            self.assertIsNone(item["transcriptJSON"])
            self.assertIsNone(item["transcriptSHA256"])
            self.assertIsNone(item["transcriptByteCount"])
        self.assertEqual(result[-1]["asrUpdatedAt"], 1_700_000_000_123)

    def test_ready_text_supersedes_old_no_speech_state(self):
        entry = self.delivered()
        self.asr(entry, "no_speech")
        self.assertEqual(self.query()["items"][0]["status"], "ready")

    def test_invalid_job_hash_or_unknown_status_is_unavailable(self):
        entry = self.delivered(ready=False)
        self.asr(entry, "no_speech", "0" * 64)
        self.assertEqual(self.query()["items"][0]["status"], "unavailable")
        self.asr(entry, "unexpected")
        self.assertEqual(self.query()["items"][0]["status"], "unavailable")

    def test_each_receipt_field_is_enforced_before_body_reads(self):
        self.delivered()
        changes = {"schemaVersion": 2, "receiverID": str(uuid.uuid4()), "deliveryID": str(uuid.uuid4()),
                   "archiveSHA256": "0" * 64, "recordingIDs": [str(uuid.uuid4())], "storedAt": 1}
        for field, value in changes.items():
            request = self.request(); request["items"][0]["receipt"][field] = value
            with self.subTest(field=field), self.traced_body_reads() as statements:
                with self.assertRaises(library.BridgeError):
                    self.query(request)
                self.assert_no_body_reads(statements)

    def test_each_source_field_is_enforced_before_body_reads(self):
        self.delivered()
        changes = {"segmentID": str(uuid.uuid4()), "sessionID": str(uuid.uuid4()),
                   "sequence": 99, "audioSHA256": "0" * 64}
        for field, value in changes.items():
            request = self.request(); request["items"][0]["source"][field] = value
            with self.subTest(field=field), self.traced_body_reads() as statements:
                with self.assertRaises(library.BridgeError):
                    self.query(request)
                self.assert_no_body_reads(statements)

    def test_last_bad_capability_prevents_whole_batch_body_reads(self):
        self.delivered(); self.delivered(1)
        request = self.request(); request["items"][-1]["receipt"]["storedAt"] += 1
        with self.traced_body_reads() as statements:
            with self.assertRaises(library.BridgeError) as raised:
                self.query(request)
            self.assertEqual(raised.exception.code, "transcript_not_authorized")
            self.assert_no_body_reads(statements)

    def test_wrong_scope_receiver_denied_but_other_scope_ids_only_echo(self):
        self.delivered()
        request = self.request(); request["scope"]["receiverID"] = str(uuid.uuid4())
        with self.assertRaises(library.BridgeError):
            self.query(request)
        request = self.request(); request["scope"]["grantEpoch"] = str(uuid.uuid4())
        self.assertEqual(self.query(request)["scope"], request["scope"], "This is explicitly NOT server-side grant authentication.")

    def test_manual_source_cannot_use_another_receipt(self):
        entry = self.delivered()
        item = segment(99); path = self.root / "manual.zip"
        write_package(path, [item]); library.import_package(path, self.store.library)
        request = self.request(); request["items"][0]["source"]["segmentID"] = item[0]["manifest"]["id"]
        with self.traced_body_reads() as statements:
            with self.assertRaises(library.BridgeError):
                self.query(request)
            self.assert_no_body_reads(statements)
        self.assertEqual(self.store.authorized_recording_ids(), entry["receipt"]["recordingIDs"])

    def test_missing_or_extra_export_member_denies_receipt(self):
        entry = self.delivered(); other = self.delivered(1)
        path = self.store.library / library.DB_NAME
        with sqlite3.connect(path) as connection:
            connection.execute("INSERT INTO export_members VALUES(?,?)", (entry["receipt"]["deliveryID"], other["source"]["segmentID"]))
        with self.assertRaises(library.BridgeError):
            self.query(self.request([entry]))
        with sqlite3.connect(path) as connection:
            connection.execute("DELETE FROM export_members WHERE export_id=?", (entry["receipt"]["deliveryID"],))
        with self.assertRaises(library.BridgeError):
            self.query(self.request([entry]))

    def test_legacy_different_export_still_imports_but_cannot_query(self):
        self.delivered(matching_export=False)
        self.assertEqual(self.store.status()["durableReceipts"], 1)
        with self.assertRaises(library.BridgeError):
            self.query()

    def test_pending_or_rejected_import_cannot_authorize_a_query(self):
        entry = self.delivered()
        with sqlite3.connect(self.store.database) as connection:
            connection.execute("UPDATE requests SET receipt_json=NULL WHERE id=?", (entry["receipt"]["deliveryID"],))
        with self.assertRaises(library.BridgeError):
            self.query()

    def test_malformed_schema_bounds_and_duplicate_sources_fail_closed(self):
        self.delivered()
        requests = []
        for field, value in [("schemaVersion", True), ("schemaVersion", 2), ("items", []),
                             ("items", self.request()["items"] * 5), ("items", self.request()["items"] * 2)]:
            request = self.request(); request[field] = value; requests.append(request)
        request = self.request(); request["extra"] = "not allowed"; requests.append(request)
        request = self.request(); request["items"][0]["source"]["sequence"] = True; requests.append(request)
        request = self.request(); request["items"][0]["receipt"]["storedAt"] += 0.5; requests.append(request)
        request = self.request(); request["items"][0]["receipt"]["extra"] = 1; requests.append(request)
        for request in requests:
            with self.subTest(request=request), self.assertRaises(library.BridgeError):
                self.query(request)

    def test_changed_manifest_columns_fail_before_body(self):
        self.delivered()
        with sqlite3.connect(self.store.library / library.DB_NAME) as connection:
            connection.execute("UPDATE recordings SET sequence=sequence+1")
        with self.traced_body_reads() as statements:
            with self.assertRaises(library.BridgeError):
                self.query()
            self.assert_no_body_reads(statements)

    def test_invalid_transcript_or_search_text_is_not_returned(self):
        self.delivered()
        with sqlite3.connect(self.store.library / library.DB_NAME) as connection:
            connection.execute("UPDATE transcripts SET search_text='inconsistent'")
        result = self.query()["items"][0]
        self.assertEqual(result["status"], "unavailable")
        self.assertIsNone(result["transcriptJSON"])

    def test_oversize_database_body_is_not_fetched(self):
        self.delivered()
        with sqlite3.connect(self.store.library / library.DB_NAME) as connection:
            connection.execute("UPDATE transcripts SET transcript_json=?", ("x" * (returned.MAX_RESPONSE_BYTES + 1),))
        with self.traced_body_reads() as statements:
            item = self.query()["items"][0]
            self.assertEqual(item["status"], "unavailable")
            self.assertEqual(item["reason"], "transcript_too_large")
            self.assert_no_body_reads(statements)

    def test_wire_limit_includes_nested_escaping_and_never_truncates_text(self):
        self.delivered()
        original = self.query()
        raw_size = original["items"][0]["transcriptByteCount"]
        wire_size = len((library.canonical_json(original) + "\n").encode())
        self.assertGreater(wire_size, raw_size)
        with mock.patch.object(returned, "MAX_RESPONSE_BYTES", wire_size):
            self.assertEqual(self.query()["items"][0]["status"], "ready")
        with mock.patch.object(returned, "MAX_RESPONSE_BYTES", wire_size - 1):
            response = self.query(); item = response["items"][0]
            self.assertEqual(item["status"], "unavailable")
            self.assertEqual(item["reason"], "transcript_too_large")
            self.assertIsNone(item["transcriptJSON"])
            self.assertLessEqual(len((library.canonical_json(response) + "\n").encode()), wire_size - 1)

    def test_query_is_read_only_cancellable_and_never_starts_asr(self):
        self.delivered()
        paths = [self.store.database, self.store.library / library.DB_NAME]
        before = [hashlib.sha256(p.read_bytes()).hexdigest() for p in paths]
        self.query()
        for options in [{"cancelled": lambda: True}, {"deadline": time.monotonic() - 1}]:
            with self.assertRaises(library.BridgeError) as raised:
                self.query(**options)
            self.assertEqual(raised.exception.code, "transcript_query_interrupted")
        self.assertEqual(before, [hashlib.sha256(p.read_bytes()).hexdigest() for p in paths])
        self.assertFalse((self.store.root / "transcription").exists())

    def test_real_tls_route_auth_json_errors_get_and_original_imports(self):
        entry = self.delivered()
        certificate, key = self.root / "cert.pem", self.root / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "1", "-nodes",
            "-subj", "/CN=localhost", "-keyout", str(key), "-out", str(certificate)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(certificate, key)
        server = HTTPServer(("127.0.0.1", 0), automatic.receiver_handler(self.store, "A" * 43))
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        trust = ssl.create_default_context(cafile=str(certificate))
        def request(method="POST", path="/v1/transcripts/query", body=None, headers=None):
            raw = library.canonical_json(self.request()).encode() if body is None else body
            sent = {"Authorization": "Bearer " + "A" * 43, "Content-Type": "application/json"}
            sent.update(headers or {})
            connection = http.client.HTTPSConnection("localhost", server.server_port, context=trust)
            try:
                connection.request(method, path, raw, sent)
                response = connection.getresponse(); data = response.read()
                return response.status, json.loads(data)
            finally:
                connection.close()
        try:
            self.assertEqual(request()[0], 200)
            self.assertEqual(request(headers={"Authorization": "Bearer wrong"})[0], 401)
            self.assertEqual(request(method="GET")[0], 405)
            self.assertEqual(request(path="/unknown")[0], 404)
            self.assertEqual(request(body=b'{"schemaVersion":1,"schemaVersion":1}')[0], 400)
            self.assertEqual(request(body=b'{"schemaVersion":NaN}')[0], 400)
            self.assertEqual(request(body=b"x" * (returned.MAX_QUERY_BYTES + 1))[0], 413)
            for headers in [{"Origin": "https://example.test"}, {"Transfer-Encoding": "chunked"}, {"Content-Type": "text/plain"}]:
                self.assertEqual(request(headers=headers)[0], 400)
            changed = self.request(); changed["items"][0]["receipt"]["storedAt"] += 1
            status, error = request(body=library.canonical_json(changed).encode())
            self.assertEqual(status, 403)
            self.assertNotIn(entry["source"]["segmentID"], json.dumps(error))
            self.assertNotIn(str(self.root), json.dumps(error))
            # Old import route still accepts the same bytes and returns the same receipt.
            raw = (self.root / (entry["receipt"]["deliveryID"] + ".zip")).read_bytes()
            status, receipt = request(path="/v1/imports", body=raw, headers={"Content-Type": "application/zip",
                "X-Delivery-ID": entry["receipt"]["deliveryID"], "X-Archive-SHA256": hashlib.sha256(raw).hexdigest()})
            self.assertEqual((status, receipt), (200, entry["receipt"]))
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
