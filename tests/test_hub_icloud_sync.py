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
