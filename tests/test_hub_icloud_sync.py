import json
from pathlib import Path

import pytest

from hub.icloud_sync import initialize_baseline, sync, ObservationError
from hub.store import Store

BRIDGE = Path(__file__).resolve().parents[1] / "channels/audio/record-for-agent/AgentBridge"


def test_scoped_cloud_commits_retry_gate_and_owner_privacy(tmp_path, monkeypatch):
    monkeypatch.syspath_prepend(str(BRIDGE / "tests"))
    from test_icloud_drive_library import Fixture
    root = tmp_path / "library"
    root.mkdir()
    chosen, historical, absent, pending = [Fixture(root) for _ in range(4)]
    chosen.commit(audio_present=True)
    historical.commit(audio_present=True)
    pending_commit, _ = pending.commit(audio_present=True)
    manifest_file = root / next(a["relativePath"] for a in pending_commit["artifacts"] if a["kind"] == "manifest")
    saved = manifest_file.read_bytes()
    manifest_file.unlink()

    baseline_path = tmp_path / "baseline.json"
    assert initialize_baseline(root, chosen.library, baseline_path)["baselineCount"] == 3
    before = json.loads(baseline_path.read_text())
    with pytest.raises(FileExistsError):
        initialize_baseline(root, chosen.library, baseline_path)
    db = Store(tmp_path / "local.sqlite3")
    ids = [chosen.sid, absent.sid, pending.sid]
    def run():
        return sync(root, chosen.library, db, ids, before)

    assert run() == dict(absentSelected=1, pending=1, rejected=0, created=1, updated=0, unchanged=0, preserved=0)
    # Both arrived between runs. This old cloud source materialized late; only the genuinely new one is eligible.
    delayed, fresh = Fixture(root), Fixture(root)
    delayed.commit(audio_present=True)
    fresh.commit(audio_present=True, at=before["startedAt"] + 1)
    manifest_file.write_bytes(saved)
    chosen.commit("private synthetic transcript", at=before["startedAt"] + 10, audio_present=True)
    assert run() == dict(absentSelected=1, pending=0, rejected=0, created=2, updated=1, unchanged=0, preserved=0)
    assert run()["unchanged"] == 3
    records = db.list_raw()
    assert {r["provenance"]["original_id"] for r in records} == {chosen.sid, fresh.sid, pending.sid}
    assert all(r["kind"] == "cloud_audio_commit" and r["privacy"]["tier"] == "local_only" for r in records)
    assert db.list_raw(agent=True) == [] and db.extract()["created"] == 0
    assert "private synthetic transcript" not in json.dumps(records)
    first = next(r for r in records if r["provenance"]["original_id"] == chosen.sid)
    db.delete_raw(first["id"], first["revision"])
    assert run()["preserved"] == 1
    with pytest.raises(ObservationError, match="library_identity_changed"):
        sync(root, absent.sid, db, ids, before)


def test_evicted_audio_and_no_content_reads(tmp_path, monkeypatch):
    monkeypatch.syspath_prepend(str(BRIDGE / "tests"))
    from test_icloud_drive_library import Fixture
    import icloud_drive_library as producer
    root = tmp_path / "library"
    root.mkdir()
    source = Fixture(root)
    report, _ = source.commit("never-open", audio_present=True)
    other = Fixture(root)
    other.commit("unselected", audio_present=True)
    reader = producer.ICloudDriveLibrary(root, source.library)
    visited = []
    read = reader._read
    def guard(descriptor, path, **opts):
        visited.append(path)
        assert not path.startswith(("audio/", "transcripts/"))
        assert other.sid not in path
        return read(descriptor, path, **opts)
    monkeypatch.setattr(reader, "_read", guard)
    real_stat = reader._stat
    def stat_entry(descriptor, path, *, audio=False, expected_size=None):
        if audio:
            raise producer.ICloudDriveError("icloud_not_downloaded", pending=True)
        return real_stat(descriptor, path, audio=audio, expected_size=expected_size)
    monkeypatch.setattr(reader, "_stat", stat_entry)
    observed = reader.hub_metadata([source.sid])
    assert len(observed["segments"]) == 1 and observed["audioBytesRead"] == 0
    assert observed["segments"][0]["transcriptCommitted"] and observed["cloudSyncComplete"] is False
    assert "never-open" not in json.dumps(observed)
    assert len(visited) > 0


def test_hydration_requests_only_selected_commit_then_bound_manifest(tmp_path, monkeypatch):
    monkeypatch.syspath_prepend(str(BRIDGE / "tests"))
    import subprocess
    from test_icloud_drive_library import Fixture
    import icloud_drive_library as producer
    root = tmp_path / "library"
    root.mkdir()
    source, old = Fixture(root), Fixture(root)
    report, commit = source.commit("synthetic private", audio_present=True)
    old.commit("unselected", audio_present=True)
    manifest = root / next(x["relativePath"] for x in report["artifacts"] if x["kind"] == "manifest")
    for expected in [commit, manifest]:
        reader = producer.ICloudDriveLibrary(root, source.library, request_metadata=True)
        def pretend_evicted(path, value):
            if path == expected or old.sid in str(path):
                raise producer.ICloudDriveError("icloud_not_downloaded", pending=True)
        monkeypatch.setattr(reader, "_sync", pretend_evicted)
        result = reader.hub_metadata([source.sid])
        assert result["pending"] == 1 and result["segments"] == []
        def request(cmd, **opts):
            files = cmd[cmd.index("-e") + 2:]
            assert files == [str(expected)]
            assert all("/audio/" not in x and "/transcripts/" not in x for x in files)
            return subprocess.CompletedProcess(cmd, 0, "1\n", "")
        monkeypatch.setattr(producer.subprocess, "run", request)
        assert reader.request_pending_metadata() == 1


def test_incorrect_committed_audio_size_is_rejected(tmp_path, monkeypatch):
    monkeypatch.syspath_prepend(str(BRIDGE / "tests"))
    from test_icloud_drive_library import Fixture
    import icloud_drive_library as producer
    root = tmp_path / "library"
    root.mkdir()
    source = Fixture(root)
    report, _ = source.commit(audio_present=True)
    (root / next(x["relativePath"] for x in report["artifacts"] if x["kind"] == "audio")).write_bytes(b"wrong")
    observed = producer.ICloudDriveLibrary(root, source.library).hub_metadata([source.sid])
    assert observed["rejected"] == 1 and observed["segments"] == []


def test_selected_metadata_grant_is_read_only_revision_bound_and_revocable(tmp_path, monkeypatch):
    from hub.contract import validate_event
    from hub.icloud_sync import main, set_metadata_grant
    from hub.imports import stable_id
    from hub.store import StoreError

    monkeypatch.syspath_prepend(str(BRIDGE / "tests"))
    from test_icloud_drive_library import Fixture
    root = tmp_path / "library"
    root.mkdir()
    first, later, manual, deleted, extra = [Fixture(root) for _ in range(5)]
    members = [first.sid, later.sid, manual.sid, deleted.sid]
    library = first.library
    for item in (first, manual, deleted, extra):
        item.commit("private text sentinel", audio_present=True)
    db = Store(tmp_path / "local.sqlite3")
    def rid(item):
        return stable_id("record-for-agent.icloud", library, item.sid)
    sync(root, library, db, members + [extra.sid])
    original = db.get_raw(rid(first))
    assert db.list_raw(agent=True) == []
    edited = db.get_raw(rid(manual))
    edited["content"]["text"] = "private manual edit"
    db.put_raw(edited, edited["revision"])
    db.delete_raw(rid(deleted), 1)

    # An incorrect library marker cannot activate the grant, even with the same selected IDs.
    with pytest.raises(ObservationError):
        sync(root, extra.sid, db, members, grant_agent_metadata=True)
    assert db.list_raw(agent=True) == []
    selected = tmp_path / "ids.json"
    selected.write_text(json.dumps(members))
    assert main(["--library-id", library, "--library-root", str(root), "--selection", str(selected),
                 "--grant-agent-metadata", "--data-dir", str(tmp_path)]) == 0
    visible = db.get_raw(rid(first), agent=True)
    assert visible["privacy"] == {"tier": "redacted"} and db.get_raw(rid(first)) == original
    validate_event({key: value for key, value in visible.items() if key != "revision"})
    assert visible["content"] == {} and (visible["tz"], visible["tz_source"]) == ("UTC", "utc_fallback")
    assert set(visible) == {"id", "source", "kind", "t_start", "t_end", "t_observed", "tz", "tz_source",
                            "content", "privacy", "context", "provenance", "revision"}
    assert set(visible["context"]) == {"sessionID", "sequence", "sampleRate", "frameCount", "byteCount"}
    assert set(visible["provenance"]) == {"connector", "source_id", "original_id", "source_hash", "manifest_sha256",
                                          "library_id", "evidence", "provider_upload_status", "audio_content_verified"}
    assert visible["provenance"]["original_id"] == first.sid and visible["provenance"]["library_id"] == library
    assert not db.list_raw("private", agent=True) and not db.list_raw("transcript", agent=True)
    assert not db.list_raw("Asia/Shanghai", agent=True)
    assert [row["id"] for row in db.list_raw(agent=True)] == [rid(first)]
    with pytest.raises(StoreError, match="not found"):
        db.delete_raw(visible["id"], visible["revision"], agent=True)
    with pytest.raises(StoreError, match="unavailable"):
        db.put_raw(visible, visible["revision"], agent=True)

    # A later arrival is recognized by a restarted normal sync even with a different selection.
    later.commit(audio_present=True)
    db = Store(tmp_path / "local.sqlite3")
    sync(root, library, db, [extra.sid])
    assert {row["id"] for row in db.list_raw(agent=True)} == {rid(first), rid(later)}
    assert db.get_raw(rid(manual))["content"]["text"] == "private manual edit"
    assert set_metadata_grant(db, extra.sid, [later.sid], enabled=False) == 0
    owner = db.get_raw(rid(later))
    owner["content"]["text"] = "new owner edit"
    db.put_raw(owner, owner["revision"])
    assert [row["id"] for row in db.list_raw(agent=True)] == [rid(first)]
    # Repeated observation never republishes that edit or restores a deleted source.
    sync(root, library, db, members)
    assert not db.list_raw("new owner edit", agent=True)
    assert main(["--library-id", library, "--selection", str(selected), "--revoke-agent-metadata",
                 "--data-dir", str(tmp_path)]) == 0
    assert db.list_raw(agent=True) == [] and db.get_raw(rid(first)) == original
    assert set_metadata_grant(db, library, members, enabled=False) == 0
    sync(root, library, db, members)
    assert db.list_raw(agent=True) == []
    with pytest.raises(StoreError, match="not found"):
        db.get_raw(rid(deleted))


def test_agent_http_distinguishes_identical_segment_ids_in_different_libraries(tmp_path, monkeypatch):
    import threading
    import uuid

    from hub.agent import HubClient, HubError
    from hub.server import HubHTTP
    from hub.icloud_sync import set_metadata_grant

    monkeypatch.syspath_prepend(str(BRIDGE / "tests"))
    from test_icloud_drive_library import Fixture, encoded
    a, b = tmp_path / "drive-a", tmp_path / "drive-b"
    a.mkdir()
    b.mkdir()
    first = Fixture(a)
    second = Fixture(b, sid=first.sid)
    second.library = str(uuid.uuid4())
    second.write("library.json", encoded({"schemaVersion": 1, "libraryID": second.library,
                                          "format": "record-for-agent-icloud-drive"}))
    for item in (first, second):
        item.commit("test-only private transcript", audio_present=True)
    store = Store(tmp_path / "hub.sqlite3")
    sync(b, second.library, store, [second.sid])
    sync(a, first.library, store, [first.sid], grant_agent_metadata=True)
    assert len(store.list_raw()) == 2
    with HubHTTP(("127.0.0.1", 0), store, "test-owner", "test-agent") as http:
        thread = threading.Thread(target=http.serve_forever, kwargs={"poll_interval": .01})
        thread.start()
        try:
            client = HubClient(f"http://127.0.0.1:{http.server_port}", "test-agent")
            rows = client.request("GET", "/api/raw?q=" + first.sid)["items"]
            assert len(rows) == 1 and rows[0]["provenance"]["library_id"] == first.library
            assert client.one("GET", "raw", rows[0]["id"]) == rows[0]
            assert client.request("GET", "/api/raw?q=transcript")["items"] == []
            set_metadata_grant(store, first.library, [first.sid], enabled=False)
            assert client.request("GET", "/api/raw")["items"] == []
            with pytest.raises(HubError) as revoked:
                client.one("GET", "raw", rows[0]["id"])
            assert revoked.value.status == 404
        finally:
            http.shutdown()
            thread.join()
