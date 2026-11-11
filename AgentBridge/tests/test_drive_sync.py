"""Only generated CAF/text and a Google-shaped in-memory transport; no accounts."""

import base64
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sqlite3
import tempfile
import threading
import time
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import urlopen
from urllib.error import HTTPError

from test_bridge import segment, write_package
from test_transcripts import transcript_for, version2
import library
import drive_sync as drive


EMAIL = "synthetic@example.invalid"
CLIENT = {"installed": {"client_id": "synthetic.apps.googleusercontent.com", "client_secret": "synthetic-secret",
          "auth_uri": drive.AUTH_URL, "token_uri": drive.TOKEN_URL, "redirect_uris": ["http://localhost"]}}


def create_synthetic_fixture(root, nonce="SYNTHETIC-WRISTRECORD-DIRECT-DRIVE-PROBE"):
    """Create a NEW isolated Library. Returned text is wholly synthetic, not a user recording."""
    root = drive.private_directory(Path(root).resolve(), create=True)
    destination = root / "synthetic-library"
    if destination.exists(): raise ValueError("Use a fresh fixture directory.")
    item = segment(0, seed=37)
    item[0]["transcript"] = transcript_for(item[0], "SYNTHETIC TEST ONLY. No private recording. Nonce: " + nonce)
    package = root / "synthetic.zip"
    write_package(package, [item], version2([item]))
    os.chmod(package, 0o600)
    library.import_package(package, destination)
    return {"library": str(destination), "recordingID": item[0]["manifest"]["id"],
            "audioSHA256": item[0]["manifest"]["sha256"], "nonce": nonce, "synthetic": True}


class FakeGoogle:
    """Exercises the actual REST client and durable queue; no local or external HTTP."""
    validate_url = staticmethod(drive.GoogleHTTP.validate_url)

    def __init__(self):
        self.email = EMAIL
        self.files, self.sessions, self.calls = {}, {}, []
        self.generated, self.starts, self.downloads = 0, 0, 0
        self.fail_final_once = self.fail_partial_once = self.fail_folder_once = False
        self.evil_location = False
        self.with_sha = True
        self.shared = set()
        self.oauth_reply = {"access_token": "synthetic-access", "refresh_token": "synthetic-refresh",
                            "expires_in": 3600, "scope": drive.SCOPE}
        self.oauth_form = None

    def reply(self, content, status=200, headers=None):
        return status, headers or {}, library.canonical_json(content).encode()

    def metadata(self, value, data=None):
        result = dict(value, ownedByMe=True, owners=[{"emailAddress": self.email}], trashed=False)
        if data is not None:
            result.update(size=str(len(data)), md5Checksum=hashlib.md5(data).hexdigest())
            if self.with_sha: result["sha256Checksum"] = hashlib.sha256(data).hexdigest()
        return result

    def request(self, method, url, *, headers=None, body=None, token=False, sink=None):
        self.validate_url(url, token=token)
        self.calls.append((method, url, dict(headers or {})))
        if token:
            self.oauth_form = parse_qs(body.decode())
            return self.reply(self.oauth_reply)
        assert headers["Authorization"] == "Bearer synthetic-access"
        parsed, query = urlsplit(url), parse_qs(urlsplit(url).query)
        route = parsed.path.removeprefix("/drive/v3/")
        if route == "about": return self.reply({"user": {"emailAddress": self.email}})
        if route == "files/generateIds":
            self.generated += 1
            return self.reply({"ids": ["syntheticFile%d" % self.generated]})
        if route == "files" and method == "POST":
            data = json.loads(body)
            if data["id"] in self.files: return self.reply({}, 409)
            self.files[data["id"]] = {"metadata": self.metadata(data), "data": None}
            if self.fail_folder_once:
                self.fail_folder_once = False
                raise drive.DriveError("network_unavailable")
            return self.reply(self.files[data["id"]]["metadata"], 201)
        if parsed.path == "/upload/drive/v3/files" and method == "POST":
            self.starts += 1
            session_id = "session%d" % self.starts
            self.sessions[session_id] = {"metadata": json.loads(body), "data": b""}
            return self.reply({}, headers={"location": "https://evil.invalid/exfiltrate" if self.evil_location else drive.UPLOAD + "?upload_id=" + session_id})
        if parsed.path == "/upload/drive/v3/files" and method == "PUT":
            session = self.sessions.get(query["upload_id"][0])
            if session is None: return self.reply({}, 404)
            identity = session["metadata"]["id"]
            if identity in self.files: return self.reply(self.files[identity]["metadata"])
            if headers["Content-Range"].startswith("bytes */"):
                return self.reply({}, 308, {"range": "bytes=0-%d" % (len(session["data"]) - 1)} if session["data"] else {})
            match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", headers["Content-Range"])
            offset, end, size = map(int, match.groups())
            assert offset == len(session["data"]) and len(body) == end - offset + 1
            session["data"] += body
            if len(session["data"]) == size:
                self.files[identity] = {"metadata": self.metadata(session["metadata"], session["data"]), "data": session["data"]}
                if self.fail_final_once:
                    self.fail_final_once = False
                    raise drive.DriveError("network_unavailable")
                return self.reply(self.files[identity]["metadata"])
            if self.fail_partial_once:
                self.fail_partial_once = False
                raise drive.DriveError("network_unavailable")
            return self.reply({}, 308, {"range": "bytes=0-%d" % (len(session["data"]) - 1)})
        if route.startswith("files/"):
            parts = route.split("/")
            value = self.files.get(parts[1])
            if value is None: return self.reply({}, 404)
            if len(parts) == 3 and parts[2] == "permissions":
                permissions = [{"type": "user", "role": "owner", "emailAddress": self.email}]
                if parts[1] in self.shared: permissions.append({"type": "anyone", "role": "reader"})
                return self.reply({"permissions": permissions})
            if query.get("alt") == ["media"]:
                self.downloads += 1
                sink(value["data"])
                return 200, {}, b""
            return self.reply(value["metadata"])
        raise AssertionError((method, url))


class DriveSyncTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.fixture = create_synthetic_fixture(self.root)
        self.library_path = Path(self.fixture["library"])
        self.state = self.root / "state"
        self.queue = drive.DriveSync.initialize(self.state, self.library_path, EMAIL, "new", scope="all")
        self.google = FakeGoogle()
        self.api = drive.DriveClient(lambda: "synthetic-access", self.google)

    def tearDown(self): self.temporary.cleanup()

    def retry_now(self):
        with self.queue.connection() as connection: connection.execute("UPDATE objects SET retry_at=0")

    def finish(self, limit=20):
        for _ in range(limit):
            self.retry_now()
            result = self.queue.sync(self.api, max_files=100)
            if result["objects"].get("pending", 0) == 0: return result
        self.fail("Synthetic queue did not drain: " + str(result))

    def objects(self):
        with self.queue.connection() as connection:
            return [dict(row) for row in connection.execute("SELECT * FROM objects ORDER BY sequence")]

    def test_roundtrip_four_artifacts_changes_source_preserved_restart_idempotent(self):
        source_before = {p.relative_to(self.library_path): p.read_bytes() for p in self.library_path.rglob("*") if p.is_file()}
        result = self.finish()
        self.assertEqual(result["verifiedAudioFiles"], 1)
        self.assertEqual({row["kind"] for row in self.objects()}, {"audio", "manifest", "transcript", "text", "changes"})
        self.assertEqual(len(self.google.files), 6)  # folder + 4 artifacts + changes
        ids = {row["key"]: row["file_id"] for row in self.objects()}
        self.queue = drive.DriveSync(self.state)
        self.assertEqual(self.queue.plan()["createdObjects"], 0)
        self.finish()
        self.assertEqual(ids, {row["key"]: row["file_id"] for row in self.objects()})
        self.assertEqual(len(self.google.files), 6)
        self.assertEqual(source_before, {p.relative_to(self.library_path): p.read_bytes() for p in self.library_path.rglob("*") if p.is_file()})
        manifest = next(row for row in self.objects() if row["kind"] == "manifest")
        value = json.loads(self.google.files[manifest["file_id"]]["data"])
        self.assertEqual(value["source"]["audioSHA256"], self.fixture["audioSHA256"])
        self.assertEqual(value["manifest"]["id"], self.fixture["recordingID"])
        self.assertEqual(value["sessionCompleteness"], "not_asserted")
        self.assertNotIn(str(self.root), json.dumps(value))
        transcript = next(row for row in self.objects() if row["kind"] == "transcript")
        self.assertEqual(json.loads(self.google.files[transcript["file_id"]]["data"])["engine"], "synthetic-fixture")
        changes = next(row for row in self.objects() if row["kind"] == "changes")
        events = json.loads(self.google.files[changes["file_id"]]["data"])["changes"]
        self.assertEqual(len(events), 4)
        self.assertTrue(all(x["source"]["segmentID"] == self.fixture["recordingID"] for x in events))

    def test_late_transcript_adds_versions_without_uploading_audio_twice(self):
        with sqlite3.connect(str(self.library_path / library.DB_NAME)) as connection:
            original = connection.execute("SELECT * FROM transcripts").fetchone()
            columns = [r[1] for r in connection.execute("PRAGMA table_info(transcripts)")]
            connection.execute("DELETE FROM transcripts")
        self.finish()
        audio_id = next(row["file_id"] for row in self.objects() if row["kind"] == "audio")
        self.assertEqual({row["kind"] for row in self.objects()}, {"audio", "manifest", "changes"})
        with sqlite3.connect(str(self.library_path / library.DB_NAME)) as connection:
            connection.execute("INSERT INTO transcripts(" + ",".join(columns) + ") VALUES (" + ",".join("?" for _ in original) + ")", original)
        self.queue = drive.DriveSync(self.state)
        self.finish()
        self.assertEqual([row["file_id"] for row in self.objects() if row["kind"] == "audio"], [audio_id])
        self.assertEqual(len([row for row in self.objects() if row["kind"] == "manifest"]), 2)
        self.assertEqual(len([row for row in self.objects() if row["kind"] == "text"]), 1)

    def test_future_scope_fixed_and_reinitialization_cannot_expand(self):
        queue = drive.DriveSync.initialize(self.root / "future", self.library_path, EMAIL, "new", scope="future", since_ms=1700000000001)
        self.assertEqual(queue.plan()["createdObjects"], 0)
        with self.assertRaises(drive.DriveError) as raised:
            drive.DriveSync.initialize(self.root / "future", self.library_path, EMAIL, "new", scope="all")
        self.assertEqual(raised.exception.code, "configuration_conflict")
        with queue.connection() as connection:
            value = dict(queue.configuration, sinceMS=None)
            connection.execute("UPDATE configuration SET value=?", (library.canonical_json(value),))
        with self.assertRaises(drive.DriveError): drive.DriveSync(queue.root)

    def test_final_commit_lost_response_restart_reuses_id(self):
        self.google.fail_final_once = True
        first = self.queue.sync(self.api)
        self.assertEqual(first["failed"], {"network_unavailable": 1})
        row = next(row for row in self.objects() if row["kind"] == "audio")
        self.assertIn(row["file_id"], self.google.files)
        self.queue = drive.DriveSync(self.state)
        self.finish()
        self.assertEqual(len(self.google.files), 7)  # two non-overlapping change batches
        self.assertEqual(len([v for v in self.google.files.values() if v["metadata"]["mimeType"] == "audio/x-caf"]), 1)
        self.assertEqual(next(r for r in self.objects() if r["kind"] == "audio")["file_id"], row["file_id"])

    def test_resumable_partial_lost_response_does_not_repeat_bytes(self):
        self.queue.plan()
        self.google.fail_partial_once = True
        with mock.patch.object(drive, "CHUNK", 256):
            first = self.queue.sync(self.api)
            self.assertEqual(first["failed"], {"network_unavailable": 1})
            self.queue = drive.DriveSync(self.state)
            self.finish()
        self.assertEqual(len([v for v in self.google.files.values() if v["metadata"]["mimeType"] == "audio/x-caf"]), 1)

    def test_expired_session_restarts_with_same_pre_generated_file_id(self):
        self.google.fail_partial_once = True
        with mock.patch.object(drive, "CHUNK", 256): self.queue.sync(self.api)
        row = next(row for row in self.objects() if row["kind"] == "audio")
        self.google.sessions.clear()
        self.retry_now()
        self.assertEqual(self.queue.sync(self.api)["failed"], {"upload_session_expired": 1})
        self.finish()
        self.assertEqual(next(r for r in self.objects() if r["kind"] == "audio")["file_id"], row["file_id"])

    def test_folder_create_lost_response_reuses_folder_id(self):
        self.google.fail_folder_once = True
        with self.assertRaises(drive.DriveError): self.queue.sync(self.api)
        folder = self.queue.configuration["folderID"]
        self.queue = drive.DriveSync(self.state)
        self.finish()
        self.assertEqual(self.queue.configuration["folderID"], folder)
        self.assertEqual(len([v for v in self.google.files.values() if v["metadata"]["mimeType"] == drive.FOLDER]), 1)

    def test_two_preconstructed_clients_reload_the_same_reserved_folder(self):
        stale = drive.DriveSync(self.state)
        self.finish()
        self.assertIsNone(stale.configuration["folderID"])
        stale.sync(self.api)
        self.assertEqual(stale.configuration["folderID"], self.queue.configuration["folderID"])
        self.assertEqual(len(self.google.files), 6)

    def test_corrupt_source_isolated_from_another_healthy_segment(self):
        source = Path(self.queue.library.get_audio_asset({"recording_id": self.fixture["recordingID"]})["localPath"])
        source.write_bytes(b"invalid synthetic CAF")
        extra = segment(1, seed=41)
        extra[0]["transcript"] = transcript_for(extra[0], "Synthetic second healthy segment")
        package = self.root / "extra.zip"
        write_package(package, [extra], version2([extra]))
        library.import_package(package, self.library_path)
        result = self.finish()
        self.assertEqual(sum(result["skipped"].values()), 1)
        self.assertEqual(result["verifiedAudioFiles"], 1)
        self.assertEqual([row["recording_id"] for row in self.objects() if row["kind"] == "audio"], [extra[0]["manifest"]["id"]])

    def test_explicit_foreground_watch_waits_between_successful_runs(self):
        emitted, waits = [], []
        self.queue.watch(self.api, cycles=3, interval=5, emit=emitted.append, sleeper=waits.append)
        self.assertEqual(waits, [5, 5])
        self.assertEqual(len(emitted), 3)
        self.assertTrue(all("synthetic-access" not in output and self.fixture["nonce"] not in output for output in emitted))
        self.assertEqual(json.loads(emitted[-1])["objects"], {"verified": 5})

    def test_no_sha_field_requires_full_download_verification(self):
        self.google.with_sha = False
        self.finish()
        self.assertEqual(self.google.downloads, 5)

    def test_account_and_sharing_fail_closed_before_data_write(self):
        self.google.email = "other@example.invalid"
        with self.assertRaises(drive.DriveError) as raised: self.queue.sync(self.api)
        self.assertEqual(raised.exception.code, "account_mismatch")
        self.assertFalse(self.google.files)
        self.google.email = EMAIL
        folder = self.queue._destination(self.api)
        self.google.shared.add(folder)
        with self.assertRaises(drive.DriveError) as raised: self.queue.sync(self.api)
        self.assertEqual(raised.exception.code, "destination_not_private_owned")
        self.assertEqual(len(self.google.files), 1)

    def test_remote_corruption_cannot_be_receipted(self):
        self.google.fail_final_once = True
        self.queue.sync(self.api)
        row = next(row for row in self.objects() if row["kind"] == "audio")
        self.google.files[row["file_id"]]["metadata"]["sha256Checksum"] = "0" * 64
        self.retry_now()
        self.assertEqual(self.queue.sync(self.api)["failed"], {"remote_integrity_mismatch": 1})
        self.assertEqual(self.queue._object(row["key"])["status"], "pending")
        with self.queue.connection() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM changes WHERE object_key=?", (row["key"],)).fetchone()[0], 0)

    def test_snapshot_corruption_rejected_and_source_not_modified(self):
        self.queue.plan()
        row = next(row for row in self.objects() if row["kind"] == "audio")
        source = Path(self.queue.library.get_audio_asset({"recording_id": self.fixture["recordingID"]})["localPath"])
        before = source.read_bytes()
        (self.queue.snapshots / row["local_name"]).write_bytes(b"corrupt synthetic snapshot")
        result = self.queue.sync(self.api)
        self.assertEqual(result["failed"], {"snapshot_integrity_mismatch": 1})
        self.assertEqual(source.read_bytes(), before)

    def test_unsafe_location_never_receives_credentials(self):
        self.google.evil_location = True
        result = self.queue.sync(self.api)
        self.assertEqual(result["failed"], {"unsafe_remote_url": 4})
        self.assertFalse(any("evil.invalid" in url for _, url, _ in self.google.calls))
        loads = mock.Mock(return_value="synthetic-access")
        api = drive.DriveClient(loads, self.google)
        for url in ("https://evil.invalid/", "https://www.googleapis.com:bad/drive/v3/files", "http://www.googleapis.com/drive/v3/files", "https://www.googleapis.com@evil.invalid/drive/v3/files"):
            with self.subTest(url=url):
                with self.assertRaises(drive.DriveError): api.request("GET", url)
        loads.assert_not_called()
        with self.assertRaises(drive.DriveError): api.upload_status(drive.DRIVE + "files/unsafe", 30)
        loads.assert_not_called()

    def test_actual_http_transport_never_follows_redirect_location(self):
        transport = drive.GoogleHTTP()
        error = HTTPError(drive.DRIVE + "about", 302, "synthetic redirect", {"Location": "https://evil.invalid/"}, io.BytesIO(b"{}"))
        transport.opener = mock.Mock()
        transport.opener.open.side_effect = error
        status, headers, _ = transport.request("GET", drive.DRIVE + "about", headers={"Authorization": "Bearer synthetic-access"})
        self.assertEqual(status, 302)
        self.assertEqual(headers["location"], "https://evil.invalid/")
        transport.opener.open.assert_called_once()
        request = transport.opener.open.call_args[0][0]
        self.assertTrue(request.full_url.startswith(drive.DRIVE))

    def test_credential_and_queue_permissions_and_queue_lock(self):
        with drive.exclusive(self.state / "queue.lock"):
            with self.assertRaises(drive.DriveError) as raised: self.queue.plan()
            self.assertEqual(raised.exception.code, "queue_busy")
        self.queue.database.chmod(0o644)
        with self.assertRaises(drive.DriveError) as raised: drive.DriveSync(self.state)
        self.assertEqual(raised.exception.code, "unsafe_permissions")

    def test_change_publication_and_cursor_are_one_transaction(self):
        self.queue.plan()
        folder = self.queue._destination(self.api)
        row = self.objects()[0]
        self.queue._upload(self.api, row, folder)
        with self.queue.connection() as connection:
            connection.execute("CREATE TRIGGER fail_cursor BEFORE UPDATE ON publications BEGIN SELECT RAISE(ABORT,'synthetic crash'); END")
        with self.assertRaises(sqlite3.IntegrityError): self.queue._plan_changes()
        with self.queue.connection() as connection:
            self.assertEqual(connection.execute("SELECT last_planned FROM publications").fetchone()[0], 0)
            self.assertEqual(connection.execute("SELECT count(*) FROM objects WHERE kind='changes'").fetchone()[0], 0)
            connection.execute("DROP TRIGGER fail_cursor")
        self.finish()
        ranges = [tuple(map(int, row["key"].split(":")[1:])) for row in self.objects() if row["kind"] == "changes"]
        for previous, current in zip(ranges, ranges[1:]): self.assertEqual(previous[1] + 1, current[0])


class OAuthTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve(); self.root.chmod(0o700)
        self.client = self.root / "client.json"
        drive.atomic_private(self.client, library.canonical_json(CLIENT).encode())
        self.token = self.root / "token.json"
        self.google = FakeGoogle()

    def tearDown(self): self.temporary.cleanup()

    def test_pkce_loopback_wrong_state_rejected_then_account_bound_token_written(self):
        callback_errors, browser_query, worker = [], {}, []
        def open_browser(url):
            self.assertTrue(url.startswith(drive.AUTH_URL + "?"))
            browser_query.update(parse_qs(urlsplit(url).query))
            def callback():
                try:
                    base = browser_query["redirect_uri"][0]
                    with self.assertRaises(Exception): urlopen(base + "?" + urlencode({"state": "wrong", "code": "wrong-code"}), timeout=4)
                    with urlopen(base + "?" + urlencode({"state": browser_query["state"][0], "code": "synthetic-code"}), timeout=4) as response:
                        self.assertEqual(response.status, 200)
                except BaseException as error: callback_errors.append(error)
            worker.append(threading.Thread(target=callback)); worker[-1].start()
            return True
        result = drive.authorize(self.client, self.token, EMAIL, http=self.google, open_browser=open_browser, timeout=5)
        worker[0].join(5)
        self.assertFalse(callback_errors)
        self.assertEqual(result["recordingsUploaded"], 0)
        verifier = self.google.oauth_form["code_verifier"][0]
        expected = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        self.assertEqual(browser_query["code_challenge"], [expected])
        self.assertEqual(browser_query["scope"], [drive.SCOPE])
        self.assertEqual(self.token.stat().st_mode & 0o777, 0o600)
        self.assertEqual(drive.FileTokenProvider(self.client, self.token, EMAIL, self.google)(), "synthetic-access")
        self.assertEqual(len(self.google.files), 0)

    def saved(self, **updates):
        value = {"account": EMAIL, "clientID": CLIENT["installed"]["client_id"], "scopes": [drive.SCOPE],
                 "accessToken": "expired", "refreshToken": "synthetic-refresh", "expiresAt": 0}
        value.update(updates); drive.atomic_private(self.token, library.canonical_json(value).encode())

    def test_refresh_persists_private_token_and_never_uses_plugin_credentials(self):
        self.saved()
        provider = drive.FileTokenProvider(self.client, self.token, EMAIL, self.google)
        self.assertEqual(provider(), "synthetic-access")
        self.assertEqual(self.google.oauth_form["grant_type"], ["refresh_token"])
        self.assertEqual(json.loads(self.token.read_bytes())["refreshToken"], "synthetic-refresh")
        self.assertEqual(self.token.stat().st_mode & 0o777, 0o600)
        self.saved(account="other@example.invalid")
        count = len(self.google.calls)
        with self.assertRaises(drive.DriveError) as raised: provider()
        self.assertEqual(raised.exception.code, "credential_scope_mismatch")
        self.assertEqual(len(self.google.calls), count)

    def test_missing_configuration_setup_required_and_no_token_echo(self):
        output = io.StringIO()
        with mock.patch("sys.stdout", output):
            result = drive.main(["auth", "--client-config", str(self.root / "missing"), "--token-file", str(self.token), "--account", EMAIL])
        self.assertEqual(result, 1)
        self.assertEqual(json.loads(output.getvalue())["error"]["code"], "setup_required")
        self.assertNotIn(EMAIL, output.getvalue())
        self.assertNotIn(str(self.root), output.getvalue())

    def test_invalid_refresh_scope_and_unsafe_credentials_rejected(self):
        self.saved()
        self.google.oauth_reply["scope"] = "openid"
        with self.assertRaises(drive.DriveError): drive.FileTokenProvider(self.client, self.token, EMAIL, self.google)()
        self.token.chmod(0o644)
        with self.assertRaises(drive.DriveError) as raised: drive.FileTokenProvider(self.client, self.token, EMAIL, self.google)()
        self.assertEqual(raised.exception.code, "unsafe_permissions")


if __name__ == "__main__": unittest.main()
