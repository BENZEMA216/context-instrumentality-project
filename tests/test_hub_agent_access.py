import json
import os
import sqlite3
import tempfile
import threading
import time
import unittest
from contextlib import contextmanager
from pathlib import Path

from hub.agent import HubClient
from hub.server import HubHTTP
from hub.store import Store, StoreError, _TABLES


class MeteredStore(Store):
    """Bound SQL work independently of filesystem cache and CI host speed."""

    @contextmanager
    def _transaction(self, write):
        with super()._transaction(write) as conn:
            if write is False:
                steps = 0

                def budget():
                    nonlocal steps
                    steps += 100
                    return steps > 3000

                conn.set_progress_handler(budget, 100)
            yield conn


def raw(key, source, tier, timestamp=1):
    return {"id": key, "kind": "note", "source": source, "t_start": timestamp, "t_end": timestamp,
            "t_observed": timestamp, "privacy": {"tier": tier}, "content": {"text": "fixture"},
            "provenance": {"connector": "synthetic", "source_id": key}}


def seed_legacy(path, n):
    # An existing Hub has no access projection; its original column layouts support positional writes.
    with sqlite3.connect(path) as conn:
        conn.executescript(_TABLES)
        conn.execute("DROP INDEX raw_agent_time")
        conn.execute("DROP INDEX raw_agent_hidden")
        for i in range(n):
            key = f"private-{i}"
            event = raw(key, "ai_chat", "local_only", i + 2)
            encoded = json.dumps(event)
            conn.execute("INSERT INTO raw_events VALUES(?,?,?,?,?,?,?,?,1,0)",
                         (key, "ai_chat", "synthetic", key, encoded, encoded, "local_only", i + 2))
            conn.execute("INSERT INTO memories VALUES(?,?,?,?,'extracted',?,1,0,0,?,?)",
                         (key, "fixture", "private", "private", key, i, i + 2))
            conn.execute("INSERT INTO evidence VALUES(?,?,0)", (key, key))


class AgentAccessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name, "synthetic.sqlite3")

    def test_migrated_private_library_and_sparse_http_pages(self):
        n = int(os.getenv("HUB_SYNTHETIC_AGENT_ROWS", "2500"))
        seed_legacy(self.path, n)
        store = MeteredStore(self.path)
        self.assertEqual(store.list_memory(agent=True), [])
        self.assertEqual(store.list_raw(agent=True), [])
        for key, source, tier in (("a", "voice", "shareable"), ("b", "clipboard", "redacted")):
            store.put_raw(raw(key, source, tier))
            store.save_memory({"id": key, "title": key, "body": "marker", "evidence_ids": [key]})
        # Force a timestamp tie to exercise the ID tiebreaker; this is an older writer's ordinary SQL.
        with sqlite3.connect(self.path) as conn:
            conn.execute("UPDATE memories SET updated_at=1 WHERE id IN ('a','b')")
        http = HubHTTP(("127.0.0.1", 0), store, "synthetic-owner", "synthetic-agent")
        thread = threading.Thread(target=http.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        thread.start()
        try:
            client = HubClient(f"http://127.0.0.1:{http.server_port}", "synthetic-agent")
            for collection in ("raw", "memory"):
                started = time.perf_counter()
                for offset, expected in enumerate((["a"], ["b"], [])):
                    result = client.search(collection, "", 1, offset)["items"]
                    self.assertEqual([r["id"] for r in result], expected)
                self.assertEqual(client.search(collection, "private", 1, 0)["items"], [])
                if os.getenv("HUB_SYNTHETIC_AGENT_ROWS"):
                    print(f"{collection}: {n:,} private sources, four HubClient queries in "
                          f"{time.perf_counter() - started:.4f}s")
        finally:
            http.shutdown()
            http.server_close()
            thread.join()

    def test_mixed_evidence_transitions_and_tombstones(self):
        store = Store(self.path)
        for key, source, tier in (("a", "browser", "redacted"), ("b", "voice", "local_only"),
                                  ("c", "mail.message", "local_only")):
            store.put_raw(raw(key, source, tier))
        store.save_memory({"id": "mixed", "title": "fixture", "body": "combined", "evidence_ids": ["a", "b", "c"]})

        def visible(expected):
            self.assertEqual(bool(store.list_memory("combined", agent=True)), expected)
            if expected:
                self.assertEqual(store.get_memory("mixed", agent=True)["evidence_ids"], ["a", "b", "c"])
            else:
                with self.assertRaises(StoreError) as error:
                    store.get_memory("mixed", agent=True)
                self.assertEqual(error.exception.status, 404)

        visible(False)
        for key, source in (("b", "voice"), ("c", "mail.message")):
            store.put_raw(raw(key, source, "shareable"), 1)
            visible(False)  # The reviewed note still requires an owner's review.
            item = store.get_memory("mixed")
            store.save_memory(item, item["revision"])
            visible(key == "c")
        store = Store(self.path)
        visible(True)
        store.put_raw(raw("a", "browser", "local_only"), 1)
        visible(False)
        store.delete_raw("c", 2)
        visible(False)
        self.assertEqual(store.list_memory(), [])
        self.assertEqual([r["id"] for r in store.list_raw(agent=True)], ["b"])

    def test_existing_mixed_and_tombstoned_evidence_is_hidden_on_upgrade(self):
        seed_legacy(self.path, 2)
        with sqlite3.connect(self.path) as conn:
            key = "public"
            encoded = json.dumps(raw(key, "voice", "shareable"))
            conn.execute("INSERT INTO raw_events VALUES(?,'voice','synthetic',?,?,?,'shareable',1,1,0)",
                         (key, key, encoded, encoded))
            conn.execute("UPDATE raw_events SET event=NULL,searchable='',tier='redacted' WHERE id='private-1'")
            for memory in ("mixed", "tombstoned", "ready", "review", "retired"):
                conn.execute("INSERT INTO memories VALUES(?,?,'body','body','manual',NULL,1,?,?,1,1)",
                             (memory, memory, memory == "review", memory == "retired"))
                conn.execute("INSERT INTO evidence VALUES(?,?,0)", (memory, key))
            conn.execute("INSERT INTO evidence VALUES('mixed','private-0',1)")
            conn.execute("INSERT INTO evidence VALUES('tombstoned','private-1',1)")
        store = Store(self.path)
        self.assertEqual([m["id"] for m in store.list_memory(agent=True)], ["ready"])
        for item in ("private-0", "private-1", "mixed", "tombstoned", "review", "retired"):
            with self.assertRaises(StoreError) as error:
                store.get_memory(item, agent=True)
            self.assertEqual(error.exception.status, 404)
