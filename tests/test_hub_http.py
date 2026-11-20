import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

from hub.server import HubHTTP, run_worker
from hub.store import Store


def sample(source_id):
    return {"source": "voice", "kind": "transcript_segment", "t_start": 1, "t_end": 8,
            "t_observed": 9, "actor": "self", "content": {"text": "决定使用合成日期筛选。"},
            "provenance": {"connector": "fixture", "source_id": source_id, "locator": "fixture://voice/1"},
            "privacy": {"tier": "shareable"}}


class HubTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.store = Store(Path(tmp.name) / "test.sqlite3")
        self.http = HubHTTP(("127.0.0.1", 0), self.store, "owner-fixture", "agent-fixture")
        self.url = f"http://127.0.0.1:{self.http.server_port}"
        thread = threading.Thread(target=self.http.serve_forever, kwargs={"poll_interval": 0.02})
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(self.http.server_close)
        self.addCleanup(self.http.shutdown)

    def call(self, path, method="GET", data=None, role="owner"):
        headers = {}
        if role:
            headers["Authorization"] = "Bearer " + role + "-fixture"
        if data is not None:
            headers["Content-Type"] = "application/json"
        payload = json.dumps(data).encode() if data is not None else None
        request = urllib.request.Request(self.url + path, method=method, data=payload, headers=headers)
        try:
            result = urllib.request.urlopen(request, timeout=3)
        except urllib.error.HTTPError as e:
            result = e
        with result:
            return result.status, json.load(result)

    def test_worker_and_revisioned_edit_delete(self):
        status, raw = self.call("/api/raw", "POST", sample("a"))
        self.assertEqual(status, 201)
        self.assertEqual(self.call("/api/raw", "POST", sample("a"))[1]["id"], raw["id"])
        stopped = threading.Event()
        worker = threading.Thread(target=run_worker, args=(self.store, .025, stopped))
        worker.start()
        self.addCleanup(worker.join)
        self.addCleanup(stopped.set)
        deadline = time.monotonic() + 3
        while not self.store.list_memory() and time.monotonic() < deadline:
            time.sleep(.015)
        memory = self.call("/api/memory", role="agent")[1]["items"][0]
        self.assertEqual(memory["evidence_ids"], [raw["id"]])
        self.assertEqual(self.call("/api/raw/" + raw["id"], role="agent")[1]["content"], raw["content"])
        self.assertEqual(self.call("/api/memory/" + memory["id"], "PUT",
                                   {**memory, "body": "人工复核摘记"}, "agent")[0], 200)
        self.assertEqual(self.call("/api/memory/" + memory["id"], "DELETE", {"revision": memory["revision"]})[0], 409)
        path = "/api/raw/" + raw["id"]
        raw["privacy"]["tier"] = "local_only"
        self.assertEqual(self.call(path, "PUT", raw)[0], 200)
        self.assertEqual(self.call("/api/memory", role="agent")[1], {"items": []})
        self.assertEqual(self.call(path, role="agent")[0], 404)
        self.assertEqual(self.call(path, "DELETE", {"revision": raw["revision"] + 1})[0], 200)
        self.assertEqual(self.call("/api/memory/" + memory["id"])[0], 404)

    def test_cloud_privacy_auth_and_validation(self):
        self.http.mode = "cloud"
        self.assertEqual(self.call("/health", role=None), (200, {"status": "ok", "mode": "cloud"}))
        self.assertEqual(self.call("/api/memory", role=None)[0], 401)
        self.assertEqual(self.call("/api/extract", "POST", {}, "agent")[0], 403)
        raw = sample("cloud")
        private = {**raw, "privacy": {"tier": "local_only"}}
        self.assertEqual(self.call("/api/raw", "POST", private)[0], 403)
        raw["unexpected"] = 1
        self.assertEqual(self.call("/api/raw", "POST", raw)[0], 400)
        del raw["unexpected"]
        self.assertEqual(self.call("/api/raw", "POST", raw)[0], 201)
        self.assertEqual(self.call("/api/raw?limit=-1")[0], 400)


if __name__ == "__main__":
    unittest.main()
