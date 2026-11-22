import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from hub.deepseek_history import deepseek_rows


class DeepSeekHistoryTests(unittest.TestCase):
    def test_visible_turns_only_and_source_identity(self):
        def user(key, kind, text):
            return {"id": key, "role": "user", "source": {"kind": kind},
                    "content": [{"type": "text", "text": text}]}

        assistant = {"id": "a", "role": "assistant",
                     "content": [{"type": "reasoning", "text": "hidden reasoning"},
                                 {"type": "text", "text": "public answer"}]}
        rows = [
            {"type": "session", "id": "conversation", "cwd": "/example",
             "delegationDepth": 1, "parentSession": "parent"},
            {"type": "user/message", "time": 1730000000000, "data": user("u", "user", "included")},
            {"type": "user/message", "time": 1730000000001, "data": user("x", "goal", "excluded")},
            {"type": "assistant/chunk", "data": {"chunk": {"text": "partial copy"}}},
            {"type": "assistant/message", "time": 1730000000002, "data": {"message": assistant}},
        ]
        with TemporaryDirectory() as temp:
            path = Path(temp) / "session.jsonl"
            path.write_text("\n".join(map(json.dumps, rows)))
            turns = list(deepseek_rows(path))
            self.assertEqual(turns, list(deepseek_rows(path)))
        self.assertEqual([turn["content"]["text"] for turn in turns], ["included", "public answer"])
        self.assertTrue(all(turn["privacy"]["tier"] == "local_only" for turn in turns))
        self.assertEqual(turns[1]["context"]["origin"], "subagent")
        self.assertEqual(turns[0]["provenance"]["message_id"], "u")
