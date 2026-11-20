"""End-to-end MCP SDK client against a real subprocess and authenticated local HTTP Hub."""
import asyncio
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest

from hub.agent import HubClient, HubError
from hub.server import HubHTTP
from hub.store import Store


class ClientBoundaryTests(unittest.TestCase):
    def test_transport_before_connecting(self):
        for url in ("http://hub.example", "https://name:token@hub.example", "https://hub.example/x?q=1"):
            with self.subTest(url=url), self.assertRaises(HubError):
                HubClient(url, "dummy")
        for url in ("http://127.0.0.1:8741", "http://[::1]:8741", "https://hub.example"):
            self.assertEqual(HubClient(url, "dummy").loopback, "hub.example" not in url)
        client = HubClient("https://never-connect.invalid", "dummy")
        with self.assertRaisesRegex(HubError, "local_only"):
            client.request("POST", "/api/raw", {"privacy": {"tier": "local_only"}})


@unittest.skipUnless(importlib.util.find_spec("mcp"), "requires the optional MCP SDK (install .[agent])")
class StdioTests(unittest.TestCase):
    def test_stdio_handshake_and_crud(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Store(Path(tmp) / "test.sqlite3")
            http = HubHTTP(("127.0.0.1", 0), store, "fixture-owner", "fixture-agent")
            worker = threading.Thread(target=http.serve_forever, kwargs={"poll_interval": 0.02})
            worker.start()
            try:
                asyncio.run(self.exercise(http.server_port, store))
            finally:
                http.shutdown()
                http.server_close()
                worker.join()

    async def exercise(self, port, store):
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client

        def raw(identifier, tier, body):
            return {"id": identifier, "kind": "copy", "source": "clipboard",
                    "t_start": 10, "t_end": 10, "t_observed": 11, "content": {"text": body},
                    "privacy": {"tier": tier}, "provenance": {"connector": "fixture", "source_id": identifier}}

        store.put_raw(raw("private", "local_only", "fixture private clipboard"))
        params = StdioServerParameters(command=sys.executable, args=["-m", "hub", "mcp"],
                                       env={"HUB_URL": f"http://127.0.0.1:{port}", "HUB_AGENT_TOKEN": "fixture-agent",
                                            "PYTHONPATH": str(Path(__file__).resolve().parents[1])})
        async with stdio_client(params) as (reader, writer), ClientSession(reader, writer) as client:
            handshake = await client.initialize()
            self.assertIn("most questions answer from Memory alone", handshake.instructions)
            self.assertIn("only for missing evidence", handshake.instructions)
            catalog = await client.list_tools()
            self.assertEqual({tool.name for tool in catalog.tools},
                             {f"{verb}_{kind}" for verb in ("search", "get", "create", "update", "delete")
                              for kind in ("raw", "memory")})
            self.assertTrue(next(tool for tool in catalog.tools if tool.name == "delete_raw").annotations.destructiveHint)

            async def call(name, **kwargs):
                result = await client.call_tool(name, kwargs)
                self.assertFalse(result.isError, result.content)
                return result.structuredContent or json.loads(result.content[0].text)

            self.assertEqual((await call("search_raw", q="fixture"))["items"], [])
            self.assertTrue((await client.call_tool("get_raw", {"id": "private"})).isError)
            event = raw("shared", "shareable", "Synthetic copied text")
            created = await call("create_raw", event=event)
            self.assertEqual(created["revision"], 1)
            self.assertEqual((await call("get_raw", id="shared"))["content"], event["content"])
            changed = await call("update_raw", id="shared", revision=1,
                                 event={**event, "content": {"text": "Synthetic corrected text"}})
            self.assertEqual(changed["revision"], 2)
            self.assertTrue((await client.call_tool("delete_raw", {"id": "shared", "revision": 1})).isError)
            m = await call("create_memory", title="Test", body="Synthetic conclusion", evidence_ids=["shared"])
            self.assertEqual((await call("search_memory", q="conclusion"))["items"][0]["id"], m["id"])
            self.assertEqual((await call("get_memory", id=m["id"]))["evidence_ids"], ["shared"])
            edited = await call("update_memory", id=m["id"], revision=m["revision"], title="Test",
                                body="Reviewed", evidence_ids=["shared"])
            await call("delete_memory", id=m["id"], revision=edited["revision"])
            await call("delete_raw", id="shared", revision=2)


if __name__ == "__main__":
    unittest.main()
