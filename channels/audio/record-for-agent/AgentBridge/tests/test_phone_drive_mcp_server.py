"""Synthetic Phone REST world only; never opens an account or a real recording."""

import copy
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
from urllib.parse import parse_qs, urlsplit
import uuid

from test_bridge import segment
from test_transcripts import transcript_for
import phone_drive_mcp_server as phone
from drive_sync import DRIVE, DriveError
from library import canonical_json

EMAIL, OWNER, FOLDER = "synthetic@example.invalid", "syntheticOwner", "syntheticPhoneFolder"
LIBRARY = "b6201275-18a9-41f2-ac17-c4271ee88b20"


class FakePhoneGoogle:
    def __init__(self):
        self.email, self.owner, self.calls, self.downloads = EMAIL, OWNER, [], []
        self.files, self.shared = {}, set()
        self.invalid_page_once = False
        self.fail_ids = set()
        self.http_failures = {}
        self.after_media = None
        self.add(FOLDER, "Phone synthetic folder", "application/vnd.google-apps.folder", None,
                 {"rfaLibraryID": LIBRARY, "rfaSchema": "1"})

    def add(self, file_id, name, mime, data, properties):
        meta = {"id": file_id, "name": name, "mimeType": mime, "ownedByMe": True,
                "owners": [{"permissionId": OWNER}], "shared": False, "trashed": False,
                "appProperties": properties}
        if file_id != FOLDER: meta["parents"] = [FOLDER]
        if data is not None: meta.update(size=str(len(data)), sha256Checksum=hashlib.sha256(data).hexdigest())
        self.files[file_id] = {"metadata": meta, "data": data}
        return file_id

    def add_segment(self, seed=1, *, with_manifest=True, with_audio=True, with_transcript=True,
                    recording_group=None, grouped_stem=None):
        item, audio = segment(seed, seed=seed)
        manifest = item["manifest"]
        sid = manifest["id"]
        if recording_group is not None:
            manifest["recordingGroup"] = recording_group
        nonce = "SYNTHETIC PHONE ONLY NONCE " + str(seed)
        result = {"manifest": manifest, "audio": audio, "nonce": nonce}
        entries = [("audio", audio), ("manifest", canonical_json(manifest).encode())]
        transcript = transcript_for(item, nonce)
        entries += [("transcriptJSON", canonical_json(transcript).encode()),
                    ("transcriptText", ("Record for Agent — 自动转写，可能有误\n片段ID: " + sid
                     + "\n原音频SHA256: " + manifest["sha256"] + "\n开始: synthetic\n结束: synthetic\n语言: zh-CN\n\n" + nonce + "\n").encode())]
        for index, (kind, data) in enumerate(entries):
            sha = hashlib.sha256(data).hexdigest()
            stem = grouped_stem + sid if grouped_stem is not None else sid
            name = stem + {"audio": ".caf", "manifest": ".manifest.json", "transcriptJSON": ".transcript-"+sha[:16]+".json",
                          "transcriptText": ".transcript-"+sha[:16]+".txt"}[kind]
            fid = "seg%dFile%d" % (seed, index)
            result[kind+"ID"] = fid
            properties = {"rfaSchema": "1", "rfaLibraryID": LIBRARY, "rfaSegmentID": sid,
                          "rfaKind": kind, "rfaAudioSHA256": manifest["sha256"], "rfaContentSHA256": sha}
            mime = {"audio": "audio/x-caf", "manifest": "application/json", "transcriptJSON": "application/json", "transcriptText": "text/plain"}[kind]
            self.add(fid, name, mime, data, properties)
            if ((kind == "audio" and not with_audio) or (kind == "manifest" and not with_manifest)
                    or (kind.startswith("transcript") and not with_transcript)):
                result[kind+"Stored"] = self.files.pop(fid)
        return result

    def request(self, method, url, *, headers=None, body=None, token=False, sink=None):
        self.calls.append((method, url))
        assert method == "GET" and body is None and not token
        assert headers["Authorization"] == "Bearer synthetic-access"
        parsed, query = urlsplit(url), parse_qs(urlsplit(url).query)
        route = parsed.path.removeprefix("/drive/v3/")
        def reply(value, status=200): return status, {}, canonical_json(value).encode()
        if route == "about": return reply({"user": {"emailAddress": self.email, "permissionId": self.owner}})
        if route == "files":
            assert query["q"] == ["'%s' in parents and trashed=false" % FOLDER]
            if query.get("pageToken") and self.invalid_page_once:
                self.invalid_page_once = False
                return reply({}, 400)
            offset = int(query.get("pageToken", ["0"])[0])
            rows = [copy.deepcopy(v["metadata"]) for k,v in sorted(self.files.items()) if k != FOLDER]
            response = {"files": rows[offset:offset+100], "incompleteSearch": False}
            if offset+100 < len(rows): response["nextPageToken"] = str(offset+100)
            return reply(response)
        parts = route.split("/")
        fid = parts[1]
        if fid in self.http_failures: return reply({}, self.http_failures[fid])
        if fid in self.fail_ids: raise DriveError("network_unavailable")
        value = self.files.get(fid)
        if value is None: return reply({}, 404)
        if len(parts) == 3:
            perms = [{"id": OWNER, "type": "user", "role": "owner"}]
            if fid in self.shared: perms.append({"id": "anyone", "type": "anyone", "role": "reader"})
            return reply({"permissions": perms})
        if query.get("alt") == ["media"]:
            self.downloads.append(fid)
            sink(value["data"])
            if self.after_media: self.after_media(fid)
            return 200, {}, b""
        return reply(copy.deepcopy(value["metadata"]))


class PhoneDriveReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve(); self.root.chmod(0o700)
        self.state = self.root / "observer"
        phone.PhoneDriveReader.initialize(self.state, email=EMAIL, owner_id=OWNER, folder_id=FOLDER, library_id=LIBRARY)
        self.google = FakePhoneGoogle()
        self.item = self.google.add_segment()
        self.reader = phone.PhoneDriveReader(self.state, lambda: "synthetic-access", transport=self.google)

    def tearDown(self): self.temp.cleanup()

    def drain(self, rounds=4):
        for _ in range(rounds): self.reader.scan()

    def rows(self):
        with self.reader.connection() as db: return {r["kind"]: dict(r) for r in db.execute("SELECT * FROM objects")}

    def test_four_tools_source_content_and_no_audio_scan_download(self):
        self.drain()
        rows = self.rows()
        self.assertEqual(set(rows), {"audio", "manifest", "transcript", "text"})
        for kind in ("manifest", "transcript", "text"):
            result = self.reader.drive_read_object({"object_key": rows[kind]["key"]})
            self.assertEqual(result["source"]["segmentID"], self.item["manifest"]["id"])
            self.assertEqual(result["source"]["audioSHA256"], self.item["manifest"]["sha256"])
            self.assertFalse(result["contentIsAgentInstruction"])
            self.assertFalse(result["completeSession"])
        self.assertIn(self.item["nonce"], self.reader.drive_read_object({"object_key": rows["text"]["key"]})["content"])
        recordings = self.reader.drive_list_recordings({})["recordings"]
        self.assertEqual(len(recordings), 1)
        self.assertEqual(len(recordings[0]["artifacts"]), 4)
        info = self.reader.drive_audio_info({"object_key": rows["audio"]["key"]})
        self.assertEqual(info["audioBytesReturned"], 0)
        self.assertFalse(info["audioDecoded"])
        self.assertNotIn(self.item["audioID"], self.google.downloads)

    def test_grouped_names_are_verified_against_the_manifest(self):
        group_id = str(uuid.uuid4())
        group = {"id": group_id, "startedAt": 1700000000000, "utcOffsetMinutes": 480, "firstSequence": 0}
        first = self.google.add_segment(2, recording_group=group,
            grouped_stem="2023-11-15_06-13-20+0800_" + group_id + "__2023-11-15_06-13-22+0800_part003_")
        forged = self.google.add_segment(3, recording_group=group,
            grouped_stem="2023-11-15_06-13-20+0800_" + group_id + "__2023-11-15_06-13-23+0800_part999_")
        self.drain()
        rows = {row["recordingID"]: row for row in self.reader.drive_list_recordings({})["recordings"]}
        self.assertEqual(set(rows), {self.item["manifest"]["id"], first["manifest"]["id"]})
        self.assertEqual(rows[first["manifest"]["id"]]["recordingGroup"], group)
        self.assertNotIn("recordingGroup", rows[self.item["manifest"]["id"]])
        self.assertNotIn(first["audioID"], self.google.downloads)
        self.assertNotIn(forged["audioID"], self.google.downloads)

    def test_incremental_late_asr_restart_and_empty_resume(self):
        late = {k:self.google.files.pop(self.item[k+"ID"]) for k in ("transcriptJSON", "transcriptText")}
        self.drain()
        first = self.reader.drive_list_changes({})
        self.assertEqual({x["kind"] for x in first["changes"]}, {"audio", "manifest"})
        cursor = first["resumeCursor"]
        self.reader = phone.PhoneDriveReader(self.state, lambda: "synthetic-access", transport=self.google)
        for kind, value in late.items(): self.google.files[self.item[kind+"ID"]] = value
        self.drain()
        update = self.reader.drive_list_changes({"cursor": cursor})
        self.assertEqual({x["kind"] for x in update["changes"]}, {"text", "transcript"})
        self.assertIsNone(update["nextCursor"])
        cursor = update["resumeCursor"]
        for _ in range(2):
            empty = self.reader.drive_list_changes({"cursor": cursor})
            self.assertEqual(empty["changes"], [])
            self.assertEqual(empty["resumeCursor"], cursor)
        with self.reader.connection() as db: self.assertEqual(db.execute("SELECT count(*) FROM events").fetchone()[0], 4)

    def test_audio_before_manifest_is_pending_and_eventually_published(self):
        manifest = self.google.files.pop(self.item["manifestID"])
        first = self.reader.drive_list_changes({})
        self.assertEqual(first["changes"], [])
        self.assertTrue(first["scanIncomplete"])
        self.assertGreater(first["pendingCandidates"], 0)
        self.google.files[self.item["manifestID"]] = manifest
        self.drain()
        self.assertEqual(set(self.rows()), {"audio", "manifest", "text", "transcript"})

    def test_large_directory_budget_pages_and_rejected_or_pending_dont_block(self):
        for index in range(281):
            self.google.add("invalid%04d"%index, "unrelated", "text/plain", b"Synthetic", {"rfaSchema": "999"})
        result = self.reader.scan()
        self.assertEqual(result["discoveredThisPass"], 100)
        self.assertLessEqual(result["processedThisPass"], 8)
        self.assertTrue(result["scanIncomplete"])
        with self.reader.connection() as db:
            self.assertIsNotNone(db.execute("SELECT page_token FROM scan").fetchone()[0])
        self.reader = phone.PhoneDriveReader(self.state, lambda: "synthetic-access", transport=self.google)
        self.drain(40)
        self.assertEqual(len(self.rows()), 4)
        self.assertNotIn(self.item["audioID"], self.google.downloads)

    def test_invalid_provider_page_token_restarts_without_duplicate_publication(self):
        for index in range(110):
            self.google.add("z%d"%index, "unrelated", "text/plain", b"Synthetic", {})
        self.reader.scan()
        self.google.invalid_page_once = True
        result = self.reader.scan()
        self.assertEqual(result["notice"], "page_token_restarted")
        self.drain(20)
        with self.reader.connection() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM events").fetchone()[0], 4)

    def test_unfinished_and_network_failed_first_audio_dont_block_other_segment(self):
        self.google.files[self.item["audioID"]]["metadata"].pop("sha256Checksum")
        second = self.google.add_segment(2)
        self.drain()
        result = self.reader.drive_list_recordings({})
        self.assertEqual([r["recordingID"] for r in result["recordings"]], [second["manifest"]["id"]])
        self.google.files[self.item["audioID"]]["metadata"]["sha256Checksum"] = self.item["manifest"]["sha256"]
        self.drain()
        self.assertEqual(len(self.reader.drive_list_recordings({})["recordings"]), 2)

    def test_wrong_account_owner_folder_shared_or_scope_changed_fail_closed(self):
        self.google.owner = "otherOwner"
        with self.assertRaises(DriveError): self.reader.scan()
        self.assertFalse(self.google.downloads)
        self.google.owner = OWNER
        self.google.email = "other@example.invalid"
        with self.assertRaises(DriveError): self.reader.scan()
        self.google.email = EMAIL
        self.google.shared.add(FOLDER)
        with self.assertRaises(DriveError): self.reader.scan()
        self.google.shared.clear()
        with self.reader.connection() as db:
            value = dict(self.reader.configuration, folderID="unselected")
            db.execute("UPDATE configuration SET value=?", (canonical_json(value),))
        self.google.calls.clear()
        with self.assertRaises(DriveError): self.reader.scan()
        self.assertFalse(self.google.calls)

    def test_media_hash_oversize_source_mismatch_and_permission_changes_rejected(self):
        self.drain()
        key = self.rows()["text"]["key"]
        fid = self.item["transcriptTextID"]
        original = self.google.files[fid]["data"]
        self.google.files[fid]["data"] = b"X" * len(original)
        with self.assertRaises(DriveError): self.reader.drive_read_object({"object_key": key})
        self.google.files[fid]["data"] = original + b"over"
        with self.assertRaises(DriveError): self.reader.drive_read_object({"object_key": key})
        self.google.files[fid]["data"] = original
        self.google.after_media = lambda _: self.google.shared.add(fid)
        with self.assertRaises(DriveError): self.reader.drive_read_object({"object_key": key})
        self.google.after_media = None; self.google.shared.clear()
        self.google.files[fid]["metadata"]["parents"] = ["unselectedFolder"]
        with self.assertRaises(DriveError): self.reader.drive_read_object({"object_key": key})

    def test_bad_manifest_or_transcript_source_doesnt_publish_or_stop_other_sources(self):
        fid = self.item["transcriptJSONID"]
        value = json.loads(self.google.files[fid]["data"])
        value["audioSHA256"] = "a"*64
        data = canonical_json(value).encode()
        meta = self.google.files[fid]["metadata"]
        sha = hashlib.sha256(data).hexdigest()
        meta["sha256Checksum"] = sha; meta["size"] = str(len(data))
        meta["appProperties"]["rfaContentSHA256"] = sha
        meta["name"] = self.item["manifest"]["id"] + ".transcript-"+sha[:16]+".json"
        self.google.files[fid]["data"] = data
        self.google.add_segment(2)
        self.drain()
        with self.reader.connection() as db:
            self.assertIsNone(db.execute("SELECT key FROM objects WHERE file_id=?", (fid,)).fetchone())
            self.assertEqual(db.execute("SELECT count(*) FROM objects WHERE kind='audio'").fetchone()[0], 2)

    def test_audio_info_only_fallback_is_bounded_and_rechecks_after_download(self):
        self.drain()
        key = self.rows()["audio"]["key"]
        self.google.files[self.item["audioID"]]["metadata"].pop("sha256Checksum")
        info = self.reader.drive_audio_info({"object_key": key})
        self.assertEqual(info["audioBytesReturned"], 0)
        self.assertEqual(self.google.downloads.count(self.item["audioID"]), 1)
        self.google.after_media = lambda _: self.google.shared.add(self.item["audioID"])
        with self.assertRaises(DriveError): self.reader.drive_audio_info({"object_key": key})

    def test_transport_rejects_mutations_arbitrary_queries_ids_urls_and_media(self):
        fence = phone.PhoneReadOnlyHTTP(FOLDER, ["selected"], transport=self.google)
        urls = [DRIVE+"files", DRIVE+"files?"+"q=anything", DRIVE+"files/unselected",
                DRIVE+"files/selected?alt=media", DRIVE+"files/selected?access_token=secret",
                "https://evil.invalid/drive/v3/files/selected", DRIVE+"changes"]
        for url in urls:
            with self.subTest(url=url):
                with self.assertRaises(DriveError): fence.request("GET", url)
        with self.assertRaises(DriveError): fence.request("DELETE", DRIVE+"files/selected?fields="+phone.FIELDS)
        self.assertFalse(self.google.calls)
        for value in ("../../token", "https://evil.invalid", "' OR 1=1", "phone-"+"a"*64):
            with self.assertRaises(DriveError): self.reader.drive_read_object({"object_key": value})

    def test_observer_private_files_and_cursor_types_config_reinit_rejected(self):
        self.drain()
        for path in self.state.iterdir(): self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        cursor = self.reader.drive_list_changes({"limit": 1})["resumeCursor"]
        with self.assertRaises(DriveError): self.reader.drive_list_recordings({"cursor": cursor})
        with self.assertRaises(FileExistsError):
            phone.PhoneDriveReader.initialize(self.state, email=EMAIL, owner_id=OWNER, folder_id=FOLDER, library_id=LIBRARY)
        before = self.reader.database.read_bytes()
        self.reader.drive_read_object({"object_key": self.rows()["text"]["key"]})
        self.assertEqual(self.reader.database.read_bytes(), before)

    def test_transient_503_and_rate_limit_403_cannot_consume_existing_event(self):
        self.drain()
        for status in (503, 403, 429):
            with self.subTest(status=status):
                self.google.http_failures[self.item["audioID"]] = status
                with self.assertRaises(DriveError): self.reader.drive_list_changes({})
                self.google.http_failures.clear()
                replay = self.reader.drive_list_changes({})
                self.assertIn(self.rows()["audio"]["key"], {x["objectKey"] for x in replay["changes"]})
                self.assertEqual(len(replay["changes"]), 4)

    def test_shared_published_file_is_unavailable_then_restored_event_after_resume(self):
        self.drain()
        fid = self.item["transcriptTextID"]
        self.google.shared.add(fid)
        result = self.reader.drive_list_changes({})
        unavailable = [x for x in result["changes"] if x["operation"] == "artifact_unavailable"]
        self.assertEqual(len(unavailable), 1)
        cursor = result["resumeCursor"]
        self.google.shared.clear()
        self.drain()
        restored = self.reader.drive_list_changes({"cursor": cursor})
        self.assertEqual(len(restored["changes"]), 1)
        self.assertEqual(restored["changes"][0]["kind"], "text")
        self.assertEqual(len(self.reader.drive_list_recordings({})["recordings"]), 1)

    def test_transient_candidate_and_crash_between_publish_and_progress_recovers_once(self):
        self.google.http_failures[self.item["audioID"]] = 403
        self.drain()
        self.assertNotIn("audio", self.rows())
        self.google.http_failures.clear()
        self.drain()
        with self.reader.connection() as db:
            # Equivalent to a process exit after the atomic publication commit,
            # before the candidate's success/progress commit.
            db.execute("UPDATE candidates SET state='pending' WHERE file_id=?", (self.item["audioID"],))
        self.reader = phone.PhoneDriveReader(self.state, lambda: "synthetic-access", transport=self.google)
        self.drain()
        with self.reader.connection() as db: self.assertEqual(db.execute("SELECT count(*) FROM events").fetchone()[0], 4)

    def test_request_deadline_stops_between_requests_and_stream_chunks(self):
        moment = [0.0]
        self.reader.clock = lambda: moment[0]
        original = self.google.request
        def slow(method, url, **kwargs):
            result = original(method, url, **kwargs)
            moment[0] += 8
            return result
        with mock.patch.object(self.google, "request", side_effect=slow):
            status = self.reader.scan()
        self.assertTrue(status["scanIncomplete"])
        self.assertLessEqual(len(self.google.calls), 4)
        self.assertFalse(self.google.downloads)
        self.reader.clock = phone.time.monotonic
        self.drain()
        self.assertEqual(len(self.rows()), 4)
        moment[0] = 0
        fence = phone.PhoneReadOnlyHTTP(FOLDER, [self.item["audioID"]], [self.item["audioID"]],
            transport=self.google, deadline=1, clock=lambda: moment[0])
        moment[0] = 2
        with self.assertRaises(DriveError): fence.validate_url(DRIVE+"files/"+self.item["audioID"]+"?alt=media")

    def test_slow_realistic_http_latency_cannot_starve_first_manifest_and_audio(self):
        for latency in (0.6, 1.0):
            with self.subTest(latency=latency):
                state = self.root / ("latency-"+str(latency))
                phone.PhoneDriveReader.initialize(state, email=EMAIL, owner_id=OWNER, folder_id=FOLDER, library_id=LIBRARY)
                google = FakePhoneGoogle(); item = google.add_segment()
                moment = [0.0]
                original = google.request
                def slow(method, url, **kwargs):
                    result = original(method, url, **kwargs)
                    moment[0] += latency
                    return result
                reader = phone.PhoneDriveReader(state, lambda: "synthetic-access", transport=google, clock=lambda: moment[0])
                cursor = None; published = set()
                with mock.patch.object(google, "request", side_effect=slow):
                    for _ in range(8):
                        result = reader.drive_list_changes({"cursor":cursor} if cursor else {})
                        published.update(e.get("kind") for e in result["changes"])
                        cursor = result["resumeCursor"]
                self.assertEqual(published, {"audio", "manifest", "transcript", "text"})
                self.assertNotIn(item["audioID"], google.downloads)

    def test_snapshot_references_do_not_duplicate_restored_artifact_events(self):
        self.drain()
        key = self.rows()["text"]["key"]
        with self.reader.connection() as db:
            for _ in range(40): db.execute("INSERT INTO events(object_key) VALUES(?)", (key,))
        snapshot = self.reader.drive_list_recordings({})["recordings"][0]
        self.assertEqual({r["kind"] for r in snapshot["artifacts"]}, {"audio", "manifest", "transcript", "text"})
        self.assertEqual(len(snapshot["artifacts"]), 4)

    def test_reopened_reader_smaller_object_limit_prevents_audio_fallback(self):
        self.drain()
        key = self.rows()["audio"]["key"]
        self.google.downloads.clear()
        small = phone.PhoneDriveReader(self.state, lambda: "synthetic-access", transport=self.google,
                                      max_text_bytes=1, max_object_bytes=100)
        self.google.files[self.item["audioID"]]["metadata"].pop("sha256Checksum")
        with self.assertRaises(DriveError): small.drive_audio_info({"object_key": key})
        self.assertFalse(self.google.downloads)

    def test_actual_stdio_subprocess_reads_synthetic_phone_nonce(self):
        self.drain()
        key = self.rows()["text"]["key"]
        script = """
import base64,json,sys
from test_phone_drive_mcp_server import FakePhoneGoogle
from phone_drive_mcp_server import PhoneDriveReader,serve
world=json.loads(sys.stdin.buffer.readline())
google=FakePhoneGoogle()
google.files={key:{'metadata':value['metadata'],'data':base64.b64decode(value['data']) if value['data'] is not None else None} for key,value in world.items()}
serve(PhoneDriveReader(sys.argv[1],lambda:'synthetic-access',transport=google))
"""
        import base64
        world = {key:{"metadata":value["metadata"],"data":base64.b64encode(value["data"]).decode() if value["data"] is not None else None} for key,value in self.google.files.items()}
        messages = [{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"Synthetic child","version":"1"}}},
                    {"jsonrpc":"2.0","method":"notifications/initialized"},
                    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"drive_read_object","arguments":{"object_key":key}}}]
        result = subprocess.run([sys.executable,"-B","-c",script,str(self.state)],
            input=canonical_json(world)+"\n"+"".join(canonical_json(m)+"\n" for m in messages),
            capture_output=True,text=True,timeout=10,
            env={"PYTHONPATH":str(Path(__file__).resolve().parent)+":"+str(Path(__file__).resolve().parents[1]),"PYTHONDONTWRITEBYTECODE":"1"})
        self.assertEqual(result.returncode,0,result.stderr); self.assertEqual(result.stderr,"")
        replies=[json.loads(line) for line in result.stdout.splitlines()]
        self.assertIn(self.item["nonce"],replies[-1]["result"]["structuredContent"]["content"])
        self.assertNotIn("synthetic-access",result.stdout); self.assertNotIn(str(self.root),result.stdout)

    def test_credential_corruption_and_additional_scope_fail_without_provider_call(self):
        token = self.root / "synthetic-token.json"
        provider = phone.StrictFileTokenProvider.__new__(phone.StrictFileTokenProvider)
        provider.path = token
        for content in ([], None, {"scopes":[phone.SCOPE, "https://www.googleapis.com/auth/drive.readonly"]}):
            token.write_text(canonical_json(content)); token.chmod(0o600)
            with self.assertRaises(DriveError) as raised: provider()
            self.assertEqual(raised.exception.code, "credential_scope_mismatch")

    def test_foundation_uppercase_uuid_json_binds_to_lowercase_properties_and_txt(self):
        for kind in ("manifest", "transcriptJSON"):
            fid = self.item[kind+"ID"]
            entry = self.google.files[fid]
            value = json.loads(entry["data"])
            for field in ("id", "sessionID", "segmentID"):
                if field in value: value[field] = value[field].upper()
            data = canonical_json(value).encode()
            sha = hashlib.sha256(data).hexdigest()
            entry["data"] = data
            meta = entry["metadata"]
            meta.update(size=str(len(data)), sha256Checksum=sha)
            meta["appProperties"]["rfaContentSHA256"] = sha
            if kind == "transcriptJSON": meta["name"] = self.item["manifest"]["id"] + ".transcript-"+sha[:16]+".json"
        self.drain()
        self.assertEqual(len(self.rows()), 4)
        for row in self.rows().values():
            self.assertEqual(json.loads(row["source"])["segmentID"], self.item["manifest"]["id"])
        for kind in ("manifest", "transcript", "text"):
            self.reader.drive_read_object({"object_key": self.rows()[kind]["key"]})

    def test_folder_deletion_never_tombstones_and_consumes_all_recording_events(self):
        self.drain()
        self.google.files.pop(FOLDER)
        with self.assertRaises(DriveError) as raised: self.reader.drive_list_changes({})
        self.assertEqual(raised.exception.code, "destination_identity_mismatch")

    def test_stdio_four_tools_error_redaction_and_synthetic_nonce(self):
        self.drain()
        messages = [{"jsonrpc":"2.0", "id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"Synthetic Phone UAT","version":"1"}}},
                    {"jsonrpc":"2.0","method":"notifications/initialized"},
                    {"jsonrpc":"2.0","id":2,"method":"tools/list"},
                    {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"drive_read_object","arguments":{"object_key":self.rows()["text"]["key"]}}}]
        output = io.BytesIO()
        phone.serve(self.reader, io.BytesIO("".join(canonical_json(m)+"\n" for m in messages).encode()), output)
        text = output.getvalue().decode()
        replies = [json.loads(line) for line in text.splitlines()]
        self.assertEqual(len(replies[1]["result"]["tools"]), 4)
        self.assertIn(self.item["nonce"], replies[2]["result"]["structuredContent"]["content"])
        self.assertNotIn("synthetic-access", text); self.assertNotIn(str(self.root), text)
        self.reader.provider = mock.Mock(side_effect=OSError("synthetic-secret https://secret.invalid"))
        server = phone.MCPServer(self.reader); server.initialized = server.ready = True
        response = server.handle(messages[-1])
        self.assertEqual(response["result"]["structuredContent"], {"error":{"code":"read_unavailable"}})
        self.assertNotIn("synthetic-secret", canonical_json(response))


if __name__ == "__main__": unittest.main()
