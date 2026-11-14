#!/usr/bin/env python3
"""Compile actual Drive transport/client with synthetic tokens and URLProtocol.

Uses a private module cache/build directory, never real OAuth, Google requests,
Keychain, media, cloud files, devices, background schedulers, or app state.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case-filter', default='')
    parser.add_argument('--reuse-core-build', type=Path,
                        help='Reuse only a prior exit0 Core compile with identical inputs/compiler/SDK/flags; Phone is rebuilt.')
    parser.add_argument('--compiler-plugin-no-sandbox', action='store_true',
                        help='Disable only Swift compiler plugin nested sandboxing when the enclosing task sandbox rejects sandbox_apply.')
    parser.add_argument('--legacy-readback-order-control', action='store_true',
                        help='Offline negative control: compile a private copy without the new ordinary-loop durable readback rotation')
    parser.add_argument('--legacy-migration-close-control', action='store_true',
                        help='Offline negative control: omit only the post-invalidation migration lifetime check in a private source copy')
    args = parser.parse_args()
    if args.legacy_migration_close_control and (args.legacy_readback_order_control or args.case_filter != 'REC-38 migration handoff during invalidation'):
        parser.error('Migration negative control must select only its invalidation interleaving regression')
    if args.legacy_readback_order_control and args.case_filter != 'ordinary pipeline completed head':
        parser.error('The negative control must select only the ordinary pipeline completed head regression')
    if sys.platform != 'darwin':
        raise SystemExit('macOS Swift/SDK required')
    run = Path(tempfile.mkdtemp(prefix='wristrecord-phone-google-drive-probe-')).resolve()
    core = sorted((ROOT / 'Sources/RecordingCore').glob('*.swift'))
    phone = [ROOT / 'Phone' / name for name in ('GoogleDriveHTTP.swift', 'GoogleDriveNetworkMonitor.swift', 'GoogleDriveFaultReports.swift', 'GoogleDriveClient.swift', 'GoogleDriveOAuth.swift', 'GoogleDriveSyncProgress.swift', 'GoogleDriveExecutionBudget.swift', 'GoogleDriveMetadataRecovery.swift', 'GoogleDriveBackgroundUploads.swift', 'BackgroundSessionRestorationGate.swift')]
    probes = [HERE / name for name in ('Harness.swift', 'TransportDiagnosticCases.swift', 'TransportHistoryCases.swift', 'TLSRecoveryCases.swift', 'FaultReportCases.swift', 'TransportFaultPresentationCases.swift', 'WorkerDiagnosticCases.swift', 'ProgressFirstCases.swift', 'DiscoveryFailureCases.swift')]
    probes.append(ROOT / 'Tests/PhoneGoogleDriveNetworkProbe/SessionInterleavingSupport.swift')
    library = ROOT / 'Phone' / 'GoogleDriveLibrary.swift'
    inputs = [*core, *phone, *probes, library, Path(__file__).resolve()]
    hashes = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    before = hashes()
    control = None
    if args.legacy_readback_order_control:
        original = ROOT / 'Phone/GoogleDriveBackgroundUploads.swift'
        source = original.read_text()
        needle = '            operations += 1\n            try rotateCompletedReadback(selected)\n'
        if source.count(needle) != 1:
            raise SystemExit('Negative-control production boundary changed')
        target = run / 'GoogleDriveBackgroundUploads-legacy-order.swift'
        target.write_text(source.replace(needle, '            operations += 1\n', 1))
        phone = [target if p == original else p for p in phone]
        control = {'mode': 'legacy_ordinary_readback_order', 'compiledPrivateCopy': str(target),
                   'copySHA256': hashlib.sha256(target.read_bytes()).hexdigest(),
                   'mutation': 'Omit only the ordinary-loop durable completed-readback rotation; production files untouched',
                   'expectedResult': 'failed_regression'}
    if args.legacy_migration_close_control:
        original = ROOT / 'Phone/GoogleDriveBackgroundUploads.swift'
        source = original.read_text()
        needle = '        await retiring.wait()\n        try checkOpen()\n'
        if source.count(needle) != 1:
            raise SystemExit('Migration lifetime control boundary changed')
        target = run / 'GoogleDriveBackgroundUploads-unsafe-migration.swift'
        target.write_text(source.replace(needle, '        await retiring.wait()\n', 1))
        phone = [target if p == original else p for p in phone]
        control = {'mode': 'legacy_migration_close', 'compiledPrivateCopy': str(target),
                   'copySHA256': hashlib.sha256(target.read_bytes()).hexdigest(),
                   'mutation': 'Omit post-invalidation lifetime check only; production files untouched',
                   'expectedResult': 'failed_regression'}
    # Compile the exact Foundation-only presentation/share models. The UIKit
    # coordinator stays in the real iOS build and owns no synthetic network.
    marker = 'struct GoogleDriveTransportFaultPresentation {'
    end_marker = '/// UIKit is observed only on MainActor.'
    model_source = marker + library.read_text().split(marker, 1)[1].split(end_marker, 1)[0]
    models = run / 'TransportFaultPresentation.swift'
    models.write_text('import Foundation\n' + model_source)
    # Execute schedule's actual pre-lease admission body, not a reimplementation.
    start, end = '    private func scheduledWorkAdmission()', '    private func schedule(isCancelled:'
    source = library.read_text()
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError('Production schedule admission boundary changed')
    admission = source[source.index(start):source.index(end)].replace('private func ', 'func ', 1)
    def actual_method(start, end):
        if source.count(start) != 1 or source.count(end) != 1:
            raise RuntimeError('Production schedule path boundary changed: ' + start)
        return source[source.index(start):source.index(end)].replace('private func ', 'func ', 1)
    foreground = actual_method('    func didBecomeActive()', '    func setAllowsCellularAccess(')
    path_opportunity = actual_method('    private func networkPathDidChange(', '    func transcriptDidSave(').replace('private func ', 'func ')
    recovery = actual_method('    private func recoverNetworkAtOpportunity(', '    private func recheckLegacyQuarantine(')
    scheduled_round = actual_method('    private func scheduleUnscoped(', '    private func advanceKnownItems(')
    migration = actual_method('    private func recheckLegacyQuarantine(', '    /// A bounded ledger turn precedes all cold enumeration.')
    commit = actual_method('    private func commitVerified(', '    /// Source admission contains no audio/')
    button_start = source.index('        canCheckNetworkRecovery = ')
    button_end = source.index('\n        allowsCellularAccess =', button_start)
    recovery_button = source[button_start:button_end].split(' = ', 1)[1]
    admission_file = run / 'ScheduleAdmission.swift'
    admission_file.write_text("""import Foundation
import RecordingCore
// Only the UIKit lease, local source lookup and persistence shell are synthetic.
// The actual admission, migration and strict commit bodies are inserted below.
@MainActor final class GoogleDriveExecutionLease {
    let deadline: TimeInterval
    private var ended = false
    init(deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 30) { self.deadline = deadline }
    static func begin(systemGranted: Bool, maximumDeadline: TimeInterval?, expiration: @escaping () -> Void) -> GoogleDriveExecutionLease {
        .init(deadline: min(maximumDeadline ?? .greatestFiniteMagnitude, ProcessInfo.processInfo.systemUptime + 30))
    }
    func check() throws { if ended || ProcessInfo.processInfo.systemUptime >= deadline { throw CancellationError() } }
    func end() { ended = true }
    func requestTimeout() throws -> TimeInterval { max(1, deadline - ProcessInfo.processInfo.systemUptime) }
}
@MainActor struct ScheduleProbeEvidence {
    mutating func observedCallback(segmentID: UUID, artifactKey: String) { }
}
@MainActor final class GoogleDriveRecoveryProbeTokens: GoogleDriveTokenProvider {
    let underlying: any GoogleDriveTokenProvider
    var hasCredential = true
    init(_ underlying: any GoogleDriveTokenProvider) { self.underlying = underlying }
    func accessToken(for accountID: String) async throws -> String { try await underlying.accessToken(for: accountID) }
    func accessToken(for accountID: String, timeout: TimeInterval?) async throws -> String {
        try await underlying.accessToken(for: accountID, timeout: timeout)
    }
}
@MainActor final class GoogleDriveScheduleAdmissionProbe {
    var ledger: GoogleDriveLibraryLedger
    var progress: GoogleDriveSyncProgress
    var networkRecoveryRequested = false
    var networkRecoveryRetry: Task<Void, Never>?
    var networkRecoveryRetryAt: Date?
    var foregroundRecoveryAwaitingPath = false
    var networkPath = GoogleDriveNetworkPath.unknown
    var isConfigured = true, ledgerUnavailable = false
    var isEnabled: Bool { !ledgerUnavailable && ledger.enabled }
    var scheduleRequests = 0, resumeRequests = 0
    var backgroundUploads: GoogleDriveBackgroundUploads?
    var preflightStore: GoogleDrivePreflightPinStore?
    var syncEvidence = ScheduleProbeEvidence()
    var workerDiagnosticState = GoogleDriveWorkerDiagnosticState()
    let http: GoogleDriveHTTP
    let oauth: GoogleDriveRecoveryProbeTokens
    var sourceChecks = 0
    var sourceIsCurrent = true
    // Opt-in execution of the exact production round routing. Legacy admission
    // tests retain an inert schedule; timer regressions execute real routing.
    var executesScheduledRounds = false
    var advance: (() async throws -> Void)?
    var isBusy = false, backgroundCallbackRequestedWork = false
    var work: Task<Void, Never>?, retry: Task<Void, Never>?, backgroundEventHandoff: Task<Void, Never>?
    var ordinaryRetryAt: Date?
    var generation: UInt64 = 0, roundSequence: UInt64 = 0, workerReportSequence: UInt64 = 0
    var workCancellation: @Sendable () -> Bool = { false }
    var executionID: UUID?, executionLease: GoogleDriveExecutionLease?
    var roundStartedAt = ProcessInfo.processInfo.systemUptime
    var nativeRegisteredThisRound = 0, scanVisitedThisRound = 0
    var currentPhase = GoogleDrivePreflightPhase.idle
    var activity = ""
    var pendingFileCount: Int { ledger.jobs.flatMap(\.artifacts).filter { $0.verifiedAt == nil }.count }
    var retryPlans: [Date] = []
    init(ledger: GoogleDriveLibraryLedger, progress: GoogleDriveSyncProgress, background: GoogleDriveBackgroundUploads,
         http: GoogleDriveHTTP, oauth: any GoogleDriveTokenProvider) {
        self.ledger = ledger; self.progress = progress; self.backgroundUploads = background; self.http = http; self.oauth = GoogleDriveRecoveryProbeTokens(oauth)
    }
    func schedule() {
        scheduleRequests += 1
        if executesScheduledRounds { scheduleUnscoped(isCancelled: { false }, systemGranted: false, maximumDeadline: nil) }
    }
    func scheduleRetry(at date: Date) { retryPlans.append(date); ordinaryRetryAt = date }
    func recordWorker(_ event: GoogleDriveWorkerReport.Event) { workerReportSequence += 1 }
    static func fixedFailure(_ error: Error) -> String { "synthetic_failure" }
    func failClosed(_ error: Error) { ledgerUnavailable = true }
    func reconcilePreflight() throws {}
    func admitCachedSources(maximum: Int?) throws {}
    func discoverSources(token: UInt64) async throws {}
    func discoverLocal(token: UInt64) async throws {}
    func advanceKnownItems(token: UInt64, lease: GoogleDriveExecutionLease, discoverAfterFailure: Bool) async throws {
        try checkWork(token); try await advance?()
    }
    func deliverKnownItems(token: UInt64, lease: GoogleDriveExecutionLease, maximumOperations: Int) async throws {
        try checkWork(token); try await advance?()
    }
    func finishSuccessfulRound() {}
    func resume() { resumeRequests += 1 }
    func publish() {}
    func checkWork(_ token: UInt64) throws {
        try Task.checkCancellation()
        if executesScheduledRounds {
            guard ledger.enabled, !ledger.revokedLocally, !ledgerUnavailable, generation == token else { throw CancellationError() }
            try executionLease?.check()
        }
    }
    func checkCompletedSource(_ pin: GoogleDrivePreflightPin, token: UInt64, stopAt: TimeInterval) async throws {
        sourceChecks += 1
        guard sourceIsCurrent, try pin.reconciled(in: ledger) != nil else { throw GoogleDriveLibraryError.changedManifest }
    }
    func change(_ body: (inout GoogleDriveLibraryLedger) throws -> Void) throws { try body(&ledger) }
    func setPhase(_ phase: GoogleDrivePreflightPhase) { }
    func recordDiagnostic(_ event: String, _ detail: String) { }
    func publishSyncEvidence() { }
""" + admission + foreground + path_opportunity + recovery + scheduled_round + migration + commit
    + '    func canCheckNetworkRecoveryFromProduction() -> Bool {\n        return ' + recovery_button + '\n    }\n}\n')

    # The coordinator's real identity transaction is compiled too. Only the
    # Keychain/browser and local persistence shell are synthetic; commit order,
    # account fencing, pending-state transitions and continue admission are not.
    connect = actual_method('    func connect() {', '    func enable(')
    enable = actual_method('    func enable(', '    func pause() {')
    resume = actual_method('    func continueSync() {', '    func revoke() {')
    identity_file = run / 'IdentityTransaction.swift'
    identity_file.write_text("""import Foundation
import RecordingCore
@MainActor final class PhoneBackgroundSync {
    static let shared = PhoneBackgroundSync()
    static func noteNewWork() {}
    private(set) var requested: [Date] = []
    func schedule(earliestBeginDate: Date) { requested.append(earliestBeginDate) }
}
@MainActor final class IdentityProbeOAuth {
    var failCommit = false
    var commits = 0
    var credential: GoogleDriveCredential?
    func authorize() async throws -> GoogleDriveCredential {
        .init(clientID: "synthetic-client", accessToken: "synthetic-access",
              refreshToken: "synthetic-refresh", expiresAt: Date(timeIntervalSinceNow: 3600))
    }
    func commit(_ value: GoogleDriveCredential, accountID: String) throws {
        if failCommit { throw GoogleDriveError.credentials }
        var bound = value; bound.accountID = accountID; credential = bound; commits += 1
    }
    func resumeUploadAccessAfterAuthorization() {}
}
@MainActor final class IdentityProbeBackground { func cancel() {} }
@MainActor final class IdentityProbeRepository {
    var reads = 0
    func manifests() throws -> [SegmentManifest] { reads += 1; return [] }
    func receivedSegmentIDs() throws -> Set<UUID> { reads += 1; return [] }
}
@MainActor final class GoogleDriveIdentityTransactionProbe {
    var isConfigured = true, isBusy = false, ledgerUnavailable = false
    var isConnected: Bool { oauth.credential?.permitsAccessToken == true }
    var ledger: GoogleDriveLibraryLedger
    let oauth = IdentityProbeOAuth()
    let http: GoogleDriveHTTP
    var backgroundUploads: IdentityProbeBackground?
    var generation: UInt64 = 0
    var work: Task<Void, Never>?
    var progress = GoogleDriveSyncProgress()
    let repository = IdentityProbeRepository()
    var latestManifests: [SegmentManifest]?
    var latestReceived: Set<UUID>?
    var activity = ""
    var writes: [GoogleDriveLibraryLedger] = []
    var failWriteNumber: Int?
    var writeAttempts = 0, schedules = 0, recoveries = 0
    init(ledger: GoogleDriveLibraryLedger, http: GoogleDriveHTTP) { self.ledger = ledger; self.http = http }
    func stopWork() { generation += 1; work?.cancel(); work = nil; isBusy = false }
    func persist(_ candidate: GoogleDriveLibraryLedger) throws {
        writeAttempts += 1
        if writeAttempts == failWriteNumber { throw GoogleDriveError.credentials }
        try candidate.validate(); writes.append(candidate)
    }
    func change(_ mutation: (inout GoogleDriveLibraryLedger) throws -> Void) throws {
        var candidate = ledger; try mutation(&candidate); try persist(candidate); ledger = candidate
    }
    func publish() {}
    func clearStopIntentAfterAuthorization() throws {}
    func failClosed(_ error: Error) { ledgerUnavailable = true }
    func checkIdentityOperation(_ token: UInt64) throws {
        try Task.checkCancellation(); if generation != token { throw CancellationError() }
    }
    func schedule() { schedules += 1 }
    func startMetadataRecoveryAtOpportunity() { recoveries += 1 }
""" + connect + enable + resume + '}\n')

    # P-56 executes the actual recovery entry and diagnostic/publication bodies.
    # Only UIKit and native reconciliation are replaced. All
    # metadata, archive files and injected failures belong to this private run.
    recovery = actual_method('    private func startMetadataRecoveryAtOpportunity(', '    private func publish()')
    phase = actual_method('    private func setPhase(', '    private func failClosed(')
    worker = actual_method('    private func recordWorker(', '    func restoreBackgroundSession(')
    diagnostic = actual_method('    private func recordDiagnostic(', '    private func recordWorker(')
    transport = actual_method('    private func recordTransportDiagnostic(', '    private func refreshTransportFaultPresentation(')
    persist_transport = actual_method('    private func persistTransportHistory(', '    private func recordDiagnostic(')
    local_files = source[source.index('enum GoogleDriveLocalFiles {'):source.index('/// Separate from the mutable queue ledger:')]
    source_scan = actual_method('    private func discoverSources(', '    private func discoverLocal(')
    # REC-38 inserted its separate network recovery entry after advanceKnownItems.
    # Keep REC-36's discovery-failure shell scoped to that exact production body.
    advance_known = actual_method('    private func advanceKnownItems(', '    private func recoverNetworkAtOpportunity(')
    evidence_start = 'private final class GoogleDriveSyncEvidenceWriter:'
    evidence_end = '/// Presentation uses only validated typed states.'
    if source.count(evidence_start) != 1 or source.count(evidence_end) != 1:
        raise RuntimeError('Production sync evidence writer boundary changed')
    evidence_writer = source[source.index(evidence_start):source.index(evidence_end)].replace('private final class ', 'final class ', 1)
    worker_file = run / 'WorkerLibraryBoundaries.swift'
    worker_file.write_text("""import Darwin
import Foundation
import RecordingCore
@MainActor final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    var applicationState = State.background
}
@MainActor final class WorkerProbeBackground {
    let nativeActiveCount = 0, pendingReadbackCount = 0
    let itemRetries: [Int] = []
    func validateRecoveryMetadata(in ledger: GoogleDriveLibraryLedger) throws {}
    func recoverMetadata(in ledger: GoogleDriveLibraryLedger, check: @MainActor () throws -> Void) async throws { try check() }
}
@MainActor struct WorkerProbeOAuth { var hasCredential = true }
@MainActor struct WorkerProbePreflight { var pin: GoogleDrivePreflightPin? }
@MainActor struct WorkerProbeFaultContext {
    let snapshot = (build: 756, state: GoogleDriveFaultApplicationState.background)
    func observeCurrentState() {}
    func noteStorageFailure() {}
}
@MainActor final class GoogleDriveWorkerLibraryProbe {
    var ledger: GoogleDriveLibraryLedger
    var ledgerUnavailable = true, isBusy = false
    let metadataRecovery = GoogleDriveMetadataRecovery()
    var work: Task<Void, Never>?, backgroundEventHandoff: Task<Void, Never>?
    var generation: UInt64 = 0
    var oauth = WorkerProbeOAuth()
    var backgroundUploads: WorkerProbeBackground? = WorkerProbeBackground()
    var preflightStore: WorkerProbePreflight? = WorkerProbePreflight()
    var executionLease: GoogleDriveExecutionLease?
    var executionID: UUID?
    var currentPhase = GoogleDrivePreflightPhase.idle
    var phaseStartedAt = ProcessInfo.processInfo.systemUptime
    var roundStartedAt = ProcessInfo.processInfo.systemUptime
    var roundSequence: UInt64 = 0
    var nativeRegisteredThisRound = 0, scanVisitedThisRound = 0
    var workerDiagnosticState = GoogleDriveWorkerDiagnosticState()
    var workerReportSequence: UInt64 = 0
    var workerObservations: [GoogleDriveWorkerReport.Observation] = []
    let workerDiagnostics: GoogleDriveWorkerDiagnosticsWriter
    let workerProcessRunID: UUID
    let workerBuild = "756"
    var progress = GoogleDriveSyncProgress()
    let directory: URL, ledgerURL: URL
    var diagnosticHandler: ((String, String) -> Void)?
    var transportHistory = GoogleDriveTransportHistory()
    var transportFaultRecorder: GoogleDriveTransportFaultRecorder?
    let transportFaultContext = WorkerProbeFaultContext()
    let transportFile: URL
    var normalSchedules = 0
    init(ledger: GoogleDriveLibraryLedger, directory: URL, transportFile: URL,
         processRunID: UUID, writer: GoogleDriveWorkerDiagnosticsWriter) {
        self.ledger = ledger; self.directory = directory; self.ledgerURL = directory.appendingPathComponent("ledger.json")
        self.transportFile = transportFile; self.workerProcessRunID = processRunID; self.workerDiagnostics = writer
    }
    func publish() {}
    func schedule(isCancelled: @escaping @Sendable () -> Bool = { false }, systemGranted: Bool = false,
                  maximumDeadline: TimeInterval? = nil) { normalSchedules += 1 }
    func refreshTransportFaultPresentation(storageFailed: Bool = false) {}
""" + recovery + phase + diagnostic + worker + transport + persist_transport + '}\n'
        + local_files + evidence_writer)

    snapshot_file = run / 'SourceSnapshotBoundary.swift'
    snapshot_file.write_text("""import Foundation
import RecordingCore
@MainActor final class GoogleDriveSourceSnapshotProbe {
    let repository: RecordingRepository
    let directory: URL
    var ledger: GoogleDriveLibraryLedger
    var progress = GoogleDriveSyncProgress()
    var executionLease: GoogleDriveExecutionLease? = .init()
    var checks = 0, cancelOnCheck: Int? = nil, persisted = 0
    init(repository: RecordingRepository, directory: URL, ledger: GoogleDriveLibraryLedger) {
        self.repository = repository; self.directory = directory; self.ledger = ledger
    }
    func checkWork(_ token: UInt64) throws {
        checks += 1
        if cancelOnCheck == checks { throw CancellationError() }
        guard let executionLease else { throw CancellationError() }
        try executionLease.check()
    }
    func persist(_ value: GoogleDriveLibraryLedger) throws {
        try GoogleDriveLocalFiles.write(TransportCodec.encode(value), to: directory.appendingPathComponent("ledger.json")); persisted += 1
    }
    func publish() {}
    func setPhase(_ phase: GoogleDrivePreflightPhase) {}
    func recordDiagnostic(_ event: String, _ detail: String) {}
    nonisolated static func checkLocalBudget(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        if ProcessInfo.processInfo.systemUptime >= deadline { throw CancellationError() }
    }
    func localIO<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(operation: operation)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
""" + source_scan + '}\n' + """
// Execute the production known-item advance/failure boundary. Only the native
// delivery side is injected; local admission uses the actual durable cursor.
@MainActor final class GoogleDriveDiscoveryFailureProbe {
    let source: GoogleDriveSourceSnapshotProbe
    let lease = GoogleDriveExecutionLease()
    var currentPhase = GoogleDrivePreflightPhase.idle
    var calls: [String] = []
    var advanceFailure: Error?
    var failReadback = true
    var cancelOnAdvance = false
    var cancelAfterDiscovery = false
    var localFailure: Error?
    var readbackOperation: (() async throws -> Void)?
    var deliveryOperation: (() async throws -> Void)?
    init(source: GoogleDriveSourceSnapshotProbe) {
        self.source = source; source.executionLease = lease
    }
    func checkWork(_ token: UInt64) throws { try Task.checkCancellation(); try lease.check() }
    func setPhase(_ phase: GoogleDrivePreflightPhase) { currentPhase = phase }
    func readBackCompletedBeforeDiscovery(token: UInt64, lease: GoogleDriveExecutionLease) async throws {
        calls.append("readback")
        if let readbackOperation { try await readbackOperation(); return }
        if failReadback { try failAdvance() }
    }
    func deliverKnownItems(token: UInt64, lease: GoogleDriveExecutionLease, maximumOperations: Int) async throws {
        calls.append("delivery")
        guard maximumOperations == 4 else { throw GoogleDriveLibraryError.invalidState }
        if let deliveryOperation { try await deliveryOperation(); return }
        if !failReadback { try failAdvance() }
    }
    func failAdvance() throws {
        setPhase(.tokenAccess)
        if cancelOnAdvance { lease.end() }
        if let advanceFailure { throw advanceFailure }
    }
    func discoverLocal(token: UInt64) async throws {
        calls.append("discovery"); setPhase(.snapshot)
        if let localFailure { throw localFailure }
        try await source.discoverSources(token: token)
        if cancelAfterDiscovery { lease.end() }
    }
""" + advance_known + '}\n')

    swift = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    flags = ['-target', platform.machine() + '-apple-macosx15.0', '-sdk', sdk, '-swift-version', '5', '-module-cache-path', str(run / 'module-cache')]
    plugin_flags = ['-Xfrontend', '-disable-sandbox'] if args.compiler_plugin_no_sandbox else []
    commands = [
        [swift, '-emit-module', '-emit-library', '-static', '-parse-as-library', '-module-name', 'RecordingCore', '-emit-module-path', str(run / 'RecordingCore.swiftmodule'), *flags, *map(str, core), '-o', str(run / 'libRecordingCore.a')],
        [swift, '-parse-as-library', '-module-name', 'PhoneGoogleDriveSyntheticProbe', '-strict-concurrency=complete', '-D', 'DEBUG', *flags, *plugin_flags, '-I', str(run), '-L', str(run), '-lRecordingCore', *map(str, phone), str(models), str(admission_file), str(identity_file), str(worker_file), str(snapshot_file), *map(str, probes), '-o', str(run / 'probe')],
        [str(run / 'probe'), str(run / 'report.json'), str(run / 'fixtures'), args.case_filter],
    ]
    steps = []
    reused_core = None
    if args.reuse_core_build:
        previous = args.reuse_core_build.resolve(strict=True)
        proof = previous / 'evidence.json'
        old = json.loads(proof.read_text())
        expected = [value.replace(str(run), str(previous)) for value in commands[0]]
        if (old['commands'][0] != expected or old['steps'][0]['index'] != 0
                or old['steps'][0]['exitCode'] != 0):
            raise RuntimeError('Reuse compiler/SDK/target/flags or prior Core exit0 did not match')
        for source in core:
            name = str(source.relative_to(ROOT))
            if old['inputSHA256Before'].get(name) != before[name] or old['inputSHA256After'].get(name) != before[name]:
                raise RuntimeError('Reuse Core input bytes changed: ' + name)
        artifacts = {}
        for name in ['RecordingCore.swiftmodule', 'RecordingCore.swiftdoc', 'RecordingCore.swiftsourceinfo', 'libRecordingCore.a']:
            source = previous / name
            if source.is_symlink() or not source.is_file():
                raise RuntimeError('Reuse Core artifact missing or non-regular: ' + name)
            value = hashlib.sha256(source.read_bytes()).hexdigest()
            shutil.copyfile(source, run / name)
            if hashlib.sha256((run / name).read_bytes()).hexdigest() != value:
                raise RuntimeError('Reuse artifact copy did not match')
            artifacts[name] = value
        reused_core = {'sourceDirectory': str(previous), 'sourceEvidence': str(proof),
                       'sourceEvidenceSHA256': hashlib.sha256(proof.read_bytes()).hexdigest(),
                       'sourceCoreCommand': old['commands'][0], 'sourceCoreExitCode': 0,
                       'allCoreInputBytesMatched': True, 'artifactsSHA256': artifacts}
    for index, command in enumerate(commands):
        if index == 0 and reused_core is not None:
            steps.append({'index': index, 'operation': 'verified_prior_core_reuse', 'exitCode': 0,
                          'executedThisRun': False, 'sourceEvidence': reused_core['sourceEvidence']})
            continue
        result = subprocess.run(command, capture_output=True, text=True, cwd=run)
        log = run / f'step-{index}.log'; log.write_text(result.stdout + result.stderr)
        steps.append({'index': index, 'exitCode': result.returncode, 'log': str(log)})
        if result.returncode:
            break
    after = hashes(); report_path = run / 'report.json'
    if not report_path.exists():
        report_path.write_text(json.dumps({'status': 'build_failed', 'caseCount': 0, 'failures': ['See ' + steps[-1]['log']]}, indent=2))
    report = json.loads(report_path.read_text()); stable = before == after
    evidence = {'sourceStableDuringRun': stable, 'inputSHA256Before': before, 'inputSHA256After': after,
                'caseFilter': args.case_filter, 'negativeControl': control,
                'compilerPluginNoSandbox': args.compiler_plugin_no_sandbox,
                'reusedCoreBuild': reused_core,
                'commands': commands, 'steps': steps, 'report': str(report_path)}
    evidence_path = run / 'evidence.json'; evidence_path.write_text(json.dumps(evidence, indent=2))
    print(json.dumps({'status': report['status'] if stable else 'source_changed_during_run', 'caseCount': report['caseCount'], 'report': str(report_path), 'evidence': str(evidence_path), 'steps': steps}, indent=2))
    return 0 if stable and report['status'] == 'passed' and steps[-1]['exitCode'] == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
