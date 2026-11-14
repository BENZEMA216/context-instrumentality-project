import base64
import json
import select
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SERVER = Path(__file__).with_name("clipcontext-mcp.py")
LATE = "2026-11-12T08:01:00+08:00"
EARLY = "2026-11-11T23:59:59.000Z"
PNG_DATA = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGP4kOMKRwzEcQCwohoRlDw0mwAAAABJRU5ErkJggg=="


class ClipContextProtocolTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.archive = Path(self.directory.name) / "clipboard.json"
        self.snapshot = {
            "schemaVersion": 1,
            "deviceID": "sample-device",
            "revision": 2,
            "updatedAt": LATE,
            "items": [
                {
                    "id": "earlier",
                    "application": "com.example.chat",
                    "firstCopiedAt": EARLY,
                    "lastCopiedAt": EARLY,
                    "numberOfCopies": 1,
                    "title": "Earlier clipboard item",
                    "contents": [{"type": "public.utf8-plain-text", "text": "给项目的反馈：请支持离线阅读"}],
                },
                {
                    "id": "later",
                    "application": "com.example.browser",
                    "firstCopiedAt": LATE,
                    "lastCopiedAt": LATE,
                    "numberOfCopies": 2,
                    "pin": "1",
                    "title": "Later clipboard item",
                    "contents": [
                        {"type": "public.url", "base64": base64.b64encode(b"https://example.org/mock").decode()},
                        {"type": "public.png", "base64": PNG_DATA},
                        {"type": "public.file-url", "text": "file:///Never-open-this.txt"},
                    ],
                },
            ],
        }
        self.write_snapshot()
        self.command = [sys.executable, str(SERVER), "--archive", str(self.archive)]

    def write_snapshot(self):
        self.archive.write_text(json.dumps(self.snapshot), encoding="utf-8")

    def rpc(self, *messages):
        body = "\n".join(json.dumps(message) for message in messages) + "\n"
        return self.rpc_lines(body)

    def rpc_lines(self, body):
        result = subprocess.run(self.command, input=body, text=True, capture_output=True, check=True, timeout=20)
        self.assertEqual(result.stderr, "")
        return [json.loads(line) for line in result.stdout.splitlines()]

    @staticmethod
    def request(method, **params):
        return {"jsonrpc": "2.0", "id": method, "method": method, "params": params}

    @staticmethod
    def tool_response_data(response):
        return json.loads(response["result"]["content"][0]["text"])

    def test_stdio_negotiation_lists_read_only_tools(self):
        responses = self.rpc(
            self.request("initialize", protocolVersion="2025-06-18"),
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            self.request("tools/list"),
            self.request("ping"),
        )
        self.assertEqual(len(responses), 3)
        self.assertEqual(responses[0]["result"]["protocolVersion"], "2025-06-18")
        tools = responses[1]["result"]["tools"]
        self.assertEqual({tool["name"] for tool in tools}, {"recent", "search", "get"})
        self.assertTrue(all(tool["annotations"]["readOnlyHint"] for tool in tools))
        self.assertEqual(responses[2]["result"], {})

    def test_recent_pagination_and_revision(self):
        latest, earlier, unchanged = self.rpc(
            self.request("tools/call", name="recent", arguments={"limit": 1}),
            self.request("tools/call", name="recent", arguments={"offset": 1}),
            self.request("tools/call", name="recent", arguments={"afterRevision": 2}),
        )
        latest = self.tool_response_data(latest)
        self.assertEqual(latest["nextOffset"], 1)
        self.assertEqual(latest["items"][0]["id"], "later")
        self.assertEqual(self.tool_response_data(earlier)["items"][0]["id"], "earlier")
        self.assertTrue(self.tool_response_data(unchanged)["unchanged"])
        self.assertNotIn(PNG_DATA, json.dumps(latest))

    def test_search_body_and_source_filters(self):
        search, recent = self.rpc(
            self.request("tools/call", name="search", arguments={"query": "离线阅读", "application": "com.example.chat"}),
            self.request("tools/call", name="recent", arguments={"since": "2026-11-12T00:00:00Z"}),
        )
        self.assertEqual([item["id"] for item in self.tool_response_data(search)["items"]], ["earlier"])
        self.assertEqual([item["id"] for item in self.tool_response_data(recent)["items"]], ["later"])

    def test_get_preserves_original_text_and_sends_image_only_on_request(self):
        plain, with_image = self.rpc(
            self.request("tools/call", name="get", arguments={"id": "later"}),
            self.request("tools/call", name="get", arguments={"id": "later", "includeImage": True}),
        )
        self.assertEqual(len(plain["result"]["content"]), 1)
        plain = self.tool_response_data(plain)
        parts = plain["item"]["contents"]
        self.assertEqual(parts[0]["text"], "https://example.org/mock")
        self.assertEqual(parts[2]["text"], "file:///Never-open-this.txt")
        self.assertNotIn(PNG_DATA, json.dumps(plain))
        self.assertEqual(with_image["result"]["content"][1]["mimeType"], "image/png")
        self.assertEqual(with_image["result"]["content"][1]["data"], PNG_DATA)

    @unittest.skipUnless(Path("/usr/bin/sips").is_file(), "TIFF preview requires macOS sips")
    def test_tiff_preview_uses_mac_conversion_on_request(self):
        png = self.archive.with_suffix(".png")
        tiff = self.archive.with_suffix(".tiff")
        png.write_bytes(base64.b64decode(PNG_DATA))
        subprocess.run(
            ["/usr/bin/sips", "-s", "format", "tiff", str(png), "--out", str(tiff)],
            capture_output=True, check=True,
        )
        original = base64.b64encode(tiff.read_bytes()).decode()
        self.snapshot["items"][1]["contents"][1] = {"type": "public.tiff", "base64": original}
        self.write_snapshot()
        response, = self.rpc(
            self.request("tools/call", name="get", arguments={"id": "later", "includeImage": True}),
        )
        image = response["result"]["content"][1]
        self.assertEqual(image["mimeType"], "image/png")
        self.assertTrue(base64.b64decode(image["data"]).startswith(b"\x89PNG"))
        self.assertEqual(json.loads(self.archive.read_text())["items"][1]["contents"][1]["base64"], original)

    def test_long_copy_can_be_paginated(self):
        self.snapshot["items"][0]["contents"][0]["text"] = "字" * 9000
        self.write_snapshot()
        first, second = self.rpc(
            self.request("tools/call", name="get", arguments={"id": "earlier"}),
            self.request("tools/call", name="get", arguments={"id": "earlier", "textOffset": 8000}),
        )
        first_part = self.tool_response_data(first)["item"]["contents"][0]
        second_part = self.tool_response_data(second)["item"]["contents"][0]
        self.assertEqual(first_part["nextTextOffset"], 8000)
        self.assertIsNone(second_part["nextTextOffset"])
        self.assertEqual(first_part["text"] + second_part["text"], "字" * 9000)

    def test_cli_can_read_synced_archive_from_explicit_path(self):
        result = subprocess.run(self.command + ["search", "离线阅读"], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)["items"][0]["id"], "earlier")
        self.assertEqual(result.stderr, "")

    def test_tool_cannot_choose_a_different_file_or_get_revoked_entry(self):
        unexpected, unavailable = self.rpc(
            self.request("tools/call", name="get", arguments={"id": "later", "path": "/etc/passwd"}),
            self.request("tools/call", name="get", arguments={"id": "revoked"}),
        )
        self.assertTrue(unexpected["result"]["isError"])
        self.assertTrue(unavailable["result"]["isError"])

    def test_missing_archive_is_a_tool_error(self):
        self.archive.unlink()
        reply, = self.rpc(self.request("tools/call", name="recent"))
        self.assertTrue(reply["result"]["isError"])
        self.assertIn("unavailable", reply["result"]["content"][0]["text"])

    def test_bad_rpc_frames_do_not_interrupt_valid_requests(self):
        ping = json.dumps(self.request("ping"))
        replies = self.rpc_lines(f'{{\n{{"jsonrpc":"1.0","id":"old","method":"ping"}}\n{ping}\n')
        self.assertEqual(len(replies), 3)
        self.assertEqual([reply["error"]["code"] for reply in replies[:2]], [-32700, -32600])
        self.assertEqual(replies[2], {"jsonrpc": "2.0", "id": "ping", "result": {}})

    def test_archive_is_validated_before_returning_any_entry(self):
        duplicate = self.snapshot["items"][0]
        self.snapshot["items"].append(duplicate)
        self.write_snapshot()
        reply, = self.rpc(self.request("tools/call", name="get", arguments={"id": "earlier"}))
        self.assertTrue(reply["result"]["isError"])
        self.assertIn("Invalid item", reply["result"]["content"][0]["text"])
        self.assertNotIn(duplicate["contents"][0]["text"], reply["result"]["content"][0]["text"])

        self.snapshot["schemaVersion"] = 2
        self.write_snapshot()
        reply, = self.rpc(self.request("tools/call", name="recent"))
        self.assertTrue(reply["result"]["isError"])
        self.assertIn("Unsupported ClipContext archive format", reply["result"]["content"][0]["text"])

    def test_read_arguments_enforce_types_and_timezone(self):
        for tool, arguments, error in [
            ("recent", {"limit": True}, "Invalid type"),
            ("recent", {"limit": 51}, "out of range"),
            ("recent", {"since": "2026-11-12T00:00:00"}, "timestamp with timezone"),
            ("search", {"query": "  "}, "non-empty"),
            ("get", {"id": "earlier", "textOffset": -1}, "out of range"),
        ]:
            with self.subTest(tool=tool, arguments=arguments):
                reply, = self.rpc(self.request("tools/call", name=tool, arguments=arguments))
                self.assertTrue(reply["result"]["isError"])
                self.assertIn(error, reply["result"]["content"][0]["text"])

    def test_running_mcp_process_reads_atomically_replaced_snapshot(self):
        with subprocess.Popen(
            self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        ) as server:
            def call(tool, **arguments):
                request = self.request("tools/call", name=tool, arguments=arguments)
                server.stdin.write(json.dumps(request) + "\n")
                server.stdin.flush()
                self.assertTrue(select.select([server.stdout], [], [], 10)[0], "MCP response timed out")
                return json.loads(server.stdout.readline())

            try:
                initial = self.tool_response_data(call("recent"))
                self.assertEqual(initial["revision"], 2)
                self.assertEqual({item["id"] for item in initial["items"]}, {"later", "earlier"})

                self.snapshot["revision"] = 3
                self.snapshot["items"] = [self.snapshot["items"][0]]
                replacement = self.archive.with_suffix(".replacement")
                replacement.write_text(json.dumps(self.snapshot), encoding="utf-8")
                replacement.replace(self.archive)

                refreshed = self.tool_response_data(call("recent", afterRevision=2))
                self.assertEqual(refreshed["revision"], 3)
                self.assertEqual([item["id"] for item in refreshed["items"]], ["earlier"])
                self.assertTrue(call("get", id="later")["result"]["isError"])
            finally:
                server.stdin.close()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
            self.assertEqual(server.returncode, 0, server.stderr.read())


if __name__ == "__main__":
    unittest.main()
