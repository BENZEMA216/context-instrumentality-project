"""Pure local tests of the production paired-upgrade guard; no device commands."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[2] / "scripts/paired_upgrade_guard.py"
SPEC = importlib.util.spec_from_file_location("paired_upgrade_guard_under_test", SOURCE)
guard_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard_module)
Guard = guard_module.PairedUpgradeGuard
GuardError = guard_module.UpgradeGuardError


class PairedUpgradeGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="paired-upgrade-guard-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "journal"
        self.now = 100_000
        self.roles = {
            "phone": {"target": "synthetic-phone", "bundle": "synthetic.phone", "old_build": "67", "new_build": "68"},
            "watch": {"target": "synthetic-watch", "bundle": "synthetic.watch", "old_build": "67", "new_build": "68"},
        }
        self.kwargs = {"upgrade_id": "synthetic-upgrade", "binding_sha256": "a" * 64,
                       "roles": self.roles, "clock": lambda: self.now}
        self.guard = self.open_guard()

    def open_guard(self, **changes):
        kwargs = dict(self.kwargs, **changes)
        value = Guard(self.directory, **kwargs)
        self.addCleanup(value.close)
        return value

    def query(self, role, build="67"):
        return {"deviceIdentifier": self.roles[role]["target"], "apps": [
            {"bundleIdentifier": self.roles[role]["bundle"], "bundleVersion": build}]}

    def before_pair(self):
        for role in ("phone", "watch"):
            self.guard.record_before(role, self.query(role), observed_at_ms=self.now)

    def install(self, role="watch", guard=None, query=None, callback=None):
        return (guard or self.guard).install_once(role, self.query(role) if query is None else query,
                    observed_at_ms=self.now, install=callback or (lambda: {"nativeReceipt": "synthetic"}))

    def test_fresh_old_build_claims_durably_before_callback(self):
        self.before_pair()
        synced = []
        actual_fsync = os.fsync
        def record_fsync(fd):
            synced.append(fd)
            return actual_fsync(fd)
        def callback():
            self.assertGreaterEqual(len(synced), 2)
            raw = (self.directory / "install-watch.json").read_bytes()
            self.assertEqual(json.loads(raw)["kind"], "install_started")
            return {"receiptOnly": True}
        with mock.patch.object(guard_module.os, "fsync", side_effect=record_fsync):
            value = self.install(callback=callback)
        self.assertTrue(value["installIssued"])
        self.assertTrue(value["requiresIndependentReadback"])
        self.assertNotIn("verifiedNewBuild", value)
        self.assertEqual((self.directory / "install-watch.json").stat().st_mode & 0o777, 0o600)

    def test_already_new_build_skips_without_claim(self):
        self.before_pair()
        callback = mock.Mock()
        value = self.install(query=self.query("watch", "68"), callback=callback)
        self.assertEqual(value["action"], "already_new_readback")
        callback.assert_not_called()
        self.assertFalse((self.directory / "install-watch.json").exists())

    def test_missing_or_untrusted_query_cannot_become_a_fresh_install(self):
        self.before_pair()
        candidates = []
        x = self.query("watch"); x["apps"] = []; candidates.append(x)
        x = self.query("watch"); x["apps"] *= 2; candidates.append(x)
        x = self.query("watch"); x["apps"] = {}; candidates.append(x)
        x = self.query("watch"); x["apps"] = [None]; candidates.append(x)
        x = self.query("watch"); x["deviceIdentifier"] = "different-target"; candidates.append(x)
        x = self.query("watch"); x["apps"][0]["bundleIdentifier"] = "different.bundle"; candidates.append(x)
        x = self.query("watch", "unknown"); candidates.append(x)
        x = self.query("watch", True); candidates.append(x)
        x = self.query("watch"); x["error"] = {"code": "synthetic"}; candidates.append(x)
        x = self.query("watch"); x["errors"] = ["synthetic"]; candidates.append(x)
        x = self.query("watch"); x["outcome"] = "failure"; candidates.append(x)
        candidates.extend([None, [], {"apps": []}])
        for index, value in enumerate(candidates):
            with self.subTest(case=index):
                callback = mock.Mock()
                with self.assertRaises(GuardError):
                    self.install(query=value if value is not None else [], callback=callback)
                callback.assert_not_called()
                self.assertFalse((self.directory / "install-watch.json").exists())

    def test_after_empty_query_only_a_new_exact_readonly_observation_can_resume(self):
        self.before_pair()
        empty = self.query("watch"); empty["apps"] = []
        with self.assertRaisesRegex(GuardError, "existing_app_not_uniquely_visible"):
            self.install(query=empty)
        callback = mock.Mock(return_value={"receipt": "synthetic"})
        self.install(query=self.query("watch"), callback=callback)
        callback.assert_called_once_with()
        with self.assertRaisesRegex(GuardError, "prior_install_started_readback_only"):
            self.install(callback=callback)
        callback.assert_called_once_with()

    def test_each_pair_member_must_have_preexisting_old_build(self):
        self.guard.record_before("phone", self.query("phone"), observed_at_ms=self.now)
        callback = mock.Mock()
        with self.assertRaisesRegex(GuardError, "both_preexisting_apps_required"):
            self.install("phone", callback=callback)
        callback.assert_not_called()
        with self.assertRaisesRegex(GuardError, "preexisting_old_build_required"):
            self.guard.record_before("watch", self.query("watch", "68"), observed_at_ms=self.now)

    def test_before_observations_are_immutable_and_cannot_be_added_after_start(self):
        self.before_pair()
        before = (self.directory / "before-watch.json").read_bytes()
        self.now += 1
        self.guard.record_before("watch", self.query("watch"), observed_at_ms=self.now)
        self.assertEqual((self.directory / "before-watch.json").read_bytes(), before)
        self.install()
        (self.directory / "before-phone.json").unlink()
        with self.assertRaisesRegex(GuardError, "before_capture_after_install_started"):
            self.guard.record_before("phone", self.query("phone"), observed_at_ms=self.now)

    def test_stale_future_and_noninteger_observations_stop(self):
        self.before_pair()
        for observed in (self.now - 60_001, self.now + 1, True, "100000"):
            with self.subTest(observed=observed), self.assertRaisesRegex(GuardError, "fresh_native_observation_required"):
                self.guard.install_once("watch", self.query("watch"), observed_at_ms=observed, install=lambda: self.fail("native"))

    def test_callback_exception_remains_claimed_across_another_entry_point(self):
        self.before_pair()
        callback = mock.Mock(side_effect=RuntimeError("synthetic installer failure"))
        with self.assertRaises(RuntimeError):
            self.install(callback=callback)
        marker = (self.directory / "install-watch.json").read_bytes()
        second = self.open_guard()
        with self.assertRaisesRegex(GuardError, "prior_install_started_readback_only"):
            self.install(guard=second, callback=callback)
        callback.assert_called_once_with()
        self.assertEqual((self.directory / "install-watch.json").read_bytes(), marker)

    def test_interruption_does_not_release_claim(self):
        self.before_pair()
        callback = mock.Mock(side_effect=KeyboardInterrupt())
        with self.assertRaises(KeyboardInterrupt):
            self.install(callback=callback)
        second = self.open_guard()
        with self.assertRaises(GuardError):
            self.install(guard=second, callback=callback)
        callback.assert_called_once_with()

    def test_failed_readback_and_successful_readback_never_clear_claim(self):
        self.before_pair()
        self.install()
        marker = (self.directory / "install-watch.json").read_bytes()
        with self.assertRaisesRegex(GuardError, "new_build_not_verified"):
            self.guard.verify_installed("watch", self.query("watch"), observed_at_ms=self.now)
        result = self.guard.verify_installed("watch", self.query("watch", "68"), observed_at_ms=self.now)
        self.assertTrue(result["priorInvocationRecorded"])
        self.assertFalse(result["dataContainerPreservedProven"])
        self.assertEqual((self.directory / "install-watch.json").read_bytes(), marker)
        callback = mock.Mock()
        self.install(query=self.query("watch", "68"), callback=callback)
        callback.assert_not_called()
        with self.assertRaises(GuardError):
            self.install(callback=callback)

    def test_both_roles_can_each_issue_only_one_install(self):
        self.before_pair()
        calls = []
        for role in ("phone", "watch"):
            self.install(role, callback=lambda r=role: calls.append(r))
            with self.assertRaises(GuardError):
                self.install(role, callback=lambda r=role: calls.append(r))
        self.assertEqual(calls, ["phone", "watch"])

    def test_two_independent_entry_points_racing_issue_one_callback(self):
        self.before_pair()
        other = self.open_guard()
        barrier = threading.Barrier(2)
        lock = threading.Lock()
        calls, successes, failures = [], [], []
        def native():
            with lock:
                calls.append("native")
        def attempt(guard):
            barrier.wait(timeout=5)
            try:
                value = self.install(guard=guard, callback=native)
                with lock: successes.append(value)
            except (GuardError, OSError) as error:
                with lock: failures.append(error)
        threads = [threading.Thread(target=attempt, args=(g,)) for g in (self.guard, other)]
        for thread in threads: thread.start()
        for thread in threads: thread.join(timeout=5)
        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.assertEqual((len(calls), len(successes), len(failures)), (1, 1, 1))

    def test_claim_fsync_failure_never_invokes_and_never_retries(self):
        self.before_pair()
        callback = mock.Mock()
        with mock.patch.object(guard_module.os, "fsync", side_effect=OSError("synthetic fsync failure")):
            with self.assertRaises(OSError):
                self.install(callback=callback)
        callback.assert_not_called()
        self.assertTrue((self.directory / "install-watch.json").exists())
        with self.assertRaises(GuardError):
            self.install(guard=self.open_guard(), callback=callback)
        callback.assert_not_called()

    def test_partial_write_leaves_a_failclosed_claim(self):
        self.before_pair()
        callback = mock.Mock()
        actual_write = os.write
        first = [True]
        def incomplete(fd, raw):
            if first[0]:
                first[0] = False
                return actual_write(fd, raw[:1])
            raise OSError("synthetic write failure")
        with mock.patch.object(guard_module.os, "write", side_effect=incomplete):
            with self.assertRaises(OSError):
                self.install(callback=callback)
        callback.assert_not_called()
        with self.assertRaisesRegex(GuardError, "journal_record_invalid"):
            self.install(guard=self.open_guard(), callback=callback)
        callback.assert_not_called()

    def test_plan_binding_change_stops_new_and_existing_entry_points(self):
        self.before_pair()
        with self.assertRaisesRegex(GuardError, "upgrade_plan_changed"):
            self.open_guard(binding_sha256="b" * 64)
        path = self.directory / "plan.json"
        value = json.loads(path.read_bytes()); value["upgradeID"] = "changed"
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(GuardError, "upgrade_plan_changed"):
            self.install(callback=lambda: self.fail("native"))

    def test_reused_plan_with_different_target_is_rejected(self):
        other = copy.deepcopy(self.roles); other["watch"]["target"] = "other-target"
        with self.assertRaisesRegex(GuardError, "upgrade_plan_changed"):
            self.open_guard(roles=other)

    def test_malformed_record_types_duplicates_and_unknown_fields_stop(self):
        self.before_pair()
        path = self.directory / "before-watch.json"
        original = path.read_bytes()
        changed = []
        x = json.loads(original); x["schemaVersion"] = True; changed.append(json.dumps(x).encode())
        x = json.loads(original); x["observedAtMS"] = -1; changed.append(json.dumps(x).encode())
        x = json.loads(original); x["extra"] = "unrecognized"; changed.append(json.dumps(x).encode())
        changed.append(original.rstrip()[:-1] + b',"role":"watch"}')
        for index, raw in enumerate(changed):
            with self.subTest(case=index):
                path.write_bytes(raw)
                with self.assertRaises(GuardError):
                    self.install(callback=lambda: self.fail("native"))
        path.write_bytes(original)

    def test_corrupt_symlink_and_hardlinked_claims_stop(self):
        self.before_pair()
        claim = self.directory / "install-watch.json"
        for kind in ("corrupt", "symlink", "hardlink"):
            with self.subTest(kind=kind):
                target = Path(self.temp.name) / (kind + ".json")
                target.write_text("{}"); target.chmod(0o600)
                if kind == "corrupt":
                    claim.write_text("{"); claim.chmod(0o600)
                elif kind == "symlink":
                    claim.symlink_to(target)
                else:
                    os.link(target, claim)
                with self.assertRaises((GuardError, OSError)):
                    self.install(callback=lambda: self.fail("native"))
                claim.unlink()

    def test_closed_guard_and_nonprivate_directory_stop(self):
        self.before_pair()
        self.guard.close()
        with self.assertRaisesRegex(GuardError, "journal_closed"):
            self.install(callback=lambda: self.fail("native"))
        self.directory.chmod(0o755)
        with self.assertRaisesRegex(GuardError, "private_journal_directory_required"):
            self.open_guard()
        self.directory.chmod(0o700)


if __name__ == "__main__":
    unittest.main()
