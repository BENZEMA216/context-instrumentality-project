"""Synthetic, committed receiver receipts drive local metadata. No personal library is read."""
import hashlib
import io
import json
from pathlib import Path
import sqlite3
import sys
import uuid

import pytest

from hub.recording_sync import main, sync
from hub.store import Store

BRIDGE = Path(__file__).resolve().parents[1] / "channels/audio/record-for-agent/AgentBridge"


@pytest.fixture
def recorder(tmp_path, monkeypatch):
    monkeypatch.syspath_prepend(str(BRIDGE))
    monkeypatch.syspath_prepend(str(BRIDGE / "tests"))
    from automatic import DeliveryStore
    from test_bridge import segment, write_package
    from test_transcripts import transcript_for, version2

    source = DeliveryStore(tmp_path / "state", tmp_path / "library", str(uuid.uuid4()))
    dest = Store(tmp_path / "local.sqlite3")

    def publish(items, ready=False):
        if ready:
            for entry, _ in items:
                entry["transcript"] = transcript_for(entry, "SECRET SYNTHETIC WORDS")
        package = tmp_path / "selected.zip"
        write_package(package, items, version2(items))
        data = package.read_bytes()
        return source.accept(io.BytesIO(data), len(data), str(uuid.uuid4()), hashlib.sha256(data).hexdigest())

    return source, dest, publish, segment


def test_selection_receipts_retry_owner_privacy_and_late_asr(recorder):
    source, dest, publish, segment = recorder
    first, second, outside = [segment(i) for i in range(3)]
    keys = [x[0]["manifest"]["id"] for x in (first, second)]
    receipt = publish([first, second, outside])
    def run():
        return sync(source.root, source.library, source.receiver_id, dest, keys)

    # A catalog row without an acknowledged request is not a daily receiver arrival.
    with source.connect() as conn:
        old = conn.execute("SELECT receipt_json FROM requests WHERE id=?", (receipt["deliveryID"],)).fetchone()[0]
        conn.execute("UPDATE requests SET receipt_json=NULL")
    assert run()["created"] == 0
    with source.connect() as conn:
        conn.execute("UPDATE requests SET receipt_json=?", (old,))
    assert run()["created"] == 2
    assert run()["unchanged"] == 2
    assert len(dest.list_raw()) == 2
    assert dest.list_raw(agent=True) == []
    publish([first], ready=True)
    assert run()["updated"] == 1
    assert run()["unchanged"] == 2
    items = sorted(dest.list_raw(), key=lambda i: i["context"]["sequence"])
    assert items[0]["content"] == {"source_transcript_available": True}
    assert items[1]["content"] == {"source_transcript_available": False}
    assert "SECRET" not in json.dumps(items) and "location" not in items[0]
    assert dest.extract()["created"] == 0 and dest.list_memory(agent=True) == []

    dest.delete_raw(items[0]["id"], items[0]["revision"])
    edited = {**items[1], "content": {"title": "owner correction"}}
    dest.put_raw(edited, expected_revision=edited["revision"])
    publish([second], ready=True)
    assert run()["preserved"] == 2
    assert len(dest.list_raw()) == 1 and dest.get_raw(edited["id"])["content"] == edited["content"]


def test_mismatched_receiver_forged_receipt_and_since(recorder, tmp_path):
    source, dest, publish, segment = recorder
    receipt = publish([segment(0)], ready=True)
    assert sync(source.root, source.library, source.receiver_id, dest, [], receipt["storedAt"] + 1)["created"] == 0
    with source.connect() as conn:
        conn.execute("UPDATE requests SET receipt_json=?", (json.dumps({**receipt,"archiveSHA256":"f"*64}),))
    assert sync(source.root, source.library, source.receiver_id, dest, [], receipt["storedAt"])["created"] == 0
    with source.connect() as conn:
        conn.execute("UPDATE requests SET receipt_json=?", (json.dumps(receipt),))
    assert sync(source.root, source.library, source.receiver_id, dest, [], receipt["storedAt"] - 10000)["created"] == 1
    with source.connect() as conn:
        conn.execute("UPDATE identity SET library=?", (str(tmp_path/"another_library"),))
    with pytest.raises(ValueError,match="different receivers"):
        sync(source.root, source.library, source.receiver_id, dest, receipt["recordingIDs"])


def test_launch_agent_keeps_the_selected_scope(recorder, tmp_path, capsysbinary):
    import plistlib
    source, dest, publish, segment = recorder
    selection = tmp_path/"ids.json"
    selection.write_text(json.dumps([str(uuid.uuid4())]))
    args = ["--receiver-state", str(source.root), "--receiver-id", source.receiver_id, "--library", str(source.library), "--data-dir", str(tmp_path)]
    assert main([*args,"--selection",str(selection),"--launchd-plist"]) == 0
    plist=plistlib.loads(capsysbinary.readouterr().out)
    assert plist["StartInterval"] == 60 and plist["RunAtLoad"]
    cmd=plist["ProgramArguments"]
    assert cmd[cmd.index("--selection")+1] == str(selection.resolve())
    assert "--since-ms" not in cmd


def test_restart_includes_new_source_but_excludes_replayed_preexisting_audio(recorder):
    source, dest, publish, segment = recorder
    old, newly_received, prior_selected = [segment(i) for i in range(3)]
    publish([old, prior_selected])
    # Fixed activation boundary. Historical source remains in the authentic library and
    # a new durable receipt later names both this old segment and a newly imported one.
    cutoff = 2000
    with sqlite3.connect(source.library/"library.sqlite3") as conn:
        conn.execute("UPDATE exports SET imported_at=?", (cutoff - 1,))
    future = publish([old, newly_received])
    keys = [prior_selected[0]["manifest"]["id"]]
    def run(receiver=source.receiver_id):
        return sync(source.root, source.library, receiver, Store(dest.path), keys, since=cutoff)

    with pytest.raises(ValueError, match="different receivers"):
        run(str(uuid.uuid4()))
    # The writer need never have been running at delivery time.
    assert run()["created"] == 2
    assert run()["unchanged"] == 2
    actual = {row["provenance"]["source_id"] for row in dest.list_raw()}
    assert actual == {prior_selected[0]["manifest"]["id"], newly_received[0]["manifest"]["id"]}
    assert old[0]["manifest"]["id"] in future["recordingIDs"]
