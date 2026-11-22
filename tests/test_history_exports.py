import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from hub.history_exports import export_native, project
from hub.history_sources import rows


class NativeExportTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.out = self.root / "out"

    def save_lines(self, path, objects):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(v) + "\n" for v in objects))
        return path

    def result(self, sid):
        file = self.out / (sid + ".json")
        self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.out.stat().st_mode & 0o777, 0o700)
        return json.loads(file.read_text())

    def test_cursor_orders_selected_headers_excludes_orphans_and_resolves_project(self):
        db = self.root / "state.vscdb"

        def state(tab, path, entries):
            with sqlite3.connect(path) as c:
                c.execute(f"CREATE TABLE {tab}(key TEXT PRIMARY KEY,value TEXT)")
                c.executemany(
                    f"INSERT INTO {tab} VALUES(?,?)",
                    [(k, json.dumps(v)) for k, v in entries.items()],
                )

        compose = {
            "composerId": "s",
            "fullConversationHeadersOnly": [
                {"bubbleId": k} for k in ("u", "hide", "a", "missing", "u")
            ],
            "text": "draft",
            "subComposerIds": ["child"],
        }

        def bubble(mid, role, text, **extra):
            return {"bubbleId": mid, "type": role, "text": text, **extra}

        state(
            "cursorDiskKV",
            db,
            {
                "composerData:s": compose,
                "composerData:child": {
                    "composerId": "child",
                    "fullConversationHeadersOnly": [],
                },
                "bubbleId:s:a": bubble(
                    "a",
                    2,
                    "reply",
                    parentBubbleId="hide",
                    thinking="secret",
                    createdAt="2026-01-01T12:00:00Z",
                ),
                "bubbleId:s:hide": bubble(
                    "hide", 2, "system", skipRendering=True, parentBubbleId="u"
                ),
                "bubbleId:s:u": bubble("u", 1, "question", richText="attachment"),
                "bubbleId:s:orphan": bubble("orphan", 2, "detached"),
            },
        )
        ws = self.root / "workspaces" / "one"
        ws.mkdir(parents=True)
        (ws / "workspace.json").write_text(
            json.dumps({"folder": "file:///projects/one"})
        )
        state(
            "ItemTable",
            ws / "state.vscdb",
            {"composer.composerData": {"allComposers": [{"composerId": "s"}]}},
        )
        counts = export_native("cursor", db, self.out, ws.parent)
        self.assertEqual(
            (counts["missing_header_bubbles"], counts["unknown_timestamp"]), (1, 1)
        )
        doc = self.result("s")
        self.assertEqual(doc["project"], project("/projects/one"))
        self.assertEqual(
            [(m["id"], m["text"]) for m in doc["messages"]],
            [("u", "question"), ("a", "reply")],
        )
        self.assertIsNone(doc["messages"][0]["timestamp"])
        self.assertEqual(doc["messages"][1]["parent_id"], "u")
        self.assertEqual(self.result("child")["parent_session_id"], "s")

    def test_workbuddy_uses_only_visible_fields_and_follows_branches(self):
        def row(tag, mid, parent, **kwargs):
            return {
                "type": tag,
                "id": mid,
                "parentId": parent,
                "sessionId": "wb",
                "cwd": "/secret/project",
                "timestamp": "2026-01-01T12:00:00Z",
                "providerData": {"text": "hidden"},
                **kwargs,
            }

        wrapped = '<system-reminder data-role="host">secret</system-reminder><user_query>human</user_query>'
        file = self.save_lines(
            self.root / "p" / "a.jsonl",
            [
                row(
                    "message",
                    "u",
                    None,
                    role="user",
                    content=[
                        {
                            "type": "input_text",
                            "text": wrapped,
                            "providerData": {"text": "hidden"},
                        },
                        {"type": "output_text", "text": "wrong role"},
                    ],
                ),
                row("function_call_result", "t", "u", output="secret"),
                row("reasoning", "r", "t"),
                row(
                    "message",
                    "a",
                    "r",
                    role="assistant",
                    content=[{"type": "output_text", "text": "answer"}],
                ),
                row(
                    "message",
                    "b",
                    "u",
                    role="assistant",
                    content=[{"type": "output_text", "text": "alternative"}],
                ),
            ],
        )
        export_native("workbuddy", file.parent.parent, self.out)
        doc = self.result("wb")
        self.assertEqual(
            [m["text"] for m in doc["messages"]], ["human", "answer", "alternative"]
        )
        self.assertEqual(
            [m.get("parent_id") for m in doc["messages"]], [None, "u", "u"]
        )
        self.assertNotIn("secret", json.dumps(doc))
        self.assertEqual(len(list(rows(self.out / "wb.json", "transcript", None))), 3)

    def test_qclaw_strips_native_sender_metadata_and_keeps_visible_json(self):
        fence = chr(96) * 3
        packet = (
            "Sender (untrusted metadata):\n"
            + fence
            + 'json\n{"id":"not-for-export"}\n'
            + fence
            + "\n\nactual question"
        )
        file = self.save_lines(
            self.root / "q.jsonl",
            [
                {"type": "session", "id": "q", "cwd": "/project"},
                {
                    "type": "message",
                    "id": "u",
                    "timestamp": 1000,
                    "message": {
                        "role": "user",
                        "content": [{"type": "text", "text": packet}],
                    },
                },
                {
                    "type": "message",
                    "id": "tool",
                    "parentId": "u",
                    "message": {
                        "role": "toolResult",
                        "content": [{"type": "text", "text": "secret"}],
                    },
                },
                {
                    "type": "message",
                    "id": "b",
                    "parentId": "tool",
                    "message": {
                        "role": "assistant",
                        "content": [
                            {"type": "thinking", "text": "secret"},
                            {"type": "text", "text": '{"visible":true}'},
                        ],
                    },
                },
            ],
        )
        self.assertEqual(export_native("qclaw", file, self.out)["unknown_timestamp"], 1)
        doc = self.result("q")
        self.assertEqual(
            [m["text"] for m in doc["messages"]],
            ["actual question", '{"visible":true}'],
        )
        self.assertEqual(doc["messages"][1]["parent_id"], "u")
        self.assertNotIn("not-for-export", json.dumps(doc))

    def test_opencode_scopes_parts_filters_injections_and_preserves_parent_session(
        self,
    ):
        db = self.root / "opencode.db"
        with sqlite3.connect(db) as c:
            c.executescript(
                "CREATE TABLE session(id,project_id,directory,parent_id); CREATE TABLE message(id,session_id,time_created,data); CREATE TABLE part(id,message_id,session_id,time_created,data);"
            )
            c.execute(
                "INSERT INTO session VALUES(?,?,?,?)",
                ("s", "p", "/project", "ancestor"),
            )
            for mid, t, meta in [
                ("u", 100, {"role": "user", "summary": {"title": "private"}}),
                (
                    "a",
                    101,
                    {"role": "assistant", "parentID": "u", "time": {"created": 105}},
                ),
            ]:
                c.execute(
                    "INSERT INTO message VALUES(?,?,?,?)",
                    (mid, "s", t, json.dumps(meta)),
                )
            for i, (mid, session_id, typ, text, flags) in enumerate(
                [
                    ("u", "s", "text", "human", {}),
                    ("a", "s", "reasoning", "secret", {}),
                    ("a", "s", "text", "ignore", {"ignored": True}),
                    ("a", "s", "text", "host", {"synthetic": True}),
                    ("a", "other", "text", "wrong session", {}),
                    ("a", "s", "text", "final", {}),
                ]
            ):
                c.execute(
                    "INSERT INTO part VALUES(?,?,?,?,?)",
                    (
                        str(i),
                        mid,
                        session_id,
                        i,
                        json.dumps({"type": typ, "text": text, **flags}),
                    ),
                )
        counts = export_native("opencode", db, self.out)
        self.assertEqual(counts["sessions"], 1)
        doc = self.result("s")
        self.assertEqual(doc["parent_session_id"], "ancestor")
        self.assertEqual(
            [(m["id"], m["text"], m["timestamp"]) for m in doc["messages"]],
            [("u", "human", 100), ("a", "final", 105)],
        )
        self.assertEqual(doc["messages"][1]["parent_id"], "u")

    def test_private_output_and_untrusted_session_id(self):
        source = self.save_lines(
            self.root / "src.jsonl",
            [
                {"type": "session", "id": "../escape"},
                {
                    "type": "message",
                    "id": "u",
                    "message": {"role": "user", "content": "hello"},
                },
            ],
        )
        self.out.mkdir()
        self.out.chmod(0o755)
        with self.assertRaises(ValueError):
            export_native("qclaw", source, self.out)
        self.out.chmod(0o700)
        self.assertEqual(export_native("qclaw", source, self.out)["user"], 1)
        self.assertFalse((self.root / "escape.json").exists())
        self.assertEqual(len(list(self.out.glob("*.json"))), 1)
