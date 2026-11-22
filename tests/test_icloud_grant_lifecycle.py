"""Owner grant ordering and deletion in a Hub shared by the server and importer."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import threading

import pytest

from hub import icloud_sync
from hub.store import Store


@pytest.fixture
def library(tmp_path, monkeypatch):
    bridge = Path(__file__).resolve().parents[1] / "channels/audio/record-for-agent/AgentBridge/tests"
    monkeypatch.syspath_prepend(str(bridge))
    from test_icloud_drive_library import Fixture

    root = tmp_path / "library"
    root.mkdir()
    return root, [Fixture(root) for _ in range(4)]


@pytest.mark.parametrize("previously_granted", [False, True])
def test_revoke_during_explicit_grant_wins_for_only_its_members(library, tmp_path, monkeypatch, previously_granted):
    root, (revoked, kept, late, regranted) = library
    lib = kept.library
    db_path = tmp_path / "hub.sqlite3"
    store, owner = Store(db_path), Store(db_path)
    ids = [revoked.sid, kept.sid, late.sid, regranted.sid]
    for item in (revoked, kept, regranted):
        item.commit()
    if previously_granted:
        icloud_sync.sync(root, lib, store, ids, grant_agent_metadata=True)

    original = icloud_sync.observe
    scan_done, resume = threading.Event(), threading.Event()
    def blocked_scan(*args):
        result = original(*args)
        scan_done.set()
        assert resume.wait(timeout=10)
        return result

    with ThreadPoolExecutor(max_workers=1) as pool:
        monkeypatch.setattr(icloud_sync, "observe", blocked_scan)
        pending = pool.submit(icloud_sync.sync, root, lib, store, ids, grant_agent_metadata=True)
        try:
            assert scan_done.wait(timeout=10)
            monkeypatch.setattr(icloud_sync, "observe", original)
            # Pending intents alone must not publish a Raw, even to a simultaneous normal sync.
            icloud_sync.sync(root, lib, owner, ids)
            assert len(owner.list_raw(agent=True)) == (3 if previously_granted else 0)
            assert icloud_sync.set_metadata_grant(owner, lib, [revoked.sid, late.sid, regranted.sid], enabled=False) == 3
            icloud_sync.sync(root, lib, owner, [regranted.sid], grant_agent_metadata=True)
        finally:
            resume.set()
        pending.result(timeout=10)

    late.commit()
    restarted = Store(db_path)
    icloud_sync.sync(root, lib, restarted, ids)
    assert {row["provenance"]["original_id"] for row in restarted.list_raw(agent=True)} == {kept.sid, regranted.sid}
    with restarted._transaction(False) as conn:
        assert conn.execute("SELECT count(*) FROM icloud_pending_grants").fetchone()[0] == 0


def test_failed_folder_verification_does_not_activate_or_keep_intents(library, tmp_path):
    root, (item, _, _, wrong) = library
    item.commit()
    store = Store(tmp_path / "hub.sqlite3")
    with pytest.raises(icloud_sync.ObservationError):
        icloud_sync.sync(root, wrong.sid, store, [item.sid], grant_agent_metadata=True)
    with store._transaction(False) as conn:
        for table in ("icloud_pending_grants", "icloud_metadata_grants"):
            assert conn.execute("SELECT count(*) FROM " + table).fetchone()[0] == 0


@pytest.mark.parametrize("legacy", [False, True])
def test_edits_and_deletes_purge_projection_copies_and_migrate_legacy(library, tmp_path, legacy):
    root, (deleted, edited, unchanged, future) = library
    ids = [deleted.sid, edited.sid, unchanged.sid, future.sid]
    for item in (deleted, edited, unchanged):
        item.commit()
    lib = deleted.library
    db_path = tmp_path / "hub.sqlite3"
    store = Store(db_path)
    icloud_sync.sync(root, lib, store, ids, grant_agent_metadata=True)
    records = {row["provenance"]["original_id"]: row for row in store.list_raw()}
    if legacy:
        # Simulate the actual old schema semantics across a restart.
        with store._transaction(True) as conn:
            conn.execute("DROP TRIGGER clear_icloud_projection_on_revision")
            conn.execute("DELETE FROM hub_migrations WHERE name='clear_stale_icloud_projections'")
    body = records[edited.sid]
    body["content"]["text"] = "owner-only revision"
    store.put_raw(body, body["revision"])
    store.delete_raw(records[deleted.sid]["id"], records[deleted.sid]["revision"])
    assert [v["provenance"]["original_id"] for v in store.list_raw(agent=True)] == [unchanged.sid]

    def cached(db):
        with db._transaction(False) as conn:
            return {row["segment_id"]: (row["verified_revision"], row["projection"], row["searchable"])
                    for row in conn.execute("SELECT * FROM icloud_metadata_grants")}

    if legacy:
        before = cached(store)
        assert all(all(before[sid]) for sid in (deleted.sid, edited.sid))
    else:
        assert all(cached(store)[sid] == (None, None, None) for sid in (deleted.sid, edited.sid))
    for _ in range(2):
        store = Store(db_path)
        rows = cached(store)
        assert all(rows[sid] == (None, None, None) for sid in (deleted.sid, edited.sid, future.sid))
        assert all(rows[unchanged.sid])
        assert {v["provenance"]["original_id"] for v in store.list_raw(agent=True)} == {unchanged.sid}
    future.commit()
    icloud_sync.sync(root, lib, store, ids)
    assert {v["provenance"]["original_id"] for v in store.list_raw(agent=True)} == {unchanged.sid, future.sid}
    rows = cached(store)
    assert rows[deleted.sid] == rows[edited.sid] == (None, None, None)
