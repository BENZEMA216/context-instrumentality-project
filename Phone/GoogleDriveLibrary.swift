import Combine
import Darwin
import Foundation
import RecordingCore
import UIKit

/// Device-local private files. OAuth tokens are deliberately not representable
/// here; only the Keychain-owned OAuth component can read/write credentials.
enum GoogleDriveLocalFiles {
    static func prepare(_ directory: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            guard try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else { throw GoogleDriveLibraryError.invalidState }
        } else {
            try prepare(directory.deletingLastPathComponent())
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
#if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
#endif
    }
    static func read(_ file: URL, maximum: Int = 32 * 1_024 * 1_024) throws -> Data {
        try GoogleDriveMetadataIO.read(file, maximum: maximum)
    }
    static func stage(_ data: Data, to file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            // Content-addressed staging is checked again before upload. Existing
            // regular files need no rewrite/fsync on every execution budget.
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { throw GoogleDriveLibraryError.invalidState }
            return
        }
        try write(data, to: file)
    }
    static func write(_ data: Data, to file: URL, beforeRename: (() throws -> Void)? = nil) throws {
        try GoogleDriveMetadataIO.perform { try writeMetadata(data, to: file, beforeRename: beforeRename) }
    }
    /// Fixed diagnostic leaves never need to read a possibly corrupt old file.
    /// Failure stays on the diagnostic writer's independent queue.
    static func writeDiagnostic(_ data: Data, to file: URL) throws {
        let maximum = file.lastPathComponent == "worker-health.json" ? GoogleDriveWorkerWriterHealth.maximumBytes : GoogleDriveWorkerReport.maximumBytes
        guard ["worker-status.json", "worker-health.json"].contains(file.lastPathComponent), !data.isEmpty, data.count <= maximum else { throw GoogleDriveLibraryError.invalidState }
        try GoogleDriveMetadataIO.perform {
            var info = stat()
            if Darwin.lstat(file.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid() else { throw GoogleDriveLibraryError.invalidState }
            } else if errno != ENOENT { throw GoogleDriveMetadataIO.syscallFailure() }
            try writeMetadata(data, to: file, readExisting: false)
        }
    }
    private static func writeMetadata(_ data: Data, to file: URL, readExisting: Bool = true,
                                      beforeRename: (() throws -> Void)? = nil) throws {
        guard data.count <= 32 * 1_024 * 1_024 else { throw GoogleDriveLibraryError.invalidState }
        try prepare(file.deletingLastPathComponent())
        if readExisting, FileManager.default.fileExists(atPath: file.path) { _ = try read(file) }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".drive-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
#endif
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data); try handle.synchronize()
        try beforeRename?()
        guard Darwin.rename(temporary.path, file.path) == 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
        let parent = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
        defer { Darwin.close(parent) }
        guard Darwin.fsync(parent) == 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
    }
}

/// Separate from the mutable queue ledger: a failed ledger replacement cannot
/// erase a user's stop request. This contains no credential or recording data.
private struct GoogleDriveStopIntent: Codable, Equatable {
    let schemaVersion: Int
    let libraryID: UUID
    let accountID: String?
    init(ledger: GoogleDriveLibraryLedger) {
        schemaVersion = 1; libraryID = ledger.libraryID; accountID = ledger.accountID
    }
    func validate(against ledger: GoogleDriveLibraryLedger) throws {
        guard schemaVersion == 1, libraryID == ledger.libraryID, accountID == ledger.accountID else {
            throw GoogleDriveLibraryError.invalidState
        }
    }
}

@MainActor
final class GoogleDriveLibrary: ObservableObject {
    @Published private(set) var allowsCellularAccess = GoogleDriveNetworkSettings.shared.allowsCellularAccess
    @Published private(set) var isWaitingForWiFi = false
    private var networkPath = GoogleDriveNetworkPath.unknown
    private var networkMonitor: GoogleDriveNetworkMonitor?
    private var networkRecoveryRequested = false
    private var foregroundRecoveryAwaitingPath = false
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var isEnabled = false
    @Published private(set) var canRetryRevocation = false
    @Published private(set) var accountLabel = "尚未连接 Google 账户"
    @Published private(set) var scope: GoogleDriveRecordingScope?
    @Published private(set) var authorizedManifests: [SegmentManifest] = []
    @Published private(set) var cloudConfirmedRecordingIDs: Set<UUID> = []
    @Published private(set) var authorizedCount = 0
    @Published private(set) var savedAudioCount = 0
    @Published private(set) var savedTranscriptCount = 0
    @Published private(set) var pendingFileCount = 0
    @Published private(set) var folderURL: URL?
    @Published private(set) var activity = "连接自己的 Google Drive 后，再选择独立的录音同步范围。"
    @Published private(set) var error: String?
    @Published private(set) var isNetworkFailure = false
    @Published private(set) var needsCredential = false
    @Published private(set) var apiFailureReason: GoogleDriveAPIReason?
    @Published private(set) var lastFailureAt: Date?
    @Published private(set) var nextPlannedAttemptAt: Date?
    @Published private(set) var canCheckNetworkRecovery = false
    @Published private(set) var transportFaultCount = 0
    @Published private(set) var latestTransportFaultAt: Date?
    @Published private(set) var transportFaultSummary = "尚无故障记录。"
    @Published private(set) var transportFaultExportError: String?
    let isConfigured: Bool
    private let repository: RecordingRepository
    private let transcriptRepository: TranscriptRepository
    private let directory: URL
    private let ledgerURL: URL
    private let http: GoogleDriveHTTP
    private let oauth: any GoogleDriveAuthorization
    private let beforeMetadataRename: ((URL) throws -> Void)?
    private var stopIntent: GoogleDriveStopIntent?
    private var ledger = GoogleDriveLibraryLedger()
    private var ledgerUnavailable = false
    private var metadataLoaded = false
    private let metadataRecovery = GoogleDriveMetadataRecovery()
    private var work: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var networkRecoveryRetry: Task<Void, Never>?
    private var networkRecoveryRetryAt: Date?
    private var ordinaryRetryAt: Date?
    private var generation: UInt64 = 0
    private var progress = GoogleDriveSyncProgress()
    private var latestManifests: [SegmentManifest]?
    private var latestReceived: Set<UUID>?
    private var workCancellation: @Sendable () -> Bool = { false }
    private var executionLease: GoogleDriveExecutionLease?
    private var executionID: UUID?
    private var backgroundUploads: GoogleDriveBackgroundUploads?
    private var preflightStore: GoogleDrivePreflightPinStore?
    private var currentPhase = GoogleDrivePreflightPhase.idle
    private var phaseStartedAt = ProcessInfo.processInfo.systemUptime
    private var roundStartedAt = ProcessInfo.processInfo.systemUptime
    private var roundSequence: UInt64 = 0
    private var nativeRegisteredThisRound = 0
    private var scanVisitedThisRound = 0
    private var backgroundCallbackRequestedWork = false
    private var diagnosticHandler: ((String, String) -> Void)?
    private let workerDiagnostics: GoogleDriveWorkerDiagnosticsWriter
    private let workerProcessRunID = VerifiedObservationPublisher.processRunID
    private let workerBuild = String((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown").prefix(32))
    private var workerReportSequence: UInt64 = 0
    private var workerObservations: [GoogleDriveWorkerReport.Observation] = []
    private var workerDiagnosticState = GoogleDriveWorkerDiagnosticState()
    private var transportHistory = GoogleDriveTransportHistory()
    private let syncEvidence: GoogleDriveSyncEvidenceWriter
    private var transportFaultRecorder: GoogleDriveTransportFaultRecorder?
    private let transportFaultContext = GoogleDriveTransportFaultObservationContext()
    private var backgroundEventHandoff: Task<Void, Never>?
#if DEBUG
    @Published private(set) var debugTLSProbeRunning = false
    @Published private(set) var debugTLSProbeStatus = "尚未检查真实连接。"
    private var debugTLSProbeTask: Task<Void, Never>?
    private var debugTLSProbeLease: GoogleDriveExecutionLease?
    private var debugTLSProbeID: UUID?
#endif

    init(repository: RecordingRepository, transcriptRepository: TranscriptRepository,
         http: GoogleDriveHTTP = GoogleDriveHTTP(), authorization: (any GoogleDriveAuthorization)? = nil,
         beforeMetadataRename: ((URL) throws -> Void)? = nil) {
        self.repository = repository; self.transcriptRepository = transcriptRepository
        self.http = http; self.beforeMetadataRename = beforeMetadataRename
        directory = repository.root.appendingPathComponent("GoogleDriveLibrary", isDirectory: true)
        ledgerURL = directory.appendingPathComponent("ledger.json")
        workerDiagnostics = GoogleDriveWorkerDiagnosticsWriter(file: directory.appendingPathComponent("worker-status.json"),
            processRunID: workerProcessRunID, build: workerBuild,
            write: { try GoogleDriveLocalFiles.writeDiagnostic($0, to: $1) })
        syncEvidence = GoogleDriveSyncEvidenceWriter(root: repository.root, workerDiagnostics: workerDiagnostics)
        oauth = authorization ?? GoogleDriveOAuth(http: http); isConfigured = oauth.configuration != nil
        do {
            if FileManager.default.fileExists(atPath: ledgerURL.path) {
                ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: GoogleDriveLocalFiles.read(ledgerURL))
                try ledger.validate()
            }
        } catch {
            ledgerUnavailable = true; progress.recordOperationFailure(GoogleDriveLibraryError.invalidState.localizedDescription)
        }
        if ledger.revokedLocally { oauth.suspendUploadAccess() }
        do {
            if let intent = try readStopIntent() {
                try intent.validate(against: ledger)
                stopIntent = intent; ledger.revoke(remoteConfirmed: ledger.remoteRevocationConfirmed)
                oauth.suspendUploadAccess()
            }
        } catch {
            // Missing is the only legacy-compatible absence. An unreadable or
            // foreign stop intent is never silently treated as permission.
            ledgerUnavailable = true; ledger.revoke(); oauth.suspendUploadAccess()
            progress.recordOperationFailure(GoogleDriveLibraryError.invalidState.localizedDescription)
        }
        do {
            // This directory already belongs to the explicit Drive grant. No
            // background request is created by restoring the coordinator.
            try GoogleDriveLocalFiles.prepare(directory)
            if let bytes = try? GoogleDriveLocalFiles.read(directory.appendingPathComponent("transport-diagnostics.json"),
                                                         maximum: GoogleDriveTransportHistory.maximumFileBytes),
               let restored = GoogleDriveTransportHistory.restored(from: bytes) {
                transportHistory = restored
            }
            preflightStore = try GoogleDrivePreflightPinStore(directory: directory)
            try preflightStore?.reconcile(in: ledger)
            backgroundUploads = try GoogleDriveBackgroundUploads(
                directory: directory.appendingPathComponent("background-uploads", isDirectory: true),
                libraryID: ledger.libraryID, changed: { [weak self] in self?.backgroundUploadDidChange() },
                finishedEvents: { [weak self] identifier in
                    Task { @MainActor in await self?.finishBackgroundEvents(identifier) }
                }, diagnostic: { [weak self] kind, detail in self?.recordDiagnostic(kind, detail) },
                transportDiagnostic: { [weak self] in self?.recordTransportDiagnostic($0) })
        } catch {
            ledgerUnavailable = true; progress.recordOperationFailure(GoogleDriveLibraryError.invalidState.localizedDescription)
        }
        metadataLoaded = !ledgerUnavailable
        // Fault logging is diagnostic-only: its storage failure must never
        // invalidate a recording grant, fail the ledger or stop a sync worker.
        transportFaultContext.startObserving()
        do {
            try GoogleDriveLocalFiles.prepare(directory)
            transportFaultRecorder = try GoogleDriveTransportFaultRecorder(
                storeURL: directory.appendingPathComponent("transport-faults.json"))
            refreshTransportFaultPresentation()
        } catch {
            transportFaultContext.noteStorageFailure()
            transportFaultSummary = "故障日志暂不可用，尚未确认故障记录已保存。"
        }
        let faultRecorder = transportFaultRecorder, faultContext = transportFaultContext
        http.setTransportDiagnosticHandler { [weak self] value in
            // Freeze before recovery or a delayed MainActor turn can run. The
            // cached context contains only the last MainActor UIKit observation.
            var failedToSave = false
            if let faultRecorder {
                let observation = faultContext.snapshot
                do { try faultRecorder.record(value, build: observation.build, applicationState: observation.state) }
                catch { failedToSave = true; faultContext.noteStorageFailure() }
            }
            let storageFailed = failedToSave
            Task { @MainActor in
                self?.recordTransportDiagnostic(value, freezeFault: false)
                self?.refreshTransportFaultPresentation(storageFailed: storageFailed)
            }
        }
        http.setRequestCompletionHandler { [weak self] completion in
            var failedToSave = false
            if let faultRecorder {
                let observation = faultContext.snapshot
                do { try faultRecorder.finish(completion, build: observation.build, applicationState: observation.state) }
                catch { failedToSave = true; faultContext.noteStorageFailure() }
            }
            let storageFailed = failedToSave
            Task { @MainActor in
                if completion.origin != .controlledFault, completion.uploadCorrelation != nil {
                    self?.recordWorker(.requestCompleted, completion: completion)
                }
                self?.refreshTransportFaultPresentation(storageFailed: storageFailed)
            }
        }
        networkMonitor = GoogleDriveNetworkMonitor { [weak self] path, restored in
            self?.networkPathDidChange(path, restored: restored)
        }
        networkMonitor?.start()
        publish()
        recordWorker(.initialized)
        if !isConfigured { activity = GoogleDriveError.unavailable.localizedDescription }
        AutomaticDeliveryBackgroundEvents.shared.registerDrive(self)
        if let backgroundUploads {
            let identifier = backgroundUploads.identifier
            // Keep the current scope routable even if its first attempt is
            // registered later in this process. Empty cold launch alone must
            // not create a native session before a real execution opportunity.
            AutomaticDeliveryBackgroundEvents.shared.registerRestore(identifier) { [weak self] in
                guard let self, self.backgroundUploads?.needsRecovery == true
                    || AutomaticDeliveryBackgroundEvents.shared.hasPendingCompletion(identifier) else { return }
                _ = self.restoreBackgroundSession(identifier)
            }
        }
    }
    deinit {
        work?.cancel(); retry?.cancel(); networkRecoveryRetry?.cancel()
#if DEBUG
        debugTLSProbeTask?.cancel(); debugTLSProbeLease?.end()
#endif
        let identifier = backgroundUploads?.identifier
        Task { @MainActor in
            if let identifier { AutomaticDeliveryBackgroundEvents.shared.unregisterRestore(identifier) }
        }
    }
    var hasPendingWork: Bool { ledger.enabled && (ledger.hasPendingFiles || progress.hasWork) }

    /// A retained recording grant, including after disconnect. This is not a
    /// currently connected account and must not itself keep a revoked row active.
    var hasAuthorizationHistory: Bool { ledger.recordingScope != nil }
    var isRevocationPending: Bool { ledger.revokedLocally && !ledger.remoteRevocationConfirmed }

    /// Queue discovery must finish too: zero pending artifacts alone can still
    /// mean that the remaining local transcripts have not been inspected.
    var isCurrentScopeSaved: Bool {
        isConnected && isEnabled && scope != nil && authorizedCount > 0
            && savedAudioCount == authorizedCount && !isBusy && error == nil && !hasPendingWork
    }
    var isWaitingForNewRecordings: Bool {
        isConnected && isEnabled && scope == .futureOnly && authorizedCount == 0
            && !isBusy && error == nil && !hasPendingWork
    }

#if DEBUG
    /// A user-started account read only. This owns neither the sync worker nor
    /// its grant/queue and never calls connect, discovery or upload methods.
    func startDebugTLSProbe(controlledFault: Bool) {
        guard !debugTLSProbeRunning else { return }
        guard isConfigured, !ledgerUnavailable, !ledger.revokedLocally,
              oauth.hasCredential, let accountID = ledger.accountID else {
            debugTLSProbeStatus = "当前 Google 连接不可用，未发起诊断。"; return
        }
        let runID = UUID(), token = generation, capture = GoogleDriveTLSProbeCapture()
        let stopAt = ProcessInfo.processInfo.systemUptime + 45
        let probeHTTP = controlledFault ? GoogleDriveHTTP() : http
        if controlledFault { probeHTTP.debugInjectClosedNoNotifyOnce() }
        let initial = GoogleDriveTLSProbeReport(runID: runID, controlledFault: controlledFault,
            build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0,
            startForeground: UIApplication.shared.applicationState == .active)
        do { try persistDebugTLSProbeReport(initial) }
        catch { debugTLSProbeStatus = "无法保存诊断报告，未发起检查。"; return }
        debugTLSProbeID = runID; debugTLSProbeRunning = true
        debugTLSProbeStatus = "连接检查已开始；两秒后发送只读账户请求。"
        let lease = GoogleDriveExecutionLease.begin(systemGranted: false,
            maximumDeadline: stopAt) { [weak self] in
                Task { @MainActor in
                    guard let self, self.debugTLSProbeID == runID else { return }
                    self.debugTLSProbeTask?.cancel()
                }
            }
        debugTLSProbeLease = lease
        let sink: @Sendable (GoogleDriveTransportDiagnostic) -> Void = { value in
            capture.enqueue(value) { UIApplication.shared.applicationState == .active }
        }
        debugTLSProbeTask = Task { [weak self] in
            guard let self else { lease.end(); return }
            defer {
                lease.end()
                if self.debugTLSProbeID == runID {
                    self.debugTLSProbeTask = nil; self.debugTLSProbeLease = nil
                    self.debugTLSProbeID = nil; self.debugTLSProbeRunning = false
                }
            }
            var report = initial
            let check: () throws -> Void = { [weak self] in
                guard let self else { throw CancellationError() }
                try self.checkDebugTLSProbe(runID: runID, token: token, accountID: accountID, lease: lease)
            }
            let client = GoogleDriveClient(http: probeHTTP, oauth: self.oauth, accountID: accountID,
                check: check, requestTimeout: { try check(); return try lease.requestTimeout() })
            do {
                try check()
                try await Task.sleep(nanoseconds: 2_000_000_000)
                try check()
                for index in 0..<(controlledFault ? 1 : 6) {
                    try check()
                    report.validationsStarted += 1
                    do {
                        try await GoogleDriveHTTP.$debugDiagnosticObserver.withValue(sink) {
                            try await client.validateAccount()
                        }
                        try check()
                        report.validationsSucceeded += 1; report.accountMatched = true
                    } catch is CancellationError { throw CancellationError() }
                    catch GoogleDriveLibraryError.changedAccount {
                        report.accountMatched = false; report.result = .accountMismatch
                        break
                    } catch {
                        try check()
                        report.validationsFailed += 1
                        if (error as? GoogleDriveError).map({ if case .needsSignIn = $0 { return true }; return false }) == true {
                            report.result = .needsSignIn; break
                        }
                    }
                    await capture.drain()
                    try check()
                    report.observe(capture.snapshot, injectionCount: probeHTTP.debugClosedNoNotifyInjectionCount)
                    try self.persistDebugTLSProbeReport(report)
                    self.debugTLSProbeStatus = "已完成 \(index + 1)/\(controlledFault ? 1 : 6) 次只读账户检查。"
                    if !controlledFault && index < 5 {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        try check()
                    }
                }
                try check()
                if report.result == .running {
                    report.result = report.validationsFailed == 0 ? .completed : .completedWithFailures
                }
            } catch is CancellationError { report.result = .cancelled }
            catch { report.result = .reportUnavailable }
            // Sink callbacks are short MainActor observations, not network work.
            // Drain them even after cancellation so the final real response is
            // retained without creating a fresh request or execution lease.
            await capture.drain()
            report.observe(capture.snapshot, injectionCount: probeHTTP.debugClosedNoNotifyInjectionCount)
            report.finishedAt = Date()
            if controlledFault && report.result == .completed {
                report.result = report.hasProvenControlledRecovery ? .controlledRecovered : .completedUnproven
            }
            do { try self.persistDebugTLSProbeReport(report) }
            catch { report.result = .reportUnavailable }
            guard self.debugTLSProbeID == runID else { return }
            self.debugTLSProbeStatus = report.status
        }
    }

    func cancelDebugTLSProbe() {
        guard debugTLSProbeRunning else { return }
        debugTLSProbeTask?.cancel(); debugTLSProbeLease?.end()
        debugTLSProbeStatus = "正在停止连接检查，正在保存已有诊断。"
    }

    private func checkDebugTLSProbe(runID: UUID, token: UInt64, accountID: String,
                                    lease: GoogleDriveExecutionLease) throws {
        try checkIdentityOperation(token)
        guard debugTLSProbeID == runID, !ledgerUnavailable, !ledger.revokedLocally,
              ledger.accountID == accountID, oauth.hasCredential else { throw CancellationError() }
        try lease.check()
    }

    private func persistDebugTLSProbeReport(_ report: GoogleDriveTLSProbeReport) throws {
        let bytes = try TransportCodec.encode(report)
        guard !bytes.isEmpty, bytes.count <= 64 * 1_024 else { throw GoogleDriveTLSProbePersistenceError.unavailable }
        try GoogleDriveLocalFiles.prepare(directory)
        let target = directory.appendingPathComponent("tls-recovery-probe.json")
        var info = stat()
        if Darwin.lstat(target.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw GoogleDriveTLSProbePersistenceError.unavailable }
        } else if errno != ENOENT { throw GoogleDriveTLSProbePersistenceError.unavailable }
        let temporary = directory.appendingPathComponent(".tls-probe-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw GoogleDriveTLSProbePersistenceError.unavailable }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: bytes); try handle.synchronize()
        guard Darwin.rename(temporary.path, target.path) == 0 else { throw GoogleDriveTLSProbePersistenceError.unavailable }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw GoogleDriveTLSProbePersistenceError.unavailable }
        defer { Darwin.close(parent) }
        guard Darwin.fsync(parent) == 0 else { throw GoogleDriveTLSProbePersistenceError.unavailable }
    }
#endif

    func discover(manifests: [SegmentManifest], receivedIDs: Set<UUID>) {
        guard latestManifests != manifests || latestReceived != receivedIDs else { schedule(); return }
        if ledger.enabled, GoogleDriveSyncProgress.sourceChangeNeedsWake(previousManifests: latestManifests,
            previousReceivedIDs: latestReceived, manifests: manifests, receivedIDs: receivedIDs) {
            PhoneBackgroundSync.noteNewWork()
        }
        latestManifests = manifests; latestReceived = receivedIDs; progress.requestDiscovery()
        schedule()
    }
    /// Queues read-only validation behind existing archive publication.
    func observeVerifiedMetadata(onThrottle: (@Sendable (Int) -> Void)? = nil) {
        syncEvidence.observeVerifiedMetadata(onThrottle: onThrottle)
    }

    /// Also called after local transcript saves and when the app becomes active.
    func resume() {
        if ledger.enabled { PhoneBackgroundSync.noteNewWork() }
        if ledgerUnavailable { startMetadataRecoveryAtOpportunity(); return }
        progress.requestDiscovery(); schedule()
    }

    /// Unlike resume(), this entry is called only by the scene-active event.
    func didBecomeActive() {
        foregroundRecoveryAwaitingPath = networkPath == .unknown
        requestNetworkRecoveryOpportunity()
        resume()
    }

    func setAllowsCellularAccess(_ value: Bool) {
        GoogleDriveNetworkSettings.shared.setAllowsCellularAccess(value)
        allowsCellularAccess = value
        networkMonitor?.settingsDidChange()
        publish()
        schedule()
    }

    private func networkPathDidChange(_ path: GoogleDriveNetworkPath, restored: Bool) {
        networkPath = path
        publish()
        let foreground = foregroundRecoveryAwaitingPath
        if path != .unknown { foregroundRecoveryAwaitingPath = false }
        if restored || foreground { requestNetworkRecoveryOpportunity() }
    }

    /// A proxy change can leave NWPath satisfied. This explicit signal uses the
    /// same grant, policy, typed-failure and shared cooldown as automatic D5.
    func checkAfterNetworkRecovery() { requestNetworkRecoveryOpportunity() }

    private func nextNetworkRecoveryOpportunity(at date: Date) -> Date? {
        guard let shared = ledger.networkRecoveryOpportunityDate(at: date) else { return nil }
        if let due = ledger.retryAfter, due > date {
            // An item signal cannot bypass a newer library-wide HTTP backoff.
            return ledger.retryFailureKind == .recoverableNetwork ? shared : nil
        }
        guard let item = backgroundUploads?.networkRecoveryOpportunityDate(in: ledger, at: date) else { return nil }
        return max(shared, item)
    }

    private func requestNetworkRecoveryOpportunity() {
        guard isConfigured, !ledgerUnavailable, ledger.enabled, !ledger.revokedLocally,
              oauth.hasCredential, GoogleDriveNetworkSettings.shared.policy.permits(networkPath) else { return }
        let now = Date()
        if let due = nextNetworkRecoveryOpportunity(at: now), due > now {
            // One retained timer, independent of ordinary retry replacements. It
            // does not hold an execution lease or claim a system wake guarantee.
            guard networkRecoveryRetryAt == nil else { return }
            networkRecoveryRetryAt = due
            PhoneBackgroundSync.shared.schedule(earliestBeginDate: due)
            networkRecoveryRetry = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0.01, min(3_600, due.timeIntervalSinceNow)) * 1_000_000_000)) }
                catch { return }
                guard let self else { return }
                self.networkRecoveryRetry = nil; self.networkRecoveryRetryAt = nil
                self.requestNetworkRecoveryOpportunity(); self.publish()
            }
            publish(); return
        }
        networkRecoveryRequested = true
        schedule()
    }

    func transcriptDidSave(for manifest: SegmentManifest) {
        if ledger.enabled { PhoneBackgroundSync.noteNewWork() }
        do {
            if try preflightStore?.transcriptDidChange(for: manifest.id) == true { stopWork() }
        } catch { failClosed(error); return }
        progress.requestDiscovery(prioritizing: manifest.id); schedule()
    }

    func connect() {
        guard isConfigured, !isBusy, !ledgerUnavailable else { return }
        stopWork()
        backgroundUploads?.cancel()
        do { try change { try $0.setEnabled(false) } }
        catch { failClosed(error); return }
        let token = generation; isBusy = true
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.work = nil; self.isBusy = false; self.publish() } }
            do {
                self.activity = "正在打开 Google 系统登录。尚未启用录音上传。"
                let credential = try await self.oauth.authorize()
                try self.checkIdentityOperation(token)
                let account = try await GoogleDriveClient.account(http: self.http, token: credential.accessToken,
                    recoveryBudget: { try self.checkIdentityOperation(token); return 30 })
                try self.checkIdentityOperation(token)
                var candidate = self.ledger
                try candidate.bind(accountID: account.id, label: account.label)
                try self.persist(candidate); self.ledger = candidate; self.publish()
                // Persist the account fence first. If Keychain persistence fails,
                // no recording can be silently bound to another account later.
                try self.oauth.commit(credential, accountID: account.id)
                // Leave a failed credential commit's pending revocation intact.
                // Only a committed new login may supersede that local state.
                try candidate.recordReauthorization(accountID: account.id, label: account.label)
                try self.persist(candidate)
                try self.clearStopIntentAfterAuthorization()
                self.oauth.resumeUploadAccessAfterAuthorization()
                self.ledger = candidate; self.progress.clearOperationError(); self.publish()
                self.activity = self.ledger.recordingScope == nil
                    ? "已连接 Google 账户。请选择范围，再明确开启自动同步。"
                    : "已连接原账户。原授权范围保持不变，请点击继续同步。"
            } catch is CancellationError { }
            catch {
                guard self.generation == token else { return }
                self.progress.recordOperationFailure(error.localizedDescription,
                    isNetwork: GoogleDriveRetryFailureKind.classify(errorDomain: (error as NSError).domain, code: (error as NSError).code) == .recoverableNetwork,
                    needsCredential: (error as? GoogleDriveError) == .needsSignIn); self.publish()
            }
        }
    }
    func enable(_ mode: GoogleDriveRecordingScope) {
        guard !isBusy, isConfigured, isConnected, !ledgerUnavailable, !ledger.revokedLocally, ledger.recordingScope == nil else { return }
        do {
            let manifests = try repository.manifests(), received = try repository.receivedSegmentIDs()
            try change { try $0.authorize(mode, knownIDs: Set(manifests.map(\.id)).union(received)) }
            latestManifests = manifests; latestReceived = received; progress.requestDiscovery()
            PhoneBackgroundSync.noteNewWork()
            activity = "已按你选择的范围开启 Drive 自动同步。原录音和转写直接发送给 Google。"
            schedule()
        } catch { failClosed(error) }
    }
    func pause() {
        stopWork()
        backgroundUploads?.cancel()
        do { try change { try $0.setEnabled(false) }; activity = "已暂停 Drive 自动同步。已有云盘文件、原录音和队列均保留。" }
        catch { failClosed(error) }
    }
    func continueSync() {
        if ledgerUnavailable { startMetadataRecoveryAtOpportunity(); return }
        guard !isBusy, isConnected, !ledgerUnavailable, !ledger.revokedLocally else { return }
        do {
            try change { try $0.setEnabled(true) }
            PhoneBackgroundSync.noteNewWork(); progress.requestDiscovery(); progress.clearOperationError(); publish(); schedule()
        }
        catch { failClosed(error) }
    }
    func revoke() {
        stopWork()
        backgroundUploads?.cancel()
        oauth.suspendUploadAccess()
        // Apply the stop to memory before IO. The old enabled ledger must not
        // be classified as an automatically recoverable metadata interruption.
        ledger.revoke(remoteConfirmed: ledger.remoteRevocationConfirmed)
        do {
            try persistStopIntent()
            try change { $0.revoke() }
        } catch {
            progress.recordOperationFailure(error.localizedDescription); publish()
            activity = stopIntent != nil
                ? "本机已停止发送，停止意图已保存；撤销账本尚未保存，可重试撤销或重新连接原账户。"
                : "当前进程已阻止发送，但停止状态保存失败；尚未向 Google 撤销，请重试或在 Google 权限页移除此应用。"
            return
        }
        let token = generation; isBusy = true
        activity = "本机已停止发送，正在向 Google 撤销授权。云盘文件不会删除。"
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.work = nil; self.isBusy = false; self.publish() } }
            do {
                let confirmed = try await self.oauth.revoke()
                try self.checkIdentityOperation(token)
                try self.change { $0.revoke(remoteConfirmed: confirmed) }
                self.activity = confirmed ? "已停止同步，Google 已确认撤销此应用授权。云盘文件仍保留。"
                    : "已在本机断开。Google 尚未确认撤销，可到 Google 账户的第三方应用权限中核对。"
            } catch is CancellationError { }
            catch {
                guard self.generation == token else { return }
                self.publish()
                self.activity = "本机已停止发送；尚未确认 Google 端撤销。请在 Google 账户的第三方应用权限中移除此应用。"
                self.progress.recordOperationFailure(error.localizedDescription); self.publish()
            }
        }
    }
    func expireBackgroundWork() {
        workerDiagnosticState.noteCancellation(.leaseExpirationObserved)
        stopWork()
        if ledger.enabled { scheduleRetry(at: Date(timeIntervalSinceNow: 60)) }
    }
    func prepareBackgroundDelivery(isCancelled: @escaping @Sendable () -> Bool, systemGranted: Bool = false) async -> Bool {
        guard !isCancelled(), ledger.enabled else { return !ledger.enabled }
        let token = generation
        let existing: GoogleDriveExecutionBudget.ParentGrant.ExistingWork
        if work == nil { existing = .none }
        else if let executionLease { existing = executionLease.isSystemGranted ? .systemSync : .ordinarySync }
        else { existing = .identityOperation }
        var grant = GoogleDriveExecutionBudget.ParentGrant(now: ProcessInfo.processInfo.systemUptime, existingWork: existing, systemGranted: systemGranted)
        if ledgerUnavailable, work == nil {
            startMetadataRecoveryAtOpportunity(isCancelled: isCancelled, systemGranted: systemGranted,
                maximumDeadline: grant.deadline, continueAfterRecovery: false)
        }
        if let current = work {
            let previous = workCancellation
            workCancellation = { previous() || isCancelled() }
            // Keep the old lease's deadline. Only after it finishes may this
            // real parent use its one remaining, absolutely bounded round.
            await current.value
        }
        guard generation == token, !isCancelled(), !ledgerUnavailable else { return false }
        if hasPendingWork, work == nil,
           let deadline = grant.takeRound(at: ProcessInfo.processInfo.systemUptime, isCancelled: isCancelled()) {
            schedule(isCancelled: isCancelled, systemGranted: systemGranted, maximumDeadline: deadline)
        }
        if let current = work {
            // An ordinary event may have started another worker while the old
            // one was awaited. It receives cancellation, never a renewed lease.
            let previous = workCancellation
            workCancellation = { previous() || isCancelled() }
            await current.value
        }
        return generation == token && !isCancelled() && !ledgerUnavailable
    }

    /// Exact pre-lease admission used by schedule. Legacy terminal repair is
    /// metadata-only, so neither a terminal-only selection nor full retained-body
    /// capacity may conceal it. Native reservations remain enforced downstream.
    private func scheduledWorkAdmission() throws -> GoogleDriveBackgroundUploads.ScheduleAdmission {
        if networkRecoveryRequested || backgroundUploads?.isReconciling == true { return .ready }
        let repairDue = backgroundUploads?.hasDueLegacyMetadataWork(in: ledger) == true
        guard backgroundUploads?.canProcess == true || progress.needsDiscovery || repairDue else { return .waitingNative }
        if !progress.needsDiscovery, !repairDue, let backgroundUploads,
           try backgroundUploads.nextUpload(in: ledger, progress: progress, allowPipelineFill: true, preflight: preflightStore?.pin) == nil {
            return .waitingSelection
        }
        return .ready
    }

    private func schedule(isCancelled: @escaping @Sendable () -> Bool = { false }, systemGranted: Bool = false,
                          maximumDeadline: TimeInterval? = nil) {
        // A callback can request another round while an upload owns the caller's
        // task context. The new round selects and binds its own jobs below.
        GoogleDriveUploadTrace.$current.withValue(nil) {
            scheduleUnscoped(isCancelled: isCancelled, systemGranted: systemGranted, maximumDeadline: maximumDeadline)
        }
    }

    private func scheduleUnscoped(isCancelled: @escaping @Sendable () -> Bool, systemGranted: Bool,
                                  maximumDeadline: TimeInterval?) {
        recordWorker(.scheduleRequested)
        do { try reconcilePreflight() } catch { failClosed(error); return }
        guard isConfigured else { recordWorker(.notConfigured); publish(); return }
        guard !ledgerUnavailable else { recordWorker(.ledgerUnavailable); publish(); return }
        guard ledger.enabled else { recordWorker(.disabled); publish(); return }
        guard oauth.hasCredential else { recordWorker(.credentialUnavailable); publish(); return }
        guard backgroundEventHandoff == nil else { recordWorker(.handoffPending); return }
        guard backgroundUploads?.isUnavailable != true else {
            recordWorker(.queueUnavailable)
            failClosed(backgroundUploads?.metadataFailure ?? GoogleDriveLibraryError.invalidState); return
        }
        progress.retryIssuesIfDue()
        // A cold Watch/receipt event can own a genuine ordinary UIKit lease
        // without being a BGProcessing parent or this URLSession's handler.
        // Acquire that finite lease below before enumerating the persisted queue.
        do {
            let admission = try scheduledWorkAdmission()
            if admission != .ready {
                if let background = backgroundUploads,
                   let due = try? background.nextWorkDate(in: ledger, progress: progress, fallback: Date(timeIntervalSinceNow: 15)) { scheduleRetry(at: due) }
                recordWorker(admission == .waitingNative ? .waitingNative : .waitingSelection)
                publish(); return
            }
        } catch { failClosed(error); return }
        guard !isBusy, work == nil else { recordWorker(.waitingWorker); return }
        // Network backoff must not conceal newly received source metadata.
        // A metadata-only round below retains the same retry deadline and exits
        // before account/session requests. Ordinary retries remain deferred.
        if !networkRecoveryRequested, !progress.needsSnapshot, let due = ledger.retryAfter, due > Date() {
            scheduleRetry(at: due); recordWorker(.waitingRetry); return
        }
        retry?.cancel(); retry = nil; ordinaryRetryAt = nil
        let recoveryOpportunity = networkRecoveryRequested
        networkRecoveryRequested = false
        let token = generation, roundID = UUID()
        isBusy = true; workCancellation = isCancelled; executionID = roundID
        let lease = GoogleDriveExecutionLease.begin(systemGranted: systemGranted, maximumDeadline: maximumDeadline) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token, self.executionID == roundID else { return }
                self.workerDiagnosticState.noteCancellation(.leaseExpirationObserved)
                self.recordDiagnostic("lease_expired", "pending_count=\(self.pendingFileCount) native_count=\(self.backgroundUploads?.nativeActiveCount ?? 0) readback_count=\(self.backgroundUploads?.pendingReadbackCount ?? 0)")
                self.work?.cancel()
            }
        }
        executionLease = lease
        roundSequence &+= 1; roundStartedAt = ProcessInfo.processInfo.systemUptime
        workerDiagnosticState.begin(id: roundID, roundSequence: roundSequence, systemGranted: systemGranted,
            parentDeadline: maximumDeadline, leaseDeadline: lease.deadline, generation: token)
        nativeRegisteredThisRound = 0; scanVisitedThisRound = 0; setPhase(.idle)
        recordDiagnostic("round_started", "system_granted=\(systemGranted) budget_ms=\(Int(max(0, lease.deadline - ProcessInfo.processInfo.systemUptime) * 1_000)) pending_count=\(pendingFileCount) native_count=\(backgroundUploads?.nativeActiveCount ?? 0)")
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                lease.end()
                if self.generation == token, self.executionID == roundID {
                    self.workerDiagnosticState.updateLeaseDeadline(lease.deadline)
                    self.executionLease = nil; self.executionID = nil; self.work = nil; self.isBusy = false; self.publish()
                    self.recordDiagnostic("round_finished", "pending_count=\(self.pendingFileCount) native_count=\(self.backgroundUploads?.nativeActiveCount ?? 0) readback_count=\(self.backgroundUploads?.pendingReadbackCount ?? 0) zero_native_pending=\(self.pendingFileCount > 0 && self.backgroundUploads?.hasActiveUpload != true)")
                    if self.backgroundCallbackRequestedWork || self.networkRecoveryRequested {
                        self.backgroundCallbackRequestedWork = false
                        self.schedule()
                    } else if self.ledger.enabled && self.backgroundUploads?.hasActiveUpload != true
                        && (self.ledger.hasPendingFiles || self.progress.needsDiscovery) {
                        let next: Date?
                        if let due = self.ledger.retryAfter, due > Date() { next = due }
                        else { next = try? self.backgroundUploads?.nextWorkDate(in: self.ledger, progress: self.progress,
                            fallback: Date(timeIntervalSinceNow: 15)) }
                        if let next { self.scheduleRetry(at: next) }
                        self.recordDiagnostic("next_work", "scheduled=\(next != nil) item_retry_count=\(self.backgroundUploads?.itemRetries.count ?? 0) native_count=\(self.backgroundUploads?.nativeActiveCount ?? 0)")
                    } else if self.ledger.enabled, self.progress.hasIssues, let due = self.progress.issueRetryAt {
                        self.scheduleRetry(at: due)
                    }
                }
            }
            do {
                try self.checkWork(token)
                if let background = self.backgroundUploads, background.isReconciling {
                    self.setPhase(.recovery)
                    await background.recover(in: self.ledger, check: { try self.checkWork(token) })
                    try self.checkWork(token)
                    guard !background.isUnavailable else { throw background.metadataFailure ?? GoogleDriveLibraryError.invalidState }
                    guard !background.isReconciling else { return }
                }
                try self.reconcilePreflight()
                let background = systemGranted || UIApplication.shared.applicationState != .active
                // Warm receipt callbacks already supplied validated metadata. Admit
                // new sources without re-enumerating historical manifests/receipts.
                try self.admitCachedSources(maximum: background ? 16 : nil)
                if recoveryOpportunity, GoogleDriveNetworkSettings.shared.policy.permits(self.networkPath) {
                    try await self.recoverNetworkAtOpportunity(token: token, lease: lease)
                }
                if let due = self.ledger.retryAfter, due > Date() {
                    try await self.discoverSources(token: token)
                    self.recordDiagnostic("network_deferred", "source_metadata_admitted=true")
                    self.scheduleRetry(at: due)
                    return
                }
                try await GoogleDriveProgressFirstRound.run(background: background,
                    check: { try self.checkWork(token) },
                    advance: {
                        try await self.advanceKnownItems(token: token, lease: lease, discoverAfterFailure: background)
                    }, discover: {
                        try await self.discoverLocal(token: token)
                    })
                // Legacy repair and refill use only what remains of this lease.
                try await self.recheckLegacyQuarantine(token: token, lease: lease)
                try await self.deliverKnownItems(token: token, lease: lease,
                    maximumOperations: GoogleDriveBackgroundUploads.maximumRoundOperations - 4)
                try self.checkWork(token)
                if self.ledger.hasPendingFiles {
                    self.activity = "已将一批文件交给系统后台保存；每份完成后仍会核验云盘回执。"
                    PhoneBackgroundSync.shared.schedule(earliestBeginDate: Date(timeIntervalSinceNow: 15 * 60))
                } else { self.finishSuccessfulRound() }
            } catch is GoogleDriveUploadHandoff {
                self.activity = "已交给系统后台保存到你的 Drive；可锁屏，完成后仍需核验云盘回执。"
                PhoneBackgroundSync.shared.schedule(earliestBeginDate: Date(timeIntervalSinceNow: 15 * 60))
            } catch is GoogleDriveUploadRetryDeferred {
                self.activity = "后台保存尚未通过云盘回执核验，队列已保留，稍后按退避继续。"
            } catch is CancellationError {
                // stopWork already records and closes the old diagnostic round.
                // Never attach an old Task's catch to a newer execution.
                if self.workerDiagnosticState.matches(roundID) { self.recordWorker(.cancelled) }
                if self.generation == token { self.activity = "同步进度已保留。系统下次给予时间或回到 App 时会继续。" }
            } catch GoogleDriveError.interrupted {
                if self.workerDiagnosticState.matches(roundID) { self.recordWorker(.interrupted) }
                self.activity = "系统暂未给予足够执行时间，已保留队列，稍后自动继续。"
            } catch let failure as GoogleDriveMetadataIOError {
                guard self.generation == token else { return }
                self.failClosed(failure)
            } catch {
                guard self.generation == token else { return }
                self.workerDiagnosticState.failed(error, phase: self.currentPhase,
                    atMS: Int64((Date().timeIntervalSince1970 * 1_000).rounded(.towardZero)), reportSequence: self.workerReportSequence &+ 1)
                self.recordDiagnostic("round_failed", Self.fixedFailure(error))
                self.progress.recordOperationFailure(error.localizedDescription,
                    isNetwork: GoogleDriveRetryFailureKind.classify(errorDomain: (error as NSError).domain, code: (error as NSError).code) == .recoverableNetwork,
                    needsCredential: (error as? GoogleDriveError) == .needsSignIn); self.publish()
                do {
                    if let libraryError = error as? GoogleDriveLibraryError {
                        switch libraryError.syncFailureScope {
                        case .disableLibrary:
                            try self.change { try $0.setEnabled(false) }
                        case .retryLibrary:
                            try self.change { $0.recordFailure() }
                            self.activity = libraryError.localizedDescription
                        case .failItemOnly:
                            self.activity = libraryError.localizedDescription
                        }
                    } else if let drive = error as? GoogleDriveError, case .needsSignIn = drive {
                        try self.change { $0.recordCredentialRequired(); try $0.setEnabled(false) }
                    } else if case GoogleDriveError.apiFailure(_, let reason) = error {
                        try self.change { $0.recordFailure(apiReason: reason) }
                    } else {
                        let failure = error as NSError
                        try self.change { $0.recordFailure(kind: GoogleDriveRetryFailureKind.classify(errorDomain: failure.domain, code: failure.code)) }
                    }
                } catch { self.failClosed(error) }
            }
        }
    }
    private func advanceKnownItems(token: UInt64, lease: GoogleDriveExecutionLease,
                                   discoverAfterFailure: Bool) async throws {
        do {
            try await readBackCompletedBeforeDiscovery(token: token, lease: lease)
            try await deliverKnownItems(token: token, lease: lease, maximumOperations: 4)
        } catch let originalError {
            // A live transport failure must not make local discovery depend on
            // the next successful token/account request. Keep the known-item
            // progress-first turn, then use only this lease's remaining local
            // slice. An original cancellation, identity or metadata failure
            // still stops without attempting local recovery.
            let temporaryHTTP: Bool
            if case GoogleDriveError.http(let status) = originalError {
                temporaryHTTP = status == 408 || status == 429 || (500...599).contains(status)
            } else if case GoogleDriveError.apiFailure(let status, let reason) = originalError {
                temporaryHTTP = reason.isRateLimit || status == 408 || status == 429 || (500...599).contains(status)
            } else { temporaryHTTP = false }
            // Foreground rounds already performed their local slice first.
            guard discoverAfterFailure && (GoogleDriveHTTP.isNaturalTimeout(originalError) || temporaryHTTP) else { throw originalError }
            let failurePhase = currentPhase
            defer { setPhase(failurePhase) }
            do {
                try checkWork(token)
                try await discoverLocal(token: token)
                try checkWork(token)
            } catch { throw originalError }
            // Local admission is not remote progress and does not recover the
            // request. Preserve the original error and its diagnostic phase so
            // the normal durable backoff/authorization handling remains in force,
            // even when the remaining local slice fails or its lease expires.
            throw originalError
        }
    }

    private func recoverNetworkAtOpportunity(token: UInt64, lease: GoogleDriveExecutionLease) async throws {
        try checkWork(token)
        if let due = ledger.retryAfter, due > Date() {
            var candidate = ledger
            guard candidate.reserveNetworkRecovery() else {
                if candidate.retryFailureKind == .recoverableNetwork { requestNetworkRecoveryOpportunity() }
                return
            }
            try change { $0 = candidate }
            let reserved = ledger
            guard let accountID = ledger.accountID else { throw GoogleDriveError.needsSignIn }
            let client = GoogleDriveClient(http: http, oauth: oauth, accountID: accountID,
                check: { try self.checkWork(token) }, requestTimeout: { try lease.requestTimeout() }, phase: { self.setPhase($0) })
            try await client.validateAccount()
            try checkWork(token)
            try change { $0.completeNetworkRecovery(reserved: reserved) }
            return
        }
        guard let background = backgroundUploads else { return }
        guard background.hasNetworkRecoveryCandidate(in: ledger) else {
            // A queued round can observe a later item cooldown than the signal
            // did. Retain that signal at the current safe date instead of losing it.
            if nextNetworkRecoveryOpportunity(at: Date()) != nil { requestNetworkRecoveryOpportunity() }
            return
        }
        var candidate = ledger
        guard candidate.reserveNetworkRecoveryOpportunity() else { requestNetworkRecoveryOpportunity(); return }
        try change { $0 = candidate }
        try await background.runNetworkRecovery(ledger: { self.ledger }, check: { try self.checkWork(token) }) { selected in
            let pin = try GoogleDrivePreflightPin(ledger: self.ledger, selected: selected)
            try await self.checkCompletedSource(pin, token: token, stopAt: lease.deadline)
            let client = GoogleDriveClient(http: self.http, oauth: self.oauth, accountID: pin.accountID,
                check: { try self.checkWork(token) }, requestTimeout: { try lease.requestTimeout() }, phase: { self.setPhase($0) })
            try await client.validateAccount()
            try await client.verifyFolder(id: pin.folderID, libraryID: pin.libraryID)
            if let fileID = pin.artifact.fileID, let remote = try await client.metadata(fileID) {
                try await self.checkCompletedSource(pin, token: token, stopAt: lease.deadline)
                try self.commitVerified(remote, selected: selected, manifest: pin.manifest, artifact: pin.artifact,
                    accountID: pin.accountID, token: token)
            }
            // A successful missing-file observation restores only transport
            // eligibility. The normal path still queries the original session.
        }
    }

    private func recheckLegacyQuarantine(token: UInt64, lease: GoogleDriveExecutionLease) async throws {
        guard let background = backgroundUploads else { return }
        try await background.runLegacyQuarantineReadback(ledger: { self.ledger }, check: { try self.checkWork(token) }) { selected in
            let pin = try GoogleDrivePreflightPin(ledger: self.ledger, selected: selected)
            let correlation = GoogleDriveUploadCorrelation(segmentID: pin.manifest.id, kind: pin.artifact.kind,
                manifestSHA256: pin.manifest.sha256)
            try await GoogleDriveUploadTrace.$current.withValue(correlation) {
                try await self.checkCompletedSource(pin, token: token, stopAt: lease.deadline)
                let client = GoogleDriveClient(http: self.http, oauth: self.oauth, accountID: pin.accountID,
                    check: { try self.checkWork(token) }, requestTimeout: { try lease.requestTimeout() }, phase: { self.setPhase($0) })
                try await client.validateAccount()
                try await client.verifyFolder(id: pin.folderID, libraryID: pin.libraryID)
                let remote: GoogleDriveRemoteFile?
                if let fileID = pin.artifact.fileID { remote = try await client.metadata(fileID) }
                else { remote = nil } // no file ID was ever allocated: normal preparation remains necessary
                try await self.checkCompletedSource(pin, token: token, stopAt: lease.deadline)
                if let remote {
                    try self.commitVerified(remote, selected: selected, manifest: pin.manifest, artifact: pin.artifact,
                        accountID: pin.accountID, token: token)
                } else {
                    // A current source and a restored private folder with no remote
                    // artifact may resume normal preparation. This creates no receipt
                    // and bypasses neither fingerprinting nor the strict upload path.
                    guard background.permitsMissingRemoteRequeue(for: selected.segmentID,
                        artifactKey: selected.artifactKey, in: self.ledger) else { throw GoogleDriveLibraryError.metadataIncomplete }
                    try background.clearItemRetry(for: selected.segmentID, artifactKey: selected.artifactKey)
                    self.recordDiagnostic("legacy_item_requeued", "remote_missing=true")
                }
            }
        }
    }
    /// A bounded ledger turn precedes all cold enumeration. It retains the exact
    /// session, per-item quarantine and strict durable receipt boundaries.
    private func deliverKnownItems(token: UInt64, lease: GoogleDriveExecutionLease,
                                   maximumOperations: Int) async throws {
        guard self.ledger.hasPendingFiles else {
            try self.checkWork(token)
            self.finishSuccessfulRound()
            return
        }
        if let background = self.backgroundUploads,
           try background.nextUpload(in: self.ledger, progress: self.progress, allowPipelineFill: true, preflight: self.preflightStore?.pin) == nil {
            // Discovery may finish while all bodies are active/deferred.
            // No account/folder request is useful without an actual item.
            return
        }
        guard let accountID = self.ledger.accountID else { throw GoogleDriveError.needsSignIn }
        let client = GoogleDriveClient(http: self.http, oauth: self.oauth, accountID: accountID,
            check: { [weak self] in guard let self else { throw CancellationError() }; try self.checkWork(token) },
            requestTimeout: { [weak self] in
                guard let self else { throw CancellationError() }
                try self.checkWork(token)
                return try lease.requestTimeout()
            }, phase: { [weak self] phase in self?.setPhase(phase) })
        try await client.validateAccount()
        if self.ledger.folderID == nil {
            let id = try await client.generateID(); try self.checkWork(token)
            try self.change { try $0.allocateFolder(id) }
        }
        let folder = self.ledger.folderID!, libraryID = self.ledger.libraryID
        try await self.backgroundUploads?.runAvailable(ledger: { self.ledger }, progress: { self.progress },
            check: { try self.checkWork(token) }, preflight: { self.preflightStore?.pin }, maximumOperations: maximumOperations) { selected in
            try self.checkWork(token)
            guard let job = self.ledger.jobs.first(where: { $0.id == selected.segmentID }),
                  var artifact = job.artifacts.first(where: { $0.key == selected.artifactKey && $0.verifiedAt == nil }) else {
                throw GoogleDriveLibraryError.invalidState
            }
            let correlation = GoogleDriveUploadCorrelation(segmentID: job.id, kind: artifact.kind,
                manifestSHA256: job.manifest.sha256)
            try await GoogleDriveUploadTrace.$current.withValue(correlation) {
                if self.backgroundUploads?.completedRecord(for: job.id, artifactKey: artifact.key) == nil {
                    try self.preflightStore?.capture(ledger: self.ledger, selected: selected)
                }
                if artifact.fileID == nil {
                    let id = try await client.generateID(); try self.checkWork(token)
                    try self.change { try $0.allocateFile(segmentID: job.id, key: artifact.key, fileID: id) }
                    artifact = self.ledger.jobs.first(where: { $0.id == job.id })!.artifacts.first(where: { $0.key == selected.artifactKey })!
                }
                let binding = try GoogleDrivePreflightPin(ledger: self.ledger, selected: selected)
                try await self.checkCompletedSource(binding, token: token, stopAt: lease.deadline)
                let local = self.localURL(job: job, artifact: artifact)
                let expected = artifact, stopAt = lease.deadline
                self.setPhase(.fingerprint)
                try await self.localIO {
                    if expected.kind == .manifest {
                        try GoogleDriveLocalFiles.stage(TransportCodec.encode(GoogleDriveLibraryLedger.exportManifest(job.manifest)), to: local)
                    }
                    let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw GoogleDriveLibraryError.changedManifest }
                    let fingerprint = try RecordingRepository.fingerprint(of: local, while: {
                        !Task.isCancelled && ProcessInfo.processInfo.systemUptime < stopAt
                    })
                    guard fingerprint.sha256 == expected.sha256, fingerprint.byteCount == expected.byteCount else { throw GoogleDriveLibraryError.changedManifest }
                }
                try self.checkWork(token)
                try await client.ensureFolder(id: folder, libraryID: libraryID)
                self.activity = "正在直接保存到你的 Drive：原录音 \(self.ledger.savedAudioCount)/\(self.ledger.jobs.count) 段。"
                let remote = try await client.upload(file: local, artifact: artifact, manifest: job.manifest,
                    folderID: folder, libraryID: libraryID, backgroundHandoff: { request, source, offset in
                        try self.checkWork(token)
                        guard let background = self.backgroundUploads,
                              let current = self.ledger.jobs.first(where: { $0.id == job.id })?.artifacts.first(where: { $0.key == expected.key }) else {
                            throw GoogleDriveLibraryError.invalidState
                        }
                        // The normal client has now checked file/session
                        // metadata and still needs bytes. Consume the prior
                        // uncertain completion once, using existing durable
                        // exponential backoff rather than rapid native PUTs.
                        if background.completedRecord(for: job.id, artifactKey: expected.key) != nil {
                            try background.deferUnverifiedRetry(for: job.id, artifactKey: expected.key)
                        }
                        let context = try GoogleDriveUploadContext(ledger: self.ledger, manifest: job.manifest, artifact: current)
                        try await background.start(request: request, file: source, offset: offset, context: context,
                            isAuthorized: { self.generation == token && context.isAuthorized(in: self.ledger) },
                            check: { try lease.check() })
                        try self.preflightStore?.clear(matching: job.id, key: expected.key)
                        // Once native registration is durable, expiration of
                        // this Swift round must not cancel the upload.
                    }, saveSession: { url in
                        try self.checkWork(token)
                        try self.change { try $0.recordSession(segmentID: job.id, key: expected.key, url: url) }
                    })
                try self.commitVerified(remote, selected: selected, manifest: job.manifest,
                    artifact: expected, accountID: accountID, token: token)
            }
        }
    }

    private func readBackCompletedBeforeDiscovery(token: UInt64, lease: GoogleDriveExecutionLease) async throws {
        guard let background = backgroundUploads else { return }
        try await background.runCompletedReadback(ledger: { self.ledger }, progress: { self.progress },
            check: { try self.checkWork(token) }) { selected in
            let binding = try GoogleDrivePreflightPin(ledger: self.ledger, selected: selected)
            let correlation = GoogleDriveUploadCorrelation(segmentID: binding.manifest.id, kind: binding.artifact.kind,
                manifestSHA256: binding.manifest.sha256)
            try await GoogleDriveUploadTrace.$current.withValue(correlation) {
                guard let prior = background.completedRecord(for: selected.segmentID, artifactKey: selected.artifactKey),
                      prior.context.isAuthorized(in: self.ledger) else { throw GoogleDriveLibraryError.notAuthorized }
                try await self.checkCompletedSource(binding, token: token, stopAt: lease.deadline)
                self.recordDiagnostic("completed_readback_started", "ready_count=\(background.readyReadbackCount) source_snapshot_pending=\(self.progress.needsSnapshot)")
                let client = GoogleDriveClient(http: self.http, oauth: self.oauth, accountID: binding.accountID,
                    check: { try self.checkWork(token) }, requestTimeout: { try self.checkWork(token); return try lease.requestTimeout() },
                    phase: { self.setPhase($0) })
                try await client.validateAccount()
                // Read-only validation must never create a missing/shared folder.
                try await client.verifyFolder(id: binding.folderID, libraryID: binding.libraryID)
                let readBack = try await client.readBackCompletedUpload(artifact: binding.artifact, manifest: binding.manifest)
                if case .sessionExpired = readBack {
                    // A dead session must not keep winning the audio turn. The file
                    // ID stays so a later turn can open a new session.
                    try self.checkWork(token)
                    try self.change { try $0.recordSession(segmentID: selected.segmentID, key: selected.artifactKey, url: nil) }
                }
                guard case .remote(let remote) = readBack else {
                    try self.checkWork(token)
                    try background.deferUnverifiedRetry(for: selected.segmentID, artifactKey: selected.artifactKey)
                    return
                }
                // Metadata is an observation, not an atomic cross-network snapshot.
                // Refuse an intervening local source/receipt/version change rather
                // than committing a stale binding from before the HTTP awaits.
                try await self.checkCompletedSource(binding, token: token, stopAt: lease.deadline)
                try self.commitVerified(remote, selected: selected, manifest: binding.manifest,
                    artifact: binding.artifact, accountID: binding.accountID, token: token)
            }
        }
    }
    private func checkCompletedSource(_ binding: GoogleDrivePreflightPin, token: UInt64,
                                      stopAt: TimeInterval) async throws {
        let repository = repository, transcripts = transcriptRepository, previous = ledger
        setPhase(.snapshot)
        let current = try await localIO {
            try Self.checkLocalBudget(stopAt)
            let valid = try binding.completedSourceIsCurrent(in: repository, transcripts: transcripts, ledger: previous)
            try Self.checkLocalBudget(stopAt)
            return valid
        }
        try checkWork(token)
        guard current, try binding.reconciled(in: ledger) != nil else { throw GoogleDriveLibraryError.changedManifest }
    }
    /// Both byte delivery and metadata-only completion converge on this exact
    /// durable boundary. A native HTTP status/session hint is never a receipt.
    private func commitVerified(_ remote: GoogleDriveRemoteFile, selected: GoogleDriveSyncProgress.UploadChoice,
                                manifest: SegmentManifest, artifact: GoogleDriveArtifact,
                                accountID: String, token: UInt64) throws {
        try checkWork(token)
        guard let live = ledger.jobs.first(where: { $0.id == manifest.id }), live.manifest == manifest,
              live.artifacts.contains(where: { $0.key == artifact.key && $0.fileID == artifact.fileID && $0.verifiedAt == nil }) else {
            throw GoogleDriveLibraryError.changedManifest
        }
        let prior = backgroundUploads?.completedRecord(for: manifest.id, artifactKey: artifact.key)
        if let prior, !prior.context.isAuthorized(in: ledger) { throw GoogleDriveLibraryError.changedManifest }
        setPhase(.strictVerify)
        try change { try $0.recordVerified(segmentID: manifest.id, key: artifact.key, file: remote, in: accountID) }
        workerDiagnosticState.didProgress(phase: .strictVerify)
        syncEvidence.observedCallback(segmentID: manifest.id, artifactKey: artifact.key)
        publishSyncEvidence()
        let matchesAttempt = prior?.context.manifest.id == manifest.id && prior?.context.artifact.key == artifact.key
        let attempt = matchesAttempt ? (prior?.nonce.uuidString.lowercased() ?? "none") : "none"
        let correlation = GoogleDriveUploadCorrelation(segmentID: manifest.id, kind: artifact.kind, manifestSHA256: manifest.sha256)
        GoogleDriveUploadTrace.$current.withValue(correlation) {
            recordDiagnostic("remote_verified", "attempt=\(attempt) kind=\(artifact.kind.rawValue) saved_audio_count=\(ledger.savedAudioCount) saved_transcript_count=\(ledger.savedTranscriptCount)")
        }
        if let prior, matchesAttempt { try backgroundUploads?.discardCompleted(nonce: prior.nonce) }
        try backgroundUploads?.clearItemRetry(for: manifest.id, artifactKey: artifact.key)
        try progress.didVerify(selected, in: ledger.jobs)
    }
    /// Source admission contains no audio/transcript reads or HTTP requests.
    /// Keep it independent of the prepared upload's network progress; only the
    /// bounded derived-record scan below may wait behind an exact preflight pin.
    private func admitCachedSources(maximum: Int?) throws {
        guard let manifests = latestManifests, let received = latestReceived else { return }
        let known = Set(ledger.jobs.map(\.id))
        let added = manifests.filter { !known.contains($0.id) && received.contains($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
        guard !added.isEmpty else { return }
        let admitted = Array(added.prefix(maximum ?? added.count))
        try change { try $0.discover(manifests: admitted, receivedIDs: received) }
    }
    private func discoverSources(token: UInt64) async throws {
        guard progress.needsSnapshot, let executionLease else { return }
        let repository = repository, request = progress.snapshot
        let stopAt = executionLease.deadline
        let cursorFile = directory.appendingPathComponent("source-snapshot-cursor.json")
        setPhase(.snapshot)
        let previous = ledger
        var cursor = try await localIO {
            try GoogleDriveSourceSnapshotCursor.loadOrCreate(file: cursorFile, repository: repository,
                ledger: previous, write: { try GoogleDriveLocalFiles.write($0, to: cursorFile) })
        }
        let sliceEnd = min(stopAt, ProcessInfo.processInfo.systemUptime + 3)
        while let id = cursor.nextID, ProcessInfo.processInfo.systemUptime < sliceEnd {
            try checkWork(token)
            let item = try await localIO {
                try Self.checkLocalBudget(stopAt)
                return try GoogleDriveSourceSnapshotCursor.readSource(id, repository: repository)
            }
            try checkWork(token)
            if let item {
                var candidate = ledger
                try candidate.discover(manifests: [item], receivedIDs: [item.id])
                if candidate != ledger { try persist(candidate); ledger = candidate }
            }
            // Commit the ledger first. If cursor persistence fails or a process
            // stops between files, replay is idempotent and cannot skip admission.
            try cursor.advance(after: id, awaitingReceipt: item == nil, write: { try GoogleDriveLocalFiles.write($0, to: cursorFile) })
        }
        guard cursor.nextID == nil else { publish(); return }
        let hints = try await localIO {
            let names = (try? FileManager.default.contentsOfDirectory(atPath:
                repository.root.appendingPathComponent("transcripts", isDirectory: true).path)) ?? []
            return GoogleDriveSyncProgress.transcriptHints(fileNames: names)
        }
        try checkWork(token)
        // Only a complete cursor establishes discovery coverage. New events
        // arriving during IO retain their revision and request another pass.
        try GoogleDriveSourceSnapshotCursor.remove(file: cursorFile)
        progress.acceptSnapshot(ledger.jobs.map(\.manifest), previousIDs: cursor.previousIDs, request: request, transcriptHints: hints)
        recordDiagnostic("sources_admitted", "authorized_count=\(ledger.jobs.count) transcript_scan_pending=\(progress.remaining.count)")
        publish()
    }
    private func discoverLocal(token: UInt64) async throws {
        guard progress.needsDiscovery else { return }
        try await discoverSources(token: token)
        let transcripts = transcriptRepository, staging = directory.appendingPathComponent("staged", isDirectory: true)
        guard let executionLease else { throw CancellationError() }
        let observedRevision = progress.revision, stopAt = executionLease.deadline
        // Never spend the whole execution budget scanning a large historical
        // library. Persist each batch, then give audio delivery its turn.
        setPhase(.transcriptScan)
        let discoveryUntil = min(stopAt - 8, ProcessInfo.processInfo.systemUptime + 3)
        var visited = 0
        while visited < 16, let manifest = progress.remaining.first,
              ProcessInfo.processInfo.systemUptime < discoveryUntil {
            let previous = ledger
            let updated = try await localIO {
                try Self.checkLocalBudget(stopAt)
                var candidate = previous
                let inspection = GoogleDriveSyncProgress.inspectTranscript(repository: transcripts, manifest: manifest)
                if let transcript = inspection.transcript {
                    try candidate.discoverTranscript(transcript, for: manifest)
                    let json = try TransportCodec.encode(transcript)
                    let text = GoogleDriveLibraryLedger.readableTranscript(transcript, manifest: manifest)
                    for (kind, bytes) in [(GoogleDriveArtifact.Kind.transcriptJSON, json), (.transcriptText, text)] {
                        try Self.checkLocalBudget(stopAt)
                        let target = staging.appendingPathComponent(manifest.id.uuidString.lowercased() + "-" + kind.rawValue + "-" + GoogleDriveLibraryLedger.digest(bytes))
                        try GoogleDriveLocalFiles.stage(bytes, to: target)
                    }
                }
                return (candidate, inspection.issue)
            }
            try checkWork(token)
            if updated.0 != ledger { try persist(updated.0); ledger = updated.0 }
            // A bad derived record stays visible but does not block valid audio
            // or make the next execution budget replay this same queue head.
            try progress.finishRecord(manifest.id, issue: updated.1); visited += 1; scanVisitedThisRound += 1
        }
        progress.finishSlice(observedRevision: observedRevision)
        publish()
    }
    /// Detached IO receives cancellation from its awaiting owner and checks a
    /// monotonic deadline between records/chunks. Pause cannot start new upload.
    private func localIO<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    nonisolated private static func checkLocalBudget(_ stopAt: TimeInterval) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < stopAt else { throw CancellationError() }
    }
    private func finishSuccessfulRound() {
        let phase = progress.finishSuccessfulRound(hasPendingFiles: ledger.hasPendingFiles)
        if !progress.needsDiscovery {
            do { try change { $0.clearRetry() } }
            catch { failClosed(error); return }
        }
        switch phase {
        case .discovering:
            activity = "当前已发现的文件已核验，仍在检查其余已有转写，尚未全部完成。"
        case .uploading:
            activity = "仍有已发现的文件等待保存到 Drive。"
        case .transcriptIssues(let count):
            activity = "原音频与可用转写已核验；另有 \(count) 段转写需要修复，稍后会自动重查。"
        case .complete:
            activity = "Drive 已保存当前范围内的原录音与已有转写。Agent 是否可读需要在对应 Agent 中另行验证。"
        }
        publish()
    }
    private func localURL(job: GoogleDriveLibraryJob, artifact: GoogleDriveArtifact) -> URL {
        artifact.kind == .audio ? repository.audioURL(for: job.manifest)
            : stagedURL(segmentID: job.id, kind: artifact.kind, hash: artifact.sha256)
    }
    private func stagedURL(segmentID: UUID, kind: GoogleDriveArtifact.Kind, hash: String) -> URL {
        directory.appendingPathComponent("staged", isDirectory: true)
            .appendingPathComponent(segmentID.uuidString.lowercased() + "-" + kind.rawValue + "-" + hash)
    }
    private func checkWork(_ token: UInt64) throws {
        try checkIdentityOperation(token)
        guard ledger.enabled else { workerDiagnosticState.noteCancellation(.libraryDisabled, generation: token); throw CancellationError() }
        guard !ledgerUnavailable else { workerDiagnosticState.noteCancellation(.ledgerUnavailable, generation: token); throw CancellationError() }
        guard !workCancellation() else { workerDiagnosticState.noteCancellation(.parentCancellationObserved, generation: token); throw CancellationError() }
        guard let executionLease else { workerDiagnosticState.noteCancellation(.leaseUnavailable, generation: token); throw CancellationError() }
        do { try executionLease.check() }
        catch {
            workerDiagnosticState.noteCancellation(ProcessInfo.processInfo.systemUptime >= executionLease.deadline ? .deadlineReached : .leaseCheckFailed, generation: token)
            throw error
        }
    }
    private func checkIdentityOperation(_ token: UInt64) throws {
        if Task.isCancelled { workerDiagnosticState.noteCancellation(.taskCancellationObserved, generation: token) }
        try Task.checkCancellation()
        guard generation == token else { workerDiagnosticState.noteCancellation(.generationChanged, generation: token); throw CancellationError() }
    }
    private func stopWork() {
#if DEBUG
        cancelDebugTLSProbe()
#endif
        metadataRecovery.cancel()
        if let id = workerDiagnosticState.execution?.id {
            workerDiagnosticState.noteCancellation(.stopRequested)
            recordWorker(.cancelled)
            executionLease?.end()
            recordWorker(.roundFinished)
            workerDiagnosticState.finish(id: id)
        }
        networkRecoveryRequested = false; foregroundRecoveryAwaitingPath = false
        networkRecoveryRetry?.cancel(); networkRecoveryRetry = nil; networkRecoveryRetryAt = nil; ordinaryRetryAt = nil
        generation &+= 1; work?.cancel(); executionLease?.end(); executionLease = nil; executionID = nil
        work = nil; retry?.cancel(); retry = nil; isBusy = false
    }
    private func scheduleRetry(at date: Date) {
        guard ledger.enabled, !ledgerUnavailable, oauth.hasCredential else { return }
        PhoneBackgroundSync.shared.schedule(earliestBeginDate: date)
        let timerDate = GoogleDriveRetrySchedule.timerDate(requested: date)
        ordinaryRetryAt = timerDate; publish()
        retry?.cancel()
        retry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, timerDate.timeIntervalSinceNow) * 1_000_000_000)) }
            catch { return }
            self?.ordinaryRetryAt = nil; self?.schedule()
        }
    }
    private func persist(_ value: GoogleDriveLibraryLedger) throws {
        try value.validate()
        try GoogleDriveLocalFiles.write(TransportCodec.encode(value), to: ledgerURL,
            beforeRename: { try self.beforeMetadataRename?(self.ledgerURL) })
    }
    private var stopIntentURL: URL { directory.appendingPathComponent("stop-intent.json") }
    private func readStopIntent() throws -> GoogleDriveStopIntent? {
        var info = stat()
        if Darwin.lstat(stopIntentURL.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw GoogleDriveMetadataIO.syscallFailure()
        }
        return try TransportCodec.decode(GoogleDriveStopIntent.self,
            from: GoogleDriveLocalFiles.read(stopIntentURL, maximum: 4_096))
    }
    private func persistStopIntent() throws {
        let intent: GoogleDriveStopIntent
        if let existing = try readStopIntent() {
            try existing.validate(against: ledger); intent = existing
        } else { intent = GoogleDriveStopIntent(ledger: ledger) }
        let file = stopIntentURL
        try GoogleDriveLocalFiles.write(TransportCodec.encode(intent), to: file,
            beforeRename: { try self.beforeMetadataRename?(file) })
        stopIntent = intent
    }
    private func clearStopIntentAfterAuthorization() throws {
        guard let expected = stopIntent else { return }
        guard try readStopIntent() == expected else { throw GoogleDriveLibraryError.invalidState }
        guard Darwin.unlink(stopIntentURL.path) == 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
        defer { Darwin.close(parent) }
        guard Darwin.fsync(parent) == 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
        stopIntent = nil
    }
    private func change(_ mutation: (inout GoogleDriveLibraryLedger) throws -> Void) throws {
        var candidate = ledger; try mutation(&candidate); try persist(candidate); ledger = candidate
        try backgroundUploads?.cancelUnauthorized(in: candidate)
        try reconcilePreflight()
        publish()
    }
    private func reconcilePreflight() throws {
        try preflightStore?.reconcileSources(in: ledger, manifests: latestManifests, receivedIDs: latestReceived)
        if let pin = preflightStore?.pin,
           backgroundUploads?.hasRegisteredRecord(for: pin.manifest.id, artifactKey: pin.artifact.key, in: ledger) == true {
            try preflightStore?.clear(matching: pin.manifest.id, key: pin.artifact.key)
        }
    }
    private func setPhase(_ value: GoogleDrivePreflightPhase) {
        currentPhase = value; phaseStartedAt = ProcessInfo.processInfo.systemUptime
        recordWorker(.phaseChanged)
    }
    private static func fixedFailure(_ error: Error) -> String {
        if let value = error as? GoogleDriveLibraryError {
            switch value {
            case .invalidState: return "error_class=library_invalid_state"
            case .changedAccount: return "error_class=changed_account"
            case .changedManifest: return "error_class=changed_manifest"
            case .notAuthorized: return "error_class=not_authorized"
            case .invalidRemoteFile: return "error_class=invalid_remote_file"
            case .metadataIncomplete: return "error_class=metadata_incomplete"
            case .invalidRemoteFolder: return "error_class=invalid_remote_folder"
            case .notConfigured: return "error_class=not_configured"
            }
        }
        if let value = error as? GoogleDriveError {
            switch value {
            case .http(let code): return "error_class=http http_status=\(code)"
            case .apiFailure(let code, let reason): return "error_class=http http_status=\(code) api_reason=\(reason.rawValue)"
            case .needsSignIn: return "error_class=needs_sign_in"
            case .credentials: return "error_class=credentials"
            case .invalidResponse: return "error_class=invalid_response"
            case .expiredSession: return "error_class=expired_session"
            case .invalidResumableOffset: return "error_class=invalid_resumable_offset"
            case .interrupted: return "error_class=interrupted"
            case .cancelled: return "error_class=cancelled"
            case .unavailable: return "error_class=unavailable"
            }
        }
        let value = error as NSError
        let category = value.domain == NSURLErrorDomain ? "network" : (value.domain == NSCocoaErrorDomain ? "local_io" : "other")
        return "error_class=\(category) error_code=\(value.code)"
    }
    private func failClosed(_ failure: Error) {
        stopWork(); ledgerUnavailable = true; isEnabled = false
        let recoverable = metadataRecovery.block(failure, ledger: ledger,
            hasTrustedQueue: metadataLoaded && backgroundUploads != nil
                && (backgroundUploads?.isUnavailable != true || backgroundUploads?.canRecoverMetadata == true))
        // Retain exact native tasks during a temporary metadata interruption.
        if !recoverable { backgroundUploads?.cancel() }
        progress.recordOperationFailure(failure.localizedDescription); publish()
    }

    /// Only resume/continue or a real BGProcessing parent may enter this path.
    /// Diagnostics, exports, discovery and retry timers never repair metadata.
    private func startMetadataRecoveryAtOpportunity(isCancelled: @escaping @Sendable () -> Bool = { false },
        systemGranted: Bool = false, maximumDeadline: TimeInterval? = nil, continueAfterRecovery: Bool = true) {
        guard ledgerUnavailable, metadataRecovery.canStartAtOpportunity,
              work == nil, backgroundEventHandoff == nil, !isCancelled(),
              ledger.enabled, !ledger.revokedLocally, oauth.hasCredential,
              let backgroundUploads, let preflightStore else { return }
        let token = generation, roundID = UUID()
        let lease = GoogleDriveExecutionLease.begin(systemGranted: systemGranted, maximumDeadline: maximumDeadline) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token, self.executionID == roundID else { return }
                self.workerDiagnosticState.noteCancellation(.leaseExpirationObserved)
                self.recordDiagnostic("lease_expired", "metadata_recovery=true")
                self.work?.cancel()
            }
        }
        executionLease = lease; executionID = roundID; isBusy = true
        roundSequence &+= 1; roundStartedAt = ProcessInfo.processInfo.systemUptime
        workerDiagnosticState.begin(id: roundID, roundSequence: roundSequence, systemGranted: systemGranted,
            parentDeadline: maximumDeadline, leaseDeadline: lease.deadline, generation: token, kind: .metadataRecovery)
        nativeRegisteredThisRound = 0; scanVisitedThisRound = 0; setPhase(.recovery)
        recordDiagnostic("round_started", "metadata_recovery=true system_granted=\(systemGranted)")
        work = Task { [weak self] in
            guard let self else { lease.end(); return }
            var recovered = false
            defer {
                let deadline = lease.deadline
                lease.end()
                if self.generation == token, self.executionID == roundID {
                    self.workerDiagnosticState.updateLeaseDeadline(deadline)
                    self.work = nil; self.executionID = nil; self.executionLease = nil; self.isBusy = false
                    self.publish()
                    self.recordDiagnostic("round_finished", "metadata_recovery=true recovered=\(recovered)")
                    if recovered && continueAfterRecovery && !isCancelled() {
                        // Normal work shares the original remaining deadline.
                        self.schedule(isCancelled: isCancelled, systemGranted: systemGranted, maximumDeadline: deadline)
                    }
                }
            }
            recovered = await self.metadataRecovery.recover(currentLedger: { self.ledger }, readLedger: {
                try GoogleDriveMetadataIO.validateDirectory(self.directory)
                return try TransportCodec.decode(GoogleDriveLibraryLedger.self,
                    from: GoogleDriveMetadataIO.read(self.ledgerURL, maximum: 32 * 1_024 * 1_024))
            }, validateMetadata: { ledger in
                let restoredPin = try GoogleDriveMetadataIO.perform { try GoogleDrivePreflightPinStore(directory: self.directory) }
                guard restoredPin.pin == preflightStore.pin else { throw GoogleDriveLibraryError.invalidState }
                if let pin = restoredPin.pin, try pin.reconciled(in: ledger) != pin { throw GoogleDriveLibraryError.invalidState }
                try backgroundUploads.validateRecoveryMetadata(in: ledger)
            }, restoreNative: { ledger, check in
                try await backgroundUploads.recoverMetadata(in: ledger, check: check)
            }, check: {
                guard self.generation == token else {
                    self.workerDiagnosticState.noteCancellation(.generationChanged, generation: token)
                    throw CancellationError()
                }
                guard !isCancelled() else {
                    self.workerDiagnosticState.noteCancellation(.parentCancellationObserved, generation: token)
                    throw CancellationError()
                }
                do { try lease.check() }
                catch {
                    self.workerDiagnosticState.noteCancellation(ProcessInfo.processInfo.systemUptime >= lease.deadline
                        ? .deadlineReached : .leaseCheckFailed, generation: token)
                    throw error
                }
            }, onFailure: { error in
                guard self.generation == token, self.workerDiagnosticState.matches(roundID) else { return }
                if error is CancellationError {
                    if Task.isCancelled { self.workerDiagnosticState.noteCancellation(.taskCancellationObserved, generation: token) }
                    self.recordWorker(.cancelled)
                } else if case GoogleDriveError.interrupted = error {
                    self.recordWorker(.interrupted)
                } else {
                    self.workerDiagnosticState.failed(error, phase: self.currentPhase,
                        atMS: Int64((Date().timeIntervalSince1970 * 1_000).rounded(.towardZero)), reportSequence: self.workerReportSequence &+ 1)
                    self.recordDiagnostic("round_failed", Self.fixedFailure(error))
                }
            })
            guard recovered, self.generation == token, !isCancelled() else { return }
            self.ledgerUnavailable = false; self.progress.clearOperationError(); self.progress.requestDiscovery()
            self.recordDiagnostic("metadata_revalidated", "grant_unchanged=true native_reconciled=true")
        }
    }

    private func publish() {
        // A retained capacity error must not hide a newer credential, network
        // or local-metadata failure. Use it only while it is still current.
        apiFailureReason = !ledgerUnavailable &&
            (progress.operationError == nil || progress.operationError == ledger.apiFailureReason?.explanation)
            ? ledger.apiFailureReason : nil
        error = progress.errorMessage ?? ledger.apiFailureReason?.explanation
        isConnected = oauth.hasCredential; isEnabled = !ledgerUnavailable && ledger.enabled
        let itemFailure = backgroundUploads?.retryPresentation(in: ledger)
        isNetworkFailure = progress.operationErrorIsNetwork || (ledger.enabled &&
            ((ledger.retryAfter != nil && ledger.retryFailureKind == .recoverableNetwork) || itemFailure?.networkFailure == true))
        needsCredential = progress.operationErrorNeedsCredential || ledger.credentialRequiredAt != nil || (!oauth.hasCredential && ledger.recordingScope != nil && !ledger.revokedLocally)
        lastFailureAt = [progress.lastFailureAt, ledger.lastFailureAt, itemFailure?.lastFailureAt].compactMap { $0 }.max()
        nextPlannedAttemptAt = isEnabled && oauth.hasCredential ? GoogleDriveRetrySchedule.nextAttempt(isBusy: isBusy,
            ordinary: ordinaryRetryAt, recovery: networkRecoveryRetryAt,
            library: ledger.retryAfter, item: backgroundUploads?.earliestRetryAt(in: ledger)) : nil
        canCheckNetworkRecovery = isEnabled && oauth.hasCredential &&
            nextNetworkRecoveryOpportunity(at: Date()) != nil
            && GoogleDriveNetworkSettings.shared.policy.permits(networkPath)
        allowsCellularAccess = GoogleDriveNetworkSettings.shared.allowsCellularAccess
        isWaitingForWiFi = isConnected && isEnabled && (ledger.hasPendingFiles || progress.hasWork)
            && GoogleDriveNetworkSettings.shared.policy.isWaitingForWiFi(on: networkPath)
        canRetryRevocation = isRevocationPending && oauth.hasRevocationCredential
        accountLabel = ledger.accountLabel ?? "尚未连接 Google 账户"; scope = ledger.recordingScope
        authorizedManifests = ledger.jobs.map(\.manifest)
        cloudConfirmedRecordingIDs = ledgerUnavailable || ledger.folderID == nil ? [] : Set(ledger.jobs.compactMap { job in
            let recordingFiles = job.artifacts.filter { $0.kind == .audio || $0.kind == .manifest }
            return recordingFiles.count == 2 && recordingFiles.allSatisfy { $0.verifiedAt != nil } ? job.id : nil
        })
        authorizedCount = ledger.jobs.count; savedAudioCount = ledger.savedAudioCount; savedTranscriptCount = ledger.savedTranscriptCount
        pendingFileCount = ledger.jobs.flatMap(\.artifacts).filter { $0.verifiedAt == nil }.count
        folderURL = ledger.folderID.flatMap { URL(string: "https://drive.google.com/drive/folders/" + $0) }
        if ledger.revokedLocally { activity = ledger.remoteRevocationConfirmed ? "Google 已确认撤销授权；云盘文件保留。" : "已在本机停止；Google 端撤销尚未确认。" }
        publishSyncEvidence()
    }

    private func publishSyncEvidence() {
        syncEvidence.submit(ledger: ledger, sourceSnapshotPending: progress.needsSnapshot,
            discoveryComplete: !ledgerUnavailable && !progress.needsSnapshot && !progress.needsDiscovery,
            discoveryRevision: Int(clamping: progress.revision), remainingDiscoveryCount: progress.remaining.count,
            failureCode: ledgerUnavailable ? "ledger_unavailable" : nil, workerReportSequence: workerReportSequence)
    }

    func setDiagnosticHandler(_ handler: @escaping (String, String) -> Void) { diagnosticHandler = handler }

    /// A fixed, bounded report lets support read the actual TLS failure without
    /// enumerating the event history or accessing recordings/credentials.
    private func recordTransportDiagnostic(_ value: GoogleDriveTransportDiagnostic, freezeFault: Bool = true) {
        guard value.origin != .controlledFault else { return }
        if freezeFault, let transportFaultRecorder {
            transportFaultContext.observeCurrentState()
            let observation = transportFaultContext.snapshot
            do {
                try transportFaultRecorder.record(value, build: observation.build, applicationState: observation.state)
                refreshTransportFaultPresentation()
            } catch { transportFaultContext.noteStorageFailure(); refreshTransportFaultPresentation(storageFailed: true) }
        }
        let failed = !value.errors.isEmpty
        // Worker observations receive each request before history sampling.
        // A delayed callback carries its own binding, even during another job.
        if value.uploadCorrelation != nil { recordWorker(.requestObserved, transport: value) }
        guard transportHistory.record(value) else { return }
        if let bytes = transportHistory.encoded() {
            workerDiagnostics.recordWrite(.transportHistory, sequence: workerReportSequence) {
                try persistTransportHistory(bytes)
            }
        }
        if failed {
            GoogleDriveUploadTrace.$current.withValue(value.uploadCorrelation) {
                recordDiagnostic("request_failed", value.logFields)
            }
        }
    }

    private func refreshTransportFaultPresentation(storageFailed: Bool = false) {
        if storageFailed { transportFaultContext.noteStorageFailure() }
        guard let transportFaultRecorder else { return }
        do {
            let presentation = GoogleDriveTransportFaultPresentation(archive: try transportFaultRecorder.snapshot())
            transportFaultCount = presentation.count
            latestTransportFaultAt = presentation.latestAt
            transportFaultSummary = presentation.summary
            if transportFaultContext.snapshot.storageFailureObserved {
                transportFaultSummary += " 本次运行曾有故障日志未能保存，报告可能不完整。"
            }
        } catch {
            transportFaultContext.noteStorageFailure()
            transportFaultSummary = "故障日志暂未能读取或保存；未据此确认恢复结果。"
        }
    }

    /// Ordinary diagnostics copy only the already retained, safe transport
    /// observations. This does not expire a window, write a file or start work.
    func diagnosticFaultSnapshot(at timestamp: Date = Date()) -> GoogleDriveDiagnosticFaultSnapshot {
        let storageFailure = transportFaultContext.snapshot.storageFailureObserved
        guard let transportFaultRecorder else {
            return .init(status: .unavailable, capturedAt: timestamp, storageFailureObserved: storageFailure,
                report: nil, error: .recorderUnavailable)
        }
        let archive = transportFaultRecorder.observationSnapshot()
        guard !archive.reports.isEmpty else {
            return .init(status: .noRetainedFaults, capturedAt: timestamp, storageFailureObserved: storageFailure,
                report: nil, error: nil)
        }
        let report = GoogleDriveTransportFaultShareReport(archive: archive, storageFailureObserved: storageFailure)
        do {
            let bytes = try TransportCodec.encode(report)
            guard bytes.count <= GoogleDriveTransportFaultRecorder.maximumArchiveBytes else {
                return .init(status: .unavailable, capturedAt: timestamp, storageFailureObserved: storageFailure,
                    report: nil, error: .byteLimitExceeded)
            }
            return .init(status: .included, capturedAt: timestamp, storageFailureObserved: storageFailure,
                report: report, error: nil)
        } catch {
            return .init(status: .unavailable, capturedAt: timestamp, storageFailureObserved: storageFailure,
                report: nil, error: .encodingFailed)
        }
    }

    /// The share action snapshots only already frozen transport observations.
    /// A unique immutable export cannot be changed by later sync callbacks.
    func prepareTransportFaultShare() -> URL? {
        transportFaultExportError = nil
        guard let transportFaultRecorder else {
            transportFaultExportError = "故障日志暂不可用，未生成分享文件。"; return nil
        }
        do {
            let archive: GoogleDriveTransportFaultArchive
            do { archive = try transportFaultRecorder.snapshot() }
            catch { transportFaultContext.noteStorageFailure(); throw error }
            guard !archive.reports.isEmpty else {
                transportFaultExportError = "尚无故障记录可分享。"; return nil
            }
            let bytes = try TransportCodec.encode(GoogleDriveTransportFaultShareReport(archive: archive,
                storageFailureObserved: transportFaultContext.snapshot.storageFailureObserved))
            let exports = directory.appendingPathComponent("FaultReportExports", isDirectory: true)
            let file = exports.appendingPathComponent("RecordForAgent-Google-connection-faults-\(UUID().uuidString.lowercased()).json")
            try pruneTransportFaultShares(in: exports)
            try writeTransportFaultShare(bytes, to: file)
            refreshTransportFaultPresentation()
            return file
        } catch {
            transportFaultExportError = "故障报告未能生成，已有故障记录保留。请稍后再试。"
            return nil
        }
    }

    private func writeTransportFaultShare(_ bytes: Data, to file: URL) throws {
        guard !bytes.isEmpty, bytes.count <= GoogleDriveTransportFaultRecorder.maximumArchiveBytes else {
            throw GoogleDriveLibraryError.invalidState
        }
        let exports = file.deletingLastPathComponent()
        try GoogleDriveLocalFiles.prepare(exports)
        // This UUID target has never been shared. Refuse even a pre-existing
        // regular file instead of replacing any previously exported snapshot.
        var info = stat()
        guard Darwin.lstat(file.path, &info) != 0, errno == ENOENT else { throw GoogleDriveLibraryError.invalidState }
        let temporary = exports.appendingPathComponent(".fault-share-\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw GoogleDriveLibraryError.invalidState }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: bytes); try handle.synchronize()
        guard Darwin.renamex_np(temporary.path, file.path, UInt32(RENAME_EXCL)) == 0 else { throw GoogleDriveLibraryError.invalidState }
        let parent = Darwin.open(exports.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw GoogleDriveLibraryError.invalidState }
        defer { Darwin.close(parent) }
        guard Darwin.fsync(parent) == 0 else { throw GoogleDriveLibraryError.invalidState }
    }

    /// Only this dedicated export directory is listed, and only our regular,
    /// single-link UUID snapshots are removed. Recording paths are never used.
    private func pruneTransportFaultShares(in exports: URL) throws {
        try GoogleDriveLocalFiles.prepare(exports)
        let prefix = "RecordForAgent-Google-connection-faults-", suffix = ".json"
        let files = try FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])
        var snapshots: [(url: URL, modified: TimeInterval)] = []
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix),
                  UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil else { continue }
            var info = stat()
            guard Darwin.lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { continue }
            snapshots.append((file, TimeInterval(info.st_mtimespec.tv_sec)))
        }
        snapshots.sort { $0.modified == $1.modified ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.modified < $1.modified }
        // Reserve one slot for the immutable snapshot created by this tap.
        for old in snapshots.prefix(max(0, snapshots.count - 9)) {
            guard Darwin.unlink(old.url.path) == 0 else { throw GoogleDriveLibraryError.invalidState }
        }
    }

    /// Replace only this fixed diagnostic file. Inspect old file metadata, never
    /// its bytes: even a corrupt/oversized prior report cannot cause a large read
    /// when the next valid observation is saved. All errors stay diagnostic-only.
    private func persistTransportHistory(_ bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= GoogleDriveTransportHistory.maximumFileBytes else {
            throw GoogleDriveMetadataIOError(code: EINVAL)
        }
        try GoogleDriveLocalFiles.prepare(directory)
        let file = directory.appendingPathComponent("transport-diagnostics.json")
        var info = stat()
        if Darwin.lstat(file.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw GoogleDriveMetadataIOError(code: EINVAL) }
        } else if errno != ENOENT { throw GoogleDriveMetadataIO.syscallFailure() }
        let temporary = directory.appendingPathComponent(".drive-transport-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
        #endif
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: bytes); try handle.synchronize()
        guard Darwin.rename(temporary.path, file.path) == 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
        defer { Darwin.close(parent) }
        guard Darwin.fsync(parent) == 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
    }

    private func recordDiagnostic(_ event: String, _ detail: String) {
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        if event == "register", executionID != nil { nativeRegisteredThisRound += 1 }
        let now = ProcessInfo.processInfo.systemUptime, active = executionLease != nil
        let phaseMS = Int(min(3_600_000, max(0, now - phaseStartedAt) * 1_000))
        let elapsedMS = (active || event == "round_finished") ? Int(min(3_600_000, max(0, now - roundStartedAt) * 1_000)) : 0
        let remainingMS = (try? executionLease?.check()) != nil ? Int(min(120_000, max(0, (executionLease?.deadline ?? now) - now) * 1_000)) : 0
        let phaseDetail = "phase=\(currentPhase.rawValue) phase_elapsed_ms=\(phaseMS) elapsed_ms=\(elapsedMS) remaining_ms=\(remainingMS) round_seq=\(roundSequence) round_active=\(active) native_registered=\(nativeRegisteredThisRound) scan_visited=\(scanVisitedThisRound) scan_remaining=\(progress.remaining.count) snapshot_needed=\(progress.needsSnapshot)"
        let correlationDetail = GoogleDriveUploadTrace.current.map { " " + $0.logFields } ?? ""
        diagnosticHandler?("phone.drive_background_" + event, "app_state=\(state) " + phaseDetail + " " + detail + correlationDetail)
        let observed: GoogleDriveWorkerReport.Event?
        switch event {
        case "round_started": observed = .roundStarted
        case "round_finished": observed = .roundFinished
        case "lease_expired": observed = .leaseExpired
        case "network_deferred": observed = .networkDeferred
        case "sources_admitted": observed = .sourceAdmitted
        case "round_failed": observed = .roundFailed
        case "register": observed = .nativeRegistered
        case "recover": observed = .queueRecovered
        case "remote_verified":
            workerDiagnosticState.clearFailure(); observed = .remoteVerified
        default: observed = nil
        }
        if let observed { recordWorker(observed) }
    }

    private func recordWorker(_ event: GoogleDriveWorkerReport.Event,
                              transport: GoogleDriveTransportDiagnostic? = nil,
                              completion: GoogleDriveRequestCompletion? = nil) {
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let atMS = Int64((now.timeIntervalSince1970 * 1_000).rounded(.towardZero))
        let leaseChecked = executionLease.map { (try? $0.check()) != nil } ?? false
        if let executionLease { workerDiagnosticState.updateLeaseDeadline(executionLease.deadline) }
        let remaining = leaseChecked
            ? Int(min(120_000, max(0, (executionLease?.deadline ?? uptime) - uptime) * 1_000)) : 0
        let execution = workerDiagnosticState.snapshot(leasePresent: executionLease != nil,
            leaseCheckSucceeded: leaseChecked, finished: event == .roundFinished, atMS: atMS)
        let cancellationReason: GoogleDriveWorkerReport.CancellationReason?
        if event == .cancelled {
            cancellationReason = workerDiagnosticState.cancellationReason ?? (Task.isCancelled ? .taskCancellationObserved : .unknown)
        } else if event == .roundFinished || event == .leaseExpired { cancellationReason = workerDiagnosticState.cancellationReason }
        else { cancellationReason = nil }
        let artifacts = ledger.jobs.flatMap(\.artifacts)
        let pending = artifacts.filter { $0.verifiedAt == nil }.count
        workerReportSequence &+= 1
        workerObservations.append(.init(atMS: atMS, event: event, phase: currentPhase,
            roundSequence: roundSequence, foreground: UIApplication.shared.applicationState == .active,
            roundActive: executionLease != nil, remainingMS: remaining, pendingCount: pending,
            nativeCount: backgroundUploads?.nativeActiveCount ?? 0, readbackCount: backgroundUploads?.pendingReadbackCount ?? 0,
            execution: execution, cancellationReason: cancellationReason,
            uploadCorrelation: transport != nil ? transport?.uploadCorrelation
                : (completion != nil ? completion?.uploadCorrelation : GoogleDriveUploadTrace.current),
            requestID: transport?.requestID ?? completion?.requestID,
            origin: transport?.origin ?? completion?.origin,
            transportPhase: transport?.phase, endpoint: transport?.endpoint, method: transport?.method,
            httpStatus: transport?.httpStatus, errorCode: transport?.errors.first?.code,
            completionOutcome: completion?.outcome))
        workerObservations = Array(workerObservations.suffix(GoogleDriveWorkerReport.maximumObservations))
        workerDiagnostics.submit(.init(schemaVersion: 2, processRunID: workerProcessRunID,
            build: workerBuild,
            generatedAtMS: atMS, sequence: workerReportSequence, enabled: ledger.enabled, ledgerAvailable: !ledgerUnavailable,
            sourceSnapshotPending: progress.needsSnapshot, discoveryComplete: !ledgerUnavailable && !progress.needsSnapshot && !progress.needsDiscovery,
            discoveryRemaining: progress.remaining.count, authorizedSourceCount: ledger.jobs.count,
            savedAudioCount: ledger.savedAudioCount, pendingArtifactCount: pending,
            nativeCount: backgroundUploads?.nativeActiveCount ?? 0, readbackCount: backgroundUploads?.pendingReadbackCount ?? 0,
            itemRetryCount: backgroundUploads?.itemRetries.count ?? 0,
            retryAfterMS: ledger.retryAfter.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded(.towardZero)) },
            failureCount: ledger.failureCount, systemGranted: execution?.systemGranted ?? false,
            lastFailure: workerDiagnosticState.lastFailure, lastFailurePhase: workerDiagnosticState.lastFailurePhase,
            observations: workerObservations, diagnosticsRevision: 5, execution: execution,
            lastFailureContext: workerDiagnosticState.lastFailureContext))
        if event == .roundFinished, let id = execution?.id { workerDiagnosticState.finish(id: id) }
    }

    func restoreBackgroundSession(_ identifier: String) -> Bool {
        guard let backgroundUploads, backgroundUploads.recognizes(identifier) else { return false }
        let events = AutomaticDeliveryBackgroundEvents.shared
        if events.hasPendingCompletion(identifier), events.requiresInvalidation(identifier) {
            guard backgroundEventHandoff == nil else { return true }
            let handoff = events.beginHandoff(identifier)
            // Stop bounded synchronization from registering another body while
            // this native event wave is closed. A user-facing OAuth operation
            // has no execution lease and is never awaited by UIKit drainage.
            if executionLease != nil { stopWork() }
            backgroundEventHandoff = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await backgroundUploads.handoffForPendingEvents()
                    events.completeHandoff(identifier, token: handoff)
                } catch {
                    self.failClosed(error)
                    // Keep the UIKit hold until the exact native fallback
                    // session acknowledges invalidation; a factory error is
                    // never evidence that its old event wave was drained.
                    events.cancelUnrestorable(identifier)
                }
                self.backgroundEventHandoff = nil
                self.backgroundUploadDidChange()
            }
            return true
        }
        guard events.canRestore(identifier) else { return true }
        Task { @MainActor [weak self] in
            guard let self, AutomaticDeliveryBackgroundEvents.shared.canRestore(identifier) else { return }
            await backgroundUploads.recover(in: self.ledger)
        }
        return true
    }

    private func backgroundUploadDidChange() {
        recordWorker(.callback)
        guard !ledgerUnavailable, ledger.enabled, oauth.hasCredential else { return }
        if backgroundUploads?.isUnavailable == true {
            failClosed(backgroundUploads?.metadataFailure ?? GoogleDriveLibraryError.invalidState); return
        }
        // Completion can arrive before the registering Swift round's defer.
        // Preserve that wake and consume it after the old worker has ended.
        backgroundCallbackRequestedWork = true
        if work == nil {
            backgroundCallbackRequestedWork = false
            schedule()
        }
    }

    private func finishBackgroundEvents(_ event: BackgroundSessionEvent) async {
        guard backgroundUploads?.recognizes(event.identifier) == true else { return }
        // Callback processing/readback uses an ordinary finite lease. Never
        // hold UIKit's completion waiting for another native upload or retry.
        await GoogleDriveBackgroundEventDrain.finish(work: work, hasBoundedExecution: executionLease != nil) {
            AutomaticDeliveryBackgroundEvents.shared.finish(event.identifier, token: event.token)
        }
    }
}

private final class GoogleDriveSyncEvidenceWriter: @unchecked Sendable {
    private struct Pending {
        let ledger: GoogleDriveLibraryLedger
        let discoveryComplete: Bool
        let sourceSnapshotPending: Bool
        let discoveryRevision: Int
        let remainingDiscoveryCount: Int
        let failureCode: String?
        let workerReportSequence: UInt64
    }
    private let archive: SyncEvidenceArchive
    private let workerDiagnostics: GoogleDriveWorkerDiagnosticsWriter
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: Pending?
    private var running = false
    private var observedKeys = Set<String>()

    init(root: URL, workerDiagnostics: GoogleDriveWorkerDiagnosticsWriter,
         queue: DispatchQueue = DispatchQueue(label: "record-for-agent.drive-sync-evidence", qos: .utility)) {
        archive = SyncEvidenceArchive(root: root, stream: "google_drive")
        self.workerDiagnostics = workerDiagnostics; self.queue = queue
    }

    func observeVerifiedMetadata(onThrottle: (@Sendable (Int) -> Void)? = nil) {
        queue.async { [self] in
            _ = archive.observe(processRunID: VerifiedObservationPublisher.processRunID, onThrottle: onThrottle)
            workerDiagnostics.observeVerifiedMetadata(onThrottle: onThrottle)
        }
    }

    func observedCallback(segmentID: UUID, artifactKey: String) {
        lock.lock(); defer { lock.unlock() }
        observedKeys.insert(segmentID.uuidString.lowercased() + ":" + artifactKey)
    }

    func submit(ledger: GoogleDriveLibraryLedger, sourceSnapshotPending: Bool, discoveryComplete: Bool,
                discoveryRevision: Int, remainingDiscoveryCount: Int, failureCode: String?, workerReportSequence: UInt64) {
        lock.lock()
        pending = Pending(ledger: ledger, discoveryComplete: discoveryComplete,
            sourceSnapshotPending: sourceSnapshotPending, discoveryRevision: discoveryRevision, remainingDiscoveryCount: remainingDiscoveryCount,
            failureCode: failureCode, workerReportSequence: workerReportSequence)
        guard !running else { lock.unlock(); return }
        running = true; lock.unlock()
        queue.async { [self] in drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let item = pending else {
                running = false; lock.unlock()
                _ = archive.observe(processRunID: VerifiedObservationPublisher.processRunID, sourceDidChange: true)
                workerDiagnostics.observeVerifiedMetadata()
                return
            }
            pending = nil
            let callbacks = observedKeys
            lock.unlock()
            let ledger = item.ledger
            let rows = ledger.jobs.map { job in
                SyncEvidenceSource(segmentID: job.id, sha256: job.manifest.sha256,
                    byteCount: job.manifest.byteCount, startedAtMS: Self.milliseconds(job.manifest.startedAt),
                    origin: "authorized_ledger", artifacts: job.artifacts.map { artifact in
                        let callback = callbacks.contains(job.id.uuidString.lowercased() + ":" + artifact.key)
                        return SyncEvidenceArtifact(kind: Self.kind(artifact.kind), sha256: artifact.sha256,
                            byteCount: artifact.byteCount, state: artifact.verifiedAt == nil ? "pending" : "remote_verified",
                            recordedAtMS: artifact.verifiedAt.map(Self.milliseconds),
                            observedAtMS: callback ? artifact.verifiedAt.map(Self.milliseconds) : nil,
                            origin: artifact.verifiedAt == nil ? "authorized_ledger" : (callback ? "observed_callback" : "restored_ledger"),
                            uploadCorrelation: artifact.verifiedUploadCorrelation)
                    })
            }
            let artifacts = ledger.jobs.flatMap(\.artifacts)
            let context = SyncEvidenceContext(scope: "phone_authorized_discovered", libraryID: ledger.libraryID,
                scopeMode: ledger.recordingScope?.rawValue, authorizedAtMS: ledger.authorizedAt.map(Self.milliseconds),
                baselineIDs: Array(ledger.baselineIDs), enabled: ledger.enabled,
                discoveryComplete: item.discoveryComplete,
                counts: ["authorized_source_count": ledger.jobs.count,
                         "artifact_count": artifacts.count,
                         "remote_verified_artifact_count": artifacts.filter { $0.verifiedAt != nil }.count,
                         "remote_verified_audio_count": ledger.savedAudioCount,
                         "remote_verified_transcript_count": ledger.savedTranscriptCount,
                         "source_snapshot_pending": item.sourceSnapshotPending ? 1 : 0,
                         "discovery_revision": item.discoveryRevision,
                         "remaining_discovery_count": item.remainingDiscoveryCount,
                         "pending_artifact_count": artifacts.filter { $0.verifiedAt == nil }.count],
                failureCode: item.failureCode)
            // The archive retains its old generation and exposes failure status.
            // Diagnostic storage never changes the recording grant or receipt.
            workerDiagnostics.recordWrite(.syncEvidence, sequence: item.workerReportSequence) {
                try archive.publish(rows: rows, context: context)
            }
        }
    }

    private static func milliseconds(_ value: Date) -> Int64 {
        Int64((value.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }
    private static func kind(_ value: GoogleDriveArtifact.Kind) -> String {
        switch value {
        case .audio: return "audio"
        case .manifest: return "manifest"
        case .transcriptJSON: return "transcriptJSON"
        case .transcriptText: return "transcriptText"
        }
    }
}

/// Presentation uses only validated typed states. A closed context window is
/// never presented as successful recovery, nor as a complete system log.
struct GoogleDriveTransportFaultPresentation {
    let count: Int
    let latestAt: Date?
    let summary: String

    init(archive: GoogleDriveTransportFaultArchive) {
        count = archive.reports.count
        latestAt = archive.reports.last?.triggeredAt
        guard let latest = archive.reports.last else { summary = "尚无故障记录。"; return }
        let recovery: String
        if let completion = latest.completion {
            switch completion.outcome {
            case .recovered: recovery = "连接请求已自动恢复。"
            case .cancelled: recovery = "请求已取消，恢复结果未确认。"
            case .succeeded: recovery = "连接请求已结束；业务保存结果请查看同步状态。"
            case .httpFailure: recovery = "连接请求已结束，Google 返回错误。"
            case .notEligible, .budgetExpired, .callerBudgetRejected, .recoveryFailed, .invalidResponse:
                recovery = "本次请求未能确认自动恢复。"
            }
        } else if !latest.correlationAvailable {
            recovery = "恢复结果未能关联到同一次请求。"
        } else if latest.state == .collecting {
            recovery = "正在收集同次请求的恢复结果。"
        } else {
            recovery = "恢复结果未确认。"
        }
        let context: String
        switch latest.state {
        case .collecting: context = "故障前后连接日志仍在收集中。"
        case .windowElapsed: context = "60 秒上下文观察窗口已结束。"
        case .truncated: context = "上下文已达到保存上限，报告已标记截断。"
        case .interrupted: context = "上次日志收集已中断，缺失区间未补填。"
        }
        let retention = archive.evictedReportCount > 0
            ? " 更早 \(archive.evictedReportCount) 份已超出保留范围。" : ""
        summary = recovery + " " + context + retention
    }
}

/// The export preserves the recorder's safe schema and marks any persistence
/// gap observed in this process. No decoded arbitrary JSON is forwarded.
struct GoogleDriveTransportFaultShareReport: Encodable, Sendable {
    let schemaVersion: Int
    let contextScope: GoogleDriveTransportFaultArchive.ContextScope
    let evictedReportCount: Int
    let reports: [GoogleDriveTransportFaultReport]
    let storageFailureObserved: Bool

    init(archive: GoogleDriveTransportFaultArchive, storageFailureObserved: Bool) {
        schemaVersion = archive.schemaVersion; contextScope = archive.contextScope
        evictedReportCount = archive.evictedReportCount; reports = archive.reports
        self.storageFailureObserved = storageFailureObserved
    }
}

/// This explicit envelope distinguishes an unavailable recorder from a recorder
/// with no retained failures. No arbitrary error strings or account data fit it.
struct GoogleDriveDiagnosticFaultSnapshot: Encodable, Sendable {
    enum Status: String, Encodable, Sendable {
        case included, noRetainedFaults = "no_retained_faults", unavailable
    }
    enum Failure: String, Encodable, Sendable {
        case libraryUnavailable = "library_unavailable", recorderUnavailable = "recorder_unavailable"
        case byteLimitExceeded = "byte_limit_exceeded", encodingFailed = "encoding_failed"
    }
    let sourceScope = "frozen_transport_observations"
    let readOnly = true
    let contextWindowUpdatedForExport = false
    let maximumArchiveBytes = GoogleDriveTransportFaultRecorder.maximumArchiveBytes
    let status: Status
    let capturedAt: Date
    let storageFailureObserved: Bool
    let report: GoogleDriveTransportFaultShareReport?
    let error: Failure?

    var summary: String {
        var text: String
        switch status {
        case .included: text = "已附 \(report?.reports.count ?? 0) 份留存的 Google 故障记录。"
        case .noRetainedFaults: text = "没有留存的 Google 故障记录。"
        case .unavailable: text = "Google 故障记录暂不可用，未当作空记录。"
        }
        if let report {
            let truncated = report.reports.filter { $0.state == .truncated }.count
            if truncated > 0 { text += " 其中 \(truncated) 份上下文已截断。" }
            if report.evictedReportCount > 0 {
                text += " 更早 \(report.evictedReportCount) 份已超出保留范围。"
            }
        }
        return text + (storageFailureObserved ? " 故障日志曾保存失败，记录可能不完整。" : "")
    }
}

/// UIKit is observed only on MainActor. Synchronous network callbacks receive
/// the most recent observed state, never query UIKit from a delegate queue.
private final class GoogleDriveTransportFaultObservationContext: @unchecked Sendable {
    struct Snapshot: Sendable {
        let build: Int
        let state: GoogleDriveFaultApplicationState
        let storageFailureObserved: Bool
    }
    private let lock = NSLock()
    private var value = Snapshot(build: 0, state: .unknown, storageFailureObserved: false)
    private var observers: [NSObjectProtocol] = []

    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }

    func noteStorageFailure() {
        lock.lock(); defer { lock.unlock() }
        value = Snapshot(build: value.build, state: value.state, storageFailureObserved: true)
    }

    @MainActor func startObserving() {
        guard observers.isEmpty else { return }
        observeCurrentState()
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.observeCurrentState() }
            })
        }
    }

    @MainActor func observeCurrentState() {
        let state: GoogleDriveFaultApplicationState
        switch UIApplication.shared.applicationState {
        case .active: state = .active
        case .inactive: state = .inactive
        case .background: state = .background
        @unknown default: state = .unknown
        }
        let build = max(0, min(10_000_000, Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0))
        lock.lock(); value = Snapshot(build: build, state: state, storageFailureObserved: value.storageFailureObserved); lock.unlock()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

#if DEBUG
private enum GoogleDriveTLSProbePersistenceError: Error { case unavailable }

/// Fixed vocabulary only. This report contains no account or recording identity,
/// raw request, response body, URL, header, certificate or error description.
struct GoogleDriveTLSProbeReport: Codable {
    enum Mode: String, Codable { case natural, controlledFault = "controlled_fault" }
    enum Result: String, Codable {
        case running, completed, cancelled
        case completedWithFailures = "completed_with_failures"
        case completedUnproven = "completed_unproven"
        case controlledRecovered = "controlled_recovered"
        case accountMismatch = "account_mismatch", needsSignIn = "needs_sign_in"
        case reportUnavailable = "report_unavailable"
    }
    struct Attempt: Codable {
        let timestamp: Date
        let foregroundObservedAt: Date
        let foregroundAtObservation: Bool
        let diagnostic: GoogleDriveTransportDiagnostic
    }
    let schemaVersion = 1
    let runID: UUID
    let build: Int
    let mode: Mode
    let startedAt: Date
    let startForeground: Bool
    var finishedAt: Date?
    var result = Result.running
    var accountMatched = false
    var validationsStarted = 0
    var validationsSucceeded = 0
    var validationsFailed = 0
    var syntheticInitialError = false
    var firstNetworkAttempted = false
    var injected = false
    var injectionCount = 0
    var attempts: [Attempt] = []
    // A callback is not necessarily a network request: the synthetic first
    // failure has no URLSession task. These counters deliberately say observed.
    var observedTransportEvents = 0
    var observedNetworkMetrics = 0

    init(runID: UUID, controlledFault: Bool, build: Int, startForeground: Bool) {
        self.runID = runID; self.build = max(0, min(1_000_000_000, build))
        mode = controlledFault ? .controlledFault : .natural
        startedAt = Date(); self.startForeground = startForeground
    }
    mutating func observe(_ values: [Attempt], injectionCount: Int) {
        attempts = Array(values.prefix(24))
        self.injectionCount = min(1, max(0, injectionCount)); injected = self.injectionCount == 1
        // This refers to the initial probed about GET; an optional OAuth refresh
        // is listed separately with the fixed oauth_token endpoint.
        let firstAbout = attempts.first(where: { $0.diagnostic.endpoint == .driveAbout })?.diagnostic
        syntheticInitialError = mode == .controlledFault && injected && firstAbout.map(Self.isSyntheticInitial) == true
        firstNetworkAttempted = firstAbout != nil && !syntheticInitialError
        observedTransportEvents = attempts.count
        observedNetworkMetrics = attempts.filter { $0.diagnostic.metrics != nil }.count
    }
    private static func isSyntheticInitial(_ value: GoogleDriveTransportDiagnostic) -> Bool {
        value.endpoint == .driveAbout && value.method == .GET && value.phase == .apiRequest
            && value.httpStatus == nil && value.metrics == nil
            && value.errors == [.init(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed),
                                .init(domain: "kCFErrorDomainCFNetwork", code: NSURLErrorSecureConnectionFailed)]
            && value.streamErrorDomain == 3 && value.streamErrorCode == -9816
    }
    var hasProvenControlledRecovery: Bool {
        let about = attempts.filter { $0.diagnostic.endpoint == .driveAbout }.map(\.diagnostic)
        guard mode == .controlledFault, injectionCount == 1, syntheticInitialError, !firstNetworkAttempted,
              accountMatched, validationsStarted == 1, validationsSucceeded == 1, validationsFailed == 0,
              about.count == 2, Self.isSyntheticInitial(about[0]), about[1].phase == .apiRecovery,
              about[1].method == .GET, about[1].errors.isEmpty, about[1].httpStatus == 200,
              let metrics = about[1].metrics else { return false }
        return metrics.requestStarted && metrics.responseStarted && metrics.tlsStarted && metrics.tlsFinished
            && !metrics.reusedConnection
    }
    var status: String {
        switch result {
        case .running: return "正在检查真实连接。"
        case .controlledRecovered: return "模拟断连恢复已通过；初始错误为模拟，恢复请求与 TLS 指标来自真实网络。"
        case .completed: return "真实连接检查完成；\(validationsSucceeded) 次账户核对一致。未据此宣称偶发 TLS 问题已根治。"
        case .completedWithFailures: return "连接检查已结束；\(validationsFailed) 次未完成，已有诊断已保存。"
        case .completedUnproven: return "模拟断连检查已结束；恢复证据不足，尚未确认通过。"
        case .cancelled: return "连接检查已停止，已有诊断已保存；同步队列未改动。"
        case .accountMismatch: return "账户核对不一致，诊断已停止，未更改同步授权。"
        case .needsSignIn: return "当前授权未通过账户检查，诊断已停止。"
        case .reportUnavailable: return "诊断报告未能保存，尚未确认检查通过。"
        }
    }
}

/// The TaskLocal sink is precise to this validation task. A bounded queue of
/// MainActor observations obtains UIKit state without reading it off-actor.
private final class GoogleDriveTLSProbeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [GoogleDriveTLSProbeReport.Attempt] = []
    private var pending: [Task<Void, Never>] = []
    private var admitted = 0

    func enqueue(_ diagnostic: GoogleDriveTransportDiagnostic,
                 foreground: @escaping @MainActor @Sendable () -> Bool) {
        guard (diagnostic.endpoint == .driveAbout && diagnostic.method == .GET)
                || (diagnostic.endpoint == .oauthToken && diagnostic.method == .POST),
              diagnostic.phase == .apiRequest || diagnostic.phase == .apiRecovery else { return }
        let timestamp = Date()
        var validator = GoogleDriveTransportHistory()
        guard validator.record(diagnostic, at: timestamp) else { return }
        lock.lock()
        guard admitted < 24 else { lock.unlock(); return }
        admitted += 1
        let task = Task { @MainActor [weak self] in
            let observation = GoogleDriveTLSProbeReport.Attempt(timestamp: timestamp,
                foregroundObservedAt: Date(), foregroundAtObservation: foreground(), diagnostic: diagnostic)
            self?.append(observation)
        }
        pending.append(task); lock.unlock()
    }
    private func append(_ value: GoogleDriveTLSProbeReport.Attempt) {
        lock.lock(); defer { lock.unlock() }
        values.append(value); values.sort { $0.timestamp < $1.timestamp }
    }
    var snapshot: [GoogleDriveTLSProbeReport.Attempt] {
        lock.lock(); defer { lock.unlock() }; return values
    }
    private func takePending() -> [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        let result = pending; pending.removeAll(); return result
    }
    func drain() async { for task in takePending() { await task.value } }
}
#endif
