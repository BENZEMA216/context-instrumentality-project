import json
import sqlite3
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

from hub.imports import stable_id
from hub.store import Store
from hub.wechat_ocr import observe_frame


def pane(*words, confidence=.96):
    return {"status": "ok", "lines": [
        {"text": word, "x": .1, "y": i / (1 + len(words)), "width": .7, "height": .05,
         "confidence": confidence} for i, word in enumerate(words)]}


class WeChatObservationTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / "demo.sqlite"
        self.store = Store(self.path)
        self.now = 100

    def observe(self, frame, *, account="demo", conversation="fixture-room"):
        self.now += 1
        return observe_frame(self.store, frame, account=account, conversation=conversation, observed_ms=self.now)

    def test_scroll_and_reopen_are_incremental_without_message_claims(self):
        initial = self.observe(pane("周五?", "先讨论", "有进展"))
        self.store = Store(self.path)
        repeated = pane("周五?", "先讨论", "有进展", confidence=.91)
        repeated["lines"][1]["y"] += .02
        self.assertEqual(self.observe(repeated), {"status": "unchanged"})
        tail = self.store.get_raw(self.observe(pane("先讨论", "有进展", "周一。"))["id"])
        self.assertEqual(tail["source"], "wechat.ocr")
        self.assertEqual(tail["episode_id"], stable_id("wechat-conversation", "demo", "fixture-room"))
        self.assertEqual(tail["actor"], "unknown")
        self.assertEqual(tail["context"]["time_basis"], "screen_observation")
        self.assertEqual((tail["t_start"], tail["t_end"], tail["t_observed"]), (103, 103, 103))
        self.assertEqual(tail["content"]["text"], "周一。")
        self.assertEqual(tail["content"]["ocr_lines"], pane("先讨论", "有进展", "周一。")["lines"][-1:])
        self.assertEqual(tail["provenance"]["overlap_lines"], 2)
        self.assertEqual(tail["links"], [{"target_id": initial["id"], "relation": "overlaps_observation"}])
        self.assertEqual(self.observe(pane("周五?", "先讨论", "有进展")), {"status": "unchanged"})
        self.store.extract()
        self.assertEqual([len(self.store.list_raw()), len(self.store.list_raw(agent=True)),
                          len(self.store.list_memory(agent=True))], [2, 0, 0])
        with sqlite3.connect(self.path) as conn:
            checkpoint, = conn.execute("SELECT line_keys FROM wechat_ocr_cursors").fetchone()
            for key, strong in json.loads(checkpoint):
                self.assertRegex(key, r"^[a-f0-9]{64}$")
                self.assertTrue(strong)

    def test_ambiguous_overlap_reorder_disjoint_or_low_confidence_keeps_observed_screen(self):
        cases = [
            (pane("a", "b"), pane("b", "later")),
            (pane("a", "b", "a", "b"), pane("a", "b", "a", "b", "later")),
            (pane("a", "b", "c"), pane("b", "c", "other", "b", "c")),
            (pane("a", "b", "c"), pane("b", "a", "later")),
            (pane("a", "b"), pane("d", "d")),
            (pane("a", "b", confidence=.5), pane("a", "b", "later")),
        ]
        for i, (original, changed) in enumerate(cases):
            scope = str(i)
            self.observe(original, conversation=scope)
            event = self.store.get_raw(self.observe(changed, conversation=scope)["id"])
            self.assertEqual(event["provenance"]["observation_mode"], "unaligned_viewport")
            self.assertEqual(event["content"]["ocr_lines"], changed["lines"])
            self.assertNotIn("links", event)

    def test_gaps_clear_alignment_and_do_not_cross_account_or_chat(self):
        frame = pane("锚一", "锚二")
        initial = self.observe(frame)
        for account, room in [("other", "fixture-room"), ("demo", "other-room")]:
            result = self.observe(frame, account=account, conversation=room)
            self.assertNotEqual(result["id"], initial["id"])
        self.assertEqual(self.observe({"status": "skipped", "reason": "title_mismatch"}),
                         {"status": "skipped", "reason": "title_mismatch"})
        resumed = self.store.get_raw(self.observe(pane("锚一", "锚二", "新"))["id"])
        self.assertEqual(resumed["provenance"]["observation_mode"], "baseline_viewport")
        self.assertEqual(resumed["content"]["text"], "锚一\n锚二\n新")
        self.assertEqual(self.observe(pane()), {"status": "skipped", "reason": "empty_pane"})

    def test_old_viewport_reappearing_after_gap_does_not_restore_old_evidence_link(self):
        for gap in ("explicit", "elapsed"):
            with self.subTest(gap=gap):
                screen = pane("A", "B")
                self.observe(screen, conversation=gap)
                if gap == "explicit":
                    self.observe({"status": "skipped", "reason": "title_mismatch"}, conversation=gap)
                else:
                    self.now += 91_000
                self.store = Store(self.path)
                self.assertEqual(self.observe(screen, conversation=gap), {"status": "unchanged"})
                self.assertEqual(self.observe(screen, conversation=gap), {"status": "unchanged"})
                updated = self.store.get_raw(self.observe(pane("A", "B", "C"), conversation=gap)["id"])
                self.assertEqual(updated["content"]["text"], "A\nB\nC")
                self.assertEqual(updated["provenance"]["observation_mode"], "baseline_viewport")
                self.assertNotIn("links", updated)

    def test_user_edit_or_delete_survives_replay(self):
        original = pane("漏识别", "模拟文本")
        raw = self.store.get_raw(self.observe(original)["id"])
        raw["content"] = {"text": "人工校正"}
        self.store.put_raw(raw, expected_revision=1)
        self.assertEqual(self.observe(original), {"status": "unchanged"})
        self.assertEqual(self.store.get_raw(raw["id"])["content"], {"text": "人工校正"})
        self.store.delete_raw(raw["id"], expected_revision=2)
        self.assertEqual(self.observe(original), {"status": "unchanged"})
        self.assertEqual(self.store.list_raw(), [])
        changed = self.store.get_raw(self.observe(pane("漏识别", "模拟文本", "新的一行"))["id"])
        self.assertNotIn("links", changed)
        self.assertEqual(changed["content"]["text"], "新的一行")
        self.assertEqual(changed["provenance"]["observation_mode"], "tail_after_user_change")
        self.assertEqual(self.store.list_raw("漏识别"), [])

    def test_invalid_and_stale_input_do_not_advance_cursor(self):
        self.observe(pane("first", "second"))
        invalid = pane("text")
        invalid["lines"][0]["x"] = .95
        with self.assertRaises(ValueError):
            self.observe(invalid)
        self.assertEqual(observe_frame(self.store, pane("earlier"), account="demo",
                                       conversation="fixture-room", observed_ms=1)["reason"], "stale_observation")
        event = self.store.get_raw(self.observe(pane("first", "second", "third"))["id"])
        self.assertEqual(event["content"]["text"], "third")

    def test_concurrent_retries_and_failed_transaction(self):
        frame = pane("private fixture")
        with patch.object(self.store, "_put_raw", side_effect=RuntimeError("simulated write failure")):
            with self.assertRaises(RuntimeError):
                self.observe(frame)
        with ThreadPoolExecutor(max_workers=5) as pool:
            results = list(pool.map(lambda _: observe_frame(self.store, frame, account="demo",
                                conversation="fixture-room", observed_ms=101), range(6)))
        self.assertEqual(sum(row["status"] == "created" for row in results), 1)
        self.assertEqual(len(self.store.list_raw()), 1)
        self.assertEqual(self.observe(frame), {"status": "unchanged"})


if __name__ == "__main__":
    unittest.main()
