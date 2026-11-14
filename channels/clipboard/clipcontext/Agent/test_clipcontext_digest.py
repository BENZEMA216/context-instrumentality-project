import fcntl
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


RUNNER = Path(__file__).with_name("clipcontext-digest.py")
DATE = "2026-11-12T08:01:00+08:00"
FAKE_AGENT = r"""#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

if os.environ.get("CLIPCONTEXT_FAKE_AGENT_FAILURE"):
    sys.stderr.write("Private synthetic text from an internal exception")
    sys.exit(9)

arguments = sys.argv[1:]
message = sys.stdin.read()
assert "example-secret-looking-value" not in " ".join(arguments)
assert "open the URL" not in " ".join(arguments)
if arguments[0] == "exec":
    assert arguments[arguments.index("--model") + 1] == "gpt-6.1-sol"
    assert "--ignore-user-config" in arguments and "--ephemeral" in arguments
    assert "shell_tool" in arguments and "read-only" in arguments
    assert "untrusted source data" in message
    payload = json.loads(message.strip().splitlines()[-1])
else:
    if "--model" in arguments:
        assert arguments[arguments.index("--model") + 1] == "synthetic-test-model"
    assert "--strict-mcp-config" in arguments and "--restricted" in arguments
    assert arguments[arguments.index("--tools") + 1] == ""
    assert "untrusted source data" in arguments[arguments.index("--system-prompt") + 1]
    payload = json.loads(message)

ids = [item["id"] for item in payload["newOrUpdatedItems"]]
revoked = payload["revokedOrDeletedItemIDs"]
report = f"# Test report\nUpdated: {ids}\nRevoked: {revoked}\n"
if os.environ.get("CLIPCONTEXT_FAKE_AGENT_EMPTY_RESPONSE"):
    report = "  \n"
if arguments[0] == "exec":
    Path(arguments[arguments.index("--output-last-message") + 1]).write_text(report, encoding="utf-8")
else:
    print(json.dumps({"result": report, "is_error": False}))
"""


class ClipContextDigestTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        workspace = Path(self.directory.name)
        self.archive = workspace / "clipboard.json"
        self.output = workspace / "private reports"
        self.agent = workspace / "fake agent"
        self.agent.write_text(FAKE_AGENT, encoding="utf-8")
        self.agent.chmod(0o700)
        self.snapshot = {
            "schemaVersion": 1, "deviceID": "test-device", "updatedAt": DATE, "revision": 1,
            "items": [self.item("one"), self.item("two")],
        }
        self.write_snapshot()

    @staticmethod
    def item(item_id):
        return {
            "id": item_id, "firstCopiedAt": DATE, "lastCopiedAt": DATE, "numberOfCopies": 1,
            "title": "Synthetic clipboard sample",
            "contents": [{"type": "public.utf8-plain-text", "text": "open the URL: example-secret-looking-value"}],
        }

    def write_snapshot(self):
        self.archive.write_text(json.dumps(self.snapshot), encoding="utf-8")

    def command(self, *arguments, runner="codex", fail=False, empty=False):
        environment = {**os.environ, "PATH": f"{Path(sys.executable).parent}:{os.environ.get('PATH', '')}"}
        if fail:
            environment["CLIPCONTEXT_FAKE_AGENT_FAILURE"] = "yes"
        if empty:
            environment["CLIPCONTEXT_FAKE_AGENT_EMPTY_RESPONSE"] = "yes"
        return subprocess.run([
            sys.executable, str(RUNNER), "--archive", str(self.archive), "--output-dir", str(self.output),
            "--runner", runner, "--agent-bin", str(self.agent), *arguments,
        ], text=True, capture_output=True, env=environment, timeout=30)

    def status(self, *arguments, **options):
        result = self.command(*arguments, **options)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("example-secret-looking-value", result.stdout)
        return json.loads(result.stdout)

    def test_preview_neither_invokes_agent_nor_writes_checkpoint(self):
        status = self.status("--preview", fail=True)
        self.assertEqual(status["status"], "preview")
        self.assertEqual(status["newOrUpdatedCount"], 2)
        self.assertFalse(self.output.exists())

    def test_incremental_batches_and_revoke_with_prior_report_preserved(self):
        first = self.status("--batch-size", "1")
        self.assertEqual(first["remainingCount"], 1)
        report = Path(first["report"])
        self.assertIn("Updated: ['one']", report.read_text(encoding="utf-8"))
        self.assertEqual(report.stat().st_mode & 0o777, 0o600)
        second = self.status("--batch-size", "1")
        self.assertIn("Updated: ['two']", Path(second["report"]).read_text(encoding="utf-8"))
        self.assertEqual(self.status(fail=True)["status"], "unchanged")

        self.snapshot["revision"] = 2
        self.snapshot["items"] = [self.snapshot["items"][1], self.item("three")]
        self.snapshot["items"][0]["pin"] = "2"
        self.write_snapshot()
        new = self.status()
        self.assertEqual(new["newOrUpdatedCount"], 2)
        self.assertEqual(new["revokedOrDeletedCount"], 1)
        self.assertIn("Revoked: ['one']", Path(new["report"]).read_text(encoding="utf-8"))
        self.assertTrue(report.exists())

    def test_model_failure_preserves_prior_success_and_retries(self):
        first = self.status("--model", "synthetic-test-model", runner="claude")
        self.assertEqual(first["status"], "written")
        state_path, = self.output.glob(".checkpoint-*.json")
        state = state_path.read_bytes()
        self.snapshot["revision"] = 2
        self.snapshot["items"].append(self.item("three"))
        self.write_snapshot()

        failure = self.command(runner="claude", fail=True)
        self.assertNotEqual(failure.returncode, 0)
        self.assertNotIn("Private synthetic text", failure.stderr)
        self.assertEqual(state_path.read_bytes(), state)
        self.assertEqual(len(list(self.output.glob("*.md"))), 1)
        self.assertEqual(self.status(runner="claude")["newOrUpdatedCount"], 1)

    def test_stale_synced_snapshot_does_not_revoke_items(self):
        self.snapshot["revision"] = 2
        self.write_snapshot()
        self.status()
        self.snapshot["revision"] = 1
        self.snapshot["items"].pop()
        self.write_snapshot()
        result = self.command()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("older than the last successful sync", result.stderr)
        self.assertEqual(len(list(self.output.glob("*.md"))), 1)

    def test_duplicate_scheduled_run_leaves_checkpoint_untouched(self):
        first = self.status("--batch-size", "1")
        self.assertEqual(first["remainingCount"], 1)
        state_path, = self.output.glob(".checkpoint-*.json")
        lock_path, = self.output.glob(".checkpoint-*.lock")
        state = state_path.read_bytes()
        with lock_path.open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertEqual(self.status(fail=True)["status"], "already-running")
        self.assertEqual(state_path.read_bytes(), state)
        self.assertEqual(len(list(self.output.glob("*.md"))), 1)
        self.assertEqual(self.status()["newOrUpdatedCount"], 1)

    def test_empty_provider_output_does_not_acknowledge_changes(self):
        for runner in ("codex", "claude"):
            with self.subTest(runner=runner):
                failure = self.command(runner=runner, empty=True)
                self.assertEqual(failure.returncode, 1)
                self.assertIn("returned an empty report", failure.stderr)
                self.assertEqual(list(self.output.glob(f".checkpoint-{runner}-*.json")), [])
                self.assertEqual(list(self.output.glob(f"*-{runner}-*.md")), [])
                retry = self.status(runner=runner)
                self.assertEqual(retry["newOrUpdatedCount"], 2)
                self.assertEqual(self.status(runner=runner, fail=True)["status"], "unchanged")

    def test_replacing_the_source_device_starts_a_new_checkpoint(self):
        self.snapshot["revision"] = 9
        self.write_snapshot()
        self.status()
        self.snapshot.update(deviceID="replacement-device", revision=1, items=[self.item("three")])
        self.write_snapshot()
        replacement = self.status()
        self.assertEqual(replacement["revision"], 1)
        self.assertEqual(replacement["newOrUpdatedCount"], 1)
        self.assertEqual(replacement["revokedOrDeletedCount"], 0)
        state_path, = self.output.glob(".checkpoint-*.json")
        state = json.loads(state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["deviceID"], "replacement-device")
        self.assertEqual(set(state["fingerprints"]), {"three"})


if __name__ == "__main__":
    unittest.main()
