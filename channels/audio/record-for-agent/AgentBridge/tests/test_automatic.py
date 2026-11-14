"""Automatic delivery integration tests use generated CAF/ZIPs and fake Agents only."""

import copy
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, HTTPServer
import io
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock
import uuid

from test_bridge import segment, write_package
from test_transcripts import transcript_for, version2
import automatic
from automatic import DeliveryStore
import delivery_clients
from delivery_clients import CodexClient, WorkBuddyACPClient, DeliveryError, dispatch_once
import library


class ReceiverStatusTests(unittest.TestCase):
    """Status checks have an identity, but no library or recording access."""

    def setUp(self):
        self.receiver = "33333333-4444-4555-8666-777777777777"
        self.token = "A" * 43

        class IdentityOnlyStore:
            receiver_id = self.receiver

            def __getattr__(self, _):
                raise AssertionError("Status must not access delivery or recording state")

        self.on_import = mock.Mock(side_effect=AssertionError("Status must not trigger import work"))
        self.handler = automatic.receiver_handler(IdentityOnlyStore(), self.token, self.on_import)

    def request(self, headers=(), path="/v1/status", method="GET"):
        # Exercise production HTTP parsing and response writing without a listener;
        # CI sandboxes may prohibit even binding an ephemeral loopback socket.
        request = (method + " " + path + " HTTP/1.1\r\nHost: synthetic.invalid\r\n" +
                   "".join(name + ": " + value + "\r\n" for name, value in headers) + "\r\n").encode()

        class MemorySocket:
            def __init__(self):
                self.output = bytearray()

            def makefile(self, *_):
                return io.BytesIO(request)

            def sendall(self, data):
                self.output.extend(data)

            def settimeout(self, _):
                pass

        connection = MemorySocket()
        self.handler(connection, ("127.0.0.1", 0), object())
        response = io.BytesIO(connection.output)
        status = int(response.readline().split()[1])
        response_headers = http.client.parse_headers(response)
        return status, dict(response_headers.items()), response.read()

    def authorized(self, *extra):
        return [("Authorization", "Bearer " + self.token), *extra]

    def test_authenticated_status_is_bounded_identity_only_and_does_not_touch_files(self):
        with mock.patch("builtins.open", side_effect=AssertionError("Status must not open files")), \
                mock.patch.object(automatic.sqlite3, "connect", side_effect=AssertionError("Status must not query receipts")):
            for _ in range(2):
                status, headers, raw = self.request(self.authorized())
                self.assertEqual(status, 200)
                self.assertEqual(json.loads(raw), {"schemaVersion": 1, "receiverID": self.receiver, "status": "ready"})
                self.assertLessEqual(len(raw), 128)
                self.assertEqual(headers["Content-Length"], str(len(raw)))
                self.assertEqual(headers["Cache-Control"], "no-store")
                self.assertEqual(headers["Connection"], "close")
        self.on_import.assert_not_called()

    def test_missing_wrong_and_duplicate_bearer_do_not_disclose_identity_and_recover(self):
        for headers in ([], [("Authorization", "Bearer incorrect")],
                        self.authorized(("Authorization", "Bearer " + self.token))):
            status, _, raw = self.request(headers)
            self.assertEqual(status, 401)
            self.assertEqual(json.loads(raw)["error"]["code"], "unauthorized")
            self.assertNotIn(self.receiver.encode(), raw)
            self.assertNotIn(self.token.encode(), raw)
        self.assertEqual(self.request(self.authorized())[0], 200)
        self.on_import.assert_not_called()

    def test_browser_and_transfer_encoding_requests_are_refused_without_reading_body(self):
        for header in (("Origin", "https://synthetic-private.invalid"), ("Transfer-Encoding", "chunked")):
            status, _, raw = self.request(self.authorized(header))
            self.assertEqual(status, 400)
            self.assertEqual(json.loads(raw)["error"]["code"], "invalid_arguments")
            self.assertNotIn(header[1].encode(), raw)
        self.on_import.assert_not_called()

    def test_status_requires_exact_get_route_and_preserves_old_method_behavior(self):
        for path in ("/", "/v1/imports", "/v1/status?private=synthetic", "/v1/status/"):
            self.assertEqual(self.request(self.authorized(), path=path)[0], 405)
        self.assertEqual(self.request(self.authorized(), method="POST")[0], 404)
        self.on_import.assert_not_called()


class AutomaticTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.receiver = str(uuid.uuid4())
        self.state = self.root / "state"
        self.destination = self.root / "library"
        self.store = DeliveryStore(self.state, self.destination, self.receiver)
        self.items = [segment(0), segment(1)]
        self.delivery = str(uuid.uuid4())
        self.token = "A" * 43

    def tearDown(self):
        self.temporary.cleanup()

    def package(self, ready=True, items=None):
        items = copy.deepcopy(self.items if items is None else items)
        if ready:
            for item, _ in items:
                item["transcript"] = transcript_for(item, "SYNTHETIC PRIVATE TEXT")
        path = self.root / (str(uuid.uuid4()) + ".zip")
        write_package(path, items, version2(items))
        return path.read_bytes()

    def upload(self, raw=None, identifier=None):
        raw = self.package() if raw is None else raw
        return self.store.accept(io.BytesIO(raw), len(raw), identifier or self.delivery, hashlib.sha256(raw).hexdigest())

    def test_ready_upload_is_visible_to_existing_mcp_library_and_content_free_outbox(self):
        receipt = self.upload()
        self.assertEqual(set(receipt), {"schemaVersion", "receiverID", "deliveryID", "archiveSHA256", "recordingIDs", "storedAt"})
        self.assertEqual(receipt["receiverID"], self.receiver)
        self.assertEqual(receipt["recordingIDs"], [item[0]["manifest"]["id"] for item in self.items])
        catalog = library.Library(self.destination)
        self.assertEqual(len(catalog.list_recordings({})["recordings"]), 2)
        self.assertEqual(catalog.get_transcript({"recording_id": receipt["recordingIDs"][0]})["transcript"]["text"], "SYNTHETIC PRIVATE TEXT")
        events = self.store.pending("codex:target")
        self.assertEqual(len(events), 1)
        self.assertNotIn("SYNTHETIC PRIVATE TEXT", json.dumps(events))
        self.assertEqual(events[0]["source"]["transcriptTool"], "get_transcript")
        self.assertEqual(self.store.authorized_recording_ids(), sorted(receipt["recordingIDs"]))

    def test_same_delivery_and_different_export_do_not_repeat_ready_notification(self):
        raw = self.package()
        receipt = self.upload(raw)
        self.assertEqual(self.upload(raw), receipt)
        self.upload(self.package(), str(uuid.uuid4()))
        self.assertEqual(self.store.status()["durableReceipts"], 2)
        self.assertEqual(self.store.status()["events"], 1)

    def test_same_delivery_different_bytes_conflicts_and_preserves_receipt(self):
        first = self.package()
        receipt = self.upload(first)
        with self.assertRaises(library.BridgeError) as raised:
            self.upload(self.package())
        self.assertEqual(raised.exception.code, "delivery_conflict")
        self.assertEqual(self.upload(first), receipt)

    def test_wrong_hash_incomplete_and_oversized_upload_do_not_import(self):
        raw = self.package()
        for source, length, digest in [(io.BytesIO(raw), len(raw), "0" * 64),
                                       (io.BytesIO(raw[:-5]), len(raw), hashlib.sha256(raw).hexdigest()),
                                       (io.BytesIO(raw), self.store.limits.max_archive_bytes + 1, "0" * 64)]:
            with self.assertRaises(library.BridgeError):
                self.store.accept(source, length, self.delivery, digest)
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.store.status()["durableReceipts"], 0)

    def test_crash_between_library_commit_and_receipt_recovers_outbox(self):
        raw = self.package()
        with mock.patch.object(self.store, "_enqueue_members", side_effect=OSError("simulated crash")):
            with self.assertRaises(OSError):
                self.upload(raw)
        self.assertEqual(len(library.Library(self.destination).list_recordings({})["recordings"]), 2)
        self.assertEqual(self.store.status()["pendingImports"], 1)
        restarted = DeliveryStore(self.state, self.destination, self.receiver)
        self.assertEqual(restarted.recover(), 1)
        self.assertEqual(restarted.status()["events"], 1)
        self.assertEqual(restarted.status()["durableReceipts"], 1)
        self.assertEqual(self.upload(raw)["recordingIDs"], [item[0]["manifest"]["id"] for item in self.items])

    def test_invalid_archive_is_recorded_as_rejected_and_does_not_poison_recovery(self):
        with self.assertRaises(library.BridgeError):
            self.upload(b"not-a-zip")
        self.assertEqual(self.store.status()["rejectedImports"], 1)
        self.assertEqual(self.store.recover(), 0)

    def test_audio_only_receipt_does_not_notify_then_asr_can_publish_ready_once(self):
        receipt = self.upload(self.package(ready=False))
        self.assertEqual(self.store.pending("target"), [])
        self.assertEqual(self.store.enqueue_available(receipt["recordingIDs"]), 0)
        ready_zip = self.root / "asr.zip"
        ready_zip.write_bytes(self.package())
        library.import_package(ready_zip, self.destination)
        self.assertEqual(self.store.enqueue_available(receipt["recordingIDs"]), 2)
        self.assertEqual(self.store.enqueue_available(receipt["recordingIDs"]), 0)
        self.assertEqual(len(self.store.pending("target")), 1)

    def test_asr_cannot_publish_old_manual_imports_or_unselected_recordings(self):
        manual = [segment(99)]
        ready_zip = self.root / "manual.zip"
        ready_zip.write_bytes(self.package(items=manual))
        library.import_package(ready_zip, self.destination)
        self.upload()
        with self.assertRaises(library.BridgeError) as raised:
            self.store.enqueue_available([manual[0][0]["manifest"]["id"]])
        self.assertEqual(raised.exception.code, "not_authorized")

    def test_identity_cannot_reassign_existing_state_or_use_insecure_directory(self):
        with self.assertRaises(library.BridgeError):
            DeliveryStore(self.state, self.destination, str(uuid.uuid4()))
        with self.assertRaises(library.BridgeError):
            DeliveryStore(self.state, self.root / "other", self.receiver)
        os.chmod(self.state, 0o755)
        with self.assertRaises(library.BridgeError):
            DeliveryStore(self.state, self.destination, self.receiver)

    def test_each_client_has_independent_durable_acceptance_and_no_repeated_send(self):
        self.upload()
        client = mock.Mock(target="codex:test")
        client.send.return_value = {"kind": "synthetic_accepted"}
        self.assertEqual(dispatch_once(self.store, client)["accepted"], 1)
        self.assertEqual(dispatch_once(self.store, client)["accepted"], 0)
        self.assertEqual(client.send.call_count, 1)
        other = mock.Mock(target="workbuddy:test")
        other.send.return_value = {"kind": "synthetic_accepted"}
        self.assertEqual(dispatch_once(self.store, other)["accepted"], 1)

    def test_pending_segments_are_combined_into_one_light_notification(self):
        self.upload()
        self.upload(self.package(items=[segment(2)]), str(uuid.uuid4()))
        client = mock.Mock(target="codex:batch")
        client.send.return_value = {"kind": "synthetic_accepted"}
        self.assertEqual(dispatch_once(self.store, client)["accepted"], 2)
        self.assertEqual(client.send.call_count, 1)
        events = client.send.call_args[0][0]
        self.assertEqual(len(events), 2)
        self.assertNotEqual(delivery_clients.batch_id(events), delivery_clients.batch_id(events[:1]))
        self.assertEqual(delivery_clients.batch_id(events), delivery_clients.batch_id(list(reversed(events))))

    def test_definite_failure_retries_but_ambiguous_start_is_retained(self):
        self.upload()
        client = mock.Mock(target="codex:test")
        client.send.side_effect = DeliveryError("offline")
        self.assertEqual(dispatch_once(self.store, client)["retry"], 1)
        self.assertEqual(self.store.pending(client.target), [])
        self.assertEqual(len(self.store.pending(client.target, at=automatic.now_ms() + 60000)), 1)
        other = mock.Mock(target="workbuddy:test")
        other.send.side_effect = DeliveryError("connection_lost_after_write", uncertain=True)
        self.assertEqual(dispatch_once(self.store, other)["uncertain"], 1)
        self.assertEqual(self.store.pending(other.target, at=automatic.now_ms() + 10000000), [])
        self.assertIn({"target": other.target, "status": "uncertain", "count": 1}, self.store.status()["deliveries"])

    def test_concurrent_dispatch_claim_cannot_deliver_same_event_twice(self):
        self.upload()
        event = self.store.pending("test")[0]
        self.assertTrue(self.store.claim("test", event["eventID"]))
        self.assertFalse(self.store.claim("test", event["eventID"]))
        self.assertEqual(self.store.pending("test"), [])

    def test_real_https_receiver_auth_integrity_duplicate_and_mcp_visibility(self):
        certificate, key = self.root / "cert.pem", self.root / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "1", "-nodes",
                        "-subj", "/CN=localhost", "-keyout", str(key), "-out", str(certificate)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(certificate), str(key))
        server = HTTPServer(("127.0.0.1", 0), automatic.receiver_handler(self.store, self.token))
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        raw = self.package()
        headers = {"Authorization": "Bearer " + self.token, "Content-Type": "application/zip",
                   "X-Delivery-ID": self.delivery, "X-Archive-SHA256": hashlib.sha256(raw).hexdigest()}
        trust = ssl.create_default_context(cafile=str(certificate))
        try:
            def request(sent_headers, body=raw):
                connection = http.client.HTTPSConnection("localhost", server.server_port, context=trust)
                try:
                    connection.request("POST", "/v1/imports", body, sent_headers)
                    response = connection.getresponse()
                    return response.status, json.loads(response.read())
                finally:
                    connection.close()
            status, _ = request(dict(headers, Authorization="Bearer incorrect"))
            self.assertEqual(status, 401)
            self.assertFalse(self.destination.exists())
            status, receipt = request(headers)
            self.assertEqual(status, 200)
            self.assertEqual(request(headers), (200, receipt))
            self.assertEqual(request(dict(headers, **{"X-Archive-SHA256": "0" * 64}))[0], 409)
            self.assertEqual(len(library.Library(self.destination).list_recordings({})["recordings"]), 2)
            self.assertEqual(self.store.status()["events"], 1)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_codex_stdio_public_protocol_uses_explicit_thread_and_preserves_settings(self):
        self.upload()
        event = self.store.pending("any")[0]
        target = str(uuid.uuid4())
        executable = self.root / "fake-codex"
        trace = self.root / "protocol.json"
        executable.write_text("#!" + sys.executable + "\n" + """
import json,sys
from pathlib import Path
assert sys.argv[1:] == ['app-server', '--stdio']
requests=[]
for line in sys.stdin:
    request=json.loads(line)
    requests.append(request)
    Path('protocol.json').write_text(json.dumps(requests))
    if 'id' not in request:
        continue
    result={'turn':{'id':'synthetic-turn'}} if request['method']=='turn/start' else {}
    print(json.dumps({'id':request['id'],'result':result}),flush=True)
    if request['method']=='turn/start':
        print(json.dumps({'method':'turn/completed','params':{'threadId':request['params']['threadId'],'turn':{'id':'synthetic-turn','status':'completed'}}}),flush=True)
        break
""")
        executable.chmod(0o700)
        result = CodexClient(str(executable), target, str(self.root)).send([event])
        requests = json.loads(trace.read_text())
        self.assertEqual(result["kind"], "codex_turn_accepted")
        self.assertEqual(result["executionObservation"], "turn_completed")
        self.assertEqual([item["method"] for item in requests], ["initialize", "initialized", "thread/resume", "turn/start"])
        self.assertEqual(requests[-2]["params"], {"threadId": target, "excludeTurns": True})
        params = requests[-1]["params"]
        self.assertEqual(params["threadId"], target)
        self.assertEqual(set(params), {"threadId", "clientUserMessageId", "input"})
        self.assertNotIn("SYNTHETIC PRIVATE TEXT", params["input"][0]["text"])

    def test_workbuddy_public_acp_resumes_exact_session_without_permission_override(self):
        self.upload()
        event = self.store.pending("any")[0]
        requests = []
        status = [200]
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                requests.append((self.path, dict(self.headers), json.loads(body)))
                self.send_response(status[0])
                self.send_header("Location", "http://127.0.0.1:1/do-not-follow")
                self.end_headers()
                if self.path == "/api/v1/acp/connect":
                    self.wfile.write(b'{"connectionId":"test-connection","sessionToken":"test-token"}')
                else:
                    value = json.loads(body)
                    result = {"stopReason": "end_turn"} if value["method"] == "session/prompt" else {}
                    self.wfile.write(("event: message\ndata: " + json.dumps({"id": value["id"], "result": result}) + "\n\n").encode())
            def do_DELETE(self):
                self.send_response(200)
                self.end_headers()
        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        client = WorkBuddyACPClient("http://127.0.0.1:" + str(server.server_port), "dedicated-session", str(self.root))
        try:
            result = client.send([event])
            self.assertEqual(result["kind"], "workbuddy_prompt_returned")
            self.assertEqual(result["desktopVisibility"], "not_verified")
            self.assertEqual(len(requests), 4)
            self.assertEqual(requests[0][0], "/api/v1/acp/connect")
            self.assertEqual([value[2]["method"] for value in requests[1:]], ["initialize", "session/resume", "session/prompt"])
            self.assertEqual(requests[2][2]["params"], {"sessionId": "dedicated-session", "cwd": str(self.root), "mcpServers": []})
            self.assertEqual(requests[3][2]["params"]["sessionId"], "dedicated-session")
            self.assertEqual(set(requests[3][2]["params"]), {"sessionId", "prompt"})
            self.assertNotIn("SYNTHETIC PRIVATE TEXT", requests[3][2]["params"]["prompt"][0]["text"])
            status[0] = 302
            with self.assertRaises(DeliveryError) as raised:
                client.send([event])
            self.assertEqual(raised.exception.code, "workbuddy_redirect_rejected")
            self.assertEqual(len(requests), 5)
            self.assertEqual(requests[0][1]["X-CodeBuddy-Request"], "1")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_remote_plaintext_arbitrary_urls_and_implicit_targets_are_rejected(self):
        for origin in ["http://192.168.1.2:8080", "https://user:pass@example.test", "https://example.test/internal", "https://example.test?token=oops"]:
            with self.assertRaises(library.BridgeError):
                WorkBuddyACPClient(origin, "explicit", str(self.root))
        with self.assertRaises(library.BridgeError):
            CodexClient("relative-executable", str(uuid.uuid4()), str(self.root))
        with self.assertRaises(library.BridgeError):
            delivery_clients.configured_client({"schemaVersion": 1, "kind": "codex-stdio"})


if __name__ == "__main__":
    unittest.main()
