import copy
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from hub.store import Store, StoreError


def event(event_id, text="决定把检索放在本地。", tier="redacted", source="clipboard"):
    return {"id": event_id, "source": source, "kind": "copy", "t_start": 1000, "t_end": 1000,
            "t_observed": 1010, "content": {"text": text}, "privacy": {"tier": tier},
            "provenance": {"connector": "demo", "source_id": event_id}}


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "nested" / "hub.db"
        self.store = Store(self.path)

    def assert_status(self, status, function, *args, **kwargs):
        with self.assertRaises(StoreError) as caught:
            function(*args, **kwargs)
        self.assertEqual(caught.exception.status, status)

    def test_roundtrip_schema_and_provenance(self):
        raw = event("r1")
        raw["content"].update({"arbitrary": {"设备": ["ＴｅＳＴ", 1.25]}, "excerpts":[{"text":"证据", "locator":"1:11"}]})
        self.assertEqual(self.store.put_raw(raw), dict(raw, revision=1))
        reopened = Store(self.path)
        self.assertEqual(reopened.list_raw("设备 TeSt"), [dict(raw, revision=1)])
        alias = dict(raw, id="other", t_observed=999)
        self.assertEqual(reopened.put_raw(alias), dict(raw, revision=1))
        different = event("r1", "另外的内容")
        self.assert_status(409, reopened.put_raw, different)
        self.assertEqual(reopened.put_raw(different, 1)["revision"], 2)
        self.assert_status(409, reopened.put_raw, different, 1)
        colliding = copy.deepcopy(different)
        colliding["provenance"]["source_id"] = "another-source"
        self.assert_status(409, reopened.put_raw, colliding)
        # An equal connector ID on a different channel is an independent piece of evidence.
        second = dict(raw, id="voice1", source="voice")
        self.assertEqual(reopened.put_raw(second)["id"], "voice1")
        self.assertEqual(len(reopened.list_raw()), 2)

    def test_invalid_external_values(self):
        for invalid in (dict(event("r1"), t_start=True), dict(event("r1"), t_end=-1),
                        dict(event("r1"), id=" "), dict(event("r1"), id="."), dict(event("r1"), id=".."),
                        dict(event("r1"), privacy={}), dict(event("r1"), source="mail.message\n"),
                        dict(event("r1"), extra={"x":1}), dict(event("r1"), attention=2),
                        dict(event("r1"), content={"text": 4}), dict(event("r1"), attention=float("nan")), dict(event("r1"), t_start=2**70)):
            self.assert_status(400, self.store.put_raw, invalid)
        self.assert_status(400, self.store.list_raw, limit=10000)
        self.assert_status(400, self.store.list_memory, offset=-2)

    def test_extraction_search_and_duplicate_invalidation(self):
        self.store.put_raw(event("a", "你好。然后再聊。多谢。决定使用 SQLite WAL。"))
        self.store.put_raw(event("b", "你好。然后再聊。多谢。决定使用 SQLite WAL。", source="voice"))
        self.assertEqual(self.store.extract(), {"created": 1, "updated":1, "skipped":0})
        note, = self.store.list_memory("决定 wal")
        self.assertIn("SQLite WAL", note["title"])
        self.assertEqual(note["evidence_ids"], ["a", "b"])
        self.assertEqual(self.store.extract()["created"], 0)
        self.store.put_raw(event("a", "计划改为离线。"), 1)
        immediately = self.store.get_memory(note["id"])
        self.assertEqual(immediately["evidence_ids"], ["b"])
        self.store.delete_raw("b", 1)
        self.assertEqual(self.store.list_memory("WAL"), [])
        self.assertEqual(self.store.extract()["created"], 1)
        self.assertEqual(self.store.list_memory("离线")[0]["evidence_ids"], ["a"])
        self.assert_status(410, self.store.put_raw, event("b", source="voice"))

    def test_edit_cannot_target_provenance_through_a_different_id(self):
        original = event("canonical")
        self.store.put_raw(original)
        different_id = dict(original, id="other")
        self.assert_status(409, self.store.put_raw, different_id, 1)
        different_id["content"] = {"text":"overwrite from the wrong URL"}
        self.assert_status(409, self.store.put_raw, different_id, 1)
        self.assertEqual(self.store.get_raw("canonical"), dict(original, revision=1))
        self.assert_status(404, self.store.get_raw, "other")

    def test_distinct_code_and_speakers_do_not_share_a_memory(self):
        for i, code in enumerate(("Foo?", "foo?", "Foo.", "  Foo?")):
            self.store.put_raw(event("code" + str(i), code))
        for role in ("assistant", "user"):
            raw = event(role, "周一需要交稿。", source="ai_chat")
            raw["content"]["role"] = role
            self.store.put_raw(raw)
        self.assertEqual(self.store.extract()["created"], 6)
        quotes = self.store.list_memory("交稿")
        self.assertEqual(len(quotes), 2)
        for quote in quotes:
            self.assertIn(quote["evidence_ids"][0], quote["title"])

    def test_tombstones_survive_repeat_and_reopen(self):
        self.store.put_raw(event("a"))
        self.store.extract()
        note, = self.store.list_memory()
        self.store.delete_memory(note["id"], note["revision"])
        reopened = Store(self.path)
        reopened.put_raw(event("b"))
        reopened.put_raw(event("a", "更正。"), 1)
        reopened.extract()
        self.assertEqual(reopened.list_memory(), [])

    def test_namespaced_source_can_roundtrip_owner_fields_and_extract(self):
        mail = event("m1", source="mail.message")
        mail["kind"] = "message"
        mail["content"] = {"title":"团队来信", "text":"请周五提交初稿。", "provider_payload":{"thread":"T-2"}}
        self.assertEqual(self.store.put_raw(mail), dict(mail, revision=1))
        self.assertEqual(self.store.extract()["created"], 1)
        result, = self.store.list_memory("周五")
        self.assertEqual((result["title"],result["body"]), ("团队来信","请周五提交初稿。"))
        self.assertEqual(self.store.get_raw(result["evidence_ids"][0])["content"], mail["content"])

    def test_metadata_only_and_source_summary(self):
        blob = event("empty", "")
        blob["content"] = {"asset": {"name":"sample.dat"}}
        self.store.put_raw(blob)
        other = event("web", source="browser")
        other["content"] = {"title":"索引说明","summary":"此页比较了两种索引。", "text":"冗长的正文。"}
        self.store.put_raw(other)
        window = event("window", source="window")
        del window["content"]
        window["context"] = {"app_bundle":"demo.app", "window_title":"工作区"}
        self.store.put_raw(window)
        self.assertEqual(self.store.extract(), {"created":2, "updated":0, "skipped":1})
        self.assertEqual(self.store.list_memory("索引")[0]["body"], "此页比较了两种索引。")
        self.assertIn("demo.app", self.store.list_memory("工作区")[0]["body"])
        self.assertEqual(self.store.get_raw("empty")["content"], blob["content"])

    def test_manual_changes_and_evidence_retirement(self):
        self.store.put_raw(event("a"))
        self.store.extract()
        extracted, = self.store.list_memory()
        data = dict(extracted, title="我自己的标题", body="我自己的注释")
        manual = self.store.save_memory(data, extracted["revision"])
        self.assertEqual(manual["origin"], "manual")
        self.assert_status(409, self.store.save_memory, data, extracted["revision"])
        self.store.put_raw(event("a", "计划改用离线存储。"), 1)
        self.assertTrue(self.store.get_memory(manual["id"])["needs_review"])
        self.assert_status(404, self.store.get_memory, manual["id"], agent=True)
        self.store.extract()
        self.assertEqual(len(self.store.list_memory()), 1)
        reviewed = self.store.get_memory(manual["id"])
        self.store.save_memory(dict(reviewed, body="已核对改用离线存储"), reviewed["revision"])
        self.assertEqual(len(self.store.list_memory(agent=True)), 1)
        self.store.delete_raw("a", 2)
        self.assertEqual(self.store.list_memory(), [])

    def test_deleted_payload_is_removed_from_sql_and_freed_pages_after_close(self):
        marker = "fixture-to-erase-" * 200
        self.store.put_raw(event("erase", marker))
        self.store.extract()
        self.store.delete_raw("erase", 1)
        self.assertEqual(self.store.list_raw("fixture-to-erase"), [])
        self.assertEqual(self.store.list_memory("fixture-to-erase"), [])
        # No live SQLite readers remain. This checks only this database, not backups or snapshots.
        self.assertNotIn(b"fixture-to-erase-", self.path.read_bytes())

    def test_manually_reviewed_extraction_is_not_replaced_by_new_duplicate(self):
        self.store.put_raw(event("first"))
        self.store.extract()
        memory, = self.store.list_memory()
        reviewed = self.store.save_memory(dict(memory, title="用户核对", body="已校正的说明"), memory["revision"])
        self.store.put_raw(event("later"))
        self.store.extract()
        result, = self.store.list_memory()
        self.assertEqual(result, reviewed)
        self.store.delete_memory(result["id"], result["revision"])
        self.store.put_raw(event("another"))
        self.store.extract()
        self.assertEqual(self.store.list_memory(), [])
        self.assert_status(404, self.store.save_memory, dict(reviewed), reviewed["revision"])

    def test_agent_scope_and_privacy_transition(self):
        self.store.put_raw(event("public"))
        self.store.put_raw(event("secret", tier="local_only"))
        self.store.extract()
        self.assertEqual([r["id"] for r in self.store.list_raw(agent=True)], ["public"])
        public, = self.store.list_memory(agent=True)
        self.assertEqual(public["evidence_ids"], ["public"])
        local = self.store.save_memory({"title":"both","body":"secret details","evidence_ids":["public","secret"]})
        self.assert_status(404, self.store.get_memory, local["id"], agent=True)
        self.assert_status(404, self.store.save_memory, dict(local, evidence_ids=["public"]), 1, agent=True)
        self.assert_status(404, self.store.save_memory, {"title":"note","body":"x","evidence_ids":["secret"]}, agent=True)
        self.assert_status(404, self.store.put_raw, event("secret"), 1, agent=True)
        self.assert_status(404, self.store.delete_raw, "secret", 1, agent=True)
        self.store.put_raw(event("public", tier="local_only"), 1)
        self.assertEqual(self.store.list_memory(agent=True), [])
        self.store.extract()
        self.assertEqual(self.store.list_raw(agent=True), [])
        self.assertEqual(self.store.list_memory(agent=True), [])

    def test_racing_retries_and_edits(self):
        with ThreadPoolExecutor(max_workers=6) as pool:
            created = list(pool.map(lambda _: self.store.put_raw(event("a")), range(12)))
        self.assertEqual({r["revision"] for r in created}, {1})

        def edit(i):
            try:
                return self.store.put_raw(event("a", str(i)), 1)["revision"]
            except StoreError as error:
                return error.status

        with ThreadPoolExecutor(max_workers=6) as pool:
            revisions = list(pool.map(edit, range(10)))
        self.assertEqual(revisions.count(2), 1)
        self.assertEqual(revisions.count(409), 9)
        self.assertEqual(self.store.get_raw("a")["revision"], 2)
