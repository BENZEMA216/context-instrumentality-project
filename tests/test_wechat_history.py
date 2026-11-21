import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

from hub.agent import HubClient
from hub.imports import import_file, main, stable_id
from hub.server import HubHTTP
from hub.store import Store


class WeFlowHistoryTests(unittest.TestCase):
    """Synthetic native file shape, delivered through the real owner HTTP API."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = Path(temp.name) / "history.json"
        self.store = Store(Path(temp.name) / "hub.sqlite3")
        server = HubHTTP(("127.0.0.1", 0), self.store, "test-owner", "test-agent")
        self.url = f"http://127.0.0.1:{server.server_port}"
        self.client = HubClient(self.url, "test-owner")
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

    def snapshot(self, messages, room="fixture-room", exported=1795000123):
        data = {"weflow": {"generator": "WeFlow", "version": "1.0.3", "exportedAt": exported},
                "session": {"accountId": room, "type": "群聊", "displayName": "测试项目",
                            "messageCount": len(messages)}, "messages": messages}
        self.path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        return data

    @staticmethod
    def message(identifier="9876543210987654321", text="提议周五。"):
        return {"localId": 1, "createTime": 1795000000, "localType": 1, "type": "文本",
                "isSend": 0, "senderUsername": "fixture-sender", "senderDisplayName": "甲",
                "content": text, "platformMessageId": identifier}

    def load(self, account="fixture-owner", **kwargs):
        return import_file(self.client, self.path, "weflow-json", account=account, **kwargs)

    def test_selected_file_cli_links_authors_times_and_overlapping_batch(self):
        first = self.message()
        self.snapshot([first])
        with patch.dict(os.environ, {"HUB_URL": self.url, "HUB_OWNER_TOKEN": "test-owner", "HUB_MODE": "local"}), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            main(["weflow-json", str(self.path), "--account", "fixture-owner"])
        self.assertEqual(json.loads(output.getvalue())["created"], 1)
        original, = self.store.list_raw()
        self.assertEqual(original["provenance"]["platform_message_id"], "9876543210987654321")
        self.assertEqual(original["t_start"], 1795000000000)
        self.assertEqual(original["t_observed"], 1795000123000)
        self.assertEqual(original["actor"], "fixture-sender")
        self.assertEqual(original["episode_id"], stable_id("wechat-conversation", "fixture-owner", "fixture-room"))
        self.assertEqual(original["privacy"]["tier"], "local_only")
        self.assertEqual(self.store.list_raw(agent=True), [])

        reply = dict(self.message("9876543210987654322", "确认周一。[引用 甲：提议周五。]"),
                     localType=49, isSend=1, senderUsername="fixture-self", appMsgKind="quote",
                     replyToMessageId=first["platformMessageId"], quotedSender="甲", quotedContent="提议周五。")
        self.snapshot([reply, dict(first, localId=2)], exported=1795001000)
        counts = self.load()
        self.assertEqual((counts["created"], counts["unchanged"]), (1, 1))
        self.assertEqual(self.store.get_raw(original["id"]), original)
        answer, = [r for r in self.store.list_raw() if r["actor"] == "self"]
        self.assertEqual(answer["content"]["text"], "确认周一。")
        self.assertEqual(answer["content"]["exported_content"], reply["content"])
        self.assertEqual(answer["links"], [{"relation": "reply_to", "target_id": original["id"]}])
        self.snapshot([reply])
        self.assertEqual(self.load()["unchanged"], 1)
        self.assertEqual(len(self.store.list_raw()), 2)

    def test_no_platform_id_is_file_scoped_and_media_stays_evidence(self):
        a = self.message(None, "../private/audio.fixture")
        del a["platformMessageId"]
        a.update(localType=34, type="语音", senderUsername="")
        b = {**a, "platformMessageId": 0, "localId": 2}
        self.snapshot([a, b])
        self.assertEqual(self.load()["created"], 2)
        self.assertEqual(self.load()["unchanged"], 2)
        for row in self.store.list_raw():
            self.assertNotIn("platform_message_id", row["provenance"])
            self.assertEqual(row["content"], {"exported_content": "../private/audio.fixture"})
            self.assertEqual(row["actor"], "unknown")
        self.snapshot([b])
        self.assertEqual(self.load()["created"], 1)
        self.assertEqual(len(self.store.list_raw()), 3)

    def test_stable_id_is_scoped_and_changed_text_requires_review(self):
        message = self.message()
        self.snapshot([message])
        self.load()
        self.assertEqual(self.load(account="other-owner")["created"], 1)
        self.snapshot([message], room="different-room")
        self.assertEqual(self.load()["created"], 1)
        self.snapshot([{**message, "content": "改期。"}])
        self.assertEqual(self.load()["conflicts"], 1)
        self.assertEqual(self.load(update_existing=True)["updated"], 1)
        self.assertEqual(len(self.store.list_raw()), 3)

    def test_deleted_or_owner_edited_rows_do_not_block_new_evidence(self):
        removed, corrected, new = [self.message(key) for key in ("gone", "edited", "new")]
        self.snapshot([removed, corrected])
        self.load()
        initial = {r["provenance"]["platform_message_id"]: r for r in self.store.list_raw()}
        self.store.delete_raw(initial["gone"]["id"], expected_revision=1)
        corrected_row = initial["edited"]
        corrected_row["content"]["text"] = "用户校正"
        self.store.put_raw(corrected_row, expected_revision=1)
        self.snapshot([removed, corrected, new])
        self.assertEqual(self.load(), {"skipped": 1, "conflicts": 1, "created": 1,
                                      "updated": 0, "unchanged": 0})
        self.assertEqual(self.store.get_raw(corrected_row["id"])["content"]["text"], "用户校正")
        self.assertEqual(self.load(update_existing=True), {"skipped": 1, "conflicts": 0,
                                                           "created": 0, "updated": 1, "unchanged": 1})
        self.assertEqual(len(self.store.list_raw()), 2)

    def test_scope_identifiers_match_capture_constraints(self):
        for value in (" leading", "trailing ", "", "with\nnewline", "a" * 513):
            with self.subTest(value=value):
                self.snapshot([self.message()])
                with self.assertRaisesRegex(ValueError, "--account"):
                    self.load(account=value)
                self.snapshot([self.message()], room=value)
                with self.assertRaisesRegex(ValueError, "session.accountId"):
                    self.load()
        self.assertEqual(self.store.list_raw(), [])

    def test_invalid_archive_stops_before_first_write(self):
        message = self.message()
        self.snapshot([message])
        with self.assertRaisesRegex(ValueError, "--account"):
            self.load(account=None)
        with self.assertRaisesRegex(ValueError, "local_only"):
            self.load(mode="cloud")
        self.snapshot([message, {**self.message("new"), "createTime": 1795000000000}])
        with self.assertRaisesRegex(ValueError, "seconds"):
            self.load()
        self.snapshot([message, dict(message, localId=2)])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.load()
        data = self.snapshot([message])
        data["weflow"]["format"] = "arkme-json"
        self.path.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "native JSON"):
            self.load()
        self.assertEqual(self.store.list_raw(), [])
