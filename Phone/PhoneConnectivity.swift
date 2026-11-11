import Foundation
import CoreFoundation
import Darwin
import Darwin
import RecordingCore
import WatchConnectivity

/// Fault boundaries for the two small scheduling metadata files, never audio or ACK state.
enum PhoneBacklogPersistencePoint: Sendable {
    case beforeEvidenceWrite(Bool)
    case afterEvidenceWriteBeforeSynchronization(Bool)
    case beforeSnapshotWrite
    case afterSnapshotWriteBeforeSynchronization
}

private struct PhoneWatchBacklogEvidence: Codable, Equatable {
    var schemaVersion = 1
    var hasBacklog: Bool
    var observedAt: Date?
}

private enum PhoneWatchBacklogEvidenceError: Error {
    case invalidRecord
}

struct PhoneConnectionState: Sendable {
    var supported = WCSession.isSupported()
    var activated = false
    var paired = false
    var watchAppInstalled = false
    var reachable = false
    var snapshot: RecorderSnapshot?
    var lastError: String?
}

struct PhoneBackgroundMaintenanceResult: Sendable {
    let succeeded: Bool
    let needsMore: Bool
}

enum PhoneStatusRequestResult: Sendable {
    case received(RecorderSnapshot)
    case unsupportedWatchVersion
    case noReport
    case staleReport
    case waitingForConnection
    case connectionStarting
    case unsupported
    case watchNotPaired
    case watchAppMissing
    case timedOut
    case failed

    var message: String {
        switch self {
        case .received: return "已收到手表录音状态。"
        case .unsupportedWatchVersion: return "当前手表版本不支持只读状态查询。请在手表 App 查看当前状态。"
        case .noReport: return "手表尚无可用的录音状态报告。请在手表 App 查看当前状态。"
        case .staleReport: return "手表返回的是上次报告，尚未收到当前状态。请在手表 App 核对。"
        case .waitingForConnection: return "暂时无法联系手表。"
        case .connectionStarting: return "正在建立手表连接，请稍后重试。"
        case .unsupported: return "当前设备不支持 Apple Watch 状态查询。"
        case .watchNotPaired: return "请先在这台 iPhone 上配对 Apple Watch。"
        case .watchAppMissing: return "请先在配对的 Apple Watch 上安装 Record for Agent。"
        case .timedOut: return "暂未收到状态更新。请打开手表 App，确认当前录音状态。"
        case .failed: return "暂时无法读取手表状态，请稍后重试。"
        }
    }

    var isError: Bool {
        if case .received = self { return false }
        return true
    }
}

enum PhoneSyncRequestResult: Sendable {
    case receivedByWatch
    case waitingForConnection
    case connectionStarting
    case unsupported
    case watchNotPaired
    case watchAppMissing
    case failed(String)

    var message: String {
        switch self {
        case .receivedByWatch: return "手表已收到同步请求。录音保存到手机后会出现在下方。"
        case .waitingForConnection: return "暂时无法即时联系手表。补传请求和保存确认会在后台连接恢复后继续处理。"
        case .connectionStarting: return "正在建立手表连接，请稍后再试。"
        case .unsupported: return "当前设备不支持 Apple Watch 同步。"
        case .watchNotPaired: return "请先在这台 iPhone 上配对 Apple Watch。"
        case .watchAppMissing: return "请先在配对的 Apple Watch 上安装 Record for Agent。"
        case .failed: return "暂未联系到手表，已保存的录音仍保留，后台补传会继续重试。"
        }
    }

    var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The callback synchronously takes durable ownership of each incoming file.
/// Decoding, repository commits and receipt replay then run one item at a time,
/// so old receipts cannot hold up WatchConnectivity's temporary file callback.
final class PhoneConnectivity: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let repository: RecordingRepository
    private let snapshotURL: URL
    private let watchBacklogURL: URL
    private let backlogFaultInjector: (@Sendable (PhoneBacklogPersistencePoint) throws -> Void)?
    private let inbox: IncomingTransferInbox
    private let replayCursorURL: URL
    private let replayPendingURL: URL
    private let replayDiscoveryURL: URL
    private let targetedPendingURL: URL
    private let work = DispatchQueue(label: "WristRecord.phone.connectivity", qos: .utility)
    private var state = PhoneConnectionState()
    private var watchBacklogEvidence = PhoneWatchBacklogEvidence(hasBacklog: false, observedAt: nil)
    private var persistedWatchBacklogEvidence: PhoneWatchBacklogEvidence?
    private var lastAcceptedWatchObservationAt: Date?
    private var watchBacklogReadUncertain = false
    private var watchBacklogStorageFailed = false
    private var pendingWatchBacklogDiagnostic: String?
    private var loggedConnectionFlags: ConnectionFlags?
    private var session: WCSession?
    #if os(iOS)
    private var pendingContentObservation: NSKeyValueObservation?
    #endif
    private let connectivityMetadata: PhoneConnectivityMetadata
    private let receiptEvidence: PhoneReceiptEvidence
    private let transferProgressMetadata: PhoneTransferProgressMetadata
    private let transferPhaseDiagnostics: PhoneTransferPhaseDiagnostics
    private let automaticSyncControl: PhoneAutomaticSyncControl
    private let statusDiagnostics: PhoneStatusDiagnostics
    private var receiptReplayPolicy = ReceiptReplayPolicy()
    private var receiptMaintenancePolicy = PhoneReceiptMaintenancePolicy()
    private var maintenanceLease: PhoneBackgroundLease?
    private var incomingCallbackLeases: [PhoneIncomingCallbackLease] = []
    private var maintenanceStarting = false
    private var maintenanceStartingFromIncoming = false
    private var maintenanceGeneration = 0
    private var maintenanceCallbacks: [@Sendable (PhoneBackgroundMaintenanceResult) -> Void] = []
    private var maintenanceCancellations: [PhoneBackgroundCancellation] = []
    private var incomingIDs: [UUID] = []
    private var incomingAttempted = Set<UUID>()
    private var replayIDs: [UUID] = []
    private var replayRequested = false
    private var replayLoaded = false
    private var replayDiscoveryForced = false
    private var lastReplayDiscoveryAt: Date?
    private var historicalReplayWorked = false
    private var replayCursor: UUID?
    private var receiptQueueContinuationRequested = false
    private static let historicalReceiptQueueLimit = 8
    private static let maximumReceiptMetadataBytes = 4_096
    private var targetedRequests: [TargetedReceiptRequest] = []
    private let targetedQueueLimit = 32
    private var maintenanceFailed = false
    private var notifyScheduled = false
    private var receiptFailureSamples: [String] = []
    private var receiptFailureCount = 0
    private var receiptFailureFlushScheduled = false
    private var manualSyncRequestID: UUID?
    private var statusRequestID: UUID?
    private let statusCancellationLock = NSLock()
    private var statusCancellation: PhoneBackgroundCancellation?
    private var statusDiagnosticAttemptID: UUID?
    var onUpdate: (@Sendable () -> Void)?
    var onNeedsBackgroundMaintenance: (@Sendable () -> Void)?
    /// WC availability only. This callback never waits for receipt/library work.
    var onStatusReachabilityChanged: (@Sendable (Bool) -> Void)?

    init(repository: RecordingRepository, root: URL,
         backlogFaultInjector: (@Sendable (PhoneBacklogPersistencePoint) throws -> Void)? = nil) throws {
        self.repository = repository
        self.connectivityMetadata = PhoneConnectivityMetadata(root: root)
        self.receiptEvidence = PhoneReceiptEvidence(repository: repository, root: root)
        self.transferProgressMetadata = PhoneTransferProgressMetadata(root: root)
        self.transferPhaseDiagnostics = PhoneTransferPhaseDiagnostics(root: root)
        self.automaticSyncControl = PhoneAutomaticSyncControl(root: root)
        self.statusDiagnostics = PhoneStatusDiagnostics(root: root)
        self.snapshotURL = root.appendingPathComponent("phone-watch-snapshot.json")
        self.watchBacklogURL = root.appendingPathComponent("phone-watch-backlog-evidence.json")
        self.backlogFaultInjector = backlogFaultInjector
        self.replayCursorURL = root.appendingPathComponent("receipt-replay-cursor.json")
        self.replayPendingURL = root.appendingPathComponent("receipt-replay-pending.json")
        self.replayDiscoveryURL = root.appendingPathComponent("receipt-replay-discovery.json")
        self.targetedPendingURL = root.appendingPathComponent("targeted-receipt-pending.json")
        self.inbox = try IncomingTransferInbox(root: root.appendingPathComponent("incoming-transfers", isDirectory: true))
        if let data = try? Data(contentsOf: replayCursorURL) {
            self.replayCursor = try? TransportCodec.decode(UUID.self, from: data)
        }
        super.init()
        if let size = try? replayDiscoveryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= 128, let data = try? Data(contentsOf: replayDiscoveryURL),
           let date = try? TransportCodec.decode(Date.self, from: data),
           date.timeIntervalSince1970.isFinite {
            lastReplayDiscoveryAt = date
        }
        if FileManager.default.fileExists(atPath: replayPendingURL.path) {
            do {
                replayIDs = try TransportCodec.decode([UUID].self, from: Data(contentsOf: replayPendingURL))
            } catch {
                // This is scheduling state only, never integrity or ACK authority.
                // Reconstruct a fresh sweep rather than trust malformed progress.
                state.lastError = "上次回执补发进度读取失败，将重新核对持久回执。"
            }
        }
        if FileManager.default.fileExists(atPath: targetedPendingURL.path) {
            do {
                let pending = try TransportCodec.decode([TargetedReceiptRequest].self,
                    from: Data(contentsOf: targetedPendingURL))
                var seen = Set<UUID>()
                targetedRequests = Array(pending.filter { seen.insert($0.segmentID).inserted }
                    .prefix(targetedQueueLimit))
            } catch {
                // Scheduling state is not ACK authority. Watch can request again.
                state.lastError = "上次定向回执请求读取失败，等待手表重新请求。"
            }
        }
        if FileManager.default.fileExists(atPath: snapshotURL.path) {
            do {
                state.snapshot = try TransportCodec.decode(RecorderSnapshot.self, from: Data(contentsOf: snapshotURL))
            } catch {
                state.lastError = "上次手表状态读取失败：\(error.localizedDescription)"
                // Before the first ledger migration, this may be the only
                // durable positive source. An unknown zero cannot replace it.
                watchBacklogReadUncertain = true
                watchBacklogStorageFailed = true
                pendingWatchBacklogDiagnostic = backlogFailureDescription(error, operation: "restore_snapshot")
            }
        }
        restoreWatchBacklogEvidence()
    }

    func start() {
        receiptEvidence.start()
        work.async { [self] in
            guard WCSession.isSupported() else { notify(); return }
            let connection = WCSession.default
            session = connection
            connection.delegate = self
            #if os(iOS)
            pendingContentObservation = connection.observe(\.hasContentPending, options: [.new]) { [weak self] session, _ in
                self?.transferProgressMetadata.observePendingContent(session)
            }
            #endif
            transferProgressMetadata.observePendingContent(connection)
            connectivityMetadata.observe(connection, owner: self, trigger: .startup)
            connectivityMetadata.activationRequested(connection, owner: self)
            connection.activate()
            if let diagnostic = pendingWatchBacklogDiagnostic {
                pendingWatchBacklogDiagnostic = nil
                recordEvent(kind: "phone.watch_backlog_evidence_failed", detail: diagnostic)
            }
        }
    }

    func currentState() -> PhoneConnectionState { work.sync { state } }

    /// Already observed phone-side query metadata only; no WC, library or disk read.
    func statusDiagnosticSnapshot() -> PhoneStatusDiagnosticSnapshot { statusDiagnostics.snapshot() }

    private func statusDiagnosticConnection(_ session: WCSession) -> PhoneStatusDiagnosticSnapshot.Connection {
        .init(activated: session.activationState == .activated, paired: session.isPaired,
              watchInstalled: session.isWatchAppInstalled, reachable: session.isReachable)
    }

    /// Observe only current WC flags; arming recovery must not depend on reload
    /// or miss a reachability callback delivered just before the query ended.
    func observeStatusAvailability() {
        guard WCSession.isSupported() else { onStatusReachabilityChanged?(false); return }
        publishStatusAvailability(WCSession.default)
    }

    func statusConnectionIsAvailable() -> Bool {
        guard WCSession.isSupported() else { return false }
        return statusConnectionIsAvailable(WCSession.default)
    }

    private func statusConnectionIsAvailable(_ session: WCSession) -> Bool {
        session.activationState == .activated && session.isPaired
            && session.isWatchAppInstalled && session.isReachable
    }

    private func publishStatusAvailability(_ session: WCSession) {
        onStatusReachabilityChanged?(statusConnectionIsAvailable(session))
    }

    /// Platform metadata only; use the existing serial event writer without
    /// making UIKit callbacks wait for repository work.
    func recordBackgroundDiagnostic(kind: String, detail: String) {
        transferProgressMetadata.backgroundSchedulerEvent(kind, detail: detail)
        work.async { [self] in
            recordEvent(kind: kind, detail: String(detail.prefix(768)))
        }
    }

    /// Lifecycle observation only. Cold background launches can supply their
    /// actual state without replaying ACKs, sending control or validating files.
    func observeApplicationForeground(_ foreground: Bool) {
        receiptEvidence.setForeground(foreground)
        let session = WCSession.isSupported() ? WCSession.default : nil
        transferProgressMetadata.setForeground(foreground, session: session)
        if let session {
            connectivityMetadata.setForeground(foreground, session: session, owner: self)
        }
    }

    /// Pure metadata observation; it never replays receipts or starts transfer work.
    func observeVerifiedMetadata(onThrottle: (@Sendable (Int) -> Void)? = nil) { receiptEvidence.observeVerifiedMetadata(onThrottle: onThrottle) }

    func appDidBecomeActive() {
        observeApplicationForeground(true)
        work.async { [self] in
            retrySessionActivationIfNeeded()
            updateConnectionState()
            resendReceipts(trigger: "app_active")
            requestWatchSync()
            notify()
        }
    }

    func requestSync(completion: @escaping @Sendable (PhoneSyncRequestResult) -> Void) {
        work.async { [self] in
            // A new explicit attempt replaces a stale transport error. Any new
            // failure is still recorded by the normal diagnostics path.
            state.lastError = nil
            let requestID = UUID()
            manualSyncRequestID = requestID
            updateConnectionState()
            // Send the interactive request before potentially expensive historical
            // audio verification in ACK replay. Replay still runs on every exit.
            defer {
                resendReceipts(trigger: "manual")
                requestWatchSync(sendImmediate: false)
            }
            guard let session else {
                completion(WCSession.isSupported() ? .connectionStarting : .unsupported)
                notify()
                return
            }
            guard session.activationState == .activated else {
                completion(.connectionStarting); notify(); return
            }
            guard session.isPaired else {
                completion(.watchNotPaired); notify(); return
            }
            guard session.isWatchAppInstalled else {
                completion(.watchAppMissing); notify(); return
            }
            guard session.isReachable else {
                completion(.waitingForConnection); notify(); return
            }
            session.sendMessage([TransportCodec.requestSyncKey: true], replyHandler: { reply in
                // This acknowledges the request only, never the recording files.
                completion(reply["requestReceived"] as? Bool == true
                    ? .receivedByWatch : .failed("手表未确认收到同步请求。"))
            }, errorHandler: { [weak self] error in
                let description = error.localizedDescription
                self?.work.async { [weak self] in
                    guard let self else { return }
                    if self.manualSyncRequestID == requestID {
                        self.recordTransportFailure("请求手表同步失败：", error: error)
                    } else {
                        self.recordEvent(kind: "phone.old_sync_request_failed", detail: description)
                    }
                }
                completion(.failed(description))
            })
            notify()
        }
    }

    /// Interactive metadata query only. In particular, neither a legacy ACK nor
    /// an unrelated application context can turn this into synchronization.
    func requestStatus(intentID: UUID? = nil, attemptID: UUID? = nil, isRecoveryRetry: Bool = false,
                       completion: @escaping @Sendable (PhoneStatusRequestResult) -> Void) {
        let cancellation = PhoneBackgroundCancellation()
        let queryIntentID = intentID ?? UUID()
        let queryAttemptID = attemptID ?? UUID()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let waitUntil = startedAt + 7
        let deadline = startedAt + 8
        connectivityMetadata.statusRequested(WCSession.default, owner: self,
            trigger: isRecoveryRetry ? .recovery : .manual)
        statusCancellationLock.lock()
        statusCancellation?.cancel()
        statusCancellation = cancellation
        statusDiagnosticAttemptID = queryAttemptID
        statusDiagnostics.begin(intentID: queryIntentID, attemptID: queryAttemptID,
            recovery: isRecoveryRetry, connection: statusDiagnosticConnection(WCSession.default))
        statusCancellationLock.unlock()
        work.async { [self] in
            guard !cancellation.isCancelled else { return }
            statusDiagnostics.stage(.workerStarted, attemptID: queryAttemptID)
            guard let session else {
                statusDiagnostics.terminal(attemptID: queryAttemptID,
                    outcome: WCSession.isSupported() ? .unavailable : .unsupported)
                completion(WCSession.isSupported() ? .connectionStarting : .unsupported); return
            }
            let requestID = queryAttemptID
            statusRequestID = requestID
            let finish: @Sendable (PhoneStatusRequestResult) -> Void = { [weak self] result in
                guard let self, !cancellation.isCancelled, self.statusRequestID == requestID else { return }
                self.statusRequestID = nil
                cancellation.cancel()
                let outcome: PhoneConnectivityMetadata.StatusOutcome
                let receivedReply: Bool
                switch result {
                case .received: outcome = .received; receivedReply = true
                case .noReport: outcome = .noReport; receivedReply = true
                case .staleReport: outcome = .staleReport; receivedReply = true
                case .timedOut: outcome = .timeout; receivedReply = false
                case .unsupportedWatchVersion: outcome = .unsupported; receivedReply = false
                case .waitingForConnection: outcome = .unreachable; receivedReply = false
                case .failed: outcome = .failed; receivedReply = false
                default: outcome = .unavailable; receivedReply = false
                }
                self.statusDiagnostics.terminal(attemptID: requestID,
                    outcome: PhoneStatusDiagnosticOutcome(rawValue: outcome.rawValue) ?? .unavailable,
                    connection: self.statusDiagnosticConnection(session))
                self.connectivityMetadata.statusFinished(session, owner: self, outcome: outcome, receivedReply: receivedReply)
                completion(result)
            }
            @Sendable func attemptSend() {
                guard !cancellation.isCancelled, statusRequestID == requestID else { return }
                guard ProcessInfo.processInfo.systemUptime < deadline else { finish(.timedOut); return }
                state.activated = session.activationState == .activated
                state.paired = session.isPaired
                state.watchAppInstalled = session.isWatchAppInstalled
                state.reachable = state.activated && session.isReachable
                guard state.activated else { finish(.connectionStarting); return }
                guard state.paired else { finish(.watchNotPaired); return }
                guard state.watchAppInstalled else { finish(.watchAppMissing); return }
                guard state.reachable else {
                    guard ProcessInfo.processInfo.systemUptime < waitUntil else {
                        finish(.waitingForConnection); return
                    }
                    // A short interactive reachability grace stays inside the
                    // original UI deadline. Never enqueue sync or deferred WC work.
                    work.asyncAfter(deadline: .now() + 0.2) { attemptSend() }
                    return
                }
                connectivityMetadata.observe(session, owner: self, trigger: .status)
                guard let data = try? TransportCodec.encode(RecorderStatusRequest(requestID: requestID)) else {
                    finish(.failed); return
                }
                guard !cancellation.isCancelled else { return }
                session.sendMessage([TransportCodec.statusRequestKey: data], replyHandler: { [weak self] reply in
                    self?.work.async { [weak self] in
                        guard let self, !cancellation.isCancelled, self.statusRequestID == requestID else { return }
                        guard ProcessInfo.processInfo.systemUptime < deadline else { finish(.timedOut); return }
                        guard let data = reply[TransportCodec.statusResponseKey] as? Data else {
                            finish(.unsupportedWatchVersion); return
                        }
                        guard reply.count == 1, data.count <= 16_384,
                              let response = try? TransportCodec.decode(RecorderStatusResponse.self, from: data),
                              response.schemaVersion == 1, response.requestID == requestID else {
                            finish(.failed); return
                        }
                        guard let snapshot = response.snapshot else { finish(.noReport); return }
                        guard snapshot.pendingCount >= 0, !snapshot.isStale(),
                              self.state.snapshot.map({ snapshot.observedAt >= $0.observedAt }) ?? true else {
                            finish(.staleReport); return
                        }
                        // Only a validated, request-bound current reply clears
                        // the old connection error. Ordinary snapshots cannot.
                        self.statusDiagnostics.stage(.validated, attemptID: requestID,
                                                     connection: self.statusDiagnosticConnection(session))
                        self.state.lastError = nil
                        self.state.snapshot = snapshot
                        finish(.received(snapshot))
                    }
                }, errorHandler: { [weak self] error in
                    self?.work.async { [weak self] in
                        guard let self, !cancellation.isCancelled, self.statusRequestID == requestID else { return }
                        let native = error as NSError
                        self.statusDiagnostics.terminal(attemptID: requestID, outcome: .failed,
                            connection: self.statusDiagnosticConnection(session),
                            error: .init(domain: native.domain == "WCErrorDomain" ? .watchConnectivity : .other, code: native.code))
                        finish(.failed)
                    }
                })
                // This records that the API invocation returned, not remote
                // delivery. Reply handlers enter the same serial worker later.
                statusDiagnostics.stage(.sent, attemptID: requestID, connection: statusDiagnosticConnection(session))
            }
            work.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime)) {
                finish(.timedOut)
            }
            attemptSend()
        }
    }

    func cancelStatusRequest(diagnosticOutcome: PhoneStatusDiagnosticOutcome = .cancelled) {
        // Do not queue this behind receipt validation: cancellation must stop a
        // not-yet-sent query even when the connectivity worker is blocked.
        statusCancellationLock.lock()
        statusCancellation?.cancel()
        statusCancellation = nil
        if let attemptID = statusDiagnosticAttemptID {
            statusDiagnostics.terminal(attemptID: attemptID, outcome: diagnosticOutcome)
        }
        statusDiagnosticAttemptID = nil
        statusCancellationLock.unlock()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // Observe actual delegate entry before any assertion or MainActor hop.
        let delegateEnteredAt = Date()
        transferProgressMetadata.incomingCallbackEvent("started")
        // The OS deletes its URL when this callback returns. Only independent
        // diagnostic/inbox locks are taken here, never repository/history locks.
        let callbackLease = PhoneIncomingCallbackLease.begin()
        var observedManifest: SegmentManifest?
        do {
            guard let data = file.metadata?[TransportCodec.manifestKey] as? Data else {
                throw ReceiveError.missingManifest
            }
            let manifest = try TransportCodec.decode(SegmentManifest.self, from: data)
            observedManifest = manifest
            transferPhaseDiagnostics.recordDelegateEntered(manifest: manifest, at: delegateEnteredAt)
            let id = try inbox.stage(fileURL: file.fileURL, manifest: manifest)
            transferPhaseDiagnostics.recordStaged(manifest: manifest, at: Date())
            transferProgressMetadata.incomingCallbackEvent("staged")
            // The old BG result may already be queued on MainActor. Mark real
            // new work before dispatching the maintenance request there.
            PhoneBackgroundSync.noteNewWork()
            work.async { [self] in
                // Preserve arrival order when a background grant can import only part of a burst.
                if !incomingIDs.contains(id) { incomingIDs.append(id) }
                recordEvent(kind: "phone.incoming_staged",
                            detail: "segment=\(manifest.id.uuidString) transfer=\(id.uuidString) awaiting_validation=true",
                            sessionID: manifest.sessionID)
                scheduleMaintenance(trigger: "file_received", includeReceipts: false,
                    incomingCallbackLease: callbackLease)
            }
        } catch {
            if observedManifest == nil {
                transferPhaseDiagnostics.recordDelegateEntered(manifest: nil, at: delegateEnteredAt)
            }
            transferProgressMetadata.incomingCallbackEvent("stage_failed")
            callbackLease.end()
            let message = error.localizedDescription
            work.async { [self] in recordFailure("接管音频失败，未发送确认，手表保留原件：\(message)") }
        }
    }

    func performBackgroundMaintenance(cancellation: PhoneBackgroundCancellation,
                                      completion: @escaping @Sendable (Bool) -> Void) {
        performBackgroundMaintenance(cancellation: cancellation, resultCompletion: {
            completion($0.succeeded && !$0.needsMore)
        })
    }

    func performBackgroundMaintenance(cancellation: PhoneBackgroundCancellation,
                                      resultCompletion: @escaping @Sendable (PhoneBackgroundMaintenanceResult) -> Void) {
        work.async { [self] in
            guard !cancellation.isCancelled else {
                resultCompletion(.init(succeeded: false, needsMore: true)); return
            }
            retrySessionActivationIfNeeded()
            maintenanceCallbacks.append(resultCompletion)
            maintenanceCancellations.append(cancellation)
            scheduleMaintenance(trigger: "background_task", includeReceipts: true)
            requestWatchSync()
        }
    }

    func appDidEnterBackground() {
        observeApplicationForeground(false)
        work.async { [self] in
            scheduleMaintenance(trigger: "app_background", includeReceipts: true)
            requestWatchSync()
        }
    }

    /// A foreground entry or a system maintenance grant can recover a failed
    /// activation. An in-flight activation or inactive paired session is owned
    /// by WatchConnectivity and does not need another request.
    private func retrySessionActivationIfNeeded() {
        guard let session, connectivityMetadata.beginActivationRetry(session, owner: self) else { return }
        transferProgressMetadata.activationRetried()
        session.activate()
    }

    func expireBackgroundMaintenance() {
        work.async { [self] in
            maintenanceLease?.expire()
            finishMaintenance(completed: false)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        work.async { [self] in receive(applicationContext) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        work.async { [self] in receive(userInfo) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        work.async { [self] in receive(message) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        // Only transport acknowledgement. Never a substitute for SegmentReceipt.
        replyHandler([:])
        work.async { [self] in receive(message) }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        connectivityMetadata.activationCompleted(session, owner: self, activationState: activationState, error: error)
        transferProgressMetadata.activationCompleted(session, failed: error != nil)
        publishStatusAvailability(session)
        work.async { [self] in
            updateConnectionState()
            if let error { recordTransportFailure("手表连接激活失败：", error: error) }
            receive(session.receivedApplicationContext)
            resendReceipts(trigger: "activation")
            requestWatchSync()
            notify()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        connectivityMetadata.observe(session, owner: self, trigger: .reachability)
        publishStatusAvailability(session)
        work.async { [self] in
            updateConnectionState()
            if session.isReachable {
                resendReceipts(trigger: "reachable")
                requestWatchSync()
            }
            notify()
        }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        connectivityMetadata.observe(session, owner: self, trigger: .counterpartChanged)
        publishStatusAvailability(session)
        work.async { [self] in
            updateConnectionState()
            if state.activated && state.paired && state.watchAppInstalled {
                resendReceipts(trigger: "watch_state")
                requestWatchSync()
            }
            notify()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        connectivityMetadata.observe(session, owner: self, trigger: .inactive)
        publishStatusAvailability(session)
        work.async { [self] in updateConnectionState(); notify() }
    }

    func sessionDidDeactivate(_ session: WCSession) {
        connectivityMetadata.activationRequested(session, owner: self)
        session.activate()
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        let receipt = Self.queuedReceipt(in: userInfoTransfer.userInfo)
        let isControl = receipt == nil && userInfoTransfer.userInfo[TransportCodec.requestSyncKey] as? Bool == true
        if isControl, error != nil { PhoneBackgroundSync.noteNewWork() }
        work.async { [self] in
            updateConnectionState()
            if let receipt {
                transferProgressMetadata.nativeReceiptCompleted(receipt, succeeded: error == nil)
                if let error {
                    recordReceiptFailure(receipt, channel: "background", error: error)
                    // A failed native attempt is not an immediate replay wake.
                    // Keep the existing finite sweep for a later system grant.
                    if !replayIDs.isEmpty { onNeedsBackgroundMaintenance?() }
                } else {
                    // OS delivery completion is not proof of Watch's durable ACK.
                    recordEvent(kind: "phone.ack_background_completed",
                                detail: "segment=\(receipt.segmentID.uuidString) channel=background transport_completed=true")
                    // Continue only an unfinished, already captured sweep. An
                    // empty sweep must not enumerate all receipts again for
                    // every successful native callback and create an ACK loop.
                    if !replayIDs.isEmpty {
                        receiptQueueContinuationRequested = true
                        scheduleMaintenance(trigger: "receipt_queue_available", includeReceipts: true)
                    }
                }
            } else if isControl {
                let id = (userInfoTransfer.userInfo["automaticSyncRequestID"] as? String).flatMap(UUID.init(uuidString:))
                transferProgressMetadata.controlEvent(error == nil ? .nativeCompleted : .nativeFailed, requestID: id)
                do { try automaticSyncControl.nativeCompleted(requestID: id, failed: error != nil,
                    payload: userInfoTransfer.userInfo) }
                catch {
                    transferProgressMetadata.controlEvent(.stateFailed, requestID: id)
                    transferProgressMetadata.controlError(error)
                }
                transferProgressMetadata.controlRetryPending(automaticSyncControl.needsRetry)
                if let error {
                    transferProgressMetadata.controlError(error)
                    recordTransportFailure("后台同步请求暂未送达，将在后续后台机会重试：", error: error)
                }
                if automaticSyncControl.needsRetry { onNeedsBackgroundMaintenance?() }
            } else if let error {
                recordTransportFailure("后台消息发送失败，回执仍已保留：", error: error)
            }
        }
    }

    private func receive(_ payload: [String: Any]) {
        if let data = payload[TransportCodec.watchRuntimeKey] as? Data {
            // Separate from recording state and ACKs; receipt time cannot make
            // a stale source report fresh or start library maintenance.
            transferPhaseDiagnostics.recordWatchRuntime(data)
            if payload.count == 1 { return }
        }
        if let data = payload[TransportCodec.snapshotKey] as? Data {
            do {
                let incoming = try TransportCodec.decode(RecorderSnapshot.self, from: data)
                acceptWatchSnapshot(incoming, data: data)
            } catch { recordFailure("手表状态保存失败：\(error.localizedDescription)") }
        }
        if let data = payload[TransportCodec.eventsKey] as? Data {
            do {
                for event in try TransportCodec.decode([RecordingEvent].self, from: data) {
                    if event.kind.hasPrefix("watch.transfer_") {
                        // New transfer observations belong only to the bounded,
                        // strictly decoded projection. Replays must not create
                        // permanent UUID journal files, even for malformed or
                        // future unknown transfer diagnostics.
                        transferPhaseDiagnostics.recordWatchEvent(event)
                    } else {
                        try repository.appendEvent(event) // Preserve legacy durable event semantics.
                    }
                }
            } catch { recordFailure("手表日志保存失败：\(error.localizedDescription)") }
        }
        switch PhoneReceiptMaintenancePolicy.request(
            targetedKeyPresent: payload.keys.contains(TransportCodec.targetedReceiptRequestKey),
            targetedData: payload[TransportCodec.targetedReceiptRequestKey] as? Data,
            legacyRequested: payload[TransportCodec.requestSyncKey] as? Bool == true) {
        case .targeted(let request):
            if let index = targetedRequests.firstIndex(where: { $0.segmentID == request.segmentID }) {
                targetedRequests[index] = request
            } else if targetedRequests.count < targetedQueueLimit {
                targetedRequests.append(request)
            } else {
                recordEvent(kind: "phone.targeted_receipt_deferred", detail: "reason=queue_full")
                break
            }
            PhoneBackgroundSync.noteNewWork()
            persistTargetedRequests()
            scheduleMaintenance(trigger: "targeted_receipt", includeReceipts: false)
        case .legacy:
            PhoneBackgroundSync.noteNewWork()
            resendReceipts(trigger: "watch_request")
        case .invalidTargeted:
            recordEvent(kind: "phone.targeted_receipt_rejected", detail: "reason=invalid_request")
        case .none:
            break
        }
        updateConnectionState()
        notify()
    }

    private func restoreWatchBacklogEvidence() {
        if FileManager.default.fileExists(atPath: watchBacklogURL.path) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: watchBacklogURL.path)
                guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4_096 else {
                    throw PhoneWatchBacklogEvidenceError.invalidRecord
                }
                let evidence = try TransportCodec.decode(PhoneWatchBacklogEvidence.self,
                    from: Data(contentsOf: watchBacklogURL))
                guard evidence.schemaVersion == 1,
                      !evidence.hasBacklog || evidence.observedAt != nil,
                      evidence.observedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
                    throw PhoneWatchBacklogEvidenceError.invalidRecord
                }
                watchBacklogEvidence = evidence
                persistedWatchBacklogEvidence = evidence
                // This ledger may predate a newer positive snapshot backup
                // whose separate ledger write failed. Reading it cannot resolve
                // an unreadable snapshot; only a successfully persisted positive
                // or known-zero report can repair that existing uncertainty.
            } catch {
                watchBacklogReadUncertain = true
                watchBacklogStorageFailed = true
                pendingWatchBacklogDiagnostic = backlogFailureDescription(error, operation: "restore")
                state.lastError = "上次手表积压依据暂未读取，不能确认后台维护已清空。"
            }
        }
        if let snapshot = state.snapshot, snapshot.pendingCount > 0 {
            // Legacy snapshots are the only durable positive evidence in an
            // existing installation. Save it before unknown zero can replace it.
            let observedAt = max(snapshot.observedAt, watchBacklogEvidence.observedAt ?? .distantPast)
            watchBacklogEvidence = .init(hasBacklog: true, observedAt: observedAt)
            do {
                try persistWatchBacklogEvidence(watchBacklogEvidence)
                watchBacklogStorageFailed = false
            } catch {
                watchBacklogStorageFailed = true
                pendingWatchBacklogDiagnostic = backlogFailureDescription(error, operation: "migrate")
                state.lastError = "手表积压依据暂未保存，原有正数报告已保留。"
            }
        }
        // A positive evidence commit may precede its display-snapshot commit.
        // Retain its ordering watermark across that crash/failure boundary.
        lastAcceptedWatchObservationAt = [state.snapshot?.observedAt, watchBacklogEvidence.observedAt]
            .compactMap { $0 }.max()
    }

    private func acceptWatchSnapshot(_ incoming: RecorderSnapshot, data: Data) {
        guard lastAcceptedWatchObservationAt.map({ incoming.observedAt >= $0 }) ?? true else { return }
        lastAcceptedWatchObservationAt = incoming.observedAt
        let positive = incoming.pendingCount > 0
        let clearsBacklog = incoming.pendingCountIsKnown && incoming.pendingCount == 0
        if positive {
            PhoneBackgroundSync.noteNewWork()
            watchBacklogEvidence = .init(hasBacklog: true, observedAt: incoming.observedAt)
        }
        // The notification follows the generation change even if persistence
        // fails; no unknown zero creates new work or requests an empty loop.
        defer { if positive { onNeedsBackgroundMaintenance?() } }
        var snapshotDurable = false
        do {
            if watchBacklogReadUncertain && !positive && !clearsBacklog {
                throw PhoneWatchBacklogEvidenceError.invalidRecord
            }
            if positive || (!clearsBacklog && watchBacklogEvidence.hasBacklog) {
                try persistWatchBacklogEvidence(watchBacklogEvidence)
            }
            // Keep observation time unchanged. Synchronizing the known-zero
            // source before clearing the hint makes both crash orders safe.
            try persistWatchSnapshot(data)
            snapshotDurable = true
            state.snapshot = incoming
            if clearsBacklog {
                let cleared = PhoneWatchBacklogEvidence(hasBacklog: false, observedAt: incoming.observedAt)
                try persistWatchBacklogEvidence(cleared)
                watchBacklogEvidence = cleared
            }
            watchBacklogStorageFailed = watchBacklogReadUncertain
        } catch {
            if positive, !snapshotDurable {
                // A separate evidence-path failure must not discard a usable
                // positive display snapshot, which startup can migrate again.
                do {
                    try persistWatchSnapshot(data)
                    snapshotDurable = true
                    state.snapshot = incoming
                } catch { /* The diagnostic below makes no durable-storage claim. */ }
            }
            if clearsBacklog, watchBacklogEvidence.hasBacklog {
                // An atomic replacement can be visible before its fsync fails.
                // Restore the last positive record when possible, without ever
                // treating that best-effort repair as a successful clear.
                try? persistWatchBacklogEvidence(watchBacklogEvidence)
            }
            // A display-only unknown zero has no backlog authority. Its failed
            // write must not keep otherwise empty background tasks running.
            watchBacklogStorageFailed = watchBacklogEvidence.hasBacklog || watchBacklogReadUncertain
            state.lastError = "手表状态或积压依据暂未保存，请稍后重试。"
            recordEvent(kind: "phone.watch_backlog_evidence_failed",
                detail: backlogFailureDescription(error, operation: clearsBacklog ? "clear" : "retain")
                    + " positive_snapshot_durable=\(positive && snapshotDurable)")
        }
    }

    private func persistWatchSnapshot(_ data: Data) throws {
        try backlogFaultInjector?(.beforeSnapshotWrite)
        try data.write(to: snapshotURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try backlogFaultInjector?(.afterSnapshotWriteBeforeSynchronization)
        try synchronizeMetadata(snapshotURL)
    }

    private func persistWatchBacklogEvidence(_ evidence: PhoneWatchBacklogEvidence) throws {
        guard evidence != persistedWatchBacklogEvidence || watchBacklogReadUncertain else { return }
        try backlogFaultInjector?(.beforeEvidenceWrite(evidence.hasBacklog))
        // After a failed replacement, no cached value can describe disk safely.
        persistedWatchBacklogEvidence = nil
        try TransportCodec.encode(evidence).write(to: watchBacklogURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try backlogFaultInjector?(.afterEvidenceWriteBeforeSynchronization(evidence.hasBacklog))
        try synchronizeMetadata(watchBacklogURL)
        persistedWatchBacklogEvidence = evidence
        watchBacklogReadUncertain = false
    }

    private func synchronizeMetadata(_ url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
        let descriptor = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private func backlogFailureDescription(_ error: Error, operation: String) -> String {
        let value = error as NSError
        return "operation=\(operation) retained_positive=\(watchBacklogEvidence.hasBacklog)"
            + " error_domain=\(value.domain) error_code=\(value.code)"
    }

    private func updateConnectionState() {
        guard let session else { return }
        let flags = ConnectionFlags(activated: session.activationState == .activated,
                                    paired: session.isPaired, installed: session.isWatchAppInstalled,
                                    reachable: session.activationState == .activated && session.isReachable)
        state.activated = flags.activated
        state.paired = flags.paired
        state.watchAppInstalled = flags.installed
        state.reachable = flags.reachable
        if loggedConnectionFlags != flags {
            loggedConnectionFlags = flags
            recordEvent(kind: "phone.connection_state",
                        detail: "activated=\(flags.activated) paired=\(flags.paired) installed=\(flags.installed) reachable=\(flags.reachable)")
        }
    }

    private func resendReceipts(trigger: String) {
        scheduleMaintenance(trigger: trigger, includeReceipts: true)
    }

    private func scheduleMaintenance(trigger: String, includeReceipts: Bool,
                                     incomingCallbackLease: PhoneIncomingCallbackLease? = nil) {
        // A fresh native file callback supplies a new opportunity. A stale local
        // lease must not consume it and leave the staged file waiting for UI.
        if incomingCallbackLease != nil,
           (maintenanceStarting && !maintenanceStartingFromIncoming)
            || (maintenanceLease.map { !$0.hasTimeRemaining } ?? false) {
            // Activation may have queued an ordinary lease behind MainActor
            // bootstrap. A real file callback can take over that pending start;
            // its old generation is released when the delayed grant arrives.
            finishMaintenance(completed: false)
        }
        if let incomingCallbackLease { incomingCallbackLeases.append(incomingCallbackLease) }
        let resumePendingReceipts = !replayIDs.isEmpty
        // Explicit and legacy recovery can bypass discovery debounce.
        // Exact requests and new deliveries can resume an already saved tail.
        replayDiscoveryForced = replayDiscoveryForced || trigger == "manual" || trigger == "watch_request"
        replayRequested = replayRequested || includeReceipts || resumePendingReceipts
        if includeReceipts || resumePendingReceipts {
            receiptMaintenancePolicy.requestHistory(limit: 8, generation: maintenanceGeneration)
        }
        guard maintenanceLease == nil, !maintenanceStarting else {
            if maintenanceLease != nil { finishIncomingCallbackHandoffs() }
            return
        }
        maintenanceStarting = true
        maintenanceStartingFromIncoming = incomingCallbackLease != nil
        maintenanceFailed = false
        historicalReplayWorked = false
        incomingAttempted.removeAll()
        // Resume an unfinished finite sweep across grants/process launches.
        // Re-enumerating the whole library every 20 seconds would never finish
        // a history larger than one grant and would keep waking an empty app.
        replayLoaded = !replayIDs.isEmpty
        let generation = maintenanceGeneration
        PhoneBackgroundLease.begin(name: "recording-sync", systemGranted: !maintenanceCallbacks.isEmpty,
            incomingCallback: incomingCallbackLease != nil,
            diagnostic: { [weak self] detail in
                self?.recordBackgroundDiagnostic(kind: "phone.background_lease", detail: detail)
            }) { [weak self] lease in
            guard let self else { lease.end(); return }
            self.work.async { [self] in
                guard generation == self.maintenanceGeneration else { lease.end(); return }
                self.maintenanceStarting = false
                self.maintenanceStartingFromIncoming = false
                self.maintenanceLease = lease
                self.finishIncomingCallbackHandoffs()
                self.receiptMaintenancePolicy.beginLease(generation: generation)
                do {
                    let waiting = try self.inbox.pendingIDs()
                    self.incomingIDs += waiting.filter { !self.incomingIDs.contains($0) }
                } catch {
                    self.maintenanceFailed = true
                    self.recordFailure("待处理收件读取失败，原文件保留：\(error.localizedDescription)")
                }
                self.recordEvent(kind: "phone.background_sync_started",
                            detail: "trigger=\(trigger) self.inbox=\(self.incomingIDs.count)")
                if !self.incomingIDs.isEmpty || !self.targetedRequests.isEmpty || self.replayRequested {
                    self.onNeedsBackgroundMaintenance?()
                }
                self.runMaintenanceStep(generation: generation)
            }
        }
    }

    private func finishIncomingCallbackHandoffs() {
        let leases = incomingCallbackLeases
        incomingCallbackLeases.removeAll()
        for lease in leases { lease.end() }
        if !leases.isEmpty { transferProgressMetadata.incomingCallbackEvent("lease_handoff") }
    }

    private func runMaintenanceStep(generation: Int) {
        guard generation == maintenanceGeneration else { return }
        guard let lease = maintenanceLease else { return }
        guard lease.hasTimeRemaining, !maintenanceCancellations.contains(where: \.isCancelled) else {
            finishMaintenance(completed: false)
            return
        }
        // A newly delivered file always goes before historical receipt replay.
        if !incomingIDs.isEmpty {
            let id = incomingIDs.removeFirst()
            guard incomingAttempted.insert(id).inserted else {
                work.async { [self] in runMaintenanceStep(generation: generation) }; return
            }
            do {
                let incoming = try inbox.load(id: id)
                try IncomingAudioValidator.validate(incoming.audioURL, against: incoming.manifest)
                // One exact metadata lstat classifies this successful receive;
                // diagnostics never enumerate, open or verify recording bytes.
                let receiptWasPresent = try? RecordingMetadataAccess.exists(at:
                    repository.root.appendingPathComponent("receipts", isDirectory: true)
                        .appendingPathComponent(incoming.manifest.id.uuidString.lowercased() + ".json"))
                let receipt = try repository.acceptIncomingFile(at: incoming.audioURL, manifest: incoming.manifest)
                transferPhaseDiagnostics.recordDurableReceipt(manifest: incoming.manifest, receipt: receipt, at: Date())
                transferProgressMetadata.incomingPersisted(receipt, receiptWasPresent: receiptWasPresent)
                receiptEvidence.incomingPersisted(manifest: incoming.manifest, receipt: receipt, receiptWasPresent: receiptWasPresent)
                // A staged file, message reply, or expired lease is never an ACK.
                // Only acceptIncomingFile's synchronized receipt permits this.
                let handoff = sendReceipt(receipt)
                var pending = replayIDs
                switch handoff {
                case .queued, .alreadyQueued:
                    // A repeated incoming callback can satisfy an older pending
                    // ACK. Retire it before a native completion opens the queue.
                    pending.removeAll { $0 == receipt.segmentID }
                case .unavailable:
                    if !pending.contains(receipt.segmentID) { pending.append(receipt.segmentID) }
                }
                if pending != replayIDs || handoff == .unavailable {
                    // Commit retry ownership before deleting the inbox entry.
                    // A failed write leaves that entry available after restart.
                    try writeSynchronized(pending, to: replayPendingURL)
                    replayIDs = pending
                }
                if handoff == .unavailable {
                    replayRequested = true
                    replayLoaded = true
                    receiptMaintenancePolicy.requestHistory(limit: 8, generation: generation)
                }
                try inbox.complete(id: id, receipt: receipt)
                recordEvent(kind: "phone.received",
                            detail: "片段 \(incoming.manifest.id.uuidString) 已校验并持久保存。",
                            sessionID: incoming.manifest.sessionID)
                notify()
            } catch {
                maintenanceFailed = true
                recordFailure("处理收件失败，未完成的文件保留待重试：\(error.localizedDescription)")
            }
            work.async { [self] in runMaintenanceStep(generation: generation) }
            return
        }
        if let request = targetedRequests.first,
           receiptMaintenancePolicy.beginTargetedAttempt(for: request, generation: generation) {
            var verified = false
            var handoff: HistoricalReceiptReplay.Handoff?
            do {
                let receipt = try PhoneReceiptMaintenancePolicy.verifiedReceipt(for: request) {
                    try repository.verifiedReceipt(for: $0)
                }
                verified = true
                handoff = sendReceipt(receipt, trigger: "targeted")
                recordEvent(kind: "phone.targeted_receipt_verified",
                            detail: "segment=\(request.segmentID.uuidString)")
            } catch {
                let failure = ReceiptVerificationFailure.classify(error)
                recordEvent(kind: "phone.targeted_receipt_unavailable",
                    detail: "segment=\(request.segmentID.uuidString) reason=\(failure.rawValue)")
                if failure.failsMaintenance {
                    maintenanceFailed = true
                    finishMaintenance(completed: false)
                    return
                }
                // Invalid data consumes only this request and its finite budget.
                // Watch keeps its copy; the healthy tail can still continue.
            }
            let progress = TargetedReceiptHandoff.step(pending: targetedRequests, verified: verified, handoff: handoff)
            guard progress.committed else {
                recordEvent(kind: "phone.targeted_receipt_deferred",
                    detail: "reason=companion_unavailable segment=\(request.segmentID.uuidString)")
                finishMaintenance(completed: !maintenanceFailed)
                return
            }
            if verified, replayIDs.contains(request.segmentID) {
                // This target also satisfies an incoming ACK deferred earlier.
                // Retire that retry before a native completion can resume it.
                let pending = replayIDs.filter { $0 != request.segmentID }
                do {
                    try writeSynchronized(pending, to: replayPendingURL)
                    replayIDs = pending
                } catch {
                    maintenanceFailed = true
                    recordFailure("回执补发进度暂未保存，下次会重新核对：\(error.localizedDescription)")
                    finishMaintenance(completed: false)
                    return
                }
            }
            targetedRequests = progress.pending
            persistTargetedRequests()
            work.async { [self] in runMaintenanceStep(generation: generation) }
            return
        }
        if replayRequested && !replayLoaded {
            replayLoaded = true
            if PhoneReceiptMaintenancePolicy.shouldDiscoverHistory(lastStartedAt: lastReplayDiscoveryAt,
                                                                   forced: replayDiscoveryForced) {
                do {
                    replayIDs = ReceiptReplayPolicy.orderedIDs(try repository.receiptIDsForReplay(), after: replayCursor)
                    persistReplayProgress()
                    historicalReplayWorked = true
                    if !maintenanceFailed { noteReplayDiscovery() }
                } catch {
                    maintenanceFailed = true
                    recordFailure("读取待重发回执清单失败：\(error.localizedDescription)")
                }
            } else {
                recordEvent(kind: "phone.ack_replay_deferred", detail: "reason=history_discovery_cooldown")
            }
        }
        if replayRequested && !replayIDs.isEmpty {
            // Historical ACKs may otherwise accumulate across many short grants
            // and occupy the native queue ahead of newly received/targeted ACKs.
            // Leave both the ID and cursor unchanged, and do no source hashing,
            // while native completion has yet to release a receipt queue slot.
            guard hasHistoricalReceiptQueueCapacity() else {
                recordEvent(kind: "phone.ack_replay_deferred", detail: "reason=receipt_queue_full_or_unavailable")
                finishMaintenance(completed: !maintenanceFailed)
                return
            }
            guard receiptMaintenancePolicy.beginHistoricalAttempt(generation: generation) else {
                finishMaintenance(completed: !maintenanceFailed)
                return
            }
            historicalReplayWorked = true
            let id = replayIDs[0]
            var verified = false
            var handoff: HistoricalReceiptReplay.Handoff?
            do {
                // Revalidate exactly one durable copy; a bad historical file does
                // not prevent receiving new files or replaying other valid ACKs.
                let receipt = try repository.verifiedReceipt(for: id)
                verified = true
                handoff = sendReceipt(receipt, trigger: "replay")
            } catch {
                let failure = ReceiptVerificationFailure.classify(error)
                recordEvent(kind: "phone.ack_replay_unavailable",
                    detail: "segment=\(id.uuidString) reason=\(failure.rawValue)")
                if failure.failsMaintenance {
                    maintenanceFailed = true
                    finishMaintenance(completed: false)
                    return
                }
            }
            let progress = HistoricalReceiptReplay.step(pending: replayIDs, cursor: replayCursor,
                verified: verified, handoff: handoff)
            guard progress.committed else {
                // The companion could not accept this ACK. Keep the head and the
                // cursor so a later activation can send the same receipt.
                recordEvent(kind: "phone.ack_replay_deferred", detail: "reason=companion_unavailable")
                finishMaintenance(completed: !maintenanceFailed)
                return
            }
            replayIDs = progress.pending
            replayCursor = progress.cursor
            persistReplayProgress()
            if let cursor = progress.cursor {
                do { try writeSynchronized(cursor, to: replayCursorURL) }
                catch {
                    maintenanceFailed = true
                    recordFailure("回执补发进度暂未保存，下次会重新核对：\(error.localizedDescription)")
                }
            }
            // Yield between items for incoming files and connection callbacks.
            // The persisted cursor prevents short background grants starving the tail.
            work.asyncAfter(deadline: .now() + 0.2) { [self] in runMaintenanceStep(generation: generation) }
            return
        }
        finishMaintenance(completed: !maintenanceFailed)
    }

    private func persistReplayProgress() {
        do { try writeSynchronized(replayIDs, to: replayPendingURL) }
        catch {
            maintenanceFailed = true
            recordFailure("回执补发进度暂未保存，下次会重新核对：\(error.localizedDescription)")
        }
    }

    private func noteReplayDiscovery() {
        let now = Date()
        // This hint never authorizes ACKs. A failed write may cause extra work
        // after restart, but cannot discard a retry or fail a durable receipt.
        lastReplayDiscoveryAt = now
        try? writeSynchronized(now, to: replayDiscoveryURL)
    }

    private func persistTargetedRequests() {
        do { try writeSynchronized(targetedRequests, to: targetedPendingURL) }
        catch {
            maintenanceFailed = true
            recordFailure("定向回执请求进度暂未保存，等待手表再次请求：\(error.localizedDescription)")
        }
    }

    private func writeSynchronized<T: Encodable>(_ value: T, to url: URL) throws {
        try TransportCodec.encode(value).write(to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    private func finishMaintenance(completed: Bool) {
        guard maintenanceLease != nil || maintenanceStarting else { return }
        if completed && !maintenanceFailed && historicalReplayWorked && replayLoaded && replayIDs.isEmpty {
            // A large sweep may span many grants and outlast the interval.
            // Anchor its next automatic discovery to completion as well.
            noteReplayDiscovery()
        }
        // A native completion can arrive after this lease spent its finite
        // history allowance but before its next queued step finishes. Preserve
        // that real wake once; never renew an expired or failed lease this way.
        let continueReceiptQueue = receiptQueueContinuationRequested && completed && !maintenanceFailed
            && !replayIDs.isEmpty && hasHistoricalReceiptQueueCapacity()
        receiptQueueContinuationRequested = false
        maintenanceGeneration += 1
        maintenanceStarting = false
        maintenanceStartingFromIncoming = false
        maintenanceLease?.end()
        maintenanceLease = nil
        finishIncomingCallbackHandoffs()
        let remainingInbox = (try? inbox.pendingIDs().count) ?? 1
        let needsMore = remainingInbox > 0 || !targetedRequests.isEmpty || !replayIDs.isEmpty
            || (replayRequested && !replayLoaded) || watchBacklogEvidence.hasBacklog || automaticSyncControl.needsRetry
        let succeeded = completed && !watchBacklogStorageFailed
        replayRequested = false
        replayLoaded = false
        replayDiscoveryForced = false
        let callbacks = maintenanceCallbacks
        maintenanceCallbacks.removeAll()
        maintenanceCancellations.removeAll()
        recordEvent(kind: "phone.background_sync_finished",
                    detail: "completed=\(succeeded) inbox=\(remainingInbox) receipts_remaining=\(replayIDs.count)"
                        + " targeted_remaining=\(targetedRequests.count)"
                        + " historical_attempts=\(receiptMaintenancePolicy.historicalAttempts)"
                        + " targeted_attempts=\(receiptMaintenancePolicy.targetedAttempts)"
                        + " watch_backlog_evidence=\(watchBacklogEvidence.hasBacklog)"
                        + " backlog_storage_failed=\(watchBacklogStorageFailed)")
        if needsMore { onNeedsBackgroundMaintenance?() }
        callbacks.forEach { $0(.init(succeeded: succeeded, needsMore: needsMore)) }
        notify()
        if continueReceiptQueue {
            scheduleMaintenance(trigger: "receipt_queue_continuation", includeReceipts: true)
        }
    }

    private static func queuedReceipt(in userInfo: [String: Any]) -> SegmentReceipt? {
        guard let bytes = userInfo[TransportCodec.receiptKey] as? Data,
              !bytes.isEmpty, bytes.count <= maximumReceiptMetadataBytes else { return nil }
        return try? TransportCodec.decode(SegmentReceipt.self, from: bytes)
    }

    private func hasHistoricalReceiptQueueCapacity() -> Bool {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return false }
        var receipts = 0
        // Only this app's small, typed ACKs consume its history allowance.
        // Other user-info traffic never turns an otherwise free ACK slot full.
        for transfer in session.outstandingUserInfoTransfers {
            if Self.queuedReceipt(in: transfer.userInfo) != nil {
                receipts += 1
                if receipts >= Self.historicalReceiptQueueLimit { return false }
            }
        }
        return true
    }

    @discardableResult
    private func sendReceipt(_ receipt: SegmentReceipt, fastPath: Bool = true, trigger: String = "received") -> HistoricalReceiptReplay.Handoff {
        updateConnectionState()
        // The durable receipt remains in the repository while WatchConnectivity
        // cannot target the companion; a later state change replays it.
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return .unavailable }
        do {
            let data = try TransportCodec.encode(receipt)
            let alreadyQueued = session.outstandingUserInfoTransfers.contains { transfer in
                Self.queuedReceipt(in: transfer.userInfo) == receipt
            }
            if !alreadyQueued {
                session.transferUserInfo([TransportCodec.receiptKey: data])
                transferPhaseDiagnostics.recordACKQueued(receipt: receipt, at: Date())
                transferProgressMetadata.receiptSent(receipt, immediate: false, historicalReplay: trigger == "replay")
            }
            if fastPath && session.isReachable && receiptReplayPolicy.beginImmediateAttempt(receipt) {
                recordEvent(kind: "phone.ack_attempt",
                            detail: "segment=\(receipt.segmentID.uuidString) trigger=\(trigger) channel=message background=\(alreadyQueued ? "already_queued" : "enqueued")")
                sendImmediateReceipt(receipt, data: data, through: session)
            } else if fastPath && !alreadyQueued {
                recordEvent(kind: "phone.ack_attempt",
                            detail: "segment=\(receipt.segmentID.uuidString) trigger=\(trigger) channel=background immediate=\(session.isReachable ? "cooldown" : "unreachable")")
            }
            return alreadyQueued ? .alreadyQueued : .queued
        } catch { recordFailure("接收确认编码失败：\(error.localizedDescription)") }
        return .unavailable
    }

    private func sendImmediateReceipt(_ receipt: SegmentReceipt, data: Data, through session: WCSession) {
        // No reply/success callback is treated as an application acknowledgement.
        session.sendMessage([TransportCodec.receiptKey: data], replyHandler: nil) { [weak self] error in
            self?.work.async { [weak self] in
                self?.recordReceiptFailure(receipt, channel: "message", error: error)
            }
        }
        transferProgressMetadata.receiptSent(receipt, immediate: true)
    }

    private func recordReceiptFailure(_ receipt: SegmentReceipt, channel: String, error: Error) {
        let value = error as NSError
        state.lastError = "确认发送失败，持久回执仍保留：\(value.localizedDescription) [channel=\(channel) domain=\(value.domain) code=\(value.code)]"
        receiptFailureCount += 1
        if receiptFailureSamples.count < receiptReplayPolicy.batchLimit {
            receiptFailureSamples.append("segment=\(receipt.segmentID.uuidString) channel=\(channel) domain=\(value.domain) code=\(value.code)")
        }
        guard !receiptFailureFlushScheduled else { return }
        receiptFailureFlushScheduled = true
        work.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.recordEvent(kind: "phone.ack_failed",
                             detail: "count=\(self.receiptFailureCount) samples=[\(self.receiptFailureSamples.joined(separator: " | "))]")
            self.receiptFailureSamples.removeAll(keepingCapacity: true)
            self.receiptFailureCount = 0
            self.receiptFailureFlushScheduled = false
            self.notify()
        }
    }

    private func requestWatchSync(sendImmediate: Bool = true, now: Date = Date()) {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        let plan: PhoneAutomaticSyncControl.Plan
        do {
            guard let prepared = try automaticSyncControl.prepare(hasBacklog: watchBacklogEvidence.hasBacklog, now: now) else { return }
            plan = prepared
        } catch {
            transferProgressMetadata.controlEvent(.stateFailed, requestID: nil)
            transferProgressMetadata.controlError(error)
            transferProgressMetadata.controlRetryPending(automaticSyncControl.needsRetry)
            onNeedsBackgroundMaintenance?()
            return
        }
        transferProgressMetadata.controlEvent(.requested, requestID: plan.id)
        var contextAccepted = false
        do {
            // Latest control state is independent of the FIFO user-info queue.
            // API acceptance is never proof of Watch delivery or file progress.
            try session.updateApplicationContext(plan.payload)
            contextAccepted = true
            transferProgressMetadata.controlEvent(.contextAccepted, requestID: plan.id)
        } catch {
            transferProgressMetadata.controlEvent(.contextFailed, requestID: plan.id)
            transferProgressMetadata.controlError(error)
            recordTransportFailure("后台同步控制状态暂未登记：", error: error)
        }
        let queuedControls = session.outstandingUserInfoTransfers.filter {
            $0.userInfo[TransportCodec.requestSyncKey] as? Bool == true
        }
        let alreadyQueued = queuedControls.contains { plan.matches($0.userInfo) }
        if !alreadyQueued {
            // A previous process/version can leave a pure control in the OS
            // queue indefinitely. It carries the same requestSync authority,
            // so the persisted current intent supersedes it. Never cancel a
            // receipt, status, event or unknown mixed envelope to make room.
            for transfer in queuedControls where PhoneAutomaticSyncControl.Plan.replaceableControl(transfer.userInfo) {
                transfer.cancel()
            }
        }
        // cancel() is asynchronous. Observe actual OS ownership again rather
        // than assuming that requesting cancellation released the bounded slot.
        let remainingControls = session.outstandingUserInfoTransfers.filter {
            $0.userInfo[TransportCodec.requestSyncKey] as? Bool == true
        }
        var nativeQueued = remainingControls.contains { plan.matches($0.userInfo) }
        if remainingControls.isEmpty {
            session.transferUserInfo(plan.payload)
            nativeQueued = true
            transferProgressMetadata.controlEvent(.nativeEnqueued, requestID: plan.id)
        }
        // An occupied or cancelling slot cannot satisfy this exact intent.
        // Retain its durable obligation and cooldown for the next real grant.
        do { try automaticSyncControl.localAttemptCompleted(contextAccepted: contextAccepted, nativeQueued: nativeQueued) }
        catch {
            transferProgressMetadata.controlEvent(.stateFailed, requestID: plan.id)
            transferProgressMetadata.controlError(error)
        }
        transferProgressMetadata.controlRetryPending(automaticSyncControl.needsRetry)
        if automaticSyncControl.needsRetry { onNeedsBackgroundMaintenance?() }
        guard sendImmediate, session.isReachable else { return }
        session.sendMessage(plan.payload, replyHandler: nil) { [weak self] error in
            self?.work.async { [weak self] in
                self?.transferProgressMetadata.controlError(error)
                self?.recordTransportFailure("请求手表同步失败：", error: error)
            }
        }
    }

    private func recordEvent(kind: String, detail: String, sessionID: UUID? = nil) {
        do { try repository.appendEvent(RecordingEvent(kind: kind, detail: detail, sessionID: sessionID)) }
        catch { state.lastError = "日志保存失败：\(error.localizedDescription)" }
    }

    private func recordFailure(_ message: String) {
        state.lastError = message
        recordEvent(kind: "phone.error", detail: message)
        notify()
    }

    private func recordTransportFailure(_ prefix: String, error: Error) {
        let value = error as NSError
        recordFailure("\(prefix)\(value.localizedDescription) [domain=\(value.domain) code=\(value.code)]")
    }

    private struct ConnectionFlags: Equatable {
        let activated: Bool
        let paired: Bool
        let installed: Bool
        let reachable: Bool
    }

    private func notify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        work.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.notifyScheduled = false
            let callback = self.onUpdate
            DispatchQueue.main.async { callback?() }
        }
    }

    private enum ReceiveError: LocalizedError {
        case missingManifest
        var errorDescription: String? { "文件缺少有效的片段清单。" }
    }
}


/// A small durable control intent, separate from recordings and receipts. All
/// methods run on PhoneConnectivity's serial worker. Never owns a timer or lease.
private final class PhoneAutomaticSyncControl {
    struct Plan {
        let id: UUID
        let payload: [String: Any]

        static func replaceableControl(_ queued: [String: Any]) -> Bool {
            guard let requested = queued[TransportCodec.requestSyncKey] as? NSNumber,
                  CFGetTypeID(requested) == CFBooleanGetTypeID(), requested.boolValue else { return false }
            if Set(queued.keys) == [TransportCodec.requestSyncKey] { return true }
            guard Set(queued.keys) == Set([TransportCodec.requestSyncKey, "automaticSyncSchemaVersion",
                "automaticSyncRequestID", "automaticSyncRequestedAtMS"]),
                  let schema = queued["automaticSyncSchemaVersion"] as? NSNumber,
                  CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
                  (queued["automaticSyncRequestID"] as? String).flatMap(UUID.init(uuidString:)) != nil,
                  let time = queued["automaticSyncRequestedAtMS"] as? NSNumber,
                  CFGetTypeID(time) != CFBooleanGetTypeID(),
                  let milliseconds = Int64(exactly: time.doubleValue), milliseconds >= 0 else { return false }
            return true
        }

        func matches(_ queued: [String: Any]) -> Bool {
            guard Set(queued.keys) == Set(payload.keys),
                  let requested = queued[TransportCodec.requestSyncKey] as? NSNumber,
                  CFGetTypeID(requested) == CFBooleanGetTypeID(), requested.boolValue,
                  let schema = queued["automaticSyncSchemaVersion"] as? NSNumber,
                  CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
                  (queued["automaticSyncRequestID"] as? String).flatMap(UUID.init(uuidString:)) == id,
                  let time = queued["automaticSyncRequestedAtMS"] as? NSNumber,
                  CFGetTypeID(time) != CFBooleanGetTypeID(),
                  let requestedAtMS = Int64(exactly: time.doubleValue) else { return false }
            return requestedAtMS == payload["automaticSyncRequestedAtMS"] as? Int64
        }
    }
    private struct State: Codable {
        var schemaVersion = 1
        let requestID: UUID
        let requestedAt: Date
        var lastAttemptAt: Date
        var retryAfter: Date
        var contextRetryPending: Bool
        var nativeRetryPending: Bool
    }
    private let directory: URL
    private let url: URL
    private var loaded = false
    private var state: State?
    private var storageFailed = false
    private static let interval: TimeInterval = 15 * 60
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    var needsRetry: Bool { storageFailed || state.map { $0.contextRetryPending || $0.nativeRetryPending } == true }

    init(root: URL) {
        directory = root.appendingPathComponent("ConnectivityDiagnostics", isDirectory: true)
        url = directory.appendingPathComponent("automatic-sync-control.json")
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        do {
            if let bytes = try RecordingMetadataAccess.readIfPresent(at: url, maximumBytes: 8_192) {
                let value = try TransportCodec.decode(State.self, from: bytes)
                guard value.schemaVersion == 1,
                      [value.requestedAt, value.lastAttemptAt, value.retryAfter].allSatisfy({
                          Int64(exactly: ($0.timeIntervalSince1970 * 1_000).rounded()) != nil
                      }),
                      value.lastAttemptAt >= value.requestedAt,
                      value.retryAfter >= value.lastAttemptAt else { throw CocoaError(.fileReadCorruptFile) }
                state = value
            } else { state = nil }
            loaded = true
            storageFailed = false
        } catch { storageFailed = true; throw error }
    }

    func prepare(hasBacklog: Bool, now: Date = Date()) throws -> Plan? {
        try loadIfNeeded()
        let expired = state.map { now.timeIntervalSince($0.requestedAt) > Self.lifetime } ?? false
        let renewBacklog = hasBacklog && !needsRetry
            && state.map { now.timeIntervalSince($0.requestedAt) >= Self.interval } == true
        var candidate: State
        if state == nil || expired || renewBacklog {
            candidate = State(requestID: UUID(), requestedAt: now, lastAttemptAt: now,
                retryAfter: now.addingTimeInterval(Self.interval), contextRetryPending: true, nativeRetryPending: true)
        } else {
            guard var previous = state, needsRetry, now >= previous.retryAfter else { return nil }
            previous.lastAttemptAt = now
            previous.retryAfter = now.addingTimeInterval(Self.interval)
            // Repeat the same exact intent on both channels after a bounded
            // delay; a new UUID cannot make a failed delivery look like progress.
            previous.contextRetryPending = true
            previous.nativeRetryPending = true
            candidate = previous
        }
        try persist(candidate)
        return plan(for: candidate)
    }

    private func plan(for value: State) -> Plan {
        Plan(id: value.requestID, payload: [TransportCodec.requestSyncKey: true,
            "automaticSyncSchemaVersion": 1, "automaticSyncRequestID": value.requestID.uuidString,
            // TransportCodec persists dates as rounded integer milliseconds;
            // use the identical value before and after a process restart.
            "automaticSyncRequestedAtMS": Int64((value.requestedAt.timeIntervalSince1970 * 1_000).rounded())])
    }

    func localAttemptCompleted(contextAccepted: Bool, nativeQueued: Bool) throws {
        guard var candidate = state else { return }
        candidate.contextRetryPending = !contextAccepted
        // Only API enqueue or an exact current envelope already owned by the OS
        // discharges this channel. A different request cannot satisfy it.
        candidate.nativeRetryPending = !nativeQueued
        try persist(candidate)
    }

    func nativeCompleted(requestID: UUID?, failed: Bool, now: Date = Date(), payload: [String: Any]? = nil) throws {
        try loadIfNeeded()
        // A late completion from an older UUID cannot clear or delay a new one.
        if let current = state, requestID != current.requestID { return }
        // The callback is bound to the exact native packet too. Sharing an ID
        // does not make a rejected schema, time or extra authority a valid twin.
        if let current = state, let payload, !plan(for: current).matches(payload) { return }
        guard var candidate = state else {
            guard failed else { return }
            // Legacy Boolean requests can fail after an app upgrade too.
            let initial = State(requestID: UUID(), requestedAt: now, lastAttemptAt: now,
                retryAfter: now.addingTimeInterval(Self.interval), contextRetryPending: true, nativeRetryPending: true)
            try persist(initial)
            return
        }
        guard failed || requestID != nil else { return }
        candidate.nativeRetryPending = failed
        if failed { candidate.retryAfter = max(candidate.retryAfter, now.addingTimeInterval(Self.interval)) }
        try persist(candidate)
    }

    private func persist(_ candidate: State) throws {
        do {
            let bytes = try TransportCodec.encode(candidate)
            guard bytes.count <= 8_192 else { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.synchronize()
            let descriptor = Darwin.open(directory.path, O_RDONLY)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            state = candidate
            loaded = true
            storageFailed = false
        } catch {
            // A visible atomic replacement may precede failed fsync. Re-read it
            // on the next real opportunity, never invent a fresh default intent.
            loaded = false
            storageFailed = true
            throw error
        }
    }
}

/// Observer-epoch observations of existing receive/send callbacks only. This
/// object has no repository, recording reader or scheduling reference.
private final class PhoneTransferProgressMetadata: @unchecked Sendable {
    enum ControlKind: String, CaseIterable {
        case requested, contextAccepted = "context_accepted", contextFailed = "context_failed"
        case nativeEnqueued = "native_enqueued", nativeCompleted = "native_completed"
        case nativeFailed = "native_failed", stateFailed = "state_failed"
    }
    private struct Signals: Codable {
        var counts: [String: Int]
        var lastAtMS: [String: Int64] = [:]
        var lastRequestID: UUID?
        var retryPending: Bool?
        var lastErrorDomain: String?
        var lastErrorCode: Int?
        var lastErrorAtMS: Int64?
        mutating func note(_ key: String, at now: Int64) {
            let count = counts[key] ?? 0
            counts[key] = count < Int.max ? count + 1 : count
            lastAtMS[key] = now
        }
    }
    private enum Kind: String, Codable {
        case incomingPersisted = "incoming_persisted"
        case ackBackgroundEnqueued = "ack_background_enqueued"
        case ackImmediateSent = "ack_immediate_sent"
        case ackNativeCompleted = "ack_native_completed"
        case ackNativeFailed = "ack_native_failed"
    }
    private struct Event: Codable {
        let kind: Kind
        let observedAtMS: Int64
        let segmentID: UUID
        let sha256: String?
        let byteCount: Int64
        let receiptReceivedAtMS: Int64?
        let receiptWasPresent: Bool?
    }
    private struct PendingContent: Codable {
        let isPending: Bool
        let observedAtMS: Int64
        var foreground: Bool?
        let activationState: Int

        init(_ session: WCSession) {
            isPending = session.hasContentPending
            activationState = session.activationState.rawValue
            observedAtMS = PhoneTransferProgressMetadata.nowMS()
        }
    }
    private struct Report: Codable {
        var schemaVersion = 1
        var role = "phone"
        var counterScope = "observer_epoch"
        let build: String
        let processRunID: UUID
        let observerEpochID: UUID
        let processID: Int32
        let observerStartedAtMS: Int64
        let reportSequence: Int
        let generatedAtMS: Int64
        let uptimeMS: Int64
        let foreground: Bool?
        let incomingPersistedCount: Int
        let newIncomingCount: Int
        let existingIncomingCount: Int
        let unclassifiedIncomingCount: Int
        let lastIncomingPersistedAtMS: Int64?
        let lastNewIncomingAtMS: Int64?
        let ackBackgroundEnqueuedCount: Int
        let historicalACKEnqueuedCount: Int
        let lastAckBackgroundEnqueuedAtMS: Int64?
        let ackImmediateSentCount: Int
        let lastAckImmediateSentAtMS: Int64?
        let ackNativeCompletedCount: Int
        let lastAckNativeCompletedAtMS: Int64?
        let ackNativeFailedCount: Int
        let lastAckNativeFailedAtMS: Int64?
        let recentEvents: [Event]
        let control: Signals
        let backgroundScheduler: Signals
        let incomingCallback: Signals
        let wcActivation: Signals
        let wcPendingContent: PendingContent?
        let lastWCPendingInBackgroundAtMS: Int64?
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "WristRecord.phone.transfer-progress-metadata", qos: .utility)
    private let directory: URL
    private let build = String((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown").prefix(32))
    private static let processRunID = UUID()
    private let observerEpochID = UUID()
    private let observerStartedAtMS = Int64(Date().timeIntervalSince1970 * 1_000)
    private var reportSequence = 0
    private var foreground: Bool?
    private var incomingPersistedCount = 0
    private var newIncomingCount = 0
    private var existingIncomingCount = 0
    private var unclassifiedIncomingCount = 0
    private var lastIncomingPersistedAtMS: Int64?
    private var lastNewIncomingAtMS: Int64?
    private var ackBackgroundEnqueuedCount = 0
    private var historicalACKEnqueuedCount = 0
    private var lastAckBackgroundEnqueuedAtMS: Int64?
    private var ackImmediateSentCount = 0
    private var lastAckImmediateSentAtMS: Int64?
    private var ackNativeCompletedCount = 0
    private var lastAckNativeCompletedAtMS: Int64?
    private var ackNativeFailedCount = 0
    private var lastAckNativeFailedAtMS: Int64?
    private var recentEvents: [Event] = []
    private var control = Signals(counts: Dictionary(uniqueKeysWithValues: ControlKind.allCases.map { ($0.rawValue, 0) }))
    private var backgroundScheduler = Signals(counts: Dictionary(uniqueKeysWithValues:
        ["registered", "register_failed", "submitted", "pending", "started", "submit_failed"].map { ($0, 0) }))
    private var incomingCallback = Signals(counts: Dictionary(uniqueKeysWithValues:
        ["started", "staged", "stage_failed", "lease_handoff"].map { ($0, 0) }))
    private var wcActivation = Signals(counts: ["completed": 0, "failed": 0, "retried": 0])
    private var wcPendingContent: PendingContent?
    private var lastWCPendingInBackgroundAtMS: Int64?

    func incomingCallbackEvent(_ kind: String) {
        lock.lock(); defer { lock.unlock() }
        guard incomingCallback.counts[kind] != nil else { return }
        incomingCallback.note(kind, at: Self.nowMS())
        enqueueLocked()
    }

    func activationCompleted(_ session: WCSession, failed: Bool) {
        let sample = PendingContent(session)
        lock.lock(); defer { lock.unlock() }
        wcActivation.note(failed ? "failed" : "completed", at: Self.nowMS())
        notePendingContent(sample)
        enqueueLocked()
    }

    func activationRetried() {
        lock.lock(); defer { lock.unlock() }
        wcActivation.note("retried", at: Self.nowMS())
        enqueueLocked()
    }

    func observePendingContent(_ session: WCSession) {
        let sample = PendingContent(session)
        lock.lock(); defer { lock.unlock() }
        notePendingContent(sample)
        enqueueLocked()
    }

    private func notePendingContent(_ observation: PendingContent) {
        guard observation.observedAtMS >= (wcPendingContent?.observedAtMS ?? 0) else { return }
        var sample = observation
        sample.foreground = foreground
        wcPendingContent = sample
        if sample.isPending, foreground == false { lastWCPendingInBackgroundAtMS = sample.observedAtMS }
    }

    init(root: URL) {
        directory = root.appendingPathComponent("ConnectivityDiagnostics", isDirectory: true)
        enqueueLocked()
    }

    func setForeground(_ value: Bool, session: WCSession?) {
        let sample = session.map(PendingContent.init)
        lock.lock(); defer { lock.unlock() }
        foreground = value
        if let sample { notePendingContent(sample) }
        enqueueLocked()
    }

    func controlEvent(_ kind: ControlKind, requestID: UUID?) {
        lock.lock(); defer { lock.unlock() }
        control.note(kind.rawValue, at: Self.nowMS())
        if let requestID { control.lastRequestID = requestID }
        enqueueLocked()
    }

    func controlRetryPending(_ pending: Bool) {
        lock.lock(); defer { lock.unlock() }
        control.retryPending = pending
        enqueueLocked()
    }

    func controlError(_ error: Error) {
        let value = error as NSError
        lock.lock(); defer { lock.unlock() }
        var domain = ""
        for scalar in value.domain.unicodeScalars.prefix(96) {
            let piece = String(scalar)
            guard domain.utf8.count + piece.utf8.count <= 96 else { break }
            domain.append(piece)
        }
        control.lastErrorDomain = domain
        control.lastErrorCode = value.code
        control.lastErrorAtMS = Self.nowMS()
        enqueueLocked()
    }

    func backgroundSchedulerEvent(_ kind: String, detail: String) {
        let key: String
        switch kind {
        case "phone.bg_register":
            if detail.contains(" registered=true") { key = "registered" }
            else if detail.contains(" registered=false") { key = "register_failed" }
            else { return }
        case "phone.bg_submit": key = "submitted"
        case "phone.bg_request_pending": key = "pending"
        case "phone.bg_task_started": key = "started"
        case "phone.bg_submit_failed": key = "submit_failed"
        default: return
        }
        lock.lock(); defer { lock.unlock() }
        backgroundScheduler.note(key, at: Self.nowMS())
        enqueueLocked()
    }

    func incomingPersisted(_ receipt: SegmentReceipt, receiptWasPresent: Bool?) {
        lock.lock(); defer { lock.unlock() }
        let now = Self.nowMS()
        Self.increment(&incomingPersistedCount)
        lastIncomingPersistedAtMS = now
        // A visible old receipt may still need durability recovery. It remains
        // an existing receive here; no metadata observation proves prior fsync.
        switch receiptWasPresent {
        case false?: Self.increment(&newIncomingCount); lastNewIncomingAtMS = now
        case true?: Self.increment(&existingIncomingCount)
        case nil: Self.increment(&unclassifiedIncomingCount)
        }
        append(.incomingPersisted, receipt: receipt, at: now, receiptWasPresent: receiptWasPresent)
    }

    func receiptSent(_ receipt: SegmentReceipt, immediate: Bool, historicalReplay: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        let now = Self.nowMS()
        if immediate {
            Self.increment(&ackImmediateSentCount); lastAckImmediateSentAtMS = now
        } else {
            Self.increment(&ackBackgroundEnqueuedCount); lastAckBackgroundEnqueuedAtMS = now
            if historicalReplay { Self.increment(&historicalACKEnqueuedCount) }
        }
        append(immediate ? .ackImmediateSent : .ackBackgroundEnqueued, receipt: receipt, at: now)
    }

    func nativeReceiptCompleted(_ receipt: SegmentReceipt, succeeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        let now = Self.nowMS()
        if succeeded {
            Self.increment(&ackNativeCompletedCount); lastAckNativeCompletedAtMS = now
        } else {
            Self.increment(&ackNativeFailedCount); lastAckNativeFailedAtMS = now
        }
        append(succeeded ? .ackNativeCompleted : .ackNativeFailed, receipt: receipt, at: now)
    }

    private static func nowMS() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
    private static func increment(_ value: inout Int) { if value < Int.max { value += 1 } }

    private func append(_ kind: Kind, receipt: SegmentReceipt, at now: Int64, receiptWasPresent: Bool? = nil) {
        // Keep only the already supplied exact identity, never arbitrary payload
        // strings. Native completion is transport evidence, not Watch durability.
        let hash = receipt.sha256.count == 64 && receipt.sha256.allSatisfy({ "0123456789abcdef".contains($0) })
            ? receipt.sha256 : nil
        recentEvents.append(Event(kind: kind, observedAtMS: now, segmentID: receipt.segmentID,
            sha256: hash, byteCount: receipt.byteCount,
            receiptReceivedAtMS: Int64(exactly: (receipt.receivedAt.timeIntervalSince1970 * 1_000).rounded(.towardZero)),
            receiptWasPresent: receiptWasPresent))
        if recentEvents.count > 6 { recentEvents.removeFirst(recentEvents.count - 6) }
        enqueueLocked()
    }

    private func enqueueLocked() {
        Self.increment(&reportSequence)
        let report = Report(build: build, processRunID: Self.processRunID, observerEpochID: observerEpochID,
            processID: ProcessInfo.processInfo.processIdentifier, observerStartedAtMS: observerStartedAtMS,
            reportSequence: reportSequence, generatedAtMS: Self.nowMS(),
            uptimeMS: Int64(ProcessInfo.processInfo.systemUptime * 1_000), foreground: foreground,
            incomingPersistedCount: incomingPersistedCount, newIncomingCount: newIncomingCount,
            existingIncomingCount: existingIncomingCount, unclassifiedIncomingCount: unclassifiedIncomingCount,
            lastIncomingPersistedAtMS: lastIncomingPersistedAtMS, lastNewIncomingAtMS: lastNewIncomingAtMS,
            ackBackgroundEnqueuedCount: ackBackgroundEnqueuedCount,
            historicalACKEnqueuedCount: historicalACKEnqueuedCount,
            lastAckBackgroundEnqueuedAtMS: lastAckBackgroundEnqueuedAtMS,
            ackImmediateSentCount: ackImmediateSentCount, lastAckImmediateSentAtMS: lastAckImmediateSentAtMS,
            ackNativeCompletedCount: ackNativeCompletedCount, lastAckNativeCompletedAtMS: lastAckNativeCompletedAtMS,
            ackNativeFailedCount: ackNativeFailedCount, lastAckNativeFailedAtMS: lastAckNativeFailedAtMS,
            recentEvents: recentEvents, control: control, backgroundScheduler: backgroundScheduler,
            incomingCallback: incomingCallback, wcActivation: wcActivation, wcPendingContent: wcPendingContent,
            lastWCPendingInBackgroundAtMS: lastWCPendingInBackgroundAtMS)
        queue.async { [directory] in
            guard let data = try? JSONEncoder().encode(report), data.count <= 8_192 else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let target = directory.appendingPathComponent("background-sync.json")
                try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            } catch {
                // Observation failure never starts work or changes transfer results.
            }
        }
    }
}

/// An independent, bounded WC-only observation. This object has no repository,
/// recording, transfer-policy or library observer reference.
private final class PhoneConnectivityMetadata: @unchecked Sendable {
    enum Trigger: String, Codable { case startup, foreground, background, status, reachability,
        activationRequested = "activation_requested", activationCompleted = "activation_completed",
        counterpartChanged = "counterpart_changed", inactive }
    enum StatusOutcome: String, Codable { case received, noReport, staleReport, failed, timeout, unsupported, unavailable, unreachable, cancelled }
    enum StatusRequestTrigger: String, Codable { case manual, recovery }
    private struct ActivationError: Codable {
        let domain: String
        let code: Int
        let observedAtMS: Int64
    }
    private struct Report: Codable {
        let schemaVersion = 1
        let role = "phone"
        let build: String
        let observedAtMS: Int64
        let uptime: TimeInterval
        let trigger: Trigger
        let activationState: Int
        let reachable: Bool
        let delegateMatches: Bool
        let foreground: Bool
        let paired: Bool
        let watchInstalled: Bool
        let activationAttemptCount: Int
        let activationRequestedAtMS: Int64?
        let activationCompletedAtMS: Int64?
        let activationInFlight: Bool
        let lastActivationError: ActivationError?
        let statusRequestCount: Int
        let statusAutoRetryCount: Int
        let statusReplyCount: Int
        let lastStatusRequestTrigger: StatusRequestTrigger?
        let lastStatusRequestedAtMS: Int64?
        let lastStatusReplyAtMS: Int64?
        let lastStatusOutcome: StatusOutcome?
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "WristRecord.phone.connectivity-metadata", qos: .utility)
    private let directory: URL
    private let build = String((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown").prefix(32))
    private var foreground = false
    private var activationInFlight = false
    private var activationRetryPending = false
    private var activationAttemptCount = 0
    private var activationRequestedAtMS: Int64?
    private var activationCompletedAtMS: Int64?
    private var lastActivationError: ActivationError?
    private var statusRequestCount = 0
    private var statusAutoRetryCount = 0
    private var statusReplyCount = 0
    private var lastStatusRequestTrigger: StatusRequestTrigger?
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

    func statusRequested(_ session: WCSession, owner: AnyObject, trigger: StatusRequestTrigger) {
        lock.lock(); defer { lock.unlock() }
        statusRequestCount += 1
        if trigger == .recovery { statusAutoRetryCount += 1 }
        lastStatusRequestTrigger = trigger
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
        noteActivationRequestLocked()
        enqueueLocked(session, owner: owner, trigger: .activationRequested)
    }

    func beginActivationRetry(_ session: WCSession, owner: AnyObject) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard activationRetryPending, !activationInFlight, session.activationState == .notActivated,
              session.delegate === owner else { return false }
        noteActivationRequestLocked()
        enqueueLocked(session, owner: owner, trigger: .activationRequested)
        return true
    }

    private func noteActivationRequestLocked() {
        activationInFlight = true
        activationRetryPending = false
        activationAttemptCount += 1
        activationRequestedAtMS = Int64(Date().timeIntervalSince1970 * 1_000)
        // The original failure remains visible across a later retry/success.
    }

    func activationCompleted(_ session: WCSession, owner: AnyObject,
                             activationState: WCSessionActivationState, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        activationInFlight = false
        activationRetryPending = activationState == .notActivated && error != nil
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        activationCompletedAtMS = now
        if let error = error as NSError? {
            lastActivationError = .init(domain: String(error.domain.prefix(128)), code: error.code, observedAtMS: now)
        }
        enqueueLocked(session, owner: owner, trigger: .activationCompleted)
    }

    private func enqueueLocked(_ session: WCSession, owner: AnyObject, trigger: Trigger) {
        let report = Report(build: build, observedAtMS: Int64(Date().timeIntervalSince1970 * 1_000),
            uptime: ProcessInfo.processInfo.systemUptime, trigger: trigger,
            activationState: session.activationState.rawValue, reachable: session.isReachable,
            delegateMatches: session.delegate === owner, foreground: foreground,
            paired: session.isPaired, watchInstalled: session.isWatchAppInstalled,
            activationAttemptCount: activationAttemptCount,
            activationRequestedAtMS: activationRequestedAtMS, activationCompletedAtMS: activationCompletedAtMS,
            activationInFlight: activationInFlight, lastActivationError: lastActivationError,
            statusRequestCount: statusRequestCount, statusAutoRetryCount: statusAutoRetryCount,
            statusReplyCount: statusReplyCount, lastStatusRequestTrigger: lastStatusRequestTrigger,
            lastStatusRequestedAtMS: lastStatusRequestedAtMS, lastStatusReplyAtMS: lastStatusReplyAtMS,
            lastStatusOutcome: lastStatusOutcome)
        // Enqueue under the short lock so a later callback cannot overwrite a
        // newer observation with an older report. No lock crosses I/O or WC send.
        queue.async { [directory] in
            guard let data = try? JSONEncoder().encode(report), data.count <= 4_096 else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let target = directory.appendingPathComponent("phone.json")
                try data.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            } catch {
                // Metadata failure must never enter library events or start sync.
            }
        }
    }
}


/// A durable per-source projection, separate from the six-event transport ring.
/// Restored repository receipts are historical metadata, not invented callbacks.
/// This object has no WCSession or audio URL, and its failures never affect ACKs.
private final class PhoneReceiptEvidence: @unchecked Sendable {
    private let repository: RecordingRepository
    private let archive: SyncEvidenceArchive
    private let queue = DispatchQueue(label: "WristRecord.phone.receipt-evidence", qos: .utility)
    private var rows: [UUID: SyncEvidenceSource] = [:]
    private var loaded = false
    private var foreground: Bool?
    private var flushPending = false
    private var historyUnavailable = false
    init(repository: RecordingRepository, root: URL) {
        self.repository = repository
        archive = SyncEvidenceArchive(root: root, stream: "phone_receipts")
    }
    func start() {
        queue.async { [self] in
            do { try restore(); try publish() } catch { archive.markUnavailable() }
        }
    }
    func observeVerifiedMetadata(onThrottle: (@Sendable (Int) -> Void)? = nil) {
        queue.async { [self] in _ = archive.observe(processRunID: VerifiedObservationPublisher.processRunID, onThrottle: onThrottle) }
    }
    func setForeground(_ value: Bool) { queue.async { self.foreground = value } }
    func incomingPersisted(manifest: SegmentManifest, receipt: SegmentReceipt, receiptWasPresent: Bool?) {
        queue.async { [self] in
            do {
                try restore()
                guard receipt.segmentID == manifest.id, receipt.sha256 == manifest.sha256,
                      receipt.byteCount == manifest.byteCount else { throw SyncEvidenceArchive.Failure.invalid }
                let old = rows[manifest.id]
                if let old {
                    guard old.sha256 == manifest.sha256, old.byteCount == manifest.byteCount,
                          old.startedAtMS == Self.ms(manifest.startedAt) else { throw SyncEvidenceArchive.Failure.invalid }
                }
                let now = Self.ms(Date())
                rows[manifest.id] = SyncEvidenceSource(segmentID: manifest.id, sha256: manifest.sha256,
                    byteCount: manifest.byteCount, startedAtMS: Self.ms(manifest.startedAt), origin: "incoming_persisted",
                    receiptAtMS: Self.ms(receipt.receivedAt), firstObservedAtMS: old?.firstObservedAtMS ?? now,
                    lastObservedAtMS: now, receiptWasPresent: old?.firstObservedAtMS != nil ? old?.receiptWasPresent : receiptWasPresent,
                    foreground: old?.firstObservedAtMS != nil ? old?.foreground : foreground,
                    artifacts: [.init(kind: "audio", sha256: manifest.sha256, byteCount: manifest.byteCount,
                        state: "phone_persisted", recordedAtMS: Self.ms(receipt.receivedAt), observedAtMS: now, origin: "incoming_persisted")])
                scheduleFlush()
            } catch { archive.markUnavailable() }
        }
    }
    private func restore() throws {
        guard !loaded else { return }
        // Failure to restore the diagnostic history never erases recording data.
        // Corrupt history stays unavailable; never silently replace it with invented events.
        var previous: [UUID: SyncEvidenceSource] = [:]
        do {
            if let snapshot = try archive.load() {
                previous = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.segmentID, $0) })
                historyUnavailable = snapshot.context.counts["history_unavailable"] == 1
            }
        } catch { historyUnavailable = true; archive.markUnavailable(); throw error }
        let snapshot = try repository.transferEvidenceSnapshot()
        let receipts = Dictionary(uniqueKeysWithValues: snapshot.receipts.map { ($0.segmentID, $0) })
        var next: [UUID: SyncEvidenceSource] = [:]
        for manifest in snapshot.manifests {
            let receipt = receipts[manifest.id], old = previous[manifest.id]
            if let old {
                guard old.sha256 == manifest.sha256, old.byteCount == manifest.byteCount,
                      old.startedAtMS == Self.ms(manifest.startedAt) else { throw SyncEvidenceArchive.Failure.invalid }
            }
            if let receipt, let old, old.receiptAtMS == Self.ms(receipt.receivedAt) { next[manifest.id] = old; continue }
            next[manifest.id] = .init(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount,
                startedAtMS: Self.ms(manifest.startedAt), origin: receipt == nil ? "no_receipt_metadata" : "stored_receipt_metadata",
                receiptAtMS: receipt.map { Self.ms($0.receivedAt) }, artifacts: receipt.map { receipt in
                    [.init(kind: "audio", sha256: receipt.sha256, byteCount: receipt.byteCount, state: "phone_persisted",
                        recordedAtMS: Self.ms(receipt.receivedAt), origin: "stored_receipt_metadata")]
                } ?? [])
        }
        rows = next; loaded = true
    }
    private func scheduleFlush() {
        guard !flushPending else { return }
        flushPending = true
        queue.asyncAfter(deadline: .now() + 0.25) { [self] in
            flushPending = false
            do { try publish() } catch { archive.markUnavailable() }
        }
    }
    private func publish() throws {
        let values = Array(rows.values)
        try archive.publish(rows: values, context: .init(scope: "phone_library_metadata", discoveryComplete: true,
            counts: ["manifest_count": values.count, "receipt_count": values.filter { $0.receiptAtMS != nil }.count,
                "observed_incoming_source_count": values.filter { $0.firstObservedAtMS != nil }.count,
                "history_unavailable": historyUnavailable ? 1 : 0]))
        _ = archive.observe(processRunID: VerifiedObservationPublisher.processRunID, sourceDidChange: true)
    }
    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero)) }
}
