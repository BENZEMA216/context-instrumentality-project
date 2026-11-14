"""Synthetic report/transport tests: never connect to a device or read recordings."""
import copy
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location("integrity_tool", Path(__file__).parents[2] / "scripts/verify-recording-integrity.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
BUNDLE = "dev.test.recorder.watchkitapp"


def host(mode="full", reuse=False, started=1_000_000, baseline=None):
    nonce = str(uuid.uuid4())
    identity = {"byteCount": 8}
    audio = {"relativePath": "segments/one.caf", "sourceKind": "sealed_audio", "expectedSHA256": "a" * 64,
             "observedSHA256": "a" * 64, "identity": identity, "expectedByteCount": 8,
             "verification": "historicalHashMetadataUnchanged" if reuse else "currentHash",
             "bytesHashed": 0 if reuse else 8, "hashObservedAt": started - 100 if reuse else started + 1}
    metadata = {"relativePath": "manifests/one.json", "sourceKind": "manifest", "observedSHA256": "b" * 64,
                "identity": {"byteCount": 4}, "verification": "currentHash", "bytesHashed": 4,
                "hashObservedAt": started + 2}
    audit = {"schemaVersion": 1, "nonce": nonce, "mode": mode, "libraryGeneration": "generation-A",
             "catalogDigest": "c" * 64, "isComplete": True, "passed": True, "fullContentVerified": mode == "full",
             "nonAtomicSnapshot": True, "issues": [], "entries": [audio, metadata],
             "currentHashCount": 1 if reuse else 2, "filesHashedThisCall": 1 if reuse else 2,
             "filesHashedInObservationWindow": 1 if reuse else 2,
             "historicalHashCount": 1 if reuse else 0, "bytesHashed": 4 if reuse else 12,
             "retainedAudioCount": 1, "recoveredOriginalCount": 0, "acknowledgedPrunedCount": 0,
             "expectedSourceCount": 1, "startedAt": started, "endedAt": started + 10}
    request = {"schemaVersion": 1, "requestID": nonce, "mode": mode}
    if baseline:
        request["expectedBaselineID"] = baseline
    report = {"schemaVersion": 1, "requestID": nonce, "mode": mode, "status": "complete", "appBundleID": BUNDLE,
              "appBuild": "test", "audit": audit, "baselineID": "d" * 64, "usedBaselineID": baseline,
              "generatedAtUnixMS": started + 10, "criticalSettings": {"recordingRequested": "false"}}
    result = {"hostSchemaVersion": 1, "deviceArgument": "test-device", "appBundleID": BUNDLE, "request": request,
              "createdAtUnixMS": started, "receivedAtUnixMS": started + 11, "watchReport": report, "audioBytesCopied": 0}
    resign(result)
    return result


def resign(value):
    value["watchReportCanonicalSHA256"] = tool.digest(tool.canonical(value["watchReport"]))


def metadata_result(collector, source, size=128):
    leaf = source.rsplit("/", 1)[-1]
    return {"deviceIdentifier": collector.device, "domainIdentifier": collector.bundle,
            "files": [{"name": leaf, "relativePath": leaf, "metadata": {"size": size},
                       "resources": {"isDirectory": False, "isSymbolicLink": False, "isReadable": True}}]}


class FakeClock:
    def __init__(self, interrupt_wait=False):
        self.now = 0
        self.events = []
        self.interrupt_wait = interrupt_wait

    def monotonic(self):
        return self.now

    def time(self):
        return 1_000_000 + self.now

    def sleep(self, seconds):
        self.events.append(("sleep", self.now, seconds))
        if self.interrupt_wait:
            self.now += min(2, seconds)
            raise KeyboardInterrupt
        self.now += seconds


def fake_native(clock, status="failed", read_duration=0):
    """Synthetic native transport; no subprocess or device is accessed."""
    def native(collector, arguments):
        collector.sequence += 1
        if arguments[:3] == ["device", "process", "launch"]:
            clock.events.append(("launch", clock.now))
            return {}
        if arguments[:3] == ["device", "info", "files"]:
            leaf = arguments[arguments.index("--filter") + 1][len("Name = '"):-1]
            return metadata_result(collector, leaf)
        direction = arguments[2]
        clock.events.append((direction, clock.now))
        source = arguments[arguments.index("--source") + 1]
        destination = arguments[arguments.index("--destination") + 1]
        if direction == "from":
            clock.now += read_duration
            if status is None:
                return None
            ticket = tool.load(collector.directory / "request-ticket.json")
            request = ticket["request"]
            if status == "complete":
                report = host(request["mode"], started=ticket["createdAtUnixMS"],
                              baseline=request.get("expectedBaselineID"))["watchReport"]
                report["requestID"] = request["requestID"]
                report["audit"]["nonce"] = request["requestID"]
            else:
                report = {"schemaVersion": 1, "requestID": request["requestID"],
                          "mode": request["mode"], "appBundleID": collector.bundle, "status": status,
                          "errorCode": "synthetic_audit_failure"}
            tool.atomic(Path(destination), report)
        return {"deviceIdentifier": collector.device, "domain": "appDataContainer",
                "domainIdentifier": collector.bundle, "source": source, "destination": destination}
    return native


class IntegrityToolTests(unittest.TestCase):
    def reject(self, value, code):
        resign(value)
        with self.assertRaisesRegex(tool.IntegrityError, code):
            tool.validate_host(value)

    def test_quick_preserves_before_without_reclaiming_full(self):
        before = host()
        after = host("quick", True, 1_001_000, before["watchReport"]["baselineID"])
        result = tool.compare(before, after)
        self.assertEqual(result["status"], "preserved")
        self.assertFalse(result["fullContentVerified"])
        self.assertEqual(result["audioBytesCopied"], 0)
        self.assertFalse(result["backupRecoverableEstablishedByThisCheck"])

    def test_full_rejects_historical_hash(self):
        self.reject(host("full", True), "historical_hash_scope_invalid")

    def test_full_accepts_same_window_checkpoint_only(self):
        value = host()
        audit = value["watchReport"]["audit"]
        audit["entries"][0].update(verification="checkpointHashMetadataUnchanged", bytesHashed=0)
        audit.update(currentHashCount=1, filesHashedThisCall=1, bytesHashed=4)
        resign(value)
        tool.validate_host(value)
        audit["entries"][0]["hashObservedAt"] = audit["startedAt"] - 10
        self.reject(value, "hash_outside_observation_window")

    def test_old_nonce_and_wrong_mode_rejected(self):
        value = host()
        value["watchReport"]["requestID"] = str(uuid.uuid4())
        self.reject(value, "report_nonce_mismatch")
        value = host()
        value["watchReport"]["audit"]["mode"] = "quick"
        self.reject(value, "audit_mode_mismatch")

    def test_changed_bytes_not_hidden_by_same_size(self):
        value = host("quick")
        value["watchReport"]["audit"]["entries"][0]["observedSHA256"] = "e" * 64
        self.reject(value, "observed_expected_mismatch")

    def test_missing_coverage_and_duplicate_paths_rejected(self):
        value = host()
        value["watchReport"]["audit"]["entries"].pop()
        self.reject(value, "coverage_counts_invalid")
        value = host()
        value["watchReport"]["audit"]["entries"].append(copy.deepcopy(value["watchReport"]["audit"]["entries"][0]))
        self.reject(value, "catalog_member_invalid")

    def test_baseline_and_generation_are_bound(self):
        value = host(baseline="f" * 64)
        value["watchReport"]["usedBaselineID"] = None
        self.reject(value, "used_baseline_mismatch")
        value = host()
        value["expectedLibraryGeneration"] = "other-library"
        self.reject(value, "library_generation_changed")

    def test_expired_window_and_clock_replay_rejected(self):
        value = host()
        value["watchReport"]["audit"]["endedAt"] += 3_600_000
        self.reject(value, "observation_window_invalid")
        value = host()
        value["createdAtUnixMS"] += 10_000
        self.reject(value, "host_observation_time_invalid")

    def test_compare_rejects_same_observation_and_changed_settings(self):
        before = host()
        with self.assertRaisesRegex(tool.IntegrityError, "new_observation"):
            tool.compare(before, before)
        after = host("quick", True, 1_001_000, before["watchReport"]["baselineID"])
        after["watchReport"]["criticalSettings"]["recordingRequested"] = "true"
        resign(after)
        with self.assertRaisesRegex(tool.IntegrityError, "settings_changed"):
            tool.compare(before, after)

    def test_nonce_cannot_escape_report_directory(self):
        for value in ["../audio.caf", "A" * 36, str(uuid.uuid4()).upper()]:
            with self.assertRaises(tool.IntegrityError):
                tool.request_id(value)

    def test_native_scope_and_no_forced_termination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            collector = tool.Collector(root, "test-device", BUNDLE)
            called = []

            def native(arguments):
                called.append(arguments)
                if arguments[:3] == ["device", "process", "launch"]:
                    return {"deviceIdentifier": "test-device"}
                if arguments[:3] == ["device", "info", "files"]:
                    return metadata_result(collector, source)
                (root / "report.json").write_bytes(b"{}")
                return {"deviceIdentifier": "test-device", "domain": "appDataContainer", "domainIdentifier": BUNDLE,
                        "source": source, "destination": str(root / "report.json")}

            collector.native = native
            collector.launch()
            source = tool.REMOTE_ROOT + "/reports/" + str(uuid.uuid4()) + ".json"
            self.assertTrue(collector.copy("from", source, root / "report.json"))
            self.assertNotIn("--terminate-existing", str(called))
            self.assertNotIn(".caf", str(called))
            with self.assertRaisesRegex(tool.IntegrityError, "report_source_invalid"):
                collector.copy("from", source + "wrong", root / "report.json")

    def test_lock_is_exclusive_and_private(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            os.chmod(root, 0o700)
            lock = root / "operation.lock"
            with tool.device_lock(lock):
                with self.assertRaisesRegex(tool.IntegrityError, "operation_in_progress"):
                    with tool.device_lock(lock):
                        pass
            self.assertEqual(lock.stat().st_mode & 0o077, 0)

    def test_native_copy_to_file_urls_and_container_absolute_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            request = root / "request.json"
            request.write_bytes(b"{}")
            remote = tool.REMOTE_ROOT + "/request.json"
            collector = tool.Collector(root, "test-device", BUNDLE)
            collector.native = lambda args: {"deviceIdentifier": "test-device", "domain": "appDataContainer",
                "domainIdentifier": BUNDLE, "source": request.resolve().as_uri(),
                "destination": "file:///private/device-container/" + remote.replace(" ", "%20")}
            self.assertTrue(collector.copy("to", request, remote))
            with self.assertRaisesRegex(tool.IntegrityError, "destination_mismatch"):
                collector.copy("to", request, remote + "wrong")

    def test_capture_reuses_successful_baseline_and_copies_only_mailbox(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            os.chmod(root, 0o700)
            before = host()
            tool.atomic(root / "latest-report.json", before)
            args = SimpleNamespace(state_dir=root, mode="quick", baseline=None, new_baseline=False,
                                   device="test-device", bundle_id=BUNDLE, timeout=1, initial_wait=0)
            with patch.object(tool, "Collector") as collector, patch.object(tool, "poll", return_value={"status": "pending"}):
                collector.return_value.copy.return_value = True
                tool.capture(args)
                collector.return_value.launch.assert_called_once()
                call = collector.return_value.copy.call_args.args
                self.assertEqual(call[0], "to")
                self.assertEqual(call[2], tool.REMOTE_ROOT + "/request.json")
                request = tool.load(call[1])
                self.assertEqual(request["mode"], "quick")
                self.assertEqual(request["expectedBaselineID"], before["watchReport"]["baselineID"])
                self.assertNotIn("audio", request)
                self.assertEqual(call[1].stat().st_mode & 0o077, 0)

    def test_explicit_new_baseline_requires_full(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            os.chmod(root, 0o700)
            args = SimpleNamespace(state_dir=root, mode="quick", baseline=None, new_baseline=True,
                                   device="test-device", bundle_id=BUNDLE, timeout=1)
            with self.assertRaisesRegex(tool.IntegrityError, "requires_full"):
                tool.capture(args)

    def capture_with_clock(self, root, clock, extra=(), status="failed", read_duration=0):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(tool.Collector, "native", fake_native(clock, status, read_duration)), \
                patch.object(tool.time, "monotonic", clock.monotonic), \
                patch.object(tool.time, "time", clock.time), patch.object(tool.time, "sleep", clock.sleep), \
                redirect_stdout(stdout), redirect_stderr(stderr):
            code = tool.main(["capture", "--device", "test-device", "--bundle-id", BUNDLE,
                              "--state-dir", str(root), *extra])
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(len(stdout.getvalue().splitlines()), 1)
        return code, json.loads(stdout.getvalue())

    def test_capture_quiet_wait_precedes_report_read_and_records_separate_timing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            clock = FakeClock()
            code, result = self.capture_with_clock(root, clock, ["--initial-wait", "45", "--timeout", "60"])
            self.assertEqual(code, 2)  # A returned failure remains a failure after waiting.
            self.assertEqual(clock.events, [("launch", 0), ("to", 0), ("sleep", 0, 45), ("from", 45)])
            self.assertEqual(result["status"], "failed")
            timing = result["collectorTiming"]
            self.assertEqual(timing["initialWaitElapsedSeconds"], 45)
            self.assertEqual(timing["reportPollingElapsedSeconds"], 0)
            self.assertEqual(timing["reportReadAttempts"], 1)
            saved = tool.load(Path(result["report"]))
            self.assertEqual(saved["collectorTiming"], timing)
            self.assertEqual(tool.load(Path(result["report"]).parent / "collection-timing.json"), timing)
            self.assertNotIn("fullContentVerified", result)

    def test_fetch_quiet_wait_has_no_launch_or_delivery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ticket_path = root / "request-ticket.json"
            ticket = {"hostSchemaVersion": 1, "deviceArgument": "test-device", "appBundleID": BUNDLE,
                      "createdAtUnixMS": 1_000_000_000, "stateDirectory": str(root),
                      "request": {"schemaVersion": 1, "requestID": str(uuid.uuid4()), "mode": "quick"}}
            tool.atomic(ticket_path, ticket)
            clock = FakeClock()
            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(tool.Collector, "native", fake_native(clock)), \
                    patch.object(tool.time, "monotonic", clock.monotonic), \
                    patch.object(tool.time, "time", clock.time), patch.object(tool.time, "sleep", clock.sleep), \
                    redirect_stdout(stdout), redirect_stderr(stderr):
                code = tool.main(["fetch", "--request", str(ticket_path), "--initial-wait", "45", "--timeout", "60"])
            self.assertEqual(code, 2)
            self.assertEqual(stderr.getvalue(), "")
            self.assertEqual(clock.events, [("sleep", 0, 45), ("from", 45)])
            self.assertEqual(json.loads(stdout.getvalue())["collectorTiming"]["initialWaitElapsedSeconds"], 45)
            self.assertEqual(tool.load(ticket_path), ticket)

    def test_success_after_quiet_wait_preserves_watch_audit_window(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            code, result = self.capture_with_clock(root, FakeClock(),
                ["--initial-wait", "45", "--timeout", "60"], status="complete")
            self.assertEqual(code, 0)
            self.assertEqual(result["status"], "complete")
            saved = tool.validate_host(tool.load(root / "latest-report.json"))
            audit = saved["watchReport"]["audit"]
            self.assertEqual(audit["endedAt"] - audit["startedAt"], 10)
            self.assertEqual(saved["collectorTiming"]["initialWaitElapsedSeconds"], 45)
            self.assertEqual(saved, tool.load(Path(result["report"])))

    def test_poll_hash_binds_the_validated_bytes_without_a_later_unbounded_read(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            # None of the production report path may use Path.read_bytes, even
            # for a subsequent digest after validation has already succeeded.
            with patch.object(Path, "read_bytes", side_effect=AssertionError("unbounded reread")):
                code, result = self.capture_with_clock(root, FakeClock(), ["--timeout", "10"], status="complete")
            self.assertEqual(code, 0)
            saved = tool.load(Path(result["report"]))
            received = next(Path(result["report"]).parent.glob("received-*.json"))
            self.assertEqual(saved["watchReportSHA256"], tool.digest(tool.report_bytes(received)))

    def test_initial_wait_consumes_original_deadline_including_native_read_time(self):
        with tempfile.TemporaryDirectory() as temporary:
            clock = FakeClock()
            _, result = self.capture_with_clock(Path(temporary), clock,
                ["--initial-wait", "6", "--timeout", "10"], status=None, read_duration=2)
            self.assertEqual(result["status"], "pending")
            self.assertIsNone(result["lastWatchStatus"])
            self.assertEqual([event for event in clock.events if event[0] == "from"], [("from", 6)])
            self.assertEqual(clock.now, 10)
            self.assertEqual(result["collectorTiming"]["totalElapsedSeconds"], 10)
            self.assertEqual(result["collectorTiming"]["reportPollingElapsedSeconds"], 4)
            self.assertFalse((Path(result["request"]).parent / "report.json").exists())

    def test_initial_wait_may_use_entire_budget_without_polling_or_claiming_complete(self):
        with tempfile.TemporaryDirectory() as temporary:
            clock = FakeClock()
            _, result = self.capture_with_clock(Path(temporary), clock,
                ["--initial-wait", "10", "--timeout", "10"])
            self.assertEqual(result["status"], "pending")
            self.assertEqual(result["collectorTiming"]["reportReadAttempts"], 0)
            self.assertNotIn("from", [event[0] for event in clock.events])

    def test_default_initial_wait_reads_immediately(self):
        with tempfile.TemporaryDirectory() as temporary:
            clock = FakeClock()
            _, result = self.capture_with_clock(Path(temporary), clock, ["--timeout", "10"])
            self.assertEqual(clock.events, [("launch", 0), ("to", 0), ("from", 0)])
            self.assertEqual(result["collectorTiming"]["initialWaitRequestedSeconds"], 0)
            self.assertEqual(result["status"], "failed")

    def test_interrupted_wait_returns_one_json_and_preserves_delivered_request(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            clock = FakeClock(interrupt_wait=True)
            code, result = self.capture_with_clock(root, clock, ["--initial-wait", "6", "--timeout", "10"])
            self.assertEqual(code, 2)
            self.assertEqual(result["status"], "pending")
            self.assertTrue(result["interrupted"])
            self.assertEqual(result["collectorTiming"]["initialWaitElapsedSeconds"], 2)
            self.assertEqual(result["collectorTiming"]["reportReadAttempts"], 0)
            self.assertNotIn("from", [event[0] for event in clock.events])
            ticket = tool.load(Path(result["request"]))
            self.assertEqual(tool.load(Path(result["request"]).parent / "request.json"), ticket["request"])
            self.assertFalse((root / "latest-report.json").exists())

    def test_invalid_initial_wait_rejected_before_any_state_or_native_access(self):
        for value in ["-1", "11", "3601", "nan", "inf"]:
            for command in ["capture", "fetch"]:
                with self.subTest(value=value, command=command), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary) / "must-not-be-created"
                    arguments = ["capture", "--device", "test-device", "--bundle-id", BUNDLE, "--state-dir", str(root)] if command == "capture" \
                        else ["fetch", "--request", str(root / "missing-ticket.json")]
                    stdout, stderr = io.StringIO(), io.StringIO()
                    with patch.object(tool.Collector, "native") as native, redirect_stdout(stdout), redirect_stderr(stderr):
                        code = tool.main([*arguments, "--timeout", "10", "--initial-wait", value])
                    self.assertEqual(code, 1)
                    self.assertEqual(stdout.getvalue(), "")
                    self.assertEqual(json.loads(stderr.getvalue())["error"], "initial_wait_invalid")
                    self.assertFalse(root.exists())
                    native.assert_not_called()


class ReportBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="integrity-json-synthetic-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.path = self.root / "report.json"
        self.path.write_bytes(b'{"value":1}')

    def test_regular_json_and_exact_maximum_size_are_accepted(self):
        data = b'{"value":1}'
        with patch.object(tool, "MAX_REPORT_BYTES", len(data)):
            self.assertEqual(tool.report_bytes(self.path), data)
            self.assertEqual(tool.load(self.path), {"value": 1})

    def test_empty_or_oversize_file_is_rejected_before_read(self):
        for data in (b"", b" " * 65):
            self.path.write_bytes(data)
            with self.subTest(size=len(data)), patch.object(tool, "MAX_REPORT_BYTES", 64), \
                    patch.object(tool.os, "read", side_effect=AssertionError("must not read")):
                with self.assertRaisesRegex(tool.IntegrityError, "report_too_large"):
                    tool.load(self.path)

    def test_symlink_and_hardlink_aliases_are_rejected(self):
        alias = self.root / "alias.json"
        alias.symlink_to(self.path)
        with self.assertRaisesRegex(tool.IntegrityError, "report_file_invalid"):
            tool.load(alias)
        alias.unlink()
        os.link(self.path, alias)
        with self.assertRaisesRegex(tool.IntegrityError, "report_file_invalid"):
            tool.load(self.path)

    def test_fifo_and_directory_are_rejected_without_read_or_blocking(self):
        fifo = self.root / "fifo.json"
        os.mkfifo(fifo)
        with patch.object(tool.os, "read", side_effect=AssertionError("must not read")):
            for path in (fifo, self.root):
                with self.subTest(path=path.name), self.assertRaisesRegex(tool.IntegrityError, "report_file_invalid"):
                    tool.load(path)

    def test_symlink_swap_at_open_cannot_bypass_the_leaf_check(self):
        target = self.root / "other-synthetic.json"
        target.write_text('{"outside":true}')
        real_open = tool.os.open
        def swapping_open(path, *args, **kwargs):
            if Path(path) == self.path:
                self.path.unlink(); self.path.symlink_to(target)
            return real_open(path, *args, **kwargs)
        with patch.object(tool.os, "open", swapping_open):
            with self.assertRaisesRegex(tool.IntegrityError, "report_file_invalid"):
                tool.load(self.path)

    def test_growth_after_initial_stat_is_bounded_and_rejected(self):
        real_read = tool.os.read
        calls = []
        def growing_read(fd, maximum):
            if not calls:
                self.path.write_bytes(json.dumps({"padding": "x" * 100}).encode())
            calls.append(maximum)
            return real_read(fd, maximum)
        with patch.object(tool, "MAX_REPORT_BYTES", 64), patch.object(tool.os, "read", growing_read):
            with self.assertRaisesRegex(tool.IntegrityError, "report_too_large"):
                tool.load(self.path)
        self.assertTrue(calls)
        self.assertLessEqual(max(calls), 65)

    def test_same_size_write_during_read_is_not_a_stable_report(self):
        real_read = tool.os.read
        changed = False
        def rewriting_read(fd, maximum):
            nonlocal changed
            if not changed:
                previous = self.path.stat()
                self.path.write_bytes(b'{"value":2}')
                os.utime(self.path, ns=(previous.st_atime_ns, previous.st_mtime_ns + 1))
                changed = True
            return real_read(fd, maximum)
        with patch.object(tool.os, "read", rewriting_read):
            with self.assertRaisesRegex(tool.IntegrityError, "report_changed_during_read"):
                tool.load(self.path)

    def test_named_leaf_replacement_during_read_is_rejected(self):
        real_read = tool.os.read
        changed = False
        def replacing_read(fd, maximum):
            nonlocal changed
            if not changed:
                self.path.unlink(); self.path.write_bytes(b'{"value":1}')
                changed = True
            return real_read(fd, maximum)
        with patch.object(tool.os, "read", replacing_read):
            with self.assertRaisesRegex(tool.IntegrityError, "report_changed_during_read"):
                tool.load(self.path)

    def test_fragmented_reads_are_complete_and_bounded(self):
        real_read = tool.os.read
        with patch.object(tool.os, "read", lambda fd, maximum: real_read(fd, min(2, maximum))):
            self.assertEqual(tool.load(self.path), {"value": 1})

    def test_ambiguous_invalid_or_nonobject_json_is_rejected(self):
        cases = [(b'{"same":false,"same":true}', "report_duplicate_json_key"),
                 (b'{"value":NaN}', "report_nonfinite_json_number"),
                 (b'{"value":Infinity}', "report_nonfinite_json_number"),
                 (b"[]", "report_json_invalid"), (b"null", "report_json_invalid"),
                 (b"\xff", "report_json_invalid"),
                 (b'{"nested":' + b"[" * 2000 + b"0" + b"]" * 2000 + b"}", "report_json_invalid")]
        for data, code in cases:
            self.path.write_bytes(data)
            with self.subTest(code=code, size=len(data)), self.assertRaisesRegex(tool.IntegrityError, code):
                tool.load(self.path)


class RemoteReportBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="integrity-native-synthetic-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.collector = tool.Collector(self.root, "synthetic-device", BUNDLE)
        self.source = tool.REMOTE_ROOT + "/reports/" + str(uuid.uuid4()) + ".json"
        self.destination = self.root / "received.json"
        self.calls = []

    def native(self, arguments):
        self.calls.append(arguments)
        if arguments[:3] == ["device", "info", "files"]:
            return metadata_result(self.collector, self.source)
        self.destination.write_bytes(b"{}")
        return {"deviceIdentifier": self.collector.device, "domain": "appDataContainer", "domainIdentifier": BUNDLE,
                "source": self.source, "destination": str(self.destination)}

    def test_preflight_is_exact_nonrecursive_mailbox_metadata_then_copy(self):
        self.collector.native = self.native
        self.assertTrue(self.collector.copy("from", self.source, self.destination))
        query, copy_call = self.calls
        self.assertEqual(query, ["device", "info", "files", "--device", "synthetic-device",
            "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
            "--subdirectory", tool.REMOTE_ROOT + "/reports", "--no-recurse", "--filter",
            "Name = '" + self.source.rsplit("/", 1)[1] + "'"])
        self.assertEqual(copy_call[:3], ["device", "copy", "from"])

    def test_missing_metadata_keeps_request_pending_and_does_not_copy(self):
        def absent(arguments):
            self.calls.append(arguments)
            return {"deviceIdentifier": self.collector.device, "domainIdentifier": BUNDLE, "files": []}
        self.collector.native = absent
        self.assertFalse(self.collector.copy("from", self.source, self.destination))
        self.assertEqual(len(self.calls), 1)
        self.assertFalse(self.destination.exists())

    def test_oversize_remote_metadata_prevents_any_copy(self):
        self.collector.native = lambda args: metadata_result(self.collector, self.source, 65)
        with patch.object(tool, "MAX_REPORT_BYTES", 64):
            with self.assertRaisesRegex(tool.IntegrityError, "report_too_large"):
                self.collector.copy("from", self.source, self.destination)
        self.assertFalse(self.destination.exists())

    def test_wrong_scope_leaf_resource_and_size_metadata_prevent_copy(self):
        for mutate in (
            lambda v: v.update(deviceIdentifier="other-device"),
            lambda v: v.update(domainIdentifier="other.bundle"),
            lambda v: v.update(errors=[{"code": 1}]),
            lambda v: v["files"].append(copy.deepcopy(v["files"][0])),
            lambda v: v["files"][0].update(name="other.json"),
            lambda v: v["files"][0].update(relativePath="../other.json"),
            lambda v: v["files"][0]["resources"].update(isDirectory=True),
            lambda v: v["files"][0]["resources"].update(isSymbolicLink=True),
            lambda v: v["files"][0]["resources"].update(isReadable=False),
            lambda v: v["files"][0]["metadata"].update(size=True)):
            value = metadata_result(self.collector, self.source)
            mutate(value)
            self.collector.native = lambda args: value
            with self.subTest(mutate=mutate), self.assertRaises(tool.IntegrityError):
                self.collector.copy("from", self.source, self.destination)
            self.assertFalse(self.destination.exists())

    def test_copy_rechecks_local_bound_if_file_grows_after_metadata(self):
        def growing(arguments):
            if arguments[:3] == ["device", "info", "files"]:
                return metadata_result(self.collector, self.source, 2)
            self.destination.write_bytes(json.dumps({"padding": "x" * 100}).encode())
            return {"deviceIdentifier": self.collector.device, "domain": "appDataContainer", "domainIdentifier": BUNDLE,
                    "source": self.source, "destination": str(self.destination)}
        self.collector.native = growing
        with patch.object(tool, "MAX_REPORT_BYTES", 64):
            with self.assertRaisesRegex(tool.IntegrityError, "report_too_large"):
                self.collector.copy("from", self.source, self.destination)

    def test_only_nonce_named_json_report_is_eligible_for_metadata(self):
        for source in (tool.REMOTE_ROOT + "/reports/test.json", "Recordings/source.caf",
                       tool.REMOTE_ROOT + "/reports/../request.json", self.source + "/child"):
            with self.subTest(source=source), patch.object(self.collector, "native") as native:
                with self.assertRaises(tool.IntegrityError):
                    self.collector.copy("from", source, self.destination)
                native.assert_not_called()


if __name__ == "__main__":
    unittest.main()
