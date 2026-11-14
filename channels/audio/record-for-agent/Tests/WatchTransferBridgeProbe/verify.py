#!/usr/bin/env python3
"""Execute the production Watch transfer bridge against controlled WCSession state.

The platform import is removed and the runtime observer singleton is redirected
to a temporary-root instance. The real RecordingCore and bridge otherwise operate
on synthetic files in an isolated temp directory;
no device, real recording, app container, microphone, or network is accessed.
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
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--reuse-core-build", type=Path,
                        help="Reuse a previously evidenced, matching RecordingCore module without compiling Core.")
    options = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("This probe requires macOS and the Swift SDK.")
    run = Path(tempfile.mkdtemp(prefix="wristrecord-watch-transfer-bridge-probe-")).resolve()
    core = sorted((ROOT / "Sources/RecordingCore").glob("*.swift"))
    bridge = ROOT / "Watch/WatchTransferBridge.swift"
    app = ROOT / "Watch/WristRecordWatchApp.swift"
    model = ROOT / "Watch/WatchRecorderModel.swift"
    audio_writer = ROOT / "Watch/AudioSegmentWriter.swift"
    inputs = [bridge, app, model, audio_writer, HERE / "Harness.swift", Path(__file__).resolve(), *core]
    before = hashes(inputs)
    model_source = model.read_text()
    def model_function(name, next_anchor):
        return model_source.split(name, 1)[1].split(next_anchor, 1)[0]
    setup = model_function("private func prepareTransferRuntimeIfNeeded() -> Bool {", "private func prepareForegroundRuntimeIfNeeded()")
    model_checks = {
        "headless_setup_disables_transaction_recovery": "recoverTransactionsOnInitialization: false" in setup,
        "headless_setup_enables_power_sampling": "isBatteryMonitoringEnabled = true" in setup and "powerStateProvider:" in setup,
        "headless_setup_never_creates_audio_writer": "AudioSegmentWriter(" not in setup and "writer.load()" not in setup,
        "storage_failure_requests_bounded_system_recovery": "requestStorageRecoveryRefreshIfNeeded()" in setup,
        "wc_task_retries_lightweight_setup": "prepareTransferRuntimeIfNeeded()" in model_function(
            "func performBackgroundConnectivityTask(id:", "func expireBackgroundConnectivityTask"),
        "scheduled_task_retries_lightweight_setup": "prepareTransferRuntimeIfNeeded()" in model_function(
            "func performBackgroundRefreshTask(id:", "func becameActive()"),
        "foreground_retries_setup_before_writer": model_function("func becameActive() {", "func becameInactive()").find(
            "prepareTransferRuntimeIfNeeded()") < model_function("func becameActive() {", "func becameInactive()").find(
            "prepareForegroundRuntimeIfNeeded()"),
        "foreground_requests_metadata_revalidation": "bridge?.observeDiagnosticEvidence()" in model_function(
            "func becameActive() {", "func becameInactive()"),
        "maintenance_context_uses_real_scene_and_running_engine": "foreground: isForeground, liveCapture: liveCapture" in model_function(
            "private func updateTransferMaintenanceAvailability() {", "private var integrityCaptureActive")
            and "wantsRecording && engine?.isRunning == true" in model_function(
                "private func updateTransferMaintenanceAvailability() {", "private var integrityCaptureActive"),
        "refresh_reports_actual_api_start_and_error_identity": "bridge?.backgroundRefreshSchedulingStarted(preferredDate: preferredDate)" in setup
            and "errorDomain: value?.domain, errorCode: value?.code" in setup,
        "real_background_edge_forwards_to_bridge": "bridge?.enteredBackground()" in model_function(
            "func enteredBackground() {", "private func receiveSyncFeedback"),
    }
    if not all(model_checks.values()):
        raise SystemExit("Model runtime retry wiring failed: " + str(model_checks))
    source = bridge.read_text()
    if source.count("import WatchConnectivity\n") != 1:
        raise SystemExit("Expected one platform import; refusing any other source transformation.")
    prepared = run / "WatchTransferBridge.swift"
    prepared.write_text(source.replace("import WatchConnectivity\n", "").replace(
        "WatchRuntimeDiagnostics.shared", "ProbeRuntimeDiagnostics.shared"))
    app_source = app.read_text()
    delegate_start = "@MainActor\nfinal class WatchApplicationDelegate:"
    delegate_end = "\nprivate struct WatchWaveformView:"
    if app_source.count(delegate_start) != 1 or app_source.count(delegate_end) != 1:
        raise SystemExit("Expected unique application delegate boundaries; refusing extraction.")
    prepared_delegate = run / "WatchApplicationDelegate.swift"
    prepared_delegate.write_text("import Foundation\nimport RecordingCore\n" + app_source[
        app_source.index(delegate_start):app_source.index(delegate_end)].replace(
            "WatchRuntimeDiagnostics.shared", "ProbeRuntimeDiagnostics.shared"))
    if "WatchRuntimeDiagnostics.shared" in prepared.read_text() or "WatchRuntimeDiagnostics.shared" in prepared_delegate.read_text():
        raise SystemExit("Production runtime observer singleton remained in a prepared probe source.")
    # Execute exact production ownership and lifecycle methods in a shell whose
    # only replacements are unavailable platform UI/audio dependencies.
    lifecycle_source = "private func updateTransferMaintenanceAvailability() {" + model_function(
        "private func updateTransferMaintenanceAvailability() {", "private var integrityCaptureActive")
    lifecycle_source += "func observeLifecycle(source:" + model_function(
        "func observeLifecycle(source:", "private func becameActive()")
    lifecycle_source += "func becameInactive() {" + model_function(
        "func becameInactive() {", "private func receiveSyncFeedback")
    lifecycle_source = lifecycle_source.replace("WatchRuntimeDiagnostics.shared", "ProbeRuntimeDiagnostics.shared")
    def model_block(start, end):
        if model_source.count(start) != 1 or model_source.count(end) != 1:
            raise SystemExit("Expected unique cold-start source boundaries; refusing extraction.")
        return start + model_source.split(start, 1)[1].split(end, 1)[0]
    # This second model shell executes the real cold-start effects, rather than
    # the counting-only foreground stub retained by the lifecycle/bridge cases.
    cold_start_source = model_block("    init() {", "    /// A pre-first-unlock launch")
    cold_start_source += model_block("    @discardableResult\n    private func prepareTransferRuntimeIfNeeded()",
                                    "    private func updateTransferMaintenanceAvailability()")
    cold_start_source += model_block("    private func updateTransferMaintenanceAvailability() {",
                                    "    private var integrityCaptureActive:")
    cold_start_source += model_block("    func observeLifecycle(source:", "    private func receiveSyncFeedback(")
    cold_start_source += model_block("    private func receive(_ status:", "    private func observeAudioSession()")
    cold_start_source += model_block("    var pendingCountText: String {", "    var canEnd: Bool {")
    replacements = {
        "RecordingRepository.defaultRoot()": "ProbeColdStartEnvironment.repositoryRoot",
        "AudioSegmentWriter(repository:": "ProbeColdAudioWriter(repository:",
        "WatchIntegrityAuditCoordinator(sourceRoot:": "ProbeColdIntegrityAudit(sourceRoot:",
    }
    for original, replacement in replacements.items():
        if cold_start_source.count(original) != 1:
            raise SystemExit("Unexpected cold-start adapter boundary; refusing transformation.")
        cold_start_source = cold_start_source.replace(original, replacement)
    cold_start_source = cold_start_source.replace("WatchRuntimeDiagnostics.shared", "ProbeRuntimeDiagnostics.shared").replace(
        "WatchStartupDiagnostics.shared", "ProbeColdStartupDiagnostics.shared")
    writer_source = audio_writer.read_text()
    status_start = "struct WatchRecordingStatus:"
    status_end = "/// Owns all file handles"
    if writer_source.count(status_start) != 1 or writer_source.count(status_end) != 1:
        raise SystemExit("Expected unique writer status boundaries; refusing extraction.")
    writer_status_source = status_start + writer_source.split(status_start, 1)[1].split(status_end, 1)[0]
    harness_source = (HERE / "Harness.swift").read_text()
    lifecycle_marker = "// PRODUCTION_MODEL_LIFECYCLE_METHODS"
    if harness_source.count(lifecycle_marker) != 1:
        raise SystemExit("Expected unique production model lifecycle marker.")
    cold_start_marker = "// PRODUCTION_MODEL_COLD_START_METHODS"
    writer_status_marker = "// PRODUCTION_WRITER_STATUS_TYPE"
    if harness_source.count(cold_start_marker) != 1 or harness_source.count(writer_status_marker) != 1:
        raise SystemExit("Expected unique cold-start/status source markers.")
    prepared_harness = run / "Harness.swift"
    prepared_harness.write_text(harness_source.replace(lifecycle_marker, lifecycle_source).replace(
        cold_start_marker, cold_start_source).replace(writer_status_marker, writer_status_source))
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    target = ["-target", platform.machine() + "-apple-macosx15.0", "-sdk", sdk, "-swift-version", "5",
              "-module-cache-path", str(run / "module-cache")]
    reused_core = None
    core_build = run
    if options.reuse_core_build:
        core_build = options.reuse_core_build.resolve()
        prior = json.loads((core_build / "evidence.json").read_text())
        expected = prior["inputSHA256After"]
        actual = hashes(core)
        if not all(expected.get(path) == digest for path, digest in actual.items()):
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
    commands.append(
        [compiler, "-parse-as-library", "-module-name", "WatchTransferBridgeProbe", *target,
         "-I", str(core_build), "-L", str(core_build), "-lRecordingCore", str(prepared), str(prepared_delegate), str(prepared_harness),
         "-o", str(run / "probe")],
    )
    if not options.build_only:
        commands.append([str(run / "probe"), str(run / "report.json"), str(run / "fixtures")])
    steps = []
    for index, command in enumerate(commands):
        process = subprocess.run(command, capture_output=True, text=True, cwd=run, timeout=180)
        log = run / ("step-%d.log" % index)
        log.write_text(process.stdout + process.stderr)
        steps.append({"index": index, "exitCode": process.returncode, "log": str(log)})
        if process.returncode:
            break
    after = hashes(inputs)
    stable = before == after
    report_path = run / "report.json"
    report = json.loads(report_path.read_text()) if report_path.exists() else {
        "status": "built" if options.build_only and steps[-1]["exitCode"] == 0 else "build_failed",
        "caseCount": 0, "assertionCount": 0,
        "failures": [] if options.build_only and steps[-1]["exitCode"] == 0 else ["See " + steps[-1]["log"]],
    }
    if not report_path.exists():
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    evidence = {
        "sourceStableDuringRun": stable, "inputSHA256Before": before, "inputSHA256After": after,
        "preparedBridgeSHA256": hashlib.sha256(prepared.read_bytes()).hexdigest(),
        "preparedApplicationDelegateSHA256": hashlib.sha256(prepared_delegate.read_bytes()).hexdigest(),
        "preparedHarnessSHA256": hashlib.sha256(prepared_harness.read_bytes()).hexdigest(),
        "extractedModelLifecycleSHA256": hashlib.sha256(lifecycle_source.encode()).hexdigest(),
        "extractedModelColdStartSHA256": hashlib.sha256(cold_start_source.encode()).hexdigest(),
        "extractedWriterStatusSHA256": hashlib.sha256(writer_status_source.encode()).hexdigest(),
        "transformations": ["Remove import WatchConnectivity and redirect WatchRuntimeDiagnostics.shared to a synthetic temporary-root instance",
                            "Extract WatchApplicationDelegate between unique source anchors; add Foundation and RecordingCore imports and redirect diagnostic singleton to synthetic root",
                            "Extract exact model lifecycle dispatcher, updateTransferMaintenanceAvailability, becameInactive, relinquishForegroundOwnership and enteredBackground methods into synthetic UI/audio dependency shell; foreground activation effects use an explicit synthetic shell",
                            "Separately extract exact model init, transfer setup/recovery refresh, foreground writer setup, lifecycle effects and writer status receiver; bind defaultRoot to synthetic disk and replace only audio, location, WatchKit, startup logging and integrity-mailbox adapters. RecordingRepository and WatchTransferBridge remain production implementations",
                            "Extract the unchanged production WatchRecordingStatus value type; synthetic writer callbacks exercise the exact model receiver and pending-count display without microphone input"],
        "commands": commands, "steps": steps, "report": str(report_path),
        "reusedCoreBuild": reused_core,
        "modelRuntimeRetryWiring": model_checks,
        "scope": "Actual WatchTransferBridge, unchanged application delegate and complete RecordingCore with controlled WCSession/WatchKit task shells; synthetic disk data only. Exact model cold-start/foreground effects and first status receiver also execute, with explicit synthetic audio/location/mailbox adapters. Does not prove SwiftUI construction, actual microphone/tail recovery, watchOS scheduling, queue removal, Bluetooth delivery, lock-screen execution, or live-device recovery.",
    }
    evidence_path = run / "evidence.json"
    evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")
    summary = {"status": report["status"] if stable else "source_changed_during_run",
               "caseCount": report["caseCount"], "assertionCount": report["assertionCount"],
               "sourceStableDuringRun": stable, "sourceSHA256": before, "report": str(report_path), "evidence": str(evidence_path), "steps": steps}
    (run / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    expected = "built" if options.build_only else "passed"
    return 0 if summary["status"] == expected and steps[-1]["exitCode"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
