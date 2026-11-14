#!/usr/bin/env python3
"""Run production PhoneConnectivity with controlled platform adapters and real disk stores.

Only platform imports are removed from temporary PhoneConnectivity and
PhoneBackgroundSync copies. The unchanged production cancellation class is copied
from the UIKit file; the finite lease, WCSession, BG scheduler, PhoneStore handoff,
and audio decoder are controlled adapters.
No real recordings, devices, network traffic, or application containers are used.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def hashes(paths):
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reuse-core-build", type=Path)
    parser.add_argument("--case-prefix", help="Run only synthetic scenario names with this prefix.")
    options = parser.parse_args()
    if options.case_prefix and not all(c.isalnum() or c == "_" for c in options.case_prefix):
        raise SystemExit("Case prefix may contain only letters, digits and underscores.")
    if sys.platform != "darwin":
        raise SystemExit("This probe requires macOS and the Swift SDK.")
    run = Path(tempfile.mkdtemp(prefix="wristrecord-phone-background-sync-probe-")).resolve()
    core = sorted((ROOT / "Sources/RecordingCore").glob("*.swift"))
    connectivity = ROOT / "Phone/PhoneConnectivity.swift"
    status_diagnostics = ROOT / "Phone/PhoneStatusDiagnostics.swift"
    store = ROOT / "Phone/PhoneStore.swift"
    scheduler = ROOT / "Phone/PhoneBackgroundSync.swift"
    lease = ROOT / "Phone/PhoneBackgroundLease.swift"
    inputs = [connectivity, status_diagnostics, store, scheduler, lease, HERE / "Harness.swift", HERE / "SchedulerHarness.swift",
              HERE / "BacklogHarness.swift", HERE / "ReceiptQueueHarness.swift", HERE / "TransferProgressHarness.swift", HERE / "AutomaticControlHarness.swift", HERE / "PrivateControlProbeAccess.swift", HERE / "StatusOnlyHarness.swift", HERE / "StatusDiagnosticsHarness.swift", Path(__file__).resolve(), *core]
    before = hashes(inputs)
    prepared_harness = HERE / "Harness.swift"
    if options.case_prefix:
        harness_text = prepared_harness.read_text()
        boundary = """        do {
            let fixture = try Fixture(root: root.appendingPathComponent(name), fault: fault, backlogFault: backlogFault)"""
        if harness_text.count(boundary) != 1:
            raise SystemExit("Expected one synthetic scenario fixture boundary for filtering.")
        prepared_harness = run / "Harness.swift"
        filtered = harness_text.replace(boundary,
            "        guard name.hasPrefix(" + json.dumps(options.case_prefix) + ") else { return }\n" + boundary)
        standalone = '            let name = "no_ack_until_repository_receipt_synchronization_succeeds"\n'
        if filtered.count(standalone) != 1:
            raise SystemExit("Expected the unique standalone legacy synthetic scenario boundary.")
        filtered = filtered.replace(standalone, standalone +
            "            guard name.hasPrefix(" + json.dumps(options.case_prefix) + ") else { return }\n")
        prepared_harness.write_text(filtered)
    prepared = run / "PhoneConnectivity.swift"
    original = connectivity.read_text()
    if original.count("import WatchConnectivity\n") != 1:
        raise SystemExit("Expected one platform import; refusing any other source transformation.")
    access = (HERE / "PrivateControlProbeAccess.swift").read_text()
    prepared.write_text(original.replace("import WatchConnectivity\n", "") + "\n" + access)
    prepared_scheduler = run / "PhoneBackgroundSync.swift"
    scheduler_text = scheduler.read_text()
    if scheduler_text.count("import BackgroundTasks\n") != 1:
        raise SystemExit("Expected one BackgroundTasks import; refusing another scheduler transformation.")
    prepared_scheduler.write_text(scheduler_text.replace("import BackgroundTasks\n", ""))
    cancellation = run / "PhoneBackgroundCancellation.swift"
    lease_text = lease.read_text()
    delimiter = "/// Finite execution time"
    if delimiter not in lease_text or lease_text.count("import UIKit\n") != 1:
        raise SystemExit("Expected the isolated production cancellation class.")
    cancellation.write_text(lease_text.split(delimiter, 1)[0].replace("import UIKit\n", ""))
    store_text = store.read_text()
    status_start = "    func requestStatus(completion:"
    status_end = "    func reload() {"
    if store_text.count(status_start) != 1 or store_text.count(status_end) != 1:
        raise SystemExit("Expected unique status-only Store method boundaries.")
    prepared_status_store = run / "StatusStoreProbe.swift"
    prepared_status_store.write_text("""import Foundation
import RecordingCore
@MainActor final class StatusStoreProbe {
    var isRequestingStatus = false
    var statusFeedback: String?
    var statusFeedbackIsError = false
    var statusQueryIntentID: UUID?
    var statusRequestGeneration: UUID?
    var isAwaitingStatusRecovery = false
    var connection = PhoneConnectionState()
    private var statusRequestID: UUID?
    private var statusFeedbackTimeout: Task<Void, Never>?
    private var statusRecoveryConnectionAvailable = false
    private var statusRecoveryRetried = false
    private var statusSuccessfulRequestGeneration: UUID?
    private var connectivity: PhoneConnectivity?
    init(connectivity: PhoneConnectivity) {
        self.connectivity = connectivity
        connectivity.onStatusReachabilityChanged = { [weak self] available in
            Task { @MainActor in self?.statusConnectionAvailabilityChanged(available) }
        }
    }
""" + store_text[store_text.index(status_start):store_text.index(status_end)] + "}\n")
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    target = ["-target", platform.machine() + "-apple-macosx15.0", "-sdk", sdk, "-swift-version", "5",
              "-module-cache-path", str(run / "module-cache")]
    reused_core = None
    core_build = run
    if options.reuse_core_build:
        core_build = options.reuse_core_build.resolve()
        prior = json.loads((core_build / "evidence.json").read_text())
        actual = hashes(core)
        if not all(prior["inputSHA256After"].get(path) == digest for path, digest in actual.items()):
            raise SystemExit("RecordingCore inputs differ from the evidenced reusable module.")
        artifacts = [core_build / "RecordingCore.swiftmodule", core_build / "libRecordingCore.a"]
        if not all(path.is_file() for path in artifacts):
            raise SystemExit("Reusable RecordingCore build artifacts are missing.")
        reused_core = {"directory": str(core_build), "inputSHA256": actual,
                       "artifactSHA256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in artifacts}}
    commands = [] if reused_core else [
        [compiler, "-emit-module", "-emit-library", "-static", "-parse-as-library", "-module-name", "RecordingCore",
         "-emit-module-path", str(run / "RecordingCore.swiftmodule"), *target, *map(str, core),
         "-o", str(run / "libRecordingCore.a")],
    ]
    commands.extend([
        [compiler, "-parse-as-library", "-module-name", "PhoneBackgroundSyncProbe", *target,
         "-I", str(core_build), "-L", str(core_build), "-lRecordingCore", str(prepared), str(status_diagnostics), str(cancellation),
         str(prepared_scheduler), str(prepared_harness), str(HERE / "SchedulerHarness.swift"),
         str(prepared_status_store), str(HERE / "BacklogHarness.swift"), str(HERE / "ReceiptQueueHarness.swift"), str(HERE / "TransferProgressHarness.swift"), str(HERE / "StatusOnlyHarness.swift"),
         str(HERE / "StatusDiagnosticsHarness.swift"), str(HERE / "AutomaticControlHarness.swift"),
         "-o", str(run / "probe")],
        [str(run / "probe"), str(run / "report.json"), str(run / "fixtures")],
    ])
    steps = []
    for index, command in enumerate(commands):
        process = subprocess.run(command, capture_output=True, text=True, cwd=run, timeout=120)
        log = run / ("step-%d.log" % index)
        log.write_text(process.stdout + process.stderr)
        steps.append({"index": index, "exitCode": process.returncode, "log": str(log)})
        if process.returncode:
            break
    stable = before == hashes(inputs)
    report_path = run / "report.json"
    report = json.loads(report_path.read_text()) if report_path.exists() else {
        "status": "build_failed", "caseCount": 0, "assertionCount": 0, "failures": ["See " + steps[-1]["log"]]}
    if options.case_prefix and report["status"] == "passed" and report["caseCount"] == 0:
        report["status"] = "no_scenarios_selected"
        report["failures"] = ["No synthetic scenario matched the requested prefix."]
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    if not report_path.exists():
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    evidence = {
        "sourceStableDuringRun": stable, "inputSHA256Before": before, "inputSHA256After": hashes(inputs),
        "preparedConnectivitySHA256": hashlib.sha256(prepared.read_bytes()).hexdigest(),
        "preparedSchedulerSHA256": hashlib.sha256(prepared_scheduler.read_bytes()).hexdigest(),
        "preparedStatusStoreSHA256": hashlib.sha256(prepared_status_store.read_bytes()).hexdigest(),
        "casePrefix": options.case_prefix,
        "preparedHarnessSHA256": hashlib.sha256(prepared_harness.read_bytes()).hexdigest(),
        "transformations": ["Remove only import WatchConnectivity from temporary PhoneConnectivity.swift",
            "Append explicit test-only same-file private helper/observer accessors and in-memory maximum-width observer boundary seeding; production declarations remain unchanged",
                            "Remove only import BackgroundTasks from temporary PhoneBackgroundSync.swift",
                            "Extract unchanged PhoneBackgroundCancellation, excluding UIKit import and lease class",
                            "Extract unchanged PhoneStore requestStatus/cancelStatusRequest into a MainActor property shell"],
        "reusedCoreBuild": reused_core,
        "commands": commands, "steps": steps, "report": str(report_path),
        "scope": "Actual PhoneConnectivity, PhoneBackgroundSync and cancellation logic plus complete RecordingCore; controlled WCSession, UIKit lease, BGTaskScheduler, PhoneStore handoff and audio validator; synthetic bytes only. Does not prove OS lock-screen delivery or live microphone continuity.",
    }
    if options.case_prefix:
        evidence["transformations"].append("Insert scenario-name prefix guards only in temporary synthetic Harness run method and standalone legacy scenario")
    evidence_path = run / "evidence.json"
    evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")
    summary = {"status": report["status"] if stable else "source_changed_during_run",
               "caseCount": report["caseCount"], "assertionCount": report["assertionCount"],
               "sourceStableDuringRun": stable, "report": str(report_path), "evidence": str(evidence_path), "steps": steps}
    (run / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if summary["status"] == "passed" and steps[-1]["exitCode"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
