import Combine
import Darwin
import Foundation
import RecordingCore
import UIKit

/// A separate, explicit iCloud Drive grant. A selected folder alone never exports
/// recordings, and neither the CloudKit first batch nor Drive's grant enables it.
@MainActor
final class ICloudDriveLibrary: ObservableObject {
    @Published private(set) var folderName = "尚未选择 iCloud Drive 文件夹"
    @Published private(set) var isConnected = false
    @Published private(set) var isEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var busyMessage = "正在处理…"
    @Published private(set) var scope: ICloudDriveRecordingScope?
    @Published private(set) var authorizedManifests: [SegmentManifest] = []
    @Published private(set) var locallyWrittenRecordingIDs: Set<UUID> = []
    @Published private(set) var cloudConfirmedRecordingIDs: Set<UUID> = []
    @Published private(set) var authorizedCount = 0
    @Published private(set) var savedAudioCount = 0
    @Published private(set) var savedTranscriptCount = 0
    @Published private(set) var hasPendingFiles = true
    @Published private(set) var uploadedFileCount = 0
    @Published private(set) var pendingCloudFileCount = 0
    @Published private(set) var activity = "先选择 iCloud Drive 文件夹，再单独确认录音同步范围。"
    @Published private(set) var error: String?
    /// Source-local warnings stay visible without closing a healthy provider
    /// session or stopping metadata-only continuation for the other sources.
    private var sourceWarning: String?
    private(set) var hasBlockingError = false
    /// A marker match alone never adopts a folder whose provider identity changed.
    @Published private(set) var recoveryConfirmationRequired = false
    @Published private var diagnosticObservation: ICloudDriveDiagnosticObservation?
    private var diagnosticOperationFailed = false

    private var providerMonitor: ICloudDriveProviderMonitor?
    private var needsProviderRefresh = false
    private var providerNotificationGeneration: UInt64 = 0
    private var needsProviderContinuation = false
    private var needsSyncContinuation = false
    private let worker: ICloudDriveLibraryWorker
    private var task: Task<Void, Never>?
    private var gate = ICloudDriveCancellation()
    private var generation: UInt64 = 0
    private var knownManifests: [SegmentManifest]?
    private var receivedIDs: Set<UUID>?
    private var needsDiscovery = false
    private var needsReload = false
    // Keep the actual source/version of a late transcript notification until a
    // bounded worker pass has inspected it. A general rotation may not reach it.
    private var pendingTranscriptRequests: [UUID: UUID] = [:]
    private var foreground = true
    private let executionWindow = ICloudDriveExecutionWindow()
    private var persistsStop = false
    private var observers: [NSObjectProtocol] = []

    /// Retained after disconnect for reconnecting the exact original grant.
    /// It does not imply folder access is currently available.
    var hasAuthorizationHistory: Bool { scope != nil }

    /// A synchronous copy of already published typed memory. Diagnostics and
    /// the status explanation never ask the worker/provider to fill a gap.
    func diagnosticSnapshot(at now: Date = Date()) -> ICloudDriveDiagnosticSnapshot {
        .init(observation: diagnosticObservation, at: now, connected: isConnected,
              enabled: isEnabled, operationFailed: diagnosticOperationFailed,
              providerMonitor: providerMonitor?.diagnosticSnapshot)
    }

    /// At least one known exported file had positive provider metadata in the
    /// last published observation. It is historical evidence, not a live cloud
    /// snapshot; zero/zero counters never establish an uploaded empty library.
    var hasCloudStatusEvidence: Bool { uploadedFileCount > 0 }

    /// Pending provider confirmation is included even though iCloud, not this
    /// worker, owns its transfer. A paused grant deliberately reports no work.
    var hasPendingWork: Bool {
        isConnected && isEnabled && scope != nil
            && (isBusy || needsDiscovery || needsReload || error != nil
                || !pendingTranscriptRequests.isEmpty
                || hasPendingFiles || savedAudioCount < authorizedCount || pendingCloudFileCount > 0)
    }

    /// The provider owns uploads after export. Do not request endless app wakes
    /// merely because iCloud has not confirmed an already-written file yet.
    var hasPendingExportWork: Bool {
        isConnected && isEnabled && scope != nil
            && (isBusy || needsDiscovery || needsReload || error != nil
                || !pendingTranscriptRequests.isEmpty || hasPendingFiles || savedAudioCount < authorizedCount)
    }

    /// These projections cover only the most recently discovered Phone queue.
    /// Published busy/error/count changes also invalidate the private dirty and
    /// reload guards. Pending artifacts come from the ledger's read-only snapshot;
    /// no completion flag is persisted.
    private var hasSettledCurrentGrant: Bool {
        isConnected && isEnabled && scope != nil && !isBusy
            && !needsDiscovery && !needsReload && !hasPendingFiles && error == nil
    }
    var isWaitingForNewRecordings: Bool {
        hasSettledCurrentGrant && scope == .futureOnly && authorizedCount == 0
    }
    var isCurrentScopeWritten: Bool {
        hasSettledCurrentGrant && authorizedCount > 0 && savedAudioCount == authorizedCount
    }
    var isCurrentScopeUploaded: Bool {
        isCurrentScopeWritten && hasCloudStatusEvidence && pendingCloudFileCount == 0
    }

    init(repository: RecordingRepository, transcriptRepository: TranscriptRepository,
         folderAccess: ICloudDriveFolderAccess = .system,
         providerMonitorFactory: (@escaping @Sendable () -> Void) -> ICloudDriveProviderMonitor = { .init(changed: $0) }) {
        worker = ICloudDriveLibraryWorker(repository: repository, transcriptRepository: transcriptRepository,
                                         folderAccess: folderAccess)
        providerMonitor = providerMonitorFactory { [weak self] in
            Task { @MainActor [weak self] in self?.providerDidChange() }
        }
        foreground = UIApplication.shared.applicationState == .active
        executionWindow.setForeground(foreground)
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.suspendForBackground() }
            })
        // PhoneStore's scene-phase callback owns foreground resumption. Keeping
        // a second didBecomeActive observer would enqueue the same scan twice.
        if foreground { run(.load) }
        else { needsReload = true; needsDiscovery = true }
    }

    deinit {
        gate.cancel(); task?.cancel()
        providerMonitor?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func connect(to url: URL) { run(.connect(url)) }
    func confirmDirectoryRecovery() { run(.confirmDirectoryRecovery) }
    func cancelDirectoryRecovery() { run(.cancelDirectoryRecovery) }

    /// An explicit foreground check of files already exported by this grant.
    /// It never enables saving, discovers sources, or schedules export work.
    func checkCloudStatusReadOnly() {
        guard foreground, !isBusy, isConnected, scope != nil, !recoveryConfirmationRequired else { return }
        run(.inspectProviderStatus)
    }

    func authorize(scope: ICloudDriveRecordingScope, knownManifests: [SegmentManifest], receivedIDs: Set<UUID>) {
        self.knownManifests = canonical(knownManifests); self.receivedIDs = receivedIDs
        run(.authorize(scope, knownManifests, receivedIDs))
    }

    func discover(manifests: [SegmentManifest], receivedIDs: Set<UUID>) {
        let normalized = canonical(manifests)
        guard knownManifests != normalized || self.receivedIDs != receivedIDs else { return }
        knownManifests = normalized; self.receivedIDs = receivedIDs; needsDiscovery = true
        schedule()
    }

    func transcriptDidSave(for manifest: SegmentManifest) {
        pendingTranscriptRequests[manifest.id] = UUID()
        needsDiscovery = true
        schedule()
    }

    /// Detached entry and actor serialization keep metadata IO off MainActor.
    func observeVerifiedMetadata(onThrottle: (@Sendable (Int) -> Void)? = nil) {
        Task.detached(priority: .utility) { [worker] in await worker.observeVerifiedMetadata(onThrottle: onThrottle) }
    }

    /// Foreground opportunities resume an enabled grant; an explicit pause stays paused.
    func resume() {
        foreground = UIApplication.shared.applicationState == .active
        executionWindow.setForeground(foreground)
        // A scan already in flight covers this foreground opportunity. Actual
        // snapshot/transcript changes keep their own dirty flag while it runs.
        if !isBusy { needsDiscovery = true }
        // A command may have persisted on the utility actor just before the
        // foreground task was cancelled, so restore its actual local state.
        schedule()
    }

    /// Called only while PhoneStore owns a real UIKit or BGProcessing lease.
    /// No fake foreground state, timer wake, or new authorization is created.
    /// A blocked provider accessor can outlive this wait, but its cancellation
    /// gate prevents a subsequent commit after the opportunity has expired.
    func prepareBackgroundDelivery(isCancelled: @escaping @Sendable () -> Bool,
                                   systemGranted: Bool = false,
                                   maximumDuration: TimeInterval = 18) async -> Bool {
        guard !isCancelled(), !Task.isCancelled else { return false }
        let id = UUID()
        let deadline = ProcessInfo.processInfo.systemUptime + min(18, max(0, maximumDuration))
        let allowed: @Sendable () -> Bool = {
            !isCancelled() && ProcessInfo.processInfo.systemUptime < deadline
        }
        executionWindow.add(id, systemGranted: systemGranted, allowed: allowed)
        defer {
            executionWindow.remove(id)
            if !executionWindow.isAllowed && isBusy && !persistsStop {
                needsReload = true; needsDiscovery = true
                stop()
            }
        }
        if !isBusy { needsDiscovery = true }
        // A receipt wake often leaves much more than two sources to export.
        // Use the already-granted lease for a few small batches instead of
        // abandoning it after the first pair and hoping for another app wake.
        // The shared window caps overlapping callers too: six sources and 32
        // provider queries in total, always subject to the parent's deadline.
        var attempts = 0
        repeat {
            schedule()
            while isBusy {
                guard allowed(), !Task.isCancelled else { return false }
                do { try await Task.sleep(nanoseconds: 20_000_000) }
                catch { return false }
            }
            attempts += 1
            guard allowed(), !hasBlockingError, hasPendingExportWork,
                  attempts < 3, executionWindow.hasBackgroundBatchBudget else { break }
            needsDiscovery = true
        } while true
        return allowed() && !hasBlockingError && !hasPendingExportWork
    }

    func expireBackgroundWork() {
        executionWindow.removeSystemPermits()
        if !executionWindow.isAllowed && !persistsStop {
            needsReload = true; needsDiscovery = true
            stop()
        }
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled { pause(); return }
        run(.setEnabled(true))
    }

    func pause() {
        providerMonitor?.stop(); needsProviderRefresh = false
        worker.stopImmediately(disconnecting: false)
        isEnabled = false
        run(.setEnabled(false))
    }

    func disconnect() {
        providerMonitor?.stop(); needsProviderRefresh = false
        // Invalidate the shared gate synchronously, before the worker can start
        // another coordinated commit. Already committed cloud files are retained.
        worker.stopImmediately(disconnecting: true)
        isConnected = false; isEnabled = false
        run(.disconnect)
    }

    func suspendForBackground() {
        // A signal received while another batch was busy still invalidates
        // checked paths. Preserve it until a worker has durably accepted it.
        providerMonitor?.stop()
        let wasForeground = foreground
        foreground = false
        executionWindow.setForeground(false)
        // A local pause/disconnect is short and must remain durable even when
        // the user immediately locks the phone. It never starts provider IO.
        if wasForeground || !executionWindow.isAllowed {
            needsDiscovery = true; needsReload = true
            if !persistsStop { stop() }
        }
        if !persistsStop { schedule() }
        activity = persistsStop ? "正在保存停止同步的本机设置。" : "已启用的队列会在系统给予后台时间或下次前台时继续；已写入文件由 iCloud 上传。"
    }

    private func canonical(_ manifests: [SegmentManifest]) -> [SegmentManifest] {
        manifests.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func stop() {
        if isBusy { diagnosticOperationFailed = true }
        gate.cancel(); task?.cancel(); task = nil
        generation &+= 1; isBusy = false; persistsStop = false
    }

    private func providerDidChange() {
        guard foreground, isConnected, isEnabled else { return }
        providerNotificationGeneration &+= 1
        needsProviderRefresh = true
        cloudConfirmedRecordingIDs.removeAll()
        // A callback already queued before a provider failure still invalidates
        // the next authorized retry. It cannot restart a currently blocked run.
        if !hasBlockingError { schedule() }
    }

    private func schedule() {
        guard executionWindow.isAllowed, !isBusy, !recoveryConfirmationRequired else { return }
        if needsReload { run(.load); return }
        guard isConnected, isEnabled else { return }
        // Discovery gets a bounded opportunity even during notification storms.
        // Its command durably accepts any pending invalidation before exporting
        // or publishing, so fairness cannot revive an older checked positive.
        if (needsDiscovery || (foreground && needsSyncContinuation)) && (foreground || executionWindow.takeBackgroundBatch()) {
            let continuation = !needsDiscovery && needsSyncContinuation
            needsDiscovery = false
            let priorityIDs = Set(pendingTranscriptRequests.keys.sorted { $0.uuidString < $1.uuidString }.prefix(16))
            run(.sync(knownManifests, receivedIDs, maximumJobs: 2,
                      priorityTranscriptIDs: priorityIDs, providerChanged: needsProviderRefresh,
                      foregroundSlice: foreground, continuation: continuation))
            return
        }
        if needsProviderRefresh {
            run(.refreshProviderStatus)
            return
        }
        if foreground && needsProviderContinuation { run(.continueProviderStatus) }
    }

    private func run(_ command: ICloudDriveLibraryCommand) {
        let refreshGeneration: UInt64?
        switch command {
        case .refreshProviderStatus, .sync(_, _, _, _, true, _, _): refreshGeneration = providerNotificationGeneration
        default: refreshGeneration = nil
        }
        let transcriptRequests: [UUID: UUID]
        if case .sync(_, _, _, let ids, _, _, _) = command {
            transcriptRequests = pendingTranscriptRequests.filter { ids.contains($0.key) }
        } else { transcriptRequests = [:] }
        switch command {
        case .load, .authorize, .setEnabled(true): needsDiscovery = true
        case .connect, .confirmDirectoryRecovery, .cancelDirectoryRecovery, .disconnect: needsDiscovery = false
        default: break
        }
        switch command {
        case .connect, .confirmDirectoryRecovery, .cancelDirectoryRecovery, .authorize, .setEnabled, .disconnect:
            // These commands replace or consume a pending candidate. Clear the
            // UI prompt even if a later worker failure cannot publish state.
            recoveryConfirmationRequired = false
        default: break
        }
        stop()
        if case .load = command { needsReload = false }
        let window = executionWindow
        let providerAllowed: (@Sendable () -> Bool)?
        switch command {
        case .load, .sync, .refreshProviderStatus, .continueProviderStatus, .inspectProviderStatus: providerAllowed = { window.isAllowed }
        default: providerAllowed = nil
        }
        let token = generation, gate = ICloudDriveCancellation(providerAllowed: providerAllowed,
            takeProviderMetadataPermit: { window.takeProviderMetadataPermit() }), worker = worker
        self.gate = gate; isBusy = true; error = sourceWarning; hasBlockingError = false
        busyMessage = ICloudDriveWorkPhase.preparing.message
        if case .inspectProviderStatus = command { busyMessage = ICloudDriveWorkPhase.checkingCloud.message }
        switch command { case .disconnect, .setEnabled(false): persistsStop = true; default: break }
        task = Task { [weak self] in
            var completed = false
            let phase: @Sendable (ICloudDriveWorkPhase) -> Void = { [weak self] phase in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, gate.isCurrent, self.isBusy else { return }
                    self.busyMessage = phase.message
                    self.activity = phase.detail
                }
            }
            let work = Task.detached(priority: .utility) { try await worker.perform(command, gate: gate, phase: phase) }
            do {
                let state = try await withTaskCancellationHandler { try await work.value }
                    onCancel: { gate.cancel(); work.cancel() }
                guard let self, self.generation == token, gate.isCurrent else { return }
                self.publish(state)
                if self.needsProviderRefresh, refreshGeneration != self.providerNotificationGeneration {
                    self.cloudConfirmedRecordingIDs.removeAll()
                }
                if let refreshGeneration, refreshGeneration == self.providerNotificationGeneration, state.blockingError == nil {
                    self.needsProviderRefresh = false
                }
                for (id, request) in transcriptRequests where state.handledTranscriptRequestIDs.contains(id)
                    && self.pendingTranscriptRequests[id] == request {
                    self.pendingTranscriptRequests.removeValue(forKey: id)
                }
                if state.blockingError == nil && !self.pendingTranscriptRequests.isEmpty { self.needsDiscovery = true }
                self.needsReload = false
                completed = true
            } catch is CancellationError {
                if let self, self.generation == token {
                    self.needsReload = true; self.needsDiscovery = true
                    self.diagnosticOperationFailed = true
                }
            }
            catch {
                guard let self, self.generation == token else { return }
                self.error = error.localizedDescription
                self.hasBlockingError = true
                self.providerMonitor?.stop()
                self.diagnosticOperationFailed = true
                self.activity = "本轮未完成；原录音和已写入的云盘文件仍保留。"
                self.needsReload = true; self.needsDiscovery = true
            }
            guard let self, self.generation == token else { return }
            self.task = nil; self.isBusy = false; self.persistsStop = false
            // A status button must not release queued discovery/export work,
            // even when saving was already enabled before this explicit check.
            if case .inspectProviderStatus = command { return }
            if completed && !self.hasBlockingError {
                // Each metadata batch is a separate execution slice. Keep the
                // task busy while yielding so foreground/stop callbacks win
                // before another batch, without granting a background wake.
                if self.foreground && (self.needsProviderContinuation || self.needsSyncContinuation) {
                    self.isBusy = true
                    await Task.yield()
                    guard self.generation == token, gate.isCurrent else { return }
                    self.isBusy = false
                }
                self.schedule()
            }
        }
    }

    private func publish(_ state: ICloudDriveLibraryState) {
        needsProviderContinuation = state.needsProviderContinuation
        needsSyncContinuation = state.needsSyncContinuation
        diagnosticObservation = state.diagnosticObservation
        diagnosticOperationFailed = false
        folderName = state.folderName; isConnected = state.connected
        isEnabled = state.enabled; scope = state.scope
        authorizedManifests = state.authorizedManifests
        locallyWrittenRecordingIDs = state.locallyWrittenRecordingIDs
        cloudConfirmedRecordingIDs = state.cloudConfirmedRecordingIDs
        authorizedCount = state.authorizedCount; savedAudioCount = state.savedAudioCount
        savedTranscriptCount = state.savedTranscriptCount; uploadedFileCount = state.uploadedFileCount
        hasPendingFiles = state.hasPendingFiles
        pendingCloudFileCount = state.pendingCloudFileCount; activity = state.activity
        sourceWarning = state.sourceWarning
        hasBlockingError = state.blockingError != nil
        error = state.error
        recoveryConfirmationRequired = state.recoveryConfirmationRequired
        providerMonitor?.observe(foreground && state.enabled && state.blockingError == nil ? state.providerObservationURL : nil)
    }
}

/// A process-local permission to use already-granted execution time. Closures
/// read the parent's cancellation/deadline; this object cannot wake the app.
private final class ICloudDriveExecutionWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var foreground = false
    private var permits: [UUID: (systemGranted: Bool, allowed: @Sendable () -> Bool)] = [:]
    private var backgroundBatches = 3
    private var providerMetadataPermits = 32
    func setForeground(_ value: Bool) { lock.lock(); foreground = value; lock.unlock() }
    func add(_ id: UUID, systemGranted: Bool, allowed: @escaping @Sendable () -> Bool) {
        lock.lock()
        if !permits.values.contains(where: { $0.allowed() }) {
            backgroundBatches = 3; providerMetadataPermits = 32
        }
        permits[id] = (systemGranted, allowed); lock.unlock()
    }
    func remove(_ id: UUID) { lock.lock(); permits.removeValue(forKey: id); lock.unlock() }
    func removeSystemPermits() { lock.lock(); permits = permits.filter { !$0.value.systemGranted }; lock.unlock() }
    var isAllowed: Bool {
        lock.lock(); let active = foreground, values = Array(permits.values); lock.unlock()
        return active || values.contains { $0.allowed() }
    }
    var hasBackgroundBatchBudget: Bool {
        lock.lock(); defer { lock.unlock() }; return backgroundBatches > 0
    }
    func takeBackgroundBatch() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard backgroundBatches > 0 else { return false }
        backgroundBatches -= 1; return true
    }
    func takeProviderMetadataPermit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if foreground { return true }
        guard providerMetadataPermits > 0 else { return false }
        providerMetadataPermits -= 1; return true
    }
}

/// Shared with the blocking coordinator accessor. Actor messages alone cannot
/// cancel an accessor that is waiting for a file provider to grant coordination.
private final class ICloudDriveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let providerAllowed: (@Sendable () -> Bool)?
    private let takeProviderMetadataPermit: (@Sendable () -> Bool)?
    init(providerAllowed: (@Sendable () -> Bool)? = nil,
         takeProviderMetadataPermit: (@Sendable () -> Bool)? = nil) {
        self.providerAllowed = providerAllowed; self.takeProviderMetadataPermit = takeProviderMetadataPermit
    }
    var isCurrent: Bool {
        lock.lock(); let current = !cancelled; lock.unlock()
        return current && (providerAllowed?() ?? true)
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { guard isCurrent, !Task.isCancelled else { throw CancellationError() } }
    func takeMetadataPermit() -> Bool { takeProviderMetadataPermit?() ?? true }
}

private enum ICloudDriveWorkPhase: Sendable {
    case preparing, saving, checkingCloud
    var message: String {
        switch self {
        case .preparing: return "正在检查新增内容…"
        case .saving: return "正在写入目录…"
        case .checkingCloud: return "正在核对上传状态…"
        }
    }
    var detail: String {
        switch self {
        case .preparing: return "正在核对本机授权、新增录音与转写。"
        case .saving: return "正在将未提交的录音或文字写入所选目录。"
        case .checkingCloud: return "正在核对已写入文件的 iCloud 状态；实际传输由系统完成。"
        }
    }
}

private enum ICloudDriveLibraryCommand: Sendable {
    case load
    case connect(URL)
    case confirmDirectoryRecovery, cancelDirectoryRecovery
    case authorize(ICloudDriveRecordingScope, [SegmentManifest], Set<UUID>)
    case setEnabled(Bool)
    case sync([SegmentManifest]?, Set<UUID>?, maximumJobs: Int? = nil, priorityTranscriptIDs: Set<UUID> = [], providerChanged: Bool = false, foregroundSlice: Bool = false, continuation: Bool = false)
    case disconnect
    case refreshProviderStatus
    case continueProviderStatus
    case inspectProviderStatus
}

private struct ICloudDriveLibraryState: Sendable {
    let folderName: String
    let connected: Bool
    let enabled: Bool
    let scope: ICloudDriveRecordingScope?
    let authorizedManifests: [SegmentManifest]
    let locallyWrittenRecordingIDs: Set<UUID>
    let cloudConfirmedRecordingIDs: Set<UUID>
    let authorizedCount: Int
    let savedAudioCount: Int
    let savedTranscriptCount: Int
    let hasPendingFiles: Bool
    let handledTranscriptRequestIDs: Set<UUID>
    let uploadedFileCount: Int
    let pendingCloudFileCount: Int
    let activity: String
    let blockingError: String?
    let sourceWarning: String?
    var error: String? { blockingError ?? sourceWarning }
    let diagnosticObservation: ICloudDriveDiagnosticObservation
    let providerObservationURL: URL?
    let needsProviderContinuation: Bool
    let needsSyncContinuation: Bool
    let recoveryConfirmationRequired: Bool
}

private enum ICloudDriveLibraryFailure: LocalizedError, Equatable {
    case unavailableState, permissionLost, staleBookmark, notICloud, changedFolder
    case directoryUnavailable, coordinatedLocationChanged, markerMissing, markerInvalid, markerMismatch
    case recoveryConfirmationRequired, recoveryCandidateChanged
    var errorDescription: String? {
        switch self {
        case .unavailableState: return "iCloud Drive 本机授权记录无法核对，已暂停同步。原录音仍保留。"
        case .permissionLost: return "所选文件夹的访问权限已失效。请重新选择原 iCloud Drive 文件夹。"
        case .staleBookmark: return "所选文件夹的访问记录已过期，未继续写入。请重新选择原文件夹。"
        case .notICloud: return "无法确认这是 iCloud Drive 文件夹。请在系统文件选择器中进入 iCloud Drive 后选择文件夹。"
        case .changedFolder: return "所选文件夹无法确认为原同步目录，本次未继续写入。请选择原录音库所在的文件夹；原授权范围保持不变，不会覆盖已有文件。"
        case .directoryUnavailable: return "暂时无法读取原 iCloud Drive 目录或资料库标记，本次未继续写入。请稍后重试；原授权和文件保留。"
        case .coordinatedLocationChanged: return "系统协调读取时返回了不同的目录位置，本次未继续读取或写入。请稍后重试或重新选择原目录；原授权和文件保留。"
        case .markerMissing: return "原资料库目录或标记暂不可见，尚不能恢复连接。请确认原目录已在 iCloud Drive 中可用后重试；不会新建或覆盖标记。"
        case .markerInvalid: return "原资料库标记无法完整读取或解析，本次未继续写入。请先核对目录状态；不会覆盖标记。"
        case .markerMismatch: return "所选目录的资料库标记与原授权不符，不能沿用原录音范围。未更换目录或覆盖文件。"
        case .recoveryConfirmationRequired: return "系统返回的目录标识已变化，但资料库标记匹配。标记副本不能证明这就是原目录，请单独确认后再恢复；持续保存仍不会自动开启。"
        case .recoveryCandidateChanged: return "待恢复目录或原授权在确认前发生变化，未恢复连接。请重新选择并核对原目录。"
        }
    }
}

/// Fixed-size, path-free diagnostic facts. The marker body, bookmark, library
/// UUID, provider identifier and NSError descriptions never enter this report.
private struct ICloudDriveDirectoryDiagnostic: Codable, Sendable {
    struct Step: Codable, Sendable { let stage: String; let result: String; let code: String?; let posixErrno: Int? }
    let schemaVersion = 1
    let scope = "directory_marker_check_only"
    let build: String
    let attemptID: UUID
    let operation: String
    let startedAtMS: Int64
    var observedAtMS: Int64
    var stage = "starting"
    var result = "checking"
    var code: String?
    var underlyingDomain: String?
    var underlyingCode: Int?
    var posixErrno: Int?
    var identityMatched: Bool?
    var identityReference = "persisted"
    var persistentIdentityAvailable: Bool?
    var markerMatched: Bool?
    var confirmationRequired = false
    var steps: [Step] = []
    let audioRead = false
    let markerWritten = false
    let scopeChanged = false
}

/// Every method runs on this utility actor. No audio, bookmark resolution, file
/// coordination, or local state serialization runs on the main UI actor.
private actor ICloudDriveLibraryWorker {
    /// Metadata-only continuation state. Its failure must not invalidate the
    /// independent recording grant or cause an exported CAF to be read again.
    private struct ProviderFileStamp: Codable, Equatable {
        let device: Int64, inode: UInt64, byteCount: Int64
        let modifiedSeconds: Int64, modifiedNanoseconds: Int64
        let changedSeconds: Int64, changedNanoseconds: Int64
        init?(_ target: URL) {
            var info = stat()
            guard lstat(target.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { return nil }
            device = Int64(info.st_dev); inode = UInt64(info.st_ino); byteCount = Int64(info.st_size)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec); changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
        func matches(_ expected: ICloudDriveFileIdentity) -> Bool {
            UInt64(UInt32(truncatingIfNeeded: device)) == expected.device && inode == expected.inode
                && byteCount == expected.byteCount && modifiedSeconds == expected.modificationSeconds
                && modifiedNanoseconds == expected.modificationNanoseconds
                && changedSeconds == expected.changeSeconds && changedNanoseconds == expected.changeNanoseconds
        }
        /// Diagnostic components only, never permission to ignore a mismatch.
        /// device/inode/size/mtime/ctime occupy bits 0...4 respectively.
        func mismatchBits(_ expected: ICloudDriveFileIdentity) -> Int {
            var bits = 0
            if UInt64(UInt32(truncatingIfNeeded: device)) != expected.device { bits |= 1 }
            if inode != expected.inode { bits |= 2 }
            if byteCount != expected.byteCount { bits |= 4 }
            if modifiedSeconds != expected.modificationSeconds || modifiedNanoseconds != expected.modificationNanoseconds { bits |= 8 }
            if changedSeconds != expected.changeSeconds || changedNanoseconds != expected.changeNanoseconds { bits |= 16 }
            return bits
        }
        var valid: Bool {
            inode > 0 && byteCount >= 0 && (0..<1_000_000_000).contains(modifiedNanoseconds)
                && (0..<1_000_000_000).contains(changedNanoseconds)
        }
    }
    private struct ProviderObservation: Codable {
        let uploaded: Bool
        let observedAtMS: Int64
        let stamp: ProviderFileStamp?
        var failureCode: String? = nil
        var identityMismatchBits: Int? = nil
        /// Marker and commit bodies validated on this observation. Absent means
        /// the path still needs an export identity or a content check.
        var contentValidated: Bool? = nil
        var status: ICloudDriveProviderObservationStatus? = nil
        var firstConfirmedAtMS: Int64? = nil
        var latestConfirmedAtMS: Int64? = nil
        var outcome: ICloudDriveProviderObservationStatus {
            .restored(status, legacyUploaded: uploaded, legacyFailureCode: failureCode)
        }
    }
    private struct RepairDiagnostics: Codable {
        var attempted = 0
        var completed = 0
        var deferred = 0
        var conflicts = 0
        var lastOutcome = 0
        var lastAtMS: Int64 = 0
        var valid: Bool {
            [attempted, completed, deferred, conflicts].allSatisfy { (0...1_000_000).contains($0) }
                && (0...3).contains(lastOutcome) && lastAtMS >= 0
        }
    }
    private struct ProviderEvidence: Codable {
        let schemaVersion: Int
        let libraryID: UUID
        let folderIdentity: String
        var nextPath: String?
        var observations: [String: ProviderObservation]
        var localExportedAtMS: [String: Int64]
        var repairNextID: UUID? = nil
        var preferRepairNext: Bool? = nil
        // New sources lead; every second export turn admits historical work.
        // Both the class turn and old-source cursor survive an expired lease.
        var preferHistoricalExportNext: Bool? = nil
        var historicalExportNextID: UUID? = nil
        var transcriptNextID: UUID? = nil
        var transcriptVisitedIDs = Set<UUID>()
        var transcriptIssueIDs = Set<UUID>()
        // Optional additions keep existing schema-1 diagnostic caches readable.
        var cacheResetReason: Int? = nil
        var cacheResetCount: Int? = nil
        /// New exports whose destination conflicted. They rotate with repairs
        /// instead of blocking the next new export.
        var exportConflictIDs: [UUID]? = nil
        /// A source whose current manifest/receipt no longer matches its grant
        /// gets an independent metadata retry in the same fair repair rotation.
        var sourceMetadataIssueIDs: [UUID]? = nil
        /// A notification invalidates provider status independently of local
        /// identity. Keep unchecked observations historical-only across restart.
        var providerChangePending: Bool? = nil
        /// One bounded cohort, never reset by a notification while in flight.
        /// Missing in older caches means every expected path is unchecked.
        var providerChangeUncheckedPaths: Set<String>? = nil
        /// All signals received during a cohort coalesce into one following
        /// generation. While set, prior positives are historical-only.
        var providerChangeReplayPending: Bool? = nil
        var providerGeneration: Int? = nil
        var providerPriorityPaths: Set<String>? = nil
        var preferHistoricalProviderNext: Bool? = nil
        // Reserve a bounded share for explicit provider-pending observations.
        // Both cursors survive cold execution opportunities; neither confirms
        // upload or permits opening recording content.
        var pendingProviderNextPath: String? = nil
        var preferPendingProviderNext: Bool? = nil
        // Diagnostic only; never an upload receipt, retry gate or cleanup proof.
        var repairDiagnostics: RepairDiagnostics? = nil
    }
    /// Fixed diagnostics only. No paths, identities or arbitrary error strings.
    private enum CacheResetReason: Int { case none, missing, invalid, folderChanged, authorizationUnavailable, disconnected, paused }
    private enum RoundPhase: Int { case idle, loading, target, discovery, export, provider }
    private static let providerBatchLimit = 32
    private static let maximumProviderEvidenceBytes = 16 * 1_024 * 1_024
    private struct Connection: Codable, Equatable {
        let bookmark: Data
        let folderName: String
    }
    private struct Persisted: Codable, Equatable {
        let schemaVersion: Int
        var ledger: ICloudDriveLibraryLedger
        var connection: Connection?
        var folderIdentity: String?
        // Optional schema-1 extension. The legacy resource digest remains a
        // cache binding and a fallback, never overrides a persistent identity.
        var persistentFolderIdentityV1: String? = nil
        var committedReceiptPaths: Set<String>?
    }
    private let repository: RecordingRepository
    private let transcripts: TranscriptRepository
    private let stateURL: URL
    private let providerEvidenceURL: URL
    private let directoryDiagnosticURL: URL
    private let syncEvidence: SyncEvidenceArchive
    private let folderAccess: ICloudDriveFolderAccess
    nonisolated private let stopFence: ICloudDriveStopFence
    private var value = Persisted(schemaVersion: 1, ledger: ICloudDriveLibraryLedger(), connection: nil, folderIdentity: nil, committedReceiptPaths: [])
    private var loaded = false
    private var unavailable = false
    private var activity = "先选择 iCloud Drive 文件夹，再单独确认录音同步范围。"
    private var lastError: String?
    private var uploaded = 0
    private var uploadedPaths: Set<String> = []
    private var awaitingCloud = 0
    private var providerEvidence: ProviderEvidence?
    private var providerEvidenceLoaded = false
    private var providerEvidenceUnavailable = false
    private var cloudMetadataCheckedThisRound = 0
    private var providerPathsCheckedThisRound = Set<String>()
    private var sourceDiscoveryCompleted = false
    private var handledTranscriptRequestIDs = Set<UUID>()
    private var sourceDiscoveryPassCount = 0
    private var sourceDiscoveryManifestCount = 0
    private var sourceDiscoveryReceivedCount = 0
    private var transcriptInspectedThisRound = 0
    private var providerTargetAvailable = false
    private var providerObservationURL: URL?
    // One foreground discovery opportunity is drained in small commands. A bad
    // source is attempted once per opportunity; it cannot create a retry loop.
    private var foregroundAttemptedIDs = Set<UUID>()
    // A failed validation must not create an automatic export loop.
    private var attemptedIdentityRepairStamps: [UUID: [String: ProviderFileStamp]] = [:]
    private var foregroundInspectedIDs = Set<UUID>()
    private var foregroundDiscovery: (manifests: [SegmentManifest], received: Set<UUID>)?
    private var needsSyncContinuation = false
    private var cacheResetReason = CacheResetReason.none
    private var cacheResetCount = 0
    private var roundPhase = RoundPhase.idle
    private var expiredAtPhase = RoundPhase.idle
    private var phaseExpiryCount = 0
    private var progressedSourceIDs = Set<UUID>()
    private var firstProgressPhase = 0 // 0 none, 1 durable export, 2 provider confirmation
    private var backgroundRound = false
    private var roundSequence = 0
    private var roundStartedAtMS: Int64 = 0
    private var roundFinishedAtMS: Int64 = 0
    private struct RecoveryCandidate {
        let original: Persisted
        let originalStateBytes: Data
        let connection: Connection
        let identity: String
        let persistentIdentity: String?
        let previousError: String?
        let previousActivity: String
    }
    private var recoveryCandidate: RecoveryCandidate?
    private var directoryDiagnostic: ICloudDriveDirectoryDiagnostic?

    init(repository: RecordingRepository, transcriptRepository: TranscriptRepository,
         folderAccess: ICloudDriveFolderAccess) {
        self.repository = repository; transcripts = transcriptRepository
        self.folderAccess = folderAccess
        stateURL = repository.root.appendingPathComponent("ICloudDriveLibrary/state.json")
        providerEvidenceURL = repository.root.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json")
        directoryDiagnosticURL = repository.root.appendingPathComponent("ICloudDriveLibrary/directory-recovery.json")
        syncEvidence = SyncEvidenceArchive(root: repository.root, stream: "icloud_drive")
        stopFence = ICloudDriveStopFence(file: repository.root.appendingPathComponent("ICloudDriveLibrary/stop-intent.json"))
    }

    func observeVerifiedMetadata(sourceDidChange: Bool = false, onThrottle: (@Sendable (Int) -> Void)? = nil) {
        _ = syncEvidence.observe(processRunID: VerifiedObservationPublisher.processRunID, sourceDidChange: sourceDidChange, onThrottle: onThrottle)
    }

    nonisolated func stopImmediately(disconnecting: Bool) { stopFence.stop(disconnecting: disconnecting) }

    func perform(_ command: ICloudDriveLibraryCommand, gate: ICloudDriveCancellation,
                 phase: @Sendable (ICloudDriveWorkPhase) -> Void = { _ in }) throws -> ICloudDriveLibraryState {
        try gate.check()
        let previousError = lastError, previousActivity = activity
        switch command {
        case .connect: beginDirectoryDiagnostic("reselect"); recoveryCandidate = nil
        case .confirmDirectoryRecovery: beginDirectoryDiagnostic("confirm_recovery")
        case .cancelDirectoryRecovery: beginDirectoryDiagnostic("cancel_recovery")
        case .load:
            if recoveryCandidate != nil { return state() }
            beginDirectoryDiagnostic("load")
        case .setEnabled(true): beginDirectoryDiagnostic("enable"); recoveryCandidate = nil
        case .authorize: beginDirectoryDiagnostic("authorize"); recoveryCandidate = nil
        case .disconnect: beginDirectoryDiagnostic("disconnect"); recoveryCandidate = nil
        case .setEnabled(false): beginDirectoryDiagnostic("pause"); recoveryCandidate = nil
        case .sync:
            if recoveryCandidate != nil { return state() }
            beginDirectoryDiagnostic("sync")
        case .refreshProviderStatus:
            if recoveryCandidate != nil { return state() }
            beginDirectoryDiagnostic("provider_refresh")
        case .continueProviderStatus:
            if recoveryCandidate != nil { return state() }
            beginDirectoryDiagnostic("provider_continue")
        case .inspectProviderStatus:
            if recoveryCandidate != nil { return state() }
            beginDirectoryDiagnostic("provider_inspect")
        }
        if case .sync(_, _, let maximumJobs, _, _, let foregroundSlice, _) = command {
            progressedSourceIDs.removeAll()
            firstProgressPhase = 0
            backgroundRound = maximumJobs != nil && !foregroundSlice
            if roundSequence < Int.max { roundSequence += 1 }
            roundStartedAtMS = Self.nowMS(); roundFinishedAtMS = 0
        }
        roundPhase = .loading
        providerTargetAvailable = false
        if case .inspectProviderStatus = command { phase(.checkingCloud) }
        else { phase(.preparing) }
        do { try directoryStep("load_state") { try load() } }
        catch { syncEvidence.markUnavailable(); throw error }
        defer {
            if !gate.isCurrent || Task.isCancelled {
                expiredAtPhase = roundPhase
                if phaseExpiryCount < Int.max { phaseExpiryCount += 1 }
            }
            if case .sync = command { roundFinishedAtMS = Self.nowMS() }
            publishSyncEvidence()
            roundPhase = .idle
        }
        loadProviderEvidence()
        try directoryStep("load_stop_fence") {
            if case .inspectProviderStatus = command { try applyStopFence(preservingPausedObservations: true) }
            else { try applyStopFence() }
        }
        guard !unavailable else { throw ICloudDriveLibraryFailure.unavailableState }
        lastError = nil
        // Each opportunity starts with unknown provider status; a failed target
        // check cannot leave an old "uploaded" count attached to a new failure.
        uploaded = 0
        uploadedPaths.removeAll()
        cloudMetadataCheckedThisRound = 0
        providerPathsCheckedThisRound.removeAll(keepingCapacity: true)
        transcriptInspectedThisRound = 0
        handledTranscriptRequestIDs.removeAll()
        awaitingCloud = expectedCloudPaths().count + (hasUnknownReceiptIndex ? 1 : 0)
        switch command {
        case .load:
            if value.connection != nil {
                do {
                    try withTarget(gate: gate) { folder in
                        if value.ledger.recordingScope != nil { try verifyMarker(in: folder, allowMissingIfUncommitted: true, gate: gate) }
                        if value.persistentFolderIdentityV1 == nil,
                           let persistent = try folderAccess.persistentIdentity?(folder) {
                            try gate.check()
                            guard try folderAccess.identity(folder) == value.folderIdentity,
                                  try folderAccess.persistentIdentity?(folder) == persistent else {
                                throw ICloudDriveLibraryFailure.changedFolder
                            }
                            // Migration must not overwrite an authorization or
                            // bookmark changed while provider metadata was read.
                            guard let bytes = try RecordingMetadataAccess.readIfPresent(at: stateURL,
                                maximumBytes: 32 * 1_024 * 1_024),
                                  try TransportCodec.decode(Persisted.self, from: bytes) == value else {
                                throw ICloudDriveLibraryFailure.recoveryCandidateChanged
                            }
                            var next = value
                            next.persistentFolderIdentityV1 = persistent
                            try persist(next, gate: gate)
                        }
                        // Loading restores authorization and validates the target.
                        // The following enabled sync performs one cloud scan.
                    }
                    activity = value.ledger.recordingScope == nil
                        ? "已恢复文件夹访问记录；尚未授权录音导出。"
                        : (value.ledger.enabled ? "已恢复独立授权，将在可用的前台或后台时间继续增量处理。" : "iCloud Drive 同步已暂停。")
                } catch is CancellationError { throw CancellationError() }
                catch { try stopForFailure(error, gate: gate) }
            }
        case .connect(let selected):
            try gate.check()
            try directoryStep("security_scope") {
                guard folderAccess.start(selected) else { throw ICloudDriveLibraryFailure.permissionLost }
            }
            defer { folderAccess.stop(selected) }
            try gate.check()
            try directoryStep("folder_validate") { try validateFolder(selected) }
            try gate.check()
            let identity = try directoryStep("folder_identity") { try folderAccess.identity(selected) }
            let persistentIdentity = try folderAccess.persistentIdentity?(selected)
            try gate.check()
            if value.ledger.recordingScope != nil {
                let matches = try directoryMatches(resource: identity, persistent: persistentIdentity)
                directoryDiagnostic?.identityMatched = matches
                if !matches {
                    // An exact marker can be copied. It only enables an explicit
                    // human decision, never automatic adoption of this folder.
                    try inspectMarker(in: selected, gate: gate)
                    let originalBytes = try directoryStep("grant_binding") {
                        guard let bytes = try RecordingMetadataAccess.readIfPresent(at: stateURL,
                            maximumBytes: 32 * 1_024 * 1_024) else { throw ICloudDriveLibraryFailure.unavailableState }
                        return bytes
                    }
                    let bookmark = try directoryStep("bookmark_create") { try folderAccess.bookmark(selected) }
                    guard bookmark.count <= 2 * 1_024 * 1_024 else { throw ICloudDriveLibraryFailure.unavailableState }
                    recoveryCandidate = RecoveryCandidate(original: value, originalStateBytes: originalBytes,
                        connection: Connection(bookmark: bookmark, folderName: selected.lastPathComponent),
                        identity: identity, persistentIdentity: persistentIdentity, previousError: previousError, previousActivity: previousActivity)
                    lastError = ICloudDriveLibraryFailure.recoveryConfirmationRequired.localizedDescription
                    activity = "等待确认这是否为原同步目录；尚未更换访问记录，也未开启持续保存。"
                    finishDirectoryDiagnostic("pending_confirmation", code: "identity_changed_marker_matches")
                    return state()
                }
                try directoryStep("identity_compare") { }
                try verifyMarker(in: selected, allowMissingIfUncommitted: true, gate: gate)
            }
            let bookmark = try directoryStep("bookmark_create") { try folderAccess.bookmark(selected) }
            guard bookmark.count <= 2 * 1_024 * 1_024 else { throw ICloudDriveLibraryFailure.unavailableState }
            var next = value
            try next.ledger.setEnabled(false)
            next.connection = Connection(bookmark: bookmark, folderName: selected.lastPathComponent)
            next.folderIdentity = identity
            next.persistentFolderIdentityV1 = persistentIdentity
            try directoryStep("save_connection") { try persist(next, gate: gate) }
            try directoryStep("save_stop_fence") { try stopFence.connectPaused(gate: gate) }
            activity = value.ledger.recordingScope == nil
                ? "已选择 iCloud Drive 文件夹。尚未导出；请选择范围并明确开启同步。"
                : "已连接原录音库。原授权范围不变，请明确继续同步。"
            finishDirectoryDiagnostic("connected_paused")
        case .confirmDirectoryRecovery:
            guard let candidate = recoveryCandidate else {
                try directoryStep("candidate_binding") { throw ICloudDriveLibraryFailure.recoveryCandidateChanged }
                break
            }
            defer {
                recoveryCandidate = nil
                // A failed confirmation consumes the volatile candidate too;
                // publish that final projection after the failing step report.
                persistDirectoryDiagnostic()
            }
            try directoryStep("candidate_binding") {
                guard value == candidate.original,
                      try RecordingMetadataAccess.readIfPresent(at: stateURL, maximumBytes: 32 * 1_024 * 1_024)
                        == candidate.originalStateBytes else { throw ICloudDriveLibraryFailure.recoveryCandidateChanged }
            }
            let resolved = try directoryStep("bookmark_resolve") { try folderAccess.resolve(candidate.connection.bookmark) }
            try gate.check()
            try directoryStep("bookmark_freshness") {
                guard !resolved.stale else { throw ICloudDriveLibraryFailure.staleBookmark }
            }
            try directoryStep("security_scope") {
                guard folderAccess.start(resolved.url) else { throw ICloudDriveLibraryFailure.permissionLost }
            }
            defer { folderAccess.stop(resolved.url) }
            try directoryStep("folder_validate") { try validateFolder(resolved.url) }
            try gate.check()
            let identity = try directoryStep("folder_identity") { try folderAccess.identity(resolved.url) }
            let persistentIdentity = try folderAccess.persistentIdentity?(resolved.url)
            directoryDiagnostic?.identityReference = "confirmed_candidate"
            directoryDiagnostic?.identityMatched = identity == candidate.identity
            try directoryStep("identity_compare") {
                guard identity == candidate.identity, persistentIdentity == candidate.persistentIdentity else { throw ICloudDriveLibraryFailure.recoveryCandidateChanged }
            }
            try inspectMarker(in: resolved.url, gate: gate)
            try gate.check()
            try directoryStep("final_identity_compare") {
                let matches = try folderAccess.identity(resolved.url) == candidate.identity
                directoryDiagnostic?.identityMatched = matches
                guard matches, try folderAccess.persistentIdentity?(resolved.url) == candidate.persistentIdentity,
                      value == candidate.original,
                      try RecordingMetadataAccess.readIfPresent(at: stateURL,
                          maximumBytes: 32 * 1_024 * 1_024) == candidate.originalStateBytes
                else { throw ICloudDriveLibraryFailure.recoveryCandidateChanged }
            }
            var next = value
            try next.ledger.setEnabled(false)
            next.connection = candidate.connection; next.folderIdentity = candidate.identity
            next.persistentFolderIdentityV1 = candidate.persistentIdentity
            try directoryStep("save_connection") { try persist(next, gate: gate) }
            try directoryStep("save_stop_fence") { try stopFence.connectPaused(gate: gate) }
            invalidateProviderEvidence(reason: .folderChanged)
            recoveryCandidate = nil
            lastError = nil
            activity = "已按你的确认恢复原资料库访问；原范围和进度保留，持续保存仍关闭。"
            finishDirectoryDiagnostic("recovered_paused", code: "explicit_identity_recovery")
        case .cancelDirectoryRecovery:
            if let candidate = recoveryCandidate {
                lastError = candidate.previousError; activity = candidate.previousActivity
            }
            recoveryCandidate = nil
            finishDirectoryDiagnostic("cancelled", code: "no_settings_changed")
        case .authorize(let scope, let manifests, let received):
            guard value.connection != nil else { throw ICloudDriveLibraryFailure.permissionLost }
            try withTarget(gate: gate) { folder in
                // No marker or recording is created by connection or account checks.
                // The first coordinated export creates this grant's marker later.
                if value.ledger.recordingScope != nil { try verifyMarker(in: folder, allowMissingIfUncommitted: true, gate: gate) }
            }
            var next = value
            try next.ledger.authorize(scope, knownIDs: Set(manifests.map(\.id)).union(received))
            try next.ledger.discover(manifests: manifests, receivedIDs: received)
            try persist(next, gate: gate)
            noteSourceDiscovery(manifests: manifests, received: received)
            sourceDiscoveryCompleted = false // transcript discovery follows in the first actual sync
            try stopFence.allow(gate: gate)
            activity = "已按本次独立选择启用 iCloud Drive，同步不改变 Google Drive 或旧首批范围。"
        case .setEnabled(let enabled):
            if !enabled { stopFence.stop(disconnecting: false) }
            var next = value
            if enabled {
                guard next.connection != nil else { throw ICloudDriveLibraryFailure.permissionLost }
                try withTarget(gate: gate) { folder in
                    try verifyMarker(in: folder, allowMissingIfUncommitted: true, gate: gate)
                }
            }
            try next.ledger.setEnabled(enabled)
            try persist(next, gate: gate)
            if enabled { try stopFence.allow(gate: gate) }
            else {
                try stopFence.flush()
                invalidateProviderEvidence(reason: .paused)
            }
            activity = enabled ? "已继续 iCloud Drive 增量同步。" : "已暂停 iCloud Drive 同步；原录音、云盘文件和授权范围均保留。"
        case .sync(let suppliedManifests, let suppliedReceived, let maximumJobs, let priorityTranscriptIDs, let providerChanged, let foregroundSlice, let continuation):
            guard value.ledger.enabled, value.connection != nil, recoveryCandidate == nil else { return state() }
            if providerChanged { acceptProviderChange() }
            do { try synchronize(suppliedManifests, received: suppliedReceived, maximumJobs: maximumJobs,
                                 priorityTranscriptIDs: priorityTranscriptIDs, foregroundSlice: foregroundSlice,
                                 continuation: continuation, gate: gate, phase: phase) }
            catch is CancellationError { throw CancellationError() }
            catch { try stopForFailure(error, gate: gate) }
        case .refreshProviderStatus, .continueProviderStatus:
            guard value.ledger.enabled, value.connection != nil, recoveryCandidate == nil else { return state() }
            if case .refreshProviderStatus = command { acceptProviderChange() }
            do {
                try withTarget(gate: gate) { folder in
                    // A cancelled marker check must not publish unchecked old
                    // positives from perform's deferred evidence snapshot.
                    providerTargetAvailable = false
                    try verifyMarker(in: folder, allowMissingIfUncommitted: true, gate: gate)
                    phase(.checkingCloud)
                    try gate.check()
                    providerTargetAvailable = true
                    try refreshCloudStatus(in: folder, gate: gate, maximumQueries: Self.providerBatchLimit)
                }
                queueIdentityRepairsAfterProviderChange()
                activity = "iCloud 状态已更新：累计确认 \(uploaded) 份、\(awaitingCloud) 份待确认；本轮仅核对元数据。"
            } catch is CancellationError { throw CancellationError() }
            catch { try stopForFailure(error, gate: gate) }
        case .inspectProviderStatus:
            // Reading the provider's acknowledgement is independent of whether
            // future exports are paused. No authorization or stop-fence write,
            // source discovery, transcript read, or export writer is invoked.
            guard value.connection != nil, value.ledger.recordingScope != nil,
                  recoveryCandidate == nil else { return state() }
            do {
                try withTarget(gate: gate) { folder in
                    try verifyMarker(in: folder, allowMissingIfUncommitted: true, gate: gate)
                    phase(.checkingCloud)
                    try refreshCloudStatus(in: folder, gate: gate, maximumQueries: Self.providerBatchLimit)
                }
                activity = "只读检查完成：累计确认 \(uploaded) 份、\(awaitingCloud) 份待确认；本轮仅核对 \(cloudMetadataCheckedThisRound) 份元数据。持续保存\(value.ledger.enabled ? "仍为开启" : "保持关闭")，未执行录音导出或校验。"
            } catch is CancellationError { throw CancellationError() }
            catch {
                // A failed inspection cannot rewrite an enabled grant or its
                // durable stop intent. Retain the failure as a status result.
                providerTargetAvailable = false
                uploaded = 0
                lastError = error.localizedDescription
                activity = "只读检查未完成；持续保存设置和原文件保持不变，未执行录音导出或校验。"
            }
        case .disconnect:
            stopFence.stop(disconnecting: true)
            var next = value
            try next.ledger.setEnabled(false)
            next.connection = nil
            try persist(next, gate: gate)
            try stopFence.flush()
            invalidateProviderEvidence(reason: .disconnected)
            uploaded = 0; awaitingCloud = 0
            activity = "已断开此文件夹并停止后续写入。云盘文件和原授权范围保留。"
        }
        try gate.check()
        return state()
    }

    private func applyStopFence(preservingPausedObservations: Bool = false) throws {
        let stop = try stopFence.current()
        if stop.stopped { try value.ledger.setEnabled(false) }
        if stop.disconnected { value.connection = nil }
        if stop.stopped, (!preservingPausedObservations || stop.disconnected),
           providerEvidence?.observations.isEmpty == false {
            invalidateProviderEvidence(reason: stop.disconnected ? .disconnected : .paused)
        }
    }

    private func load() throws {
        guard !loaded else { return }
        do {
            if let data = try RecordingMetadataAccess.readIfPresent(at: stateURL, maximumBytes: 32 * 1_024 * 1_024) {
                let restored = try TransportCodec.decode(Persisted.self, from: data)
                guard restored.schemaVersion == 1,
                      restored.connection.map({ !$0.bookmark.isEmpty && $0.bookmark.count <= 2 * 1_024 * 1_024 && $0.folderName.utf8.count <= 1_024 }) ?? true
                else { throw ICloudDriveLibraryFailure.unavailableState }
                try restored.ledger.validate()
                if let paths = restored.committedReceiptPaths {
                    let ids = Set(restored.ledger.jobs.map { $0.id.uuidString.lowercased() })
                    guard paths.count <= 100_000, paths.allSatisfy({ path in
                        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                        guard parts.count == 3, parts[0] == "commits", ids.contains(String(parts[1])),
                              parts[2].hasSuffix(".json") else { return false }
                        let digest = parts[2].dropLast(5)
                        return digest.count == 64 && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
                    }) else { throw ICloudDriveLibraryFailure.unavailableState }
                }
                guard restored.folderIdentity.map({ $0.count == 64 && $0.allSatisfy { $0.isHexDigit && !$0.isUppercase } }) ?? (restored.connection == nil && restored.ledger.recordingScope == nil),
                      restored.connection != nil || !restored.ledger.enabled else { throw ICloudDriveLibraryFailure.unavailableState }
                if let persistent = restored.persistentFolderIdentityV1 {
                    guard persistent.count == 64, persistent.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                          restored.folderIdentity != nil else { throw ICloudDriveLibraryFailure.unavailableState }
                }
                value = restored
            }
            loaded = true
        } catch {
            // A locked/unreadable file is not an empty grant or permanent
            // corruption. Keep loaded=false so the next real opportunity reads
            // the original bytes again. Invalid decoded state remains closed.
            if error is DecodingError || error is RecordingMetadataAccessError || error is ICloudDriveLibraryFailure {
                unavailable = true
            }
            throw ICloudDriveLibraryFailure.unavailableState
        }
    }

    private func persist(_ next: Persisted, gate: ICloudDriveCancellation) throws {
        try gate.check()
        try next.ledger.validate()
        do {
            try GoogleDriveLocalFiles.write(TransportCodec.encode(next), to: stateURL)
            value = next
        } catch {
            unavailable = true
            // Preserve the native metadata-write error for the bounded recovery
            // report instead of reducing a save failure to a generic category.
            if directoryDiagnostic?.stage == "save_connection" { throw error }
            throw ICloudDriveLibraryFailure.unavailableState
        }
    }

    private func stopForFailure(_ error: Error, gate: ICloudDriveCancellation) throws {
        try gate.check()
        // Current readiness fails closed, but a transient coordinator/export
        // failure is not evidence that every historical receipt or cursor is
        // invalid. Keep those as-of facts for the same verified grant.
        providerTargetAvailable = false
        if error as? ICloudDriveLibraryFailure == .changedFolder, value.ledger.recordingScope != nil {
            do {
                try prepareBookmarkedRecovery(gate: gate)
                invalidateProviderEvidence(reason: .folderChanged)
                return
            } catch is CancellationError { throw CancellationError() }
            catch {
                // A failed marker/permission check cannot create a candidate.
                // Retain the original rejection and normal fail-closed path.
                recoveryCandidate = nil
            }
        }
        let transient = error as? ICloudDriveLibraryFailure == .directoryUnavailable
            || error as? ICloudDriveLibraryFailure == .coordinatedLocationChanged
            || error as? ICloudDriveLibraryFailure == .markerMissing
        if error is ICloudDriveLibraryFailure && !transient {
            invalidateProviderEvidence(reason: error as? ICloudDriveLibraryFailure == .changedFolder
                ? .folderChanged : .authorizationUnavailable)
            // A rejected directory must not rewrite an already-paused grant.
            // Besides avoiding needless I/O, this preserves its exact durable
            // bytes until an explicit recovery or real enable-state change.
            if value.ledger.enabled {
                var next = value
                try next.ledger.setEnabled(false)
                try persist(next, gate: gate)
            }
        }
        lastError = error.localizedDescription
        activity = "本轮未完成，将在下次可用执行时间重试；原录音和已写入的云盘文件仍保留。"
    }

    private func state() -> ICloudDriveLibraryState {
        let hasCurrentProviderEvidence = providerTargetAvailable && !providerEvidenceUnavailable && lastError == nil
            && recoveryCandidate == nil
        var written: Set<UUID> = [], confirmed: Set<UUID> = []
        for job in value.ledger.jobs {
            let recordingFiles = job.artifacts.filter { $0.kind == .audio || $0.kind == .manifest }
            guard recordingFiles.count == 2,
                  recordingFiles.allSatisfy({ job.exportedKeys.contains($0.key) }) else { continue }
            written.insert(job.id)
            if hasCurrentProviderEvidence && recordingFiles.allSatisfy({ uploadedPaths.contains($0.relativePath) }) {
                confirmed.insert(job.id)
            }
        }
        return ICloudDriveLibraryState(folderName: value.connection?.folderName ?? "尚未选择 iCloud Drive 文件夹",
            connected: value.connection != nil, enabled: value.ledger.enabled && recoveryCandidate == nil, scope: value.ledger.recordingScope,
            authorizedManifests: value.ledger.jobs.map(\.manifest),
            locallyWrittenRecordingIDs: written, cloudConfirmedRecordingIDs: confirmed,
            authorizedCount: value.ledger.jobs.count, savedAudioCount: value.ledger.exportedAudioCount,
            savedTranscriptCount: value.ledger.exportedTranscriptCount, hasPendingFiles: value.ledger.hasPendingFiles,
            handledTranscriptRequestIDs: handledTranscriptRequestIDs,
            uploadedFileCount: uploaded,
            pendingCloudFileCount: awaitingCloud, activity: activity, blockingError: lastError,
            sourceWarning: sourceWarning(),
            diagnosticObservation: diagnosticState(),
            providerObservationURL: providerTargetAvailable && value.ledger.enabled ? providerObservationURL : nil,
            needsProviderContinuation: value.ledger.enabled && lastError == nil && providerTargetAvailable
                && !providerEvidenceUnavailable
                && (providerEvidence?.providerChangePending == true || providerEvidence?.providerChangeReplayPending == true),
            needsSyncContinuation: value.ledger.enabled && lastError == nil && needsSyncContinuation,
            recoveryConfirmationRequired: recoveryCandidate != nil)
    }

    /// These IDs are durable source-scoped findings. A provider-only command
    /// cannot resolve them and must not erase the warning or classify it as a
    /// provider/auth failure. Only a later source inspection clears its own ID.
    private func sourceWarning() -> String? {
        guard let evidence = providerEvidence, evidence.libraryID == value.ledger.libraryID,
              evidence.folderIdentity == value.folderIdentity else { return nil }
        var warnings: [String] = []
        if !evidence.transcriptIssueIDs.isEmpty {
            warnings.append("\(evidence.transcriptIssueIDs.count) 段本机转写未通过核对，未导出对应文字；原录音可单独同步。")
        }
        if let issues = evidence.sourceMetadataIssueIDs, !issues.isEmpty {
            warnings.append("\(issues.count) 段来源清单或持久收件未通过核对，已单独跳过；其余录音会继续同步。")
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }

    /// Read existing actor fields only. This must remain safe to include in a
    /// normal state result; no directory access, content verification or scan.
    private func diagnosticState() -> ICloudDriveDiagnosticObservation {
        let sameGrant = providerEvidence?.libraryID == value.ledger.libraryID
            && providerEvidence?.folderIdentity == value.folderIdentity
        let observations = sameGrant ? (providerEvidence?.observations ?? [:]) : [:]
        let failure: ICloudDriveDiagnosticObservation.Failure? = unavailable ? .ledgerUnavailable
            : (providerEvidenceUnavailable ? .evidenceUnavailable : (lastError == nil ? nil : .providerUnavailable))
        let providerTime = observations.values.map(\.observedAtMS).max().map {
            Date(timeIntervalSince1970: Double($0) / 1_000)
        }
        return .init(observedAt: Date(), latestProviderObservationAt: providerTime,
            failure: failure, sourceDiscoveryComplete: sourceDiscoveryCompleted && sourceWarning() == nil,
            cacheResetReason: .init(rawValue: cacheResetReason.rawValue) ?? .unknown,
            expiredPhase: .init(rawValue: expiredAtPhase.rawValue) ?? .unknown,
            counts: .init(authorizedSources: value.ledger.jobs.count,
                locallyWrittenAudio: value.ledger.exportedAudioCount,
                locallyWrittenTranscripts: value.ledger.exportedTranscriptCount,
                providerConfirmedFiles: uploaded, pendingProviderFiles: awaitingCloud,
                needsIdentityRevalidationSources: sameGrant ? value.ledger.jobs.filter(needsIdentityRevalidation).count : 0,
                identityMismatchFiles: observations.values.filter { $0.failureCode == "export_identity_changed" || $0.failureCode == "file_changed_during_check" }.count,
                unavailableFiles: observations.values.filter { $0.failureCode == "file_unavailable" }.count,
                providerReportedPendingFiles: observations.values.filter { $0.outcome == .notUploaded }.count,
                retainedHistoricalPositiveFiles: observations.values.filter { $0.outcome == .uploaded }.count,
                sourceDiscoveryCovered: sameGrant ? providerEvidence?.transcriptVisitedIDs.count ?? 0 : 0,
                metadataCheckedLastRound: cloudMetadataCheckedThisRound,
                cacheResetCount: cacheResetCount, phaseExpiryCount: phaseExpiryCount,
                providerMissingKeyFiles: observations.values.filter { $0.outcome == .missingKey }.count,
                providerResourceErrorFiles: observations.values.filter { $0.outcome == .resourceError }.count,
                providerNotUbiquitousFiles: observations.values.filter { $0.outcome == .notUbiquitous }.count,
                providerInvalidFileFiles: observations.values.filter { $0.outcome == .invalidFile }.count,
                providerLegacyUnknownFiles: observations.values.filter { $0.outcome == .legacyUnknown }.count),
            firstProviderConfirmationAt: observations.values.compactMap(\.firstConfirmedAtMS).min().map { Date(timeIntervalSince1970: Double($0) / 1_000) },
            latestProviderConfirmationAt: observations.values.compactMap(\.latestConfirmedAtMS).max().map { Date(timeIntervalSince1970: Double($0) / 1_000) })
    }

    private func validateFolder(_ folder: URL) throws {
        try folderAccess.validate(folder)
    }

    private func directoryMatches(resource: String, persistent: String?) throws -> Bool {
        if let expected = value.persistentFolderIdentityV1 {
            // Unavailable provider metadata is not evidence of a replacement
            // folder. Defer this round without downgrading the persisted grant
            // or accepting the weaker temporary ID as proof.
            guard let persistent else { throw ICloudDriveLibraryFailure.directoryUnavailable }
            return expected == persistent
        }
        return value.folderIdentity == resource
    }

    private func prepareBookmarkedRecovery(gate: ICloudDriveCancellation) throws {
        guard let connection = value.connection else { throw ICloudDriveLibraryFailure.permissionLost }
        let resolved = try directoryStep("bookmark_resolve") { try folderAccess.resolve(connection.bookmark) }
        guard !resolved.stale else { throw ICloudDriveLibraryFailure.staleBookmark }
        guard folderAccess.start(resolved.url) else { throw ICloudDriveLibraryFailure.permissionLost }
        defer { folderAccess.stop(resolved.url) }
        try gate.check()
        try directoryStep("folder_validate") { try validateFolder(resolved.url) }
        let identity = try folderAccess.identity(resolved.url)
        let persistent = try folderAccess.persistentIdentity?(resolved.url)
        try inspectMarker(in: resolved.url, gate: gate)
        try gate.check()
        let originalBytes = try directoryStep("grant_binding") {
            guard let bytes = try RecordingMetadataAccess.readIfPresent(at: stateURL, maximumBytes: 32 * 1_024 * 1_024),
                  try TransportCodec.decode(Persisted.self, from: bytes) == value,
                  try folderAccess.identity(resolved.url) == identity,
                  try folderAccess.persistentIdentity?(resolved.url) == persistent else {
                throw ICloudDriveLibraryFailure.recoveryCandidateChanged
            }
            return bytes
        }
        recoveryCandidate = RecoveryCandidate(original: value, originalStateBytes: originalBytes,
            connection: connection, identity: identity, persistentIdentity: persistent,
            previousError: ICloudDriveLibraryFailure.changedFolder.localizedDescription, previousActivity: activity)
        lastError = ICloudDriveLibraryFailure.recoveryConfirmationRequired.localizedDescription
        activity = "已找到原授权位置和匹配的录音库，请确认恢复；无需重新选择目录。"
        finishDirectoryDiagnostic("pending_confirmation", code: "bookmarked_identity_changed_marker_matches")
    }

    private func withTarget<T>(gate: ICloudDriveCancellation, _ operation: (URL) throws -> T) throws -> T {
        let previousPhase = roundPhase
        roundPhase = .target
        try gate.check()
        guard let connection = value.connection else {
            return try directoryStep("bookmark_resolve") { throw ICloudDriveLibraryFailure.permissionLost }
        }
        let resolved = try directoryStep("bookmark_resolve") { try folderAccess.resolve(connection.bookmark) }
        try gate.check()
        try directoryStep("bookmark_freshness") {
            guard !resolved.stale else { throw ICloudDriveLibraryFailure.staleBookmark }
        }
        let folder = resolved.url
        try directoryStep("security_scope") {
            guard folderAccess.start(folder) else { throw ICloudDriveLibraryFailure.permissionLost }
        }
        defer { folderAccess.stop(folder) }
        try gate.check()
        try directoryStep("folder_validate") { try validateFolder(folder) }
        try gate.check()
        let identity = try directoryStep("folder_identity") { try folderAccess.identity(folder) }
        try gate.check()
        let persistent = try folderAccess.persistentIdentity?(folder)
        let matches = try directoryMatches(resource: identity, persistent: persistent)
        directoryDiagnostic?.persistentIdentityAvailable = persistent != nil
        directoryDiagnostic?.identityReference = value.persistentFolderIdentityV1 == nil ? "legacy_resource" : "persistent_document_v1"
        directoryDiagnostic?.identityMatched = matches
        try directoryStep("identity_compare") {
            guard matches else { throw ICloudDriveLibraryFailure.changedFolder }
        }
        providerTargetAvailable = true
        providerObservationURL = folder
        roundPhase = previousPhase
        return try operation(folder)
    }

    private func verifyMarker(in folder: URL, allowMissingIfUncommitted: Bool = false,
                              alreadyCoordinated: Bool = false,
                              gate: ICloudDriveCancellation) throws {
        try gate.check()
        let writer = ICloudDriveExportWriter(root: folder, libraryID: value.ledger.libraryID)
        var info = stat()
        if lstat(writer.libraryURL.path, &info) != 0 {
            let code = errno
            if code == ENOENT, allowMissingIfUncommitted,
               !value.ledger.jobs.contains(where: { !$0.exportedKeys.isEmpty }) {
                finishDirectoryDiagnostic("uncommitted", code: "uncommitted_library_absent")
                return
            }
        }
        try inspectMarker(in: folder, alreadyCoordinated: alreadyCoordinated, gate: gate)
        try gate.check()
    }

    private func inspectMarker(in folder: URL, alreadyCoordinated: Bool = false,
                               gate: ICloudDriveCancellation) throws {
        try gate.check()
        let writer = ICloudDriveExportWriter(root: folder, libraryID: value.ledger.libraryID)
        if folderAccess.inspectMarker == nil && !alreadyCoordinated {
            // The coordinator itself may open its input before invoking the
            // accessor. Reject already-visible unsafe leaves before that call;
            // this metadata preflight is not a guarantee against all later
            // provider changes or system-coordinator waits.
            try directoryStep("marker_preflight") {
                let marker = writer.libraryURL.appendingPathComponent("library.json")
                var info = stat()
                if lstat(marker.path, &info) == 0 {
                    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                        throw ICloudDriveMarkerInspectionError.unsafeEntry
                    }
                    guard info.st_size >= 0, info.st_size <= 4_096 else {
                        throw ICloudDriveMarkerInspectionError.invalidEncoding
                    }
                } else if errno != ENOENT {
                    throw ICloudDriveMarkerInspectionError.systemCall(errno)
                }
            }
        }
        try directoryStep("marker_inspection") {
            if let inspect = folderAccess.inspectMarker { try inspect(folder, value.ledger.libraryID) }
            else {
                // Only an accessor already holding the enclosing directory's
                // write coordination may bypass a second, nested coordinator.
                if alreadyCoordinated {
                    try writer.inspectExistingMarker()
                    directoryDiagnostic?.markerMatched = true
                    return
                }
                let marker = writer.libraryURL.appendingPathComponent("library.json")
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordinationError: NSError?, result: Result<Void, Error>?
                coordinator.coordinate(readingItemAt: marker, options: .withoutChanges, error: &coordinationError) { coordinated in
                    result = Result {
                        try gate.check()
                        // A provider may substitute the accessor URL. The
                        // original path is not covered by that coordination;
                        // fail closed rather than read it or adopt a new root.
                        guard coordinated.standardizedFileURL == marker.standardizedFileURL else {
                            directoryDiagnostic?.stage = "marker_coordinate"
                            throw ICloudDriveLibraryFailure.coordinatedLocationChanged
                        }
                        try writer.inspectExistingMarker()
                    }
                }
                if let coordinationError {
                    directoryDiagnostic?.stage = "marker_coordinate"
                    throw coordinationError
                }
                guard let result else {
                    directoryDiagnostic?.stage = "marker_coordinate"
                    throw ICloudDriveLibraryFailure.directoryUnavailable
                }
                try result.get()
            }
            directoryDiagnostic?.markerMatched = true
        }
        try gate.check()
        finishDirectoryDiagnostic("verified", code: "existing_marker_matches")
    }

    private func beginDirectoryDiagnostic(_ operation: String) {
        let now = Self.nowMS()
        directoryDiagnostic = ICloudDriveDirectoryDiagnostic(
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            attemptID: UUID(), operation: operation, startedAtMS: now, observedAtMS: now)
    }

    private func persistDirectoryDiagnostic() {
        guard var diagnostic = directoryDiagnostic else { return }
        diagnostic.observedAtMS = Self.nowMS()
        diagnostic.confirmationRequired = recoveryCandidate != nil
        directoryDiagnostic = diagnostic
        // A diagnostic write cannot replace the original operation error or
        // mutate a grant. The collector will call an absent report unknown.
        if let bytes = try? TransportCodec.encode(diagnostic), bytes.count <= 8_192 {
            try? GoogleDriveLocalFiles.write(bytes, to: directoryDiagnosticURL)
        }
    }

    private func finishDirectoryDiagnostic(_ result: String, code: String? = nil) {
        directoryDiagnostic?.result = result
        directoryDiagnostic?.code = code
        persistDirectoryDiagnostic()
    }

    private func directoryStep<T>(_ stage: String, _ operation: () throws -> T) throws -> T {
        directoryDiagnostic?.stage = stage
        directoryDiagnostic?.result = "checking"
        persistDirectoryDiagnostic()
        do {
            let result = try operation()
            directoryDiagnostic?.steps.append(.init(stage: stage, result: "passed", code: nil, posixErrno: nil))
            if (directoryDiagnostic?.steps.count ?? 0) > 16 { directoryDiagnostic?.steps.removeFirst() }
            return result
        } catch {
            if error is CancellationError { throw error }
            let failedStage = directoryDiagnostic?.stage ?? stage
            let classified = directoryFailure(error, stage: failedStage)
            directoryDiagnostic?.result = "failed"
            directoryDiagnostic?.code = classified.code
            directoryDiagnostic?.underlyingDomain = classified.domain
            directoryDiagnostic?.underlyingCode = classified.underlyingCode
            directoryDiagnostic?.posixErrno = classified.posix
            if failedStage.hasPrefix("marker_") { directoryDiagnostic?.markerMatched = false }
            directoryDiagnostic?.steps.append(.init(stage: failedStage, result: "failed", code: classified.code, posixErrno: classified.posix))
            if (directoryDiagnostic?.steps.count ?? 0) > 16 { directoryDiagnostic?.steps.removeFirst() }
            lastError = classified.error.localizedDescription
            persistDirectoryDiagnostic()
            throw classified.error
        }
    }

    private func directoryFailure(_ error: Error, stage: String) ->
        (error: ICloudDriveLibraryFailure, code: String, domain: String?, underlyingCode: Int?, posix: Int?) {
        if let marker = error as? ICloudDriveMarkerInspectionError {
            switch marker {
            case .missingLibrary: return (.markerMissing, "library_directory_missing", nil, nil, Int(ENOENT))
            case .missingMarker: return (.markerMissing, "marker_missing", nil, nil, Int(ENOENT))
            case .invalidEncoding: return (.markerInvalid, stage == "marker_preflight" ? "marker_preflight_size_invalid" : "marker_invalid_encoding", nil, nil, nil)
            case .libraryMismatch: return (.markerMismatch, "marker_library_mismatch", nil, nil, nil)
            case .unsafeEntry: return (.markerInvalid, stage == "marker_preflight" ? "marker_preflight_unsafe_entry" : "marker_unsafe_entry", nil, nil, nil)
            case .changedDuringRead: return (.directoryUnavailable, "marker_changed_during_read", nil, nil, nil)
            case .systemCall(let code): return (.directoryUnavailable, stage == "marker_preflight" ? "marker_preflight_io_unavailable" : "marker_io_unavailable", NSPOSIXErrorDomain, Int(code), Int(code))
            }
        }
        if let failure = error as? ICloudDriveLibraryFailure {
            let code: String
            switch failure {
            case .unavailableState: code = "local_state_unavailable"
            case .permissionLost: code = "security_scope_unavailable"
            case .staleBookmark: code = "bookmark_stale"
            case .notICloud: code = "not_icloud_directory"
            case .changedFolder: code = stage == "identity_compare" ? "directory_identity_mismatch" : "directory_identity_unavailable"
            case .recoveryCandidateChanged: code = "recovery_candidate_changed"
            case .recoveryConfirmationRequired: code = "identity_confirmation_required"
            case .directoryUnavailable: code = "directory_unavailable"
            case .coordinatedLocationChanged: code = "coordinated_location_changed"
            case .markerMissing: code = "marker_missing"
            case .markerInvalid: code = "marker_invalid"
            case .markerMismatch: code = "marker_library_mismatch"
            }
            return (failure, code, nil, nil, nil)
        }
        let native = error as NSError
        var cursor = native, posix: Int?
        for _ in 0..<4 {
            if cursor.domain == NSPOSIXErrorDomain { posix = cursor.code; break }
            guard let next = cursor.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            cursor = next
        }
        let allowed = [NSPOSIXErrorDomain, NSCocoaErrorDomain, NSURLErrorDomain, "NSFileProviderErrorDomain"]
        let domain = allowed.contains(native.domain) ? native.domain : "other"
        let localState = stage.hasPrefix("save_") || stage.hasPrefix("load_") || stage == "grant_binding" || stage == "candidate_binding"
        return (localState ? .unavailableState : .directoryUnavailable,
                localState ? "local_state_io_unavailable" : (stage.hasPrefix("marker_") ? "marker_io_unavailable" : "directory_metadata_unavailable"),
                domain, native.code, posix)
    }

    private func synchronize(_ suppliedManifests: [SegmentManifest]?, received suppliedReceived: Set<UUID>?,
                             maximumJobs: Int?,
                             priorityTranscriptIDs: Set<UUID>, foregroundSlice: Bool, continuation: Bool,
                             gate: ICloudDriveCancellation,
                             phase: @Sendable (ICloudDriveWorkPhase) -> Void) throws {
        try gate.check()
        sourceDiscoveryCompleted = false
        needsSyncContinuation = false
        if foregroundSlice && (!continuation || foregroundDiscovery == nil) {
            foregroundAttemptedIDs.removeAll(); foregroundInspectedIDs.removeAll()
            foregroundDiscovery = nil
        }
        // Validate the retained authorization before changing discovery cursors.
        // This is the required target/marker gate, never a provider-status query.
        if maximumJobs != nil {
            try withTarget(gate: gate) { folder in
                try verifyMarker(in: folder, allowMissingIfUncommitted: true, gate: gate)
            }
        }
        // A known ledger can advance without a full repository walk. Supplied
        // receive snapshots are already in memory and admit the newest sources;
        // a cold repository scan waits until after the first committed exports.
        let deferRepositoryDiscovery = !foregroundSlice && maximumJobs != nil && suppliedManifests == nil
            && value.ledger.hasPendingFiles
        roundPhase = .discovery
        phase(.preparing)
        let reusingForegroundDiscovery = foregroundSlice && foregroundDiscovery != nil
        var manifests = try (foregroundSlice ? foregroundDiscovery?.manifests : nil) ?? suppliedManifests ?? (deferRepositoryDiscovery
            ? value.ledger.jobs.map(\.manifest) : sourceManifests(background: maximumJobs != nil, gate: gate))
        if !deferRepositoryDiscovery && !reusingForegroundDiscovery { manifests = try sourceDiscoveryManifests(manifests, gate: gate) }
        var received = try (foregroundSlice ? foregroundDiscovery?.received : nil) ?? suppliedReceived ?? (deferRepositoryDiscovery
            ? Set(value.ledger.jobs.map(\.id)) : sourceReceivedIDs(manifests, background: maximumJobs != nil, gate: gate))
        var next = value
        if !deferRepositoryDiscovery { try next.ledger.discover(manifests: manifests, receivedIDs: received) }
        // An excluded source is not permission to export its text. It can stop
        // occupying the request queue; a later grant has its own discovery pass.
        handledTranscriptRequestIDs = priorityTranscriptIDs.subtracting(Set(next.ledger.jobs.map(\.id)))
        var textByID: [UUID: SegmentTranscript] = [:]
        let inspectionCandidates = foregroundSlice ? next.ledger.jobs.filter { !foregroundInspectedIDs.contains($0.id) } : next.ledger.jobs
        let inspectedJobs = transcriptInspectionJobs(inspectionCandidates, maximumJobs: maximumJobs,
                                                     priorityIDs: priorityTranscriptIDs)
        // Only already-pending transcript payloads needed by the next export
        // batch may precede it. Optional text for a new audio export and all
        // historical transcript coverage use the remaining opportunity later.
        let immediateIDs = Set(orderedExports(next.ledger.jobs.filter { job in
            job.artifacts.contains { !job.exportedKeys.contains($0.key) }
        }).prefix(maximumJobs.map { max(0, $0) } ?? next.ledger.jobs.count).map(\.id))
        let knownProgressWork = !immediateIDs.isEmpty || next.ledger.jobs.contains(where: needsIdentityRevalidation)
        let immediateInspection = maximumJobs != nil && knownProgressWork
            ? inspectedJobs.filter { job in
                immediateIDs.contains(job.id) && job.artifacts.contains {
                    ($0.kind == .transcriptJSON || $0.kind == .transcriptText) && !job.exportedKeys.contains($0.key)
                }
            } : inspectedJobs
        let immediateInspectedIDs = Set(immediateInspection.map(\.id))
        var inspectedTranscriptIDs = Set<UUID>()
        func inspectTranscripts(_ jobs: [ICloudDriveLibraryJob]) throws {
            var discoveredText: [(transcript: SegmentTranscript, manifest: SegmentManifest)] = []
            for job in jobs {
                try gate.check()
                guard inspectedTranscriptIDs.insert(job.id).inserted else { continue }
                transcriptInspectedThisRound += 1
                if foregroundSlice { foregroundInspectedIDs.insert(job.id) }
                do {
                    if let transcript = try transcripts.transcript(for: job.manifest) {
                        discoveredText.append((transcript, job.manifest))
                        textByID[job.id] = transcript
                    }
                    providerEvidence?.transcriptIssueIDs.remove(job.id)
                    if priorityTranscriptIDs.contains(job.id) { handledTranscriptRequestIDs.insert(job.id) }
                } catch {
                    try gate.check()
                    providerEvidence?.transcriptIssueIDs.insert(job.id)
                    // The request was inspected and isolated. Repeating the
                    // same corrupt bytes is not useful discovery work; a new
                    // transcript-save notification provides a fresh request.
                    if priorityTranscriptIDs.contains(job.id) { handledTranscriptRequestIDs.insert(job.id) }
                }
                providerEvidence?.transcriptVisitedIDs.insert(job.id)
            }
            try next.ledger.discoverTranscripts(discoveredText)
            if foregroundSlice {
                let previousArtifacts = Dictionary(uniqueKeysWithValues: value.ledger.jobs.map { ($0.id, $0.artifacts) })
                for job in next.ledger.jobs where job.artifacts != previousArtifacts[job.id] {
                    foregroundAttemptedIDs.remove(job.id)
                }
            }
            if next.ledger != value.ledger { try persist(next, gate: gate) }
        }
        try inspectTranscripts(immediateInspection)
        if !deferRepositoryDiscovery && !reusingForegroundDiscovery { noteSourceDiscovery(manifests: manifests, received: received) }
        if maximumJobs != nil { sourceDiscoveryCompleted = false }
        if foregroundSlice { foregroundDiscovery = (manifests, received) }
        persistProviderEvidence()
        try withTarget(gate: gate) { folder in
            // A prior successful export must retain its exact original marker.
            try verifyMarker(in: folder, allowMissingIfUncommitted: true, gate: gate)
            // Bound repairs separately, including fully exported audio whose
            // ctime changed after the original commit. Normal sync only; load
            // and diagnostic export never enter this path. Alternate the first
            // category durably: even a lease expiring after one attempt must not
            // let a sustained export backlog starve identity repairs (or vice versa).
            let conflictIDs = Set(providerEvidence?.exportConflictIDs ?? [])
                .union(providerEvidence?.sourceMetadataIssueIDs ?? [])
            let exports = orderedExports(value.ledger.jobs.filter { job in
                if foregroundSlice && foregroundAttemptedIDs.contains(job.id) { return false }
                let pending = job.artifacts.contains { !job.exportedKeys.contains($0.key) }
                return ICloudDriveExportAdmission.admitsNewExport(pendingExport: pending,
                    needsRepair: needsExportIdentityRepair(job), conflictBlocked: conflictIDs.contains(job.id))
            })
            let repairCandidates = value.ledger.jobs.filter { job in
                if foregroundSlice && foregroundAttemptedIDs.contains(job.id) { return false }
                let pending = job.artifacts.contains { !job.exportedKeys.contains($0.key) }
                return ICloudDriveExportAdmission.admitsRepair(pendingExport: pending,
                    needsRepair: needsExportIdentityRepair(job), conflictBlocked: conflictIDs.contains(job.id))
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            let repairStart = providerEvidence?.repairNextID.flatMap { id in
                repairCandidates.firstIndex { $0.id.uuidString >= id.uuidString }
            } ?? 0
            let repairs = (0..<min(2, repairCandidates.count)).map {
                repairCandidates[(repairStart + $0) % repairCandidates.count]
            }
            let repairIDs = Set(repairCandidates.map(\.id))
            var pending = Array(exports.prefix(0))
            var exportIndex = 0, repairIndex = 0
            var preferRepair = providerEvidence?.preferRepairNext ?? false
            // A newly due recent-source turn takes the first slot even when
            // an earlier historical export left repair preferred. The next
            // slot/lease still retains repair and historical turns durably.
            if let first = exports.first, isNewSource(first),
               providerEvidence?.preferHistoricalExportNext != true { preferRepair = false }
            while exportIndex < exports.count || repairIndex < repairs.count {
                if repairIndex < repairs.count && (preferRepair || exportIndex == exports.count) {
                    pending.append(repairs[repairIndex]); repairIndex += 1
                    preferRepair = false
                } else {
                    pending.append(exports[exportIndex]); exportIndex += 1
                    preferRepair = true
                }
            }
            for job in pending.prefix(maximumJobs.map { max(0, $0) } ?? pending.count) {
                try gate.check()
                if foregroundSlice { foregroundAttemptedIDs.insert(job.id) }
                if let stamps = ctimeRepairStamps(job) { attemptedIdentityRepairStamps[job.id] = stamps }
                roundPhase = .export
                // A pure export conflict belongs to the repair category too.
                // Persist its turn before coordinating so an expired lease or
                // permanent conflict cannot pin the first repair batch forever.
                let repairing = repairIDs.contains(job.id)
                providerEvidence?.preferRepairNext = !repairing
                if !repairing { advanceExportTurn(after: job, candidates: exports) }
                persistProviderEvidence()
                if repairing, let index = repairCandidates.firstIndex(where: { $0.id == job.id }) {
                    // Move past an unreadable/conflicting target as well. A
                    // permanent quarantine must not starve other repairable files.
                    providerEvidence?.repairNextID = repairCandidates[(index + 1) % repairCandidates.count].id
                    persistProviderEvidence()
                }
                // A cold progress-first round has not walked the repository.
                // Fence this exact source using bounded metadata before any
                // writer can open audio or reuse an existing exported body.
                guard try sourceMetadataMatches(job, gate: gate) else {
                    noteSourceMetadataIssue(job)
                    continue
                }
                // An already-discovered late transcript still needs its exact
                // local metadata if it was outside the general rotating pass.
                if !inspectedTranscriptIDs.contains(job.id) && textByID[job.id] == nil && job.artifacts.contains(where: {
                    ($0.kind == .transcriptJSON || $0.kind == .transcriptText) && !job.exportedKeys.contains($0.key)
                }) {
                    inspectedTranscriptIDs.insert(job.id)
                    transcriptInspectedThisRound += 1
                    if foregroundSlice { foregroundInspectedIDs.insert(job.id) }
                    do {
                        textByID[job.id] = try transcripts.transcript(for: job.manifest)
                        providerEvidence?.transcriptIssueIDs.remove(job.id)
                        if priorityTranscriptIDs.contains(job.id) { handledTranscriptRequestIDs.insert(job.id) }
                    } catch {
                        try gate.check()
                        providerEvidence?.transcriptIssueIDs.insert(job.id)
                        if priorityTranscriptIDs.contains(job.id) { handledTranscriptRequestIDs.insert(job.id) }
                    }
                    providerEvidence?.transcriptVisitedIDs.insert(job.id)
                }
                phase(.saving)
                if repairing { noteRepairOutcome(0) }
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordinationError: NSError?
                var result: Result<ICloudDriveExportReceipt, Error>?
                coordinator.coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError) { coordinated in
                    result = Result {
                        try gate.check()
                        try validateFolder(coordinated)
                        try gate.check()
                        let identity = try folderAccess.identity(coordinated)
                        try gate.check()
                        guard try directoryMatches(resource: identity, persistent: try folderAccess.persistentIdentity?(coordinated)) else { throw ICloudDriveLibraryFailure.changedFolder }
                        try verifyMarker(in: coordinated, allowMissingIfUncommitted: true,
                                         alreadyCoordinated: true, gate: gate)
                        // Coordination may have waited while source metadata
                        // changed. Recheck immediately before the actual export.
                        guard try sourceMetadataMatches(job, gate: gate) else { throw ICloudDriveLibraryError.changedManifest }
                        return try ICloudDriveExportWriter(root: coordinated, libraryID: value.ledger.libraryID)
                            .export(job: job, audioURL: repository.audioURL(for: job.manifest),
                                    transcript: textByID[job.id], revalidateLocalAudio: needsIdentityRevalidation(job), while: { gate.isCurrent && stopFence.mayWrite && !Task.isCancelled })
                    }
                }
                if let coordinationError { throw coordinationError }
                guard let result else { throw ICloudDriveLibraryFailure.permissionLost }
                let receipt: ICloudDriveExportReceipt
                do { receipt = try result.get() }
                catch ICloudDriveLibraryError.changedManifest {
                    noteSourceMetadataIssue(job)
                    continue
                }
                catch ICloudDriveLibraryError.requiresRevalidation {
                    if repairing { noteRepairOutcome(2) }
                    noteIdentityRevalidation(job, in: folder)
                    continue
                }
                catch ICloudDriveLibraryError.conflict {
                    if repairing { noteRepairOutcome(3) }
                    // A conflicted head becomes a repair candidate. Later new
                    // exports in this round keep their turn.
                    noteExportConflict(job)
                    if needsIdentityRevalidation(job) { noteIdentityRevalidation(job, in: folder) }
                    continue
                }
                try gate.check()
                guard try sourceMetadataMatches(job, gate: gate) else {
                    noteSourceMetadataIssue(job)
                    continue
                }
                var committed = value
                try committed.ledger.recordExported(receipt)
                // A legacy record without an index remains explicitly unknown;
                // one new commit cannot prove that all older commits are known.
                if let paths = committed.committedReceiptPaths {
                    committed.committedReceiptPaths = paths.union([receipt.relativePath])
                }
                try persist(committed, gate: gate)
                if repairing { noteRepairOutcome(1) }
                if receipt.artifacts.contains(where: { !job.exportedKeys.contains($0.key) }) {
                    noteProgress(job.id, phase: 1)
                }
                noteLocalExport(receipt)
                if var issues = providerEvidence?.sourceMetadataIssueIDs {
                    issues.removeAll { $0 == job.id }
                    providerEvidence?.sourceMetadataIssueIDs = issues.isEmpty ? nil : issues
                    persistProviderEvidence()
                }
                if var conflicts = providerEvidence?.exportConflictIDs {
                    conflicts.removeAll { $0 == job.id }
                    providerEvidence?.exportConflictIDs = conflicts.isEmpty ? nil : conflicts
                    persistProviderEvidence()
                }
            }
            if foregroundSlice {
                phase(.checkingCloud)
                try refreshCloudStatus(in: folder, gate: gate,
                    maximumQueries: max(0, Self.providerBatchLimit - cloudMetadataCheckedThisRound))
            }
            // Full local discovery and historical text inspection cannot take
            // the first export's time. Their ordinary durable ledger updates
            // leave new work pending for the next bounded batch if cancelled.
            next = value
            roundPhase = .discovery
            if deferRepositoryDiscovery {
                try gate.check()
                manifests = try sourceManifests(background: true, gate: gate)
                manifests = try sourceDiscoveryManifests(manifests, gate: gate)
                received = try suppliedReceived ?? sourceReceivedIDs(manifests, background: true, gate: gate)
                try next.ledger.discover(manifests: manifests, receivedIDs: received)
                if next.ledger != value.ledger { try persist(next, gate: gate) }
                noteSourceDiscovery(manifests: manifests, received: received)
            }
            try inspectTranscripts(inspectedJobs.filter { !immediateInspectedIDs.contains($0.id) })
            if maximumJobs != nil {
                sourceDiscoveryCompleted = Set(value.ledger.jobs.map(\.id))
                    .isSubset(of: providerEvidence?.transcriptVisitedIDs ?? [])
                    && providerEvidence?.transcriptIssueIDs.isEmpty == true
            }
            persistProviderEvidence()
            // A real execution opportunity may observe a fixed small batch of
            // provider metadata. It never polls, opens or hashes audio, and its
            // durable cursor continues across future background opportunities.
            if !foregroundSlice {
                phase(.checkingCloud)
                try refreshCloudStatus(in: folder, gate: gate,
                    maximumQueries: max(0, Self.providerBatchLimit - cloudMetadataCheckedThisRound))
            }
        }
        if foregroundSlice {
            // New transcript artifacts discovered after an audio export deserve
            // another export turn, but failures already attempted do not.
            needsSyncContinuation = value.ledger.jobs.contains { job in
                !foregroundInspectedIDs.contains(job.id)
                    || (!foregroundAttemptedIDs.contains(job.id)
                        && (job.artifacts.contains { !job.exportedKeys.contains($0.key) }
                            || needsExportIdentityRepair(job)))
            }
        }
        activity = "已写入 iCloud Drive 目录：原录音 \(value.ledger.exportedAudioCount) 段、转写 \(value.ledger.exportedTranscriptCount) 段；累计观察到系统已上传 \(uploaded) 份文件，另有 \(awaitingCloud) 份待确认；本轮仅查 \(cloudMetadataCheckedThisRound) 份元数据。"
        if maximumJobs != nil && !foregroundSlice {
            activity = "已后台写入目录：原录音 \(value.ledger.exportedAudioCount) 段、转写 \(value.ledger.exportedTranscriptCount) 段；本轮只查 \(cloudMetadataCheckedThisRound) 份元数据，累计确认 \(uploaded) 份、\(awaitingCloud) 份待确认。"
        }
        if hasUnknownReceiptIndex {
            activity += " 旧本机记录缺少提交报告索引，资料库完整上传状态仍待核对。"
        }
    }

    /// Accept a signal without provider I/O. Both metadata-only refresh and a
    /// discovery opportunity use the same durable invalidation boundary.
    private func acceptProviderChange() {
        if providerEvidence == nil, let identity = value.folderIdentity {
            providerEvidence = emptyProviderEvidence(identity: identity)
        }
        guard var evidence = providerEvidence else { return }
        let expected = expectedCloudPaths()
        if evidence.providerChangePending == true || evidence.providerChangeReplayPending == true {
            // Never restart an unchecked tail. Unlocated signals coalesce into
            // one successor generation and fence all prior positives now.
            evidence.providerChangeReplayPending = expected.isEmpty ? nil : true
        } else {
            evidence.providerChangePending = expected.isEmpty ? nil : true
            evidence.providerChangeUncheckedPaths = expected.isEmpty ? nil : expected
            evidence.providerGeneration = min(Int.max - 1, evidence.providerGeneration ?? 0) + 1
        }
        providerEvidence = evidence
        persistProviderEvidence()
    }

    private func refreshCloudStatus(in folder: URL, gate: ICloudDriveCancellation,
                                    maximumQueries: Int = 32, includeMarker: Bool = true) throws {
        roundPhase = .provider
        try gate.check()
        uploaded = 0; awaitingCloud = 0
        uploadedPaths.removeAll()
        let expected = expectedCloudPaths()
        guard !expected.isEmpty else { return }
        let library = try ICloudDriveExportWriter(root: folder, libraryID: value.ledger.libraryID).validateMarker()
        guard let identity = value.folderIdentity else { throw ICloudDriveLibraryFailure.changedFolder }
        if providerEvidence?.libraryID != value.ledger.libraryID || providerEvidence?.folderIdentity != identity {
            providerEvidence = emptyProviderEvidence(identity: identity)
        }
        // Unknown changes are fenced by unchecked/replay state. Validate each
        // selected path below; a continuation must not lstat the entire library
        // before every bounded batch (or consume an unbounded cancellation gap).
        guard var evidence = providerEvidence else { return }
        evidence.observations = evidence.observations.filter { expected.contains($0.key) }
        evidence.localExportedAtMS = evidence.localExportedAtMS.filter { expected.contains($0.key) }
        var unchecked = uncheckedProviderPaths(evidence, expected: expected)
        if unchecked.isEmpty && evidence.providerChangeReplayPending == true {
            unchecked = expected
            evidence.providerChangeReplayPending = nil
            evidence.providerGeneration = min(Int.max - 1, evidence.providerGeneration ?? 0) + 1
        }
        evidence.providerPriorityPaths = evidence.providerPriorityPaths?.intersection(expected)
        evidence.providerChangeUncheckedPaths = unchecked.isEmpty ? nil : unchecked
        evidence.providerChangePending = unchecked.isEmpty ? nil : true
        providerEvidence = evidence
        // Commit and marker paths used to sit behind every audio artifact in
        // one lexical queue. Interleave kinds so a large backlog gets bounded
        // evidence for every layer immediately, with the same fair cursor and
        // the same 32-query maximum. Changing the order retains an exact next
        // path when resuming an older diagnostic cache.
        // Check the marker first once per cohort. Rechecking it every slice
        // can starve all other paths when its accessor consumes the slice.
        // Ordinary inspections without a cohort still recheck the marker.
        let paths = providerInspectionPaths(expected).filter { $0 != "library.json" }
        let start = evidence.nextPath.flatMap { paths.firstIndex(of: $0) } ?? 0
        // Pending files are revisited by a fair rotating cursor too: one slow
        // provider item cannot starve later sources or invalidate prior facts.
        let maximum = min(Self.providerBatchLimit, max(0, maximumQueries))
        let marker = includeMarker && maximum > 0 && !providerPathsCheckedThisRound.contains("library.json")
            && (unchecked.isEmpty || unchecked.contains("library.json"))
        let rotated = (0..<paths.count).map { paths[(start + $0) % paths.count] }
            .filter { !providerPathsCheckedThisRound.contains($0) }
        // Finish the invalidated cohort before revisiting checked paths. The
        // fair cursor still advances, including across cancellation/restart.
        let candidates = unchecked.isEmpty ? rotated : rotated.filter { unchecked.contains($0) }
        let priority = evidence.providerPriorityPaths ?? []
        let fresh = Array(candidates.filter { priority.contains($0) }.sorted {
            let lhs = evidence.localExportedAtMS[$0] ?? 0, rhs = evidence.localExportedAtMS[$1] ?? 0
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }.prefix(8))
        let freshSet = Set(fresh)
        let historical = candidates.filter { !priority.contains($0) }
        // An export gets one priority-batch opportunity. Unselected priority
        // paths join the durable historical rotation on the next slice; a
        // steady stream of exactly eight arrivals cannot pin an older cohort
        // outside both quotas forever.
        // Apply the demotion only after a non-marker check completes, so a
        // zero-permit/cancelled slice does not consume the priority opportunity.
        // A small new-export reservation plus a historical quota. Interleaving
        // the two also preserves progress when a short lease expires mid-batch.
        var ordered: [String] = []
        for index in 0..<max(fresh.count, historical.count) {
            if evidence.preferHistoricalProviderNext == true {
                if index < historical.count { ordered.append(historical[index]) }
                if index < fresh.count { ordered.append(fresh[index]) }
            } else {
                if index < fresh.count { ordered.append(fresh[index]) }
                if index < historical.count { ordered.append(historical[index]) }
            }
        }
        // Spare capacity can serve additional fresh paths if history is empty.
        let reserved = Set(ordered)
        ordered += candidates.filter { !reserved.contains($0) }
        let slots = maximum - (marker ? 1 : 0)
        // A just-checked negative must not consume another reservation while
        // the ordinary cursor still owes other files their first check. This
        // is a selection rule within real opportunities, never a poll timer.
        let pendingCutoff = Self.nowMS() - 60_000
        let pendingPaths = candidates.filter {
            guard let observed = evidence.observations[$0] else { return false }
            return observed.outcome == .notUploaded && observed.observedAtMS <= pendingCutoff
        }.sorted()
        let pendingStart = evidence.pendingProviderNextPath.flatMap { next in
            pendingPaths.firstIndex { $0 >= next }
        } ?? 0
        let pending = pendingPaths.isEmpty ? [] : (0..<min(8, min(slots, pendingPaths.count))).map {
            pendingPaths[(pendingStart + $0) % pendingPaths.count]
        }
        let pendingSet = Set(pending)
        let ordinary = ordered.filter { !pendingSet.contains($0) }
        var balanced: [String] = []
        for index in 0..<max(pending.count, ordinary.count) {
            if evidence.preferPendingProviderNext != false {
                if index < pending.count { balanced.append(pending[index]) }
                if index < ordinary.count { balanced.append(ordinary[index]) }
            } else {
                if index < ordinary.count { balanced.append(ordinary[index]) }
                if index < pending.count { balanced.append(pending[index]) }
            }
        }
        let selected = (marker ? ["library.json"] : []) + Array(balanced.prefix(slots))
        let sliceDeadline = ProcessInfo.processInfo.systemUptime + 1
        let identities = exportedFileIdentities()
        // Persist completed observations even when the next provider callback
        // blocks until expiry. A later process resumes after those facts rather
        // than repeating the same first 32 files forever.
        defer { persistProviderEvidence() }
        for relativePath in selected {
            try gate.check()
            guard gate.takeMetadataPermit() else { break }
            let target = library.appendingPathComponent(relativePath)
            let before = ProviderFileStamp(target)
            let identityMatches = identities[relativePath].map { before?.matches($0) == true }
            let validatedBody = identityMatches == nil && contentValidated(relativePath, stamp: before, at: target)
            let sampled: ICloudDriveProviderObservationStatus = before == nil ? .fileUnavailable
                : (folderAccess.observation?(target) ?? (folderAccess.uploaded(target) ? .uploaded : .notUploaded))
            try gate.check()
            let after = ProviderFileStamp(target)
            let stable = before != nil && before == after
            let outcome = sampled.applyingIdentity(fileAvailable: before != nil, identityMatches: identityMatches,
                contentValidated: validatedBody, stampStable: stable)
            let admitted = outcome == .uploaded
            let failure: String?
            switch outcome {
            case .uploaded: failure = nil
            case .identityMismatch: failure = "export_identity_changed"
            case .notUploaded: failure = "provider_pending"
            default: failure = outcome.rawValue
            }
            let previous = evidence.observations[relativePath]
            let wasConfirmed = previous.map { isPositiveProviderUpload(relativePath, $0, identities: identities) } ?? false
            let observedAt = Self.nowMS()
            evidence.observations[relativePath] = ProviderObservation(
                uploaded: admitted, observedAtMS: observedAt, stamp: after,
                failureCode: failure, identityMismatchBits: identities[relativePath].flatMap { expected in
                    after.map { $0.mismatchBits(expected) }
                }, contentValidated: (relativePath == "library.json" || relativePath.hasPrefix("commits/")) && validatedBody && stable ? true : nil,
                status: outcome, firstConfirmedAtMS: previous?.firstConfirmedAtMS ?? (admitted ? observedAt : nil),
                latestConfirmedAtMS: admitted ? observedAt : previous?.latestConfirmedAtMS)
            cloudMetadataCheckedThisRound += 1
            providerPathsCheckedThisRound.insert(relativePath)
            if let index = pendingPaths.firstIndex(of: relativePath), pendingSet.contains(relativePath) {
                evidence.pendingProviderNextPath = pendingPaths[(index + 1) % pendingPaths.count]
            }
            if relativePath != "library.json" {
                evidence.preferPendingProviderNext = !pendingSet.contains(relativePath)
            }
            if relativePath != "library.json", !freshSet.contains(relativePath), !pendingSet.contains(relativePath), let index = paths.firstIndex(of: relativePath) {
                evidence.nextPath = paths[(index + 1) % paths.count]
            }
            if relativePath != "library.json" {
                evidence.preferHistoricalProviderNext = freshSet.contains(relativePath)
                evidence.providerPriorityPaths = freshSet.isEmpty ? nil
                    : (evidence.providerPriorityPaths ?? []).intersection(freshSet)
            }
            unchecked.remove(relativePath)
            evidence.providerPriorityPaths?.remove(relativePath)
            if evidence.providerPriorityPaths?.isEmpty == true { evidence.providerPriorityPaths = nil }
            evidence.providerChangeUncheckedPaths = unchecked.isEmpty ? nil : unchecked
            evidence.providerChangePending = unchecked.isEmpty ? nil : true
            // Keep already observed facts if the execution gate expires between
            // two queries. The cache is diagnostic-only and safely replayable.
            providerEvidence = evidence
            if admitted && !wasConfirmed,
               let job = value.ledger.jobs.first(where: { job in job.artifacts.contains { $0.relativePath == relativePath } }) {
                noteProgress(job.id, phase: 2)
            }
            // A slow accessor can use the slice; retain the completed cursor
            // and let the active coordinator start another slice automatically.
            if ProcessInfo.processInfo.systemUptime >= sliceDeadline { break }
        }
        uploadedPaths = Set(evidence.observations.compactMap { path, observed in
            guard evidence.providerChangeReplayPending != true, !unchecked.contains(path),
                  isPositiveProviderUpload(path, observed, identities: identities) else { return nil }
            return path
        })
        uploaded = uploadedPaths.count
        awaitingCloud = expected.count - uploaded
        if hasUnknownReceiptIndex { awaitingCloud += 1 }
    }

    private func providerInspectionPaths(_ expected: Set<String>) -> [String] {
        var groups: [[String]] = [[], [], [], [], [], []]
        for path in expected.sorted() {
            let index: Int
            if path == "library.json" { index = 0 }
            else if path.hasPrefix("commits/") { index = 1 }
            else if path.hasPrefix("audio/") { index = 2 }
            else if path.hasPrefix("manifests/") { index = 3 }
            else if path.hasSuffix(".json") { index = 4 }
            else { index = 5 }
            groups[index].append(path)
        }
        var result: [String] = []
        result.reserveCapacity(expected.count)
        for offset in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where offset < group.count { result.append(group[offset]) }
        }
        return result
    }

    private static func nowMS() -> Int64 { milliseconds(Date()) }
    private static func milliseconds(_ value: Date) -> Int64 {
        Int64((value.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }

    private func noteSourceDiscovery(manifests: [SegmentManifest], received: Set<UUID>) {
        sourceDiscoveryCompleted = true
        if sourceDiscoveryPassCount < Int.max { sourceDiscoveryPassCount += 1 }
        sourceDiscoveryManifestCount = manifests.count; sourceDiscoveryReceivedCount = received.count
    }

    private func sourceManifests(background: Bool, gate: ICloudDriveCancellation) throws -> [SegmentManifest] {
        guard background else { return try repository.manifests() }
        guard let manifests = try repository.manifests(while: { gate.isCurrent && !Task.isCancelled }) else {
            throw CancellationError()
        }
        return manifests
    }

    private func sourceReceivedIDs(_ manifests: [SegmentManifest], background: Bool,
                                   gate: ICloudDriveCancellation) throws -> Set<UUID> {
        var received = Set<UUID>()
        // Avoid the historical all-receipts repository lock while the other
        // cloud worker needs an exact source preflight in the same short lease.
        // Each independently bounded receipt is metadata only, never ACK or
        // cleanup authority, and the gate can cancel between source files.
        for manifest in manifests {
            try gate.check()
            let file = repository.root.appendingPathComponent("receipts")
                .appendingPathComponent(manifest.id.uuidString.lowercased() + ".json")
            do {
                guard let bytes = try RecordingMetadataAccess.readIfPresent(at: file, maximumBytes: 16 * 1_024) else { continue }
                let receipt = try TransportCodec.decode(SegmentReceipt.self, from: bytes)
                guard receipt.segmentID == manifest.id, receipt.sha256 == manifest.sha256,
                      receipt.byteCount == manifest.byteCount, receipt.receivedAt.timeIntervalSince1970.isFinite else {
                    throw ICloudDriveLibraryError.changedManifest
                }
                received.insert(manifest.id)
            } catch {
                try gate.check()
                // Existing grants keep their original binding while a damaged
                // receipt is retried independently. Unknown-source failures
                // retain the strict discovery rejection; they grant nothing.
                guard let job = value.ledger.jobs.first(where: { $0.id == manifest.id }) else { throw error }
                noteSourceMetadataIssue(job)
            }
        }
        try gate.check()
        return received
    }

    /// A replaced manifest for one already-authorized ID cannot rewrite its
    /// ledger job or prevent healthy peers from being discovered on cold start.
    /// Validate malformed/duplicate input before isolating valid replacements.
    private func sourceDiscoveryManifests(_ manifests: [SegmentManifest],
                                         gate: ICloudDriveCancellation) throws -> [SegmentManifest] {
        guard manifests.count <= 10_000, Set(manifests.map(\.id)).count == manifests.count else {
            throw ICloudDriveLibraryError.invalidState
        }
        let jobs = Dictionary(uniqueKeysWithValues: value.ledger.jobs.map { ($0.id, $0) })
        var accepted: [SegmentManifest] = []
        for manifest in manifests {
            try gate.check()
            if let job = jobs[manifest.id], job.manifest != manifest {
                // Reuse Core's exact manifest validation without modifying the
                // actual grant or duplicating its format/size/date guards.
                var validation = ICloudDriveLibraryLedger(libraryID: value.ledger.libraryID)
                try validation.authorize(.existingAndFuture, knownIDs: [manifest.id])
                try validation.discover(manifests: [manifest], receivedIDs: [manifest.id])
                noteSourceMetadataIssue(job)
                continue
            }
            if let job = jobs[manifest.id], providerEvidence?.sourceMetadataIssueIDs?.contains(job.id) == true,
               try sourceMetadataMatches(job, gate: gate) {
                var issues = providerEvidence?.sourceMetadataIssueIDs ?? []
                issues.removeAll { $0 == job.id }
                providerEvidence?.sourceMetadataIssueIDs = issues.isEmpty ? nil : issues
                persistProviderEvidence()
            }
            accepted.append(manifest)
        }
        return accepted
    }

    /// Metadata authority only: no source audio is opened or fingerprinted.
    /// Missing, changed or unsafe per-source metadata isolates that source;
    /// cancellation still stops the worker instead of creating a false issue.
    private func sourceMetadataMatches(_ job: ICloudDriveLibraryJob, gate: ICloudDriveCancellation) throws -> Bool {
        try gate.check()
        do {
            guard try repository.transferEvidenceManifest(id: job.id) == job.manifest else { return false }
            try gate.check()
            let file = repository.root.appendingPathComponent("receipts")
                .appendingPathComponent(job.id.uuidString.lowercased() + ".json")
            guard let bytes = try RecordingMetadataAccess.readIfPresent(at: file, maximumBytes: 16 * 1_024) else { return false }
            let receipt = try TransportCodec.decode(SegmentReceipt.self, from: bytes)
            try gate.check()
            return receipt.segmentID == job.id && receipt.sha256 == job.manifest.sha256
                && receipt.byteCount == job.manifest.byteCount && receipt.receivedAt.timeIntervalSince1970.isFinite
        } catch {
            try gate.check()
            return false
        }
    }

    private func isNewSource(_ job: ICloudDriveLibraryJob) -> Bool {
        guard let authorizedAt = value.ledger.authorizedAt else { return false }
        return job.manifest.startedAt > authorizedAt
    }

    private func orderedExports(_ jobs: [ICloudDriveLibraryJob]) -> [ICloudDriveLibraryJob] {
        let recent = jobs.filter(isNewSource).sorted {
            if $0.manifest.startedAt != $1.manifest.startedAt { return $0.manifest.startedAt > $1.manifest.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let historical = jobs.filter { !isNewSource($0) }.sorted { $0.id.uuidString < $1.id.uuidString }
        let start = providerEvidence?.historicalExportNextID.flatMap { id in
            historical.firstIndex { $0.id.uuidString >= id.uuidString }
        } ?? 0
        let rotated = (0..<historical.count).map { historical[(start + $0) % historical.count] }
        var result: [ICloudDriveLibraryJob] = [], recentIndex = 0, historyIndex = 0
        var preferHistorical = providerEvidence?.preferHistoricalExportNext ?? false
        while recentIndex < recent.count || historyIndex < rotated.count {
            if historyIndex < rotated.count && (preferHistorical || recentIndex == recent.count) {
                result.append(rotated[historyIndex]); historyIndex += 1; preferHistorical = false
            } else {
                result.append(recent[recentIndex]); recentIndex += 1; preferHistorical = true
            }
        }
        return result
    }

    private func advanceExportTurn(after job: ICloudDriveLibraryJob, candidates: [ICloudDriveLibraryJob]) {
        providerEvidence?.preferHistoricalExportNext = isNewSource(job)
        guard !isNewSource(job) else { return }
        let historical = candidates.filter { !isNewSource($0) }.sorted { $0.id.uuidString < $1.id.uuidString }
        if let index = historical.firstIndex(where: { $0.id == job.id }) {
            providerEvidence?.historicalExportNextID = historical[(index + 1) % historical.count].id
        }
    }

    private func noteProgress(_ sourceID: UUID, phase: Int) {
        guard roundStartedAtMS > 0 && roundFinishedAtMS == 0 else { return }
        progressedSourceIDs.insert(sourceID)
        if firstProgressPhase == 0 { firstProgressPhase = phase }
    }

    private func transcriptInspectionJobs(_ jobs: [ICloudDriveLibraryJob], maximumJobs: Int?,
                                          priorityIDs: Set<UUID>) -> [ICloudDriveLibraryJob] {
        guard let identity = value.folderIdentity, !jobs.isEmpty else { return jobs }
        if providerEvidence?.libraryID != value.ledger.libraryID || providerEvidence?.folderIdentity != identity {
            providerEvidence = emptyProviderEvidence(identity: identity)
        }
        guard maximumJobs != nil else { return jobs }
        let sorted = jobs.sorted { $0.id.uuidString < $1.id.uuidString }, ids = Set(jobs.map(\.id))
        // This is coverage evidence, not the rotation cursor. Starting another
        // fair metadata pass must not erase an already completed discovery
        // pass; new IDs still remain uncovered until actually inspected, and
        // later transcript failures independently withdraw completeness.
        let allIDs = Set(value.ledger.jobs.map(\.id)).union(ids)
        let visited = (providerEvidence?.transcriptVisitedIDs ?? []).intersection(allIDs)
        let start = providerEvidence?.transcriptNextID.flatMap { id in sorted.firstIndex(where: { $0.id.uuidString >= id.uuidString }) } ?? 0
        let count = min(16, sorted.count)
        let pending = orderedExports(jobs.filter { job in job.artifacts.contains { !job.exportedKeys.contains($0.key) } })
            .prefix(min(2, max(0, maximumJobs ?? 0)))
        let limit = min(jobs.count, 16 + pending.count)
        var selected: [ICloudDriveLibraryJob] = [], seen = Set<UUID>()
        // At least four of the normal sixteen slots remain available to the
        // rotating scan even under a continuous stream of targeted notices.
        let targeted = sorted.filter { priorityIDs.contains($0.id) }.prefix(12)
        for job in Array(pending) + Array(targeted)
            where selected.count < limit && seen.insert(job.id).inserted { selected.append(job) }
        var advanced = 0
        for offset in 0..<count where selected.count < limit {
            let job = sorted[(start + offset) % sorted.count]
            advanced = offset + 1
            if seen.insert(job.id).inserted { selected.append(job) }
        }
        providerEvidence?.transcriptVisitedIDs = visited
        providerEvidence?.transcriptIssueIDs.formIntersection(allIDs)
        providerEvidence?.transcriptNextID = sorted[(start + advanced) % sorted.count].id
        return selected
    }

    private func loadProviderEvidence() {
        guard !providerEvidenceLoaded else { return }
        providerEvidenceLoaded = true
        do {
            guard let bytes = try RecordingMetadataAccess.readIfPresent(at: providerEvidenceURL,
                maximumBytes: Self.maximumProviderEvidenceBytes) else {
                cacheResetReason = .missing
                return
            }
            let restored = try TransportCodec.decode(ProviderEvidence.self, from: bytes)
            let expected = expectedCloudPaths(), now = Self.nowMS()
            guard restored.schemaVersion == 1, restored.libraryID == value.ledger.libraryID,
                  restored.folderIdentity == value.folderIdentity,
                  restored.observations.count <= 100_000, restored.localExportedAtMS.count <= 100_000,
                  restored.transcriptVisitedIDs.count <= 10_000,
                  restored.transcriptVisitedIDs.isSubset(of: Set(value.ledger.jobs.map(\.id))),
                  restored.transcriptIssueIDs.count <= 10_000,
                  restored.transcriptIssueIDs.isSubset(of: Set(value.ledger.jobs.map(\.id))),
                  restored.nextPath.map({ expected.contains($0) }) ?? true,
                  restored.pendingProviderNextPath.map({ expected.contains($0) }) ?? true,
                  restored.repairNextID.map({ id in value.ledger.jobs.contains { $0.id == id } }) ?? true,
                  restored.historicalExportNextID.map({ id in value.ledger.jobs.contains { $0.id == id } }) ?? true,
                  restored.sourceMetadataIssueIDs.map({ $0.count <= 10_000 }) ?? true,
                  restored.providerGeneration.map({ $0 >= 0 }) ?? true,
                  restored.providerPriorityPaths.map({ $0.count <= 100_000 && $0.isSubset(of: expected) }) ?? true,
                  restored.providerChangeUncheckedPaths.map({
                      restored.providerChangePending == true && $0.count <= 100_000 && $0.isSubset(of: expected)
                  }) ?? true,
                  restored.observations.allSatisfy({ path, observed in
                      expected.contains(path) && observed.observedAtMS >= 0 && observed.observedAtMS <= now + 300_000
                          && (observed.stamp?.valid ?? true)
                          && (!observed.uploaded || observed.stamp != nil)
                          && (observed.identityMismatchBits.map({ (0...31).contains($0) }) ?? true)
                          && (observed.failureCode.map({ ["file_unavailable", "export_identity_changed", "file_changed_during_check", "provider_pending", "missing_key", "resource_error", "not_ubiquitous", "invalid_file", "legacy_unknown"].contains($0) }) ?? true)
                          && (observed.firstConfirmedAtMS.map({ $0 >= 0 && $0 <= observed.observedAtMS }) ?? true)
                          && (observed.latestConfirmedAtMS.map({ $0 >= (observed.firstConfirmedAtMS ?? 0) && $0 <= observed.observedAtMS }) ?? true)
                  }),
                  restored.localExportedAtMS.allSatisfy({ expected.contains($0.key) && $0.value >= 0 && $0.value <= now + 300_000 }),
                  restored.cacheResetReason.map({ CacheResetReason(rawValue: $0) != nil }) ?? true,
                  restored.cacheResetCount.map({ $0 >= 0 }) ?? true,
                  restored.repairDiagnostics.map({ $0.valid && $0.lastAtMS <= now + 300_000 }) ?? true
            else { throw ICloudDriveLibraryFailure.unavailableState }
            providerEvidence = restored
            let knownJobs = Set(value.ledger.jobs.map(\.id))
            providerEvidence?.exportConflictIDs = restored.exportConflictIDs?
                .filter { knownJobs.contains($0) }
            if providerEvidence?.exportConflictIDs?.isEmpty == true { providerEvidence?.exportConflictIDs = nil }
            providerEvidence?.sourceMetadataIssueIDs = restored.sourceMetadataIssueIDs?
                .filter { knownJobs.contains($0) }
            if providerEvidence?.sourceMetadataIssueIDs?.isEmpty == true { providerEvidence?.sourceMetadataIssueIDs = nil }
            cacheResetReason = restored.cacheResetReason.flatMap(CacheResetReason.init(rawValue:)) ?? .none
            cacheResetCount = restored.cacheResetCount ?? 0
        } catch {
            // A broken diagnostic cache is unknown evidence, never a broken
            // grant, a false upload confirmation, or permission to hash audio.
            providerEvidence = nil; providerEvidenceUnavailable = true
            cacheResetReason = .invalid
            if cacheResetCount < Int.max { cacheResetCount += 1 }
        }
    }

    private func persistProviderEvidence() {
        guard let evidence = providerEvidence else { return }
        do {
            guard evidence.observations.count <= 100_000, evidence.localExportedAtMS.count <= 100_000,
                  (evidence.providerChangeUncheckedPaths?.count ?? 0) <= 100_000 else {
                throw ICloudDriveLibraryFailure.unavailableState
            }
            let bytes = try TransportCodec.encode(evidence)
            guard bytes.count <= Self.maximumProviderEvidenceBytes else { throw ICloudDriveLibraryFailure.unavailableState }
            try GoogleDriveLocalFiles.write(bytes, to: providerEvidenceURL)
            providerEvidenceUnavailable = false
        } catch { providerEvidenceUnavailable = true }
    }

    private func emptyProviderEvidence(identity: String) -> ProviderEvidence {
        ProviderEvidence(schemaVersion: 1, libraryID: value.ledger.libraryID,
            folderIdentity: identity, nextPath: nil, observations: [:], localExportedAtMS: [:],
            cacheResetReason: cacheResetReason.rawValue, cacheResetCount: cacheResetCount)
    }

    private func invalidateProviderEvidence(reason: CacheResetReason) {
        providerTargetAvailable = false
        cacheResetReason = reason
        if cacheResetCount < Int.max { cacheResetCount += 1 }
        guard let identity = value.folderIdentity else { providerEvidence = nil; return }
        providerEvidence = emptyProviderEvidence(identity: identity)
        persistProviderEvidence()
    }

    private func noteLocalExport(_ receipt: ICloudDriveExportReceipt) {
        guard let identity = value.folderIdentity else { return }
        if providerEvidence?.libraryID != value.ledger.libraryID || providerEvidence?.folderIdentity != identity {
            providerEvidence = emptyProviderEvidence(identity: identity)
        }
        var newPaths = Set<String>()
        for artifact in receipt.artifacts {
            // A late text export returns audio/manifest entries too. An exact
            // retained identity does not erase their original timed provider
            // observation or pretend they were just uploaded again.
            let old = providerEvidence?.observations[artifact.relativePath]
            let sameIdentity = receipt.localFileIdentities[artifact.key].map { expected in
                old?.stamp?.matches(expected) == true
            } ?? false
            if !sameIdentity { providerEvidence?.observations.removeValue(forKey: artifact.relativePath) }
            if !sameIdentity || old?.outcome != .uploaded {
                // Keep a matching negative and its first/latest confirmation
                // times, while still giving it a new bounded check opportunity.
                newPaths.insert(artifact.relativePath)
            }
            if providerEvidence?.localExportedAtMS[artifact.relativePath] == nil {
                providerEvidence?.localExportedAtMS[artifact.relativePath] = Self.milliseconds(receipt.committedAt)
            }
        }
        // Legacy ledgers retain an unknown receipt index after a new export.
        // Only indexed commits belong to expectedCloudPaths and may enter the
        // durable cache: cancellation before the next metadata pass must leave
        // the entire recovery snapshot valid on cold load.
        if value.committedReceiptPaths?.contains(receipt.relativePath) == true {
            if providerEvidence?.observations[receipt.relativePath] == nil { newPaths.insert(receipt.relativePath) }
            if providerEvidence?.localExportedAtMS[receipt.relativePath] == nil {
                providerEvidence?.localExportedAtMS[receipt.relativePath] = Self.milliseconds(receipt.committedAt)
            }
        }
        if !newPaths.isEmpty {
            let expected = expectedCloudPaths()
            var unchecked = providerEvidence.map { uncheckedProviderPaths($0, expected: expected) } ?? []
            // A resumed grant may retain local receipts after its provider
            // cache was cleared. New slices must also check those unobserved
            // existing exports instead of declaring only the new paths drained.
            unchecked.formUnion(expected.subtracting(Set(providerEvidence?.observations.keys.map { $0 } ?? [])))
            unchecked.formUnion(newPaths)
            unchecked.insert("library.json")
            providerEvidence?.providerChangeUncheckedPaths = unchecked
            providerEvidence?.providerChangePending = true
            let priority = (providerEvidence?.providerPriorityPaths ?? []).union(newPaths)
            let times = providerEvidence?.localExportedAtMS ?? [:]
            // Keep only a bounded recent reservation. Older exports retain the
            // durable historical cursor instead of competing as "new" forever.
            providerEvidence?.providerPriorityPaths = Set(priority.sorted {
                let lhs = times[$0] ?? 0, rhs = times[$1] ?? 0
                return lhs == rhs ? $0 < $1 : lhs > rhs
            }.prefix(32))
        }
        persistProviderEvidence()
    }

    private func isPositiveProviderUpload(_ path: String, _ observed: ProviderObservation,
                                          identities: [String: ICloudDriveFileIdentity]) -> Bool {
        guard let stamp = observed.stamp else { return false }
        return ICloudDriveProviderAdmission.providerUploaded(
            identityMatches: identities[path].map { stamp.matches($0) },
            contentValidated: observed.contentValidated == true,
            providerReportsUploaded: observed.outcome == .uploaded, stampStable: true)
    }
    /// Reads only the small marker or commit JSON. Audio bytes are never opened.
    /// A matching file name is not enough.
    private func contentValidated(_ relativePath: String, stamp: ProviderFileStamp?, at target: URL) -> Bool {
        guard let stamp, stamp.byteCount >= 0 else { return false }
        if relativePath == "library.json" {
            guard stamp.byteCount <= 4_096,
                  let data = try? RecordingMetadataAccess.readIfPresent(at: target, maximumBytes: 4_096),
                  ICloudDriveLibraryLedger.provesMarker(data, libraryID: value.ledger.libraryID),
                  ProviderFileStamp(target) == stamp else { return false }
            return true
        }
        guard relativePath.hasPrefix("commits/"), stamp.byteCount <= 128 * 1_024,
              let job = commitJob(relativePath),
              let data = try? RecordingMetadataAccess.readIfPresent(at: target, maximumBytes: 128 * 1_024),
              ICloudDriveLibraryLedger.provesCommit(data, relativePath: relativePath, job: job),
              ProviderFileStamp(target) == stamp else { return false }
        return true
    }
    private func commitJob(_ relativePath: String) -> ICloudDriveLibraryJob? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "commits", let id = UUID(uuidString: parts[1]),
              parts[1] == id.uuidString.lowercased(), parts[2].hasSuffix(".json") else { return nil }
        return value.ledger.jobs.first { $0.id == id }
    }
    private func noteExportConflict(_ job: ICloudDriveLibraryJob) {
        guard let identity = value.folderIdentity else { return }
        if providerEvidence?.libraryID != value.ledger.libraryID || providerEvidence?.folderIdentity != identity {
            providerEvidence = emptyProviderEvidence(identity: identity)
        }
        var ids = providerEvidence?.exportConflictIDs ?? []
        if !ids.contains(job.id), ids.count < 10_000 { ids.append(job.id) }
        providerEvidence?.exportConflictIDs = ids
        persistProviderEvidence()
    }
    private func noteSourceMetadataIssue(_ job: ICloudDriveLibraryJob) {
        guard let identity = value.folderIdentity else { return }
        if providerEvidence?.libraryID != value.ledger.libraryID || providerEvidence?.folderIdentity != identity {
            providerEvidence = emptyProviderEvidence(identity: identity)
        }
        var ids = providerEvidence?.sourceMetadataIssueIDs ?? []
        if !ids.contains(job.id), ids.count < 10_000 { ids.append(job.id) }
        providerEvidence?.sourceMetadataIssueIDs = ids
        persistProviderEvidence()
    }
    private func uncheckedProviderPaths(_ evidence: ProviderEvidence, expected: Set<String>) -> Set<String> {
        guard evidence.providerChangePending == true else { return [] }
        return (evidence.providerChangeUncheckedPaths ?? expected).intersection(expected)
    }
    private func exportedFileIdentities() -> [String: ICloudDriveFileIdentity] {
        var result: [String: ICloudDriveFileIdentity] = [:]
        for job in value.ledger.jobs {
            for artifact in job.artifacts where job.exportedKeys.contains(artifact.key) {
                result[artifact.relativePath] = job.exportedFiles[artifact.key]
            }
        }
        return result
    }

    // 0=started, 1=local content/identity committed, 2=deferred, 3=conflict.
    // These bounded counters describe the existing writer. They cannot promote
    // provider status or release another attempt, and contain no file identity.
    private func noteRepairOutcome(_ outcome: Int) {
        var stats = providerEvidence?.repairDiagnostics ?? RepairDiagnostics()
        switch outcome {
        case 0: stats.attempted = min(1_000_000, stats.attempted + 1)
        case 1: stats.completed = min(1_000_000, stats.completed + 1)
        case 2: stats.deferred = min(1_000_000, stats.deferred + 1)
        case 3: stats.conflicts = min(1_000_000, stats.conflicts + 1)
        default: return
        }
        stats.lastOutcome = outcome; stats.lastAtMS = Self.nowMS()
        providerEvidence?.repairDiagnostics = stats
        persistProviderEvidence()
    }

    private func needsIdentityRevalidation(_ job: ICloudDriveLibraryJob) -> Bool {
        guard let audio = job.artifacts.first(where: { $0.kind == .audio }),
              let observation = providerEvidence?.observations[audio.relativePath] else { return false }
        return observation.failureCode == "export_identity_changed" || observation.failureCode == "file_changed_during_check"
            || (observation.failureCode == "file_unavailable" && job.exportedKeys.contains(audio.key))
    }

    private func needsExportIdentityRepair(_ job: ICloudDriveLibraryJob) -> Bool {
        needsIdentityRevalidation(job) || ctimeRepairStamps(job) != nil
    }

    private func ctimeRepairStamps(_ job: ICloudDriveLibraryJob) -> [String: ProviderFileStamp]? {
        var stamps: [String: ProviderFileStamp] = [:]
        for artifact in job.artifacts {
            guard let observation = providerEvidence?.observations[artifact.relativePath],
                  observation.failureCode == "export_identity_changed",
                  observation.identityMismatchBits == 16, let stamp = observation.stamp else { continue }
            stamps[artifact.key] = stamp
        }
        return stamps.isEmpty ? nil : stamps
    }

    /// Only normal notifications can resume the enabled writer. It validates
    /// the exported content before updating identity; metadata is not proof.
    /// Read-only inspection never calls this or releases writer work.
    private func queueIdentityRepairsAfterProviderChange() {
        guard value.ledger.enabled, providerTargetAvailable, lastError == nil else { return }
        let blocked = Set(providerEvidence?.exportConflictIDs ?? [])
            .union(providerEvidence?.sourceMetadataIssueIDs ?? [])
        for job in value.ledger.jobs where !blocked.contains(job.id) {
            guard let stamps = ctimeRepairStamps(job), attemptedIdentityRepairStamps[job.id] != stamps else { continue }
            foregroundAttemptedIDs.remove(job.id)
            needsSyncContinuation = true
        }
    }

    private func noteIdentityRevalidation(_ job: ICloudDriveLibraryJob, in folder: URL) {
        guard let audio = job.artifacts.first(where: { $0.kind == .audio }),
              let expected = job.exportedFiles[audio.key] else { return }
        let target = ICloudDriveExportWriter(root: folder, libraryID: value.ledger.libraryID)
            .libraryURL.appendingPathComponent(audio.relativePath)
        let stamp = ProviderFileStamp(target)
        let previous = providerEvidence?.observations[audio.relativePath]
        providerEvidence?.observations[audio.relativePath] = ProviderObservation(uploaded: false,
            observedAtMS: Self.nowMS(), stamp: stamp, failureCode: "export_identity_changed",
            identityMismatchBits: stamp.map { $0.mismatchBits(expected) }, status: .identityMismatch,
            firstConfirmedAtMS: previous?.firstConfirmedAtMS, latestConfirmedAtMS: previous?.latestConfirmedAtMS)
        persistProviderEvidence()
    }

    private func publishSyncEvidence() {
        let expected = expectedCloudPaths(), identities = exportedFileIdentities()
        let sameGrant = providerEvidence?.libraryID == value.ledger.libraryID
            && providerEvidence?.folderIdentity == value.folderIdentity
        let historicalObservations = sameGrant ? (providerEvidence?.observations ?? [:]) : [:]
        let bound = sameGrant && value.connection != nil && value.ledger.enabled && lastError == nil
            && providerTargetAvailable && !providerEvidenceUnavailable
        let unchecked = providerEvidence.map { uncheckedProviderPaths($0, expected: expected) } ?? []
        let observations = bound && providerEvidence?.providerChangeReplayPending != true ? (providerEvidence?.observations ?? [:]).filter { !unchecked.contains($0.key) } : [:]
        let positive = Set(observations.compactMap { path, observed -> String? in
            guard expected.contains(path), isPositiveProviderUpload(path, observed, identities: identities) else { return nil }
            return path
        })
        // The durable writer index supplies exact source/commit association.
        // No directory enumeration, commit-body read, or derived hash is needed.
        var commitsBySource: [UUID: [(path: String, digest: String)]] = [:]
        for path in value.committedReceiptPaths ?? [] {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "commits", let id = UUID(uuidString: String(parts[1])),
                  String(parts[1]) == id.uuidString.lowercased(), parts[2].hasSuffix(".json") else { continue }
            let digest = String(parts[2].dropLast(5))
            guard digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            commitsBySource[id, default: []].append((path, digest))
        }
        let rows = value.ledger.jobs.map { job in
            SyncEvidenceSource(segmentID: job.id, sha256: job.manifest.sha256,
                byteCount: job.manifest.byteCount, startedAtMS: Self.milliseconds(job.manifest.startedAt),
                origin: "authorized_ledger", artifacts: job.artifacts.map { artifact in
                    let local = job.exportedKeys.contains(artifact.key)
                    let observed = observations[artifact.relativePath]
                    let recorded = sameGrant ? providerEvidence?.localExportedAtMS[artifact.relativePath] : nil
                    let historical = historicalObservations[artifact.relativePath]
                    let providerGate: SyncEvidenceICloudProviderGate = !local ? .awaitingLocalExport
                        : (!bound ? .contextUnavailable
                            : (providerEvidence?.providerChangeReplayPending == true ? .replayPending
                                : (unchecked.contains(artifact.relativePath) ? .unchecked : .current)))
                    let state = !local ? "pending" : (positive.contains(artifact.relativePath) ? "provider_uploaded" : "local_exported")
                    return SyncEvidenceArtifact(kind: Self.evidenceKind(artifact.kind), sha256: artifact.sha256,
                        byteCount: artifact.byteCount, state: state, recordedAtMS: recorded,
                        observedAtMS: observed?.observedAtMS,
                        origin: observed != nil ? "provider_metadata" : (recorded == nil ? "restored_ledger" : "observed_callback"),
                        localExportedAtMS: recorded, providerCheckedAtMS: historical?.observedAtMS,
                        providerResult: historical?.outcome, providerGate: providerGate)
                }, commits: (commitsBySource[job.id] ?? []).sorted { $0.digest < $1.digest }.map { commit in
                    SyncEvidenceCommit(exportDigest: commit.digest, providerUploaded: positive.contains(commit.path),
                        observedAtMS: observations[commit.path]?.observedAtMS)
                })
        }
        let artifacts = value.ledger.jobs.flatMap(\.artifacts)
        let exported = value.ledger.jobs.reduce(0) { $0 + $1.exportedKeys.count }
        let commits = value.committedReceiptPaths ?? []
        let context = SyncEvidenceContext(scope: "phone_authorized_discovered", libraryID: value.ledger.libraryID,
            scopeMode: value.ledger.recordingScope?.rawValue, authorizedAtMS: value.ledger.authorizedAt.map(Self.milliseconds),
            baselineIDs: Array(value.ledger.baselineIDs), enabled: value.ledger.enabled && recoveryCandidate == nil,
            discoveryComplete: sourceDiscoveryCompleted && sourceWarning() == nil && !unavailable && lastError == nil
                && !providerEvidenceUnavailable && !hasUnknownReceiptIndex,
            counts: ["authorized_source_count": value.ledger.jobs.count, "artifact_count": artifacts.count,
                     "local_exported_artifact_count": exported,
                     "provider_uploaded_artifact_count": artifacts.filter { positive.contains($0.relativePath) }.count,
                     "pending_export_artifact_count": artifacts.count - exported,
                     "expected_provider_file_count": expected.count,
                     "provider_uploaded_file_count": positive.count,
                     "pending_provider_file_count": expected.count - positive.count + (hasUnknownReceiptIndex ? 1 : 0),
                     "provider_change_unchecked_file_count": unchecked.count,
                     "provider_change_replay_pending": providerEvidence?.providerChangeReplayPending == true ? 1 : 0,
                     "provider_generation": providerEvidence?.providerGeneration ?? 0,
                     "commit_file_count": commits.count,
                     "provider_uploaded_commit_count": commits.intersection(positive).count,
                     "provider_uploaded_marker_count": positive.contains("library.json") ? 1 : 0,
                     "unknown_commit_index_count": hasUnknownReceiptIndex ? 1 : 0,
                     "source_discovery_pass_count": sourceDiscoveryPassCount,
                     "source_discovery_manifest_count": sourceDiscoveryManifestCount,
                     "source_discovery_received_count": sourceDiscoveryReceivedCount,
                     "source_discovery_covered_count": providerEvidence?.transcriptVisitedIDs.count ?? 0,
                     "transcript_inspected_this_round": transcriptInspectedThisRound,
                     "progressed_items": progressedSourceIDs.count,
                     "first_progress_phase": firstProgressPhase,
                     "bg_round": backgroundRound ? 1 : 0,
                     "bg_round_sequence": roundSequence,
                     "round_started_at_ms": Int(roundStartedAtMS),
                     "round_finished_at_ms": Int(roundFinishedAtMS),
                     "transcript_issue_count": providerEvidence?.transcriptIssueIDs.count ?? 0,
                     "source_metadata_issue_count": providerEvidence?.sourceMetadataIssueIDs?.count ?? 0,
                     "metadata_checked_this_round": cloudMetadataCheckedThisRound,
                     "provider_identity_mismatch_count": observations.values.filter { $0.failureCode == "export_identity_changed" || $0.failureCode == "file_changed_during_check" }.count,
                     "provider_file_unavailable_count": observations.values.filter { $0.failureCode == "file_unavailable" }.count,
                     "provider_reported_pending_count": observations.values.filter { $0.outcome == .notUploaded }.count,
                     "provider_missing_key_count": observations.values.filter { $0.outcome == .missingKey }.count,
                     "provider_resource_error_count": observations.values.filter { $0.outcome == .resourceError }.count,
                     "provider_not_ubiquitous_count": observations.values.filter { $0.outcome == .notUbiquitous }.count,
                     "provider_invalid_file_count": observations.values.filter { $0.outcome == .invalidFile }.count,
                     "provider_legacy_unknown_count": observations.values.filter { $0.outcome == .legacyUnknown }.count,
                     "needs_identity_revalidation_count": value.ledger.jobs.filter(needsIdentityRevalidation).count,
                     "identity_repair_attempted_count": providerEvidence?.repairDiagnostics?.attempted ?? 0,
                     "identity_repair_completed_count": providerEvidence?.repairDiagnostics?.completed ?? 0,
                     "identity_repair_deferred_count": providerEvidence?.repairDiagnostics?.deferred ?? 0,
                     "identity_repair_conflict_count": providerEvidence?.repairDiagnostics?.conflicts ?? 0,
                     "identity_repair_last_outcome": providerEvidence?.repairDiagnostics?.lastOutcome ?? 0,
                     "identity_repair_last_at_ms": Int(providerEvidence?.repairDiagnostics?.lastAtMS ?? 0),
                     "identity_ctime_only_changed_count": providerEvidence?.observations.values.filter { $0.identityMismatchBits == 16 }.count ?? 0,
                     "provider_target_available": providerTargetAvailable ? 1 : 0,
                     "retained_historical_provider_positive_count": providerEvidence?.observations.values.filter { $0.outcome == .uploaded }.count ?? 0,
                     "provider_cache_reset_reason": cacheResetReason.rawValue,
                     "provider_cache_reset_count": cacheResetCount,
                     "provider_phase_expiry_count": phaseExpiryCount,
                     "provider_last_expired_phase": expiredAtPhase.rawValue],
            failureCode: unavailable ? "ledger_unavailable" : (providerEvidenceUnavailable ? "provider_evidence_unavailable" : (lastError == nil ? nil : "provider_unavailable")))
        try? syncEvidence.publish(rows: rows, context: context)
        observeVerifiedMetadata(sourceDidChange: true)
    }

    private static func evidenceKind(_ kind: ICloudDriveArtifact.Kind) -> String {
        switch kind {
        case .audio: return "audio"
        case .manifest: return "manifest"
        case .transcriptJSON: return "transcriptJSON"
        case .transcriptText: return "transcriptText"
        }
    }

    private var hasUnknownReceiptIndex: Bool {
        value.committedReceiptPaths == nil && value.ledger.jobs.contains(where: { !$0.exportedKeys.isEmpty })
    }

    private func expectedCloudPaths() -> Set<String> {
        var paths = value.committedReceiptPaths ?? []
        for job in value.ledger.jobs {
            paths.formUnion(job.artifacts.filter { job.exportedKeys.contains($0.key) }.map(\.relativePath))
        }
        if !paths.isEmpty { paths.insert("library.json") }
        return paths

    }
}

/// Narrow dependency seam for offline, synthetic tests. Production always uses
/// genuine security-scoped URLs and the file provider's resource metadata.
struct ICloudDriveFolderAccess: @unchecked Sendable {
    var bookmark: (URL) throws -> Data
    var resolve: (Data) throws -> (url: URL, stale: Bool)
    var start: (URL) -> Bool
    var stop: (URL) -> Void
    var validate: (URL) throws -> Void
    var identity: (URL) throws -> String
    var uploaded: (URL) -> Bool
    var observation: ((URL) -> ICloudDriveProviderObservationStatus)? = nil
    /// Offline seam only. Production inspects the exact existing marker using
    /// the fd-anchored Core reader; it never creates one during recovery.
    var inspectMarker: ((URL, UUID) throws -> Void)? = nil
    /// Persistent across restarts only when the underlying volume supports it.
    /// nil is unknown; never fall back from an existing persistent grant.
    var persistentIdentity: ((URL) throws -> String?)? = nil

    static let system = ICloudDriveFolderAccess(
        bookmark: { try $0.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) },
        resolve: { data in
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: .withoutUI,
                relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        },
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() },
        validate: { folder in
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ICloudDriveLibraryFailure.changedFolder }
            guard values.isUbiquitousItem == true else { throw ICloudDriveLibraryFailure.notICloud }
        },
        identity: { folder in
            var fresh = folder
            fresh.removeAllCachedResourceValues()
            let resource = try fresh.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
            guard let resource else { throw ICloudDriveLibraryFailure.directoryUnavailable }
            return try ICloudDriveDirectoryIdentity.digest(resource)
        },
        uploaded: { _ in false }, // Compatibility seam for older synthetic adapters only.
        observation: { target in
            do {
                let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                    .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey])
                return .metadata(regular: values.isRegularFile, symbolicLink: values.isSymbolicLink,
                    ubiquitous: values.isUbiquitousItem, uploaded: values.ubiquitousItemIsUploaded)
            } catch { return .resourceError }
        }, persistentIdentity: { folder in
            var fresh = folder
            fresh.removeAllCachedResourceValues()
            let values = try fresh.resourceValues(forKeys: [.documentIdentifierKey, .volumeUUIDStringKey])
            return ICloudDriveDirectoryIdentity.persistentDigest(documentIdentifier: values.documentIdentifier,
                                                                 volumeUUID: values.volumeUUIDString)
        })
}

/// Paths, URLs and arbitrary `description` strings cannot prove folder identity.
/// Only provider-returned, strictly typed resource identifiers are accepted.
enum ICloudDriveDirectoryIdentity {
    static func persistentDigest(documentIdentifier: Int?, volumeUUID: String?) -> String? {
        guard let documentIdentifier, documentIdentifier > 0,
              let volumeUUID, let volume = UUID(uuidString: volumeUUID) else { return nil }
        return ICloudDriveLibraryLedger.digest(Data(("directory-document-v1\0" + volume.uuidString.lowercased()
                                                     + "\0" + String(documentIdentifier)).utf8))
    }

    static func digest(_ identifier: Any) throws -> String {
        let bytes: Data
        if let data = identifier as? Data, !data.isEmpty, data.count <= 65_536 {
            bytes = Data("data\0".utf8) + data
        } else if let string = identifier as? String, !string.isEmpty, string.utf8.count <= 65_536 {
            bytes = Data(("string\0" + string).utf8)
        } else if let number = identifier as? NSNumber, number.doubleValue.isFinite {
            let type = String(cString: number.objCType)
            guard !type.isEmpty, type.utf8.count <= 16 else { throw ICloudDriveLibraryFailure.changedFolder }
            bytes = Data(("number\0" + type + "\0" + number.stringValue).utf8)
        } else { throw ICloudDriveLibraryFailure.changedFolder }
        return ICloudDriveLibraryLedger.digest(bytes)
    }
}

/// A stop intent has its own tiny utility queue, so a file provider blocking a
/// coordinated export cannot delay recording pause/disconnect on local disk.
/// It is a safety fence, separate from the export ledger and cloud directory.
private final class ICloudDriveStopFence: @unchecked Sendable {
    private struct Record: Codable { let schemaVersion: Int; let stopped: Bool; let disconnected: Bool }
    private let file: URL
    private let queue = DispatchQueue(label: "dev.benzema.icloud-drive-stop-intent", qos: .utility)
    private let lock = NSLock()
    private var record = Record(schemaVersion: 1, stopped: false, disconnected: false)
    private var revision: UInt64 = 0
    private var loaded = false
    private var writeError: Error?
    init(file: URL) { self.file = file }
    var mayWrite: Bool { lock.lock(); defer { lock.unlock() }; return !record.stopped && writeError == nil }

    func stop(disconnecting: Bool) {
        lock.lock()
        record = Record(schemaVersion: 1, stopped: true, disconnected: record.disconnected || disconnecting)
        revision &+= 1
        let expected = revision
        // Enqueue under the same lock that orders stop revisions. A concurrent
        // disconnect must never be overwritten by an older pause snapshot.
        queue.async { [self] in
            do {
                try restoreIfNeeded()
                lock.lock(); let current = revision == expected; let next = record; lock.unlock()
                guard current else { return }
                try GoogleDriveLocalFiles.write(TransportCodec.encode(next), to: file)
            } catch { lock.lock(); writeError = error; lock.unlock() }
        }
        lock.unlock()
    }
    func current() throws -> (stopped: Bool, disconnected: Bool) {
        try queue.sync {
            try restoreIfNeeded()
            lock.lock(); defer { lock.unlock() }
            if writeError != nil { throw ICloudDriveLibraryFailure.unavailableState }
            return (record.stopped, record.disconnected)
        }
    }
    // Queue-confined load merges a stop arriving before the first restoration.
    // A cold-launch pause cannot accidentally clear an earlier disconnect.
    private func restoreIfNeeded() throws {
        guard !loaded else { return }
        if let data = try RecordingMetadataAccess.readIfPresent(at: file, maximumBytes: 4_096) {
            let restored = try TransportCodec.decode(Record.self, from: data)
            guard restored.schemaVersion == 1, !restored.disconnected || restored.stopped else {
                throw ICloudDriveLibraryFailure.unavailableState
            }
            lock.lock()
            if revision == 0 { record = restored }
            else {
                record = Record(schemaVersion: 1, stopped: record.stopped || restored.stopped,
                                disconnected: record.disconnected || restored.disconnected)
            }
            lock.unlock()
        }
        loaded = true
    }
    func flush() throws { _ = try current() }
    func connectPaused(gate: ICloudDriveCancellation) throws { try replace(stopped: true, disconnected: false, gate: gate) }
    func allow(gate: ICloudDriveCancellation) throws { try replace(stopped: false, disconnected: false, gate: gate) }
    private func replace(stopped: Bool, disconnected: Bool, gate: ICloudDriveCancellation) throws {
        lock.lock(); let expected = revision; lock.unlock()
        try queue.sync {
            try gate.check()
            try restoreIfNeeded()
            lock.lock()
            guard revision == expected, writeError == nil else { lock.unlock(); throw CancellationError() }
            record = Record(schemaVersion: 1, stopped: stopped, disconnected: disconnected)
            revision &+= 1
            let next = record
            lock.unlock()
            do { try GoogleDriveLocalFiles.write(TransportCodec.encode(next), to: file) }
            catch {
                lock.lock(); record = Record(schemaVersion: 1, stopped: true, disconnected: disconnected)
                writeError = error; lock.unlock()
                throw ICloudDriveLibraryFailure.unavailableState
            }
        }
    }
}

/// Upload acknowledgement and local download residency are independent. The
/// caller still brackets this metadata check with exact export identity checks.
enum ICloudDriveUploadStatus {
    static func isConfirmed(regular: Bool?, symbolicLink: Bool?, ubiquitous: Bool?, uploaded: Bool?) -> Bool {
        ICloudDriveProviderObservationStatus.metadata(regular: regular, symbolicLink: symbolicLink,
            ubiquitous: ubiquitous, uploaded: uploaded) == .uploaded
    }
}

/// A foreground-only signal source scoped to the explicitly selected folder.
/// It never reads query results or file contents. Every signal is independently
/// revalidated by the actor's bounded metadata-only command; no sync is requested.
final class ICloudDriveProviderMonitor {
    private var query: NSMetadataQuery?
    private var folder: URL?
    private var observers: [NSObjectProtocol] = []
    private let changed: @Sendable () -> Void
    private let makeQuery: () -> NSMetadataQuery
    private let startAccess: (URL) -> Bool
    private let stopAccess: (URL) -> Void
    private var startAttemptCount = 0, startSuccessCount = 0, startFailureCount = 0, notificationCount = 0
    private var firstGatherAt: Date?, latestNotificationAt: Date?
    var diagnosticSnapshot: ICloudDriveProviderMonitorDiagnostic {
        .init(startAttemptCount: startAttemptCount, startSuccessCount: startSuccessCount,
              startFailureCount: startFailureCount, notificationCount: notificationCount,
              firstGatherAt: firstGatherAt, latestNotificationAt: latestNotificationAt)
    }
    init(changed: @escaping @Sendable () -> Void,
         makeQuery: @escaping () -> NSMetadataQuery = { NSMetadataQuery() },
         startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.changed = changed; self.makeQuery = makeQuery
        self.startAccess = startAccess; self.stopAccess = stopAccess
    }
    func observe(_ url: URL?) {
        guard folder != url else { return }
        stop()
        guard let url else { return }
        startAttemptCount = min(1_000_000_000, startAttemptCount + 1)
        guard startAccess(url) else { startFailureCount = min(1_000_000_000, startFailureCount + 1); return }
        folder = url
        let query = makeQuery()
        query.searchScopes = [url]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")
        query.notificationBatchingInterval = 1
        self.query = query
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.notificationCount = min(1_000_000_000, self.notificationCount + 1)
                self.latestNotificationAt = Date()
                if name == .NSMetadataQueryDidFinishGathering && self.firstGatherAt == nil { self.firstGatherAt = self.latestNotificationAt }
                self.changed()
            })
        }
        if query.start() { startSuccessCount = min(1_000_000_000, startSuccessCount + 1) }
        else { startFailureCount = min(1_000_000_000, startFailureCount + 1); stop() }
    }
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        query?.stop(); query = nil
        if let folder { stopAccess(folder) }; folder = nil
    }
    deinit { stop() }
}
