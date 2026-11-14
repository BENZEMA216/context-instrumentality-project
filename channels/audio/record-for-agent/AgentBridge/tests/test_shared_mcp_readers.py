"""Two real MCP stdio clients share an isolated synthetic library without consuming it.

No network listener, model, chat, ASR service, user configuration, or real recording
is used. Each server process receives an explicit temporary library path.
"""

import hashlib
import json
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import unittest

from test_bridge import segment, write_package
from test_transcripts import transcript_for, version2
import bridge
import library


class StdioReader:
    def __init__(self, destination, name):
        self.process = subprocess.Popen(
            [sys.executable, "-B", str(Path(bridge.__file__)), "serve", "--library", str(destination)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
        )
        self.next_id = 1
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            self.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                       "clientInfo": {"name": name, "version": "1"}})
            self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
            self.process.stdin.flush()
        except BaseException:
            self.close()
            raise

    def request(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": request_id,
                                            "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        if not self.selector.select(timeout=5):
            raise AssertionError("Isolated MCP reader did not reply within five seconds")
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError("Isolated MCP reader exited before replying")
        reply = json.loads(line)
        if reply.get("id") != request_id or "error" in reply:
            raise AssertionError("Unexpected MCP protocol reply: " + json.dumps(reply))
        return reply["result"]

    def call(self, name, arguments=None):
        result = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        if result.get("isError"):
            raise AssertionError("Synthetic MCP tool failed: " + json.dumps(result))
        return result["structuredContent"]

    def close(self):
        self.selector.close()
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        for stream in (self.process.stdout, self.process.stderr):
            if stream:
                stream.close()


class SharedMCPReaderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="record-for-agent-shared-readers-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.destination = self.root / "synthetic-library"
        self.first = self.add_recording(0)
        self.a = StdioReader(self.destination, "synthetic-agent-a")
        self.addCleanup(self.a.close)
        self.b = StdioReader(self.destination, "synthetic-agent-b")
        self.addCleanup(self.b.close)

    def add_recording(self, sequence):
        item, content = segment(sequence, seed=sequence + 1)
        item["transcript"] = transcript_for(item, "Synthetic shared recording number %d." % sequence)
        package = self.root / ("fixture-%d.zip" % sequence)
        write_package(package, [(item, content)], version2([(item, content)]))
        library.import_package(package, self.destination)
        return item

    def ids(self, reader):
        return {r["recordingID"] for r in reader.call("list_recordings")["recordings"]}

    def test_two_agents_read_same_recording_without_consuming_or_modifying_it(self):
        identifier = self.first["manifest"]["id"]
        asset = library.Library(self.destination).get_audio_asset({"recording_id": identifier})
        source = Path(asset["localPath"])
        original_digest = hashlib.sha256(source.read_bytes()).hexdigest()
        for reader in (self.a, self.b):
            self.assertEqual(self.ids(reader), {identifier})
            result = reader.call("get_transcript", {"recording_id": identifier})
            self.assertEqual(result["transcript"], self.first["transcript"])
            self.assertEqual(result["transcriptStatus"], "ready")
        self.assertEqual(self.ids(self.a), {identifier}, "Reader B must not consume Reader A's recording")
        self.assertEqual(self.ids(self.b), {identifier}, "Reader A must not consume Reader B's recording")
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), original_digest)
        self.assertEqual(len(list((self.destination / "objects").rglob("*.caf"))), 1)

    def test_both_live_readers_see_incremental_import_and_one_can_disconnect_independently(self):
        initial = self.first["manifest"]["id"]
        self.assertEqual(self.ids(self.a), {initial})
        self.assertEqual(self.ids(self.b), {initial})
        second = self.add_recording(1)
        identifiers = {initial, second["manifest"]["id"]}
        for reader in (self.a, self.b):
            self.assertEqual(self.ids(reader), identifiers, "Incremental imports must be visible without server restart")
            self.assertEqual(reader.call("get_transcript", {"recording_id": second["manifest"]["id"]})["transcript"],
                             second["transcript"])
        self.a.close()
        self.assertEqual(self.a.process.returncode, 0)
        third = self.add_recording(2)
        self.assertEqual(self.ids(self.b), identifiers | {third["manifest"]["id"]})
        self.assertIsNone(self.b.process.poll(), "Disconnecting A must not stop B")
        self.assertEqual(self.b.call("get_transcript", {"recording_id": initial})["transcript"], self.first["transcript"])


if __name__ == "__main__":
    unittest.main()
