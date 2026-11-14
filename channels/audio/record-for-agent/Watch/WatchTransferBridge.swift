import Foundation
import CryptoKit
import CoreFoundation
import Darwin
import RecordingCore
import WatchConnectivity

/// WatchConnectivity completion means delivery, not durable iPhone acceptance.
/// Only an integrity-matching SegmentReceipt is allowed to prune local audio.
final class WatchTransferBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    var onRepositoryChanged: (@Sendable () -> Void)?
    var onIssue: (@Sendable (String) -> Void)?
    var onSyncFeedback: (@Sendable (SyncFeedback) -> Void)?
    var onBackgroundRefreshRequested: (@Sendable (Date) -> Void)?
    var onStatusQuery: (@Sendable (@escaping @Sendable (RecorderSnapshot?) -> Void) -> Void)?

    private let maintenanceLock = NSLock()
    private var ownerMaintenanceAllowed: Bool
    private var evidenceForeground: Bool?
    private var evidenceLiveCapture: Bool?
    private var backgroundTaskIDs = Set<UUID>()
    private var backgroundTaskGenerations: [UUID: UInt64] = [:]
    private var expiredBackgroundTaskIDs = Set<UUID>()
    private var backgroundExecutionExpired = false
    private var backgroundExecutionGeneration: UInt64 = 0
    private var maintenanceNeedsOwnerSignal = false
    private var backgroundBudgetNeedsReset = false
    private var lightWindowStarted = Date.distantPast
    private var lightCandidateChecksRemaining = 8
    private var lightEnqueuesRemaining = 3
    private var lightEnqueued = 0
    private var lightCandidatesChecked = 0
    private let powerStateProvider: @Sendable () -> Bool
    private let handoffClock: @Sendable () -> TimeInterval
    private let availableCapacityProvider: @Sendable () -> Int64?
    private var handoffStartedAt: TimeInterval?
    private var handoffLastRefusal: String?
    private var handoffSkippedCandidates = 0
    private var acknowledgementInspectionOffset = 0
    // A raw KVO value becoming active does not prove its serial preparation
    // pass ran. Keep the WK lease until one activated pass actually drains.
    private var preparedActivationGeneration: UInt64?
    private var backgroundPowerPolicy = WatchBackgroundTransferPolicy()
    private var sealedBacklogHandoff = false
    private let transferDiagnosticStore: WatchTransferDiagnosticStore
    private let diagnosticClock: @Sendable () -> Date
    private var diagnosticProgress: [UUID: (completed: Int64, total: Int64, at: Date,
        foreground: Bool?, liveCapture: Bool?, generation: UInt64)] = [:]
    private var deliveredTransferDiagnosticIDs = Set<UUID>()
    private var legacyEventTurnPending = false
    private var pendingLegacyEventCompletion = false
    private var transferDiagnosticObservationAllowed = true
    private let repository: RecordingRepository
    private let work = DispatchQueue(label: "WristRecord.watch-transfer", qos: .utility,
                                     autoreleaseFrequency: .workItem)
    private let connectivity: WCSession?
    private let connectivityMetadata: WatchConnectivityMetadata
    private let backgroundSyncDiagnostics: WatchBackgroundSyncDiagnostics
    private let backlogEvidence: WatchBacklogEvidence
    private var snapshotState = TransferSnapshotState()
    // A full scan can refine the count without changing the writer observation.
    // Keep that refinement across bounded passes until a new writer value arrives.
    private var snapshotForPublication: RecorderSnapshot?
    private var lastPublishedSnapshot: RecorderSnapshot?
    private var snapshotPublicationAttempted = false
    private var lastPublishedRuntime: WatchRuntimeObservation?
    private var lastRuntimePublicationUptime: TimeInterval?
    private var diagnostics = TransferDiagnosticsPolicy()
    private var eventFailureDiagnostics = TransferDiagnosticsPolicy()
    private var syncFailureDiagnostics = TransferDiagnosticsPolicy()
    private static let enqueuedAtKey = "diagnosticEnqueuedAt"
    fileprivate static let attemptIDKey = "fileTransferAttemptID"
    private static let receiptRejectionMessage = "手机确认校验失败，手表上的录音已保留。可再次同步重试。"
    private static var transferStateWritingOptions: Data.WritingOptions {
        #if os(watchOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return .atomic
        #endif
    }
    private var deliveredEventIDs = Set<UUID>()
    // Retain cancelled objects for this process: a delayed completion must not
    // mark the safe half of a mixed packet delivered, or reuse an object ID.
    private var cancelledDiagnosticTransfers: [ObjectIdentifier: WCSessionUserInfoTransfer] = [:]
    // Cancellation is asynchronous. Retain superseded receipt requests so they
    // still count in the native queue, and delayed cancellation callbacks cannot
    // be reported as failures of the current head's request.
    private var supersededReceiptRequests: [ObjectIdentifier: WCSessionUserInfoTransfer] = [:]
    /// This evidence only authorizes waiting for a queried receipt. It is never
    /// a segment ACK. Callback threads revoke it synchronously so a blocked
    /// source check cannot cancel using a query that has already failed.
    private final class ReceiptQueryBackground: @unchecked Sendable {
        let transfer: WCSessionUserInfoTransfer
        private let lock = NSLock()
        private var completed: Bool?
        private var revoked = false

        init(_ transfer: WCSessionUserInfoTransfer) { self.transfer = transfer }

        func finished(succeeded: Bool) {
            lock.lock(); defer { lock.unlock() }
            if completed == nil { completed = succeeded }
        }

        func revoke() {
            lock.lock(); defer { lock.unlock() }
            revoked = true
        }

        func canBind(queued: [WCSessionUserInfoTransfer]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return !revoked && completed == nil && queued.contains { $0 === transfer }
        }

        func isValid(queued: [WCSessionUserInfoTransfer]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return !revoked && (completed == true || (completed == nil && queued.contains { $0 === transfer }))
        }
    }
    private final class RecoveryReceiptQuery: @unchecked Sendable {
        let background: ReceiptQueryBackground?
        private let lock = NSLock()
        private var immediateReplied = false
        private var revoked = false

        init(background: ReceiptQueryBackground?) { self.background = background }

        func immediateFinished(succeeded: Bool) {
            lock.lock(); defer { lock.unlock() }
            immediateReplied = succeeded
            if !succeeded { revoked = true }
        }

        func revoke() {
            lock.lock(); defer { lock.unlock() }
            revoked = true
        }

        func isValid(queued: [WCSessionUserInfoTransfer]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !revoked else { return false }
            if let background, !background.isValid(queued: queued) {
                // A missing native query without a completion cannot hand its
                // old grace to a late reply from the other channel.
                revoked = true
                return false
            }
            return immediateReplied || background != nil
        }
    }
    private let recoveryQueryLock = NSLock()
    private var recoveryReceiptQueries: [String: RecoveryReceiptQuery] = [:]
    private var issuedReceiptQueries: [ObjectIdentifier: ReceiptQueryBackground] = [:]
    private var receiptQueryRegistrationDisabled = false
    private var outstandingPolicy = OutstandingFileTransferPolicy()
    private let recoveryStateURL: URL
    private var recoveryStateLoaded = false
    private var recoveryStateBytes: Data?
    private var lastRecoveryStateError: String?
    private let recoveryIdleInterval: TimeInterval
    private let recoveryReceiptGrace: TimeInterval
    private let recoveryContinuityID: String?
    private let recoveryClock: @Sendable () -> (date: Date, uptime: TimeInterval)
    private var lastBackgroundStallRecoveryGeneration: UInt64?
    // One ordinary one-minute PCM segment, with room for its container.
    private static let backgroundStallRecoveryMaxBytes: Int64 = 16 * 1_024 * 1_024
    private static let backgroundStallRecoveryTimeLimit: TimeInterval = 1
    private let receiptRequestUptime: @Sendable () -> TimeInterval
    private var receiptRequestPolicy = BackgroundReceiptRequestPolicy()
    // A selection hint only: it cannot acknowledge a source, grant access, or
    // authorize a file transfer. Keep its failure separate from queue ownership.
    private struct HistoricalReceiptCursor: Codable {
        let schemaVersion: Int
        let nextNativeOffset: UInt64
    }
    private let historicalReceiptCursorURL: URL
    private var historicalReceiptCursor: HistoricalReceiptCursor?
    private var historicalReceiptCursorBytes: Data?
    private var lastHistoricalReceiptCursorError: String?
    // Delayed cancellation completions must not back off a newer file attempt.
    private var stalledCancellationKeys = Set<String>()
    private struct VerifiedPreemptionSource {
        let manifest: SegmentManifest
        let fileSignature: String
        // Historical sources may be prepared before the first current seal.
        // Older fresh sources are certified only for one exact priority head.
        let priorityIdentity: FreshTransferPriorityIdentity?
    }
    private enum ReceiptRequestPlan {
        case none
        case legacy
        case targeted(TargetedReceiptRequest)
        case historical(TargetedReceiptRequest, nextNativeOffset: UInt64)
        case skipHistorical(nextNativeOffset: UInt64)

        func matchesQueuedRequest(_ payload: [String: Any]) -> Bool {
            guard payload[TransportCodec.requestSyncKey] as? Bool == true else { return false }
            switch self {
            case .none, .skipHistorical: return false
            case .legacy: return payload[TransportCodec.targetedReceiptRequestKey] == nil
            case .targeted(let expected), .historical(let expected, _):
                guard let data = payload[TransportCodec.targetedReceiptRequestKey] as? Data,
                      let actual = try? TransportCodec.decode(TargetedReceiptRequest.self, from: data) else { return false }
                return actual == expected
            }
        }
    }
    // Only in-process certificates can avoid hashing in a short WK callback.
    // A persisted intent does not certify source bytes after a process restart.
    private var verifiedPreemptionSources: [String: VerifiedPreemptionSource] = [:]
    private var requestedPreemptionAttempts = Set<String>()
    private var retryPolicy = FileTransferRetryPolicy()
    private var persistedRetryPolicy = FileTransferRetryPolicy()
    private let retryStateURL: URL
    private var retryStateReadError: String?
    private var retryStateLoaded = false
    private var lastRetryPersistenceError: String?
    private var retryWake: DispatchWorkItem?
    private var retryWakeAt: Date?
    private var schedulingPolicy = FileTransferSchedulingPolicy()
    private var persistedSchedulingPolicy = FileTransferSchedulingPolicy()
    private let schedulingStateURL: URL
    private var schedulingStateReadError: String?
    private var schedulingStateLoaded = false
    private var lastSchedulingPersistenceError: String?
    // Only queued presentation/synchronization work is combined. Each receipt
    // still validates and commits independently before requesting a refresh.
    private var pendingSynchronizationTrigger: TransferDiagnosticsPolicy.Trigger?
    private var pendingSynchronizationGeneration: UInt64?
    // Serial-worker context: an old bounded pass cannot inherit a newer WK
    // opportunity while it is paused inside metadata/repository work.
    private var activeBoundedGeneration: UInt64?
    private var pendingPreservingFailure = false
    private var pendingFeedbackRefresh = false
    private var refreshScheduled = false
    // Retain exact native objects while cancellation is pending. Two attempts
    // for the same segment may sit in different bounded inspection pages.
    private var acknowledgedCancellationRequests: [ObjectIdentifier: WCSessionFileTransfer] = [:]
    // Retained for this process even after the system removes a cancelled task:
    // its completion callback may arrive later, including more than one duplicate.
    // This evidence suppresses callbacks only; cancellation still checks disk.
    private var cancelledAcknowledgedManifests: [UUID: SegmentManifest] = [:]
    private var acknowledgementCheckFailures = Set<UUID>()
    private var syncFeedback = SyncFeedback()
    private var syncIssue: String?
    private var deliveredPendingIDs = Set<UUID>()
    // Refresh after a successful retry even if an earlier failed fsync left the
    // same ACK visible. Keep recovery notifications beyond a cleared UI error.
    // Neither set is ever acknowledgement proof.
    private var failedReceiptIDs = Set<UUID>()
    private var presentedReceiptFailureIDs = Set<UUID>()
    private var backgroundCompletions: [UUID: @Sendable () -> Void] = [:]
    private var backgroundFinalizingTaskIDs = Set<UUID>()
    private var applicationRefreshTaskIDs = Set<UUID>()
    private var backgroundCompletionCheckScheduled = false
    // The serial transfer worker and the two diagnostic writers are separate
    // queues. Relinquishing a WK lease when only `work` has drained can suspend
    // the process before an already committed ACK reaches its metadata report.
    // A revision binds each asynchronous flush to the work it actually covered.
    private var backgroundMetadataFlushInFlight = false
    private var backgroundMetadataFlushedRevision: UInt64?
    private var backgroundWorkRevision: UInt64 = 0
    private var backgroundObservations: [NSKeyValueObservation] = []
    private var backgroundActivationFailed = false
    private struct CandidateSweep: Codable {
        let indexStamp: String
        let recordCount: Int
        let nextCursor: Int
        let coveredCursorSteps: Int
        // Optional for schema-1 compatibility with earlier continuation hints.
        let completed: Bool?
        init(indexStamp: String, recordCount: Int, nextCursor: Int,
             coveredCursorSteps: Int, completed: Bool = false) {
            self.indexStamp = indexStamp; self.recordCount = recordCount
            self.nextCursor = nextCursor; self.coveredCursorSteps = coveredCursorSteps
            self.completed = completed
        }
        var valid: Bool {
            guard !indexStamp.isEmpty, indexStamp.utf8.count <= 2_048, recordCount >= 0,
                  nextCursor >= 0, recordCount == 0 ? nextCursor == 0 : nextCursor < recordCount,
                  coveredCursorSteps >= 0, coveredCursorSteps <= recordCount else { return false }
            return completed == true ? coveredCursorSteps == recordCount
                : recordCount > 0 && coveredCursorSteps < recordCount
        }
    }
    private struct BackgroundRefreshIntent: Codable {
        let schemaVersion: Int
        let preferredDate: Date?
        let candidateSweep: CandidateSweep?
        init(schemaVersion: Int, preferredDate: Date?, candidateSweep: CandidateSweep? = nil) {
            self.schemaVersion = schemaVersion; self.preferredDate = preferredDate
            self.candidateSweep = candidateSweep
        }
    }
    private var candidateSweep: CandidateSweep?
    private let backgroundRefreshStateURL: URL
    private var foregroundExitPending = false
    private var backgroundRefreshPreferredDate: Date?
    private var backgroundRefreshRequestInFlight: Date?
    private var backgroundRefreshConfirmedDate: Date?
    private var backgroundRefreshRetryAfter: Date?
    private var backgroundRefreshRecoveryNeeded = false
    private var backgroundRefreshStateLoaded = false
    private var backgroundRefreshStateReadError: String?
    private var lastTransferStateLoadFailure: String?
    // Best-effort system successor while protected metadata is unavailable.
    // This deliberately does not overwrite the unreadable durable intent.
    private var stateRecoveryRefreshDate: Date?
    private var stateRecoveryRefreshInFlight = false
    private var stateRecoveryRefreshRetryAfter: Date?
    private struct AutomaticSyncRequest: Codable {
        let id: UUID
        let requestedAtMS: Int64
    }
    private struct AutomaticSyncState: Codable {
        let schemaVersion: Int
        let requests: [AutomaticSyncRequest]
    }
    private static let automaticSyncSchemaKey = "automaticSyncSchemaVersion"
    private static let automaticSyncIDKey = "automaticSyncRequestID"
    private static let automaticSyncTimeKey = "automaticSyncRequestedAtMS"
    private static let automaticSyncMaximumBytes = 8_192
    private static let automaticSyncMaximumIDs = 32
    private var automaticSyncRequests: [AutomaticSyncRequest]?
    private var automaticSyncStateURL: URL {
        repository.root.appendingPathComponent("transfer-automatic-sync-state.json")
    }
    private enum BackgroundDecision: String {
        case notEvaluated = "not_evaluated", awaitingActivation = "awaiting_activation"
        case nativeOccupied = "native_occupied", foreignNative = "foreign_native"
        case candidateBudget = "candidate_budget", enqueueBudget = "enqueue_budget"
        case retryBackoff = "retry_backoff", noAdmission = "no_admission"
        case openTail = "open_tail", candidateReadFailed = "candidate_read_failed"
        case freshReadFailed = "fresh_read_failed", enqueued
    }
    // Diagnostic observations only. They never admit/cancel a task or change
    // retry/ACK state. Unknown (-1) differs from an observed empty native queue.
    private var backgroundDecision = BackgroundDecision.notEvaluated
    private var backgroundDecisionRecorded = false
    private var backgroundDecisionCandidates: Int?
    private var backgroundDecisionEligible: Int?
    private var backgroundDecisionNative: Int?
    private var backgroundDecisionNativeSample = 0
    private var backgroundDecisionNativeZero = 0
    private var backgroundDecisionNativeFinished = 0
    private var backgroundDecisionForeign: Int?

    init(repository: RecordingRepository, maintenanceAllowed: Bool = true,
         powerStateProvider: @escaping @Sendable () -> Bool = { false },
         diagnosticClock: @escaping @Sendable () -> Date = { Date() },
         handoffClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         availableCapacityProvider: (@Sendable () -> Int64?)? = nil,
         recoveryIdleInterval: TimeInterval = OutstandingFileTransferPolicy.minimumIdle,
         recoveryReceiptGrace: TimeInterval = 60,
         recoveryContinuityID: String? = WatchTransferBridge.bootContinuityID(),
         recoveryClock: @escaping @Sendable () -> (date: Date, uptime: TimeInterval) = {
             (Date(), ProcessInfo.processInfo.systemUptime)
         }, receiptRequestUptime: @escaping @Sendable () -> TimeInterval = {
             ProcessInfo.processInfo.systemUptime
         }) {
        self.repository = repository
        self.diagnosticClock = diagnosticClock
        self.transferDiagnosticStore = WatchTransferDiagnosticStore(root: repository.root, clock: diagnosticClock)
        self.connectivityMetadata = WatchConnectivityMetadata(root: repository.root)
        self.backlogEvidence = WatchBacklogEvidence(root: repository.root,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            processRunID: WatchRuntimeDiagnostics.shared.processRunID)
        self.backgroundSyncDiagnostics = WatchBackgroundSyncDiagnostics(root: repository.root,
            maintenanceOwnerAllowed: maintenanceAllowed)
        self.recoveryClock = recoveryClock
        self.recoveryIdleInterval = recoveryIdleInterval
        self.recoveryReceiptGrace = recoveryReceiptGrace.isFinite && recoveryReceiptGrace >= 0 ? recoveryReceiptGrace : 60
        self.recoveryContinuityID = recoveryContinuityID
        self.receiptRequestUptime = receiptRequestUptime
        self.powerStateProvider = powerStateProvider
        self.handoffClock = handoffClock
        self.availableCapacityProvider = availableCapacityProvider ?? {
            // Volume metadata only. No audio is opened, copied, or hashed.
            let values = try? FileManager.default.attributesOfFileSystem(forPath: repository.root.path)
            return (values?[.systemFreeSize] as? NSNumber)?.int64Value
        }
        let powerPolicy = WatchBackgroundTransferPolicy(isCharging: powerStateProvider(), sealedBacklog: sealedBacklogHandoff)
        backgroundPowerPolicy = powerPolicy
        lightCandidateChecksRemaining = powerPolicy.maximumCandidateChecks
        lightEnqueuesRemaining = powerPolicy.maximumEnqueues
        ownerMaintenanceAllowed = maintenanceAllowed
        retryStateURL = repository.root.appendingPathComponent("transfer-retry-state.json")
        recoveryStateURL = repository.root.appendingPathComponent("transfer-progress-state.json")
        schedulingStateURL = repository.root.appendingPathComponent("transfer-scheduling-state.json")
        backgroundRefreshStateURL = repository.root.appendingPathComponent("transfer-background-refresh-state.json")
        historicalReceiptCursorURL = repository.root.appendingPathComponent("transfer-receipt-request-position.json")
        connectivity = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        _ = loadRecoveryStateIfNeeded()
        _ = loadTransferStateIfNeeded()
        // Clean up legacy queued diagnostics before requesting activation too.
        // System-owned work already delivered before launch cannot be recalled.
        if let connectivity {
            cancelIneligibleQueuedDiagnostics(using: connectivity)
            if connectivity.activationState == .activated { sanitizeQueuedApplicationContext(using: connectivity) }
        }
        connectivity?.delegate = self
        if let connectivity {
            // A background wake can arrive before activation, and the last
            // hasContentPending change need not produce another delegate call.
            backgroundObservations = [
                connectivity.observe(\.activationState, options: [.new]) { [weak self] _, _ in
                    self?.backgroundSessionStateChanged()
                },
                connectivity.observe(\.hasContentPending, options: [.new]) { [weak self] _, _ in
                    self?.backgroundSessionStateChanged()
                }
            ]
        }
        if let connectivity {
            connectivityMetadata.observe(connectivity, owner: self, trigger: .startup)
            connectivityMetadata.activationRequested(connectivity, owner: self)
            connectivity.activate()
        }
    }

    /// Only proven absence allows default state. Protected/unreadable/corrupt
    /// metadata must not erase cooldowns, ordering, or the durable continuation.
    /// Reattempt on real opportunities; incoming exact ACK commits stay separate.
    private func loadTransferStateIfNeeded() -> Bool {
        if !retryStateLoaded {
            do {
                let data = try RecordingMetadataAccess.readIfPresent(at: retryStateURL, maximumBytes: 16 * 1_024 * 1_024)
                let loaded = try data.map { try TransportCodec.decode(FileTransferRetryPolicy.self, from: $0) }
                    ?? FileTransferRetryPolicy()
                retryPolicy = loaded
                persistedRetryPolicy = loaded
                retryStateReadError = nil
                retryStateLoaded = true
            } catch { retryStateReadError = Self.describe(error) }
        }
        if !schedulingStateLoaded {
            do {
                let data = try RecordingMetadataAccess.readIfPresent(at: schedulingStateURL, maximumBytes: 65_536)
                let loaded = try data.map { try TransportCodec.decode(FileTransferSchedulingPolicy.self, from: $0) }
                    ?? FileTransferSchedulingPolicy()
                schedulingPolicy = loaded
                persistedSchedulingPolicy = loaded
                schedulingStateReadError = nil
                schedulingStateLoaded = true
            } catch { schedulingStateReadError = Self.describe(error) }
        }
        if !backgroundRefreshStateLoaded {
            do {
                if let data = try RecordingMetadataAccess.readIfPresent(at: backgroundRefreshStateURL, maximumBytes: 4_096) {
                    let intent = try TransportCodec.decode(BackgroundRefreshIntent.self, from: data)
                    guard intent.schemaVersion == 1,
                          intent.candidateSweep.map({ $0.valid }) ?? true else {
                        throw RepositoryError.invalidManifest("后台同步续接记录无效")
                    }
                    if let date = intent.preferredDate {
                        guard date.timeIntervalSince1970.isFinite,
                              date > Date(timeIntervalSince1970: 946_684_800),
                              date <= Date().addingTimeInterval(24 * 60 * 60) else {
                            throw RepositoryError.invalidManifest("后台同步续接时间无效")
                        }
                    }
                    candidateSweep = intent.candidateSweep
                    backgroundRefreshPreferredDate = intent.preferredDate
                }
                backgroundRefreshStateReadError = nil
                backgroundRefreshStateLoaded = true
            } catch { backgroundRefreshStateReadError = Self.describe(error) }
        }
        return transferStateLoaded
    }

    private var transferStateLoaded: Bool {
        retryStateLoaded && schedulingStateLoaded && backgroundRefreshStateLoaded
    }

    /// WC lifecycle only: no transfer work, repository access or writer refresh.
    func foregroundDidChange(_ active: Bool) {
        maintenanceLock.lock(); evidenceForeground = active; maintenanceLock.unlock()
        backgroundSyncDiagnostics.context(foreground: active)
        if active { work.async { [self] in foregroundExitPending = true } }
        guard let connectivity else { return }
        connectivityMetadata.setForeground(active, session: connectivity, owner: self)
        if active, connectivityMetadata.beginForegroundActivation(connectivity, owner: self) {
            connectivity.activate()
        }
    }

    /// A real foreground/manual action may revalidate persisted diagnostic
    /// metadata. This path cannot request transfer work or read the repository.
    func observeDiagnosticEvidence(onThrottle: (@Sendable (Int) -> Void)? = nil) {
        backlogEvidence.observeVerifiedMetadata(onThrottle: onThrottle)
    }

    /// Only the real WatchKit background transition can retire a request which
    /// the system ignored while this app remained in the foreground. Ordinary
    /// background callbacks must keep an accepted overdue request unchanged.
    func enteredBackground(at now: Date = Date()) {
        work.async { [self] in
            guard foregroundExitPending else { return }
            foregroundExitPending = false
            // Inactivity can revoke full maintenance during a sealed handoff.
            // Use this real edge before suspension; a timer cannot wake us.
            // This never renews an expired generation or foreground ownership.
            requestSynchronization()
            guard loadTransferStateIfNeeded(),
                  WatchBackgroundTransferPolicy.shouldRenewRefreshAfterForegroundExit(
                    preferredDate: backgroundRefreshPreferredDate, now: now) else { return }
            backgroundRefreshConfirmedDate = nil
            backgroundRefreshRequestInFlight = nil
            backgroundRefreshRetryAfter = nil
            record(kind: "watch.background_refresh_foreground_deadline_missed", detail: "renewed_on_background_edge=true")
            requestBackgroundRefreshIfNeeded(now: now)
        }
    }

    /// Publish the gate synchronously: a refresh already queued on `work` must
    /// see scene/task changes before beginning any historical maintenance.
    func setMaintenanceAllowed(_ allowed: Bool, foreground: Bool? = nil, liveCapture: Bool? = nil) {
        maintenanceLock.lock()
        if let foreground { evidenceForeground = foreground }
        if let liveCapture { evidenceLiveCapture = liveCapture }
        maintenanceLock.unlock()
        _ = updateMaintenanceOwner(allowed)
        backgroundSyncDiagnostics.context(foreground: foreground, liveCapture: liveCapture,
            maintenanceOwnerAllowed: allowed)
    }

    /// The foreground owner rechecks its current scene before calling. A WK
    /// task may have outlived the last writer status; renew only that permission,
    /// and request work once when the gate actually reopens. Task completion
    /// alone never grants maintenance or resets delivery/ACK backoff.
    func renewForegroundMaintenance() {
        guard updateMaintenanceOwner(true) else { return }
        work.async { [self] in
            // An inactive transition or a new WK task can close the gate before
            // this coalesced request reaches the serial worker.
            guard maintenanceAllowed else { return }
            requestSynchronization()
        }
    }

    private func backlogEvidenceContext() -> WatchBacklogEvidence.Context {
        maintenanceLock.lock()
        let foreground = evidenceForeground, capture = evidenceLiveCapture
        maintenanceLock.unlock()
        // A point observation at the event, never proof of continuous charging.
        return WatchBacklogEvidence.Context(foreground: foreground, liveCapture: capture,
            externalPower: powerStateProvider(), opportunity: activeBoundedGeneration)
    }

    private func updateMaintenanceOwner(_ allowed: Bool) -> Bool {
        maintenanceLock.lock()
        defer { maintenanceLock.unlock() }
        let wasAllowed = ownerMaintenanceAllowed && backgroundTaskIDs.isEmpty && !maintenanceNeedsOwnerSignal
        ownerMaintenanceAllowed = allowed
        if allowed, backgroundTaskIDs.isEmpty {
            maintenanceNeedsOwnerSignal = false
            backgroundExecutionExpired = false
        }
        let isAllowed = ownerMaintenanceAllowed && backgroundTaskIDs.isEmpty && !maintenanceNeedsOwnerSignal
        return !wasAllowed && isAllowed
    }

    private var maintenanceAllowed: Bool {
        maintenanceLock.lock(); defer { maintenanceLock.unlock() }
        return ownerMaintenanceAllowed && backgroundTaskIDs.isEmpty && !maintenanceNeedsOwnerSignal
    }

    private var hasBackgroundTasks: Bool {
        maintenanceLock.lock(); defer { maintenanceLock.unlock() }
        return !backgroundTaskIDs.isEmpty
    }

    private var boundedExecutionAllowed: Bool {
        maintenanceLock.lock(); defer { maintenanceLock.unlock() }
        return !backgroundExecutionExpired
            && (activeBoundedGeneration == nil || activeBoundedGeneration == backgroundExecutionGeneration)
    }

    private func hasLiveBackgroundStallRecoveryTask(generation: UInt64) -> Bool {
        maintenanceLock.lock(); defer { maintenanceLock.unlock() }
        // Timers, delegate callbacks, and the scene-exit pass can observe idle
        // progress, but only a current WatchKit grant can verify a source here.
        return generation == backgroundExecutionGeneration && !backgroundExecutionExpired
            && !ownerMaintenanceAllowed && evidenceLiveCapture != true
            && backgroundTaskIDs.contains { id in
                backgroundTaskGenerations[id] == generation && !expiredBackgroundTaskIDs.contains(id)
            }
    }

    private var currentBackgroundGeneration: UInt64 {
        maintenanceLock.lock(); defer { maintenanceLock.unlock() }
        return backgroundExecutionGeneration
    }

    private func releaseBackgroundTask(_ id: UUID) {
        maintenanceLock.lock()
        backgroundTaskIDs.remove(id)
        backgroundTaskGenerations.removeValue(forKey: id)
        expiredBackgroundTaskIDs.remove(id)
        maintenanceLock.unlock()
    }

    private func consumeBackgroundBudgetReset() {
        maintenanceLock.lock()
        guard activeBoundedGeneration == nil || activeBoundedGeneration == backgroundExecutionGeneration else {
            maintenanceLock.unlock()
            return
        }
        let needed = backgroundBudgetNeedsReset
        backgroundBudgetNeedsReset = false
        maintenanceLock.unlock()
        if needed { resetLightBudget() }
    }

    private func resetLightBudget() {
        lightWindowStarted = Date()
        lightEnqueued = 0
        lightCandidatesChecked = 0
        refreshPowerBudget()
        backgroundDecision = .notEvaluated
        backgroundDecisionRecorded = false
        backgroundDecisionCandidates = nil
        backgroundDecisionEligible = nil
        backgroundDecisionNative = nil
        backgroundDecisionNativeSample = 0
        backgroundDecisionNativeZero = 0
        backgroundDecisionNativeFinished = 0
        backgroundDecisionForeign = nil
    }

    private func refreshPowerBudget() {
        // WatchKit exposes a current battery state, not a charging wake event.
        // Sampling only during real runtime cannot wake a suspended process.
        backgroundPowerPolicy = WatchBackgroundTransferPolicy(isCharging: powerStateProvider(), sealedBacklog: sealedBacklogHandoff)
        lightCandidateChecksRemaining = backgroundPowerPolicy.remainingCandidateChecks(consumed: lightCandidatesChecked)
        lightEnqueuesRemaining = backgroundPowerPolicy.remainingEnqueues(consumed: lightEnqueued)
        backgroundSyncDiagnostics.budget(externalPower: backgroundPowerPolicy.isCharging,
            candidateLimit: backgroundPowerPolicy.maximumCandidateChecks,
            enqueueLimit: backgroundPowerPolicy.maximumEnqueues,
            candidateRemaining: lightCandidateChecksRemaining, enqueueRemaining: lightEnqueuesRemaining,
            nativeLimit: backgroundPowerPolicy.maximumOutstandingFiles)
    }

    private func observeBackgroundDecision(_ decision: BackgroundDecision, candidates: Int? = nil,
                                           eligible: Int? = nil, transfers: [WCSessionFileTransfer]? = nil,
                                           foreign: Int? = nil) {
        if let transfers { backgroundSyncDiagnostics.nativeQueue(transfers) }
        if let reason = WatchTransferRefusalDiagnostic.Reason(rawValue: decision.rawValue) {
            recordTransferRefusal(reason, nativeCount: transfers?.count)
        }
        backgroundSyncDiagnostics.admission(reason: decision.rawValue, candidates: candidates, eligible: eligible)
        guard !backgroundCompletions.isEmpty else { return }
        backgroundDecision = decision
        if let candidates { backgroundDecisionCandidates = candidates; backgroundDecisionEligible = nil }
        if let eligible { backgroundDecisionEligible = eligible }
        if let foreign { backgroundDecisionForeign = foreign }
        if let transfers {
            backgroundDecisionNative = transfers.count
            let sample = Array(transfers.prefix(3))
            backgroundDecisionNativeSample = sample.count
            backgroundDecisionNativeZero = sample.filter {
                $0.progress.totalUnitCount > 0 && $0.progress.completedUnitCount == 0
            }.count
            backgroundDecisionNativeFinished = sample.filter {
                $0.progress.totalUnitCount > 0 && $0.progress.completedUnitCount >= $0.progress.totalUnitCount
            }.count
        }
    }

    private func recordBackgroundDecision(completionReason: String) {
        guard !backgroundDecisionRecorded else { return }
        backgroundDecisionRecorded = true
        let decision = lightEnqueued > 0 ? BackgroundDecision.enqueued.rawValue : backgroundDecision.rawValue
        record(kind: "watch.background_transfer_decision", detail:
            "reason=\(decision) completion=\(completionReason) completionStage=opportunity_drained activation=\(connectivity?.activationState.rawValue ?? -1)"
            + " observedNative=\(backgroundDecisionNative ?? -1) nativeSample=\(backgroundDecisionNativeSample)"
            + " nativeZeroProgress=\(backgroundDecisionNativeZero) nativeFinishedProgress=\(backgroundDecisionNativeFinished)"
            + " observedForeignPresent=\(backgroundDecisionForeign ?? -1) candidates=\(backgroundDecisionCandidates ?? -1)"
            + " lastCandidateEligible=\(backgroundDecisionEligible ?? -1) candidateBudget=\(lightCandidateChecksRemaining)"
            + " enqueueBudget=\(lightEnqueuesRemaining) enqueued=\(lightEnqueued)"
            + " scheduledTasks=\(applicationRefreshTaskIDs.count) incomingPending=\(connectivity?.hasContentPending ?? false)"
            + " refreshIntent=\(backgroundRefreshPreferredDate != nil) refreshRequestPending=\(backgroundRefreshRequestInFlight != nil)"
            + " externalPower=\(backgroundPowerPolicy.isCharging) candidateLimit=\(backgroundPowerPolicy.maximumCandidateChecks) enqueueLimit=\(backgroundPowerPolicy.maximumEnqueues)")
        // A successful early enqueue must not erase why the rest of this pass
        // stopped. These are bounded reason enums/counts, never source IDs.
        if let handoffLastRefusal {
            record(kind: "watch.background_handoff_stopped", detail:
                "reason=\(handoffLastRefusal) skippedCandidates=\(handoffSkippedCandidates) elapsedLimitSeconds=2")
        }
    }

    /// Holds the system's WatchConnectivity execution opportunity until both
    /// incoming content and the serial ACK/queue work have drained. Outgoing
    /// transfers remain system-owned; this never waits for a phone to connect.
    func performBackgroundConnectivityTask(id: UUID, completion: @escaping @Sendable () -> Void) {
        beginBackgroundTask(id: id, applicationRefresh: false, completion: completion)
    }

    /// A scheduled fallback only gets the same small preparation budget as a
    /// WC wake. It never waits for outgoing files or starts capture/history work.
    func performBackgroundRefreshTask(id: UUID, completion: @escaping @Sendable () -> Void) {
        beginBackgroundTask(id: id, applicationRefresh: true, completion: completion)
    }

    private func beginBackgroundTask(id: UUID, applicationRefresh: Bool,
                                     completion: @escaping @Sendable () -> Void) {
        let startedAt = Date()
        maintenanceLock.lock()
        if backgroundTaskIDs.subtracting(expiredBackgroundTaskIDs).isEmpty {
            backgroundExecutionGeneration &+= 1
            backgroundBudgetNeedsReset = true
            backgroundExecutionExpired = false
        }
        let generation = backgroundExecutionGeneration
        backgroundTaskIDs.insert(id)
        backgroundTaskGenerations[id] = generation
        maintenanceNeedsOwnerSignal = true
        backgroundSyncDiagnostics.taskStarted(id: id, generation: generation,
            applicationRefresh: applicationRefresh)
        maintenanceLock.unlock()
        work.async { [self] in
            recordTransferOpportunity(.started, generation: generation, observedAt: startedAt)
            backgroundCompletions[id] = completion
            maintenanceLock.lock()
            let alreadyExpired = expiredBackgroundTaskIDs.contains(id)
                || generation != backgroundExecutionGeneration
            maintenanceLock.unlock()
            guard !alreadyExpired else { return }
            consumeBackgroundBudgetReset()
            if applicationRefresh {
                stateRecoveryRefreshDate = nil
                stateRecoveryRefreshInFlight = false
                stateRecoveryRefreshRetryAfter = nil
                applicationRefreshTaskIDs.insert(id)
                // The system delivered this request. A still-pending source
                // will establish the next intent with a new preferred date.
                let hadPendingIntent = backgroundRefreshPreferredDate != nil
                // Keep the last durable continuation until this bounded pass
                // commits either its successor or a complete cache-ACK sweep.
                // An expiration before that commit cannot erase the disk hint.
                backgroundRefreshPreferredDate = nil
                backgroundRefreshRequestInFlight = nil
                backgroundRefreshConfirmedDate = nil
                backgroundRefreshRetryAfter = nil
                backgroundRefreshRecoveryNeeded = hadPendingIntent
            }
            // A closed FIFO is already durable. Arm its next opportunity from
            // fixed-size metadata before activation, receipt replay, or native
            // queue inspection can spend the rest of this WatchKit grant.
            if connectivity != nil, boundedExecutionAllowed,
               (try? repository.hasClosedFreshBacklog()) == true {
                sealedBacklogHandoff = true
                requestBackgroundRefreshIfNeeded()
            }
            record(kind: "watch.background_connectivity_started",
                   detail: "task=\(id.uuidString) applicationRefresh=\(applicationRefresh)")
            if let connectivity, connectivity.activationState != .activated {
                backgroundActivationFailed = false
                connectivityMetadata.activationRequested(connectivity, owner: self)
                connectivity.activate()
            }
            requestSynchronization()
            requestBackgroundCompletionCheck()
        }
    }

    func expireBackgroundConnectivityTask(id: UUID) {
        // Publish expiration before any work already queued on the serial worker
        // can enqueue another file. Exact incoming ACK commits remain separate.
        let expiredAt = Date()
        maintenanceLock.lock()
        let expiredGeneration = backgroundTaskGenerations[id] ?? backgroundExecutionGeneration
        let wasRegistered = backgroundTaskIDs.contains(id) && !expiredBackgroundTaskIDs.contains(id)
        if wasRegistered {
            expiredBackgroundTaskIDs.insert(id)
            backgroundSyncDiagnostics.taskEnded(id: id, expired: true)
            if expiredGeneration == backgroundExecutionGeneration,
               backgroundTaskIDs.subtracting(expiredBackgroundTaskIDs).isEmpty {
                backgroundExecutionExpired = true
            }
        }
        maintenanceLock.unlock()
        work.async { [self] in
            if wasRegistered { recordTransferOpportunity(.expired, generation: expiredGeneration, observedAt: expiredAt) }
            guard backgroundCompletions.removeValue(forKey: id) != nil else { return }
            backgroundFinalizingTaskIDs.remove(id)
            applicationRefreshTaskIDs.remove(id)
            releaseBackgroundTask(id)
            // Expiration is not an ACK. In-progress repository transactions keep
            // their existing durability/recovery rules and unconfirmed audio.
            record(kind: "watch.background_connectivity_expired", detail: "task=\(id.uuidString)")
        }
    }

    private func backgroundSessionStateChanged() {
        work.async { [self] in
            // Activation KVO can precede its delegate callback. Drain a bounded
            // pass before considering a cold scheduled opportunity complete.
            if !backgroundCompletions.isEmpty, connectivity?.activationState == .activated {
                requestSynchronization()
            }
            requestBackgroundCompletionCheck()
        }
    }

    private func requestBackgroundCompletionCheck() {
        guard !backgroundCompletions.isEmpty, !backgroundCompletionCheckScheduled else { return }
        backgroundCompletionCheckScheduled = true
        work.async { [self] in
            backgroundCompletionCheckScheduled = false
            // A callback may have queued a coalesced synchronization after this
            // check. That synchronization requests another check when finished.
            guard !refreshScheduled else { return }
            if connectivity?.activationState == .activated,
               preparedActivationGeneration != currentBackgroundGeneration {
                requestSynchronization()
                return
            }
            guard backgroundMetadataFlushedRevision == backgroundWorkRevision else {
                flushBackgroundMetadataBeforeCompletion()
                return
            }
            // Persist/schedule the successor before relinquishing a scheduled
            // refresh opportunity. Expiration remains the hard execution bound.
            if backgroundRefreshRequestInFlight == nil, !stateRecoveryRefreshInFlight,
               connectivity == nil || connectivity?.activationState == .activated {
                finishBackgroundConnectivityTasks(reason: "scheduled_local_work_drained",
                    only: applicationRefreshTaskIDs)
            }
            if backgroundActivationFailed {
                finishBackgroundConnectivityTasks(reason: "activation_failed")
                return
            }
            guard connectivity == nil || (connectivity?.activationState == .activated
                && connectivity?.hasContentPending == false) else { return }
            finishBackgroundConnectivityTasks(reason: "incoming_and_local_work_drained",
                only: Set(backgroundCompletions.keys).subtracting(applicationRefreshTaskIDs))
        }
    }

    private func flushBackgroundMetadataBeforeCompletion() {
        guard !backgroundMetadataFlushInFlight else { return }
        backgroundMetadataFlushInFlight = true
        let revision = backgroundWorkRevision
        let group = DispatchGroup()
        group.enter()
        backgroundSyncDiagnostics.flush { group.leave() }
        group.enter()
        backlogEvidence.flush { group.leave() }
        group.notify(queue: work) { [self] in
            backgroundMetadataFlushInFlight = false
            backgroundMetadataFlushedRevision = revision
            // A receipt arriving during I/O must drain its own repository and
            // diagnostic work before completion; it cannot borrow this flush.
            requestBackgroundCompletionCheck()
        }
    }

    private func finishBackgroundConnectivityTasks(reason: String, only ids: Set<UUID>? = nil) {
        guard !backgroundCompletions.isEmpty else { return }
        maintenanceLock.lock()
        let liveTaskIDs = backgroundTaskIDs.subtracting(expiredBackgroundTaskIDs)
        maintenanceLock.unlock()
        let completions = backgroundCompletions.filter {
            liveTaskIDs.contains($0.key) && !backgroundFinalizingTaskIDs.contains($0.key)
                && (ids == nil || ids!.contains($0.key))
        }
        guard !completions.isEmpty else { return }
        // Refresh-only completion can precede the incoming WC drain. Sample
        // the shared counters only when the final live waiter is completing.
        // A new ID is registered synchronously before its worker closure runs.
        maintenanceLock.lock()
        let finalRegisteredWaiters = backgroundTaskIDs.subtracting(expiredBackgroundTaskIDs)
            .isSubset(of: Set(completions.keys))
        maintenanceLock.unlock()
        if completions.count == backgroundCompletions.count, finalRegisteredWaiters {
            recordBackgroundDecision(completionReason: reason)
        }
        backgroundFinalizingTaskIDs.formUnion(completions.keys)
        record(kind: "watch.background_connectivity_finished",
               detail: "tasks=\(completions.count) reason=\(reason) candidatesChecked=\(lightCandidatesChecked) enqueued=\(lightEnqueued) maintenanceDeferred=true")
        for id in completions.keys {
            backgroundSyncDiagnostics.taskEnded(id: id, expired: false)
        }
        // The completion counters belong in the same durable small report as
        // the ACK/queue observations. A failed report write is contained by its
        // writer; the OS expiration handler remains the hard execution bound.
        flushFinalBackgroundMetadata(completions, revision: backgroundWorkRevision)
    }

    private func flushFinalBackgroundMetadata(_ completions: [UUID: @Sendable () -> Void], revision: UInt64) {
        let group = DispatchGroup()
        group.enter()
        backgroundSyncDiagnostics.flush { group.leave() }
        group.enter()
        backlogEvidence.flush { group.leave() }
        group.notify(queue: work) { [self] in
            maintenanceLock.lock()
            let live = backgroundTaskIDs.subtracting(expiredBackgroundTaskIDs)
            maintenanceLock.unlock()
            let pending = completions.filter { live.contains($0.key) && backgroundCompletions[$0.key] != nil }
            guard !pending.isEmpty else { return }
            // Keep completion ownership through the final counter write. An ACK
            // arriving on `work` while that I/O is pending must drain both
            // writers again, including an otherwise side-effect-free replay.
            // Expired tasks are excluded above; the native expiration callback
            // never waits for a writer or for this queue to relinquish its lease.
            guard revision == backgroundWorkRevision, !refreshScheduled else {
                flushFinalBackgroundMetadata(pending, revision: backgroundWorkRevision)
                return
            }
            backgroundMetadataFlushedRevision = revision
            maintenanceLock.lock()
            let completedGenerations = Set(pending.keys.compactMap { backgroundTaskGenerations[$0] })
            maintenanceLock.unlock()
            for generation in completedGenerations { recordTransferOpportunity(.completed, generation: generation) }
            forwardTransferDiagnostics()
            for (id, completion) in pending {
                backgroundCompletions.removeValue(forKey: id)
                backgroundFinalizingTaskIDs.remove(id)
                applicationRefreshTaskIDs.remove(id)
                releaseBackgroundTask(id)
                completion()
            }
            requestBackgroundCompletionCheck()
        }
    }

    func update(_ snapshot: RecorderSnapshot, forceRetry: Bool = false) {
        // A queued writer observation may lose its execution opportunity before
        // this worker runs. It cannot revive an expired or superseded grant.
        maintenanceLock.lock()
        let observedGeneration = backgroundExecutionGeneration, observedExpired = backgroundExecutionExpired
        maintenanceLock.unlock()
        work.async { [self] in
            let newSeal = snapshot.lastSealedAt != nil && snapshot.lastSealedAt != snapshotState.latest?.lastSealedAt
            let closed = snapshot.state == .paused || snapshot.state == .ended
            if closed, newSeal || snapshot.state != snapshotState.latest?.state {
                registerSnapshotOpportunity(expectedGeneration: observedGeneration, observedExpired: observedExpired)
            }
            maintenanceLock.lock()
            let outsideBackgroundTask = backgroundTaskIDs.isEmpty
            if outsideBackgroundTask, ownerMaintenanceAllowed { maintenanceNeedsOwnerSignal = false }
            maintenanceLock.unlock()
            if outsideBackgroundTask, newSeal { resetLightBudget() }
            if snapshot.state == .paused || snapshot.state == .ended {
                sealedBacklogHandoff = true
                refreshPowerBudget()
            }
            if snapshot != snapshotState.latest { snapshotForPublication = snapshot }
            snapshotState.receive(snapshot)
            // A foreground/status refresh must not erase delivery/ACK backoff.
            // forceRetry remains source-compatible with the recorder's refresh call.
            requestSynchronization()
        }
    }

    func resynchronize(requestedAt: Date? = nil) {
        if requestedAt != nil { observeDiagnosticEvidence() }
        work.async { [self] in
            if let requestedAt {
                syncFeedback.beginRequest(at: requestedAt)
                onSyncFeedback?(syncFeedback)
            }
            deliveredEventIDs.removeAll()
            requestSynchronization(trigger: .manual)
        }
    }

    /// Foreground presentation refresh; does not enqueue work or change backoff.
    func refreshFeedback() {
        work.async { [self] in requestFeedbackRefresh() }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        connectivityMetadata.activationCompleted(session, owner: self, error: error)
        let message = error?.localizedDescription
        let failure = error.map(Self.describe)
        work.async { [self] in
            if let failure { record(kind: "watch_activation_failed", detail: failure) }
            if let message { reportSyncIssue("手机连接初始化失败：\(message)") }
            backgroundActivationFailed = failure != nil
            if activationState == .activated, failure == nil {
                lastPublishedSnapshot = nil
                cancelIneligibleQueuedDiagnostics(using: session)
                sanitizeQueuedApplicationContext(using: session)
            }
            requestSynchronization(preservingFailure: message != nil)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        registerRealCallbackOpportunity()
        connectivityMetadata.observe(session, owner: self, trigger: .reachability)
        work.async { [self] in
            requestSynchronization()
        }
    }

    func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        // Informational for this dependent Watch app, never an authorization gate.
        connectivityMetadata.observe(session, owner: self, trigger: .counterpartChanged)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        registerRealCallbackOpportunity()
        receive(Payload(dictionary: userInfo))
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        registerRealCallbackOpportunity()
        receiveAutomaticSync(Payload(dictionary: applicationContext), channel: "application_context")
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // This protocol is reply-only. Never route it (even a mixed/invalid
        // packet) through receipt processing or synchronization.
        if message.keys.contains(TransportCodec.statusRequestKey) {
            connectivityMetadata.observe(session, owner: self, trigger: .status)
            return
        }
        registerRealCallbackOpportunity()
        receive(Payload(dictionary: message))
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        if message.keys.contains(TransportCodec.statusRequestKey) {
            connectivityMetadata.statusRequested(session, owner: self)
            work.async { [self] in
                guard message.count == 1,
                      let data = message[TransportCodec.statusRequestKey] as? Data, data.count <= 1_024,
                      let request = try? TransportCodec.decode(RecorderStatusRequest.self, from: data),
                      request.schemaVersion == 1 else {
                    replyHandler([:]); return
                }
                let respond: @Sendable (RecorderSnapshot?) -> Void = { [weak self] snapshot in
                    guard let self else { return }
                    self.work.async {
                        guard let encoded = try? TransportCodec.encode(RecorderStatusResponse(
                            requestID: request.requestID,
                            snapshot: snapshot.map(WatchDiagnosticTransferPolicy.snapshotForTransfer))) else {
                            replyHandler([:]); return
                        }
                        self.connectivityMetadata.statusFinished(session, owner: self,
                        outcome: snapshot == nil ? .noReport : .received, receivedReply: true)
                    replyHandler([TransportCodec.statusResponseKey: encoded])
                    }
                }
                // Query an already living writer only. No repository
                // access, queue/count scan, timestamp renewal, ACK, events,
                // application context publication or synchronization trigger.
                // In particular a cached bridge snapshot cannot be made current
                // when the writer is absent in a headless process.
                if let onStatusQuery { onStatusQuery(respond) }
                else { respond(nil) }
            }
            return
        }
        registerRealCallbackOpportunity()
        receive(Payload(dictionary: message))
        // Receipt processing is deliberately separate. This is not a segment ACK.
        replyHandler(["requestReceived": true])
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let callbackAt = Date()
        registerRealCallbackOpportunity()
        let manifest = (fileTransfer.file.metadata?[TransportCodec.manifestKey] as? Data)
            .flatMap { try? TransportCodec.decode(SegmentManifest.self, from: $0) }
        let attemptID = persistentAttemptID(fileTransfer)
        let enqueuedAt = (fileTransfer.file.metadata?[Self.enqueuedAtKey] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        let failure = error.map(Self.describe)
        work.async { [self] in
            recordTransferAttempt(fileTransfer, phase: .completion,
                outcome: error == nil ? .succeeded : .failed, observedAt: callbackAt)
            defer { forwardTransferDiagnostics() }
            let wasStalledCancellation = recoveryKey(fileTransfer)
                .map { stalledCancellationKeys.remove($0) != nil } ?? false
            // A malformed or obsolete callback cannot replace the retry state
            // of a different local file that happens to share its UUID.
            guard let manifest else {
                record(kind: "file_transfer_callback_ignored", detail: "reason=missing_or_invalid_manifest")
                requestSynchronization()
                return
            }
            do {
                guard try repository.manifest(id: manifest.id) == manifest else {
                    record(kind: "file_transfer_callback_ignored",
                           detail: "id=\(manifest.id.uuidString) reason=manifest_mismatch")
                    requestSynchronization()
                    return
                }
            } catch {
                record(kind: "file_transfer_callback_lookup_failed", detail: Self.describe(error))
                requestSynchronization()
                return
            }
            // A receipt can arrive before a file completion callback, including
            // the completion of an obsolete retransmission we have cancelled.
            if cancelledAcknowledgedManifests[manifest.id] == manifest
                || hasDurableAcknowledgement(for: manifest) {
                retryPolicy.acknowledge(id: manifest.id)
                requestSynchronization()
                return
            }
            let recoveryStateAvailable = loadRecoveryStateIfNeeded()
            if wasStalledCancellation || (recoveryStateAvailable
                && recoveryKey(fileTransfer).map({ outstandingPolicy.cancellationRequested(key: $0) }) == true) {
                // Both success and failure can arrive after cancel, queue removal,
                // restart, or replacement. Neither is a new receipt or failure.
                record(kind: "file_stalled_cancellation_completed",
                       detail: "id=\(manifest.id.uuidString) transport_only=true")
                requestSynchronization()
                return
            }
            if let attemptID {
                do {
                    if let intent = try repository.preemptionIntent(attemptID: attemptID), intent.manifest == manifest {
                        // Both success and cancellation failure are obsolete scheduling
                        // callbacks. Neither changes retry counts or acknowledges audio.
                        record(kind: "file_preemption_callback_ignored",
                               detail: "id=\(manifest.id.uuidString) attempt=\(attemptID) transport_only=true")
                        requestSynchronization()
                        return
                    }
                } catch {
                    // Unknown cancellation bookkeeping cannot overwrite another attempt.
                    reportSyncIssue("发送任务状态待核对，原始录音保留。")
                    requestSynchronization()
                    return
                }
            }
            if let connectivity {
                adoptOutstandingAttempts(using: connectivity, pending: [manifest])
            }
            if let failure {
                    if !recoveryStateAvailable {
                        // The optional watchdog must not swallow a completion
                        // or let an unclassified cancellation shorten ACK wait.
                        guard retryPolicy.deferUnclassifiedCompletion(of: manifest, attemptID: attemptID,
                                                                       enqueuedAt: enqueuedAt) else {
                            record(kind: "file_transfer_obsolete_callback",
                                   detail: "id=\(manifest.id.uuidString) attempt=\(attemptID ?? "unknown") outcome=unclassified_error ignored=true")
                            requestSynchronization()
                            return
                        }
                        persistRetryStateIfNeeded()
                        record(kind: "file_transfer_completion_deferred",
                               detail: "id=\(manifest.id.uuidString) attempt=\(attemptID ?? "unknown") cancellation_state=unavailable outcome=error transport_only=true \(failure)")
                        reportSyncIssue("发送完成状态待核对，原录音与手机确认等待已保留。")
                        requestSynchronization(preservingFailure: true)
                        return
                    }
                    guard retryPolicy.recordFailure(of: manifest, attemptID: attemptID, enqueuedAt: enqueuedAt) else {
                        record(kind: "file_transfer_obsolete_callback",
                               detail: "id=\(manifest.id.uuidString) attempt=\(attemptID ?? "unknown") outcome=failure ignored=true")
                        requestSynchronization()
                        return
                    }
                    record(kind: "file_transfer_failed", detail: "id=\(manifest.id.uuidString) \(failure)")
                    reportSyncIssue("片段暂未送达，原录音已保留，将在后台机会到来时自动重试。")
            } else {
                // Keep the CAF until a separate iPhone persistent receipt arrives.
                guard retryPolicy.recordDelivery(of: manifest, attemptID: attemptID, enqueuedAt: enqueuedAt) else {
                    record(kind: "file_transfer_obsolete_callback",
                           detail: "id=\(manifest.id.uuidString) attempt=\(attemptID ?? "unknown") outcome=delivery ignored=true transport_only=true")
                    requestSynchronization()
                    return
                }
                deliveredPendingIDs.insert(manifest.id)
                let retryAt = retryPolicy.nextRetryDate(pending: [manifest])
                record(kind: "file_delivered_waiting_ack",
                       detail: "id=\(manifest.id.uuidString) attempt=\(attemptID ?? "unknown") retryAt=\(retryAt?.timeIntervalSince1970 ?? 0)")
            }
            // Callback state survives even when the next synchronization cannot
            // run because its maintenance or background execution gate closed.
            persistRetryStateIfNeeded()
            requestSynchronization(preservingFailure: failure != nil)
        }
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        let isReceiptRequest = userInfoTransfer.userInfo[TransportCodec.requestSyncKey] as? Bool == true
        let data = userInfoTransfer.userInfo[TransportCodec.eventsKey] as? Data
        let isEventTransfer = userInfoTransfer.userInfo.keys.contains(TransportCodec.eventsKey)
        let eligibleEvents = WatchDiagnosticTransferPolicy.transferableBatch(from: data)
        let ids = eligibleEvents?.map(\.id) ?? []
        let transferIdentity = ObjectIdentifier(userInfoTransfer)
        let failure = error.map(Self.describe)
        let failureCode = error.map { "\(($0 as NSError).domain):\(($0 as NSError).code)" }
        // A failed optional event packet deliberately does not start another
        // sync. It must therefore not supersede an in-flight file handoff's
        // generation and strand that work until another system opportunity.
        let renewsOpportunity = error == nil || isReceiptRequest || (isEventTransfer && eligibleEvents == nil)
        if renewsOpportunity { registerRealCallbackOpportunity() }
        // Delegate callbacks can arrive while the serial worker is hashing a
        // source. Revoke/complete this exact query before queuing follow-up work.
        if isReceiptRequest { finishReceiptQuery(userInfoTransfer, succeeded: error == nil) }
        work.async { [self] in
            if isEventTransfer && (cancelledDiagnosticTransfers[transferIdentity] != nil || eligibleEvents == nil) {
                // Cancelled/mixed packet completions are not delivery evidence.
                // The next pass selects safe events again using their original IDs.
                // Cancellation ownership is worker-confined; only this branch
                // turns an otherwise failed event completion into follow-up work.
                if !renewsOpportunity { registerRealCallbackOpportunity() }
                pendingLegacyEventCompletion = true
                requestSynchronization(trigger: .eventDeliveryCompletion)
                return
            }
            if isReceiptRequest {
                if let failure, supersededReceiptRequests[transferIdentity] == nil {
                    record(kind: "phone_receipt_request_failed", detail: failure)
                }
                // A transport completion never acknowledges audio and does not
                // bypass the request cooldown.
                requestSynchronization()
                return
            }
            if failure == nil {
                let typedIDs = Set((eligibleEvents ?? []).filter { WatchTransferDiagnostic.parse($0) != nil }.map(\.id))
                deliveredTransferDiagnosticIDs.formUnion(typedIDs)
                deliveredEventIDs.formUnion(Set(ids).subtracting(typedIDs))
                pendingLegacyEventCompletion = pendingLegacyEventCompletion || ids.contains { !typedIDs.contains($0) }
                // Event delivery has no application ACK in this prototype. Explicit resync and
                // app restart replay the journal; the phone deduplicates by stable event.id.
                requestSynchronization(trigger: .eventDeliveryCompletion)
            } else if let failure, let failureCode {
                // The failure does not start another synchronization. Repeated
                // failures of the log channel itself also share the same throttle.
                if eventFailureDiagnostics.shouldLogQueue(fingerprint: failureCode, trigger: .automatic) {
                    record(kind: "event_transfer_failed", detail: failure)
                }
                reportSyncIssue("事件日志暂未送达手机，将在下次同步时重试。")
                requestFeedbackRefresh(preservingFailure: true)
            }
        }
    }

    private func receive(_ payload: Payload) {
        // Also reject status packets sent over a deferred/noninteractive
        // channel: a query must never carry hidden sync or receipt work.
        if payload.dictionary.keys.contains(TransportCodec.statusRequestKey) { return }
        if payload.dictionary.keys.contains(Self.automaticSyncSchemaKey)
            || payload.dictionary.keys.contains(Self.automaticSyncIDKey)
            || payload.dictionary.keys.contains(Self.automaticSyncTimeKey) {
            receiveAutomaticSync(payload, channel: "message_or_user_info")
            return
        }
        work.async { [self] in
            defer { requestBackgroundCompletionCheck() }
            var receiptFailed = false
            var needsSynchronization = false
            if let data = payload.dictionary[TransportCodec.receiptKey] as? Data {
                // Every receipt observation changes diagnostic metadata, even
                // an idempotent replay that needs no transfer/repository work.
                // It must not borrow a flush completed before this callback.
                backgroundWorkRevision &+= 1
                var receivedID: UUID?
                var acknowledgementStage = WatchBackgroundSyncDiagnostics.AcknowledgementStage.decode
                var acknowledgementOperation: AcknowledgementOperation?
                do {
                    let receipt = try TransportCodec.decode(SegmentReceipt.self, from: data)
                    receivedID = receipt.segmentID
                    acknowledgementStage = .commit
                    // Separate the durable application receipt from optional
                    // local cleanup. acknowledge(pruneAudio: true) can throw
                    // after its ACK fsync when unlink/directory sync fails;
                    // that must not hide the committed ACK or block refill.
                    let result = try repository.acknowledge(receipt, pruneAudio: false,
                        observingOperation: { acknowledgementOperation = $0 })
                    backgroundSyncDiagnostics.acknowledged(receipt,
                        newlyCommitted: result.acknowledgementChanged)
                    // The ACK has already committed. Diagnostic failure must not
                    // alter delivery, pruning, retry or application feedback.
                    if let manifest = try? repository.transferEvidenceManifest(id: receipt.segmentID) {
                        backlogEvidence.recordAcknowledgement(receipt, manifest: manifest,
                            newlyCommitted: result.acknowledgementChanged, context: backlogEvidenceContext())
                    } else { backlogEvidence.recordIdentityReadFailure() }
                    let previousRetryPolicy = retryPolicy
                    retryPolicy.acknowledge(id: receipt.segmentID)
                    let wasDeliveredPending = deliveredPendingIDs.remove(receipt.segmentID) != nil
                    let recoveredFailure = failedReceiptIDs.remove(receipt.segmentID) != nil
                    presentedReceiptFailureIDs.remove(receipt.segmentID)
                    // A malformed payload has no segment ID. A later valid ACK
                    // can clear its presentation error without claiming a new
                    // recording change; unresolved known IDs still retain it.
                    let clearedReceiptFailure = presentedReceiptFailureIDs.isEmpty
                        && syncIssue == Self.receiptRejectionMessage
                    if clearedReceiptFailure { syncIssue = nil }
                    var audioPruned = false
                    do {
                        // Revalidate/synchronize the exact proof again before
                        // deleting source audio; metadata diagnostics alone can
                        // never grant pruning permission.
                        audioPruned = try repository.acknowledge(receipt, pruneAudio: true).audioPruned
                    } catch {
                        backgroundSyncDiagnostics.acknowledgedCleanupDeferred()
                        record(kind: "watch.background_ack_cleanup_deferred",
                               detail: "id=\(receipt.segmentID.uuidString) durableACK=true localCleanup=deferred")
                    }
                    if result.didChange || audioPruned || recoveredFailure {
                        syncFeedback.recordVerifiedReceipt(id: receipt.segmentID)
                        record(kind: "phone_durable_ack", detail: "id=\(receipt.segmentID.uuidString)")
                        onRepositoryChanged?()
                    }
                    // A replay can still be useful when an obsolete transfer
                    // remains in the system queue. Cancellation revalidates disk.
                    let cancelled = connectivity.map { cancelAcknowledgedDuplicates(using: $0) } ?? false
                    needsSynchronization = result.didChange || audioPruned || recoveredFailure || clearedReceiptFailure || wasDeliveredPending
                        || previousRetryPolicy != retryPolicy || cancelled
                } catch {
                    backgroundSyncDiagnostics.acknowledgementUncommitted(error: error, stage: acknowledgementStage,
                        segmentID: receivedID, operation: acknowledgementOperation)
                    if let receivedID {
                        failedReceiptIDs.insert(receivedID)
                        presentedReceiptFailureIDs.insert(receivedID)
                    }
                    receiptFailed = true
                    needsSynchronization = true
                    record(kind: "phone_ack_rejected", detail: error.localizedDescription)
                    reportSyncIssue(Self.receiptRejectionMessage)
                }
            }
            let requestedSync = payload.dictionary[TransportCodec.requestSyncKey] as? Bool == true
            if requestedSync {
                deliveredEventIDs.removeAll()
                onRepositoryChanged?()
            }
            if needsSynchronization || requestedSync {
                requestSynchronization(trigger: requestedSync ? .manual : .automatic,
                                       preservingFailure: receiptFailed)
            }
        }
    }

    /// Context is a control-only fallback. It never carries a receipt or status
    /// query, grants foreground ownership, or bypasses a saved file retry delay.
    private func receiveAutomaticSync(_ payload: Payload, channel: String) {
        work.async { [self] in
            defer { requestBackgroundCompletionCheck() }
            let dictionary = payload.dictionary
            let keys: Set<String> = [TransportCodec.requestSyncKey, Self.automaticSyncSchemaKey,
                                     Self.automaticSyncIDKey, Self.automaticSyncTimeKey]
            guard Set(dictionary.keys) == keys,
                  let requested = dictionary[TransportCodec.requestSyncKey] as? NSNumber,
                  CFGetTypeID(requested) == CFBooleanGetTypeID(), requested.boolValue,
                  let schema = dictionary[Self.automaticSyncSchemaKey] as? NSNumber,
                  CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
                  let rawID = dictionary[Self.automaticSyncIDKey] as? String, rawID.utf8.count == 36,
                  let id = UUID(uuidString: rawID),
                  let number = dictionary[Self.automaticSyncTimeKey] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let requestedAtMS = Int64(exactly: number.doubleValue) else {
                backgroundSyncDiagnostics.automaticRequest(outcome: "invalid", channel: channel)
                return
            }
            let nowMS = Int64(Date().timeIntervalSince1970 * 1_000)
            let oldest = nowMS - 7 * 24 * 60 * 60 * 1_000
            guard requestedAtMS >= oldest, requestedAtMS <= nowMS + 5 * 60 * 1_000 else {
                backgroundSyncDiagnostics.automaticRequest(outcome: "stale", channel: channel)
                return
            }
            do {
                if automaticSyncRequests == nil {
                    if let data = try RecordingMetadataAccess.readIfPresent(at: automaticSyncStateURL,
                            maximumBytes: Self.automaticSyncMaximumBytes) {
                        let state = try TransportCodec.decode(AutomaticSyncState.self, from: data)
                        guard state.schemaVersion == 1, state.requests.count <= Self.automaticSyncMaximumIDs,
                              Set(state.requests.map(\.id)).count == state.requests.count,
                              state.requests.allSatisfy({ $0.requestedAtMS > 946_684_800_000
                                  && $0.requestedAtMS <= nowMS + 5 * 60 * 1_000 }) else {
                            throw RepositoryError.invalidManifest("自动同步请求去重记录无效")
                        }
                        automaticSyncRequests = state.requests
                    } else { automaticSyncRequests = [] }
                }
                guard !automaticSyncRequests!.contains(where: { $0.id == id }) else {
                    backgroundSyncDiagnostics.automaticRequest(outcome: "replay", channel: channel)
                    return
                }
                var retained = automaticSyncRequests!.filter { $0.requestedAtMS >= oldest }
                retained.append(AutomaticSyncRequest(id: id, requestedAtMS: requestedAtMS))
                retained = Array(retained.suffix(Self.automaticSyncMaximumIDs))
                let bytes = try TransportCodec.encode(AutomaticSyncState(schemaVersion: 1, requests: retained))
                guard bytes.count <= Self.automaticSyncMaximumBytes else { throw POSIXError(.EFBIG) }
                // A replay after process restart must not renew the work. Only
                // a successful small atomic commit consumes this request ID.
                try bytes.write(to: automaticSyncStateURL, options: Self.transferStateWritingOptions)
                automaticSyncRequests = retained
                backgroundSyncDiagnostics.automaticRequest(outcome: "accepted", channel: channel)
                requestSynchronization()
            } catch {
                // Unknown/corrupt state is never empty state. Preserve its exact
                // bytes and retry only on another real incoming opportunity.
                backgroundSyncDiagnostics.automaticRequest(outcome: "state_unavailable", channel: channel)
            }
        }
    }

    private func requestSynchronization(trigger: TransferDiagnosticsPolicy.Trigger = .automatic,
                                        preservingFailure: Bool = false) {
        backgroundWorkRevision &+= 1
        let generation = activeBoundedGeneration ?? currentBackgroundGeneration
        // Coalescing may use a newer explicitly requested opportunity, but an
        // old pass cannot replace that request with its stale execution context.
        pendingSynchronizationGeneration = max(pendingSynchronizationGeneration ?? generation, generation)
        switch (pendingSynchronizationTrigger, trigger) {
        case (.manual?, _), (_, .manual): pendingSynchronizationTrigger = .manual
        case (.automatic?, _), (_, .automatic): pendingSynchronizationTrigger = .automatic
        default: pendingSynchronizationTrigger = trigger
        }
        pendingPreservingFailure = pendingPreservingFailure || preservingFailure
        scheduleRefresh()
    }

    private func requestFeedbackRefresh(preservingFailure: Bool = false) {
        pendingFeedbackRefresh = true
        pendingPreservingFailure = pendingPreservingFailure || preservingFailure
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Drain already queued callbacks first; no debounce delay is introduced.
        work.async { [self] in
            let trigger = pendingSynchronizationTrigger
            let generation = pendingSynchronizationGeneration ?? currentBackgroundGeneration
            let preservingFailure = pendingPreservingFailure
            let feedbackOnly = pendingFeedbackRefresh
            pendingSynchronizationTrigger = nil
            pendingSynchronizationGeneration = nil
            pendingPreservingFailure = false
            pendingFeedbackRefresh = false
            refreshScheduled = false
            if let trigger {
                synchronize(trigger: trigger, preservingFailure: preservingFailure, generation: generation)
            } else if feedbackOnly, maintenanceAllowed {
                publishSyncFeedback()
            }
            requestBackgroundCompletionCheck()
        }
    }

    private func synchronize(trigger: TransferDiagnosticsPolicy.Trigger,
                             preservingFailure: Bool, generation: UInt64) {
        // Candidate preparation can include a full metadata catalogue scan.
        // Start the shared handoff budget at its first actual admission check.
        handoffStartedAt = nil
        handoffLastRefusal = nil
        handoffSkippedCandidates = 0
        let fullMaintenance = maintenanceAllowed
        let previousDiagnosticPermission = transferDiagnosticObservationAllowed
        if case .eventDeliveryCompletion = trigger { transferDiagnosticObservationAllowed = false }
        defer { transferDiagnosticObservationAllowed = previousDiagnosticPermission }
        let replayLegacyEvents: Bool
        if case .eventDeliveryCompletion = trigger { replayLegacyEvents = pendingLegacyEventCompletion }
        else { replayLegacyEvents = true }
        pendingLegacyEventCompletion = false
        defer { forwardTransferDiagnostics() }
        guard fullMaintenance || generation == currentBackgroundGeneration else {
            recordTransferRefusal(.expiredGeneration); return
        }
        let previousGeneration = activeBoundedGeneration
        activeBoundedGeneration = fullMaintenance ? nil : generation
        defer { activeBoundedGeneration = previousGeneration }
        let activatedAtStart = connectivity == nil || connectivity?.activationState == .activated
        defer {
            if !fullMaintenance, activatedAtStart, generation == currentBackgroundGeneration {
                preparedActivationGeneration = generation
            }
        }
        refreshPowerBudget()
        guard maintenanceAllowed || boundedExecutionAllowed else {
            recordTransferRefusal(.expiredGeneration); return
        }
        snapshotPublicationAttempted = false
        defer {
            // Intermediate fresh-admission checks can pass through no_admission
            // before ending at open_tail/native_occupied. Transport only the
            // completed pass, otherwise identical triggers oscillate diagnostics.
            backgroundSyncDiagnostics.finishAdmissionObservation()
            if let connectivity { publishApplicationSnapshot(using: connectivity) }
        }
        guard loadTransferStateIfNeeded() else {
            // Keep the exact disk state until a later opportunity can read it.
            reportSyncIssue("同步等待记录暂不可读，原录音与重试状态保留，将在后台机会中重新读取。")
            let failure = [retryStateReadError, schedulingStateReadError, backgroundRefreshStateReadError]
                .compactMap { $0 }.joined(separator: " | ")
            if failure != lastTransferStateLoadFailure {
                lastTransferStateLoadFailure = failure
                record(kind: "file_transfer_state_load_failed", detail: failure)
            }
            requestStateRecoveryRefreshIfNeeded()
            scheduleBoundedRetryWake()
            return
        }
        lastTransferStateLoadFailure = nil
        stateRecoveryRefreshDate = nil
        stateRecoveryRefreshInFlight = false
        stateRecoveryRefreshRetryAfter = nil
        // This must precede maintenance/fresh-priority early returns and history
        // scans: old diagnostic packets are independent of audio queue capacity.
        if let connectivity {
            cancelIneligibleQueuedDiagnostics(using: connectivity)
            if connectivity.activationState == .activated { sanitizeQueuedApplicationContext(using: connectivity) }
            if connectivity.activationState == .activated {
                recoverStalledTransfer(using: connectivity)
            }
        }
        // A prior WC acceptance does not prove that the phone still has the
        // snapshot. Explicit recovery requests may resend its original evidence.
        if case .manual = trigger { lastPublishedSnapshot = nil }
        guard maintenanceAllowed else {
            if !hasBackgroundTasks { recordTransferRefusal(.noOwner) }
            synchronizeBoundedBackground()
            return
        }
        // Capture the immutable metadata cohort only on ordinary foreground
        // maintenance. It has its own queue and never scans the events or audio.
        backlogEvidence.captureIfNeeded { [weak self] in
            guard let self, self.maintenanceAllowed else { return nil }
            self.maintenanceLock.lock(); let foreground = self.evidenceForeground; self.maintenanceLock.unlock()
            guard foreground == true else { return nil }
            let snapshot = try self.repository.transferEvidenceSnapshot()
            guard self.maintenanceAllowed else { return nil }
            return snapshot
        }
        if !preservingFailure {
            syncIssue = nil
            // These IDs only retain the current failure presentation. Once a
            // normal synchronization clears it, stale IDs must not block a
            // later unrelated receipt-error recovery.
            presentedReceiptFailureIDs.removeAll()
        }
        guard let connectivity else {
            reportSyncIssue("此手表暂时无法使用手机连接，请稍后重试。")
            publishSyncFeedback()
            return
        }
        var feedbackPending: [SegmentManifest]?
        defer {
            persistRetryStateIfNeeded()
            persistSchedulingStateIfNeeded()
            backgroundSyncDiagnostics.consumption(candidateRemaining: lightCandidateChecksRemaining,
                enqueueRemaining: lightEnqueuesRemaining)
            publishSyncFeedback(pendingSnapshot: feedbackPending)
        }
        if let error = retryStateReadError {
            retryStateReadError = nil
            record(kind: "file_retry_state_load_failed", detail: error)
            reportSyncIssue("同步等待记录读取失败；原录音保留，将重新核对手机确认。")
        }
        if let error = schedulingStateReadError {
            schedulingStateReadError = nil
            record(kind: "file_scheduling_state_load_failed", detail: error)
        }
        do {
            if synchronizeFreshPriority(using: connectivity, bounded: false) { return }
            let pending: [SegmentManifest]
            do {
                guard let refreshed = try repository.refreshTransferCandidates(while: { self.maintenanceAllowed }) else {
                    synchronizeBoundedBackground()
                    return
                }
                pending = refreshed
            } catch {
                // A damaged source/ACK cannot authorize a partial full-catalogue
                // result, but the existing bounded path can validate other IDs
                // independently. Directory/access and index-write failures are
                // deliberately excluded and retain the ordinary failure path.
                let damageKind: String
                if error is DecodingError { damageKind = "metadata_decode" }
                else if case RepositoryError.invalidManifest = error { damageKind = "manifest_validation" }
                else if case RepositoryError.receiptMismatch = error { damageKind = "receipt_identity" }
                else { throw error }
                reportSyncIssue("部分历史录音元数据暂无法核对，原始录音保留，将继续有限补传。")
                if syncFailureDiagnostics.shouldLogQueue(fingerprint: "candidate_scan:\(damageKind)", trigger: trigger) {
                    record(kind: "file_transfer_candidate_scan_deferred",
                           detail: "reason=\(damageKind) fullCatalogue=false boundedCandidates=true")
                }
                synchronizeBoundedBackground()
                return
            }
            guard maintenanceAllowed else { synchronizeBoundedBackground(); return }
            feedbackPending = pending
            retryPolicy.retainPending(manifests: pending)
            if pending.isEmpty { clearBackgroundRefreshIntent() }
            else { requestBackgroundRefreshIfNeeded() }
            guard connectivity.activationState == .activated else {
                recordQueue(using: connectivity, pendingCount: pending.count, trigger: trigger)
                return
            }
            // Activation may precede writer.load(). File/receipt work can continue,
            // but only a real writer observation is allowed onto the phone.
            if let snapshot = snapshotState.applicationSnapshot(pendingCount: pending.count) {
                snapshotForPublication = snapshot
                publishApplicationSnapshot(using: connectivity)
            }

            cancelAcknowledgedDuplicates(using: connectivity)
            adoptOutstandingAttempts(using: connectivity, pending: pending)
            guard maintenanceAllowed else { synchronizeBoundedBackground(); return }
            // Cancellation may be asynchronous. Re-read the system queue and
            // count every remaining task; a cancel request does not free a slot.
            let transfers = connectivity.outstandingFileTransfers
            var queuedIDs = Set(transfers.compactMap { transfer -> UUID? in
                guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data else { return nil }
                return try? TransportCodec.decode(SegmentManifest.self, from: data).id
            })
            for id in retryPolicy.recordDisappearedTransfers(outstandingIDs: queuedIDs) {
                record(kind: "file_transfer_disappeared_grace",
                       detail: "id=\(id.uuidString) graceSeconds=\(FileTransferRetryPolicy.disappearanceGrace) retained=true")
            }
            var eligible = pending.filter { !queuedIDs.contains($0.id) && retryPolicy.isEligible($0) }
            var submittedThisPass = 0
            while maintenanceAllowed {
                refreshPowerBudget()
                let native = connectivity.outstandingFileTransfers
                // The scheduling policy permits two historical tasks, reserving
                // the third battery slot for a recently sealed recording.
                let limit = backgroundPowerPolicy.maximumOutstandingFiles
                guard native.count < limit, submittedThisPass < limit else { break }
                queuedIDs = Set(native.compactMap { transfer -> UUID? in
                    guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data else { return nil }
                    return (try? TransportCodec.decode(SegmentManifest.self, from: data))?.id
                })
                let candidate = backgroundPowerPolicy.isCharging
                    ? schedulingPolicy.nextCandidate(from: eligible)
                    : schedulingPolicy.nextCandidate(from: eligible, outstandingIDs: queuedIDs,
                                                       outstandingCount: native.count)
                guard let manifest = candidate, maintenanceAllowed else { break }
                eligible.removeAll { $0.id == manifest.id }
                if let refusal = handoffRefusal(manifest, outstanding: native) {
                    observeHandoffRefusal(refusal, skipped: !refusal.stopsPass)
                    if refusal.stopsPass { break }
                    continue
                }
                guard maintenanceAllowed else { break }
                let audioURL = repository.audioURL(for: manifest)
                // Handoff admission already checked regular-file/size metadata
                // for both power modes, followed by the final deadline check.
                guard maintenanceAllowed else { break }
                let enqueuedAt = Date()
                let attemptID = UUID().uuidString
                let transfer = connectivity.transferFile(audioURL, metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(manifest),
                    Self.enqueuedAtKey: enqueuedAt.timeIntervalSince1970,
                    Self.attemptIDKey: attemptID
                ])
                noteEnqueuedProgress(transfer)
                backgroundSyncDiagnostics.enqueued(manifest, generation: activeBoundedGeneration)
                backlogEvidence.recordEnqueued(manifest, context: backlogEvidenceContext())
                accountEnqueuedTransfer(bounded: false)
                retryPolicy.noteEnqueued(manifest, attemptID: attemptID, at: enqueuedAt)
                schedulingPolicy.noteEnqueued(manifest, outstandingIDs: queuedIDs, at: enqueuedAt)
                persistSchedulingStateIfNeeded()
                record(kind: "file_transfer_enqueued",
                       detail: "id=\(manifest.id.uuidString) sequence=\(manifest.sequence) bytes=\(manifest.byteCount) enqueuedAt=\(enqueuedAt.timeIntervalSince1970) attempt=\(attemptID)")
                queuedIDs.insert(manifest.id)
                submittedThisPass += 1
            }
            requestPhoneReceipts(using: connectivity,
                plan: receiptRequestPlan(using: connectivity, freshHead: nil, hasPendingSegments: !pending.isEmpty))
            scheduleRetryWake(pending: pending, queuedIDs: queuedIDs)
            recordQueue(using: connectivity, pendingCount: pending.count, trigger: trigger)
            // A completed legacy packet must not let a large journal reclaim
            // every event slot before recent transfer diagnostics get a turn.
            // Keep the same shared capacity and never replace native ownership.
            if !legacyEventTurnPending || !replayLegacyEvents { forwardTransferDiagnostics() }
            if maintenanceAllowed, replayLegacyEvents { try synchronizeEvents(using: connectivity) }
        } catch {
            publishApplicationSnapshot(using: connectivity)
            let value = error as NSError
            if syncFailureDiagnostics.shouldLogQueue(fingerprint: "\(value.domain):\(value.code)", trigger: trigger) {
                record(kind: "file_sync_failed", detail: Self.describe(error))
            }
            reportSyncIssue("同步暂未完成：\(error.localizedDescription)")
        }
    }

    /// Only already-observed metadata is serialized here. No history scan or
    /// refreshed observation time is needed to publish during a bounded wake.
    private func publishApplicationSnapshot(using connectivity: WCSession) {
        guard connectivity.activationState == .activated,
              !snapshotPublicationAttempted else { return }
        let snapshot = snapshotForPublication.map(WatchDiagnosticTransferPolicy.snapshotForTransfer)
        let runtime = backgroundSyncDiagnostics.transportObservation()
        let sameProgress = runtime.map { current in
            lastPublishedRuntime.map { current.hasSameProgress(as: $0) } ?? false
        } ?? (lastPublishedRuntime == nil)
        let refreshDue = runtime != nil && lastRuntimePublicationUptime.map {
            ProcessInfo.processInfo.systemUptime - $0 >= 30
        } == true
        guard snapshot != lastPublishedSnapshot || !sameProgress || refreshDue else { return }
        var context: [String: Any] = [:]
        if snapshot != lastPublishedSnapshot, let snapshot {
            context[TransportCodec.snapshotKey] = try? TransportCodec.encode(snapshot)
        }
        if let runtime, let data = try? TransportCodec.encode(runtime),
           data.count <= WatchRuntimeObservation.maximumBytes {
            context[TransportCodec.watchRuntimeKey] = data
        }
        guard !context.isEmpty else { return }
        snapshotPublicationAttempted = true
        do {
            try connectivity.updateApplicationContext(context)
            lastPublishedSnapshot = snapshot
            lastPublishedRuntime = runtime
            lastRuntimePublicationUptime = ProcessInfo.processInfo.systemUptime
        } catch {
            // A failed publication must remain eligible for the next real trigger.
            reportSyncIssue("状态暂未送达手机：\(error.localizedDescription)")
        }
    }

    /// Whole-opportunity limits, not per callback. External power permits a
    /// bounded refill, never unlimited work. Exact incoming ACKs remain independent.
    private func synchronizeBoundedBackground() {
        if activeBoundedGeneration == nil { activeBoundedGeneration = currentBackgroundGeneration }
        defer {
            persistRetryStateIfNeeded()
            persistSchedulingStateIfNeeded()
            backgroundSyncDiagnostics.consumption(candidateRemaining: lightCandidateChecksRemaining,
                enqueueRemaining: lightEnqueuesRemaining)
        }
        guard boundedExecutionAllowed else { return }
        consumeBackgroundBudgetReset()
        guard let connectivity else { return }
        publishApplicationSnapshot(using: connectivity)
        if !hasBackgroundTasks, Date().timeIntervalSince(lightWindowStarted) >= 60 { resetLightBudget() }
        if connectivity.activationState == .activated { cancelAcknowledgedDuplicates(using: connectivity) }
        if synchronizeFreshPriority(using: connectivity, bounded: true) { return }
        // Resolve fresh ownership before spending a request cooldown. A stable
        // completed cache hint suppresses timer/receipt feedback loops, not ACKs.
        var requestLegacyReceipts = true
        defer {
            if requestLegacyReceipts {
                requestPhoneReceipts(using: connectivity,
                    plan: receiptRequestPlan(using: connectivity, freshHead: nil, hasPendingSegments: true))
            }
        }
        let transfers = connectivity.outstandingFileTransfers
        // Native occupancy is real work and invalidates an old empty-cache hint.
        let hasUnknownTransfer = transfers.contains { transfer in
            guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data else { return true }
            return (try? TransportCodec.decode(SegmentManifest.self, from: data)) == nil
        }
        if hasUnknownTransfer || transfers.count >= backgroundPowerPolicy.maximumOutstandingFiles {
            candidateSweep = nil
            observeBackgroundDecision(.nativeOccupied, transfers: transfers)
            requestBackgroundRefreshIfNeeded()
            scheduleBoundedRetryWake()
            return
        }
        do {
            if try retainCompletedCandidateSweep(using: connectivity) {
                requestLegacyReceipts = false
                return
            }
        } catch {
            // A failed generation read is not empty-library evidence. A bounded
            // page can retry it without consuming more than the normal budget.
            if candidateSweep != nil { backgroundRefreshRecoveryNeeded = true }
            candidateSweep = nil
        }
        guard lightCandidateChecksRemaining > 0, lightEnqueuesRemaining > 0 else {
            observeBackgroundDecision(lightCandidateChecksRemaining <= 0 ? .candidateBudget : .enqueueBudget,
                                      transfers: transfers)
            if backgroundRefreshRecoveryNeeded || candidateSweep != nil { requestBackgroundRefreshIfNeeded() }
            scheduleBoundedRetryWake()
            return
        }
        do {
            let batch = try repository.transferCandidateBatch(limit: lightCandidateChecksRemaining)
            if let count = batch.bootstrapCount {
                record(kind: "transfer_candidate_index_bootstrap",
                       detail: "filenames=\(count) seconds=\(batch.bootstrapDuration) manifestDecodes=0 audioHashes=0")
            }
            var candidates: [SegmentManifest] = []
            var needsIndexRepair = false
            // The repository has validated every selected raw position before
            // returning the UUID-deduplicated page. A strict ACK for one UUID
            // covers its repeated positions in that page; only pending/error or
            // an interrupted check can prevent this page's coverage commit.
            var allCheckedAcknowledged = true
            var checkedUniqueIDs = 0
            for id in batch.ids {
                guard boundedExecutionAllowed else { break }
                lightCandidateChecksRemaining -= 1
                lightCandidatesChecked += 1
                checkedUniqueIDs += 1
                do {
                    if let manifest = try repository.pendingSegment(id: id) {
                        allCheckedAcknowledged = false
                        candidates.append(manifest)
                    }
                } catch {
                    // A corrupt/missing hint cannot block other candidates and
                    // never authorizes deleting a file or declaring completion.
                    allCheckedAcknowledged = false
                    syncIssue = "部分待传索引需重新核对，原始录音保留。"
                    let failure = error as NSError
                    // A missing hint can be removed by filename bootstrap. A
                    // damaged real manifest must not reset the historical cursor
                    // on every wake and starve all candidates after it.
                    if failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError {
                        needsIndexRepair = true
                    }
                }
            }
            if needsIndexRepair { try? repository.invalidateTransferCandidates() }
            if checkedUniqueIDs != batch.ids.count { allCheckedAcknowledged = false }
            guard boundedExecutionAllowed else { return }
            observeBackgroundDecision(.noAdmission, candidates: candidates.count, transfers: transfers)
            if try finishCandidateSweepPage(batch, allCheckedAcknowledged: allCheckedAcknowledged,
                                            using: connectivity) {
                requestLegacyReceipts = false
                return
            }
            guard connectivity.activationState == .activated else {
                observeBackgroundDecision(.awaitingActivation)
                if !candidates.isEmpty { scheduleBoundedRetryWake() }
                return
            }
            var queuedIDs = Set(transfers.compactMap { transfer -> UUID? in
                guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data else { return nil }
                return try? TransportCodec.decode(SegmentManifest.self, from: data).id
            })
            adoptOutstandingAttempts(using: connectivity, pending: candidates)
            retryPolicy.recordDisappearedTransfers(outstandingIDs: queuedIDs)
            let notQueued = candidates.filter { !queuedIDs.contains($0.id) }
            var eligible = notQueued.filter { retryPolicy.isEligible($0) }
            backgroundSyncDiagnostics.candidateClassification(candidates: candidates.count,
                alreadyQueued: candidates.count - notQueued.count, retryDeferred: notQueued.count - eligible.count,
                eligible: eligible.count)
            if !notQueued.isEmpty, eligible.isEmpty { observeBackgroundDecision(.retryBackoff, eligible: 0) }
            else if !candidates.isEmpty, notQueued.isEmpty { observeBackgroundDecision(.nativeOccupied, eligible: 0) }
            while boundedExecutionAllowed, lightEnqueuesRemaining > 0 {
                // Re-read native occupancy: even a requested cancellation still
                // owns its slot, and a power downgrade cannot admit extra files.
                refreshPowerBudget()
                let outstandingTransfers = connectivity.outstandingFileTransfers
                let outstanding = outstandingTransfers.count
                backgroundSyncDiagnostics.nativeQueue(outstandingTransfers)
                guard outstanding < backgroundPowerPolicy.maximumOutstandingFiles else { break }
                let candidate = backgroundPowerPolicy.isCharging
                    ? schedulingPolicy.nextCandidate(from: eligible)
                    : schedulingPolicy.nextCandidate(from: eligible, outstandingIDs: queuedIDs,
                                                       outstandingCount: outstanding)
                // Native inspection can outlast this lease. A newer registered
                // task cannot lend its permission to the paused old generation.
                guard boundedExecutionAllowed, lightEnqueuesRemaining > 0,
                      let manifest = candidate else { break }
                eligible.removeAll { $0.id == manifest.id }
                if let refusal = handoffRefusal(manifest, outstanding: outstandingTransfers) {
                    observeHandoffRefusal(refusal, skipped: !refusal.stopsPass)
                    if refusal.stopsPass { break }
                    // No scheduling turn/enqueue budget/attempt is consumed and the source is not
                    // acknowledged or altered. Try another verified candidate
                    // from this already bounded page during the same deadline.
                    continue
                }
                guard boundedExecutionAllowed, lightEnqueuesRemaining > 0 else { break }
                let now = Date()
                let attemptID = UUID().uuidString
                let transfer = connectivity.transferFile(repository.audioURL(for: manifest), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(manifest),
                    Self.enqueuedAtKey: now.timeIntervalSince1970, Self.attemptIDKey: attemptID
                ])
                noteEnqueuedProgress(transfer)
                backgroundSyncDiagnostics.enqueued(manifest, generation: activeBoundedGeneration)
                backlogEvidence.recordEnqueued(manifest, context: backlogEvidenceContext())
                retryPolicy.noteEnqueued(manifest, attemptID: attemptID, at: now)
                schedulingPolicy.noteEnqueued(manifest, outstandingIDs: queuedIDs, at: now)
                accountEnqueuedTransfer(bounded: true)
                observeBackgroundDecision(.enqueued, eligible: 1)
                record(kind: "file_transfer_enqueued",
                       detail: "id=\(manifest.id.uuidString) sequence=\(manifest.sequence) bytes=\(manifest.byteCount) enqueuedAt=\(now.timeIntervalSince1970) attempt=\(attemptID) boundedBackground=true")
                queuedIDs.insert(manifest.id)
            }
            // This timer only runs while the process remains alive. It does not
            // hold the WK task or claim a guaranteed system wake.
            if !batch.ids.isEmpty { scheduleBoundedRetryWake() }
        } catch {
            observeBackgroundDecision(.candidateReadFailed)
            syncIssue = "同步候选暂未读取，原始录音保留，稍后重试。"
            recoverBackgroundRefreshAfterReadFailure()
            scheduleBoundedRetryWake()
        }
    }

    /// A completed pass only suppresses unchanged-cache scheduling. Check the
    /// generation and cursor under the repository lock on every later callback.
    private func retainCompletedCandidateSweep(using connectivity: WCSession) throws -> Bool {
        guard let sweep = candidateSweep, sweep.completed == true else { return false }
        var retained = false
        _ = try repository.withCurrentTransferCandidateCheckpoint(indexStamp: sweep.indexStamp,
                recordCount: sweep.recordCount, nextCursor: sweep.nextCursor) {
            guard boundedExecutionAllowed, connectivity.outstandingFileTransfers.isEmpty else { return }
            retryWake?.cancel(); retryWake = nil; retryWakeAt = nil
            backgroundRefreshRecoveryNeeded = false
            retained = true
        }
        if !retained {
            candidateSweep = nil
            // A changed/unknown generation needs another bounded pass. Fresh
            // ACK checks may already have exhausted this opportunity's budget;
            // retain a continuation rather than falling back to a process timer.
            backgroundRefreshRecoveryNeeded = true
        }
        return retained
    }

    /// A sampled empty page is not an empty library. Only continuous, actually
    /// checked cursor spans in one stable cache generation can stop this hint.
    /// Returns true only after a stable completed scheduling marker is persisted.
    private func finishCandidateSweepPage(_ batch: TransferCandidateBatch,
                                          allCheckedAcknowledged: Bool,
                                          using connectivity: WCSession) throws -> Bool {
        let previous = candidateSweep
        var covered = 0
        if allCheckedAcknowledged, let stamp = batch.indexStamp {
            if let previous, previous.completed != true, previous.indexStamp == stamp,
               previous.recordCount == batch.recordCount, previous.nextCursor == batch.startCursor {
                covered = previous.coveredCursorSteps
            }
            // Repeated newest-tail checks do not advance this coverage. Every
            // cursor step names a position present in this successfully read page.
            covered = min(batch.recordCount, covered + batch.cursorSteps)
            let complete = batch.selectedRecordCount == batch.recordCount || covered >= batch.recordCount
            if complete {
                var committed = false
                _ = try repository.withCurrentTransferCandidateBatch(batch) {
                    guard boundedExecutionAllowed, connectivity.outstandingFileTransfers.isEmpty else { return }
                    let completed = CandidateSweep(indexStamp: stamp, recordCount: batch.recordCount,
                        nextCursor: batch.nextCursor, coveredCursorSteps: batch.recordCount, completed: true)
                    // A genuinely empty library need not create a new state
                    // file. If an earlier hint exists, clear just that hint.
                    if batch.recordCount > 0 || FileManager.default.fileExists(atPath: backgroundRefreshStateURL.path) {
                        try TransportCodec.encode(BackgroundRefreshIntent(schemaVersion: 1,
                            preferredDate: nil, candidateSweep: batch.recordCount > 0 ? completed : nil))
                            .write(to: backgroundRefreshStateURL, options: Self.transferStateWritingOptions)
                    }
                    candidateSweep = batch.recordCount > 0 ? completed : nil
                    backgroundRefreshPreferredDate = nil
                    backgroundRefreshRequestInFlight = nil
                    backgroundRefreshConfirmedDate = nil
                    backgroundRefreshRetryAfter = nil
                    backgroundRefreshRecoveryNeeded = false
                    retryWake?.cancel(); retryWake = nil; retryWakeAt = nil
                    committed = true
                }
                if committed {
                    record(kind: "watch.background_candidate_sweep", detail: "outcome=cache_acknowledged checked=\(batch.ids.count) covered=\(covered) cachedRecords=\(batch.recordCount)")
                    return true
                }
                candidateSweep = nil
            } else {
                candidateSweep = CandidateSweep(indexStamp: stamp, recordCount: batch.recordCount,
                    nextCursor: batch.nextCursor, coveredCursorSteps: covered)
            }
        } else { candidateSweep = nil }
        // An unknown/bad page retains a continuation; it never manufactures an
        // ACK or repeatedly bootstraps a damaged real manifest to cursor zero.
        if backgroundRefreshPreferredDate != nil {
            try TransportCodec.encode(BackgroundRefreshIntent(schemaVersion: 1,
                preferredDate: backgroundRefreshPreferredDate, candidateSweep: candidateSweep))
                .write(to: backgroundRefreshStateURL, options: Self.transferStateWritingOptions)
        }
        requestBackgroundRefreshIfNeeded()
        if backgroundRefreshPreferredDate != nil { backgroundRefreshRecoveryNeeded = false }
        record(kind: "watch.background_candidate_sweep", detail: "outcome=continue checked=\(batch.ids.count) covered=\(covered) cachedRecords=\(batch.recordCount)")
        return false
    }

    /// Returns true whenever fresh work (or unknown fresh state) owns admission.
    /// Charging runtime may hand off up to twelve sealed members in FIFO order;
    /// on battery the existing three-member window remains conservative.
    /// only durable ACKs advance the head and eventually release historical work.
    private func synchronizeFreshPriority(using connectivity: WCSession, bounded: Bool) -> Bool {
        do {
            // Read the durable capture boundary, not a potentially stale UI
            // snapshot. A closed queue gets the same bounded handoff on a WC/WK
            // opportunity as at pause, even after the screen goes dark.
            let state = try readFreshTransferSnapshot(bounded: bounded)
            sealedBacklogHandoff = !state.captureOpen && state.blocksHistory
            refreshPowerBudget()
            guard state.blocksHistory else { return false }
            observeBackgroundDecision(.noAdmission, candidates: state.admissions.count)
            if state.remainingCount > 0 || state.unresolvedOpenCount > 0 {
                requestBackgroundRefreshIfNeeded()
            }
            backgroundRefreshRecoveryNeeded = false
            if !bounded { publishApplicationSnapshot(using: connectivity) }
            if !state.captureOpen, state.unresolvedOpenCount > 0 {
                reportSyncIssue("部分新录音尾段仍待恢复，原始音频保留，历史发送继续等待。")
            }
            guard connectivity.activationState == .activated else {
                observeBackgroundDecision(.awaitingActivation)
                scheduleBoundedRetryWake()
                return true
            }
            requestPhoneReceipts(using: connectivity,
                plan: receiptRequestPlan(using: connectivity, freshHead: state.head,
                                         hasPendingSegments: state.remainingCount > 0))
            cancelAcknowledgedDuplicates(using: connectivity)
            if !bounded { preparePreemptions(using: connectivity, priority: state.priorityIdentity) }
            if let head = state.head, let epoch = state.headEpochID {
                preemptTransfers(using: connectivity, head: head, epochID: epoch, priority: state.priorityIdentity)
                let candidates = state.admissions
                let manifests = candidates.map(\.manifest)
                adoptOutstandingAttempts(using: connectivity, pending: manifests)
                var actual = connectivity.outstandingFileTransfers
                // Normal pause has already sealed the tail. Use that remaining
                // foreground runtime to give the OS a bounded batch before a
                // later wrist lock/charger placement can suspend this process.
                let closedForegroundBatch = !state.captureOpen
                var queued = Set(actual.compactMap { transfer -> UUID? in
                    guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data else { return nil }
                    return try? TransportCodec.decode(SegmentManifest.self, from: data).id
                })
                retryPolicy.recordDisappearedTransfers(outstandingIDs: queued)
                // Older/unknown tasks must actually leave after safe preemption.
                // They never create permission to mix epochs or assume a slot.
                func hasForeignTransfer(_ transfers: [WCSessionFileTransfer]) -> Bool {
                    transfers.contains { transfer in
                        guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data,
                              let manifest = try? TransportCodec.decode(SegmentManifest.self, from: data) else { return true }
                        if manifests.contains(manifest) { return false }
                        return (try? repository.isOwnedFreshTransfer(manifest, priority: state.priorityIdentity)) != true
                    }
                }
                observeBackgroundDecision(.noAdmission, transfers: actual)
                for admission in candidates {
                    refreshPowerBudget()
                    let manifest = admission.manifest
                    let nativeLimit = backgroundPowerPolicy.isCharging || closedForegroundBatch ? 12 : 3
                    let hasForeign = hasForeignTransfer(actual)
                    if hasForeign { observeBackgroundDecision(.foreignNative, foreign: 1) }
                    else if actual.count >= nativeLimit { observeBackgroundDecision(.nativeOccupied, foreign: 0) }
                    else if bounded, lightEnqueuesRemaining <= 0 { observeBackgroundDecision(.enqueueBudget, foreign: 0) }
                    else { observeBackgroundDecision(.noAdmission, foreign: 0) }
                    guard !hasForeign, actual.count < nativeLimit,
                          (!bounded || lightEnqueuesRemaining > 0),
                          bounded ? boundedExecutionAllowed : maintenanceAllowed else { break }
                    guard !queued.contains(manifest.id) else {
                        observeBackgroundDecision(.nativeOccupied)
                        continue
                    }
                    let isEligible = retryPolicy.isEligible(manifest)
                    guard isEligible else {
                        observeBackgroundDecision(.retryBackoff, eligible: 0)
                        continue
                    }
                    observeBackgroundDecision(.noAdmission, eligible: 1)
                    let current = try repository.withCurrentFreshAdmission(admission, head: head,
                                                                          priority: state.priorityIdentity) {
                        refreshPowerBudget()
                        let latest = connectivity.outstandingFileTransfers
                        guard !hasForeignTransfer(latest), latest.count < (backgroundPowerPolicy.isCharging || closedForegroundBatch ? 12 : 3),
                              permitsHandoff(manifest, outstanding: latest, closedForegroundBatch: closedForegroundBatch),
                              (!bounded || lightEnqueuesRemaining > 0),
                              bounded ? boundedExecutionAllowed : maintenanceAllowed else { return }
                        let now = Date()
                        let attemptID = UUID().uuidString
                        let transfer = connectivity.transferFile(repository.audioURL(for: manifest), metadata: [
                            TransportCodec.manifestKey: try TransportCodec.encode(manifest),
                            Self.enqueuedAtKey: now.timeIntervalSince1970, Self.attemptIDKey: attemptID
                        ])
                        noteEnqueuedProgress(transfer)
                        backgroundSyncDiagnostics.enqueued(manifest, generation: activeBoundedGeneration)
                backlogEvidence.recordEnqueued(manifest, context: backlogEvidenceContext())
                        accountEnqueuedTransfer(bounded: bounded)
                        retryPolicy.noteEnqueued(manifest, attemptID: attemptID, at: now)
                        record(kind: "file_transfer_enqueued",
                               detail: "id=\(manifest.id.uuidString) sequence=\(manifest.sequence) bytes=\(manifest.byteCount) enqueuedAt=\(now.timeIntervalSince1970) attempt=\(attemptID) freshFIFO=true window=\(nativeLimit) boundedBackground=\(bounded)")
                    }
                    // A concurrent explicit resume/ACK can revoke this window.
                    if !current { requestSynchronization(); break }
                    actual = connectivity.outstandingFileTransfers
                    backgroundSyncDiagnostics.nativeQueue(actual)
                    queued = Set(actual.compactMap { transfer -> UUID? in
                        guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data else { return nil }
                        return try? TransportCodec.decode(SegmentManifest.self, from: data).id
                    })
                }
                scheduleRetryWake(pending: manifests, queuedIDs: queued)
            } else {
                if lightCandidateChecksRemaining <= 0 { observeBackgroundDecision(.candidateBudget) }
                else if state.unresolvedOpenCount > 0 || state.captureOpen { observeBackgroundDecision(.openTail) }
                // The producer can be momentarily empty between minute seals.
                // A bounded ACK prefix can also need another future opportunity.
                scheduleBoundedRetryWake()
            }
            if !bounded { recordQueue(using: connectivity, pendingCount: state.remainingCount, trigger: .automatic) }
            return true
        } catch {
            observeBackgroundDecision(.freshReadFailed)
            if !bounded { publishApplicationSnapshot(using: connectivity) }
            reportSyncIssue("新录音发送顺序待恢复，录音文件已保留。")
            requestPhoneReceipts(using: connectivity,
                plan: receiptRequestPlan(using: connectivity, freshHead: nil, hasPendingSegments: true))
            recoverBackgroundRefreshAfterReadFailure()
            scheduleBoundedRetryWake()
            return true
        }
    }

    private func readFreshTransferSnapshot(bounded: Bool) throws -> FreshTransferQueueSnapshot {
        sealedBacklogHandoff = try repository.hasClosedFreshBacklog()
        refreshPowerBudget()
        var checkedAttempts = 0
        defer {
            // A failed candidate still consumed this opportunity. A WK arrival
            // during full maintenance shares the same counter, including when
            // the candidate read throws before a snapshot can be returned.
            let enteredBackground = !bounded && hasBackgroundTasks
            if enteredBackground { consumeBackgroundBudgetReset() }
            if bounded || enteredBackground {
                lightCandidateChecksRemaining = max(0, lightCandidateChecksRemaining - checkedAttempts)
                lightCandidatesChecked += checkedAttempts
            }
        }
        return try repository.freshTransferSnapshot(
            acknowledgementLimit: bounded ? lightCandidateChecksRemaining : 64,
            maximumAdmissions: backgroundPowerPolicy.isCharging ? 12 : 3,
            closedCaptureMaximumAdmissions: 12,
            while: { bounded ? self.boundedExecutionAllowed : self.maintenanceAllowed },
            onCandidateCheck: { checkedAttempts += 1 })
    }

    /// Pre-register bounded work while runtime actually exists. Native queued
    /// files remain system-owned after suspension; accepting one proves neither
    /// delivery nor a phone ACK. This is metadata admission, never an audio audit.
    private func permitsHandoff(_ manifest: SegmentManifest,
                                         outstanding: [WCSessionFileTransfer],
                                         closedForegroundBatch: Bool = false) -> Bool {
        guard let refusal = handoffRefusal(manifest, outstanding: outstanding,
                closedForegroundBatch: closedForegroundBatch) else { return true }
        observeHandoffRefusal(refusal, skipped: false)
        return false
    }

    private struct HandoffRefusal {
        let reason: String
        let stopsPass: Bool
    }

    private func observeHandoffRefusal(_ refusal: HandoffRefusal, skipped: Bool) {
        handoffLastRefusal = refusal.reason
        if skipped { handoffSkippedCandidates += 1 }
        backgroundSyncDiagnostics.handoffRefused(reason: refusal.reason, skipped: skipped)
        let reason: WatchTransferRefusalDiagnostic.Reason
        switch refusal.reason {
        case "deadline": reason = .deadline
        case "nativeCount": reason = .cap
        case "queuedBytes", "unknownQueuedBytes": reason = .byteLimit
        case "capacityUnknown", "capacityReserve", "candidateCapacity": reason = .capacityLimit
        case "power_or_owner_changed": reason = .noOwner
        default: reason = .metadataUnavailable
        }
        recordTransferRefusal(reason)
    }

    private func handoffRefusal(_ manifest: SegmentManifest,
                                       outstanding: [WCSessionFileTransfer],
                                       closedForegroundBatch: Bool = false) -> HandoffRefusal? {
        if handoffStartedAt == nil { handoffStartedAt = handoffClock() }
        guard let handoffStartedAt else { return HandoffRefusal(reason: "deadline", stopsPass: true) }
        let expanded = backgroundPowerPolicy.isCharging || closedForegroundBatch
        let policy = WatchTransferHandoffPolicy(isCharging: backgroundPowerPolicy.isCharging,
            sealedBacklog: closedForegroundBatch)
        let sizes: [Int64?] = outstanding.map { transfer in
            guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data,
                  let queued = try? TransportCodec.decode(SegmentManifest.self, from: data) else { return nil }
            return queued.byteCount
        }
        func refusal(_ decision: WatchTransferHandoffPolicy.Decision) -> HandoffRefusal? {
            decision == .allowed ? nil : HandoffRefusal(reason: decision.rawValue, stopsPass: decision.stopsPass)
        }
        if let rejected = refusal(policy.decision(candidateBytes: manifest.byteCount, outstandingBytes: sizes,
                elapsed: handoffClock() - handoffStartedAt, availableCapacity: availableCapacityProvider())) {
            return rejected
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: repository.audioURL(for: manifest).path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == manifest.byteCount else {
            return HandoffRefusal(reason: "source_metadata_unavailable", stopsPass: false)
        }
        // Metadata calls can span expiration, unplugging, or the soft deadline.
        let finalCapacity = availableCapacityProvider()
        refreshPowerBudget()
        guard !expanded || backgroundPowerPolicy.isCharging || (closedForegroundBatch && (maintenanceAllowed || boundedExecutionAllowed)) else {
            return HandoffRefusal(reason: "power_or_owner_changed", stopsPass: true)
        }
        return refusal(policy.decision(candidateBytes: manifest.byteCount, outstandingBytes: sizes,
            elapsed: handoffClock() - handoffStartedAt, availableCapacity: finalCapacity))
    }

    private func accountEnqueuedTransfer(bounded: Bool) {
        // A WK grant can register during the native enqueue call, after the
        // full-maintenance guard passed. Charge that overlap to its shared budget.
        let enteredBackground = !bounded && hasBackgroundTasks
        if enteredBackground { consumeBackgroundBudgetReset() }
        if bounded || enteredBackground {
            lightEnqueuesRemaining = max(0, lightEnqueuesRemaining - 1)
            lightEnqueued += 1
            backgroundSyncDiagnostics.consumption(candidateRemaining: lightCandidateChecksRemaining,
                enqueueRemaining: lightEnqueuesRemaining)
        }
    }

    private func preemptionSourceSignature(_ manifest: SegmentManifest) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: repository.audioURL(for: manifest).path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value == manifest.byteCount,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw RepositoryError.missingAudio
        }
        return "\(device):\(inode):\(size):\(modified.timeIntervalSince1970)"
    }

    /// Historical sources may be prepared before the first seal. An older fresh
    /// source requires an already durable current priority head. Hashing remains
    /// confined to full maintenance and observes its revocable execution gate.
    private func preparePreemptions(using connectivity: WCSession, priority: FreshTransferPriorityIdentity?) {
        let transfers = WatchPreemptionScan.candidates(connectivity.outstandingFileTransfers)
        let keys = Set(transfers.compactMap(persistentAttemptID))
        verifiedPreemptionSources = verifiedPreemptionSources.filter {
            keys.contains($0.key) && ($0.value.priorityIdentity == nil || $0.value.priorityIdentity == priority)
        }
        requestedPreemptionAttempts.formIntersection(keys)
        guard maintenanceAllowed else { return }
        for transfer in transfers {
            guard maintenanceAllowed, let key = persistentAttemptID(transfer),
                  !stalledCancellationKeys.contains(recoveryKey(transfer) ?? ""),
                  !requestedPreemptionAttempts.contains(key),
                  verifiedPreemptionSources[key] == nil,
                  let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data,
                  let manifest = try? TransportCodec.decode(SegmentManifest.self, from: data) else { continue }
            do {
                guard try canPreparePreemption(manifest, priority: priority) else { continue }
                let before = try preemptionSourceSignature(manifest)
                let source = try RecordingRepository.fingerprint(of: repository.audioURL(for: manifest),
                                                                 while: { self.maintenanceAllowed })
                guard maintenanceAllowed, source.byteCount == manifest.byteCount,
                      source.sha256 == manifest.sha256, try preemptionSourceSignature(manifest) == before,
                      try canPreparePreemption(manifest, priority: priority) else { continue }
                verifiedPreemptionSources[key] = VerifiedPreemptionSource(manifest: manifest,
                    fileSignature: before, priorityIdentity: priority)
            } catch {
                if maintenanceAllowed { reportSyncIssue("较早发送任务暂未让位，原始录音保留等待完整性核对。") }
            }
        }
    }

    private func canPreparePreemption(_ manifest: SegmentManifest,
                                      priority: FreshTransferPriorityIdentity?) throws -> Bool {
        guard try repository.pendingSegment(id: manifest.id) == manifest else { return false }
        if let priority {
            return try repository.canYieldToPriority(manifest, priority: priority)
        }
        return try !repository.isProtectedFreshSegment(manifest)
    }

    private func preemptTransfers(using connectivity: WCSession, head: SegmentManifest, epochID: UUID,
                                 priority: FreshTransferPriorityIdentity?) {
        if let priority, priority.headID != head.id || priority.epochID != epochID { return }
        for transfer in WatchPreemptionScan.candidates(connectivity.outstandingFileTransfers) {
            guard let key = persistentAttemptID(transfer), !requestedPreemptionAttempts.contains(key),
                  !stalledCancellationKeys.contains(recoveryKey(transfer) ?? ""),
                  let verified = verifiedPreemptionSources[key],
                  verified.priorityIdentity == nil || verified.priorityIdentity == priority else { continue }
            do {
                // beginPriorityCapture cannot change epochs between the final
                // identity check and cancellation. No hashing occurs under this
                // short repository lock or in a bounded background opportunity.
                _ = try repository.withCurrentFreshHead(head, priority: priority) {
                    guard try canPreparePreemption(verified.manifest, priority: priority),
                          try preemptionSourceSignature(verified.manifest) == verified.fileSignature,
                          let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data,
                          try TransportCodec.decode(SegmentManifest.self, from: data) == verified.manifest else { return }
                    let intent = FileTransferPreemptionIntent(manifest: verified.manifest, attemptID: key,
                        epochID: epochID, freshHeadID: head.id)
                    try repository.persistPreemptionIntent(intent)
                    // Persistent intent alone never replaces current scheduling
                    // or source evidence, including after a failed prior attempt.
                    guard try repository.withCurrentFreshHead(head, priority: priority, {}),
                          try canPreparePreemption(verified.manifest, priority: priority),
                          try preemptionSourceSignature(verified.manifest) == verified.fileSignature else { return }
                    requestedPreemptionAttempts.insert(key)
                    transfer.cancel()
                    record(kind: "file_transfer_priority_yield_requested",
                           detail: "id=\(verified.manifest.id.uuidString) attempt=\(key) head=\(head.id.uuidString) epoch=\(epochID.uuidString) durableIntent=true")
                    // Cancellation remains system-owned; count the real queue until removal.
                    work.asyncAfter(deadline: .now() + 1) { [weak self] in self?.requestSynchronization() }
                }
            } catch { reportSyncIssue("较早任务让位状态保存失败，保留现有发送任务和原始音频。") }
        }
    }

    /// Called only after observing durable fresh work, a valid pending manifest,
    /// a system-owned file task, or an unfinished bounded cache recheck. A timer alone is never backlog evidence.
    /// Keep the same preferred date across callbacks/relaunches: replacing the
    /// single WK request with now+interval each minute could postpone it forever.
    private func requestBackgroundRefreshIfNeeded(now: Date = Date()) {
        guard transferStateLoaded, boundedExecutionAllowed, let request = onBackgroundRefreshRequested else { return }
        if let retryAfter = backgroundRefreshRetryAfter, retryAfter > now { return }
        let confirmedHere = backgroundRefreshPreferredDate.map {
            backgroundRefreshConfirmedDate == $0 || backgroundRefreshRequestInFlight == $0
        } ?? false
        refreshPowerBudget()
        let next = WatchBackgroundTransferPolicy.preferredRefreshDate(existing: backgroundRefreshPreferredDate,
            confirmedDuringThisProcess: confirmedHere, sealedBacklog: sealedBacklogHandoff,
            isCharging: backgroundPowerPolicy.isCharging, now: now)
        if backgroundRefreshPreferredDate != next {
            // TransportCodec persists integer milliseconds. Use that same value
            // for the live callback so reloaded intent has exact Date identity.
            do {
                try TransportCodec.encode(BackgroundRefreshIntent(schemaVersion: 1, preferredDate: next, candidateSweep: candidateSweep))
                    .write(to: backgroundRefreshStateURL, options: Self.transferStateWritingOptions)
                backgroundRefreshPreferredDate = next
                backgroundRefreshRequestInFlight = nil
                backgroundRefreshConfirmedDate = nil
            } catch {
                record(kind: "watch.background_refresh_state_failed", detail: "operation=persist_intent retained=true")
                backgroundRefreshRetryAfter = now.addingTimeInterval(60)
                scheduleBoundedRetryWake()
                return
            }
        }
        guard let date = backgroundRefreshPreferredDate,
              backgroundRefreshRequestInFlight != date, backgroundRefreshConfirmedDate != date else { return }
        backgroundRefreshRequestInFlight = date
        record(kind: "watch.background_refresh_requested", detail: "preferred_delay_seconds=\(max(0, Int(date.timeIntervalSince(now))))")
        request(date)
    }

    private func recoverBackgroundRefreshAfterReadFailure() {
        // A consumed persisted intent came from previously observed source
        // work. A temporarily unreadable index must not erase that sole wake
        // opportunity. A successful bounded read (including empty) clears this
        // hint; it is never used as proof of an audio receipt or completeness.
        guard backgroundRefreshRecoveryNeeded else { return }
        backgroundRefreshRecoveryNeeded = false
        requestBackgroundRefreshIfNeeded()
    }

    private func requestStateRecoveryRefreshIfNeeded() {
        guard boundedExecutionAllowed, stateRecoveryRefreshDate == nil,
              let request = onBackgroundRefreshRequested else { return }
        let now = Date()
        if let retryAfter = stateRecoveryRefreshRetryAfter, retryAfter > now { return }
        let date = WatchBackgroundTransferPolicy.preferredRefreshDate(existing: nil, now: now)
        stateRecoveryRefreshDate = date
        stateRecoveryRefreshInFlight = true
        // A successful schedule is only a request, never guaranteed runtime.
        // No inaccessible retry/order/continuation file is changed here.
        request(date)
    }

    func backgroundRefreshSchedulingStarted(preferredDate: Date) {
        backgroundSyncDiagnostics.refreshRequested(preferredDate: preferredDate)
    }

    func backgroundRefreshSchedulingCompleted(preferredDate: Date, succeeded: Bool,
                                              errorDomain: String? = nil, errorCode: Int? = nil) {
        backgroundSyncDiagnostics.refreshCompleted(preferredDate: preferredDate, succeeded: succeeded,
            errorDomain: errorDomain, errorCode: errorCode)
        work.async { [self] in
            if stateRecoveryRefreshDate == preferredDate {
                stateRecoveryRefreshInFlight = false
                if !succeeded {
                    stateRecoveryRefreshDate = nil
                    stateRecoveryRefreshRetryAfter = Date().addingTimeInterval(60)
                    scheduleBoundedRetryWake()
                }
                record(kind: "watch.background_state_recovery_schedule_result", detail: "accepted=\(succeeded)")
                requestBackgroundCompletionCheck()
                return
            }
            guard backgroundRefreshPreferredDate == preferredDate,
                  backgroundRefreshRequestInFlight == preferredDate else { return }
            backgroundRefreshRequestInFlight = nil
            if succeeded {
                backgroundRefreshConfirmedDate = preferredDate
                backgroundRefreshRetryAfter = nil
            } else {
                backgroundRefreshConfirmedDate = nil
                backgroundRefreshRetryAfter = Date().addingTimeInterval(60)
                scheduleBoundedRetryWake()
            }
            record(kind: "watch.background_refresh_schedule_result", detail: "accepted=\(succeeded)")
            requestBackgroundCompletionCheck()
        }
    }

    private func clearBackgroundRefreshIntent() {
        guard backgroundRefreshPreferredDate != nil || backgroundRefreshRequestInFlight != nil
            || backgroundRefreshRecoveryNeeded || candidateSweep != nil else { return }
        candidateSweep = nil
        do {
            try TransportCodec.encode(BackgroundRefreshIntent(schemaVersion: 1, preferredDate: nil))
                .write(to: backgroundRefreshStateURL, options: Self.transferStateWritingOptions)
        } catch {
            // Existing source/ACK state stays authoritative. A later launch can
            // issue one extra harmless wake, never infer an ACK from this hint.
            record(kind: "watch.background_refresh_state_failed", detail: "operation=clear_intent retained=true")
        }
        backgroundRefreshPreferredDate = nil
        backgroundRefreshRequestInFlight = nil
        backgroundRefreshConfirmedDate = nil
        backgroundRefreshRetryAfter = nil
    }

    private func scheduleBoundedRetryWake() {
        let next = Date().addingTimeInterval(60)
        if let scheduled = retryWakeAt, scheduled > Date(), scheduled <= next { return }
        retryWake?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWake = nil
            self.retryWakeAt = nil
            self.requestSynchronization()
        }
        retryWake = item
        retryWakeAt = next
        work.asyncAfter(deadline: .now() + 60, execute: item)
    }

    private func reportSyncIssue(_ message: String) {
        syncIssue = message
        if maintenanceAllowed { onIssue?(message) }
    }

    private func publishSyncFeedback(pendingSnapshot: [SegmentManifest]? = nil) {
        guard maintenanceAllowed else { return }
        do {
            var pending: [SegmentManifest]
            if let pendingSnapshot { pending = pendingSnapshot }
            else {
                guard let values = try repository.pendingSegments(while: { self.maintenanceAllowed }) else { return }
                pending = values
            }
            var hasSealedSegments = !pending.isEmpty
            var allReceiptsVerified = false
            if pending.isEmpty {
                guard let manifests = try repository.manifests(while: { self.maintenanceAllowed }) else { return }
                hasSealedSegments = !manifests.isEmpty
                // A visible ACK file can survive a prior synchronization error.
                // Re-establish durability before presenting a completed state.
                allReceiptsVerified = true
                for manifest in manifests {
                    guard maintenanceAllowed else { return }
                    if try !repository.hasDurableAcknowledgement(for: manifest) {
                        allReceiptsVerified = false
                        break
                    }
                }
                // The recorder may have sealed another segment during verification.
                guard let values = try repository.pendingSegments(while: { self.maintenanceAllowed }) else { return }
                pending = values
                hasSealedSegments = hasSealedSegments || !pending.isEmpty
            }
            let pendingIDs = Set(pending.map(\.id))
            deliveredPendingIDs.formIntersection(pendingIDs)
            let transfers = connectivity?.outstandingFileTransfers.filter { transfer in
                guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data,
                      let manifest = try? TransportCodec.decode(SegmentManifest.self, from: data) else { return false }
                return pending.contains(manifest)
            } ?? []
            let queuedIDs = Set(transfers.compactMap { transfer -> UUID? in
                guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data else { return nil }
                return try? TransportCodec.decode(SegmentManifest.self, from: data).id
            })
            // Presentation must not mutate the persisted retry policy (including
            // its wall-clock correction) or move a retry deadline.
            var observedRetryPolicy = retryPolicy
            let retryAt = observedRetryPolicy.nextRetryDate(pending: pending, excludingIDs: queuedIDs)
            syncFeedback.observe(pendingCount: pending.count, queuedCount: transfers.count,
                                 transferringCount: transfers.filter(\.isTransferring).count,
                                 awaitingConfirmationCount: deliveredPendingIDs.count,
                                 connectionReady: connectivity?.activationState == .activated,
                                 reachable: connectivity?.isReachable ?? false,
                                 hasSealedSegments: hasSealedSegments,
                                 allReceiptsVerified: allReceiptsVerified, retryAt: retryAt,
                                 failure: syncIssue)
        } catch {
            syncFeedback.recordFailure("暂时无法核对同步结果：\(error.localizedDescription)")
        }
        if maintenanceAllowed { onSyncFeedback?(syncFeedback) }
    }

    private func persistRetryStateIfNeeded() {
        guard transferStateLoaded, retryPolicy != persistedRetryPolicy else { return }
        do {
            try TransportCodec.encode(retryPolicy).write(to: retryStateURL, options: Self.transferStateWritingOptions)
            persistedRetryPolicy = retryPolicy
            lastRetryPersistenceError = nil
        } catch {
            let detail = Self.describe(error)
            if detail != lastRetryPersistenceError {
                lastRetryPersistenceError = detail
                record(kind: "file_retry_state_save_failed", detail: detail)
                reportSyncIssue("同步等待记录暂未保存；本次等待继续有效，原录音保留。")
            }
        }
    }

    private func persistSchedulingStateIfNeeded() {
        guard transferStateLoaded, schedulingPolicy != persistedSchedulingPolicy else { return }
        do {
            try TransportCodec.encode(schedulingPolicy).write(to: schedulingStateURL, options: Self.transferStateWritingOptions)
            persistedSchedulingPolicy = schedulingPolicy
            lastSchedulingPersistenceError = nil
        } catch {
            let detail = Self.describe(error)
            if detail != lastSchedulingPersistenceError {
                lastSchedulingPersistenceError = detail
                record(kind: "file_scheduling_state_save_failed", detail: detail)
                reportSyncIssue("同步顺序暂未保存；本次轮换继续有效，原录音保留。")
            }
        }
    }

    private func scheduleRetryWake(pending: [SegmentManifest], queuedIDs: Set<UUID>) {
        let now = Date()
        let fileRetry = retryPolicy.nextRetryDate(pending: pending, excludingIDs: queuedIDs, at: now)
        // A queued task can otherwise occupy a slot forever without a callback.
        // This modest in-process check also retries the bounded receipt request.
        let observation = pending.isEmpty ? nil : now.addingTimeInterval(60)
        guard let next = [fileRetry, observation].compactMap({ $0 }).min() else {
            retryWake?.cancel()
            retryWake = nil
            retryWakeAt = nil
            return
        }
        if let scheduled = retryWakeAt, scheduled > now && scheduled <= next { return }
        retryWake?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWake = nil
            self.retryWakeAt = nil
            self.requestSynchronization()
        }
        retryWake = item
        retryWakeAt = next
        // This is an in-process retry, not a guarantee that watchOS will wake us.
        // A later activation/resume also re-evaluates the persisted deadlines.
        work.asyncAfter(deadline: .now() + max(1, next.timeIntervalSince(now)), execute: item)
    }

    /// Reuse the already budgeted fresh snapshot. The fallback inspects at most
    /// three native metadata entries per pass, rotating across the native queue;
    /// it never advances a fresh head or reads historical source/audio files.
    private func receiptRequestPlan(using connectivity: WCSession, freshHead: SegmentManifest?,
                                    hasPendingSegments: Bool) -> ReceiptRequestPlan {
        guard hasPendingSegments else { return .none }
        if let freshHead, let request = try? TargetedReceiptRequest(manifest: freshHead) {
            return .targeted(request)
        }
        let transfers = connectivity.outstandingFileTransfers
        guard !transfers.isEmpty else { return .legacy }
        guard let cursor = loadHistoricalReceiptCursor() else { return .none }
        let start = Int(cursor.nextNativeOffset % UInt64(transfers.count))
        let inspected = min(3, transfers.count)
        for offset in 0..<inspected {
            let index = (start + offset) % transfers.count
            let transfer = transfers[index]
            guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data,
                  let manifest = try? TransportCodec.decode(SegmentManifest.self, from: data),
                  let request = try? TargetedReceiptRequest(manifest: manifest) else { continue }
            return .historical(request, nextNativeOffset: UInt64(index + 1))
        }
        // Preserve the pre-existing small/unknown migration fallback. A large
        // queue with invalid metadata must not trigger whole-history replay just
        // because its first bounded window contains no exact identity.
        if transfers.count <= inspected { return .legacy }
        return .skipHistorical(nextNativeOffset: UInt64((start + inspected) % transfers.count))
    }

    private func loadHistoricalReceiptCursor() -> HistoricalReceiptCursor? {
        if let historicalReceiptCursor { return historicalReceiptCursor }
        do {
            let bytes = try RecordingMetadataAccess.readIfPresent(at: historicalReceiptCursorURL, maximumBytes: 4_096)
            let cursor = try bytes.map { try TransportCodec.decode(HistoricalReceiptCursor.self, from: $0) }
                ?? HistoricalReceiptCursor(schemaVersion: 1, nextNativeOffset: 0)
            guard cursor.schemaVersion == 1 else {
                throw RepositoryError.invalidManifest("历史确认轮换记录版本无效")
            }
            historicalReceiptCursor = cursor
            historicalReceiptCursorBytes = bytes
            lastHistoricalReceiptCursorError = nil
            return cursor
        } catch {
            historicalReceiptCursorFailure(error)
            return nil
        }
    }

    private func persistHistoricalReceiptCursor(nextNativeOffset: UInt64) -> Bool {
        guard let current = historicalReceiptCursor else { return false }
        do {
            // Reject newly inaccessible/invalid objects, or externally changed
            // hints, instead of overwriting them or silently resetting to head.
            let observed = try RecordingMetadataAccess.readIfPresent(at: historicalReceiptCursorURL, maximumBytes: 4_096)
            guard observed == historicalReceiptCursorBytes else {
                historicalReceiptCursor = nil
                throw RepositoryError.invalidManifest("历史确认轮换记录已变化")
            }
            if current.nextNativeOffset == nextNativeOffset { return true }
            let cursor = HistoricalReceiptCursor(schemaVersion: 1, nextNativeOffset: nextNativeOffset)
            let bytes = try TransportCodec.encode(cursor)
            try bytes.write(to: historicalReceiptCursorURL, options: Self.transferStateWritingOptions)
            historicalReceiptCursor = cursor
            historicalReceiptCursorBytes = bytes
            lastHistoricalReceiptCursorError = nil
            return true
        } catch {
            historicalReceiptCursorFailure(error)
            return false
        }
    }

    private func historicalReceiptCursorFailure(_ error: Error) {
        let detail = Self.describe(error)
        guard detail != lastHistoricalReceiptCursorError else { return }
        lastHistoricalReceiptCursorError = detail
        record(kind: "historical_receipt_cursor_failed", detail: detail)
    }

    @discardableResult
    private func requestPhoneReceipts(using connectivity: WCSession, plan: ReceiptRequestPlan,
                                      recoveryKey: String? = nil) -> Bool {
        guard connectivity.activationState == .activated,
              maintenanceAllowed || boundedExecutionAllowed else { return false }
        var request: [String: Any] = [TransportCodec.requestSyncKey: true]
        let scope: String
        switch plan {
        case .none: return false
        case .skipHistorical(let nextNativeOffset):
            // Invalid metadata cannot monopolize the bounded inspection window.
            // This spends no request cooldown and emits no legacy/history query.
            _ = persistHistoricalReceiptCursor(nextNativeOffset: nextNativeOffset)
            return false
        case .legacy: scope = "legacy"
        case .targeted(let target), .historical(let target, _):
            // Build a valid payload before consuming either bounded opportunity.
            guard let data = try? TransportCodec.encode(target) else { return false }
            request[TransportCodec.targetedReceiptRequestKey] = data
            scope = "exact segment=\(target.segmentID.uuidString)"
        }
        let queuedTransfers = connectivity.outstandingUserInfoTransfers
        pruneIssuedReceiptQueries(queued: queuedTransfers)
        let alreadyQueued = queuedTransfers.contains {
            supersededReceiptRequests[ObjectIdentifier($0)] == nil && plan.matchesQueuedRequest($0.userInfo)
        }
        // Native metadata inspection may span expiration and a newer grant.
        // Recheck before consuming either request cooldown or emitting traffic.
        guard maintenanceAllowed || boundedExecutionAllowed else { return false }
        let uptime = receiptRequestUptime()
        var nextPolicy = receiptRequestPolicy
        let queuedCounts = Self.userInfoCounts(queuedTransfers)
        let receiptRoom = WatchUserInfoScheduling.admitsReceiptRequest(
            events: queuedCounts.events, receiptRequests: queuedCounts.receiptRequests, others: queuedCounts.others)
        if !alreadyQueued, !receiptRoom, case .targeted = plan {
            // The per-kind reservation must not leave a new FIFO head behind
            // obsolete legacy/other-head requests. Replace only our small typed
            // receipt packets, never events, mixed payloads, or unknown traffic.
            // Keep the cancelled objects in every native occupancy calculation:
            // only a later actual removal/completion can make room.
            var cancellations = 0
            for transfer in queuedTransfers {
                guard maintenanceAllowed || boundedExecutionAllowed else { return false }
                let identity = ObjectIdentifier(transfer)
                guard cancellations < WatchUserInfoScheduling.maximumPerKind,
                      supersededReceiptRequests[identity] == nil,
                      Self.isReplaceableReceiptRequest(transfer.userInfo),
                      !plan.matchesQueuedRequest(transfer.userInfo) else { continue }
                supersededReceiptRequests[identity] = transfer
                revokeReceiptQuery(transfer)
                transfer.cancel()
                cancellations += 1
            }
            if cancellations > 0 {
                record(kind: "phone_receipt_request_superseded", detail: "count=\(cancellations) native_slots_retained=true")
            }
        }
        let enqueueBackground = receiptRoom && nextPolicy.beginBackgroundRequest(
            hasPendingSegments: true, alreadyQueued: alreadyQueued, uptime: uptime)
        let sendImmediate = nextPolicy.beginImmediateRequest(
            hasPendingSegments: true,
            activated: connectivity.activationState == .activated,
            reachable: connectivity.isReachable, uptime: uptime)
        guard enqueueBackground || sendImmediate else {
            // Preserve the policy's conservative clock-rollback observation.
            // No selection hint changes when neither request can be emitted.
            receiptRequestPolicy = nextPolicy
            if let recoveryKey,
               let background = queuedTransfers.compactMap({ transfer -> ReceiptQueryBackground? in
                   guard plan.matchesQueuedRequest(transfer.userInfo),
                         let query = issuedReceiptQuery(for: transfer), query.canBind(queued: queuedTransfers) else { return nil }
                   return query
               }).first {
                setRecoveryReceiptQuery(RecoveryReceiptQuery(background: background), for: recoveryKey)
            }
            return alreadyQueued
        }
        if case .historical(_, let nextNativeOffset) = plan {
            // A failed hint commit must consume neither request budget nor
            // selection position, so the same exact request can retry later.
            guard persistHistoricalReceiptCursor(nextNativeOffset: nextNativeOffset) else { return false }
        }
        guard maintenanceAllowed || boundedExecutionAllowed else { return false }
        receiptRequestPolicy = nextPolicy
        // The system-owned request survives either app being suspended.
        var background: ReceiptQueryBackground?
        if enqueueBackground {
            let transfer = connectivity.transferUserInfo(request)
            background = registerReceiptQuery(transfer)
        } else {
            background = queuedTransfers.compactMap { transfer -> ReceiptQueryBackground? in
                guard plan.matchesQueuedRequest(transfer.userInfo),
                      let query = issuedReceiptQuery(for: transfer), query.canBind(queued: queuedTransfers) else { return nil }
                return query
            }.first
        }
        let recoveryQuery = recoveryKey.map { key in
            let query = RecoveryReceiptQuery(background: background)
            setRecoveryReceiptQuery(query, for: key)
            return query
        }
        // An active Watch can also give iOS a background delivery opportunity.
        // A background request still awaiting delivery must not block this path.
        // Its reply is only a transport reply, never a durable SegmentReceipt.
        if sendImmediate {
            let reachableAtAttempt = connectivity.isReachable
            record(kind: "phone_receipt_request_immediate_attempt",
                   detail: "reachableAtAttempt=\(reachableAtAttempt) activated=true pending=true")
            connectivity.sendMessage(request, replyHandler: { [weak self] _ in
                recoveryQuery?.immediateFinished(succeeded: true)
                self?.work.async { [weak self] in
                    self?.record(kind: "phone_receipt_request_immediate_reply",
                                 detail: "reachableAtAttempt=\(reachableAtAttempt) transport_only=true")
                }
            }) { [weak self] error in
                recoveryQuery?.immediateFinished(succeeded: false)
                let detail = Self.describe(error)
                self?.work.async { [weak self] in
                    self?.record(kind: "phone_receipt_request_immediate_failed",
                                 detail: "reachableAtAttempt=\(reachableAtAttempt) \(detail)")
                }
            }
        }
        record(kind: "phone_receipt_request_enqueued",
               detail: "scope=\(scope) background_enqueued=\(enqueueBackground) background_outstanding=\(alreadyQueued) immediate=\(sendImmediate)")
        return true
    }

    private func issuedReceiptQuery(for transfer: WCSessionUserInfoTransfer) -> ReceiptQueryBackground? {
        recoveryQueryLock.lock(); defer { recoveryQueryLock.unlock() }
        return issuedReceiptQueries[ObjectIdentifier(transfer)]
    }

    private func registerReceiptQuery(_ transfer: WCSessionUserInfoTransfer) -> ReceiptQueryBackground? {
        recoveryQueryLock.lock(); defer { recoveryQueryLock.unlock() }
        return receiptQueryLocked(transfer)
    }

    private func finishReceiptQuery(_ transfer: WCSessionUserInfoTransfer, succeeded: Bool) {
        recoveryQueryLock.lock(); defer { recoveryQueryLock.unlock() }
        // A delegate callback may beat transferUserInfo's return. Registration
        // must reuse this terminal holder rather than resurrect a failed query.
        receiptQueryLocked(transfer)?.finished(succeeded: succeeded)
        if !succeeded {
            for query in recoveryReceiptQueries.values where query.background?.transfer === transfer { query.revoke() }
        }
    }

    private func revokeReceiptQuery(_ transfer: WCSessionUserInfoTransfer) {
        recoveryQueryLock.lock(); defer { recoveryQueryLock.unlock() }
        issuedReceiptQueries[ObjectIdentifier(transfer)]?.revoke()
        for query in recoveryReceiptQueries.values where query.background?.transfer === transfer { query.revoke() }
    }

    /// Caller holds only the registry lock; no native getter or transport call.
    private func receiptQueryLocked(_ transfer: WCSessionUserInfoTransfer) -> ReceiptQueryBackground? {
        let identity = ObjectIdentifier(transfer)
        if let existing = issuedReceiptQueries[identity] { return existing }
        guard !receiptQueryRegistrationDisabled, issuedReceiptQueries.count < 128 else {
            // Stop granting new background proof if pathological callbacks
            // exhaust bookkeeping. An unrecorded completion cannot be revived
            // by a later registration after pruning; exact replies still work.
            receiptQueryRegistrationDisabled = true
            return nil
        }
        let query = ReceiptQueryBackground(transfer)
        issuedReceiptQueries[identity] = query
        return query
    }

    private func pruneIssuedReceiptQueries(queued: [WCSessionUserInfoTransfer]) {
        let identities = Set(queued.map(ObjectIdentifier.init))
        recoveryQueryLock.lock(); defer { recoveryQueryLock.unlock() }
        // Active recovery proofs retain completed query evidence independently.
        let recovering = Set(recoveryReceiptQueries.values.compactMap { $0.background.map { ObjectIdentifier($0.transfer) } })
        issuedReceiptQueries = issuedReceiptQueries.filter { identities.contains($0.key) || recovering.contains($0.key) }
    }

    private func setRecoveryReceiptQuery(_ query: RecoveryReceiptQuery?, for key: String) {
        recoveryQueryLock.lock()
        let old = recoveryReceiptQueries[key]
        recoveryReceiptQueries[key] = query
        recoveryQueryLock.unlock()
        old?.revoke()
    }

    private func recoveryReceiptQuery(for key: String) -> RecoveryReceiptQuery? {
        recoveryQueryLock.lock(); defer { recoveryQueryLock.unlock() }
        return recoveryReceiptQueries[key]
    }

    private func hasLiveRecoveryQuery(key: String, using connectivity: WCSession) -> Bool {
        // WC getters can invoke callbacks. Never hold the map lock across them.
        let queued = connectivity.outstandingUserInfoTransfers
        guard let query = recoveryReceiptQuery(for: key), query.isValid(queued: queued) else { return false }
        return recoveryReceiptQuery(for: key) === query
    }

    private func clearRecoveryReceiptQueries() {
        recoveryQueryLock.lock()
        let old = Array(recoveryReceiptQueries.values)
        recoveryReceiptQueries.removeAll()
        recoveryQueryLock.unlock()
        old.forEach { $0.revoke() }
    }

    // The kernel boot timestamp is stable across process restarts. Missing or
    // changed continuity evidence makes the policy restart its observation window.
    private static func bootContinuityID() -> String? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0,
              size == MemoryLayout<timeval>.size else { return nil }
        return "\(boot.tv_sec):\(boot.tv_usec)"
    }

    private func loadRecoveryStateIfNeeded() -> Bool {
        if recoveryStateLoaded { return true }
        do {
            let bytes = try RecordingMetadataAccess.readIfPresent(at: recoveryStateURL, maximumBytes: 262_144)
            outstandingPolicy = try bytes.map { try TransportCodec.decode(OutstandingFileTransferPolicy.self, from: $0) }
                ?? OutstandingFileTransferPolicy(minimumIdle: recoveryIdleInterval)
            outstandingPolicy.reconfigure(minimumIdle: recoveryIdleInterval)
            outstandingPolicy.invalidateReceiptRequests()
            clearRecoveryReceiptQueries()
            recoveryStateBytes = bytes
            recoveryStateLoaded = true
            lastRecoveryStateError = nil
            return true
        } catch {
            recoveryStateFailure(error)
            return false
        }
    }

    @discardableResult
    private func persistRecoveryState() -> Bool {
        guard recoveryStateLoaded else { return false }
        do {
            let bytes = try TransportCodec.encode(outstandingPolicy)
            guard bytes.count <= 262_144 else { throw RepositoryError.persistenceFailure("发送进度观察超出上限") }
            // Never overwrite an inaccessible, corrupt, or externally replaced
            // file. This optional watchdog can stop without blocking safe delivery.
            let observed = try RecordingMetadataAccess.readIfPresent(at: recoveryStateURL, maximumBytes: 262_144)
            guard observed == recoveryStateBytes else {
                recoveryStateLoaded = false
                throw RepositoryError.persistenceFailure("发送进度观察已变化")
            }
            if bytes != recoveryStateBytes {
                try bytes.write(to: recoveryStateURL, options: Self.transferStateWritingOptions)
                recoveryStateBytes = bytes
            }
            lastRecoveryStateError = nil
            return true
        } catch {
            recoveryStateFailure(error)
            return false
        }
    }

    private func recoveryStateFailure(_ error: Error) {
        let detail = Self.describe(error)
        guard detail != lastRecoveryStateError else { return }
        lastRecoveryStateError = detail
        record(kind: "file_transfer_progress_state_failed", detail: detail)
    }

    private func recoveryKey(_ transfer: WCSessionFileTransfer) -> String? {
        guard let attempt = persistentAttemptID(transfer), !attempt.isEmpty, attempt.utf8.count <= 256,
              let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data,
              let manifest = try? TransportCodec.decode(SegmentManifest.self, from: data),
              let canonical = try? TransportCodec.encode(manifest) else { return nil }
        // Metadata only: a reused attempt ID cannot inherit another source's
        // progress, ACK query, or cancellation suppression.
        let identity = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        return "\(attempt):\(identity)"
    }

    private func recoverySourceSignature(_ manifest: SegmentManifest) throws -> String {
        var value = stat()
        let path = repository.audioURL(for: manifest).path
        guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_size == manifest.byteCount else { throw RepositoryError.missingAudio }
        return "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }

    private func noteEnqueuedProgress(_ transfer: WCSessionFileTransfer) {
        recordTransferAttempt(transfer, phase: .enqueue, outcome: .enqueued)
        guard loadRecoveryStateIfNeeded(), let key = recoveryKey(transfer) else { return }
        let time = recoveryClock()
        let progress = transfer.progress
        _ = outstandingPolicy.observe(key: key, enqueuedAt: nil,
            completed: progress.completedUnitCount, total: progress.totalUnitCount,
            isTransferring: transfer.isTransferring, now: time.date, uptime: time.uptime,
            continuityID: recoveryContinuityID)
        _ = persistRecoveryState()
    }

    private func recoverStalledTransfer(using connectivity: WCSession) {
        guard maintenanceAllowed || boundedExecutionAllowed, loadRecoveryStateIfNeeded() else { return }
        let transfers = connectivity.outstandingFileTransfers
        for transfer in transfers.prefix(64) { recordTransferAttempt(transfer, phase: .progress, outcome: .observed) }
        let keys = Set(transfers.compactMap(recoveryKey))
        outstandingPolicy.retainOutstanding(keys: keys)
        recoveryQueryLock.lock()
        let absentKeys = recoveryReceiptQueries.keys.filter { !keys.contains($0) }
        recoveryQueryLock.unlock()
        absentKeys.forEach { setRecoveryReceiptQuery(nil, for: $0) }
        let observedTime = recoveryClock()
        var candidates: [(WCSessionFileTransfer, SegmentManifest, String)] = []
        // Native metadata only, bounded independently of repository history.
        for transfer in transfers.prefix(64) {
            guard maintenanceAllowed || boundedExecutionAllowed,
                  let key = recoveryKey(transfer),
                  let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data,
                  let manifest = try? TransportCodec.decode(SegmentManifest.self, from: data) else { continue }
            let progress = transfer.progress
            let idle = outstandingPolicy.observe(key: key, enqueuedAt: nil,
                completed: progress.completedUnitCount, total: progress.totalUnitCount,
                isTransferring: transfer.isTransferring, now: observedTime.date,
                uptime: observedTime.uptime, continuityID: recoveryContinuityID)
            if idle, !requestedPreemptionAttempts.contains(transferAttemptKey(transfer)) {
                candidates.append((transfer, manifest, key))
            } else {
                // An old successful query cannot survive a progress or clock
                // reset and authorize cancellation in a later idle window.
                setRecoveryReceiptQuery(nil, for: key)
                outstandingPolicy.invalidateReceiptRequest(key: key)
            }
        }
        guard persistRecoveryState(), maintenanceAllowed || boundedExecutionAllowed else { return }
        // A damaged or already-ACKed native task cannot hide a healthy candidate.
        // Only three exact repository lookups and one source hash per pass.
        for (transfer, manifest, key) in candidates.prefix(3) {
            let target: TargetedReceiptRequest
            do {
                // An exact local ACK wins even if the transport callback disappeared.
                // A corrupt/unreadable receipt throws and never authorizes recovery.
                guard try repository.pendingSegment(id: manifest.id) == manifest,
                      let request = try? TargetedReceiptRequest(manifest: manifest) else {
                    outstandingPolicy.deferRecovery(key: key, uptime: observedTime.uptime)
                    setRecoveryReceiptQuery(nil, for: key)
                    _ = persistRecoveryState()
                    continue
                }
                target = request
            } catch {
                // Unknown or corrupt native metadata is isolated before any
                // source read, so it cannot consume the sole recovery action.
                outstandingPolicy.deferRecovery(key: key, uptime: observedTime.uptime)
                setRecoveryReceiptQuery(nil, for: key)
                _ = persistRecoveryState()
                record(kind: "file_stalled_transfer_recovery_deferred",
                       detail: "id=\(manifest.id.uuidString) \(Self.describe(error))")
                continue
            }
            do {
                if !hasLiveRecoveryQuery(key: key, using: connectivity) {
                    outstandingPolicy.invalidateReceiptRequest(key: key)
                    _ = requestPhoneReceipts(using: connectivity, plan: .targeted(target), recoveryKey: key)
                }
                guard hasLiveRecoveryQuery(key: key, using: connectivity) else {
                    _ = persistRecoveryState()
                    return
                }
                // Query creation/native inspection may have blocked since the
                // progress sample. Start grace only after live proof is valid.
                outstandingPolicy.markReceiptRequested(key: key, uptime: recoveryClock().uptime)
                guard persistRecoveryState() else { return }
                if !outstandingPolicy.canRecover(key: key, uptime: observedTime.uptime,
                                                 receiptGrace: recoveryReceiptGrace) {
                    return
                }
                let backgroundGeneration: UInt64?
                if maintenanceAllowed {
                    backgroundGeneration = nil
                } else {
                    // Clear at most one blocked slot per real background grant.
                    // Large legacy files retain the ordinary maintenance path.
                    guard let generation = activeBoundedGeneration,
                          transfers.count >= backgroundPowerPolicy.maximumOutstandingFiles,
                          lastBackgroundStallRecoveryGeneration != generation,
                          hasLiveBackgroundStallRecoveryTask(generation: generation) else { return }
                    guard manifest.byteCount <= Self.backgroundStallRecoveryMaxBytes else { continue }
                    lastBackgroundStallRecoveryGeneration = generation
                    backgroundGeneration = generation
                }
                let deadline = backgroundGeneration.map { _ in handoffClock() + Self.backgroundStallRecoveryTimeLimit }
                let recoveryMayContinue = {
                    if let backgroundGeneration, let deadline {
                        return self.handoffClock() < deadline
                            && self.hasLiveBackgroundStallRecoveryTask(generation: backgroundGeneration)
                    }
                    return self.maintenanceAllowed
                }
                let before = try recoverySourceSignature(manifest)
                guard recoveryMayContinue() else { return }
                let source = try RecordingRepository.fingerprint(of: repository.audioURL(for: manifest),
                                                                 while: recoveryMayContinue)
                guard recoveryMayContinue() else { return }
                guard source.sha256 == manifest.sha256, source.byteCount == manifest.byteCount else {
                    throw RepositoryError.checksumMismatch
                }
                // Serialize the final missing-ACK/source binding with repository
                // mutations; recheck ownership and live native progress after I/O.
                _ = try repository.withPendingTransfer(manifest) {
                    guard recoveryMayContinue(), try recoverySourceSignature(manifest) == before,
                          connectivity.outstandingFileTransfers.contains(where: { $0 === transfer }),
                          recoveryKey(transfer) == key else { return }
                    let latest = transfer.progress
                    let completed = latest.completedUnitCount
                    let total = latest.totalUnitCount
                    let transferring = transfer.isTransferring
                    let time = recoveryClock()
                    guard outstandingPolicy.observe(key: key, enqueuedAt: nil,
                        completed: completed, total: total,
                        isTransferring: transferring, now: time.date, uptime: time.uptime,
                        continuityID: recoveryContinuityID),
                        outstandingPolicy.canRecover(key: key, uptime: time.uptime, receiptGrace: recoveryReceiptGrace),
                        hasLiveRecoveryQuery(key: key, using: connectivity)
                    else {
                        setRecoveryReceiptQuery(nil, for: key)
                        outstandingPolicy.invalidateReceiptRequest(key: key)
                        _ = persistRecoveryState()
                        return
                    }
                    let queued = (transfer.file.metadata?[Self.enqueuedAtKey] as? NSNumber)
                        .map { Date(timeIntervalSince1970: $0.doubleValue) }
                    let prior = outstandingPolicy
                    var didCancel = false
                    // Any failed/throwing final check must undo the unissued intent.
                    // The defer also runs when source metadata becomes inaccessible.
                    defer {
                        if !didCancel { outstandingPolicy = prior; _ = persistRecoveryState() }
                    }
                    outstandingPolicy.markCancellationRequested(key: key)
                    guard persistRecoveryState() else { return }
                    // All potentially blocking writes precede this final check.
                    guard connectivity.outstandingFileTransfers.contains(where: { $0 === transfer }),
                          recoveryKey(transfer) == key,
                          try recoverySourceSignature(manifest) == before,
                          completed == transfer.progress.completedUnitCount,
                          total == transfer.progress.totalUnitCount,
                          transferring == transfer.isTransferring,
                          hasLiveRecoveryQuery(key: key, using: connectivity),
                          recoveryMayContinue() else { return }
                    stalledCancellationKeys.insert(key)
                    transfer.cancel()
                    didCancel = true
                    // Only an issued cancellation is a failed native attempt.
                    // A crash before this write retains the original enqueued
                    // phase and its disappearance grace, never a false failure.
                    adoptOutstandingAttempts(using: connectivity, pending: [manifest])
                    retryPolicy.recordFailure(of: manifest, attemptID: persistentAttemptID(transfer),
                                              enqueuedAt: queued, at: time.date)
                    persistRetryStateIfNeeded()
                    record(kind: "file_stalled_transfer_cancel_requested",
                           detail: "id=\(manifest.id.uuidString) observedIdleSeconds=\(recoveryIdleInterval) exact_ack_queried=true source_verified=true retained=true watchKitTask=\(backgroundGeneration != nil)")
                    work.asyncAfter(deadline: .now() + 1) { [weak self] in self?.requestSynchronization() }
                }
            } catch is CancellationError {
                // A revoked grant or time limit interrupted verification. Keep
                // the exact query and its grace for the next eligible pass.
                return
            } catch {
                outstandingPolicy.deferRecovery(key: key, uptime: observedTime.uptime)
                setRecoveryReceiptQuery(nil, for: key)
                _ = persistRecoveryState()
                record(kind: "file_stalled_transfer_recovery_deferred",
                       detail: "id=\(manifest.id.uuidString) \(Self.describe(error))")
                if maintenanceAllowed {
                    reportSyncIssue("后台传输暂时等待；原录音校验未完成，已保留文件和现有传输。")
                }
            }
            return
        }
    }

    private func adoptOutstandingAttempts(using connectivity: WCSession, pending: [SegmentManifest]) {
        let candidates = connectivity.outstandingFileTransfers.compactMap { transfer -> (SegmentManifest, String, Date?)? in
            guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data,
                  let manifest = try? TransportCodec.decode(SegmentManifest.self, from: data),
                  pending.contains(manifest), let identity = persistentAttemptID(transfer) else { return nil }
            let queued = (transfer.file.metadata?[Self.enqueuedAtKey] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            return (manifest, identity, queued)
        }.sorted {
            if $0.2 != $1.2 { return ($0.2 ?? .distantPast) > ($1.2 ?? .distantPast) }
            return $0.1 > $1.1
        }
        var adoptedIDs = Set<UUID>()
        for (manifest, identity, queued) in candidates where adoptedIDs.insert(manifest.id).inserted {
            retryPolicy.adoptOutstanding(manifest, attemptID: identity, enqueuedAt: queued)
        }
    }

    private func persistentAttemptID(_ transfer: WCSessionFileTransfer) -> String? {
        if let id = transfer.file.metadata?[Self.attemptIDKey] as? String { return id }
        // Pre-upgrade tasks lack an explicit attempt ID, but retain their enqueue
        // timestamp. Unknown legacy identities stay conservative across wrappers.
        if let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data,
           let manifest = try? TransportCodec.decode(SegmentManifest.self, from: data),
           let queued = transfer.file.metadata?[Self.enqueuedAtKey] as? NSNumber {
            return "\(manifest.id.uuidString):\(manifest.sha256):\(queued.doubleValue)"
        }
        return nil
    }

    private func transferAttemptKey(_ transfer: WCSessionFileTransfer) -> String {
        persistentAttemptID(transfer) ?? String(describing: ObjectIdentifier(transfer))
    }

    @discardableResult
    private func cancelAcknowledgedDuplicates(using connectivity: WCSession) -> Bool {
        let fullMaintenance = maintenanceAllowed
        let generation = currentBackgroundGeneration
        let mayContinue = {
            fullMaintenance ? self.maintenanceAllowed
                : (self.boundedExecutionAllowed && self.currentBackgroundGeneration == generation)
        }
        guard mayContinue() else { return false }
        let systemTransfers = connectivity.outstandingFileTransfers
        // Battery background still rotates three durable-ACK checks. Charging
        // inspects the whole queue in one wake so acknowledged tasks can leave
        // before the next enqueue. A cancel request still does not free a slot
        // by itself, and a missing durable ACK never cancels.
        var boundedTransfers = systemTransfers
        let inspectionCount = WatchBackgroundTransferPolicy(isCharging: powerStateProvider(), sealedBacklog: sealedBacklogHandoff)
            .acknowledgedDuplicateInspectionCount(outstanding: systemTransfers.count,
                                                   maintenanceAllowed: fullMaintenance)
        if inspectionCount < systemTransfers.count, !systemTransfers.isEmpty {
            let start = acknowledgementInspectionOffset % systemTransfers.count
            boundedTransfers = (0..<inspectionCount).map { systemTransfers[(start + $0) % systemTransfers.count] }
            acknowledgementInspectionOffset = (start + inspectionCount) % systemTransfers.count
        }
        let transfers = boundedTransfers.compactMap { transfer -> (WCSessionFileTransfer, SegmentManifest)? in
            guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data,
                  let manifest = try? TransportCodec.decode(SegmentManifest.self, from: data) else { return nil }
            return (transfer, manifest)
        }
        let outstandingIDs = Set(systemTransfers.compactMap { transfer -> UUID? in
            guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data else { return nil }
            return (try? TransportCodec.decode(SegmentManifest.self, from: data))?.id
        })
        let outstandingObjects = Set(systemTransfers.map(ObjectIdentifier.init))
        acknowledgedCancellationRequests = acknowledgedCancellationRequests.filter { outstandingObjects.contains($0.key) }
        acknowledgementCheckFailures.formIntersection(outstandingIDs)
        var requestedCancellation = false
        for (transfer, manifest) in transfers {
            guard mayContinue() else { break }
            let identity = ObjectIdentifier(transfer)
            guard acknowledgedCancellationRequests[identity] == nil,
                  hasDurableAcknowledgement(for: manifest) else { continue }
            // Revalidating an ACK can block in file/directory synchronization.
            // Optional duplicate cleanup must stop after expiration or ownership
            // changes; a newer WK grant cannot extend this pass's generation.
            // Exact incoming ACK commits remain independent of this cleanup.
            guard mayContinue() else { break }
            acknowledgedCancellationRequests[identity] = transfer
            cancelledAcknowledgedManifests[manifest.id] = manifest
            retryPolicy.acknowledge(id: manifest.id)
            transfer.cancel()
            requestedCancellation = true
            record(kind: "file_transfer_cancel_requested_after_ack",
                   detail: "id=\(manifest.id.uuidString) sequence=\(manifest.sequence) bytes=\(manifest.byteCount)")
        }
        if requestedCancellation {
            // One bounded recheck covers delayed queue removal even if cancellation
            // produces no callback. This does not cancel any task based on age.
            work.asyncAfter(deadline: .now() + 1) { [weak self] in self?.requestSynchronization() }
        }
        return requestedCancellation
    }

    private func hasDurableAcknowledgement(for manifest: SegmentManifest) -> Bool {
        do {
            return try repository.hasDurableAcknowledgement(for: manifest)
        } catch {
            // A missing/invalid/unreadable proof never authorizes cancellation.
            // Keep the first failure until this ID leaves the queue. Different
            // malformed manifests sharing an ID must not alternate log entries.
            if acknowledgementCheckFailures.insert(manifest.id).inserted {
                record(kind: "file_transfer_ack_check_failed",
                       detail: "id=\(manifest.id.uuidString) sequence=\(manifest.sequence) \(Self.describe(error))")
            }
            return false
        }
    }

    private func recordQueue(using connectivity: WCSession, pendingCount: Int,
                             trigger: TransferDiagnosticsPolicy.Trigger) {
        let transfers = connectivity.outstandingFileTransfers.map { transfer in
            let manifest = (transfer.file.metadata?[TransportCodec.manifestKey] as? Data)
                .flatMap { try? TransportCodec.decode(SegmentManifest.self, from: $0) }
            let id = manifest?.id.uuidString ?? "unknown"
            let enqueuedAt = (transfer.file.metadata?[Self.enqueuedAtKey] as? NSNumber)?.doubleValue
            let progress = transfer.progress
            return (key: "\(id):\(transfer.isTransferring)",
                    detail: "id=\(id) progress=\(progress.completedUnitCount)/\(progress.totalUnitCount) fraction=\(progress.fractionCompleted) isTransferring=\(transfer.isTransferring) enqueuedAt=\(enqueuedAt.map { String($0) } ?? "unknown") attempt=\(persistentAttemptID(transfer) ?? "unknown")")
        }.sorted { $0.key < $1.key }
        let connection = "activation=\(connectivity.activationState.rawValue) reachable=\(connectivity.isReachable) companionInstalled=\(connectivity.isCompanionAppInstalled)"
        let summary = "\(connection) snapshotReady=\(snapshotState.latest != nil) pending=\(pendingCount) outstanding=\(transfers.count)"
        let fingerprint = summary + transfers.map { $0.key }.joined(separator: ",")
        guard diagnostics.shouldLogQueue(fingerprint: fingerprint, trigger: trigger) else { return }
        // Normally there are at most three entries. Bound unexpected legacy queues
        // too, without putting progress/time/user-info counts into the throttle key.
        let limit = 16
        let detail = transfers.prefix(limit).map { $0.detail }.joined(separator: "; ")
        record(kind: "file_transfer_queue",
               detail: "\(summary) trigger=\(trigger) items=[\(detail)] omitted=\(max(0, transfers.count - limit))")
    }

    private static func userInfoCounts(_ transfers: [WCSessionUserInfoTransfer]) -> (events: Int, receiptRequests: Int, others: Int) {
        var events = 0, receiptRequests = 0, others = 0
        for transfer in transfers {
            if transfer.userInfo[TransportCodec.eventsKey] != nil { events += 1 }
            else if transfer.userInfo[TransportCodec.requestSyncKey] as? Bool == true { receiptRequests += 1 }
            else { others += 1 }
        }
        return (events, receiptRequests, others)
    }

    private static func isReplaceableReceiptRequest(_ payload: [String: Any]) -> Bool {
        let allowed = Set([TransportCodec.requestSyncKey, TransportCodec.targetedReceiptRequestKey])
        guard payload[TransportCodec.requestSyncKey] as? Bool == true,
              Set(payload.keys).isSubset(of: allowed) else { return false }
        guard let value = payload[TransportCodec.targetedReceiptRequestKey] else { return true }
        guard let bytes = value as? Data, bytes.count <= 4_096 else { return false }
        return (try? TransportCodec.decode(TargetedReceiptRequest.self, from: bytes)) != nil
    }

    private func synchronizeEvents(using connectivity: WCSession) throws {
        cancelIneligibleQueuedDiagnostics(using: connectivity)
        let transfers = connectivity.outstandingUserInfoTransfers
        let counts = Self.userInfoCounts(transfers)
        // Optional journal/typed packets share one event slot. Leave two
        // physical slots for receipt replacement and unknown existing traffic.
        guard counts.events == 0, WatchUserInfoScheduling.admitsEvent(events: counts.events,
            receiptRequests: counts.receiptRequests, others: counts.others) else { return }
        let queuedIDs = Set(transfers.flatMap { transfer -> [UUID] in
            guard cancelledDiagnosticTransfers[ObjectIdentifier(transfer)] == nil,
                  let events = WatchDiagnosticTransferPolicy.transferableBatch(
                    from: transfer.userInfo[TransportCodec.eventsKey] as? Data) else { return [] }
            return events.map(\.id)
        })
        var batch: [RecordingEvent] = []
        for event in try repository.events(while: { self.maintenanceAllowed }) {
            guard maintenanceAllowed else { return }
            guard WatchDiagnosticTransferPolicy.mayTransfer(event) else { continue }
            // Earlier unbounded diagnostic records remain preserved on disk.
            // Only the bounded snapshot replays these three optional kinds;
            // legacy recording lifecycle evidence retains its existing channel.
            guard WatchTransferDiagnostic.parse(event) == nil else { continue }
            guard !deliveredEventIDs.contains(event.id), !queuedIDs.contains(event.id) else { continue }
            let proposed = batch + [event]
            let data = try TransportCodec.encode(proposed)
            guard data.count <= 40_000 else { break }
            batch = proposed
            if batch.count == 30 { break }
        }
        guard maintenanceAllowed, !batch.isEmpty else { return }
        connectivity.transferUserInfo([TransportCodec.eventsKey: try TransportCodec.encode(batch)])
        legacyEventTurnPending = false
    }

    /// Only packets carrying our event key are candidates. Receipt requests and
    /// other user-info transfers are untouched; cancelled tasks still occupy
    /// their real system slots until WatchConnectivity removes them.
    private func cancelIneligibleQueuedDiagnostics(using connectivity: WCSession) {
        var requestedCancellation = false
        for transfer in connectivity.outstandingUserInfoTransfers {
            guard WatchDiagnosticTransferPolicy.shouldCancelQueuedUserInfo(transfer.userInfo) else { continue }
            let identity = ObjectIdentifier(transfer)
            guard cancelledDiagnosticTransfers[identity] == nil else { continue }
            cancelledDiagnosticTransfers[identity] = transfer
            if let data = transfer.userInfo[TransportCodec.eventsKey] as? Data,
               let events = try? TransportCodec.decode([RecordingEvent].self, from: data) {
                deliveredEventIDs.subtract(events.map(\.id))
                deliveredTransferDiagnosticIDs.subtract(events.map(\.id))
            }
            transfer.cancel()
            requestedCancellation = true
        }
        if requestedCancellation {
            work.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.pendingLegacyEventCompletion = true
                self.requestSynchronization(trigger: .eventDeliveryCompletion)
            }
        }
    }

    /// Replace a queued legacy context without refreshing its observation time
    /// or inventing writer state before the writer has loaded.
    private func sanitizeQueuedApplicationContext(using connectivity: WCSession) {
        var context = connectivity.applicationContext
        guard let value = context[TransportCodec.snapshotKey] else { return }
        do {
            if let data = value as? Data,
               let original = try? TransportCodec.decode(RecorderSnapshot.self, from: data) {
                let safe = WatchDiagnosticTransferPolicy.snapshotForTransfer(original)
                guard safe != original else { return }
                context[TransportCodec.snapshotKey] = try TransportCodec.encode(safe)
            } else {
                context.removeValue(forKey: TransportCodec.snapshotKey)
            }
            try connectivity.updateApplicationContext(context)
        } catch {
            reportSyncIssue("状态暂未送达手机，请稍后重试。")
        }
    }

    private func record(kind: String, detail: String) {
        // Avoid journal growth and fsync work for every ACK/callback in a short
        // system wake. These few task/budget/enqueue records remain auditable.
        guard maintenanceAllowed || kind.hasPrefix("watch.background_")
            || kind == "file_transfer_enqueued" || kind == "transfer_candidate_index_bootstrap"
            || kind == "file_transfer_priority_yield_requested"
            || kind == "file_stalled_transfer_cancel_requested" else { return }
        do {
            try repository.appendEvent(RecordingEvent(kind: kind, detail: detail,
                sessionID: kind == "watch.background_transfer_decision" || kind == "watch.background_handoff_stopped"
                    ? nil : snapshotState.latest?.sessionID))
        } catch { reportSyncIssue("同步日志保存失败：\(error.localizedDescription)") }
    }

    /// An actual WC delegate invocation is new execution time after an expired
    /// WK grant. It cannot extend that old grant or release its task twice.
    private func registerRealCallbackOpportunity() {
        maintenanceLock.lock(); defer { maintenanceLock.unlock() }
        guard backgroundTaskIDs.subtracting(expiredBackgroundTaskIDs).isEmpty else { return }
        backgroundExecutionGeneration &+= 1
        backgroundExecutionExpired = false
        backgroundBudgetNeedsReset = true
    }

    private func registerSnapshotOpportunity(expectedGeneration: UInt64, observedExpired: Bool) {
        maintenanceLock.lock(); defer { maintenanceLock.unlock() }
        // A genuine new final seal arriving after expiry may use its own
        // callback. A signal queued before that expiry cannot cross the fence.
        guard backgroundExecutionExpired == observedExpired, backgroundExecutionGeneration == expectedGeneration,
              backgroundTaskIDs.subtracting(expiredBackgroundTaskIDs).isEmpty else { return }
        backgroundExecutionGeneration &+= 1
        backgroundExecutionExpired = false
        backgroundBudgetNeedsReset = true
    }

    private func diagnosticContext() -> (foreground: Bool?, liveCapture: Bool?, generation: UInt64) {
        maintenanceLock.lock(); defer { maintenanceLock.unlock() }
        return (evidenceForeground, evidenceLiveCapture, backgroundExecutionGeneration)
    }

    private func appendTransferDiagnostic(kind: String, detail: String?) {
        guard let detail else { return }
        let event = RecordingEvent(kind: kind, detail: detail)
        guard WatchDiagnosticTransferPolicy.mayTransfer(event) else { return }
        // A bounded metadata snapshot coalesces repeated waiting observations.
        // Recording lifecycle evidence remains in its existing durable journal.
        transferDiagnosticStore.record(event)
    }

    private func recordTransferAttempt(_ transfer: WCSessionFileTransfer,
                                       phase: WatchTransferAttemptDiagnostic.Phase,
                                       outcome: WatchTransferAttemptDiagnostic.Outcome,
                                       observedAt: Date? = nil) {
        let observedAt = observedAt ?? diagnosticClock()
        // Pure diagnostic completion cannot create a progress echo. A real
        // enqueue during that callback still needs its mandatory attempt record.
        if phase == .progress, !transferDiagnosticObservationAllowed { return }
        guard let data = transfer.file.metadata?[TransportCodec.manifestKey] as? Data,
              let manifest = try? TransportCodec.decode(SegmentManifest.self, from: data),
              let rawAttempt = persistentAttemptID(transfer), let attempt = UUID(uuidString: rawAttempt) else { return }
        let completed = max(0, transfer.progress.completedUnitCount), total = max(0, transfer.progress.totalUnitCount)
        let context = diagnosticContext()
        if phase == .progress, let old = diagnosticProgress[attempt], old.completed == completed, old.total == total,
           old.foreground == context.foreground, old.liveCapture == context.liveCapture,
           old.generation == context.generation, observedAt.timeIntervalSince(old.at) >= 0,
           observedAt.timeIntervalSince(old.at) < 60 { return }
        if phase == .completion { diagnosticProgress.removeValue(forKey: attempt) }
        else if phase == .progress {
            if diagnosticProgress.count >= 128 { diagnosticProgress.removeAll(keepingCapacity: true) }
            diagnosticProgress[attempt] = (completed, total, observedAt, context.foreground, context.liveCapture, context.generation)
        }
        let protection: WatchTransferProtection
        if let attributes = try? FileManager.default.attributesOfItem(atPath: transfer.file.fileURL.path) {
            #if os(watchOS)
            if let value = attributes[.protectionKey] as? FileProtectionType {
                switch value {
                case .complete: protection = .complete
                case .completeUntilFirstUserAuthentication: protection = .untilFirstAuth
                case .completeUnlessOpen: protection = .unlessOpen
                case .none: protection = .none
                default: protection = .unknown
                }
            } else { protection = .unknown }
            #else
            _ = attributes
            protection = .unknown
            #endif
        } else { protection = .unavailable }
        let queued = (transfer.file.metadata?[Self.enqueuedAtKey] as? NSNumber)?.doubleValue
        let enqueuedAtMS = queued.flatMap { value -> Int64? in
            guard value.isFinite, value > 0, value < Double(Int64.max / 1_000) else { return nil }
            return Int64(value * 1_000)
        }
        let value = WatchTransferAttemptDiagnostic(phase: phase, segmentID: manifest.id, attemptID: attempt,
            sourceCategory: repository.diagnosticSourceCategory(for: manifest), protection: protection,
            observedAtMS: Int64(observedAt.timeIntervalSince1970 * 1_000), enqueuedAtMS: enqueuedAtMS,
            generation: context.generation, foreground: context.foreground, liveCapture: context.liveCapture,
            completed: completed, total: total, outcome: outcome,
            processRunID: WatchRuntimeDiagnostics.shared.processRunID)
        appendTransferDiagnostic(kind: "watch.transfer_attempt", detail: value.detail())
    }

    private func recordTransferRefusal(_ reason: WatchTransferRefusalDiagnostic.Reason, nativeCount: Int? = nil) {
        guard transferDiagnosticObservationAllowed else { return }
        let context = diagnosticContext()
        appendTransferDiagnostic(kind: "watch.transfer_refusal", detail: WatchTransferRefusalDiagnostic(
            reason: reason, observedAtMS: Int64(diagnosticClock().timeIntervalSince1970 * 1_000), generation: context.generation,
            foreground: context.foreground, liveCapture: context.liveCapture, nativeCount: nativeCount,
            processRunID: WatchRuntimeDiagnostics.shared.processRunID).detail())
    }

    private func recordTransferOpportunity(_ phase: WatchTransferOpportunityDiagnostic.Phase,
                                           generation: UInt64, observedAt: Date = Date()) {
        let context = diagnosticContext()
        appendTransferDiagnostic(kind: "watch.transfer_opportunity", detail: WatchTransferOpportunityDiagnostic(
            phase: phase, generation: generation, observedAtMS: Int64(observedAt.timeIntervalSince1970 * 1_000),
            foreground: context.foreground, liveCapture: context.liveCapture,
            processRunID: WatchRuntimeDiagnostics.shared.processRunID).detail())
    }

    private func forwardTransferDiagnostics() {
        // Prune completion IDs against the bounded published snapshot. Old
        // in-flight revisions remain immutable and are excluded by native IDs.
        let retainedIDs = Set(transferDiagnosticStore.events(limit: WatchTransferDiagnosticStore.maximumEvents).map(\.id))
        deliveredTransferDiagnosticIDs.formIntersection(retainedIDs)
        guard !retainedIDs.isEmpty, let connectivity,
              connectivity.activationState == .activated, maintenanceAllowed || boundedExecutionAllowed else { return }
        let transfers = connectivity.outstandingUserInfoTransfers
        let counts = Self.userInfoCounts(transfers)
        let queued = Set(transfers.flatMap { transfer in
            WatchDiagnosticTransferPolicy.transferableBatch(from: transfer.userInfo[TransportCodec.eventsKey] as? Data)?.map(\.id) ?? []
        })
        // Keep two physical slots available for exact receipt replacement and
        // unknown pre-existing traffic. Diagnostic delivery cannot starve ACK.
        guard counts.events == 0, counts.receiptRequests + counts.others < 2,
              WatchUserInfoScheduling.admitsEvent(events: counts.events,
            receiptRequests: counts.receiptRequests, others: counts.others) else { return }
        let batch = transferDiagnosticStore.events(excluding: queued.union(deliveredTransferDiagnosticIDs), limit: 30)
        guard !batch.isEmpty, let bytes = try? TransportCodec.encode(batch), bytes.count <= 40_000,
              WatchDiagnosticTransferPolicy.transferableBatch(from: bytes) != nil else { return }
        connectivity.transferUserInfo([TransportCodec.eventsKey: bytes])
        // A diagnostic completion must not scan the journal. Preserve its turn
        // for the next ordinary opportunity, even if that opportunity also
        // creates fresh transfer observations.
        legacyEventTurnPending = true
    }

    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "domain=\(error.domain) code=\(error.code) message=\(error.localizedDescription.prefix(300))"
    }

    private struct Payload: @unchecked Sendable { let dictionary: [String: Any] }
}


/// Local observations only. No repository reference, source enumeration, audio
/// reads, WC requests or extra execution lease is available to this reporter.
private final class WatchBackgroundSyncDiagnostics: @unchecked Sendable {
    enum AcknowledgementStage: String, Codable { case decode, commit }
    private struct AcknowledgementFailure: Codable {
        let observedAtMS: Int64
        let stage: AcknowledgementStage
        let segmentID: UUID?
        let reason: String
        let systemCode: Int?
        let operation: AcknowledgementOperation?
        let foreground: Bool?
        let liveCapture: Bool?

        init(error: Error, stage: AcknowledgementStage, segmentID: UUID?, context: Context,
             operation: AcknowledgementOperation?) {
            observedAtMS = WatchBackgroundSyncDiagnostics.nowMS
            self.stage = stage
            self.segmentID = stage == .commit ? segmentID : nil
            self.operation = stage == .commit ? operation : nil
            foreground = context.foreground
            liveCapture = context.liveCapture
            // Never persist localized descriptions, NSError.userInfo, paths or
            // arbitrary domains. A single replacement sample bounds storage
            // even when an old invalid receipt is repeatedly replayed.
            let osError = error as NSError
            systemCode = stage == .commit && (osError.domain == NSCocoaErrorDomain || osError.domain == NSPOSIXErrorDomain)
                ? osError.code : nil
            if stage == .decode { reason = "decode_failed"; return }
            if let error = error as? RepositoryError {
                switch error {
                case .receiptMismatch: reason = "receipt_mismatch"
                case .invalidManifest: reason = "invalid_manifest"
                case .conflictingSegment: reason = "conflicting_segment"
                case .checksumMismatch: reason = "checksum_mismatch"
                case .missingAudio: reason = "missing_audio"
                case .invalidStagingPath: reason = "invalid_staging_path"
                case .persistenceFailure: reason = "persistence_failure"
                }
            } else if error is DecodingError { reason = "stored_metadata_decode_failed" }
            else {
                let value = error as NSError
                if value.domain == NSCocoaErrorDomain { reason = "cocoa_io" }
                else if value.domain == NSPOSIXErrorDomain { reason = "posix_io" }
                else { reason = "other" }
            }
        }
    }
    private static let maximumBytes = 8_192
    private static let maximumRecentSources = 8
    private static let processRunID = WatchRuntimeDiagnostics.shared.processRunID
    private struct Context: Codable {
        var foreground: Bool?
        var liveCapture: Bool?
        var maintenanceOwnerAllowed: Bool
    }
    private struct Budget: Codable {
        let observedAtMS: Int64
        let externalPower: Bool
        // The bridge's conservative false also includes unknown battery state.
        let powerMeaning = "true_charging_or_full_false_other_or_unknown"
        let candidateLimit: Int
        let enqueueLimit: Int
        var candidateRemaining: Int
        var enqueueRemaining: Int
        let nativeLimit: Int
    }
    private struct NativeQueue: Codable {
        let observedAtMS: Int64
        let count: Int
        let maximumObservedCount: Int
        let sample: [NativeTransfer]
    }
    private struct NativeTransfer: Codable {
        let segmentID: UUID?
        let attemptID: UUID?
        let isTransferring: Bool
        let completed: Int64
        let total: Int64
    }
    private struct RefreshScheduling: Codable {
        var requestedCount = 0
        var acceptedCount = 0
        var failedCount = 0
        var lastRequestedAtMS: Int64?
        var lastRequestedPreferredDateMS: Int64?
        var lastCompletedAtMS: Int64?
        var lastCompletedPreferredDateMS: Int64?
        var lastAccepted: Bool?
        var lastErrorDomain: String?
        var lastErrorCode: Int?
    }
    private struct AutomaticRequests: Codable {
        var acceptedCount = 0
        var replayCount = 0
        var invalidCount = 0
        var staleCount = 0
        var stateUnavailableCount = 0
        var lastObservedAtMS: Int64?
        var lastAcceptedAtMS: Int64?
        var lastChannel: String?
        var lastOutcome: String?
    }
    private struct Admission: Codable {
        var observedAtMS: Int64
        var reason: String
        var candidates: Int?
        var eligible: Int?
        var classifiedAtMS: Int64?
        var alreadyQueued: Int?
        var retryDeferred: Int?
        var lastHandoffRefusal: String?
        var handoffRefusedAtMS: Int64?
        var candidateSkippedCount = 0
    }
    private struct Source: Codable {
        let segmentID: UUID
        let sequence: Int?
        let byteCount: Int64
        let observedAtMS: Int64
        let opportunityNumber: UInt64?
        let foreground: Bool?
        let liveCapture: Bool?
    }
    private struct Opportunity: Codable {
        let number: UInt64
        let startedAtMS: Int64
        var endedAtMS: Int64?
        var endReason: String?
        var connectivityTasksStarted = 0
        var applicationRefreshTasksStarted = 0
        var tasksCompleted = 0
        var tasksExpired = 0
        var liveTaskCount = 0
        var enqueuedCount = 0
        var durableACKCommittedCount = 0
        var durableACKReplayedCount = 0
        var initialBudget: Budget?
        var latestBudget: Budget?
        let contextAtStart: Context
    }
    private struct Report: Codable {
        let schemaVersion = 1
        let role = "watch"
        let counterScope = "observer_epoch"
        let taskCompletionMeaning = "bridge_release_before_WK_completion_callback"
        let maximumReportBytes = WatchBackgroundSyncDiagnostics.maximumBytes
        let includesAudio = false
        let audioReadForReport = false
        let sourceLibraryEnumeratedForReport = false
        let lockState = "not_observed"
        let build: String
        let processRunID = WatchBackgroundSyncDiagnostics.processRunID
        let observerEpochID = UUID()
        var reportSequence: UInt64 = 0
        var generatedAtMS: Int64 = 0
        var uptimeMS: Int64 = 0
        var context: Context
        var currentOpportunity: Opportunity?
        var lastOpportunity: Opportunity?
        var liveTaskCount = 0
        var connectivityTasksStarted = 0
        var applicationRefreshTasksStarted = 0
        var tasksCompleted = 0
        var tasksExpired = 0
        var fileEnqueuedCount = 0
        var durableACKCommittedCount = 0
        var durableACKReplayedCount = 0
        var acknowledgementUncommittedCount = 0
        var lastAcknowledgementFailure: AcknowledgementFailure?
        var acknowledgedCleanupDeferredCount = 0
        var lastEnqueuedAtMS: Int64?
        var lastDurableACKCommittedAtMS: Int64?
        var lastDurableACKReplayedAtMS: Int64?
        var budget: Budget?
        var nativeQueue: NativeQueue?
        var admission: Admission?
        var refreshScheduling = RefreshScheduling()
        var automaticRequests = AutomaticRequests()
        var recentEnqueuedSources: [Source] = []
        var recentACKCommittedSources: [Source] = []
        var reportWriteFailureCount = 0
    }
    private struct Task { let generation: UInt64; let applicationRefresh: Bool }
    private let root: URL
    private let lock = NSLock()
    private let io = DispatchQueue(label: "WristRecord.watch.background-sync-diagnostics", qos: .utility)
    private var value: Report
    private var transportAdmission: Admission?
    private var tasks: [UUID: Task] = [:]
    // At most one queued writer and one replacement snapshot. A callback storm
    // cannot create an unbounded diagnostic I/O backlog or reorder snapshots.
    private var pending: Report?
    private var writeScheduled = false

    init(root: URL, maintenanceOwnerAllowed: Bool) {
        self.root = root
        value = Report(build: RedactedDiagnosticReport.safeBuild(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"),
            context: Context(maintenanceOwnerAllowed: maintenanceOwnerAllowed))
        update { _ in true }
    }

    func context(foreground: Bool? = nil, liveCapture: Bool? = nil, maintenanceOwnerAllowed: Bool? = nil) {
        update { report in
            if let foreground { report.context.foreground = foreground }
            if let liveCapture { report.context.liveCapture = liveCapture }
            if let maintenanceOwnerAllowed { report.context.maintenanceOwnerAllowed = maintenanceOwnerAllowed }
            return true
        }
    }

    func budget(externalPower: Bool, candidateLimit: Int, enqueueLimit: Int,
                candidateRemaining: Int, enqueueRemaining: Int, nativeLimit: Int) {
        update { report in
            let sample = Budget(observedAtMS: Self.nowMS, externalPower: externalPower,
                candidateLimit: candidateLimit, enqueueLimit: enqueueLimit,
                candidateRemaining: candidateRemaining, enqueueRemaining: enqueueRemaining, nativeLimit: nativeLimit)
            report.budget = sample
            if report.currentOpportunity != nil {
                if report.currentOpportunity?.initialBudget == nil { report.currentOpportunity?.initialBudget = sample }
                report.currentOpportunity?.latestBudget = sample
            }
            return true
        }
    }

    func transportObservation() -> WatchRuntimeObservation? {
        lock.lock(); defer { lock.unlock() }
        var result = WatchRuntimeObservation(build: value.build, processRunID: value.processRunID,
            observerEpochID: value.observerEpochID, sequence: value.reportSequence, observedAtMS: value.generatedAtMS)
        result.foreground = value.context.foreground; result.liveCapture = value.context.liveCapture
        result.maintenanceOwnerAllowed = value.context.maintenanceOwnerAllowed
        result.nativeQueueCount = value.nativeQueue?.count
        result.nativeQueueObservedAtMS = value.nativeQueue?.observedAtMS
        result.queueSamples = value.nativeQueue?.sample.map {
            .init(attemptID: $0.attemptID, isTransferring: $0.isTransferring,
                  completedUnits: $0.completed >= 0 ? $0.completed : nil,
                  totalUnits: $0.total >= 0 ? $0.total : nil)
        }
        if let failure = value.lastAcknowledgementFailure,
           let stage = WatchRuntimeObservation.ACKFailure.Stage(rawValue: failure.stage.rawValue),
           let reason = WatchRuntimeObservation.ACKFailure.Reason(rawValue: failure.reason) {
            result.lastACKFailure = .init(observedAtMS: failure.observedAtMS, stage: stage,
                reason: reason, systemCode: failure.systemCode, operation: failure.operation)
        }
        let refresh = value.refreshScheduling
        let errorKind: WatchRuntimeObservation.Refresh.ErrorKind? = refresh.lastErrorDomain.map {
            switch $0 {
            case NSCocoaErrorDomain: return .cocoa
            case NSPOSIXErrorDomain: return .posix
            case "WKErrorDomain": return .watchkit
            default: return .other
            }
        }
        result.refresh = .init(requestedCount: refresh.requestedCount, acceptedCount: refresh.acceptedCount,
            failedCount: refresh.failedCount, requestedAtMS: refresh.lastRequestedAtMS,
            preferredAtMS: refresh.lastRequestedPreferredDateMS, completedAtMS: refresh.lastCompletedAtMS,
            accepted: refresh.lastAccepted, errorKind: errorKind, errorCode: refresh.lastErrorCode)
        if let admission = transportAdmission,
           let reason = WatchRuntimeObservation.Admission.Reason(rawValue: admission.reason) {
            result.admission = .init(observedAtMS: admission.observedAtMS, reason: reason)
            result.admission?.handoffReason = admission.lastHandoffRefusal
            result.admission?.handoffObservedAtMS = admission.handoffRefusedAtMS
        }
        result.lastEnqueuedAtMS = value.lastEnqueuedAtMS
        result.lastACKCommittedAtMS = value.lastDurableACKCommittedAtMS
        result.lastACKReplayedAtMS = value.lastDurableACKReplayedAtMS
        result.enqueuedCount = value.fileEnqueuedCount
        result.ackCommittedCount = value.durableACKCommittedCount
        result.ackReplayedCount = value.durableACKReplayedCount
        result.ackUncommittedCount = value.acknowledgementUncommittedCount
        result.connectivityTasksStarted = value.connectivityTasksStarted
        result.applicationRefreshTasksStarted = value.applicationRefreshTasksStarted
        result.tasksCompleted = value.tasksCompleted; result.tasksExpired = value.tasksExpired
        result.liveTaskCount = value.liveTaskCount
        return result.isValid ? result : nil
    }

    func finishAdmissionObservation() {
        lock.lock(); defer { lock.unlock() }
        transportAdmission = value.admission
    }

    func nativeQueue(_ transfers: [WCSessionFileTransfer]) {
        // These objects were already fetched by admission. Reporting does not
        // perform another native lookup, source read or directory enumeration.
        let sample = transfers.prefix(3).map { transfer -> NativeTransfer in
            let manifest = (transfer.file.metadata?[TransportCodec.manifestKey] as? Data)
                .flatMap { try? TransportCodec.decode(SegmentManifest.self, from: $0) }
            let attemptID = (transfer.file.metadata?[WatchTransferBridge.attemptIDKey] as? String).flatMap(UUID.init(uuidString:))
            return NativeTransfer(segmentID: manifest?.id, attemptID: attemptID, isTransferring: transfer.isTransferring,
                completed: transfer.progress.completedUnitCount, total: transfer.progress.totalUnitCount)
        }
        update { report in
            report.nativeQueue = NativeQueue(observedAtMS: Self.nowMS, count: transfers.count,
                maximumObservedCount: max(transfers.count, report.nativeQueue?.maximumObservedCount ?? 0), sample: sample)
            return true
        }
    }

    func admission(reason: String, candidates: Int?, eligible: Int?) {
        update { report in
            var observation = report.admission ?? Admission(observedAtMS: Self.nowMS, reason: reason)
            observation.observedAtMS = Self.nowMS
            observation.reason = reason
            if let candidates { observation.candidates = candidates; observation.eligible = nil }
            if let eligible { observation.eligible = eligible }
            report.admission = observation
            return true
        }
    }

    func candidateClassification(candidates: Int, alreadyQueued: Int, retryDeferred: Int, eligible: Int) {
        update { report in
            var observation = report.admission ?? Admission(observedAtMS: Self.nowMS, reason: "not_evaluated")
            observation.classifiedAtMS = Self.nowMS
            observation.candidates = candidates
            observation.alreadyQueued = alreadyQueued
            observation.retryDeferred = retryDeferred
            observation.eligible = eligible
            report.admission = observation
            return true
        }
    }

    func handoffRefused(reason: String, skipped: Bool) {
        update { report in
            var observation = report.admission ?? Admission(observedAtMS: Self.nowMS, reason: "not_evaluated")
            observation.lastHandoffRefusal = reason
            observation.handoffRefusedAtMS = Self.nowMS
            if skipped { observation.candidateSkippedCount = min(1_000_000, observation.candidateSkippedCount + 1) }
            report.admission = observation
            return true
        }
    }

    func refreshRequested(preferredDate: Date) {
        update { report in
            report.refreshScheduling.requestedCount += 1
            report.refreshScheduling.lastRequestedAtMS = Self.nowMS
            report.refreshScheduling.lastRequestedPreferredDateMS = Int64((preferredDate.timeIntervalSince1970 * 1_000).rounded())
            return true
        }
    }

    func refreshCompleted(preferredDate: Date, succeeded: Bool, errorDomain: String?, errorCode: Int?) {
        update { report in
            if succeeded { report.refreshScheduling.acceptedCount += 1 }
            else { report.refreshScheduling.failedCount += 1 }
            report.refreshScheduling.lastCompletedAtMS = Self.nowMS
            report.refreshScheduling.lastCompletedPreferredDateMS = Int64((preferredDate.timeIntervalSince1970 * 1_000).rounded())
            report.refreshScheduling.lastAccepted = succeeded
            report.refreshScheduling.lastErrorDomain = succeeded ? nil : errorDomain.map {
                String(String.UnicodeScalarView($0.unicodeScalars.prefix(96).map {
                    $0.value >= 32 && $0.value <= 126 ? $0 : UnicodeScalar(95)!
                }))
            }
            report.refreshScheduling.lastErrorCode = succeeded ? nil : errorCode
            return true
        }
    }

    func automaticRequest(outcome: String, channel: String) {
        update { report in
            switch outcome {
            case "accepted": report.automaticRequests.acceptedCount += 1; report.automaticRequests.lastAcceptedAtMS = Self.nowMS
            case "replay": report.automaticRequests.replayCount += 1
            case "invalid": report.automaticRequests.invalidCount += 1
            case "stale": report.automaticRequests.staleCount += 1
            default: report.automaticRequests.stateUnavailableCount += 1
            }
            report.automaticRequests.lastObservedAtMS = Self.nowMS
            report.automaticRequests.lastChannel = channel
            report.automaticRequests.lastOutcome = outcome
            return true
        }
    }

    func consumption(candidateRemaining: Int, enqueueRemaining: Int) {
        update { report in
            guard var budget = report.budget else { return false }
            budget.candidateRemaining = candidateRemaining
            budget.enqueueRemaining = enqueueRemaining
            report.budget = budget
            report.currentOpportunity?.latestBudget = budget
            return true
        }
    }

    func taskStarted(id: UUID, generation: UInt64, applicationRefresh: Bool) {
        update { report in
            guard tasks[id] == nil else { return false }
            tasks[id] = Task(generation: generation, applicationRefresh: applicationRefresh)
            if report.currentOpportunity?.number != generation {
                report.currentOpportunity = Opportunity(number: generation, startedAtMS: Self.nowMS,
                    contextAtStart: report.context)
            }
            if applicationRefresh {
                report.applicationRefreshTasksStarted += 1
                report.currentOpportunity?.applicationRefreshTasksStarted += 1
            } else {
                report.connectivityTasksStarted += 1
                report.currentOpportunity?.connectivityTasksStarted += 1
            }
            report.liveTaskCount = tasks.count
            report.currentOpportunity?.liveTaskCount = tasks.values.filter { $0.generation == generation }.count
            return true
        }
    }

    func taskEnded(id: UUID, expired: Bool) {
        update { report in
            guard let task = tasks.removeValue(forKey: id) else { return false }
            if expired { report.tasksExpired += 1 } else { report.tasksCompleted += 1 }
            report.liveTaskCount = tasks.count
            if report.currentOpportunity?.number == task.generation {
                if expired { report.currentOpportunity?.tasksExpired += 1 }
                else { report.currentOpportunity?.tasksCompleted += 1 }
                let remaining = tasks.values.filter { $0.generation == task.generation }.count
                report.currentOpportunity?.liveTaskCount = remaining
                if remaining == 0 {
                    report.currentOpportunity?.endedAtMS = Self.nowMS
                    report.currentOpportunity?.endReason = expired ? "expired" : "completed"
                    report.lastOpportunity = report.currentOpportunity
                    report.currentOpportunity = nil
                }
            }
            return true
        }
    }

    func enqueued(_ manifest: SegmentManifest, generation: UInt64?) {
        update { report in
            let now = Self.nowMS
            report.fileEnqueuedCount += 1
            report.lastEnqueuedAtMS = now
            if let generation, report.currentOpportunity?.number == generation {
                report.currentOpportunity?.enqueuedCount += 1
            } else if let generation, report.lastOpportunity?.number == generation {
                report.lastOpportunity?.enqueuedCount += 1
            }
            report.recentEnqueuedSources.append(Source(segmentID: manifest.id, sequence: manifest.sequence,
                byteCount: manifest.byteCount, observedAtMS: now,
                opportunityNumber: generation,
                foreground: report.context.foreground, liveCapture: report.context.liveCapture))
            report.recentEnqueuedSources = Array(report.recentEnqueuedSources.suffix(Self.maximumRecentSources))
            return true
        }
    }

    func acknowledged(_ receipt: SegmentReceipt, newlyCommitted: Bool) {
        update { report in
            let now = Self.nowMS
            if newlyCommitted {
                report.durableACKCommittedCount += 1
                report.lastDurableACKCommittedAtMS = now
                report.currentOpportunity?.durableACKCommittedCount += 1
                report.recentACKCommittedSources.append(Source(segmentID: receipt.segmentID, sequence: nil,
                    byteCount: receipt.byteCount, observedAtMS: now,
                    opportunityNumber: report.currentOpportunity?.number,
                    foreground: report.context.foreground, liveCapture: report.context.liveCapture))
                report.recentACKCommittedSources = Array(report.recentACKCommittedSources.suffix(Self.maximumRecentSources))
            } else {
                report.durableACKReplayedCount += 1
                report.lastDurableACKReplayedAtMS = now
                report.currentOpportunity?.durableACKReplayedCount += 1
            }
            return true
        }
    }

    func acknowledgementUncommitted(error: Error, stage: AcknowledgementStage, segmentID: UUID?,
                                    operation: AcknowledgementOperation?) {
        update { report in
            report.acknowledgementUncommittedCount += 1
            report.lastAcknowledgementFailure = AcknowledgementFailure(error: error, stage: stage, segmentID: segmentID,
                context: report.context, operation: operation)
            return true
        }
    }

    func acknowledgedCleanupDeferred() {
        update { report in report.acknowledgedCleanupDeferredCount += 1; return true }
    }

    /// Drain only observations already admitted by callbacks. No library scan,
    /// transfer request or audio work is performed, and failures are not retried.
    func flush(completion: @escaping @Sendable () -> Void) {
        io.async { [self] in drain(); completion() }
    }

    private static var nowMS: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    private func update(_ body: (inout Report) -> Bool) {
        lock.lock()
        guard body(&value) else { lock.unlock(); return }
        value.reportSequence &+= 1
        value.generatedAtMS = Self.nowMS
        value.uptimeMS = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
        pending = value
        let startWriter = !writeScheduled
        writeScheduled = true
        lock.unlock()
        if startWriter { io.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let snapshot = pending else { writeScheduled = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            do {
                let bytes = try JSONEncoder().encode(snapshot)
                guard !bytes.isEmpty, bytes.count <= Self.maximumBytes else { throw POSIXError(.EFBIG) }
                try persist(bytes)
            } catch {
                // Preserve the prior successful atomic report; no issue callback,
                // library log, retry loop, synchronization or WK lease is added.
                lock.lock(); value.reportWriteFailureCount += 1; lock.unlock()
                WatchRuntimeDiagnostics.shared.record(.backgroundReportWriteFailed, error: error)
            }
        }
    }

    private func persist(_ bytes: Data) throws {
        let parent = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard parent >= 0 else { throw POSIXError(.EACCES) }
        defer { Darwin.close(parent) }
        if Darwin.mkdirat(parent, "ConnectivityDiagnostics", 0o700) != 0, errno != EEXIST { throw POSIXError(.EACCES) }
        let directory = Darwin.openat(parent, "ConnectivityDiagnostics", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard directory >= 0 else { throw POSIXError(.EACCES) }
        defer { Darwin.close(directory) }
        var directoryInfo = stat()
        guard Darwin.fstat(directory, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
              Darwin.fchmod(directory, 0o700) == 0 else { throw POSIXError(.EACCES) }
        let temporary = ".background-sync-\(UUID().uuidString).tmp"
        let descriptor = Darwin.openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { Darwin.close(descriptor); Darwin.unlinkat(directory, temporary, 0) }
        #if os(watchOS)
        let directoryURL = root.appendingPathComponent("ConnectivityDiagnostics", isDirectory: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.path)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.appendingPathComponent(temporary).path)
        #endif
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw POSIXError(.EINVAL) }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        var existing = stat()
        if Darwin.fstatat(directory, "background-sync.json", &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1,
                  existing.st_uid == getuid() else { throw POSIXError(.EINVAL) }
        } else if errno != ENOENT { throw POSIXError(.EIO) }
        guard Darwin.fsync(descriptor) == 0,
              Darwin.renameat(directory, temporary, directory, "background-sync.json") == 0,
              Darwin.fsync(directory) == 0 else { throw POSIXError(.EIO) }
    }
}

/// A frozen metadata cohort with persistent, member-keyed progress. This is
/// diagnostic evidence only: it never authorizes transfer, pruning or an ACK.
/// Page JSON hashes bind metadata bytes, never audio content.
final class WatchBacklogEvidence: @unchecked Sendable {
    enum FaultPoint: Sendable { case summaryRenamed, pagesWritten, statusPrepared, legacyReferenceRenamed, currentCohortRenamed }
    static let maximumSources = 12_288
    static let sourcesPerPage = 28
    static let maximumPages = 440
    static let maximumPageBytes = 32_768
    static let maximumSummaryBytes = 65_536
    static let summaryName = "watch-backlog.json"
    static let statusName = "watch-backlog-status.json"
    static let currentDirectory = "CurrentEvidence/v1"
    static let legacyReferenceName = "legacy-empty-reference.json"
    static let currentCohortName = "current-cohort.json"
    private static let intentName = "watch-backlog-capture.json"
    /// This link describes a superseded diagnostic catalogue, never a transfer
    /// or audio migration. The referenced legacy files remain untouched.
    struct Supersedes: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let reason: String
        let legacySummarySHA256: String
        let legacySummaryByteLength: Int
        let legacySourceSetID: UUID
        let legacyGeneration: UInt64
        let legacyBuild: String
        let legacyCapturedAtMS: Int64
        let legacyGeneratedAtMS: Int64
        let legacyIntentAbsent: Bool
    }
    struct MetadataQueue: Codable, Equatable, Sendable {
        let metadataUnacknowledgedMemberCount: Int
        let transportEligibilityEvaluated: Bool
        let transportEligibleMemberCount: Int?
        let meaning: String
    }
    struct CurrentCohort: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let sourceSetID: UUID
        let capturedAtMS: Int64
        let supersedes: Supersedes
    }
    struct Context: Codable, Equatable, Sendable {
        var foreground: Bool?
        var liveCapture: Bool?
        var externalPower: Bool
        var opportunity: UInt64?
    }
    struct Member: Codable, Equatable, Sendable {
        let segmentID: UUID
        let sha256: String
        let byteCount: Int64
        let startedAtMS: Int64
        let sequence: Int
        let historicalACKMetadata: Bool
        let historicalReceiptMetadata: Bool
        var firstEnqueuedAtMS: Int64?
        var lastEnqueuedAtMS: Int64?
        var enqueueCount: UInt64 = 0
        var lastEnqueueProcessRunID: UUID?
        var lastEnqueueContext: Context?
        var firstACKConfirmedAtMS: Int64?
        var lastACKConfirmedAtMS: Int64?
        var acknowledgementCount: UInt64 = 0
        var firstNewACKCommittedAtMS: Int64?
        var firstNewACKProcessRunID: UUID?
        var firstNewACKContext: Context?
        var lastACKProcessRunID: UUID?
        var lastACKContext: Context?
    }
    struct Page: Codable, Sendable {
        let schemaVersion: Int
        let role: String
        let sourceSetID: UUID
        let generation: UInt64
        let build: String
        let processRunID: UUID
        let index: Int
        let sourceCount: Int
        var members: [Member]
    }
    struct PageBinding: Codable, Sendable {
        let generation: UInt64
        let byteLength: Int
        let sha256: String
    }
    struct Summary: Codable, Sendable {
        let schemaVersion: Int
        let role: String
        let scope: String
        let sourceSetID: UUID
        let generation: UInt64
        let build: String
        let processRunID: UUID
        let capturedAtMS: Int64
        let generatedAtMS: Int64
        let sourceCount: Int
        let totalByteCount: Int64
        let catalogSHA256: String
        let pages: [PageBinding]
        let historicalACKMetadataCount: Int
        let historicalReceiptMetadataCount: Int
        let enqueuedMemberCount: Int
        let successfulACKConfirmationMemberCount: Int
        let newACKCommittedMemberCount: Int
        let pendingNonHistoricalMemberCount: Int
        let outsideCohortObservationCount: UInt64
        let identityConflictCount: UInt64
        let identityReadFailureCount: UInt64
        let observationOverflowCount: UInt64
        let sourceSetComplete: Bool
        let allNonHistoricalMembersACKConfirmed: Bool
        let audioRead: Bool
        let includesAudio: Bool
        let historicalACKMeaning: String
        let pendingMeaning: String
        let cloudCompletionProven: Bool
        var supersedes: Supersedes? = nil
        var metadataQueue: MetadataQueue? = nil
    }
    private struct Intent: Codable { let sourceSetID: UUID; let generatedAtMS: Int64 }
    private enum FailureStage: String, Codable {
        case snapshotRead = "snapshot_read", captureCommit = "capture_commit"
        case restore, persist, statusWrite = "status_write"
    }
    private struct FailureDetail: Codable {
        let stage: FailureStage
        let kind: String
        let nativeErrorCode: Int?
    }
    private struct Status: Codable {
        let schemaVersion = 1
        let role = "watch"
        let build: String
        let processRunID: UUID
        let generatedAtMS: Int64
        let state: String
        let sourceSetID: UUID?
        let generation: UInt64?
        let lastError: String?
        let failureDetail: FailureDetail?
        let audioRead = false
        let includesAudio = false
        var supersedes: Supersedes? = nil
    }
    private struct StoredStatusHeader: Decodable {
        let schemaVersion: Int
        let role: String
        let state: String
        let sourceSetID: UUID?
        let generation: UInt64?
    }
    // Unlike the writer's default constants, every safety field must actually
    // be decoded from disk before an observation can attest it.
    private struct ObservationStatus: Decodable {
        let schemaVersion: Int
        let role: String
        let build: String
        let processRunID: UUID
        let generatedAtMS: Int64
        let state: String
        let sourceSetID: UUID?
        let generation: UInt64?
        let lastError: String?
        let failureDetail: FailureDetail?
        let audioRead: Bool
        let includesAudio: Bool
        let supersedes: Supersedes?
    }
    private enum Failure: Error { case invalid, incomplete, capacity, identity, unavailable }
    private let root: URL
    private let build: String
    private let processRunID: UUID
    private let observationPublisher: VerifiedObservationPublisher
    private let faultInjector: (@Sendable (FaultPoint) throws -> Void)?
    private let io = DispatchQueue(label: "WristRecord.watch.backlog-evidence", qos: .utility)
    private let admissionLock = NSLock()
    private var queuedObservations = 0
    private var overflow: UInt64 = 0
    private var loaded = false
    private var blocked = false
    private var restoreRetryNeeded = false
    private var persistenceRetryNeeded = false
    private var summaryPublicationNeeded = false
    private var pendingStatusState: String?
    private var deferredObservations: [@Sendable (WatchBacklogEvidence) -> Void] = []
    private var captureAttempted = false
    private var persistScheduled = false
    private var summary: Summary?
    private var pages: [Page] = []
    private var memberLocations: [UUID: (page: Int, member: Int)] = [:]
    private var dirtyPages = Set<Int>()
    // A summary rename can become visible even when the following directory
    // fsync fails. Never overwrite a page from any earlier write attempt: it
    // may already be referenced by the last on-disk summary after a crash.
    private var attemptedPageGeneration: UInt64 = 0
    private var outside: UInt64 = 0
    private var conflicts: UInt64 = 0
    private var identityFailures: UInt64 = 0
    private var metadataWriterFailure: UInt64 = 0
    private var usesCurrentNamespace = false
    private var supersedes: Supersedes?
    private var observationAwaitingInitialCapture = false

    init(root: URL, build: String, processRunID: UUID,
         faultInjector: (@Sendable (FaultPoint) throws -> Void)? = nil,
         observationMinimumIntervalMS: Int64 = 30_000) {
        self.root = root; self.build = String(build.prefix(32)); self.processRunID = processRunID
        self.observationPublisher = VerifiedObservationPublisher(
            directory: root.appendingPathComponent("ConnectivityDiagnostics", isDirectory: true),
            reportKind: "watch_backlog", build: String(build.prefix(32)), processRunID: processRunID,
            minimumIntervalMS: observationMinimumIntervalMS)
        self.faultInjector = faultInjector
        io.async { [self] in loadOnce() }
    }

    /// Deliberately does not call loadOnce, flush, fail, or any capture provider.
    /// Only separate observation sidecars may be written by this operation.
    func observeVerifiedMetadata(onThrottle: (@Sendable (Int) -> Void)? = nil) {
        io.async { [self] in
            // A new install has no frozen report yet. Remember only the real
            // foreground request; the ordinary capture path may satisfy it.
            if loaded, !blocked, !restoreRetryNeeded, summary == nil, !captureAttempted {
                observationAwaitingInitialCapture = true
                return
            }
            publishVerifiedObservation(onThrottle: onThrottle)
        }
    }
    private func publishVerifiedObservation(sourceDidChange: Bool = false, onThrottle: (@Sendable (Int) -> Void)? = nil) {
        // A real event already owns the pending write. Do not invalidate the
        // last completed observation merely because another publish is queued,
        // and do not enqueue a competing observation behind a moving queue.
        // The ordinary successful commit below requests full revalidation.
        // Actual restore/persistence failures still enter the failing validator.
        if loaded, !blocked, !restoreRetryNeeded, !persistenceRetryNeeded, persistScheduled { return }
        observationPublisher.observe(sourceDidChange: sourceDidChange, onThrottle: onThrottle) {
            guard loaded, !blocked, !restoreRetryNeeded, !persistenceRetryNeeded,
                  !summaryPublicationNeeded, !persistScheduled, pendingStatusState == nil,
                  dirtyPages.isEmpty, deferredObservations.isEmpty else { throw Failure.incomplete }
            return try validatedObservationSource()
        }
    }
    /// The provider is called once on the independent diagnostic queue, only
    /// after its caller checks ordinary foreground maintenance permission.
    /// Nil and empty snapshots defer capture. An empty metadata directory is
    /// not sufficient evidence to freeze a complete source set.
    func captureIfNeeded(_ provider: @escaping @Sendable () throws -> RecordingTransferEvidenceSnapshot?) {
        io.async { [self] in
            loadOnce()
            guard loaded, !blocked else { return }
            drainDeferredObservations()
            guard summary == nil, !captureAttempted else { return }
            var stage = FailureStage.snapshotRead
            do {
                guard let snapshot = try provider() else { return }
                guard !snapshot.manifests.isEmpty else {
                    // Do not consume the one-shot capture or create an intent:
                    // storage visibility can change at a later real opportunity.
                    do { try writeStatus("awaiting_nonempty_catalog", error: nil) }
                    catch { deferFailure("empty_catalog_status_unavailable", underlying: error, stage: .statusWrite) }
                    return
                }
                captureAttempted = true
                stage = .captureCommit
                try capture(snapshot)
                if observationAwaitingInitialCapture {
                    observationAwaitingInitialCapture = false
                    publishVerifiedObservation(sourceDidChange: true)
                }
            } catch { fail("capture_failed", underlying: error, stage: stage) }
        }
    }
    func recordEnqueued(_ manifest: SegmentManifest, context: Context, at time: Int64 = nowMS()) {
        observe { owner in
            guard let location = owner.location(for: manifest) else { return }
            var member = owner.pages[location.page].members[location.member]
            member.firstEnqueuedAtMS = member.firstEnqueuedAtMS ?? time
            member.lastEnqueuedAtMS = time
            member.enqueueCount = owner.incremented(member.enqueueCount)
            member.lastEnqueueProcessRunID = owner.processRunID; member.lastEnqueueContext = context
            owner.pages[location.page].members[location.member] = member
            owner.dirtyPages.insert(location.page); owner.schedulePersist()
        }
    }
    /// Call only after repository.acknowledge has successfully returned. Replays
    /// confirm durability too, but are never labelled newly committed ACKs.
    func recordAcknowledgement(_ receipt: SegmentReceipt, manifest: SegmentManifest,
                               newlyCommitted: Bool, context: Context, at time: Int64 = nowMS()) {
        observe { owner in
            guard receipt.segmentID == manifest.id, receipt.sha256 == manifest.sha256,
                  receipt.byteCount == manifest.byteCount else {
                owner.conflicts = owner.incremented(owner.conflicts); owner.schedulePersist(); return
            }
            guard let location = owner.location(for: manifest) else { return }
            var member = owner.pages[location.page].members[location.member]
            member.firstACKConfirmedAtMS = member.firstACKConfirmedAtMS ?? time
            member.lastACKConfirmedAtMS = time
            member.acknowledgementCount = owner.incremented(member.acknowledgementCount)
            if newlyCommitted, member.firstNewACKCommittedAtMS == nil {
                member.firstNewACKCommittedAtMS = time
                member.firstNewACKProcessRunID = owner.processRunID; member.firstNewACKContext = context
            }
            member.lastACKProcessRunID = owner.processRunID; member.lastACKContext = context
            owner.pages[location.page].members[location.member] = member
            owner.dirtyPages.insert(location.page); owner.schedulePersist()
        }
    }
    func recordIdentityReadFailure() {
        observe { owner in owner.identityFailures = owner.incremented(owner.identityFailures); owner.schedulePersist() }
    }
    /// An observation enqueued before this barrier can itself schedule a later
    /// persist block. Commit that pending metadata here, rather than treating a
    /// plain queue barrier as proof that its child write has already executed.
    func flush(completion: @escaping @Sendable () -> Void) {
        io.async { [self] in
            loadOnce()
            if loaded, !blocked { drainDeferredObservations() }
            if persistScheduled || persistenceRetryNeeded {
                persistScheduled = false
                if loaded, !blocked { persistOrDefer() }
            }
            completion()
        }
    }
    private func observe(_ body: @escaping @Sendable (WatchBacklogEvidence) -> Void) {
        admissionLock.lock()
        guard queuedObservations < Self.maximumSources * 2 else {
            overflow = incremented(overflow); admissionLock.unlock(); return
        }
        queuedObservations += 1; admissionLock.unlock()
        io.async { [self] in
            loadOnce()
            guard !blocked else { releaseObservationAdmission(); return }
            guard loaded else {
                // Keep only actual, already observed events while protected
                // metadata is temporarily unavailable. Admission remains held
                // so repeated opportunities cannot grow this queue unbounded.
                deferredObservations.append(body); return
            }
            drainDeferredObservations()
            body(self); releaseObservationAdmission()
            if persistenceRetryNeeded { schedulePersist(summaryChanged: false) }
        }
    }
    private func releaseObservationAdmission() {
        admissionLock.lock(); queuedObservations -= 1; admissionLock.unlock()
    }
    private func drainDeferredObservations() {
        guard loaded, !blocked, !deferredObservations.isEmpty else { return }
        let pending = deferredObservations; deferredObservations.removeAll(keepingCapacity: true)
        for body in pending { body(self); releaseObservationAdmission() }
    }
    private func location(for manifest: SegmentManifest) -> (page: Int, member: Int)? {
        guard let location = memberLocations[manifest.id] else {
            outside = incremented(outside); schedulePersist(); return nil
        }
        let member = pages[location.page].members[location.member]
        guard let start = Self.milliseconds(manifest.startedAt), member.sha256 == manifest.sha256,
              member.byteCount == manifest.byteCount, member.startedAtMS == start else {
            conflicts = incremented(conflicts); schedulePersist(); return nil
        }
        return location
    }
    private func capture(_ snapshot: RecordingTransferEvidenceSnapshot) throws {
        guard snapshot.manifests.count <= Self.maximumSources else { throw Failure.capacity }
        let ackIDs = Set(snapshot.acknowledgements.map(\.segmentID))
        let receiptIDs = Set(snapshot.receipts.map(\.segmentID))
        let values = try snapshot.manifests.sorted { $0.id.uuidString < $1.id.uuidString }.map { value -> Member in
            guard let time = Self.milliseconds(value.startedAt) else { throw Failure.invalid }
            return Member(segmentID: value.id, sha256: value.sha256, byteCount: value.byteCount,
                startedAtMS: time, sequence: value.sequence, historicalACKMetadata: ackIDs.contains(value.id),
                historicalReceiptMetadata: receiptIDs.contains(value.id))
        }
        guard Set(values.map(\.segmentID)).count == values.count else { throw Failure.identity }
        let sourceSetID = UUID(), captureTime = Self.nowMS()
        if usesCurrentNamespace {
            guard let supersedes,
                  try read(name: Self.currentCohortName, maximum: 4_096) == nil else { throw Failure.incomplete }
            // Never remove this witness: loss of summary/intent must not make
            // a once-started current cohort appear to be a fresh opportunity.
            let witness = CurrentCohort(schemaVersion: 1, sourceSetID: sourceSetID,
                capturedAtMS: captureTime, supersedes: supersedes)
            try write(Self.encode(witness), name: Self.currentCohortName, maximum: 4_096)
        }
        let intent = try Self.encode(Intent(sourceSetID: sourceSetID, generatedAtMS: captureTime))
        try write(intent, name: Self.intentName, maximum: 1_024)
        pages = stride(from: 0, to: values.count, by: Self.sourcesPerPage).enumerated().map { index, offset in
            Page(schemaVersion: 1, role: "watch", sourceSetID: sourceSetID, generation: 1,
                build: build, processRunID: processRunID, index: index, sourceCount: values.count,
                members: Array(values[offset..<min(values.count, offset + Self.sourcesPerPage)]))
        }
        let initial = try makeSummary(id: sourceSetID, generation: 1, capturedAt: captureTime, bindings: [])
        summary = initial; dirtyPages = Set(pages.indices); summaryPublicationNeeded = true
        rebuildLocations()
        try persist()
        try remove(name: Self.intentName)
    }
    private func loadOnce() {
        guard !loaded, !blocked else { return }; loaded = true
        var restorationCompleted = false
        do {
            let bytes = try read(name: Self.summaryName, maximum: Self.maximumSummaryBytes)
            let intent = try read(name: Self.intentName, maximum: 1_024)
            guard let bytes else {
                // After a failed read, never replace a previously frozen
                // cohort with a new capture merely because its files vanished.
                guard intent == nil, !restoreRetryNeeded else { throw Failure.incomplete }
                if !usesCurrentNamespace {
                    // Current evidence is reachable only through the exact
                    // preserved legacy summary. Its loss is not a new install.
                    guard try !diagnosticEntryExists("CurrentEvidence") else { throw Failure.incomplete }
                }
                if usesCurrentNamespace { try requireNeverCapturedCurrentNamespace() }
                try writeStatus("awaiting_foreground_capture", error: nil); return
            }
            let value = try TransportCodec.decode(Summary.self, from: bytes)
            guard value.schemaVersion == 1, value.role == "watch", value.scope == "frozen_manifest_metadata_catalog",
                  value.sourceSetComplete, !value.audioRead, !value.includesAudio, !value.cloudCompletionProven,
                  value.sourceCount >= 0, value.sourceCount <= Self.maximumSources,
                  value.pages.count == (value.sourceCount + Self.sourcesPerPage - 1) / Self.sourcesPerPage,
                  value.pages.count <= Self.maximumPages, value.generation > 0,
                  value.capturedAtMS > 0, value.generatedAtMS >= value.capturedAtMS else { throw Failure.invalid }
            guard value.supersedes == supersedes else { throw Failure.identity }
            if usesCurrentNamespace {
                guard let supersedes,
                      let witnessBytes = try read(name: Self.currentCohortName, maximum: 4_096),
                      try TransportCodec.decode(CurrentCohort.self, from: witnessBytes)
                        == CurrentCohort(schemaVersion: 1, sourceSetID: value.sourceSetID,
                            capturedAtMS: value.capturedAtMS, supersedes: supersedes) else { throw Failure.identity }
            }
            if let intent {
                // A partially published current capture is not permission to
                // mint another catalogue, even if its UUID happens to match.
                guard !usesCurrentNamespace else { throw Failure.incomplete }
                let pending = try TransportCodec.decode(Intent.self, from: intent)
                guard pending.sourceSetID == value.sourceSetID else { throw Failure.incomplete }
            }
            var restored: [Page] = []
            for (index, binding) in value.pages.enumerated() {
                guard binding.byteLength > 0, binding.byteLength <= Self.maximumPageBytes,
                      binding.generation > 0, binding.generation <= value.generation,
                      let bytes = try read(name: Self.pageName(index, generation: binding.generation),
                        maximum: Self.maximumPageBytes, cohort: value.sourceSetID),
                      bytes.count == binding.byteLength, Self.digest(bytes) == binding.sha256 else { throw Failure.invalid }
                let page = try TransportCodec.decode(Page.self, from: bytes)
                guard page.schemaVersion == 1, page.role == "watch", page.sourceSetID == value.sourceSetID,
                      page.generation == binding.generation, page.index == index,
                      page.sourceCount == value.sourceCount,
                      page.members.count == min(Self.sourcesPerPage, value.sourceCount - index * Self.sourcesPerPage) else { throw Failure.identity }
                restored.append(page)
            }
            pages = restored; summary = value
            let all = pages.flatMap(\.members)
            guard all.count == value.sourceCount, Set(all.map(\.segmentID)).count == all.count,
                  all.map(\.segmentID.uuidString) == all.map(\.segmentID.uuidString).sorted(),
                  all.allSatisfy(Self.validMember), Self.catalogDigest(all) == value.catalogSHA256 else { throw Failure.invalid }
            outside = value.outsideCohortObservationCount; conflicts = value.identityConflictCount
            identityFailures = value.identityReadFailureCount
            admissionLock.lock()
            let pendingOverflow = overflow
            overflow = value.observationOverflowCount
            admissionLock.unlock()
            let recomputed = try makeSummary(id: value.sourceSetID, generation: value.generation,
                capturedAt: value.capturedAtMS, bindings: value.pages)
            guard recomputed.sourceCount == value.sourceCount, recomputed.totalByteCount == value.totalByteCount,
                  recomputed.historicalACKMetadataCount == value.historicalACKMetadataCount,
                  recomputed.historicalReceiptMetadataCount == value.historicalReceiptMetadataCount,
                  recomputed.enqueuedMemberCount == value.enqueuedMemberCount,
                  recomputed.successfulACKConfirmationMemberCount == value.successfulACKConfirmationMemberCount,
                  recomputed.newACKCommittedMemberCount == value.newACKCommittedMemberCount,
                  recomputed.pendingNonHistoricalMemberCount == value.pendingNonHistoricalMemberCount,
                  recomputed.allNonHistoricalMembersACKConfirmed == value.allNonHistoricalMembersACKConfirmed else { throw Failure.invalid }
            if usesCurrentNamespace {
                guard value.metadataQueue == recomputed.metadataQueue else { throw Failure.invalid }
            }
            guard !all.isEmpty else {
                // Only an entirely validated legacy empty catalogue can be
                // superseded. Neither its intent nor any original file is
                // removed or rewritten. New-format empty archives remain bad
                // evidence, rather than becoming a recurring recapture loop.
                guard !usesCurrentNamespace, value.supersedes == nil,
                      value.metadataQueue == nil, intent == nil else { throw Failure.incomplete }
                try selectCurrentNamespace(legacy: value, bytes: bytes,
                                           pendingOverflow: pendingOverflow)
                loaded = false
                loadOnce()
                return
            }
            admissionLock.lock()
            let combinedOverflow = overflow.addingReportingOverflow(pendingOverflow)
            overflow = combinedOverflow.overflow ? UInt64.max : combinedOverflow.partialValue
            admissionLock.unlock()
            rebuildLocations()
            restorationCompleted = true; restoreRetryNeeded = false
            if value.build != build {
                // Re-observe the fully validated frozen metadata under this
                // build. The existing publication path advances generation,
                // retains every page binding/event, and commits status last.
                // This is publication, not a new capture or a new durable ACK.
                summaryPublicationNeeded = true
                persistOrDefer()
            } else {
                // Also repairs a prior summary commit whose following status
                // write failed. Same-build restore never rewrites the summary.
                pendingStatusState = "restored"
                try publishPendingStatus()
            }
        } catch {
            if restorationCompleted {
                // Validation already passed; an unavailable status file is a
                // publication failure, never evidence of a corrupt catalogue.
                if Self.retryableMetadataError(error) {
                    persistenceRetryNeeded = true
                    deferFailure("persistence_unavailable", underlying: error, stage: .statusWrite)
                } else { fail("persistence_failed", underlying: error, stage: .statusWrite) }
                return
            }
            // A rejected legacy archive must retain its original status too.
            // Publish the failure separately without changing the namespace
            // that a later retryable restore must read.
            let readNamespace = usesCurrentNamespace, readSummary = summary
            if !usesCurrentNamespace {
                usesCurrentNamespace = true; summary = nil
            }
            defer { usesCurrentNamespace = readNamespace; summary = readSummary }
            if Self.retryableMetadataError(error) {
                loaded = false; restoreRetryNeeded = true
                deferFailure("restore_unavailable", underlying: error, stage: .restore)
            } else { fail("restore_failed", underlying: error, stage: .restore) }
        }
    }

    /// Independent disk validation. Nothing here changes cached source state,
    /// repairs a status, advances a generation, or grants transfer permission.
    private func validatedObservationSource() throws -> VerifiedObservationSource {
        struct ReadBinding {
            let name: String
            let maximum: Int
            let cohort: UUID?
            let current: Bool
            let bytes: Data
            var relativeName: String {
                (current ? WatchBacklogEvidence.currentDirectory + "/" : "")
                    + (cohort.map { "BacklogEvidence/" + $0.uuidString.lowercased() + "/" } ?? "") + name
            }
        }
        var bindings: [ReadBinding] = []
        func validBuild(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 20 && value.utf8.allSatisfy { (48...57).contains($0) }
        }
        func required(_ name: String, maximum: Int, current: Bool, cohort: UUID? = nil) throws -> Data {
            guard let bytes = try read(name: name, maximum: maximum, cohort: cohort, current: current) else {
                throw Failure.incomplete
            }
            bindings.append(ReadBinding(name: name, maximum: maximum, cohort: cohort, current: current, bytes: bytes))
            return bytes
        }
        func archive(current: Bool, expectedSupersedes: Supersedes?) throws -> Summary {
            let bytes = try required(Self.summaryName, maximum: Self.maximumSummaryBytes, current: current)
            let value = try TransportCodec.decode(Summary.self, from: bytes)
            guard value.schemaVersion == 1, value.role == "watch", value.scope == "frozen_manifest_metadata_catalog",
                  value.sourceSetComplete, !value.audioRead, !value.includesAudio, !value.cloudCompletionProven,
                  validBuild(value.build),
                  value.sourceCount >= 0, value.sourceCount <= Self.maximumSources,
                  value.pages.count == (value.sourceCount + Self.sourcesPerPage - 1) / Self.sourcesPerPage,
                  value.pages.count <= Self.maximumPages, value.generation > 0,
                  value.capturedAtMS > 0, value.generatedAtMS >= value.capturedAtMS,
                  value.historicalACKMeaning == "historical_ack_metadata_not_new_durability",
                  value.pendingMeaning == "frozen_members_without_historical_ack_or_later_successful_ack_confirmation_not_audio_availability",
                  value.supersedes == expectedSupersedes,
                  try read(name: Self.intentName, maximum: 1_024, current: current) == nil else { throw Failure.invalid }
            var members: [Member] = []
            for (index, binding) in value.pages.enumerated() {
                guard binding.byteLength > 0, binding.byteLength <= Self.maximumPageBytes,
                      binding.generation > 0, binding.generation <= value.generation else { throw Failure.invalid }
                let bytes = try required(Self.pageName(index, generation: binding.generation),
                    maximum: Self.maximumPageBytes, current: current, cohort: value.sourceSetID)
                guard bytes.count == binding.byteLength, Self.digest(bytes) == binding.sha256 else { throw Failure.invalid }
                let page = try TransportCodec.decode(Page.self, from: bytes)
                guard page.schemaVersion == 1, page.role == "watch", page.sourceSetID == value.sourceSetID,
                      page.generation == binding.generation, page.index == index, validBuild(page.build),
                      page.sourceCount == value.sourceCount,
                      page.members.count == min(Self.sourcesPerPage, value.sourceCount - index * Self.sourcesPerPage)
                else { throw Failure.identity }
                members.append(contentsOf: page.members)
            }
            guard members.count == value.sourceCount, Set(members.map(\.segmentID)).count == members.count,
                  members.map(\.segmentID.uuidString) == members.map(\.segmentID.uuidString).sorted(),
                  members.allSatisfy(Self.validMember), Self.catalogDigest(members) == value.catalogSHA256 else {
                throw Failure.invalid
            }
            var total: Int64 = 0
            for member in members {
                let added = total.addingReportingOverflow(member.byteCount)
                guard !added.overflow, member.startedAtMS > 0,
                      [member.firstEnqueuedAtMS, member.lastEnqueuedAtMS, member.firstACKConfirmedAtMS,
                       member.lastACKConfirmedAtMS, member.firstNewACKCommittedAtMS].compactMap({ $0 })
                        .allSatisfy({ $0 > 0 && $0 <= value.generatedAtMS })
                else { throw Failure.invalid }
                total = added.partialValue
            }
            let pending = members.filter { !$0.historicalACKMetadata && $0.firstACKConfirmedAtMS == nil }.count
            guard value.totalByteCount == total,
                  value.historicalACKMetadataCount == members.filter(\.historicalACKMetadata).count,
                  value.historicalReceiptMetadataCount == members.filter(\.historicalReceiptMetadata).count,
                  value.enqueuedMemberCount == members.filter({ $0.enqueueCount > 0 }).count,
                  value.successfulACKConfirmationMemberCount == members.filter({ $0.firstACKConfirmedAtMS != nil }).count,
                  value.newACKCommittedMemberCount == members.filter({ $0.firstNewACKCommittedAtMS != nil }).count,
                  value.pendingNonHistoricalMemberCount == pending,
                  value.allNonHistoricalMembersACKConfirmed == (pending == 0 && value.identityConflictCount == 0
                    && value.identityReadFailureCount == 0 && value.observationOverflowCount == 0) else { throw Failure.invalid }
            if current || value.metadataQueue != nil {
                guard value.metadataQueue == MetadataQueue(metadataUnacknowledgedMemberCount: pending,
                    transportEligibilityEvaluated: false, transportEligibleMemberCount: nil,
                    meaning: "metadata_absence_of_ACK_not_transport_eligibility") else { throw Failure.invalid }
            }
            return value
        }

        let current = usesCurrentNamespace
        var reference: Supersedes?
        if current {
            let legacy = try archive(current: false, expectedSupersedes: nil)
            guard legacy.sourceCount == 0, legacy.metadataQueue == nil,
                  let legacyBytes = bindings.first?.bytes else { throw Failure.identity }
            let expected = Supersedes(schemaVersion: 1, reason: "legacy_empty_catalog",
                legacySummarySHA256: Self.digest(legacyBytes), legacySummaryByteLength: legacyBytes.count,
                legacySourceSetID: legacy.sourceSetID, legacyGeneration: legacy.generation,
                legacyBuild: legacy.build, legacyCapturedAtMS: legacy.capturedAtMS,
                legacyGeneratedAtMS: legacy.generatedAtMS, legacyIntentAbsent: true)
            let bytes = try required(Self.legacyReferenceName, maximum: 4_096, current: true)
            guard bytes == (try Self.encode(expected)),
                  try TransportCodec.decode(Supersedes.self, from: bytes) == expected else { throw Failure.identity }
            reference = expected
        } else {
            guard try !diagnosticEntryExists("CurrentEvidence", current: false) else { throw Failure.identity }
        }
        let value = try archive(current: current, expectedSupersedes: reference)
        guard value.sourceCount > 0, value.build == build else { throw Failure.invalid }
        if let reference {
            let bytes = try required(Self.currentCohortName, maximum: 4_096, current: true)
            guard try TransportCodec.decode(CurrentCohort.self, from: bytes)
                == CurrentCohort(schemaVersion: 1, sourceSetID: value.sourceSetID,
                    capturedAtMS: value.capturedAtMS, supersedes: reference) else { throw Failure.identity }
        }
        let statusBytes = try required(Self.statusName, maximum: 4_096, current: current)
        let status = try TransportCodec.decode(ObservationStatus.self, from: statusBytes)
        guard status.schemaVersion == 1, status.role == "watch", status.build == value.build,
              ["ready", "restored"].contains(status.state), status.sourceSetID == value.sourceSetID,
              status.generation == value.generation, status.generatedAtMS >= value.generatedAtMS,
              status.lastError == nil, status.failureDetail == nil, !status.audioRead, !status.includesAudio,
              status.supersedes == reference else { throw Failure.invalid }
        // Re-open each bound file with the same no-follow checks. A page or
        // control file replaced during validation invalidates this observation.
        for binding in bindings {
            guard try read(name: binding.name, maximum: binding.maximum, cohort: binding.cohort,
                           current: binding.current) == binding.bytes else { throw Failure.identity }
        }
        guard try read(name: Self.intentName, maximum: 1_024, current: current) == nil else {
            throw Failure.incomplete
        }
        if current, try read(name: Self.intentName, maximum: 1_024, current: false) != nil { throw Failure.incomplete }
        return VerifiedObservationSource(sourceGeneratedAtMS: value.generatedAtMS,
            identity: ["sourceSetID": value.sourceSetID.uuidString.lowercased(), "catalogSHA256": value.catalogSHA256,
                "capturedAtMS": String(value.capturedAtMS), "generation": String(value.generation),
                "sourceCount": String(value.sourceCount), "processRunID": value.processRunID.uuidString.lowercased()],
            files: bindings.map { VerifiedObservationFile(name: $0.relativeName, bytes: $0.bytes) },
            snapshotFiles: Dictionary(uniqueKeysWithValues: bindings.map { ($0.relativeName, $0.bytes) }))
    }
    private func selectCurrentNamespace(legacy: Summary, bytes: Data, pendingOverflow: UInt64) throws {
        let reference = Supersedes(schemaVersion: 1, reason: "legacy_empty_catalog",
            legacySummarySHA256: Self.digest(bytes), legacySummaryByteLength: bytes.count,
            legacySourceSetID: legacy.sourceSetID, legacyGeneration: legacy.generation,
            legacyBuild: legacy.build, legacyCapturedAtMS: legacy.capturedAtMS,
            legacyGeneratedAtMS: legacy.generatedAtMS, legacyIntentAbsent: true)
        // Selection is provisional until the exact reference is readable and
        // committed. A retry must re-read legacy+reference, not jump directly
        // into current pages after a protected-file or fsync failure.
        var selected = false
        defer {
            if !selected { usesCurrentNamespace = false; supersedes = nil; summary = legacy }
        }
        usesCurrentNamespace = true; supersedes = reference
        summary = nil; pages = []; memberLocations = [:]; dirtyPages = []
        summaryPublicationNeeded = false; pendingStatusState = nil
        attemptedPageGeneration = 0; outside = 0; conflicts = 0; identityFailures = 0
        admissionLock.lock(); overflow = pendingOverflow; admissionLock.unlock()
        let canonical = try Self.encode(reference)
        if let existing = try read(name: Self.legacyReferenceName, maximum: 4_096) {
            guard existing == canonical,
                  try TransportCodec.decode(Supersedes.self, from: existing) == reference else { throw Failure.identity }
        } else {
            // A missing link beside existing current state is a torn or unknown
            // transaction. Do not adopt its pages or bind a replacement link.
            guard try read(name: Self.summaryName, maximum: Self.maximumSummaryBytes) == nil,
                  try read(name: Self.intentName, maximum: 1_024) == nil,
                  try !diagnosticEntryExists(Self.currentCohortName),
                  try !diagnosticEntryExists("BacklogEvidence") else { throw Failure.incomplete }
            try write(canonical, name: Self.legacyReferenceName, maximum: 4_096)
        }
        restoreRetryNeeded = false
        selected = true
    }
    private func requireNeverCapturedCurrentNamespace() throws {
        // A reference-only crash may resume, but missing summary+intent beside
        // old pages or a previously published cohort is not a new catalogue.
        guard try !diagnosticEntryExists(Self.currentCohortName),
              try !diagnosticEntryExists("BacklogEvidence") else { throw Failure.incomplete }
        if let bytes = try read(name: Self.statusName, maximum: 4_096) {
            let value = try TransportCodec.decode(StoredStatusHeader.self, from: bytes)
            guard value.schemaVersion == 1, value.role == "watch",
                  value.sourceSetID == nil, value.generation == nil,
                  ["awaiting_foreground_capture", "awaiting_nonempty_catalog", "retry_pending"].contains(value.state)
            else { throw Failure.incomplete }
        }
    }
    private func rebuildLocations() {
        memberLocations.removeAll(keepingCapacity: true)
        for (pageIndex, page) in pages.enumerated() {
            for (memberIndex, member) in page.members.enumerated() {
                memberLocations[member.segmentID] = (pageIndex, memberIndex)
            }
        }
    }
    private func schedulePersist(summaryChanged: Bool = true) {
        guard summary != nil else { return }
        // Summary-only counters are observations too; dirty page membership
        // alone cannot identify whether another summary must be published.
        if summaryChanged { summaryPublicationNeeded = true }
        guard !persistScheduled else { return }; persistScheduled = true
        io.async { [self] in
            guard persistScheduled else { return }
            persistScheduled = false
            guard !blocked else { return }
            persistOrDefer()
        }
    }
    private func persistOrDefer() {
        let sourceChanged = summaryPublicationNeeded || pendingStatusState != nil
        do {
            if summaryPublicationNeeded { try persist() }
            else { try publishPendingStatus() }
            persistenceRetryNeeded = false
            if sourceChanged { publishVerifiedObservation(sourceDidChange: true) }
        }
        catch {
            let stage: FailureStage = summaryPublicationNeeded ? .persist : .statusWrite
            if Self.retryableMetadataError(error) {
                persistenceRetryNeeded = true; deferFailure("persistence_unavailable", underlying: error, stage: stage)
            } else { fail("persistence_failed", underlying: error, stage: stage) }
        }
    }
    private func publishPendingStatus() throws {
        guard let state = pendingStatusState else { return }
        try writeStatus(state, error: nil)
        pendingStatusState = nil
    }
    private func persist() throws {
        guard let previous = summary else { return }
        let generation: UInt64
        let floor = max(previous.generation, attemptedPageGeneration)
        if attemptedPageGeneration == 0, previous.pages.isEmpty, !pages.isEmpty { generation = previous.generation }
        else { guard floor < UInt64.max else { throw Failure.capacity }; generation = floor + 1 }
        // Reserve before any page I/O, including an attempt which later fails.
        attemptedPageGeneration = generation
        var bindings = previous.pages
        if bindings.isEmpty { bindings = Array(repeating: PageBinding(generation: generation, byteLength: 0, sha256: ""), count: pages.count) }
        var replacements: [(Int, Page)] = []
        for index in dirtyPages.sorted() {
            let old = pages[index]
            let updated = Page(schemaVersion: 1, role: "watch", sourceSetID: previous.sourceSetID,
                generation: generation, build: build, processRunID: processRunID, index: index,
                sourceCount: previous.sourceCount, members: old.members)
            let bytes = try Self.encode(updated)
            guard bytes.count <= Self.maximumPageBytes else { throw Failure.capacity }
            try write(bytes, name: Self.pageName(index, generation: generation),
                maximum: Self.maximumPageBytes, cohort: previous.sourceSetID)
            bindings[index] = PageBinding(generation: generation, byteLength: bytes.count, sha256: Self.digest(bytes))
            replacements.append((index, updated))
        }
        let next = try makeSummary(id: previous.sourceSetID, generation: generation,
            capturedAt: previous.capturedAtMS, bindings: bindings)
        let bytes = try Self.encode(next)
        guard bytes.count <= Self.maximumSummaryBytes else { throw Failure.capacity }
        try faultInjector?(.pagesWritten)
        // Immutable page versions first, one atomic summary binding last. A
        // crash cannot mix old/new page bodies behind a committed old summary.
        try write(bytes, name: Self.summaryName, maximum: Self.maximumSummaryBytes)
        summary = next
        for (index, page) in replacements { pages[index] = page }
        dirtyPages.removeAll()
        // Once the summary commit succeeds, a status outage must not advance
        // its generation or generatedAtMS on every later flush. Genuine new
        // observations set summaryPublicationNeeded again in schedulePersist.
        summaryPublicationNeeded = false
        pendingStatusState = "ready"
        try publishPendingStatus()
        for (index, _) in replacements where index < previous.pages.count {
            let oldGeneration = previous.pages[index].generation
            if oldGeneration != bindings[index].generation {
                try? remove(name: Self.pageName(index, generation: oldGeneration), cohort: previous.sourceSetID)
            }
        }
    }
    private func makeSummary(id: UUID, generation: UInt64, capturedAt: Int64,
                             bindings: [PageBinding]) throws -> Summary {
        let values = pages.flatMap(\.members)
        var total: Int64 = 0
        for value in values {
            let addition = total.addingReportingOverflow(value.byteCount)
            guard !addition.overflow, value.byteCount > 0 else { throw Failure.capacity }
            total = addition.partialValue
        }
        let historical = values.filter(\.historicalACKMetadata).count
        let pending = values.filter { !$0.historicalACKMetadata && $0.firstACKConfirmedAtMS == nil }.count
        admissionLock.lock(); let dropped = overflow; admissionLock.unlock()
        return Summary(schemaVersion: 1, role: "watch", scope: "frozen_manifest_metadata_catalog",
            sourceSetID: id, generation: generation, build: build, processRunID: processRunID,
            capturedAtMS: capturedAt, generatedAtMS: Self.nowMS(), sourceCount: values.count,
            totalByteCount: total, catalogSHA256: Self.catalogDigest(values), pages: bindings,
            historicalACKMetadataCount: historical, historicalReceiptMetadataCount: values.filter(\.historicalReceiptMetadata).count,
            enqueuedMemberCount: values.filter { $0.enqueueCount > 0 }.count,
            successfulACKConfirmationMemberCount: values.filter { $0.firstACKConfirmedAtMS != nil }.count,
            newACKCommittedMemberCount: values.filter { $0.firstNewACKCommittedAtMS != nil }.count,
            pendingNonHistoricalMemberCount: pending, outsideCohortObservationCount: outside,
            identityConflictCount: conflicts, identityReadFailureCount: identityFailures, observationOverflowCount: dropped,
            sourceSetComplete: true, allNonHistoricalMembersACKConfirmed: pending == 0 && conflicts == 0 && identityFailures == 0 && dropped == 0,
            audioRead: false, includesAudio: false, historicalACKMeaning: "historical_ack_metadata_not_new_durability",
            pendingMeaning: "frozen_members_without_historical_ack_or_later_successful_ack_confirmation_not_audio_availability",
            cloudCompletionProven: false, supersedes: supersedes,
            metadataQueue: MetadataQueue(metadataUnacknowledgedMemberCount: pending,
                transportEligibilityEvaluated: false, transportEligibleMemberCount: nil,
                meaning: "metadata_absence_of_ACK_not_transport_eligibility"))
    }
    private func fail(_ code: String, underlying: Error? = nil, stage: FailureStage? = nil) {
        blocked = true; metadataWriterFailure = incremented(metadataWriterFailure)
        for _ in deferredObservations { releaseObservationAdmission() }
        deferredObservations.removeAll()
        writeFailureStatus("failed", code: code, underlying: underlying, stage: stage)
    }
    private func deferFailure(_ code: String, underlying: Error? = nil, stage: FailureStage? = nil) {
        metadataWriterFailure = incremented(metadataWriterFailure)
        writeFailureStatus("retry_pending", code: code, underlying: underlying, stage: stage)
    }
    private func writeFailureStatus(_ state: String, code: String, underlying: Error?, stage: FailureStage?) {
        // Preserve the error across later successful recovery, including when
        // the mutable business failure status itself cannot be written.
        if (UInt64(build) ?? 0) >= 87 { observationPublisher.invalidate() }
        do { try writeStatus(state, error: code, detail: Self.failureDetail(underlying, stage: stage)) }
        catch {
            // Even the bounded failure report may be unwritable. Retain the
            // retry/blocked state and explicitly log fixed categories only;
            // never serialize an error description, path or recording UUID.
            let original = Self.failureDetail(underlying, stage: stage)
            let detail = Self.failureDetail(error, stage: .statusWrite)
            NSLog("WatchBacklogEvidence failure status unavailable: code=%@ stage=%@ kind=%@ native=%@ statusKind=%@ statusNative=%@",
                  code, original?.stage.rawValue ?? "none", original?.kind ?? "other",
                  original?.nativeErrorCode.map(String.init) ?? "none",
                  detail?.kind ?? "other", detail?.nativeErrorCode.map(String.init) ?? "none")
        }
    }
    // Keep only fixed categories and OS error codes. Descriptions, paths,
    // decoding keys and repository associated strings can contain private IDs.
    private static func failureDetail(_ error: Error?, stage: FailureStage?) -> FailureDetail? {
        guard let error, let stage else { return nil }
        let kind: String
        if let value = error as? Failure {
            switch value {
            case .invalid: kind = "invalid_evidence"
            case .incomplete: kind = "incomplete_evidence"
            case .capacity: kind = "capacity"
            case .identity: kind = "identity_mismatch"
            case .unavailable: kind = "metadata_unavailable"
            }
        } else if let value = error as? DecodingError {
            switch value {
            case .typeMismatch: kind = "decode_type_mismatch"
            case .valueNotFound: kind = "decode_missing_value"
            case .keyNotFound: kind = "decode_missing_key"
            case .dataCorrupted: kind = "decode_corrupted"
            @unknown default: kind = "decode_other"
            }
        } else if let value = error as? RepositoryError {
            switch value {
            case .invalidManifest: kind = "invalid_manifest"
            case .checksumMismatch: kind = "repository_checksum_mismatch"
            case .conflictingSegment: kind = "repository_conflict"
            case .receiptMismatch: kind = "repository_receipt_mismatch"
            case .missingAudio: kind = "repository_missing_audio"
            case .invalidStagingPath: kind = "repository_invalid_staging"
            case .persistenceFailure: kind = "repository_persistence"
            }
        } else {
            let native = error as NSError
            if native.domain == NSCocoaErrorDomain || native.domain == NSPOSIXErrorDomain {
                return FailureDetail(stage: stage, kind: native.domain == NSCocoaErrorDomain ? "cocoa" : "posix",
                    nativeErrorCode: native.code)
            }
            kind = "other"
        }
        return FailureDetail(stage: stage, kind: kind, nativeErrorCode: nil)
    }
    private static func retryableMetadataError(_ error: Error) -> Bool {
        if let value = error as? Failure { if case .unavailable = value { return true }; return false }
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain {
            return [EACCES, EPERM, EINTR, EIO, EBUSY, ENOSPC, EROFS, ENFILE, EMFILE, ETIMEDOUT, EAGAIN].contains(Int32(value.code))
        }
        guard value.domain == NSCocoaErrorDomain else { return false }
        return [CocoaError.Code.fileReadNoPermission, .fileWriteNoPermission, .fileReadUnknown,
                .fileWriteUnknown, .fileWriteOutOfSpace].contains(CocoaError.Code(rawValue: value.code))
    }
    private func writeStatus(_ state: String, error: String?, detail: FailureDetail? = nil) throws {
        let value = Status(build: build, processRunID: processRunID, generatedAtMS: Self.nowMS(), state: state,
            sourceSetID: summary?.sourceSetID, generation: summary?.generation, lastError: error, failureDetail: detail,
            supersedes: supersedes)
        try write(Self.encode(value), name: Self.statusName, maximum: 4_096)
    }
    private static func validMember(_ value: Member) -> Bool {
        guard value.byteCount > 0, value.sequence >= 0, value.sha256.count == 64,
              value.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
        guard (value.firstEnqueuedAtMS == nil) == (value.lastEnqueuedAtMS == nil),
              (value.firstACKConfirmedAtMS == nil) == (value.lastACKConfirmedAtMS == nil),
              (value.firstNewACKCommittedAtMS != nil) == (value.firstNewACKProcessRunID != nil),
              (value.firstNewACKCommittedAtMS != nil) == (value.firstNewACKContext != nil) else { return false }
        let enqueued = value.firstEnqueuedAtMS != nil && value.lastEnqueuedAtMS != nil
        let acknowledged = value.firstACKConfirmedAtMS != nil && value.lastACKConfirmedAtMS != nil
        guard (value.enqueueCount > 0) == enqueued, (value.acknowledgementCount > 0) == acknowledged,
              (value.lastEnqueueProcessRunID != nil) == enqueued, (value.lastEnqueueContext != nil) == enqueued,
              (value.lastACKProcessRunID != nil) == acknowledged, (value.lastACKContext != nil) == acknowledged else { return false }
        if let first = value.firstEnqueuedAtMS, let last = value.lastEnqueuedAtMS, first > last { return false }
        if let first = value.firstACKConfirmedAtMS, let last = value.lastACKConfirmedAtMS, first > last { return false }
        if let first = value.firstNewACKCommittedAtMS {
            guard let lo = value.firstACKConfirmedAtMS, let hi = value.lastACKConfirmedAtMS,
                  first >= lo, first <= hi else { return false }
        }
        return true
    }
    private static func catalogDigest(_ members: [Member]) -> String {
        let canonical = members.map { "\($0.segmentID.uuidString.lowercased())|\($0.sha256)|\($0.byteCount)|\($0.startedAtMS)\n" }.joined()
        return digest(Data(canonical.utf8))
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func milliseconds(_ date: Date) -> Int64? {
        let value = (date.timeIntervalSince1970 * 1_000).rounded(.towardZero)
        return value.isFinite ? Int64(exactly: value) : nil
    }
    static func nowMS() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
    private func incremented(_ n: UInt64) -> UInt64 { n < UInt64.max ? n + 1 : n }
    private static func pageName(_ index: Int, generation: UInt64) -> String {
        String(format: "page-%04d-g%020llu.json", index, generation)
    }
    private func directory<T>(cohort: UUID?, create: Bool, current: Bool? = nil, _ body: (Int32) throws -> T) throws -> T {
        var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Self.systemIOError() }
        defer { Darwin.close(descriptor) }
        let components = ["ConnectivityDiagnostics"] + ((current ?? usesCurrentNamespace) ? ["CurrentEvidence", "v1"] : [])
            + (cohort.map { ["BacklogEvidence", $0.uuidString.lowercased()] } ?? [])
        for component in components {
            if create, Darwin.mkdirat(descriptor, component, 0o700) != 0, errno != EEXIST { throw Self.systemIOError() }
            let next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard next >= 0 else {
                if errno == ENOENT { throw CocoaError(.fileNoSuchFile) }; throw Self.systemIOError()
            }
            var info = stat()
            guard Darwin.fstat(next, &info) == 0 else { let failure = Self.systemIOError(); Darwin.close(next); throw failure }
            guard info.st_uid == getuid() else { Darwin.close(next); throw Failure.invalid }
            if create {
                guard Darwin.fchmod(next, 0o700) == 0 else { let failure = Self.systemIOError(); Darwin.close(next); throw failure }
            }
            Darwin.close(descriptor); descriptor = next
        }
        return try body(descriptor)
    }
    private func diagnosticEntryExists(_ name: String, current: Bool? = nil) throws -> Bool {
        do {
            return try directory(cohort: nil, create: false, current: current) { directory in
                var info = stat()
                if Darwin.fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
                if errno == ENOENT { return false }; throw Self.systemIOError()
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile { return false }
    }
    private func read(name: String, maximum: Int, cohort: UUID? = nil, current: Bool? = nil) throws -> Data? {
        do {
            return try directory(cohort: cohort, create: false, current: current) { directory in
                let descriptor = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard descriptor >= 0 else { if errno == ENOENT { return nil }; throw Self.systemIOError() }
                defer { Darwin.close(descriptor) }
                var before = stat()
                guard Darwin.fstat(descriptor, &before) == 0 else { throw Self.systemIOError() }
                guard before.st_mode & S_IFMT == S_IFREG,
                      before.st_nlink == 1, before.st_uid == getuid(), before.st_size > 0,
                      before.st_size <= maximum else { throw Failure.invalid }
                var bytes = Data(count: Int(before.st_size))
                try bytes.withUnsafeMutableBytes { raw in
                    guard let address = raw.baseAddress else { throw Failure.invalid }
                    var offset = 0
                    while offset < raw.count {
                        let n = Darwin.read(descriptor, address.advanced(by: offset), raw.count - offset)
                        if n < 0, errno == EINTR { continue }
                        guard n >= 0 else { throw Self.systemIOError() }
                        guard n > 0 else { throw Failure.invalid }; offset += n
                    }
                }
                var after = stat()
                guard Darwin.fstat(descriptor, &after) == 0 else { throw Self.systemIOError() }
                guard before.st_ino == after.st_ino,
                      before.st_dev == after.st_dev, before.st_size == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.invalid }
                return bytes
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile { return nil }
    }
    private func write(_ bytes: Data, name: String, maximum: Int, cohort: UUID? = nil) throws {
        guard !bytes.isEmpty, bytes.count <= maximum else { throw Failure.capacity }
        try directory(cohort: cohort, create: true) { directory in
            var existing = stat()
            if Darwin.fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1,
                      existing.st_uid == getuid() else { throw Failure.invalid }
            } else if errno != ENOENT { throw Self.systemIOError() }
            let temporary = ".backlog-\(UUID().uuidString).tmp"
            let descriptor = Darwin.openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard descriptor >= 0 else { throw Self.systemIOError() }
            defer { Darwin.close(descriptor); Darwin.unlinkat(directory, temporary, 0) }
            #if os(watchOS)
            let diagnosticsURL = root.appendingPathComponent("ConnectivityDiagnostics", isDirectory: true)
            let dirURL = usesCurrentNamespace
                ? diagnosticsURL.appendingPathComponent(Self.currentDirectory, isDirectory: true) : diagnosticsURL
            let target = cohort.map { dirURL.appendingPathComponent("BacklogEvidence", isDirectory: true)
                .appendingPathComponent($0.uuidString.lowercased(), isDirectory: true) } ?? dirURL
            let protected = cohort == nil ? [dirURL, target.appendingPathComponent(temporary)]
                : [dirURL, dirURL.appendingPathComponent("BacklogEvidence", isDirectory: true), target, target.appendingPathComponent(temporary)]
            let namespaceParents = usesCurrentNamespace
                ? [diagnosticsURL, diagnosticsURL.appendingPathComponent("CurrentEvidence", isDirectory: true)] : []
            for url in namespaceParents + protected {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            }
            #endif
            try bytes.withUnsafeBytes { raw in
                guard let address = raw.baseAddress else { throw Failure.invalid }
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(descriptor, address.advanced(by: offset), raw.count - offset)
                    if n < 0, errno == EINTR { continue }
                    guard n >= 0 else { throw Self.systemIOError() }
                    guard n > 0 else { throw Failure.unavailable }; offset += n
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw Self.systemIOError() }
            if name == Self.statusName, cohort == nil { try faultInjector?(.statusPrepared) }
            guard Darwin.renameat(directory, temporary, directory, name) == 0 else { throw Self.systemIOError() }
            if name == Self.summaryName, cohort == nil { try faultInjector?(.summaryRenamed) }
            if name == Self.legacyReferenceName, cohort == nil { try faultInjector?(.legacyReferenceRenamed) }
            if name == Self.currentCohortName, cohort == nil { try faultInjector?(.currentCohortRenamed) }
            guard Darwin.fsync(directory) == 0 else { throw Self.systemIOError() }
        }
    }
    private func remove(name: String, cohort: UUID? = nil) throws {
        try directory(cohort: cohort, create: false) { directory in
            var info = stat()
            if Darwin.fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return }; throw Self.systemIOError()
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid() else { throw Failure.invalid }
            guard Darwin.unlinkat(directory, name, 0) == 0, Darwin.fsync(directory) == 0 else { throw Self.systemIOError() }
        }
    }
    private static func systemIOError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// An independent, bounded WC-only observation. This object has no repository,
/// recording, transfer-policy or library observer reference.
private final class WatchConnectivityMetadata: @unchecked Sendable {
    enum Trigger: String, Codable { case startup, foreground, background, status, reachability,
        activationRequested = "activation_requested", activationCompleted = "activation_completed",
        counterpartChanged = "counterpart_changed", inactive }
    enum StatusOutcome: String, Codable { case received, noReport, staleReport, failed, timeout, unsupported, unavailable, unreachable, cancelled }
    private struct ActivationError: Codable {
        let domain: String
        let code: Int
        let observedAtMS: Int64
    }
    private struct Report: Codable {
        let schemaVersion = 1
        let role = "watch"
        let build: String
        let observedAtMS: Int64
        let uptime: TimeInterval
        let trigger: Trigger
        let activationState: Int
        let reachable: Bool
        let delegateMatches: Bool
        let foreground: Bool
        let companionInstalled: Bool
        let needsUnlockAfterReboot: Bool
        let activationAttemptCount: Int
        let activationRequestedAtMS: Int64?
        let activationCompletedAtMS: Int64?
        let activationInFlight: Bool
        let lastActivationError: ActivationError?
        let statusRequestCount: Int
        let statusReplyCount: Int
        let lastStatusRequestedAtMS: Int64?
        let lastStatusReplyAtMS: Int64?
        let lastStatusOutcome: StatusOutcome?
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "WristRecord.watch.connectivity-metadata", qos: .utility)
    private let directory: URL
    private let build = String((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown").prefix(32))
    private var foreground = false
    private var activationInFlight = false
    private var activationAttemptCount = 0
    private var activationRequestedAtMS: Int64?
    private var activationCompletedAtMS: Int64?
    private var lastAttemptUptime: TimeInterval?
    private var lastActivationError: ActivationError?
    private var statusRequestCount = 0
    private var statusReplyCount = 0
    private var lastStatusRequestedAtMS: Int64?
    private var lastStatusReplyAtMS: Int64?
    private var lastStatusOutcome: StatusOutcome?

    init(root: URL) { directory = root.appendingPathComponent("ConnectivityDiagnostics", isDirectory: true) }

    func setForeground(_ value: Bool, session: WCSession, owner: AnyObject) {
        lock.lock(); defer { lock.unlock() }
        foreground = value
        enqueueLocked(session, owner: owner, trigger: value ? .foreground : .background)
    }

    func observe(_ session: WCSession, owner: AnyObject, trigger: Trigger) {
        lock.lock(); defer { lock.unlock() }
        enqueueLocked(session, owner: owner, trigger: trigger)
    }

    func statusRequested(_ session: WCSession, owner: AnyObject) {
        lock.lock(); defer { lock.unlock() }
        statusRequestCount += 1
        lastStatusRequestedAtMS = Int64(Date().timeIntervalSince1970 * 1_000)
        lastStatusOutcome = nil
        enqueueLocked(session, owner: owner, trigger: .status)
    }

    func statusFinished(_ session: WCSession, owner: AnyObject, outcome: StatusOutcome, receivedReply: Bool) {
        lock.lock(); defer { lock.unlock() }
        lastStatusOutcome = outcome
        if receivedReply {
            statusReplyCount += 1
            lastStatusReplyAtMS = Int64(Date().timeIntervalSince1970 * 1_000)
        }
        enqueueLocked(session, owner: owner, trigger: .status)
    }

    func activationRequested(_ session: WCSession, owner: AnyObject) {
        lock.lock(); defer { lock.unlock() }
        noteActivationRequestLocked(now: ProcessInfo.processInfo.systemUptime)
        enqueueLocked(session, owner: owner, trigger: .activationRequested)
    }

    private func noteActivationRequestLocked(now: TimeInterval) {
        activationInFlight = true
        activationAttemptCount += 1
        activationRequestedAtMS = Int64(Date().timeIntervalSince1970 * 1_000)
        lastAttemptUptime = now
        // The original failure remains visible across a later retry/success.
    }

    func activationCompleted(_ session: WCSession, owner: AnyObject, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        activationInFlight = false
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        activationCompletedAtMS = now
        if let error = error as NSError? {
            lastActivationError = .init(domain: String(error.domain.prefix(128)), code: error.code, observedAtMS: now)
        }
        enqueueLocked(session, owner: owner, trigger: .activationCompleted)
    }

    /// Only a genuine foreground entry may retry a failed initial activation.
    /// Activated-but-unreachable is a normal platform state, never a retry grant.
    func beginForegroundActivation(_ session: WCSession, owner: AnyObject) -> Bool {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        guard foreground, session.activationState == .notActivated, !activationInFlight,
              lastAttemptUptime.map({ now - $0 >= 5 }) ?? true else {
            lock.unlock(); return false
        }
        noteActivationRequestLocked(now: now)
        enqueueLocked(session, owner: owner, trigger: .activationRequested)
        lock.unlock()
        return true
    }

    private func enqueueLocked(_ session: WCSession, owner: AnyObject, trigger: Trigger) {
        let report = Report(build: build, observedAtMS: Int64(Date().timeIntervalSince1970 * 1_000),
            uptime: ProcessInfo.processInfo.systemUptime, trigger: trigger,
            activationState: session.activationState.rawValue, reachable: session.isReachable,
            delegateMatches: session.delegate === owner, foreground: foreground,
            companionInstalled: session.isCompanionAppInstalled,
            needsUnlockAfterReboot: session.iOSDeviceNeedsUnlockAfterRebootForReachability,
            activationAttemptCount: activationAttemptCount,
            activationRequestedAtMS: activationRequestedAtMS, activationCompletedAtMS: activationCompletedAtMS,
            activationInFlight: activationInFlight, lastActivationError: lastActivationError,
            statusRequestCount: statusRequestCount, statusReplyCount: statusReplyCount,
            lastStatusRequestedAtMS: lastStatusRequestedAtMS, lastStatusReplyAtMS: lastStatusReplyAtMS,
            lastStatusOutcome: lastStatusOutcome)
        // Enqueue under the short lock so a later callback cannot overwrite a
        // newer observation with an older report. No lock crosses I/O or WC send.
        queue.async { [directory] in
            guard let data = try? JSONEncoder().encode(report), data.count <= 4_096 else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let target = directory.appendingPathComponent("watch.json")
                try data.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            } catch {
                // Metadata failure must never enter library events or start sync.
            }
        }
    }
}
