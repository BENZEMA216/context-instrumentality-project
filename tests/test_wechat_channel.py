"""Exercise selected-text intake, the real polling entry point and owner-scoped export."""
import json
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

import pytest

from hub.imports import stable_id
from hub.store import Store
from hub.wechat import export_episode, import_text, main


def test_selected_history_is_an_excerpt_and_archive_tracks_owner_changes(tmp_path):
    store = Store(tmp_path / "store.sqlite3")
    document = tmp_path / "excerpt.txt"
    document.write_text("甲建议周五，乙回复下周一。", encoding="utf-8-sig")
    room = stable_id("wechat-conversation", "mine", "team")
    event_id = import_text(store, room, document, 125)["id"]
    assert import_text(store, room, document, 200)["status"] == "already_imported"
    import_text(store, "other-room", document, 202)
    store.extract()
    assert len(store.list_memory()) == 2
    assert store.list_memory(agent=True) == []
    forged = dict(store.get_raw(event_id), id="unrelated", source="clipboard")
    store.put_raw(forged)
    folder = tmp_path / "out"
    result = export_episode(store, room, folder)
    assert result["records"] == 1
    path = folder / result["filename"]
    event, = json.loads(path.read_text())
    assert event["actor"] == "unknown"
    assert event["t_observed"] == event["t_start"] == 125
    assert event["context"]["time_basis"] == "import_observation"
    assert event["id"] == event_id
    assert "revision" not in event and path.stat().st_mode & 0o777 == 0o600
    store.delete_raw(event_id, 1)
    assert import_text(store, room, document, 250)["status"] == "deleted"
    assert export_episode(store, room, folder)["records"] == 0
    assert json.loads(path.read_text()) == []


def test_partial_export_retains_last_completed_snapshot(tmp_path):
    store = Store(tmp_path / "store.sqlite3")
    folder = tmp_path / "export"
    result = export_episode(store, "room", folder)
    original = (folder / result["filename"]).read_bytes()

    def failing_read(*args):
        yield '{"id":"partial"}'
        raise OSError("test interruption")

    with patch.object(store, "episode_events", failing_read), pytest.raises(OSError):
        export_episode(store, "room", folder)
    assert list(folder.iterdir()) == [folder / result["filename"]]
    assert (folder / result["filename"]).read_bytes() == original


def invoke(argv):
    output = StringIO()
    with redirect_stdout(output):
        status = main(argv)
    return status, [json.loads(line) for line in output.getvalue().splitlines()]


def test_poll_loop_with_real_subprocess_idempotent_and_portable(tmp_path, monkeypatch):
    monkeypatch.setenv("HUB_MODE", "local")
    helper = tmp_path / "wechat-ocr"
    frame = {"status": "ok", "lines": [
        {"text": "会议定在周一", "x": 0.1, "y": 0.3, "width": 0.5, "height": 0.1, "confidence": 0.99}]}
    helper.write_text("#!/usr/bin/env python3\nimport sys\n"
                      "assert sys.argv[1] == 'capture' and sys.argv[-4:] == "
                      "['--window-id','123','--process-id','456']\n"
                      + "print(" + repr(json.dumps(frame)) + ")\n")
    helper.chmod(0o700)
    layout = tmp_path / "layout.json"
    layout.write_text(json.dumps({"header": "0.3,0,0.5,0.1", "messages": "0.3,0.2,0.5,0.55",
                                 "status": "ok", "window_size": "800x600", "window_id": 123, "process_id": 456}))
    root = tmp_path / "local"
    folder = tmp_path / "export"
    cmd = ["watch", "--account", "test", "--conversation", "demo", "--title", "项目",
           "--data-dir", str(root), "--helper", str(helper), "--calibration", str(layout),
           "--interval", "2", "--export-dir", str(folder)]
    # Exercise the next scheduled tick using a fake wait; both helper invocations are real subprocesses.
    with patch("hub.wechat.sleep", side_effect=[None, KeyboardInterrupt]):
        code, reports = invoke(cmd)
    assert code == 0 and [row["status"] for row in reports] == ["created", "exported", "unchanged", "exported"]
    store = Store(root / "local.sqlite3")
    row, = store.list_raw()
    assert store.list_raw(agent=True) == [] and row["content"]["text"] == "会议定在周一"
    assert [e["id"] for e in json.loads((folder / reports[1]["filename"]).read_text())] == [row["id"]]
    helper.write_text("#!/usr/bin/env python3\nraise SystemExit(1)\n")
    code, reports = invoke([*cmd, "--once"])
    assert code == 1 and reports[0]["stage"] == "capture"
    assert len(store.list_raw()) == 1


def test_local_cli_rejects_cloud_before_creating_data(tmp_path, monkeypatch):
    monkeypatch.setenv("HUB_MODE", "cloud")
    with pytest.raises(SystemExit) as exc:
        main(["export", "--account", "test", "--conversation", "room", "--data-dir", str(tmp_path / "cloud"),
              "--export-dir", str(tmp_path / "out")])
    assert exc.value.code == 1 and not (tmp_path / "cloud").exists()
