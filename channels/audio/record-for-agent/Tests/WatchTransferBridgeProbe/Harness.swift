import Foundation
import CryptoKit
import OSLog
import RecordingCore

// Both production singleton references are redirected here by verify.py.
// The real runtime observer only writes beneath this synthetic temporary root.
enum ProbeRuntimeDiagnostics {
    static let shared = WatchRuntimeDiagnostics(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("wristrecord-runtime-probe-" + UUID().uuidString), build: "probe")
}

// The only platform substitute is WCSession. Production bridge and repository
// logic, retry persistence, manifests, ACK files and audio cleanup run unchanged.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func access<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body(&value)
    }
    var current: Value { access { $0 } }
}

@objc enum WCSessionActivationState: Int { case notActivated, inactive, activated }
protocol WCSessionDelegate: AnyObject {}
final class WCSessionFile: @unchecked Sendable {
    let fileURL: URL
    let metadata: [String: Any]?
    init(fileURL: URL, metadata: [String: Any]?) { self.fileURL = fileURL; self.metadata = metadata }
}
final class WCSessionFileTransfer: @unchecked Sendable {
    let file: WCSessionFile
    let progress = Progress(totalUnitCount: 100)
    var isTransferring = false
    let cancellationCount = Locked(0)
    let cancellationAction = Locked<(() -> Void)?>(nil)
    init(fileURL: URL, metadata: [String: Any]?) { file = WCSessionFile(fileURL: fileURL, metadata: metadata) }
    // Real cancellation is asynchronous: it deliberately does not remove this
    // task from the fake system queue. Only removeFromSystemQueue can do that.
    func cancel() {
        cancellationCount.access { $0 += 1 }
        cancellationAction.current?()
    }
    var manifest: SegmentManifest? {
        guard let data = file.metadata?[TransportCodec.manifestKey] as? Data else { return nil }
        return try? TransportCodec.decode(SegmentManifest.self, from: data)
    }
}
final class WCSessionUserInfoTransfer: @unchecked Sendable {
    let userInfo: [String: Any]
    let cancellationCount = Locked(0)
    init(_ userInfo: [String: Any]) { self.userInfo = userInfo }
    func cancel() { cancellationCount.access { $0 += 1 } }
}
final class ProbeMessage: @unchecked Sendable {
    let payload: [String: Any]
    let reply: (([String: Any]) -> Void)?
    let fail: ((Error) -> Void)?
    init(_ payload: [String: Any], reply: (([String: Any]) -> Void)?, fail: ((Error) -> Void)?) {
        self.payload = payload; self.reply = reply; self.fail = fail
    }
}
final class WCSession: NSObject, @unchecked Sendable {
    struct State {
        var files: [WCSessionFileTransfer] = []
        var allEnqueued: [WCSessionFileTransfer] = []
        var userInfo: [WCSessionUserInfoTransfer] = []
        var contexts: [[String: Any]] = []
        var contextAttempts = 0
        var remainingContextFailures = 0
        var maximumOutstanding = 0
        var outstandingReads = 0
        var messages = 0
        var messagePayloads: [[String: Any]] = []
    }
    static var `default` = WCSession()
    static func isSupported() -> Bool { true }
    weak var delegate: WCSessionDelegate?
    @objc dynamic var activationState = WCSessionActivationState.activated
    @objc dynamic var hasContentPending = false
    var isReachable = true
    var iOSDeviceNeedsUnlockAfterRebootForReachability = false
    var isCompanionAppInstalled = true
    let state = Locked(State())
    let contextGate = Locked<DispatchSemaphore?>(nil)
    let contextGateEntered = Locked(false)
    let outstandingReadAction = Locked<((Int) -> Void)?>(nil)
    let userInfoReadAction = Locked<(() -> Void)?>(nil)
    let fileEnqueueAction = Locked<(() -> Void)?>(nil)
    let userInfoEnqueueAction = Locked<((WCSessionUserInfoTransfer) -> Void)?>(nil)
    let messageAction = Locked<((ProbeMessage) -> Void)?>(nil)
    var outstandingFileTransfers: [WCSessionFileTransfer] {
        let observed = state.access { value -> ([WCSessionFileTransfer], Int) in
            value.outstandingReads += 1
            return (value.files, value.outstandingReads)
        }
        outstandingReadAction.current?(observed.1)
        return observed.0
    }
    var outstandingUserInfoTransfers: [WCSessionUserInfoTransfer] {
        let observed = state.current.userInfo
        userInfoReadAction.current?()
        return observed
    }
    var applicationContext: [String: Any] { state.current.contexts.last ?? [:] }
    let activationCalls = Locked(0)
    func activate() { activationCalls.access { $0 += 1 } }
    func updateApplicationContext(_ context: [String: Any]) throws {
        let shouldFail = state.access { value -> Bool in
            value.contextAttempts += 1
            guard value.remainingContextFailures > 0 else { return false }
            value.remainingContextFailures -= 1
            return true
        }
        if shouldFail { throw NSError(domain: "SyntheticContextFailure", code: 1) }
        state.access { $0.contexts.append(context) }
        let gate = contextGate.access { value -> DispatchSemaphore? in
            let gate = value; value = nil; return gate
        }
        if let gate {
            contextGateEntered.access { $0 = true }
            _ = gate.wait(timeout: .now() + 10)
        }
    }
    @discardableResult func transferFile(_ url: URL, metadata: [String: Any]?) -> WCSessionFileTransfer {
        let transfer = WCSessionFileTransfer(fileURL: url, metadata: metadata)
        state.access {
            $0.files.append(transfer); $0.allEnqueued.append(transfer)
            $0.maximumOutstanding = max($0.maximumOutstanding, $0.files.count)
        }
        fileEnqueueAction.current?()
        return transfer
    }
    @discardableResult func transferUserInfo(_ payload: [String: Any]) -> WCSessionUserInfoTransfer {
        let transfer = WCSessionUserInfoTransfer(payload)
        state.access { $0.userInfo.append(transfer) }
        userInfoEnqueueAction.current?(transfer)
        return transfer
    }
    func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?,
                     errorHandler: ((Error) -> Void)?) {
        state.access { $0.messages += 1; $0.messagePayloads.append(message) }
        if let action = messageAction.current {
            action(ProbeMessage(message, reply: replyHandler, fail: errorHandler))
        } else { replyHandler?(["requestReceived": true]) }
    }
    func removeFromSystemQueue(_ transfer: WCSessionFileTransfer) {
        state.access { $0.files.removeAll { $0 === transfer } }
    }
    func removeFromSystemQueue(_ transfer: WCSessionUserInfoTransfer) {
        state.access { $0.userInfo.removeAll { $0 === transfer } }
    }
    func addLegacyTask(url: URL, metadata: [String: Any]?) -> WCSessionFileTransfer {
        let task = WCSessionFileTransfer(fileURL: url, metadata: metadata)
        state.access {
            $0.files.append(task); $0.maximumOutstanding = max($0.maximumOutstanding, $0.files.count)
        }
        return task
    }
}

// The unchanged production application delegate is compiled alongside these
// task shells. Production model ownership/lifecycle methods are extracted by
// verify.py; only their UI/audio dependencies use the synthetic shells below.
protocol WKApplicationDelegate: AnyObject {}
enum WKApplicationState { case active, inactive, background }
@MainActor final class WKApplication {
    private static let instance = WKApplication()
    static func shared() -> WKApplication { instance }
    var applicationState = WKApplicationState.inactive
    var refreshRequests: [Date] = []
    var refreshError: Error?
    func scheduleBackgroundRefresh(withPreferredDate date: Date, userInfo: Any?,
                                   scheduledCompletion: @escaping (Error?) -> Void) {
        refreshRequests.append(date)
        scheduledCompletion(refreshError)
    }
}
class WKRefreshBackgroundTask: NSObject {
    var expirationHandler: (() -> Void)?
    var completionCount = 0
    func setTaskCompletedWithSnapshot(_ value: Bool) { completionCount += 1 }
}
final class WKWatchConnectivityRefreshBackgroundTask: WKRefreshBackgroundTask {}
final class WKApplicationRefreshBackgroundTask: WKRefreshBackgroundTask {}
final class WKSnapshotRefreshBackgroundTask: WKRefreshBackgroundTask {
    func setTaskCompleted(restoredDefaultState: Bool, estimatedSnapshotExpiration: Date?, userInfo: Any?) {
        completionCount += 1
    }
}
final class ProbeCaptureEngine { var isRunning = true }
final class ProbeWaveform { func setVisible(_ visible: Bool) {} }
final class ProbeRecordingLocation {
    var isForeground = false
    var isActuallyRecording: () -> Bool = { false }
    var onLocation: ((SegmentLocation) -> Void)?
    var onClearLocation: (() -> Void)?
    var interfaceReadyCount = 0
    var recordingActive = false
    func setForeground(_ value: Bool) { isForeground = value }
    func refreshAuthorization() {}
    func setInterfaceReady() { interfaceReadyCount += 1 }
    func setRecordingActive(_ value: Bool) { recordingActive = value }
}
@MainActor final class WatchRecorderModel {
    static let shared = WatchRecorderModel()
    var bridge: WatchTransferBridge?
    var isForeground = false
    var lifecyclePolicy = WatchLifecyclePolicy()
    var foregroundEffectCount = 0
    var initialized = true
    var wantsRecording = false
    var engine: ProbeCaptureEngine?
    let recordingLocation = ProbeRecordingLocation()
    let waveform = ProbeWaveform()
    var syncFeedbackTask: Task<Void, Never>?
    var integrityPollTask: Task<Void, Never>?
    private func updateIntegrityAvailability() {}
    // PRODUCTION_MODEL_LIFECYCLE_METHODS
    // The production dispatcher is executed exactly. Audio/UI preparation is
    // unavailable in this host probe, so count its activation effect explicitly.
    private func becameActive() {
        foregroundEffectCount += 1
        bridge?.foregroundDidChange(true)
        isForeground = true
        recordingLocation.setForeground(true)
        updateTransferMaintenanceAvailability()
        bridge?.resynchronize()
    }
    func performBackgroundConnectivityTask(id: UUID, completion: @escaping @Sendable () -> Void) {
        bridge?.performBackgroundConnectivityTask(id: id, completion: completion)
    }
    func performBackgroundRefreshTask(id: UUID, completion: @escaping @Sendable () -> Void) {
        bridge?.performBackgroundRefreshTask(id: id, completion: completion)
    }
    func expireBackgroundConnectivityTask(id: UUID) { bridge?.expireBackgroundConnectivityTask(id: id) }
}

// This separate shell runs the complete production cold-start methods. Only
// platform/audio/UI dependencies below are synthetic; setup uses the real
// repository and bridge, so a blocked root is a real storage-open failure.
enum ProbeColdStartEnvironment {
    static var repositoryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wristrecord-unused-cold-start-" + UUID().uuidString)
}
enum ProbeColdStartupDiagnostics {
    final class Recorder: @unchecked Sendable {
        let events = Locked<Set<WatchStartupDiagnostics.Event>>([])
        func recordOnce(_ event: WatchStartupDiagnostics.Event) { events.access { _ = $0.insert(event) } }
    }
    static let shared = Recorder()
}
enum ProbeBatteryState { case unknown, unplugged, charging, full }
final class WKInterfaceDevice: @unchecked Sendable {
    private static let instance = WKInterfaceDevice()
    static func current() -> WKInterfaceDevice { instance }
    var isBatteryMonitoringEnabled = false
    var batteryState = ProbeBatteryState.unplugged
    var batteryLevel: Float = 0.5
}
// PRODUCTION_WRITER_STATUS_TYPE

final class ProbeColdAudioWriter: @unchecked Sendable {
    let repository: RecordingRepository
    let root: URL
    var onStatus: (@Sendable (WatchRecordingStatus) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    var loadCount = 0
    var refreshCount = 0
    var queryCount = 0
    var location: SegmentLocation?
    var logs: [String] = []
    init(repository: RecordingRepository, root: URL, waveform: ProbeWaveform) {
        self.repository = repository
        self.root = root
    }
    // Never create an audio engine, microphone, real history scan or location
    // driver. Tests deliver a synthetic writer result through the real callback.
    func load() { loadCount += 1 }
    func refreshStatus() { refreshCount += 1 }
    func queryStatus(completion: @escaping @Sendable (RecorderSnapshot?) -> Void) {
        queryCount += 1; completion(nil)
    }
    func updateLocation(_ value: SegmentLocation?) { location = value }
    func inspectAudioFreshness(_ completion: @escaping @Sendable (Date?, Date) -> Void) {
        completion(nil, Date())
    }
    func log(kind: String, detail: String) { logs.append(kind) }
    func deliver(_ status: WatchRecordingStatus) { onStatus?(status) }
}
final class ProbeColdIntegrityAudit {
    var onMessage: (@Sendable (String) -> Void)?
    init(sourceRoot: URL) {}
    func acceptLaunchArguments(_ arguments: [String]) {}
}
@MainActor final class ProbeColdStartModel {
    var snapshot = RecorderSnapshot(state: .idle)
    var effectiveDuration: TimeInterval = 0
    var sealedCount = 0
    var freeBytes: Int64?
    var isBusy = true
    var activityText = "正在检查本地录音"
    var errorMessage: String?
    var syncWarning: String?
    var recoveryMessage: String?
    var pendingCountIsKnown = false
    var pendingCountIsRefreshing = false
    var syncFeedback = SyncFeedback()
    var transferMessage: String?
    var integrityAuditMessage: String?
    var observationPreparationMessage = ""
    private var observationPreparationRequest = UUID()
    private var observationPreparationCooldownSeconds = 0
    var batteryLevel: Float = -1
    let recordingLocation = ProbeRecordingLocation()
    let waveform = ProbeWaveform()
    var repository: RecordingRepository?
    var writer: ProbeColdAudioWriter?
    var bridge: WatchTransferBridge?
    var engine: ProbeCaptureEngine?
    var engineStartedAt: Date?
    var wantsRecording = false
    var interruptionActive = false
    var finishing = false
    var initialized = false
    var isForeground = false
    var lifecyclePolicy = WatchLifecyclePolicy()
    var transferInitializationFailed = false
    var storageRecoveryRefreshDate: Date?
    var integrityAudit: ProbeColdIntegrityAudit?
    var syncFeedbackTask: Task<Void, Never>?
    var integrityPollTask: Task<Void, Never>?
    var operation = UUID()
    struct CaptureAttempt {
        let token: AudioRecoveryPolicy.Attempt
        let elapsedMS: Int64 = 0
    }
    var activeAttempt: CaptureAttempt?
    var recoveryPolicy = AudioRecoveryPolicy()
    var lastStatusRevision: UInt64 = 0
    var forceNextStatusSync = false
    var lastSyncedAudioAt: Date?
    var lastSyncedState: CaptureState?
    var lastSyncedPendingCount: Int?
    var lastSyncedPendingCountIsKnown: Bool?
    var lastSyncedSealedAt: Date?
    var lastBatteryLoggedSegmentCount = -1
    var audioSessionObserverCount = 0
    var feedbackStartCount = 0
    var integrityPollingStartCount = 0
    var captureEffects = 0
    private let logger = Logger(subsystem: "WristRecordSyntheticProbe", category: "cold-start")
    // PRODUCTION_MODEL_COLD_START_METHODS
    private func observeAudioSession() { audioSessionObserverCount += 1 }
    private func startIntegrityPolling() { integrityPollingStartCount += 1 }
    private func startSyncFeedbackUpdates() { feedbackStartCount += 1 }
    private func updateIntegrityAvailability() {}
    private func receiveSyncFeedback(_ value: SyncFeedback) {}
    private func fail(_ message: String) { errorMessage = message; captureEffects += 1 }
    private func cancelCaptureAttempts(reason: String) { captureEffects += 1 }
    private func finishCapture(state: CaptureState, detail: String) { captureEffects += 1 }
    private func logCapture(_ kind: String, attempt: CaptureAttempt? = nil, detail: String) {}
}

enum ProbeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

struct FileIdentity: Equatable {
    let inode: UInt64
    let modificationDate: Date
    let data: Data
    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        inode = (attributes[.systemFileNumber] as! NSNumber).uint64Value
        modificationDate = attributes[.modificationDate] as! Date
        data = try Data(contentsOf: url)
    }
}

final class Fixture: @unchecked Sendable {
    let root: URL
    let watch: RecordingRepository
    let phone: RecordingRepository
    let session = WCSession()
    var bridge: WatchTransferBridge
    let recordingSession: RecordingSession
    private let recentCaptureBase = Date().addingTimeInterval(-120)
    let changes = Locked(0)
    let feedback = Locked<[SyncFeedback]>([])
    let issues = Locked<[String]>([])
    let recoveryTime = Locked((date: Date(timeIntervalSince1970:
        (Date().timeIntervalSince1970 * 1_000).rounded() / 1_000), uptime: ProcessInfo.processInfo.systemUptime))
    let receiptRequestUptime = Locked<TimeInterval>(1_000)
    let charging = Locked(false)
    let handoffTime = Locked<TimeInterval>(0)
    let availableCapacity = Locked<Int64?>(1_024 * 1_024 * 1_024)
    let capacityReadAction = Locked<(() -> Void)?>(nil)
    let refreshRequests = Locked<[Date]>([])
    var refreshAutoCompletion: Bool?
    var recoveryIdleInterval = OutstandingFileTransferPolicy.minimumIdle
    var recoveryReceiptGrace: TimeInterval = 60

    init(root: URL, fault: ((RepositoryFaultPoint) throws -> Void)? = nil) throws {
        self.root = root
        watch = try RecordingRepository(root: root.appendingPathComponent("watch"), faultInjector: fault)
        phone = try RecordingRepository(root: root.appendingPathComponent("phone"))
        var active = try watch.createSession(at: Date(timeIntervalSince1970: 1_700_000_000))
        active.state = .recording
        try watch.saveSession(active)
        recordingSession = active
        WCSession.default = session
        bridge = WatchTransferBridge(repository: watch, powerStateProvider: { [charging] in charging.current },
            diagnosticClock: { [recoveryTime] in recoveryTime.current.date },
            handoffClock: { [handoffTime] in handoffTime.current },
            availableCapacityProvider: { [availableCapacity, capacityReadAction] in
                capacityReadAction.current?(); return availableCapacity.current
            }, recoveryContinuityID: "synthetic-watch-boot",
            recoveryClock: { [recoveryTime] in recoveryTime.current },
            receiptRequestUptime: { [receiptRequestUptime] in receiptRequestUptime.current })
        installCallbacks()
    }
    func installCallbacks() {
        let changes = changes, feedback = feedback, issues = issues
        bridge.onRepositoryChanged = { changes.access { $0 += 1 } }
        bridge.onSyncFeedback = { value in feedback.access { $0.append(value) } }
        bridge.onIssue = { value in issues.access { $0.append(value) } }
        if let acceptance = refreshAutoCompletion {
            bridge.onBackgroundRefreshRequested = { [weak self] date in
                self?.refreshRequests.access { $0.append(date) }
                self?.bridge.backgroundRefreshSchedulingStarted(preferredDate: date)
                if acceptance {
                    self?.bridge.backgroundRefreshSchedulingCompleted(preferredDate: date, succeeded: true)
                }
            }
        }
    }
    func restartBridge(maintenanceAllowed: Bool = true,
                       recoveryIdleInterval: TimeInterval? = nil,
                       recoveryReceiptGrace: TimeInterval? = nil) {
        if let recoveryIdleInterval { self.recoveryIdleInterval = recoveryIdleInterval }
        if let recoveryReceiptGrace { self.recoveryReceiptGrace = recoveryReceiptGrace }
        WCSession.default = session
        bridge = WatchTransferBridge(repository: watch, maintenanceAllowed: maintenanceAllowed,
            powerStateProvider: { [charging] in charging.current },
            diagnosticClock: { [recoveryTime] in recoveryTime.current.date },
            handoffClock: { [handoffTime] in handoffTime.current },
            availableCapacityProvider: { [availableCapacity, capacityReadAction] in
                capacityReadAction.current?(); return availableCapacity.current
            }, recoveryIdleInterval: self.recoveryIdleInterval,
            recoveryReceiptGrace: self.recoveryReceiptGrace,
            recoveryContinuityID: "synthetic-watch-boot",
            recoveryClock: { [recoveryTime] in recoveryTime.current },
            receiptRequestUptime: { [receiptRequestUptime] in receiptRequestUptime.current })
        installCallbacks()
    }
    var transferDiagnostics: WatchTransferDiagnosticStore {
        Mirror(reflecting: bridge).children.first { $0.label == "transferDiagnosticStore" }!.value as! WatchTransferDiagnosticStore
    }
    func transferEvents() -> [RecordingEvent] { transferDiagnostics.events(limit: WatchTransferDiagnosticStore.maximumEvents) }
    var backgroundSyncReportURL: URL {
        watch.root.appendingPathComponent("ConnectivityDiagnostics/background-sync.json")
    }
    func backgroundSyncReport() throws -> [String: Any] {
        let bytes = try Data(contentsOf: backgroundSyncReportURL)
        guard !bytes.isEmpty, bytes.count <= 8_192,
              let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ProbeFailure.failed("Expected a bounded typed background report")
        }
        return value
    }
    func seal(_ sequence: Int) throws -> SegmentManifest {
        try seal(sequence, startedAt: recentCaptureBase.addingTimeInterval(Double(sequence)))
    }
    func sealHistorical(_ sequence: Int) throws -> SegmentManifest {
        try sealHistorical(sequence, byteCount: 4_096)
    }
    func sealHistorical(_ sequence: Int, byteCount: Int) throws -> SegmentManifest {
        try seal(sequence, startedAt: recordingSession.startedAt.addingTimeInterval(Double(sequence * 60)), byteCount: byteCount)
    }
    private func seal(_ sequence: Int, startedAt start: Date, byteCount: Int = 4_096) throws -> SegmentManifest {
        let id = UUID()
        let staged = watch.stagingURL(for: id)
        try Data(repeating: UInt8(sequence % 250), count: byteCount).write(to: staged)
        return try watch.sealSegment(stagedURL: staged, id: id, sessionID: recordingSession.id,
            sequence: sequence, startedAt: start, endedAt: start.addingTimeInterval(60),
            sampleRate: 16_000, frameCount: 960_000)
    }
    func receipt(_ manifest: SegmentManifest) throws -> SegmentReceipt {
        try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
    }
    func deliver(_ receipt: SegmentReceipt, route: Int = 0) throws {
        let payload: [String: Any] = [TransportCodec.receiptKey: try TransportCodec.encode(receipt)]
        switch route % 3 {
        case 0: bridge.session(session, didReceiveUserInfo: payload)
        case 1: bridge.session(session, didReceiveMessage: payload)
        default: bridge.session(session, didReceiveMessage: payload, replyHandler: { _ in })
        }
    }
    func update(observedAt: Date = Date(), detail: String? = nil) {
        bridge.update(RecorderSnapshot(state: .recording, sessionID: recordingSession.id,
                                      observedAt: observedAt, detail: detail))
    }
    func ackURL(_ manifest: SegmentManifest) -> URL {
        watch.root.appendingPathComponent("acknowledgements/" + manifest.id.uuidString.lowercased() + ".json")
    }
    var retryURL: URL { watch.root.appendingPathComponent("transfer-retry-state.json") }
    var schedulingURL: URL { watch.root.appendingPathComponent("transfer-scheduling-state.json") }
    var refreshURL: URL { watch.root.appendingPathComponent("transfer-background-refresh-state.json") }
    var automaticSyncURL: URL { watch.root.appendingPathComponent("transfer-automatic-sync-state.json") }
    var receiptCursorURL: URL { watch.root.appendingPathComponent("transfer-receipt-request-position.json") }
    func automaticRequest(id: UUID = UUID(), at date: Date = Date()) -> [String: Any] {
        [TransportCodec.requestSyncKey: true, "automaticSyncSchemaVersion": 1,
         "automaticSyncRequestID": id.uuidString,
         "automaticSyncRequestedAtMS": Int64((date.timeIntervalSince1970 * 1_000).rounded())]
    }
    func enableBackgroundRefresh(autoAccept: Bool = true) {
        refreshAutoCompletion = autoAccept
        installCallbacks()
    }
    func retryState() throws -> FileTransferRetryPolicy {
        try TransportCodec.decode(FileTransferRetryPolicy.self, from: Data(contentsOf: retryURL))
    }
    func retryAttempt(_ manifest: SegmentManifest) throws -> [String: Any] {
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: retryURL)) as! [String: Any]
        let attempts = data["attempts"] as! [[String: Any]]
        guard let attempt = attempts.first(where: {
            (($0["manifest"] as? [String: Any])?["id"] as? String)?.lowercased() == manifest.id.uuidString.lowercased()
        }) else { throw ProbeFailure.failed("Expected synthetic retry attempt missing") }
        return attempt
    }
    func complete(_ task: WCSessionFileTransfer, error: Error? = nil) {
        session.removeFromSystemQueue(task)
        bridge.session(session, didFinish: task, error: error)
    }
    var receiptRequests: [[String: Any]] {
        session.outstandingUserInfoTransfers.map(\.userInfo).filter { $0[TransportCodec.requestSyncKey] as? Bool == true }
    }
    func requestTarget(_ payload: [String: Any]) throws -> TargetedReceiptRequest? {
        guard let data = payload[TransportCodec.targetedReceiptRequestKey] as? Data else { return nil }
        return try TransportCodec.decode(TargetedReceiptRequest.self, from: data)
    }
    func publishedSnapshots() throws -> [RecorderSnapshot] {
        try session.state.current.contexts.compactMap { context in
            guard let data = context[TransportCodec.snapshotKey] as? Data else {
                if let runtime = context[TransportCodec.watchRuntimeKey] as? Data,
                   WatchRuntimeObservation.decode(runtime) != nil { return nil }
                throw ProbeFailure.failed("Application context must carry a recorder snapshot.")
            }
            return try TransportCodec.decode(RecorderSnapshot.self, from: data)
        }
    }
}

@MainActor final class Probe {
    let root: URL
    var assertions = 0
    var cases: [[String: Any]] = []
    init(root: URL) { self.root = root }
    func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        guard try value() else { throw ProbeFailure.failed(message) }
    }
    func eventually(_ reason: String, _ predicate: () throws -> Bool) async throws {
        for _ in 0..<500 {
            if try predicate() { assertions += 1; return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ProbeFailure.failed("Timed out: " + reason)
    }
    // Event polling must share the bridge's writer queue. This preserves the
    // original condition/deadline and propagates read failures without retrying
    // a partially observed write from the unrelated main-actor test task.
    func eventuallyOnBridgeQueue(_ f: Fixture, _ reason: String,
                                 _ predicate: @escaping @Sendable () throws -> Bool) async throws {
        guard let queue = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "work" })?.value as? DispatchQueue else {
            throw ProbeFailure.failed("Production bridge serial queue not found")
        }
        for _ in 0..<500 {
            let matched = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                queue.async { continuation.resume(with: Result { try predicate() }) }
            }
            if matched { assertions += 1; return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ProbeFailure.failed("Timed out: " + reason)
    }
    func report(_ f: Fixture, _ reason: String, matching predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        var observed: [String: Any] = [:]
        try await eventually(reason) {
            guard let value = try? f.backgroundSyncReport(), predicate(value) else { return false }
            observed = value
            return true
        }
        return observed
    }
    // Observe the actual serial queue without adding a production test API.
    // Two barriers also cross the refresh closure coalesced by prior callbacks.
    // Headless mode deliberately does not publish UI feedback.
    func settle(_ f: Fixture) async throws {
        guard let queue = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "work" })?.value as? DispatchQueue else {
            throw ProbeFailure.failed("Production bridge serial queue not found")
        }
        for _ in 0..<2 {
            f.bridge.refreshFeedback()
            await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        }
    }
    // Unlike settle(), this observes coalesced work without requesting feedback
    // or introducing a new owner signal of its own.
    func drainQueuedWork(_ f: Fixture) async throws {
        guard let queue = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "work" })?.value as? DispatchQueue else {
            throw ProbeFailure.failed("Production bridge serial queue not found")
        }
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        }
    }
    func receiptOpportunity(_ f: Fixture) async throws {
        let done = Locked(0)
        f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
        try await eventually("bounded receipt opportunity finished") { done.current == 1 }
        try await drainQueuedWork(f)
    }
    func drainReportWrites(_ f: Fixture) async throws {
        try await drainQueuedWork(f)
        guard let observer = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "backgroundSyncDiagnostics" })?.value,
              let queue = Mirror(reflecting: observer).children.first(where: { $0.label == "io" })?.value as? DispatchQueue else {
            throw ProbeFailure.failed("Production report writer queue missing")
        }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    func retryWake(_ f: Fixture) -> DispatchWorkItem? {
        guard let value = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "retryWake" })?.value else { return nil }
        return Mirror(reflecting: value).children.first?.value as? DispatchWorkItem
    }
    func fireRetryWake(_ f: Fixture) async throws {
        guard let item = retryWake(f),
              let queue = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "work" })?.value as? DispatchQueue else {
            throw ProbeFailure.failed("A production retry work item must exist before simulating its firing.")
        }
        // Execute the exact installed production work item on its real queue;
        // no rewritten retry implementation or timing sleep is substituted.
        let installed = Locked(item)
        await withCheckedContinuation { continuation in
            queue.async { installed.current.perform(); continuation.resume() }
        }
        try await drainQueuedWork(f)
    }
    func run(_ name: String, fault: ((RepositoryFaultPoint) throws -> Void)? = nil,
             _ body: (Fixture) async throws -> Void) async {
        if let filter = ProcessInfo.processInfo.environment["RFA_PROBE_CASE_FILTER"],
           !filter.isEmpty, !name.contains(filter) { return }
        do {
            let f = try Fixture(root: root.appendingPathComponent(name), fault: fault)
            WatchRecorderModel.shared.lifecyclePolicy = WatchLifecyclePolicy()
            WatchRecorderModel.shared.foregroundEffectCount = 0
            WKApplication.shared().applicationState = .inactive
            try await body(f)
            try await settle(f)
            try check(try f.watch.sessions().first?.state == .recording,
                      "Transfer work must preserve the source's active recording state.")
            cases.append(["name": name, "status": "passed"])
        } catch {
            cases.append(["name": name, "status": "failed", "error": String(describing: error)])
        }
    }

    func drainBacklog(_ observer: WatchBacklogEvidence) async throws {
        guard let queue = Mirror(reflecting: observer).children.first(where: { $0.label == "io" })?.value as? DispatchQueue else {
            throw ProbeFailure.failed("Backlog diagnostic queue missing")
        }
        for _ in 0..<3 { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    }
    func backlogSummary(_ root: URL, current: Bool = false) throws -> WatchBacklogEvidence.Summary {
        let directory = "ConnectivityDiagnostics/" + (current ? WatchBacklogEvidence.currentDirectory + "/" : "")
        let bytes = try Data(contentsOf: root.appendingPathComponent(directory + "watch-backlog.json"))
        try check(bytes.count <= WatchBacklogEvidence.maximumSummaryBytes, "Summary must remain within fixed 64 KiB cap")
        return try TransportCodec.decode(WatchBacklogEvidence.Summary.self, from: bytes)
    }
    func backlogPages(_ root: URL, _ summary: WatchBacklogEvidence.Summary) throws -> [WatchBacklogEvidence.Page] {
        try summary.pages.enumerated().map { index, binding in
            let name = String(format: "page-%04d-g%020llu.json", index, binding.generation)
            let directory = "ConnectivityDiagnostics/" + (summary.supersedes != nil ? WatchBacklogEvidence.currentDirectory + "/" : "")
            let url = root.appendingPathComponent(directory + "BacklogEvidence/" + summary.sourceSetID.uuidString.lowercased() + "/" + name)
            let bytes = try Data(contentsOf: url)
            try check(bytes.count == binding.byteLength && bytes.count <= 32_768, "Each exact page length must fit 32 KiB")
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try check(digest == binding.sha256, "Each page is bound by metadata-byte SHA256")
            let page = try TransportCodec.decode(WatchBacklogEvidence.Page.self, from: bytes)
            try check(page.sourceSetID == summary.sourceSetID && page.index == index && page.generation == binding.generation,
                      "A summary cannot mix source sets, page indices or page generations")
            return page
        }
    }
    func legacyEmptyBacklog(_ root: URL) throws -> WatchBacklogEvidence.Summary {
        let directory = root.appendingPathComponent("ConnectivityDiagnostics")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let empty = WatchBacklogEvidence.Summary(schemaVersion: 1, role: "watch", scope: "frozen_manifest_metadata_catalog",
            sourceSetID: UUID(), generation: 2, build: "67", processRunID: UUID(), capturedAtMS: 1_000,
            generatedAtMS: 1_001, sourceCount: 0, totalByteCount: 0,
            catalogSHA256: SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined(), pages: [],
            historicalACKMetadataCount: 0, historicalReceiptMetadataCount: 0, enqueuedMemberCount: 0,
            successfulACKConfirmationMemberCount: 0, newACKCommittedMemberCount: 0, pendingNonHistoricalMemberCount: 0,
            outsideCohortObservationCount: 0, identityConflictCount: 0, identityReadFailureCount: 0, observationOverflowCount: 0,
            sourceSetComplete: true, allNonHistoricalMembersACKConfirmed: true, audioRead: false, includesAudio: false,
            historicalACKMeaning: "historical_ack_metadata_not_new_durability",
            pendingMeaning: "frozen_members_without_historical_ack_or_later_successful_ack_confirmation_not_audio_availability",
            cloudCompletionProven: false)
        try TransportCodec.encode(empty).write(to: directory.appendingPathComponent("watch-backlog.json"))
        try Data("{\"schemaVersion\":1,\"state\":\"legacy_ready\",\"build\":\"67\"}".utf8)
            .write(to: directory.appendingPathComponent("watch-backlog-status.json"))
        return empty
    }
    func metadataFixture(_ root: URL, count: Int) throws -> (RecordingRepository, [SegmentManifest]) {
        let repository = try RecordingRepository(root: root, recoverTransactionsOnInitialization: false)
        let session = UUID(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let manifests = try (0..<count).map { index -> SegmentManifest in
            let id = UUID()
            let value = SegmentManifest(id: id, sessionID: session, sequence: index, startedAt: date.addingTimeInterval(Double(index)),
                endedAt: date.addingTimeInterval(Double(index + 1)), sampleRate: 16_000, frameCount: 16_000,
                fileName: id.uuidString.lowercased() + ".caf", byteCount: 4096, sha256: String(repeating: "a", count: 64))
            try TransportCodec.encode(value).write(to: root.appendingPathComponent("manifests/" + id.uuidString.lowercased() + ".json"))
            return value
        }
        return (repository, manifests)
    }
    func backlogStatus(_ root: URL, current: Bool = false) throws -> [String: Any] {
        let directory = "ConnectivityDiagnostics/" + (current ? WatchBacklogEvidence.currentDirectory + "/" : "")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(
            directory + "watch-backlog-status.json"))) as! [String: Any]
    }
    func backlogPageIdentities(_ root: URL, _ summary: WatchBacklogEvidence.Summary) throws -> [FileIdentity] {
        let directory = "ConnectivityDiagnostics/" + (summary.supersedes != nil ? WatchBacklogEvidence.currentDirectory + "/" : "")
        return try summary.pages.enumerated().map { index, binding in
            let name = String(format: "page-%04d-g%020llu.json", index, binding.generation)
            return try FileIdentity(root.appendingPathComponent(directory + "BacklogEvidence/"
                + summary.sourceSetID.uuidString.lowercased() + "/" + name))
        }
    }
    func seededBacklog(_ root: URL, build: String, current: Bool = false) async throws -> (RecordingRepository, [SegmentManifest]) {
        let (repository, manifests) = try metadataFixture(root, count: 3)
        if current { _ = try legacyEmptyBacklog(root) }
        let historical = manifests[0]
        let receipt = SegmentReceipt(segmentID: historical.id, sha256: historical.sha256, byteCount: historical.byteCount)
        for folder in ["receipts", "acknowledgements"] {
            try TransportCodec.encode(receipt).write(to: root.appendingPathComponent(folder + "/" + historical.id.uuidString.lowercased() + ".json"))
        }
        let observer = WatchBacklogEvidence(root: root, build: build, processRunID: UUID())
        observer.captureIfNeeded { try repository.transferEvidenceSnapshot() }
        try await drainBacklog(observer)
        _ = try backlogSummary(root, current: current)
        let manifest = manifests[1]
        let realACK = SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount)
        _ = try repository.acknowledge(realACK, pruneAudio: false)
        let context = WatchBacklogEvidence.Context(foreground: false, liveCapture: false, externalPower: true, opportunity: 83)
        // Use the production clock: a fast fixture can publish within two
        // milliseconds of capture, so capture + 2 can fabricate a future ACK
        // and correctly fail the verified-metadata validator.
        observer.recordEnqueued(manifest, context: context)
        observer.recordAcknowledgement(realACK, manifest: manifest, newlyCommitted: true, context: context)
        try await drainBacklog(observer)
        return (repository, manifests)
    }
    func checkFrozenBacklog(_ before: WatchBacklogEvidence.Summary, _ after: WatchBacklogEvidence.Summary) throws {
        func frozen(_ summary: WatchBacklogEvidence.Summary) throws -> NSDictionary {
            var object = try JSONSerialization.jsonObject(with: TransportCodec.encode(summary)) as! [String: Any]
            for key in ["build", "processRunID", "generation", "generatedAtMS"] { object.removeValue(forKey: key) }
            return object as NSDictionary
        }
        try check(try frozen(before).isEqual(frozen(after)),
            "Build publication may change only build, process run, summary generation and generatedAtMS; all frozen evidence remains identical.")
    }
    func backlogObservation(_ root: URL) throws -> VerifiedObservationPublisher.Receipt {
        try TransportCodec.decode(VerifiedObservationPublisher.Receipt.self,
            from: Data(contentsOf: root.appendingPathComponent("ConnectivityDiagnostics/verified-observation.json")))
    }
    func backlogObservationStatus(_ root: URL) throws -> VerifiedObservationPublisher.Status {
        try TransportCodec.decode(VerifiedObservationPublisher.Status.self,
            from: Data(contentsOf: root.appendingPathComponent("ConnectivityDiagnostics/verified-observation-status.json")))
    }
    func backlogSnapshotIndex(_ root: URL) throws -> [String: Any] {
        try XCTUnwrapProbe(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("ConnectivityDiagnostics/snapshot-index.json"))) as? [String: Any])
    }
    func pinnedBacklogPackage(_ root: URL, index: [String: Any]) throws -> [String: FileIdentity] {
        let generation = try XCTUnwrapProbe(index["generationID"] as? String)
        let directory = root.appendingPathComponent("ConnectivityDiagnostics/SnapshotGenerations/" + generation)
        let names = try FileManager.default.subpathsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }
        return try Dictionary(uniqueKeysWithValues: names.map { ($0, try FileIdentity(directory.appendingPathComponent($0))) })
    }
    func frozenDiagnosticFiles(_ root: URL) throws -> [String: FileIdentity] {
        let directory = root.appendingPathComponent("ConnectivityDiagnostics")
        var result: [String: FileIdentity] = [:]
        for name in try FileManager.default.subpathsOfDirectory(atPath: directory.path)
            where name.hasSuffix(".json") && !name.hasPrefix("verified-observation") {
            result[name] = try FileIdentity(directory.appendingPathComponent(name))
        }
        return result
    }
    func executeVerifiedBacklogObservationCases() async {
        for build in ["87", "88"] {
        await run("verified_backlog_build\(build)_source_failure_advances_fence_before_recovery") { f in
            for current in [false, true] {
                for stage in ["pages", "status"] {
                    let root = f.root.appendingPathComponent("snapshot-failure-\(current)-\(stage)")
                    let (_, manifests) = try await self.seededBacklog(root, build: build, current: current)
                    let shouldFail = Locked(false)
                    let observer = WatchBacklogEvidence(root: root, build: build, processRunID: UUID(), faultInjector: { point in
                        if point == .pagesWritten, shouldFail.current { throw POSIXError(.EIO) }
                    }, observationMinimumIntervalMS: 0)
                    try await self.drainBacklog(observer)
                    observer.observeVerifiedMetadata(); try await self.drainBacklog(observer)
                    let before = try self.backlogSnapshotIndex(root), package = try self.pinnedBacklogPackage(root, index: before)
                    try self.check(before["available"] as? Bool == true && !package.isEmpty,
                        "A fully validated build\(build) baseline must have a complete immutable package before the injected fault.")
                    let statusURL = root.appendingPathComponent("ConnectivityDiagnostics/"
                        + (current ? WatchBacklogEvidence.currentDirectory + "/" : "") + "watch-backlog-status.json")
                    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: statusURL.path) }
                    if stage == "pages" { shouldFail.access { $0 = true } }
                    else { try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: statusURL.path) }
                    let context = WatchBacklogEvidence.Context(foreground: true, liveCapture: false, externalPower: false, opportunity: nil)
                    observer.recordEnqueued(manifests[0], context: context)
                    try await self.drainBacklog(observer)
                    // Do not request a new observation: the source failure must
                    // invalidate the old pointer at the failure boundary itself.
                    let failed = try self.backlogSnapshotIndex(root)
                    try self.check(failed["available"] as? Bool == false
                        && failed["failureCode"] as? String == "source_publication_failed"
                        && failed["fenceID"] as? String != before["fenceID"] as? String,
                        "An actual source write failure immediately changes the error fence even if writing failure status is also blocked.")
                    try self.check(try self.pinnedBacklogPackage(root, index: before) == package,
                        "A failed source publication preserves every pinned manifest, page, receipt and status byte and file identity.")
                    shouldFail.access { $0 = false }
                    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: statusURL.path)
                    await withCheckedContinuation { done in observer.flush { done.resume() } }
                    try await self.drainBacklog(observer)
                    let recovered = try self.backlogSnapshotIndex(root)
                    try self.check(recovered["available"] as? Bool == true
                        && recovered["fenceID"] as? String == failed["fenceID"] as? String
                        && recovered["generationID"] as? String != before["generationID"] as? String,
                        "Recovery publishes a different generation while retaining the failure fence so an in-flight collector detects the intervening error.")
                    try self.check(try self.pinnedBacklogPackage(root, index: before) == package
                        && self.backlogObservation(root).sourceGeneratedAtMS == self.backlogSummary(root, current: current).generatedAtMS,
                        "Recovered observation uses the real source timestamp and leaves the older immutable package unchanged.")
                }
            }
        }
        }
        for (priorBuild, nextBuild) in [("87", "88"), ("88", "89")] {
        await run("verified_backlog_build\(priorBuild)_to\(nextBuild)_upgrade_and_enqueue_burst_preserves_live_events_and_pinned_generation") { f in
            for current in [false, true] {
                let root = f.root.appendingPathComponent("build\(nextBuild)-upgrade-burst-\(current)")
                let (_, manifests) = try await self.seededBacklog(root, build: priorBuild, current: current)
                let old = try self.backlogSummary(root, current: current)
                let oldPages = try self.backlogPageIdentities(root, old)
                let observer = WatchBacklogEvidence(root: root, build: nextBuild, processRunID: UUID())
                try await self.drainBacklog(observer)
                let upgraded = try self.backlogSummary(root, current: current)
                try self.checkFrozenBacklog(old, upgraded)
                try self.check(upgraded.build == nextBuild && upgraded.generation == old.generation + 1
                    && self.backlogPageIdentities(root, upgraded) == oldPages,
                    "Build\(priorBuild) upgrade republishes the binding while preserving the frozen catalogue, ACK history and page identities.")
                observer.observeVerifiedMetadata(); try await self.drainBacklog(observer)
                let before = try self.backlogSnapshotIndex(root)
                let package = try self.pinnedBacklogPackage(root, index: before)
                let initialReceipt = try self.backlogObservation(root)
                let initialMembers = try self.backlogPages(root, upgraded).flatMap(\.members)
                let initialEnqueues = try XCTUnwrapProbe(initialMembers.first { $0.segmentID == manifests[2].id }).enqueueCount
                let context = WatchBacklogEvidence.Context(foreground: true, liveCapture: false, externalPower: false, opportunity: nil)
                for _ in 0..<64 {
                    observer.recordEnqueued(manifests[2], context: context)
                    try await self.drainBacklog(observer)
                }
                let after = try self.backlogSummary(root, current: current)
                let receipt = try self.backlogObservation(root), index = try self.backlogSnapshotIndex(root)
                let members = try self.backlogPages(root, after).flatMap(\.members)
                try self.check(try XCTUnwrapProbe(members.first { $0.segmentID == manifests[2].id }).enqueueCount == initialEnqueues + 64
                    && after.newACKCommittedMemberCount == old.newACKCommittedMemberCount,
                    "Every real enqueue survives a burst without fabricating ACK completion.")
                try self.check(receipt.sequence >= initialReceipt.sequence + 64
                    && receipt.identity["generation"] == String(after.generation)
                    && receipt.sourceGeneratedAtMS == after.generatedAtMS,
                    "Every changed source is revalidated into the honest latest live observation during snapshot coalescing.")
                try self.check(index["available"] as? Bool == true
                    && index["generationID"] as? String == before["generationID"] as? String
                    && index["fenceID"] as? String == before["fenceID"] as? String
                    && self.pinnedBacklogPackage(root, index: before) == package,
                    "A sub-30-second build\(nextBuild) source burst keeps the same complete immutable package and fence, avoiding per-event quota growth.")
            }
        }
        }
        await run("verified_backlog_build87_failed_cold_restore_invalidates_prior_package") { f in
            let root = f.root.appendingPathComponent("snapshot-failed-cold-restore")
            _ = try await self.seededBacklog(root, build: "87")
            let observer = WatchBacklogEvidence(root: root, build: "87", processRunID: UUID(), observationMinimumIntervalMS: 0)
            try await self.drainBacklog(observer)
            observer.observeVerifiedMetadata(); try await self.drainBacklog(observer)
            let before = try self.backlogSnapshotIndex(root), package = try self.pinnedBacklogPackage(root, index: before)
            let summaryURL = root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog.json")
            try Data("{}".utf8).write(to: summaryURL)
            let invalidSummary = try FileIdentity(summaryURL), runID = UUID()
            let restarted = WatchBacklogEvidence(root: root, build: "87", processRunID: runID)
            try await self.drainBacklog(restarted)
            let failed = try self.backlogSnapshotIndex(root)
            try self.check(failed["available"] as? Bool == false
                && failed["failureCode"] as? String == "source_publication_failed"
                && failed["fenceID"] as? String != before["fenceID"] as? String
                && (failed["observerProcessRunID"] as? String)?.lowercased() == runID.uuidString.lowercased(),
                "A failing cold restore cannot expose the prior process's available snapshot, even without an explicit observation call.")
            try self.check(try self.pinnedBacklogPackage(root, index: before) == package
                && FileIdentity(summaryURL) == invalidSummary,
                "Cold restore failure preserves both the old immutable package and the rejected original source bytes.")
        }
        await run("verified_backlog_idle_same_build_fresh_sidecar_preserves_frozen_report_and_events") { f in
            for current in [false, true] {
                let root = f.root.appendingPathComponent(current ? "current-observed" : "legacy-observed")
                _ = try await self.seededBacklog(root, build: "86", current: current)
                // Seed a genuinely old source report; the production clock is
                // not replaced, and only the later sidecar may become fresh.
                let sourceDirectory = root.appendingPathComponent("ConnectivityDiagnostics/"
                    + (current ? WatchBacklogEvidence.currentDirectory : ""))
                let summaryURL = sourceDirectory.appendingPathComponent("watch-backlog.json")
                var aged = try JSONSerialization.jsonObject(with: Data(contentsOf: summaryURL)) as! [String: Any]
                var pageBindings = aged["pages"] as! [[String: Any]]
                let sourceSetID = (aged["sourceSetID"] as! String).lowercased()
                for index in pageBindings.indices {
                    let generation = pageBindings[index]["generation"] as! UInt64
                    let pageURL = sourceDirectory.appendingPathComponent("BacklogEvidence/" + sourceSetID + "/"
                        + String(format: "page-%04d-g%020llu.json", index, generation))
                    var page = try JSONSerialization.jsonObject(with: Data(contentsOf: pageURL)) as! [String: Any]
                    var members = page["members"] as! [[String: Any]]
                    for row in members.indices {
                        for key in ["firstEnqueuedAtMS", "lastEnqueuedAtMS", "firstACKConfirmedAtMS", "lastACKConfirmedAtMS", "firstNewACKCommittedAtMS"] {
                            if let old = members[row][key] as? Int64 { members[row][key] = old - 600_000 }
                        }
                    }
                    page["members"] = members
                    let bytes = try JSONSerialization.data(withJSONObject: page, options: [.sortedKeys])
                    try bytes.write(to: pageURL)
                    pageBindings[index]["byteLength"] = bytes.count
                    pageBindings[index]["sha256"] = VerifiedObservationPublisher.digest(bytes)
                }
                aged["pages"] = pageBindings
                aged["capturedAtMS"] = (aged["capturedAtMS"] as! Int64) - 600_000
                aged["generatedAtMS"] = (aged["generatedAtMS"] as! Int64) - 600_000
                try JSONSerialization.data(withJSONObject: aged, options: [.sortedKeys]).write(to: summaryURL)
                if current {
                    let witnessURL = sourceDirectory.appendingPathComponent("current-cohort.json")
                    var witness = try JSONSerialization.jsonObject(with: Data(contentsOf: witnessURL)) as! [String: Any]
                    witness["capturedAtMS"] = aged["capturedAtMS"]
                    try JSONSerialization.data(withJSONObject: witness, options: [.sortedKeys]).write(to: witnessURL)
                }
                let runID = UUID()
                let observer = WatchBacklogEvidence(root: root, build: "86", processRunID: runID,
                    observationMinimumIntervalMS: 0)
                try await self.drainBacklog(observer)
                let before = try self.frozenDiagnosticFiles(root), source = try self.backlogSummary(root, current: current)
                let rows = try self.backlogPages(root, source).flatMap(\.members)
                let closed = ["manifests", "events", "segments", "acknowledgements", "receipts"]
                for name in closed { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent(name).path) }
                defer { for name in closed { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(name).path) } }
                let start = WatchBacklogEvidence.nowMS()
                observer.observeVerifiedMetadata(); try await self.drainBacklog(observer)
                let receipt = try self.backlogObservation(root), status = try self.backlogObservationStatus(root)
                try self.check(receipt.build == "86" && receipt.observerProcessRunID == runID
                    && receipt.observedAtMS >= start && receipt.observedAtMS <= WatchBacklogEvidence.nowMS()
                    && receipt.schemaVersion == 2 && receipt.clockName == "CLOCK_MONOTONIC"
                    && receipt.continuousTimeMS > 0 && receipt.sourceGeneratedAtMS == source.generatedAtMS
                    && receipt.observedAtMS - receipt.sourceGeneratedAtMS > 300_000
                    && receipt.identity["generation"] == String(source.generation)
                    && receipt.identity["processRunID"] == source.processRunID.uuidString.lowercased(),
                    "A fresh observation identifies the current process while binding the original producer, generation and timestamp.")
                try self.check(status.available && status.sequence == receipt.sequence
                    && status.schemaVersion == 2 && status.clockName == receipt.clockName
                    && status.continuousTimeMS == receipt.continuousTimeMS && !receipt.audioRead && !receipt.includesAudio,
                    "Only completed full metadata validation publishes an available metadata-only sidecar.")
                let expected = Set(before.keys.filter { !current || $0 != "watch-backlog-status.json" })
                try self.check(Set(receipt.files.map(\.name)) == expected,
                    "The manifest binds every relevant summary, status, page and current/legacy control file.")
                try self.check(try self.frozenDiagnosticFiles(root) == before
                    && self.backlogPages(root, source).flatMap(\.members) == rows,
                    "Idle revalidation preserves source bytes, inode, mtime, page members and genuine event timestamps.")
            }
        }
        await run("verified_backlog_repeated_foreground_is_throttled_and_new_process_revalidates") { f in
            let root = f.root.appendingPathComponent("process-observed")
            _ = try await self.seededBacklog(root, build: "86")
            let first = WatchBacklogEvidence(root: root, build: "86", processRunID: UUID())
            try await self.drainBacklog(first)
            first.observeVerifiedMetadata(); try await self.drainBacklog(first)
            let original = try FileIdentity(root.appendingPathComponent("ConnectivityDiagnostics/verified-observation.json"))
            let receipt = try self.backlogObservation(root)
            for _ in 0..<20 { first.observeVerifiedMetadata() }
            try await self.drainBacklog(first)
            try self.check(try FileIdentity(root.appendingPathComponent("ConnectivityDiagnostics/verified-observation.json")) == original,
                "Repeated foreground callbacks within the throttle cannot rewrite or freshen the observation.")
            let second = WatchBacklogEvidence(root: root, build: "86", processRunID: UUID())
            try await self.drainBacklog(second)
            let before = try self.frozenDiagnosticFiles(root)
            second.observeVerifiedMetadata(); try await self.drainBacklog(second)
            let refreshed = try self.backlogObservation(root)
            try self.check(refreshed.observerProcessRunID != receipt.observerProcessRunID
                && refreshed.identity == receipt.identity && refreshed.sourceGeneratedAtMS == receipt.sourceGeneratedAtMS
                && refreshed.observedAtMS >= receipt.observedAtMS && (try self.frozenDiagnosticFiles(root)) == before,
                "A same-build process restart revalidates disk with a new observer identity without changing the frozen source.")
        }
        await run("verified_backlog_pending_real_persist_preserves_last_complete_receipt_until_commit") { f in
            let root = f.root.appendingPathComponent("pending-persist-observed")
            let (_, manifests) = try await self.seededBacklog(root, build: "86")
            let enteredFirstGate = Locked(false), enteredSecondGate = Locked(false), enteredSecondPersist = Locked(false)
            let firstGate = DispatchSemaphore(value: 0), secondGate = DispatchSemaphore(value: 0)
            let secondPersistGate = DispatchSemaphore(value: 0), persistCount = Locked(0)
            defer { firstGate.signal(); secondGate.signal(); secondPersistGate.signal() }
            let observer = WatchBacklogEvidence(root: root, build: "86", processRunID: UUID(), faultInjector: { point in
                if point == .pagesWritten {
                    let number = persistCount.access { $0 += 1; return $0 }
                    if number == 2 {
                        enteredSecondPersist.access { $0 = true }
                        _ = secondPersistGate.wait(timeout: .now() + 10)
                    }
                }
            }, observationMinimumIntervalMS: 0)
            try await self.drainBacklog(observer)
            observer.observeVerifiedMetadata(); try await self.drainBacklog(observer)
            let before = try self.backlogSummary(root)
            guard let queue = Mirror(reflecting: observer).children.first(where: { $0.label == "io" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Backlog diagnostic queue missing")
            }
            let directory = root.appendingPathComponent("ConnectivityDiagnostics")
            let middle = Locked<Result<[String: FileIdentity], Error>?>(nil)
            let context = WatchBacklogEvidence.Context(foreground: true, liveCapture: false, externalPower: false, opportunity: nil)
            // Arrange E1, foreground observation, P1, E2. Previously the
            // foreground hook queued a deferred observation after E2, which
            // invalidated P1's valid receipt merely because P2 was now queued.
            queue.async { enteredFirstGate.access { $0 = true }; _ = firstGate.wait(timeout: .now() + 10) }
            try await self.eventually("first ordering gate starts") { enteredFirstGate.current }
            observer.recordEnqueued(manifests[0], context: context)
            queue.async { enteredSecondGate.access { $0 = true }; _ = secondGate.wait(timeout: .now() + 10) }
            observer.observeVerifiedMetadata()
            firstGate.signal()
            try await self.eventually("first real event schedules its normal commit") { enteredSecondGate.current }
            queue.async {
                middle.access { value in
                    value = Result {
                        try Dictionary(uniqueKeysWithValues: ["verified-observation.json", "verified-observation-status.json", "watch-backlog.json"]
                            .map { ($0, try FileIdentity(directory.appendingPathComponent($0))) })
                    }
                }
            }
            observer.recordEnqueued(manifests[1], context: context)
            secondGate.signal()
            try await self.eventually("second normal commit pauses before summary publication") { enteredSecondPersist.current }
            let committed = try XCTUnwrapProbe(middle.current).get()
            for (name, identity) in committed {
                try self.check(try FileIdentity(directory.appendingPathComponent(name)) == identity,
                    "A later legitimate pending write cannot alter the completed receipt, status or bound summary.")
            }
            let status = try self.backlogObservationStatus(root), intermediate = try self.backlogObservation(root)
            try self.check(status.available && intermediate.identity["generation"] == String(before.generation + 1),
                "The prior successful observation remains available only for the exact already committed generation.")
            secondPersistGate.signal(); try await self.drainBacklog(observer)
            let after = try self.backlogSummary(root), receipt = try self.backlogObservation(root)
            try self.check(after.generation == before.generation + 2 && receipt.identity["generation"] == String(after.generation)
                && receipt.sequence > intermediate.sequence && (try self.backlogObservationStatus(root)).available,
                "The existing real commit eventually publishes a fully validated observation for its new source generation.")
            let currentSummary = try Data(contentsOf: directory.appendingPathComponent("watch-backlog.json"))
            try self.check(receipt.files.first { $0.name == "watch-backlog.json" }?.sha256 == VerifiedObservationPublisher.digest(currentSummary)
                && receipt.files.first { $0.name == "watch-backlog.json" }?.sha256 != intermediate.files.first { $0.name == "watch-backlog.json" }?.sha256,
                "The older receipt cannot attest the later changed source bytes.")
        }
        await run("verified_backlog_pending_retry_after_real_source_failure_still_invalidates_receipt") { f in
            let root = f.root.appendingPathComponent("failed-persist-observed")
            let (_, manifests) = try await self.seededBacklog(root, build: "86")
            let shouldFail = Locked(false)
            let observer = WatchBacklogEvidence(root: root, build: "86", processRunID: UUID(), faultInjector: { point in
                if point == .pagesWritten, shouldFail.current { throw POSIXError(.EIO) }
            }, observationMinimumIntervalMS: 0)
            try await self.drainBacklog(observer)
            observer.observeVerifiedMetadata(); try await self.drainBacklog(observer)
            let receiptURL = root.appendingPathComponent("ConnectivityDiagnostics/verified-observation.json")
            let original = try FileIdentity(receiptURL)
            let context = WatchBacklogEvidence.Context(foreground: true, liveCapture: false, externalPower: false, opportunity: nil)
            shouldFail.access { $0 = true }
            observer.recordEnqueued(manifests[0], context: context)
            try await self.drainBacklog(observer)
            try self.check(try self.backlogStatus(root)["state"] as? String == "retry_pending",
                "The synthetic I/O fault must first produce an actual source persistence failure.")
            guard let queue = Mirror(reflecting: observer).children.first(where: { $0.label == "io" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Backlog diagnostic queue missing")
            }
            let entered = Locked(false), gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            queue.async { entered.access { $0 = true }; _ = gate.wait(timeout: .now() + 10) }
            try await self.eventually("failure ordering gate starts") { entered.current }
            observer.recordEnqueued(manifests[1], context: context)
            observer.observeVerifiedMetadata()
            gate.signal(); try await self.drainBacklog(observer)
            let failed = try self.backlogObservationStatus(root)
            try self.check(!failed.available && failed.failureCode != nil && (try FileIdentity(receiptURL)) == original,
                "A pending retry cannot hide a genuine source failure or overwrite the previous receipt.")
        }
        await run("verified_backlog_cold_memory_cannot_attest_corrupt_or_missing_bound_metadata") { f in
            for fault in ["summary", "page", "status", "reference", "cohort", "legacy", "missing", "symlink",
                          "future_event", "page_build", "legacy_build"] {
                let root = f.root.appendingPathComponent("corrupt-" + fault)
                _ = try await self.seededBacklog(root, build: "86", current: true)
                let observer = WatchBacklogEvidence(root: root, build: "86", processRunID: UUID(), observationMinimumIntervalMS: 0)
                try await self.drainBacklog(observer)
                observer.observeVerifiedMetadata(); try await self.drainBacklog(observer)
                let oldReceipt = try FileIdentity(root.appendingPathComponent("ConnectivityDiagnostics/verified-observation.json"))
                let source = try self.backlogSummary(root, current: true)
                let directory = root.appendingPathComponent("ConnectivityDiagnostics/" + WatchBacklogEvidence.currentDirectory)
                let target: URL
                switch fault {
                case "page", "future_event", "page_build": target = directory.appendingPathComponent("BacklogEvidence/" + source.sourceSetID.uuidString.lowercased()
                    + "/" + String(format: "page-%04d-g%020llu.json", 0, source.pages[0].generation))
                case "status": target = directory.appendingPathComponent("watch-backlog-status.json")
                case "reference": target = directory.appendingPathComponent("legacy-empty-reference.json")
                case "cohort": target = directory.appendingPathComponent("current-cohort.json")
                case "legacy", "legacy_build": target = root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog.json")
                default: target = directory.appendingPathComponent("watch-backlog.json")
                }
                let original = try Data(contentsOf: target)
                let summaryURL = directory.appendingPathComponent("watch-backlog.json")
                let originalSummary = try Data(contentsOf: summaryURL)
                if fault == "missing" { try FileManager.default.removeItem(at: target) }
                else if fault == "symlink" {
                    let replacement = root.appendingPathComponent("synthetic-replacement.json")
                    try original.write(to: replacement)
                    try FileManager.default.removeItem(at: target)
                    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: replacement)
                } else {
                    var value = try JSONSerialization.jsonObject(with: original) as! [String: Any]
                    if fault == "summary" { value["pendingNonHistoricalMemberCount"] = 999 }
                    else if fault == "status" { value["audioRead"] = true }
                    else if fault == "page_build" || fault == "legacy_build" { value["build"] = "unknown" }
                    else if fault == "future_event" {
                        var members = value["members"] as! [[String: Any]]
                        let index = members.firstIndex { ($0["acknowledgementCount"] as? UInt64 ?? 0) > 0 }!
                        members[index]["lastACKConfirmedAtMS"] = source.generatedAtMS + 600_000
                        value["members"] = members
                    }
                    else { value["sourceSetID"] = UUID().uuidString }
                    let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                    try bytes.write(to: target)
                    if fault == "future_event" || fault == "page_build" {
                        var envelope = try JSONSerialization.jsonObject(with: originalSummary) as! [String: Any]
                        var bindings = envelope["pages"] as! [[String: Any]]
                        bindings[0]["sha256"] = VerifiedObservationPublisher.digest(bytes)
                        bindings[0]["byteLength"] = bytes.count
                        envelope["pages"] = bindings
                        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: summaryURL)
                    }
                }
                observer.observeVerifiedMetadata(); try await self.drainBacklog(observer)
                let status = try self.backlogObservationStatus(root)
                try self.check(!status.available && status.failureCode != nil
                    && (try FileIdentity(root.appendingPathComponent("ConnectivityDiagnostics/verified-observation.json"))) == oldReceipt,
                    "Missing, unsafe or inconsistent \(fault) metadata invalidates availability and preserves the previous receipt exactly.")
                if fault == "symlink" { try FileManager.default.removeItem(at: target) }
                try original.write(to: target)
                if fault == "future_event" || fault == "page_build" { try originalSummary.write(to: summaryURL) }
                observer.observeVerifiedMetadata(); try await self.drainBacklog(observer)
                try self.check(try self.backlogObservationStatus(root).available,
                    "A later real request can recover after exact source metadata is restored, without reloading cached state.")
            }
        }
        await run("verified_backlog_first_foreground_waits_for_ordinary_capture_without_consuming_throttle") { f in
            let root = f.root.appendingPathComponent("new-capture")
            let (repository, _) = try self.metadataFixture(root, count: 2)
            let observer = WatchBacklogEvidence(root: root, build: "86", processRunID: UUID())
            observer.observeVerifiedMetadata(); try await self.drainBacklog(observer)
            try self.check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ConnectivityDiagnostics/verified-observation.json").path),
                "A new install does not invent a frozen report to answer a foreground observation.")
            observer.captureIfNeeded { try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(observer)
            try self.check(try self.backlogObservationStatus(root).available,
                "The existing normal capture may satisfy the pending real foreground request after its actual commit completes.")
        }
    }
    func executeBacklogBuildPublicationCases() async {
        await run("backlog_build83_to84_cold_restore_publishes_fresh_binding_without_recapture_or_event_rewrite") { f in
            for current in [false, true] {
                let root = f.root.appendingPathComponent(current ? "current" : "legacy-nonempty")
                let (repository, _) = try await self.seededBacklog(root, build: "83", current: current)
                let before = try self.backlogSummary(root, current: current)
                let pages = try self.backlogPageIdentities(root, before)
                let rows = try self.backlogPages(root, before).flatMap(\.members)
                let closed = ["manifests", "events", "segments", "acknowledgements", "receipts"]
                for name in closed { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent(name).path) }
                defer { for name in closed { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(name).path) } }
                let used = Locked(0), runID = UUID()
                try await Task.sleep(nanoseconds: 5_000_000)
                let restoreStartedAtMS = WatchBacklogEvidence.nowMS()
                let observer = WatchBacklogEvidence(root: root, build: "84", processRunID: runID)
                observer.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
                try await self.drainBacklog(observer)
                let after = try self.backlogSummary(root, current: current)
                try self.check(after.build == "84" && after.processRunID == runID && after.generation == before.generation + 1
                    && after.generatedAtMS > before.generatedAtMS && after.generatedAtMS >= restoreStartedAtMS
                    && after.generatedAtMS <= WatchBacklogEvidence.nowMS(),
                    "A fully validated cold restore publishes this build/process and next generation with a fresh timestamp inside the restore interval.")
                try self.checkFrozenBacklog(before, after)
                try self.check(try self.backlogPageIdentities(root, after) == pages
                    && self.backlogPages(root, after).flatMap(\.members) == rows,
                    "Published metadata keeps exact page bytes, inodes, timestamps and all original member event provenance.")
                let status = try self.backlogStatus(root, current: current)
                try self.check(status["state"] as? String == "ready" && status["build"] as? String == "84"
                    && status["processRunID"] as? String == runID.uuidString && status["generation"] as? UInt64 == after.generation,
                    "Ready status follows the committed fresh summary with matching process and generation.")
                try self.check(used.current == 0 && !after.audioRead && !after.includesAudio && !after.cloudCompletionProven,
                    "Cold publication cannot call the provider, access protected repository/audio folders, or invent content/cloud proof.")
            }
        }
        await run("backlog_same_build_cold_restore_and_flush_leave_summary_bytes_inode_and_mtime_unchanged") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, _) = try await self.seededBacklog(root, build: "84")
            let url = root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog.json")
            let original = try FileIdentity(url), before = try self.backlogSummary(root), used = Locked(0)
            for _ in 0..<3 {
                let observer = WatchBacklogEvidence(root: root, build: "84", processRunID: UUID())
                observer.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
                await withCheckedContinuation { done in observer.flush { done.resume() } }
                try await self.drainBacklog(observer)
                try self.check(try FileIdentity(url) == original, "A same-build restore/flush never republishes summary or freshens its observation time.")
                let status = try self.backlogStatus(root)
                try self.check(status["state"] as? String == "restored" && status["generation"] as? UInt64 == before.generation,
                    "A same-build process may refresh status while retaining the exact existing summary generation.")
            }
            try self.check(used.current == 0, "Repeated same-build starts cannot rescan the frozen source catalogue.")
        }
        await run("backlog_cross_build_invalid_summary_or_bound_page_never_publishes_new_build") { f in
            for corruptSummary in [false, true] {
                let root = f.root.appendingPathComponent(corruptSummary ? "summary-count" : "page-digest")
                let (repository, _) = try await self.seededBacklog(root, build: "83")
                let before = try self.backlogSummary(root)
                let directory = root.appendingPathComponent("ConnectivityDiagnostics")
                let url = directory.appendingPathComponent("watch-backlog.json"), statusURL = directory.appendingPathComponent("watch-backlog-status.json")
                if corruptSummary {
                    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                    object["pendingNonHistoricalMemberCount"] = 99
                    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
                } else {
                    let name = String(format: "page-%04d-g%020llu.json", 0, before.pages[0].generation)
                    try Data("invalid bound metadata".utf8).write(to: directory.appendingPathComponent("BacklogEvidence/"
                        + before.sourceSetID.uuidString.lowercased() + "/" + name))
                }
                let original = try FileIdentity(url), originalStatus = try FileIdentity(statusURL), used = Locked(0)
                let observer = WatchBacklogEvidence(root: root, build: "84", processRunID: UUID())
                observer.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
                try await self.drainBacklog(observer)
                let status = try self.backlogStatus(root, current: true)
                try self.check(status["state"] as? String == "failed" && status["lastError"] as? String == "restore_failed",
                    "Cross-build publication is blocked until every bound page and recomputed summary field passes restore validation.")
                try self.check(try FileIdentity(url) == original && FileIdentity(statusURL) == originalStatus && used.current == 0,
                    "Failed validation preserves the original summary/status and cannot recapture or relabel the frozen source set.")
            }
        }
        await run("backlog_cross_build_summary_before_rename_failure_preserves_old_commit_and_retries_explicitly") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            _ = try await self.seededBacklog(root, build: "83")
            let url = root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog.json")
            let original = try FileIdentity(url), before = try self.backlogSummary(root)
            let pages = try self.backlogPageIdentities(root, before), fail = Locked(true)
            let observer = WatchBacklogEvidence(root: root, build: "84", processRunID: UUID(), faultInjector: { point in
                if point == .pagesWritten, fail.current { throw POSIXError(.EIO) }
            })
            try await self.drainBacklog(observer)
            try self.check(try FileIdentity(url) == original && self.backlogPageIdentities(root, before) == pages,
                "A failure before summary rename retains the old complete summary and all bound pages exactly.")
            let status = try self.backlogStatus(root), detail = try XCTUnwrapProbe(status["failureDetail"] as? [String: Any])
            try self.check(status["state"] as? String == "retry_pending" && detail["stage"] as? String == "persist"
                && detail["kind"] as? String == "posix" && detail["nativeErrorCode"] as? Int == Int(EIO),
                "A failed build publication records the actual persistence stage and OS code rather than reporting ready.")
            fail.access { $0 = false }
            await withCheckedContinuation { done in observer.flush { done.resume() } }
            try await self.drainBacklog(observer)
            let after = try self.backlogSummary(root)
            try self.check(after.build == "84" && after.generation > before.generation, "An authorized later flush can finish the failed metadata publication.")
            try self.checkFrozenBacklog(before, after)
        }
        await run("backlog_cross_build_actual_summary_rename_failure_preserves_old_file_and_recovers") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            _ = try await self.seededBacklog(root, build: "83")
            let url = root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog.json")
            let original = try FileIdentity(url), before = try self.backlogSummary(root)
            let pages = try self.backlogPageIdentities(root, before)
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
            let observer = WatchBacklogEvidence(root: root, build: "84", processRunID: UUID())
            try await self.drainBacklog(observer)
            let status = try self.backlogStatus(root), detail = try XCTUnwrapProbe(status["failureDetail"] as? [String: Any])
            try self.check(try FileIdentity(url) == original && self.backlogPageIdentities(root, before) == pages,
                "An actual renameat failure on an immutable destination preserves exact old summary bytes, inode, mtime and bound pages.")
            try self.check(status["state"] as? String == "retry_pending" && detail["stage"] as? String == "persist"
                && detail["kind"] as? String == "posix" && detail["nativeErrorCode"] as? Int == Int(EPERM),
                "The real failed atomic replacement must expose its actual EPERM metadata error without claiming success.")
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
            await withCheckedContinuation { done in observer.flush { done.resume() } }
            try await self.drainBacklog(observer)
            let after = try self.backlogSummary(root), ready = try self.backlogStatus(root)
            try self.check(after.build == "84" && after.generation > before.generation && ready["state"] as? String == "ready",
                "Removing the synthetic write obstruction lets a later flush complete the same frozen publication.")
            try self.checkFrozenBacklog(before, after)
        }
        await run("backlog_cross_build_summary_after_rename_failure_exposes_complete_binding_but_keeps_retry_pending") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            _ = try await self.seededBacklog(root, build: "83")
            let before = try self.backlogSummary(root), pages = try self.backlogPageIdentities(root, before), fail = Locked(true)
            let observer = WatchBacklogEvidence(root: root, build: "84", processRunID: UUID(), faultInjector: { point in
                if point == .summaryRenamed, fail.current { throw POSIXError(.EIO) }
            })
            try await self.drainBacklog(observer)
            let uncertain = try self.backlogSummary(root), status = try self.backlogStatus(root)
            try self.check(uncertain.build == "84" && uncertain.generation == before.generation + 1
                && status["state"] as? String == "retry_pending" && status["generation"] as? UInt64 == before.generation,
                "A rename-before-directory-fsync failure may expose a complete new summary but must not claim that commit succeeded.")
            try self.checkFrozenBacklog(before, uncertain)
            try self.check(try self.backlogPageIdentities(root, uncertain) == pages,
                "The uncertain visible summary still references the exact complete immutable pages.")
            fail.access { $0 = false }
            await withCheckedContinuation { done in observer.flush { done.resume() } }
            try await self.drainBacklog(observer)
            let after = try self.backlogSummary(root), ready = try self.backlogStatus(root)
            try self.check(after.generation > uncertain.generation && ready["state"] as? String == "ready"
                && ready["generation"] as? UInt64 == after.generation, "Retry reserves a later generation and publishes matching success only after the commit completes.")
            try self.checkFrozenBacklog(before, after)
        }
        await run("backlog_cross_build_status_outage_retries_status_without_advancing_committed_summary") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            _ = try await self.seededBacklog(root, build: "83")
            let directory = root.appendingPathComponent("ConnectivityDiagnostics"), fail = Locked(true)
            let url = directory.appendingPathComponent("watch-backlog.json"), statusURL = directory.appendingPathComponent("watch-backlog-status.json")
            let oldStatus = try FileIdentity(statusURL)
            let observer = WatchBacklogEvidence(root: root, build: "84", processRunID: UUID(), faultInjector: { point in
                if point == .statusPrepared, fail.current { throw POSIXError(.EIO) }
            })
            try await self.drainBacklog(observer)
            let committed = try FileIdentity(url), summary = try self.backlogSummary(root)
            try self.check(summary.build == "84" && (try FileIdentity(statusURL)) == oldStatus,
                "Status failure after summary success retains the old status atomically while the complete fresh summary remains available.")
            for _ in 0..<3 {
                await withCheckedContinuation { done in observer.flush { done.resume() } }
                try await self.drainBacklog(observer)
                try self.check(try FileIdentity(url) == committed && FileIdentity(statusURL) == oldStatus,
                    "Persistent status failure cannot rewrite summary, advance generation or freshen generatedAtMS on retry.")
            }
            let failures = Mirror(reflecting: observer).children.first { $0.label == "metadataWriterFailure" }?.value as? UInt64
            try self.check(failures == 4, "Each failed publication attempt remains explicitly counted even when its failure status is also unwritable.")
            fail.access { $0 = false }
            await withCheckedContinuation { done in observer.flush { done.resume() } }
            try await self.drainBacklog(observer)
            let status = try self.backlogStatus(root)
            try self.check(try FileIdentity(url) == committed && status["state"] as? String == "ready"
                && status["generation"] as? UInt64 == summary.generation && status["failureDetail"] == nil,
                "Recovery repairs only status for the already committed summary and clears current failure detail.")
        }
        await run("backlog_committed_build_status_failure_is_repaired_by_same_build_cold_start") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            _ = try await self.seededBacklog(root, build: "83")
            let first = WatchBacklogEvidence(root: root, build: "84", processRunID: UUID(), faultInjector: { point in
                if point == .statusPrepared { throw POSIXError(.EIO) }
            })
            try await self.drainBacklog(first)
            let url = root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog.json"), original = try FileIdentity(url)
            let summary = try self.backlogSummary(root), runID = UUID(), fail = Locked(true)
            let restored = WatchBacklogEvidence(root: root, build: "84", processRunID: runID, faultInjector: { point in
                if point == .statusPrepared, fail.current { throw POSIXError(.EIO) }
            })
            try await self.drainBacklog(restored)
            await withCheckedContinuation { done in restored.flush { done.resume() } }
            try await self.drainBacklog(restored)
            try self.check(try FileIdentity(url) == original, "Same-build cold status failure and its retries cannot republish an already committed fresh summary.")
            fail.access { $0 = false }
            await withCheckedContinuation { done in restored.flush { done.resume() } }
            try await self.drainBacklog(restored)
            let status = try self.backlogStatus(root)
            try self.check(try FileIdentity(url) == original && status["state"] as? String == "restored"
                && status["processRunID"] as? String == runID.uuidString && status["generation"] as? UInt64 == summary.generation,
                "A same-build cold process repairs the matching status without changing frozen summary ownership or observation time.")
        }
        await run("backlog_status_pending_still_publishes_real_summary_only_observations") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (_, manifests) = try await self.seededBacklog(root, build: "83")
            let fail = Locked(true)
            let observer = WatchBacklogEvidence(root: root, build: "84", processRunID: UUID(), faultInjector: { point in
                if point == .statusPrepared, fail.current { throw POSIXError(.EIO) }
            })
            try await self.drainBacklog(observer)
            let before = try self.backlogSummary(root), pages = try self.backlogPageIdentities(root, before)
            let value = manifests[0], id = UUID()
            let outside = SegmentManifest(id: id, sessionID: value.sessionID, sequence: 9, startedAt: value.startedAt, endedAt: value.endedAt,
                sampleRate: value.sampleRate, frameCount: value.frameCount, fileName: id.uuidString.lowercased() + ".caf", byteCount: value.byteCount, sha256: value.sha256)
            let conflict = SegmentReceipt(segmentID: value.id, sha256: String(repeating: "b", count: 64), byteCount: value.byteCount)
            let context = WatchBacklogEvidence.Context(foreground: false, liveCapture: false, externalPower: true, opportunity: 84)
            observer.recordEnqueued(outside, context: context)
            observer.recordAcknowledgement(conflict, manifest: value, newlyCommitted: false, context: context)
            observer.recordIdentityReadFailure()
            try await self.drainBacklog(observer)
            let after = try self.backlogSummary(root)
            try self.check(after.generation > before.generation && after.outsideCohortObservationCount == 1
                && after.identityConflictCount == 1 && after.identityReadFailureCount == 1,
                "New summary-only observations must still publish while status remains pending, even with no dirty pages.")
            try self.check(try self.backlogPageIdentities(root, after) == pages && after.newACKCommittedMemberCount == before.newACKCommittedMemberCount,
                "Summary-only errors cannot alter frozen pages or add successful ACK history.")
            let url = root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog.json"), committed = try FileIdentity(url)
            fail.access { $0 = false }
            await withCheckedContinuation { done in observer.flush { done.resume() } }
            try await self.drainBacklog(observer)
            try self.check(try FileIdentity(url) == committed && self.backlogStatus(root)["generation"] as? UInt64 == after.generation,
                "The eventual status repair binds the latest real observation without another summary generation.")
        }
    }
    func executeBacklogEvidenceCases() async {
        await run("backlog_evidence_empty_catalog_defers_before_intent_and_later_captures_nonempty_metadata") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, _) = try self.metadataFixture(root, count: 0)
            let observer = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
            let used = Locked(0)
            for _ in 0..<2 {
                observer.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
                try await self.drainBacklog(observer)
            }
            let directory = root.appendingPathComponent("ConnectivityDiagnostics")
            let status = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("watch-backlog-status.json"))) as! [String: Any]
            try self.check(used.current == 2 && status["state"] as? String == "awaiting_nonempty_catalog",
                           "An empty metadata snapshot must remain retryable without consuming the one-shot capture.")
            try self.check(status["sourceSetID"] == nil && status["generation"] == nil,
                           "An empty observation cannot allocate a source-set identity or claim a generation.")
            try self.check(status["failureDetail"] == nil,
                           "A successful empty metadata observation is a wait state, not an invented read error or root-change diagnosis.")
            for name in ["watch-backlog.json", "watch-backlog-capture.json", "BacklogEvidence"] {
                try self.check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
                               "An empty snapshot cannot write a summary, capture intent or source pages.")
            }
            let (_, manifests) = try self.metadataFixture(root, count: 3)
            observer.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(observer)
            let summary = try self.backlogSummary(root)
            let rows = try self.backlogPages(root, summary).flatMap(\.members)
            try self.check(used.current == 3 && summary.sourceCount == 3 && summary.generation == 1,
                           "A later real nonempty snapshot must freeze its first generation without recreating the observer.")
            try self.check(Set(rows.map(\.segmentID)) == Set(manifests.map(\.id)) && summary.pendingNonHistoricalMemberCount == 3
                           && summary.historicalACKMetadataCount == 0 && summary.newACKCommittedMemberCount == 0
                           && !summary.allNonHistoricalMembersACKConfirmed,
                           "The later cohort must contain exactly the metadata sources, with no invented historical or new ACKs.")
            observer.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(observer)
            try self.check(used.current == 3, "A successfully frozen nonempty cohort still prevents repeated catalogue capture.")
            try self.check(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("segments").path).isEmpty,
                           "Empty-to-nonempty recovery uses manifest metadata only, without synthetic audio files.")
        }
        await run("backlog_evidence_empty_catalog_status_write_failure_remains_retryable") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, _) = try self.metadataFixture(root, count: 0)
            let observer = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
            try await self.drainBacklog(observer)
            let directory = root.appendingPathComponent("ConnectivityDiagnostics")
            let statusURL = directory.appendingPathComponent("watch-backlog-status.json")
            let originalStatus = try FileIdentity(statusURL)
            // The writer repairs directory modes itself. Make the synthetic
            // existing status immutable so its actual rename must fail instead.
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: statusURL.path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: statusURL.path) }
            let used = Locked(0)
            observer.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(observer)
            let writerFailures = Mirror(reflecting: observer).children.first { $0.label == "metadataWriterFailure" }?.value as? UInt64
            let afterStatus = try FileIdentity(statusURL)
            try self.check(writerFailures == 1 && afterStatus == originalStatus,
                           "The actual empty-status atomic replacement must fail and retain the previous status bytes, inode and mtime.")
            try self.check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("watch-backlog.json").path),
                           "A failed empty-state status write must not publish an empty summary.")
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: statusURL.path)
            _ = try self.metadataFixture(root, count: 1)
            observer.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(observer)
            let summary = try self.backlogSummary(root)
            try self.check(used.current == 2 && summary.sourceCount == 1,
                           "Failure to persist a deferred empty status must not block a later nonempty metadata capture.")
        }
        await run("backlog_evidence_legacy_empty_supersedes_without_rewriting_original_and_restarts_idempotently") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (emptyRepository, _) = try self.metadataFixture(root, count: 0)
            let directory = root.appendingPathComponent("ConnectivityDiagnostics")
            let empty = try self.legacyEmptyBacklog(root)
            let summaryURL = directory.appendingPathComponent("watch-backlog.json")
            let statusURL = directory.appendingPathComponent("watch-backlog-status.json")
            let original = try FileIdentity(summaryURL), originalStatus = try FileIdentity(statusURL)
            let current = directory.appendingPathComponent(WatchBacklogEvidence.currentDirectory)
            let referenceURL = current.appendingPathComponent(WatchBacklogEvidence.legacyReferenceName)
            let used = Locked(0)
            var firstReference: FileIdentity?
            for _ in 0..<2 {
                let observer = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
                observer.captureIfNeeded { used.access { $0 += 1 }; return nil }
                try await self.drainBacklog(observer)
                let status = try JSONSerialization.jsonObject(with: Data(contentsOf: current.appendingPathComponent("watch-backlog-status.json"))) as! [String: Any]
                try self.check(status["state"] as? String == "awaiting_foreground_capture" && status["sourceSetID"] == nil,
                               "Superseding an empty archive only establishes a current wait state, not a completed cohort.")
                try self.check(status["supersedes"] != nil && status["generation"] == nil,
                               "The wait state retains its explicit legacy reference without inventing a current generation.")
                let reference = try FileIdentity(referenceURL)
                if let firstReference { try self.check(reference == firstReference, "Restart must reuse the exact reference bytes, inode and mtime.") }
                else { firstReference = reference }
            }
            let waiting = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
            waiting.captureIfNeeded { used.access { $0 += 1 }; return try emptyRepository.transferEvidenceSnapshot() }
            try await self.drainBacklog(waiting)
            let emptyStatus = try JSONSerialization.jsonObject(with: Data(contentsOf: current.appendingPathComponent("watch-backlog-status.json"))) as! [String: Any]
            try self.check(emptyStatus["state"] as? String == "awaiting_nonempty_catalog"
                           && !FileManager.default.fileExists(atPath: current.appendingPathComponent("watch-backlog-capture.json").path)
                           && !FileManager.default.fileExists(atPath: current.appendingPathComponent("watch-backlog.json").path),
                           "A real empty metadata opportunity keeps waiting without creating a current intent or catalogue.")
            let (repository, manifests) = try self.metadataFixture(root, count: 2)
            let observer = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
            observer.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(observer)
            let captured = try self.backlogSummary(root, current: true)
            let members = try self.backlogPages(root, captured).flatMap(\.members)
            let binding = try XCTUnwrapProbe(captured.supersedes)
            let witness = try TransportCodec.decode(WatchBacklogEvidence.CurrentCohort.self,
                from: Data(contentsOf: current.appendingPathComponent(WatchBacklogEvidence.currentCohortName)))
            let originalBytes = try Data(contentsOf: summaryURL)
            let originalDigest = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()
            try self.check(captured.sourceSetID != empty.sourceSetID && captured.sourceCount == 2
                           && Set(members.map(\.segmentID)) == Set(manifests.map(\.id)),
                           "A later nonempty snapshot creates a different explicitly bound current cohort, never replaces the frozen legacy one.")
            try self.check(binding.legacySourceSetID == empty.sourceSetID && binding.legacyGeneration == 2
                           && binding.legacySummarySHA256 == originalDigest && binding.legacySummaryByteLength == originalBytes.count
                           && binding.legacyIntentAbsent && binding.reason == "legacy_empty_catalog",
                           "Supersedes must identify the exact preserved legacy bytes and its absent commit intent.")
            try self.check(witness.schemaVersion == 1 && witness.sourceSetID == captured.sourceSetID
                           && witness.capturedAtMS == captured.capturedAtMS && witness.supersedes == binding,
                           "The immutable capture-start witness binds this one current cohort to the exact legacy reference.")
            let queue = try XCTUnwrapProbe(captured.metadataQueue)
            try self.check(queue.metadataUnacknowledgedMemberCount == 2 && !queue.transportEligibilityEvaluated
                           && queue.transportEligibleMemberCount == nil && captured.newACKCommittedMemberCount == 0,
                           "Known metadata without ACK is distinct from unmeasured transport eligibility and cannot manufacture new ACKs.")
            let restored = WatchBacklogEvidence(root: root, build: "next", processRunID: UUID())
            restored.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(restored)
            let after = try self.backlogSummary(root, current: true)
            try self.check(after.sourceSetID == captured.sourceSetID && used.current == 4,
                           "Once current evidence exists, restart restores it instead of invoking the provider or refreezing another identity.")
            try self.check(try FileIdentity(summaryURL) == original && FileIdentity(statusURL) == originalStatus,
                           "Migration, current capture and restart preserve exact legacy summary/status bytes, inode and mtime.")
            try self.check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("watch-backlog-capture.json").path)
                           && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("BacklogEvidence").path)
                           && (try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("segments").path)).isEmpty,
                           "Current diagnostic pages are independent and all fixture work remains metadata-only.")
        }
        await run("backlog_evidence_migrated_current_preserves_real_ACK_provenance_and_pending_on_restart") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, manifests) = try self.metadataFixture(root, count: 3)
            _ = try self.legacyEmptyBacklog(root)
            let historical = SegmentReceipt(segmentID: manifests[0].id, sha256: manifests[0].sha256, byteCount: manifests[0].byteCount)
            _ = try repository.acknowledge(historical, pruneAudio: false)
            let run = UUID()
            let observer = WatchBacklogEvidence(root: root, build: "candidate", processRunID: run)
            observer.captureIfNeeded { try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(observer)
            let before = try self.backlogSummary(root, current: true)
            try self.check(before.historicalACKMetadataCount == 1 && before.newACKCommittedMemberCount == 0
                           && before.metadataQueue?.metadataUnacknowledgedMemberCount == 2,
                           "Historical metadata is retained as history rather than relabelled as a new durable ACK.")
            let receipt = SegmentReceipt(segmentID: manifests[1].id, sha256: manifests[1].sha256, byteCount: manifests[1].byteCount)
            let committed = try repository.acknowledge(receipt, pruneAudio: false)
            let at = before.capturedAtMS + 7
            let context = WatchBacklogEvidence.Context(foreground: false, liveCapture: false, externalPower: true, opportunity: 73)
            observer.recordEnqueued(manifests[1], context: context, at: at - 1)
            observer.recordAcknowledgement(receipt, manifest: manifests[1], newlyCommitted: committed.acknowledgementChanged, context: context, at: at)
            await withCheckedContinuation { done in observer.flush { done.resume() } }
            try await self.drainBacklog(observer)
            let used = Locked(0), restored = WatchBacklogEvidence(root: root, build: "next", processRunID: UUID())
            restored.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(restored)
            let after = try self.backlogSummary(root, current: true)
            let row = try XCTUnwrapProbe(try self.backlogPages(root, after).flatMap(\.members).first { $0.segmentID == manifests[1].id })
            try self.check(used.current == 0 && after.sourceSetID == before.sourceSetID && after.catalogSHA256 == before.catalogSHA256
                           && after.supersedes == before.supersedes && after.newACKCommittedMemberCount == 1
                           && after.metadataQueue?.metadataUnacknowledgedMemberCount == 1,
                           "A cold current restore preserves the exact denominator and real progress, and does not recapture newly changed repository metadata.")
            try self.check(row.firstNewACKCommittedAtMS == at && row.firstNewACKProcessRunID == run
                           && row.firstNewACKContext == context && row.firstEnqueuedAtMS == at - 1,
                           "Current namespace pages retain the actual event time, background callback context and process provenance.")
        }
        await run("backlog_evidence_invalid_or_new_format_empty_never_supersedes_and_preserves_archive") { f in
            for kind in ["corrupt_catalog", "new_format"] {
                let root = f.root.appendingPathComponent(kind)
                let (repository, _) = try self.metadataFixture(root, count: 1)
                _ = try self.legacyEmptyBacklog(root)
                let directory = root.appendingPathComponent("ConnectivityDiagnostics")
                let summary = directory.appendingPathComponent("watch-backlog.json")
                var object = try JSONSerialization.jsonObject(with: Data(contentsOf: summary)) as! [String: Any]
                if kind == "corrupt_catalog" { object["catalogSHA256"] = String(repeating: "0", count: 64) }
                else { object["metadataQueue"] = ["metadataUnacknowledgedMemberCount": 0, "transportEligibilityEvaluated": false,
                                                 "meaning": "metadata_absence_of_ACK_not_transport_eligibility"] }
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: summary)
                let original = try FileIdentity(summary), oldStatus = try FileIdentity(directory.appendingPathComponent("watch-backlog-status.json"))
                let used = Locked(0), observer = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
                observer.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
                try await self.drainBacklog(observer)
                let current = directory.appendingPathComponent(WatchBacklogEvidence.currentDirectory)
                try self.check(used.current == 0 && !FileManager.default.fileExists(atPath: current.appendingPathComponent(WatchBacklogEvidence.legacyReferenceName).path)
                               && FileIdentity(summary) == original && FileIdentity(directory.appendingPathComponent("watch-backlog-status.json")) == oldStatus,
                               "Only validated old-format empty evidence qualifies: corruption or a new-format empty archive cannot cause recurring refreezes.")
            }
        }
        await run("backlog_evidence_legacy_empty_any_unfinished_intent_is_preserved_and_refuses_migration") { f in
            for kind in ["matching", "other", "broken"] {
                let root = f.root.appendingPathComponent(kind)
                let (repository, _) = try self.metadataFixture(root, count: 2)
                let empty = try self.legacyEmptyBacklog(root)
                let directory = root.appendingPathComponent("ConnectivityDiagnostics")
                let intentURL = directory.appendingPathComponent("watch-backlog-capture.json")
                let bytes = kind == "broken" ? Data("{broken intent".utf8) : try JSONSerialization.data(withJSONObject:
                    ["sourceSetID": (kind == "matching" ? empty.sourceSetID : UUID()).uuidString, "generatedAtMS": 1_000], options: [.sortedKeys])
                try bytes.write(to: intentURL)
                let files = ["watch-backlog.json", "watch-backlog-status.json", "watch-backlog-capture.json"]
                let original = try files.map { try FileIdentity(directory.appendingPathComponent($0)) }
                let used = Locked(0)
                for _ in 0..<2 {
                    let observer = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
                    observer.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
                    await withCheckedContinuation { done in observer.flush { done.resume() } }
                    try await self.drainBacklog(observer)
                }
                let current = directory.appendingPathComponent(WatchBacklogEvidence.currentDirectory)
                let status = try JSONSerialization.jsonObject(with: Data(contentsOf: current.appendingPathComponent("watch-backlog-status.json"))) as! [String: Any]
                try self.check(used.current == 0 && status["state"] as? String == "failed"
                               && status["lastError"] as? String == "restore_failed",
                               "Even a matching intent is an unfinished legacy transaction, never a valid empty migration.")
                try self.check(try files.enumerated().allSatisfy { try FileIdentity(directory.appendingPathComponent($0.element)) == original[$0.offset] },
                               "Every old summary/status/intent must retain its exact bytes, inode and mtime across failed restore and restart.")
                try self.check(!FileManager.default.fileExists(atPath: current.appendingPathComponent(WatchBacklogEvidence.legacyReferenceName).path)
                               && !FileManager.default.fileExists(atPath: current.appendingPathComponent("watch-backlog.json").path),
                               "Rejected legacy evidence cannot allocate a migration reference or current catalogue.")
            }
        }
        await run("backlog_evidence_current_partial_commit_never_refreezes_or_hides_failure") { f in
            for stage in ["reference", "cohort", "pages", "summary"] {
                let root = f.root.appendingPathComponent(stage)
                let (repository, _) = try self.metadataFixture(root, count: 2)
                _ = try self.legacyEmptyBacklog(root)
                let directory = root.appendingPathComponent("ConnectivityDiagnostics")
                let original = try FileIdentity(directory.appendingPathComponent("watch-backlog.json"))
                let oldStatus = try FileIdentity(directory.appendingPathComponent("watch-backlog-status.json"))
                let used = Locked(0)
                let observer = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID(), faultInjector: { point in
                    if (stage == "reference" && point == .legacyReferenceRenamed)
                        || (stage == "cohort" && point == .currentCohortRenamed)
                        || (stage == "pages" && point == .pagesWritten)
                        || (stage == "summary" && point == .summaryRenamed) { throw POSIXError(.EIO) }
                })
                observer.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
                try await self.drainBacklog(observer)
                let calls = used.current
                let current = directory.appendingPathComponent(WatchBacklogEvidence.currentDirectory)
                let referenceIdentity = try FileIdentity(current.appendingPathComponent(WatchBacklogEvidence.legacyReferenceName))
                let restarted = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
                restarted.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
                await withCheckedContinuation { done in restarted.flush { done.resume() } }
                try await self.drainBacklog(restarted)
                let status = try JSONSerialization.jsonObject(with: Data(contentsOf: current.appendingPathComponent("watch-backlog-status.json"))) as! [String: Any]
                if stage == "reference" {
                    try self.check(calls == 1 && used.current == calls && (try self.backlogSummary(root, current: true)).sourceCount == 2,
                                   "The same observer can recover a durable reference-only fsync failure at a later opportunity; restart restores its one committed cohort.")
                } else {
                    try self.check(used.current == calls && status["state"] as? String == "failed"
                                   && status["lastError"] as? String == "restore_failed",
                                   "A current intent left by page or summary publication blocks reuse and cannot mint a replacement cohort.")
                }
                try self.check(try FileIdentity(directory.appendingPathComponent("watch-backlog.json")) == original
                               && FileIdentity(directory.appendingPathComponent("watch-backlog-status.json")) == oldStatus
                               && FileIdentity(current.appendingPathComponent(WatchBacklogEvidence.legacyReferenceName)) == referenceIdentity,
                               "Every failure boundary preserves the historical archive and stable migration reference.")
            }
        }
        await run("backlog_evidence_current_reference_or_supersedes_tampering_cannot_rebind_existing_pages") { f in
            for kind in ["missing_reference", "changed_reference", "missing_witness", "changed_witness", "changed_supersedes", "changed_queue"] {
                let root = f.root.appendingPathComponent(kind)
                let (repository, _) = try self.metadataFixture(root, count: 2)
                _ = try self.legacyEmptyBacklog(root)
                let first = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
                first.captureIfNeeded { try repository.transferEvidenceSnapshot() }
                try await self.drainBacklog(first)
                let current = root.appendingPathComponent("ConnectivityDiagnostics/" + WatchBacklogEvidence.currentDirectory)
                let reference = current.appendingPathComponent(WatchBacklogEvidence.legacyReferenceName)
                let witness = current.appendingPathComponent(WatchBacklogEvidence.currentCohortName)
                let summary = current.appendingPathComponent("watch-backlog.json")
                if kind == "missing_reference" { try FileManager.default.removeItem(at: reference) }
                else if kind == "missing_witness" { try FileManager.default.removeItem(at: witness) }
                else {
                    let target = kind == "changed_reference" ? reference : (kind == "changed_witness" ? witness : summary)
                    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as! [String: Any]
                    if kind == "changed_reference" { object["legacyGeneration"] = 999 }
                    else if kind == "changed_witness" { object["sourceSetID"] = UUID().uuidString }
                    else if kind == "changed_supersedes" {
                        var link = object["supersedes"] as! [String: Any]
                        link["legacyGeneration"] = 999; object["supersedes"] = link
                    } else {
                        var queue = object["metadataQueue"] as! [String: Any]
                        queue["metadataUnacknowledgedMemberCount"] = 0; object["metadataQueue"] = queue
                    }
                    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: target)
                }
                let before = try FileIdentity(summary), used = Locked(0)
                let restarted = WatchBacklogEvidence(root: root, build: "next", processRunID: UUID())
                restarted.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
                try await self.drainBacklog(restarted)
                let status = try JSONSerialization.jsonObject(with: Data(contentsOf: current.appendingPathComponent("watch-backlog-status.json"))) as! [String: Any]
                try self.check(used.current == 0 && status["state"] as? String == "failed" && (try FileIdentity(summary)) == before,
                               "A missing/changed reference or cross-bound supersedes cannot adopt, overwrite or refreeze a current catalogue.")
            }
        }
        await run("backlog_evidence_current_orphan_pages_or_committed_status_never_authorize_recapture") { f in
            for kind in ["pages", "committed_status", "witness"] {
                let root = f.root.appendingPathComponent(kind)
                let (repository, _) = try self.metadataFixture(root, count: 2)
                _ = try self.legacyEmptyBacklog(root)
                let first = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
                first.captureIfNeeded { try repository.transferEvidenceSnapshot() }
                try await self.drainBacklog(first)
                let current = root.appendingPathComponent("ConnectivityDiagnostics/" + WatchBacklogEvidence.currentDirectory)
                let summary = try self.backlogSummary(root, current: true)
                try FileManager.default.removeItem(at: current.appendingPathComponent("watch-backlog.json"))
                if kind != "witness" { try FileManager.default.removeItem(at: current.appendingPathComponent(WatchBacklogEvidence.currentCohortName)) }
                if kind != "pages" { try FileManager.default.removeItem(at: current.appendingPathComponent("BacklogEvidence")) }
                if kind == "witness" { try FileManager.default.removeItem(at: current.appendingPathComponent("watch-backlog-status.json")) }
                let reference = try FileIdentity(current.appendingPathComponent(WatchBacklogEvidence.legacyReferenceName))
                let used = Locked(0)
                for _ in 0..<2 {
                    let restored = WatchBacklogEvidence(root: root, build: "next", processRunID: UUID())
                    restored.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
                    try await self.drainBacklog(restored)
                }
                let status = try JSONSerialization.jsonObject(with: Data(contentsOf: current.appendingPathComponent("watch-backlog-status.json"))) as! [String: Any]
                try self.check(used.current == 0 && status["state"] as? String == "failed"
                               && !FileManager.default.fileExists(atPath: current.appendingPathComponent("watch-backlog.json").path)
                               && FileIdentity(current.appendingPathComponent(WatchBacklogEvidence.legacyReferenceName)) == reference,
                               "Missing summary and intent cannot erase prior pages or a committed status and mint another current cohort.")
                if kind == "pages" {
                    let name = String(format: "page-%04d-g%020llu.json", 0, summary.pages[0].generation)
                    try self.check(FileManager.default.fileExists(atPath: current.appendingPathComponent("BacklogEvidence/" + summary.sourceSetID.uuidString.lowercased() + "/" + name).path),
                                   "Unknown residual current pages remain preserved for diagnosis.")
                }
            }
        }
        await run("backlog_evidence_missing_legacy_summary_cannot_bypass_existing_current_namespace") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, _) = try self.metadataFixture(root, count: 2)
            _ = try self.legacyEmptyBacklog(root)
            let first = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
            first.captureIfNeeded { try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(first)
            let directory = root.appendingPathComponent("ConnectivityDiagnostics")
            let current = directory.appendingPathComponent(WatchBacklogEvidence.currentDirectory)
            let statusIdentity = try FileIdentity(directory.appendingPathComponent("watch-backlog-status.json"))
            let preserved = try [WatchBacklogEvidence.legacyReferenceName, WatchBacklogEvidence.currentCohortName, "watch-backlog.json"]
                .map { try FileIdentity(current.appendingPathComponent($0)) }
            try FileManager.default.removeItem(at: directory.appendingPathComponent("watch-backlog.json"))
            let used = Locked(0)
            for _ in 0..<2 {
                let restarted = WatchBacklogEvidence(root: root, build: "next", processRunID: UUID())
                restarted.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
                try await self.drainBacklog(restarted)
            }
            try self.check(used.current == 0 && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("watch-backlog.json").path)
                           && FileIdentity(directory.appendingPathComponent("watch-backlog-status.json")) == statusIdentity,
                           "A missing legacy anchor cannot turn existing current evidence into a fresh root capture or overwrite the original status.")
            try self.check(try [WatchBacklogEvidence.legacyReferenceName, WatchBacklogEvidence.currentCohortName, "watch-backlog.json"]
                .enumerated().allSatisfy { try FileIdentity(current.appendingPathComponent($0.element)) == preserved[$0.offset] },
                           "The disconnected current reference, witness and summary remain intact instead of being adopted or replaced.")
        }
        await run("backlog_evidence_current_reference_protection_retry_revalidates_link_before_restore") { f in
            for corrupt in [false, true] {
                let root = f.root.appendingPathComponent(corrupt ? "corrupt_after_outage" : "valid_after_outage")
                let (repository, _) = try self.metadataFixture(root, count: 2)
                _ = try self.legacyEmptyBacklog(root)
                let first = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
                first.captureIfNeeded { try repository.transferEvidenceSnapshot() }
                try await self.drainBacklog(first)
                let current = root.appendingPathComponent("ConnectivityDiagnostics/" + WatchBacklogEvidence.currentDirectory)
                let reference = current.appendingPathComponent(WatchBacklogEvidence.legacyReferenceName)
                let summary = try self.backlogSummary(root, current: true)
                let summaryIdentity = try FileIdentity(current.appendingPathComponent("watch-backlog.json"))
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: reference.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reference.path) }
                let used = Locked(0), restored = WatchBacklogEvidence(root: root, build: "next", processRunID: UUID())
                restored.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
                await withCheckedContinuation { done in restored.flush { done.resume() } }
                try await self.drainBacklog(restored)
                var status = try JSONSerialization.jsonObject(with: Data(contentsOf: current.appendingPathComponent("watch-backlog-status.json"))) as! [String: Any]
                try self.check(used.current == 0 && status["state"] as? String == "retry_pending",
                               "Repeated real opportunities cannot bypass an unreadable reference merely because current pages are readable.")
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reference.path)
                if corrupt { try Data("{broken reference".utf8).write(to: reference) }
                restored.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
                try await self.drainBacklog(restored)
                status = try JSONSerialization.jsonObject(with: Data(contentsOf: current.appendingPathComponent("watch-backlog-status.json"))) as! [String: Any]
                let after = try self.backlogSummary(root, current: true)
                try self.check(used.current == 0 && status["state"] as? String == (corrupt ? "failed" : "ready")
                               && after.sourceSetID == summary.sourceSetID,
                               "Recovery revalidates exact reference bytes before restoring the same current cohort; a damaged link stays failed closed.")
                if corrupt {
                    try self.check(try FileIdentity(current.appendingPathComponent("watch-backlog.json")) == summaryIdentity,
                                   "A damaged reference must preserve the exact prior summary without cross-build publication.")
                } else {
                    try self.check(after.build == "next" && after.generation == summary.generation + 1,
                                   "Only successful complete revalidation may publish the restored cohort under the current build.")
                    try self.checkFrozenBacklog(summary, after)
                }
            }
        }
        await run("backlog_evidence_metadata_read_errors_are_not_empty_catalog_observations") { f in
            for denied in [false, true] {
                let root = f.root.appendingPathComponent(denied ? "permission-error" : "decode-error")
                let (repository, manifests) = try self.metadataFixture(root, count: 1)
                let manifestURL = root.appendingPathComponent("manifests/" + manifests[0].id.uuidString.lowercased() + ".json")
                if !denied { try Data("{not valid manifest metadata".utf8).write(to: manifestURL) }
                let original = try FileIdentity(manifestURL)
                let manifestsDirectory = root.appendingPathComponent("manifests")
                if denied { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: manifestsDirectory.path) }
                defer { if denied { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manifestsDirectory.path) } }
                let observer = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
                observer.captureIfNeeded { try repository.transferEvidenceSnapshot() }
                try await self.drainBacklog(observer)
                let directory = root.appendingPathComponent("ConnectivityDiagnostics")
                let status = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("watch-backlog-status.json"))) as! [String: Any]
                try self.check(status["state"] as? String == "failed" && status["lastError"] as? String == "capture_failed",
                               "Real decode and permission failures must preserve the failure path, not become an empty retry or successful catalogue.")
                let detail = try XCTUnwrapProbe(status["failureDetail"] as? [String: Any])
                try self.check(detail["stage"] as? String == "snapshot_read"
                               && detail["kind"] as? String == (denied ? "cocoa" : "decode_corrupted"),
                               "The strict metadata provider's read failure must be distinguishable from a capture commit failure.")
                try self.check(denied ? detail["nativeErrorCode"] as? Int == CocoaError.Code.fileReadNoPermission.rawValue
                                      : detail["nativeErrorCode"] == nil,
                               "Known OS read failures retain only their numeric code; decode failures retain no native payload.")
                for name in ["watch-backlog.json", "watch-backlog-capture.json", "BacklogEvidence"] {
                    try self.check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
                                   "A failed metadata read cannot publish an empty summary, identity or intent.")
                }
                if denied { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manifestsDirectory.path) }
                try self.check(try FileIdentity(manifestURL) == original, "Metadata read errors must leave the original synthetic manifest unchanged.")
            }
        }
        await run("backlog_evidence_failure_details_distinguish_capture_restore_and_retryable_persist") { f in
            let secret = "PRIVATE-PATH-OR-RECORDING-ID-MUST-NOT-APPEAR"
            let failure = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO),
                userInfo: [NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: secret])
            func status(_ root: URL, current: Bool = false) throws -> ([String: Any], Data) {
                let directory = root.appendingPathComponent("ConnectivityDiagnostics")
                let data = try Data(contentsOf: (current ? directory.appendingPathComponent(WatchBacklogEvidence.currentDirectory) : directory)
                    .appendingPathComponent("watch-backlog-status.json"))
                return (try JSONSerialization.jsonObject(with: data) as! [String: Any], data)
            }
            let commitRoot = f.root.appendingPathComponent("capture-commit")
            let (commitRepository, _) = try self.metadataFixture(commitRoot, count: 1)
            let commit = WatchBacklogEvidence(root: commitRoot, build: "candidate", processRunID: UUID(), faultInjector: { point in
                if point == .pagesWritten { throw failure }
            })
            commit.captureIfNeeded { try commitRepository.transferEvidenceSnapshot() }
            try await self.drainBacklog(commit)
            let (commitStatus, commitBytes) = try status(commitRoot)
            let commitDetail = try XCTUnwrapProbe(commitStatus["failureDetail"] as? [String: Any])
            try self.check(commitStatus["state"] as? String == "failed" && commitDetail["stage"] as? String == "capture_commit"
                           && commitDetail["kind"] as? String == "posix" && commitDetail["nativeErrorCode"] as? Int == Int(EIO),
                           "A metadata page/summary commit failure must retain its own stage and OS code, never masquerade as a provider read error.")
            try self.check(commitBytes.count < 4_096 && !String(decoding: commitBytes, as: UTF8.self).contains(secret),
                           "Commit diagnostics remain bounded and cannot serialize localized descriptions or file paths.")

            let restoreRoot = f.root.appendingPathComponent("restore-decode")
            _ = try self.metadataFixture(restoreRoot, count: 1)
            let restoreDirectory = restoreRoot.appendingPathComponent("ConnectivityDiagnostics")
            try FileManager.default.createDirectory(at: restoreDirectory, withIntermediateDirectories: false)
            let summaryURL = restoreDirectory.appendingPathComponent("watch-backlog.json")
            try Data(("{invalid frozen summary " + secret).utf8).write(to: summaryURL)
            let original = try FileIdentity(summaryURL)
            let restore = WatchBacklogEvidence(root: restoreRoot, build: "candidate", processRunID: UUID())
            try await self.drainBacklog(restore)
            let (restoreStatus, restoreBytes) = try status(restoreRoot, current: true)
            let restoreDetail = try XCTUnwrapProbe(restoreStatus["failureDetail"] as? [String: Any])
            try self.check(restoreStatus["state"] as? String == "failed" && restoreStatus["lastError"] as? String == "restore_failed"
                           && restoreDetail["stage"] as? String == "restore" && restoreDetail["kind"] as? String == "decode_corrupted",
                           "A rejected stored archive must identify restore/decode failure without treating the existing summary as an empty new library.")
            try self.check(try FileIdentity(summaryURL) == original,
                           "Diagnostic classification cannot replace a corrupt frozen summary.")
            try self.check(!String(decoding: restoreBytes, as: UTF8.self).contains(secret),
                           "A decode context or its stored JSON content cannot leak into the bounded status.")

            let persistRoot = f.root.appendingPathComponent("persist-retry")
            let (persistRepository, manifests) = try self.metadataFixture(persistRoot, count: 1)
            let failPersist = Locked(false)
            let observer = WatchBacklogEvidence(root: persistRoot, build: "candidate", processRunID: UUID(), faultInjector: { point in
                if point == .pagesWritten, failPersist.current { throw failure }
            })
            observer.captureIfNeeded { try persistRepository.transferEvidenceSnapshot() }
            try await self.drainBacklog(observer)
            let before = try self.backlogSummary(persistRoot)
            failPersist.access { $0 = true }
            observer.recordEnqueued(manifests[0], context: .init(foreground: false, liveCapture: false, externalPower: true, opportunity: 1))
            try await self.drainBacklog(observer)
            let (retryStatus, retryBytes) = try status(persistRoot)
            let retryDetail = try XCTUnwrapProbe(retryStatus["failureDetail"] as? [String: Any])
            try self.check(retryStatus["state"] as? String == "retry_pending" && retryStatus["lastError"] as? String == "persistence_unavailable"
                           && retryDetail["stage"] as? String == "persist" && retryDetail["kind"] as? String == "posix"
                           && retryDetail["nativeErrorCode"] as? Int == Int(EIO),
                           "A retryable metadata persistence failure stays pending with a distinct stage and native code.")
            try self.check(!String(decoding: retryBytes, as: UTF8.self).contains(secret),
                           "Retry diagnostics cannot include NSError userInfo.")
            failPersist.access { $0 = false }
            await withCheckedContinuation { done in observer.flush { done.resume() } }
            try await self.drainBacklog(observer)
            let (readyStatus, _) = try status(persistRoot)
            let after = try self.backlogSummary(persistRoot)
            try self.check(readyStatus["state"] as? String == "ready" && readyStatus["lastError"] == nil && readyStatus["failureDetail"] == nil,
                           "A successful retry must clear its current failure detail rather than label a ready report with an old error.")
            try self.check(after.sourceSetID == before.sourceSetID && after.catalogSHA256 == before.catalogSHA256
                           && after.enqueuedMemberCount == 1 && after.newACKCommittedMemberCount == 0,
                           "Diagnostic retry cannot replace the frozen cohort or invent an ACK.")
        }
        await run("backlog_evidence_failure_details_redact_repository_reasons_and_unknown_error_domains") { f in
            let secret = "PRIVATE-DOMAIN-PATH-ID-DO-NOT-EXPORT"
            let examples: [(Error, String)] = [
                (RepositoryError.invalidManifest(secret), "invalid_manifest"),
                (RepositoryError.persistenceFailure(secret), "repository_persistence"),
                (NSError(domain: secret, code: 7, userInfo: [NSLocalizedDescriptionKey: secret]), "other")
            ]
            for (index, example) in examples.enumerated() {
                let root = f.root.appendingPathComponent("redaction-\(index)")
                _ = try self.metadataFixture(root, count: 0)
                let observer = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
                let injected = example.0
                observer.captureIfNeeded { throw injected }
                try await self.drainBacklog(observer)
                let bytes = try Data(contentsOf: root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog-status.json"))
                let value = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                let detail = try XCTUnwrapProbe(value["failureDetail"] as? [String: Any])
                try self.check(value["state"] as? String == "failed" && detail["stage"] as? String == "snapshot_read"
                               && detail["kind"] as? String == example.1 && detail["nativeErrorCode"] == nil,
                               "Only a fixed safe category may represent repository associated text or an unknown error domain.")
                try self.check(bytes.count < 4_096 && !String(decoding: bytes, as: UTF8.self).contains(secret),
                               "Private error descriptions, associated values, paths and custom domains must stay out of the report.")
                try self.check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog.json").path),
                               "Classifying an error never authorizes a successful empty catalogue.")
            }
        }
        await run("backlog_evidence_missing_summary_with_capture_intent_never_refreezes_metadata") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, _) = try self.metadataFixture(root, count: 2)
            let directory = root.appendingPathComponent("ConnectivityDiagnostics")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let intentURL = directory.appendingPathComponent("watch-backlog-capture.json")
            let intent = try JSONSerialization.data(withJSONObject: ["sourceSetID": UUID().uuidString, "generatedAtMS": 1_000], options: [.sortedKeys])
            try intent.write(to: intentURL)
            let original = try FileIdentity(intentURL), used = Locked(0)
            let observer = WatchBacklogEvidence(root: root, build: "candidate", processRunID: UUID())
            observer.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(observer)
            let status = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(WatchBacklogEvidence.currentDirectory + "/watch-backlog-status.json"))) as! [String: Any]
            try self.check(used.current == 0 && status["state"] as? String == "failed" && status["lastError"] as? String == "restore_failed",
                           "A missing summary with an old capture intent cannot be treated as a fresh empty installation.")
            try self.check(try FileIdentity(intentURL) == original, "An unresolved old intent must remain byte-for-byte available for diagnosis.")
            try self.check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("watch-backlog.json").path),
                           "A missing frozen summary cannot authorize a replacement metadata cohort.")
        }
        await run("backlog_evidence_12288_complete_metadata_sources_without_audio_or_event_scan") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, manifests) = try self.metadataFixture(root, count: 12_288)
            // A bad event proves this capture never reuses the old full event export.
            try Data("broken event".utf8).write(to: root.appendingPathComponent("events/" + UUID().uuidString.lowercased() + ".json"))
            let historical = manifests[0]
            let receipt = SegmentReceipt(segmentID: historical.id, sha256: historical.sha256, byteCount: historical.byteCount)
            for folder in ["receipts", "acknowledgements"] {
                try TransportCodec.encode(receipt).write(to: root.appendingPathComponent(folder + "/" + historical.id.uuidString.lowercased() + ".json"))
            }
            let observer = WatchBacklogEvidence(root: root, build: "62", processRunID: UUID())
            observer.captureIfNeeded { try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(observer)
            let summary = try self.backlogSummary(root), pages = try self.backlogPages(root, summary)
            try self.check(summary.sourceCount == 12_288 && pages.flatMap(\.members).count == 12_288, "No source may be truncated at 10k capacity")
            try self.check(summary.pages.count == 439 && summary.sourceSetComplete, "All 439 bounded pages must be committed before summary")
            try self.check(summary.historicalACKMetadataCount == 1 && summary.successfulACKConfirmationMemberCount == 0,
                           "Initial ACK JSON is historical metadata, never a fresh durability observation")
            try self.check(summary.pendingNonHistoricalMemberCount == 12_287 && !summary.allNonHistoricalMembersACKConfirmed,
                           "All other metadata sources remain explicitly unconfirmed")
            try self.check(!summary.audioRead && !summary.includesAudio && !summary.cloudCompletionProven,
                           "A metadata cohort cannot claim content integrity or cloud upload")
            try self.check(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("segments").path).isEmpty,
                           "The entire capacity fixture has no audio files")
            let count = Locked(0)
            observer.captureIfNeeded { count.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(observer)
            try self.check(count.current == 0, "Ordinary foreground recurrence must not repeat a full catalogue scan")
        }
        await run("backlog_evidence_progress_retained_per_source_across_restart_and_replay") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, manifests) = try self.metadataFixture(root, count: 36)
            let firstRun = UUID(), nextRun = UUID()
            let observer = WatchBacklogEvidence(root: root, build: "62", processRunID: firstRun)
            observer.captureIfNeeded { try repository.transferEvidenceSnapshot() }; try await self.drainBacklog(observer)
            let original = try self.backlogSummary(root)
            let context = WatchBacklogEvidence.Context(foreground: false, liveCapture: false, externalPower: true, opportunity: 43)
            for (index, manifest) in manifests.enumerated() {
                observer.recordEnqueued(manifest, context: context, at: original.capturedAtMS + Int64(index) + 1)
                let receipt = SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount)
                observer.recordAcknowledgement(receipt, manifest: manifest, newlyCommitted: true, context: context,
                    at: original.capturedAtMS + Int64(index) + 101)
            }
            try await self.drainBacklog(observer)
            let summary = try self.backlogSummary(root)
            try self.check(summary.newACKCommittedMemberCount == 36 && summary.pendingNonHistoricalMemberCount == 0,
                           "More than eight per-source ACKs must survive together")
            let restored = WatchBacklogEvidence(root: root, build: "63", processRunID: nextRun)
            try await self.drainBacklog(restored)
            let used = Locked(0)
            restored.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            let receipt = SegmentReceipt(segmentID: manifests[0].id, sha256: manifests[0].sha256, byteCount: manifests[0].byteCount)
            restored.recordAcknowledgement(receipt, manifest: manifests[0], newlyCommitted: false,
                context: .init(foreground: true, liveCapture: false, externalPower: false, opportunity: nil),
                at: original.capturedAtMS + 1000)
            try await self.drainBacklog(restored)
            let next = try self.backlogSummary(root), members = try self.backlogPages(root, next).flatMap(\.members)
            try self.check(next.sourceSetID == original.sourceSetID && next.generation > summary.generation && used.current == 0,
                           "Cold restore preserves the exact cohort without scanning repository history")
            let member = try XCTUnwrapProbe(members.first { $0.segmentID == manifests[0].id })
            try self.check(member.firstNewACKProcessRunID == firstRun && member.firstNewACKContext == context && member.lastACKProcessRunID == nextRun,
                           "A foreground ACK replay cannot replace the original background new-ACK evidence")
            try self.check(next.newACKCommittedMemberCount == 36 && next.allNonHistoricalMembersACKConfirmed,
                           "A replay confirms current ACK durability without inventing another new ACK")
        }
        await run("backlog_evidence_corrupt_or_missing_page_blocks_restore_without_recapture") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, _) = try self.metadataFixture(root, count: 29)
            let observer = WatchBacklogEvidence(root: root, build: "62", processRunID: UUID())
            observer.captureIfNeeded { try repository.transferEvidenceSnapshot() }; try await self.drainBacklog(observer)
            let original = try self.backlogSummary(root)
            let summaryURL = root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog.json")
            let preserved = try Data(contentsOf: summaryURL)
            let name = String(format: "page-%04d-g%020llu.json", 0, original.pages[0].generation)
            let page = root.appendingPathComponent("ConnectivityDiagnostics/BacklogEvidence/" + original.sourceSetID.uuidString.lowercased() + "/" + name)
            try FileManager.default.removeItem(at: page)
            let restored = WatchBacklogEvidence(root: root, build: "62", processRunID: UUID()), used = Locked(0)
            restored.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(restored)
            let statusBytes = try Data(contentsOf: root.appendingPathComponent("ConnectivityDiagnostics/" + WatchBacklogEvidence.currentDirectory + "/watch-backlog-status.json"))
            let status = try JSONSerialization.jsonObject(with: statusBytes) as! [String: Any]
            try self.check(status["state"] as? String == "failed" && status["lastError"] as? String == "restore_failed",
                           "A missing bound page is an explicit failure")
            try self.check(used.current == 0 && (try Data(contentsOf: summaryURL)) == preserved,
                           "A damaged archive is never silently rebuilt or relabelled complete")
        }
        await run("backlog_evidence_retry_transient_restore_preserves_deferred_real_ACK_and_frozen_cohort") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, manifests) = try self.metadataFixture(root, count: 36)
            let first = WatchBacklogEvidence(root: root, build: "63", processRunID: UUID())
            first.captureIfNeeded { try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(first)
            let original = try self.backlogSummary(root)
            let manifest = manifests[0]
            let receipt = SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount)
            let committed = try repository.acknowledge(receipt, pruneAudio: false)
            try self.check(committed.acknowledgementChanged, "Only a real repository commit supplies the deferred observation.")
            let observedAt = original.capturedAtMS + 7
            let context = WatchBacklogEvidence.Context(foreground: false, liveCapture: false, externalPower: true, opportunity: 71)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
            let restored = WatchBacklogEvidence(root: root, build: "64", processRunID: UUID())
            restored.recordAcknowledgement(receipt, manifest: manifest, newlyCommitted: true, context: context, at: observedAt)
            try await self.drainBacklog(restored)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let used = Locked(0)
            restored.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            await withCheckedContinuation { done in restored.flush { done.resume() } }
            try await self.drainBacklog(restored)
            let after = try self.backlogSummary(root)
            let row = try XCTUnwrapProbe(try self.backlogPages(root, after).flatMap(\.members).first { $0.segmentID == manifest.id })
            try self.check(after.sourceSetID == original.sourceSetID && after.catalogSHA256 == original.catalogSHA256 && used.current == 0,
                           "A transient read outage must restore the original frozen cohort, never recapture history.")
            try self.check(after.newACKCommittedMemberCount == 1 && row.firstNewACKCommittedAtMS == observedAt && row.firstNewACKContext == context,
                           "The successful ACK observed during a temporary metadata outage must retain its exact event time/context after recovery.")
            try self.check(try repository.hasDurableAcknowledgement(for: manifest), "Metadata retry cannot replace the real durable ACK.")
        }
        await run("backlog_evidence_retry_transient_persist_retains_dirty_ACK_until_next_real_opportunity") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, manifests) = try self.metadataFixture(root, count: 2)
            let observer = WatchBacklogEvidence(root: root, build: "64", processRunID: UUID())
            observer.captureIfNeeded { try repository.transferEvidenceSnapshot() }; try await self.drainBacklog(observer)
            let original = try self.backlogSummary(root), manifest = manifests[0]
            let receipt = SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount)
            _ = try repository.acknowledge(receipt, pruneAudio: false)
            let context = WatchBacklogEvidence.Context(foreground: false, liveCapture: false, externalPower: true, opportunity: 72)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
            observer.recordAcknowledgement(receipt, manifest: manifest, newlyCommitted: true, context: context, at: original.capturedAtMS + 5)
            try await self.drainBacklog(observer)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            observer.recordEnqueued(manifests[1], context: context, at: original.capturedAtMS + 8)
            await withCheckedContinuation { done in observer.flush { done.resume() } }
            try await self.drainBacklog(observer)
            let after = try self.backlogSummary(root)
            try self.check(after.sourceSetID == original.sourceSetID && after.catalogSHA256 == original.catalogSHA256,
                           "A write outage cannot change the frozen denominator or catalogue.")
            try self.check(after.newACKCommittedMemberCount == 1 && after.enqueuedMemberCount == 1 && after.pendingNonHistoricalMemberCount == 1,
                           "A transient writer failure cannot permanently block dirty ACK and later genuine enqueue observations.")
        }
        await run("backlog_evidence_retry_cannot_recapture_a_cohort_removed_during_outage") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, _) = try self.metadataFixture(root, count: 2)
            let first = WatchBacklogEvidence(root: root, build: "63", processRunID: UUID())
            first.captureIfNeeded { try repository.transferEvidenceSnapshot() }; try await self.drainBacklog(first)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
            let restored = WatchBacklogEvidence(root: root, build: "64", processRunID: UUID())
            try await self.drainBacklog(restored)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try FileManager.default.removeItem(at: root.appendingPathComponent("ConnectivityDiagnostics"))
            let used = Locked(0)
            restored.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(restored)
            let status = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ConnectivityDiagnostics/" + WatchBacklogEvidence.currentDirectory + "/watch-backlog-status.json"))) as! [String: Any]
            try self.check(used.current == 0 && status["state"] as? String == "failed" && status["lastError"] as? String == "restore_failed",
                           "An outage followed by missing evidence is a hard failure, never a new denominator.")
            try self.check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog.json").path),
                           "A failed recovery cannot silently freeze replacement history.")
        }
        await run("backlog_evidence_retry_refuses_corrupt_bound_page_and_discards_deferred_observation") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, manifests) = try self.metadataFixture(root, count: 2)
            let first = WatchBacklogEvidence(root: root, build: "63", processRunID: UUID())
            first.captureIfNeeded { try repository.transferEvidenceSnapshot() }; try await self.drainBacklog(first)
            let original = try self.backlogSummary(root), manifest = manifests[0]
            let receipt = SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount)
            _ = try repository.acknowledge(receipt, pruneAudio: false)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
            let restored = WatchBacklogEvidence(root: root, build: "64", processRunID: UUID())
            restored.recordAcknowledgement(receipt, manifest: manifest, newlyCommitted: true,
                context: .init(foreground: false, liveCapture: false, externalPower: true, opportunity: 73))
            try await self.drainBacklog(restored)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let name = String(format: "page-%04d-g%020llu.json", 0, original.pages[0].generation)
            let page = root.appendingPathComponent("ConnectivityDiagnostics/BacklogEvidence/" + original.sourceSetID.uuidString.lowercased() + "/" + name)
            try Data("{\"corrupt\":true}".utf8).write(to: page)
            let used = Locked(0)
            restored.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(restored)
            let after = try self.backlogSummary(root)
            let status = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ConnectivityDiagnostics/" + WatchBacklogEvidence.currentDirectory + "/watch-backlog-status.json"))) as! [String: Any]
            try self.check(used.current == 0 && status["state"] as? String == "failed" && after.generation == original.generation && after.newACKCommittedMemberCount == 0,
                           "A corrupt bound page cannot become retryable or apply deferred ACKs behind an invalid catalogue.")
            try self.check(try repository.hasDurableAcknowledgement(for: manifest), "A rejected evidence archive cannot undo the actual durable ACK.")
        }
        await run("backlog_evidence_retry_deferred_events_share_bounded_admission_and_report_overflow") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, manifests) = try self.metadataFixture(root, count: 1)
            let first = WatchBacklogEvidence(root: root, build: "63", processRunID: UUID())
            first.captureIfNeeded { try repository.transferEvidenceSnapshot() }; try await self.drainBacklog(first)
            let original = try self.backlogSummary(root), manifest = manifests[0]
            let receipt = SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount)
            _ = try repository.acknowledge(receipt, pruneAudio: false)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
            let restored = WatchBacklogEvidence(root: root, build: "64", processRunID: UUID())
            let limit = WatchBacklogEvidence.maximumSources * 2
            for index in 0...limit {
                restored.recordAcknowledgement(receipt, manifest: manifest, newlyCommitted: index == 0,
                    context: .init(foreground: false, liveCapture: false, externalPower: true, opportunity: 74),
                    at: original.capturedAtMS + Int64(index + 1))
            }
            try await self.drainBacklog(restored)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            await withCheckedContinuation { done in restored.flush { done.resume() } }
            try await self.drainBacklog(restored)
            let after = try self.backlogSummary(root)
            let member = try XCTUnwrapProbe(try self.backlogPages(root, after).flatMap(\.members).first)
            try self.check(after.sourceSetID == original.sourceSetID && after.catalogSHA256 == original.catalogSHA256 && member.acknowledgementCount == UInt64(limit),
                           "Deferred events consume the same bounded admission as queued events and preserve the immutable cohort.")
            try self.check(after.observationOverflowCount == 1 && !after.allNonHistoricalMembersACKConfirmed,
                           "Overflow while storage is unavailable survives restore and prevents an unsupported completion claim.")
        }
        await run("backlog_evidence_uncertain_summary_commit_never_reuses_bound_page_generation") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, manifests) = try self.metadataFixture(root, count: 2)
            let mode = Locked(0), blocked = Locked(false), release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let observer = WatchBacklogEvidence(root: root, build: "64", processRunID: UUID(), faultInjector: { point in
                let state = mode.current
                if point == .summaryRenamed, state == 1 {
                    mode.access { $0 = 2 }; throw POSIXError(.EIO)
                }
                if point == .pagesWritten, state == 3 {
                    blocked.access { $0 = true }; _ = release.wait(timeout: .now() + 10)
                    mode.access { $0 = 4 }; throw POSIXError(.EIO)
                }
            })
            observer.captureIfNeeded { try repository.transferEvidenceSnapshot() }; try await self.drainBacklog(observer)
            let original = try self.backlogSummary(root)
            let context = WatchBacklogEvidence.Context(foreground: false, liveCapture: false, externalPower: true, opportunity: 75)
            let firstTime = original.capturedAtMS + 5, secondTime = original.capturedAtMS + 8
            let first = SegmentReceipt(segmentID: manifests[0].id, sha256: manifests[0].sha256, byteCount: manifests[0].byteCount)
            let second = SegmentReceipt(segmentID: manifests[1].id, sha256: manifests[1].sha256, byteCount: manifests[1].byteCount)
            _ = try repository.acknowledge(first, pruneAudio: false)
            mode.access { $0 = 1 }
            observer.recordAcknowledgement(first, manifest: manifests[0], newlyCommitted: true, context: context, at: firstTime)
            try await self.drainBacklog(observer)
            let uncertain = try self.backlogSummary(root)
            _ = try self.backlogPages(root, uncertain)
            try self.check(uncertain.generation > original.generation && uncertain.newACKCommittedMemberCount == 1,
                           "A rename followed by failed directory fsync can expose a complete newer binding while memory retains the old summary.")
            _ = try repository.acknowledge(second, pruneAudio: false)
            mode.access { $0 = 3 }
            observer.recordAcknowledgement(second, manifest: manifests[1], newlyCommitted: true, context: context, at: secondTime)
            try await self.eventually("retry pages were written before the next summary commit") { blocked.current }
            let duringRetry = try self.backlogSummary(root)
            let bound = try self.backlogPages(root, duringRetry)
            try self.check(duringRetry.generation == uncertain.generation && bound.flatMap(\.members).filter { $0.firstNewACKCommittedAtMS != nil }.count == 1,
                           "Writing a retry with a new ACK cannot overwrite any page still referenced by the uncertain committed summary.")
            let used = Locked(0)
            let cold = WatchBacklogEvidence(root: root, build: "64", processRunID: UUID())
            cold.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
            try await self.drainBacklog(cold)
            try self.check(used.current == 0 && (try self.backlogSummary(root)).sourceSetID == original.sourceSetID,
                           "A cold observer during this crash window still restores the last complete binding without recapturing.")
            release.signal(); try await self.drainBacklog(observer)
            mode.access { $0 = 0 }
            observer.recordEnqueued(manifests[0], context: context, at: original.capturedAtMS + 12)
            await withCheckedContinuation { done in observer.flush { done.resume() } }; try await self.drainBacklog(observer)
            let after = try self.backlogSummary(root), rows = try self.backlogPages(root, after).flatMap(\.members)
            try self.check(after.sourceSetID == original.sourceSetID && after.catalogSHA256 == original.catalogSHA256 && after.newACKCommittedMemberCount == 2,
                           "Recovery preserves the exact frozen cohort and both real committed ACKs.")
            try self.check(rows.first { $0.segmentID == manifests[0].id }?.firstNewACKCommittedAtMS == firstTime
                && rows.first { $0.segmentID == manifests[1].id }?.firstNewACKCommittedAtMS == secondTime
                && rows.allSatisfy { $0.firstNewACKContext == context },
                           "Retry generations cannot relabel the original ACK event times or contexts.")
        }
        await run("backlog_evidence_retry_rejects_symlink_and_wrong_type_as_permanent_metadata_failures") { f in
            for wrongType in [false, true] {
                let root = f.root.appendingPathComponent(wrongType ? "wrong-type" : "symlink")
                let (repository, _) = try self.metadataFixture(root, count: 1)
                let first = WatchBacklogEvidence(root: root, build: "63", processRunID: UUID())
                first.captureIfNeeded { try repository.transferEvidenceSnapshot() }; try await self.drainBacklog(first)
                let url = root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog.json")
                let sentinel = root.appendingPathComponent("sentinel-metadata.json"), saved = try Data(contentsOf: url)
                try saved.write(to: sentinel); try FileManager.default.removeItem(at: url)
                if wrongType { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
                else { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: sentinel) }
                let used = Locked(0), restored = WatchBacklogEvidence(root: root, build: "64", processRunID: UUID())
                restored.captureIfNeeded { used.access { $0 += 1 }; return try repository.transferEvidenceSnapshot() }
                try await self.drainBacklog(restored)
                let status = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ConnectivityDiagnostics/" + WatchBacklogEvidence.currentDirectory + "/watch-backlog-status.json"))) as! [String: Any]
                try self.check(used.current == 0 && status["state"] as? String == "failed" && status["lastError"] as? String == "restore_failed",
                               "ELOOP and verified nonregular metadata are permanent failures, never retryable unavailability.")
                try self.check(try Data(contentsOf: sentinel) == saved, "Unsafe metadata paths cannot modify the synthetic sentinel or recapture a denominator.")
            }
        }
        await run("backlog_evidence_outside_cohort_and_exact_identity_conflicts_are_explicit") { f in
            let root = f.root.appendingPathComponent("metadata-only")
            let (repository, manifests) = try self.metadataFixture(root, count: 1)
            let observer = WatchBacklogEvidence(root: root, build: "62", processRunID: UUID())
            observer.captureIfNeeded { try repository.transferEvidenceSnapshot() }; try await self.drainBacklog(observer)
            let value = manifests[0], id = UUID()
            let outside = SegmentManifest(id: id, sessionID: value.sessionID, sequence: 2, startedAt: value.startedAt, endedAt: value.endedAt,
                sampleRate: value.sampleRate, frameCount: value.frameCount, fileName: id.uuidString.lowercased() + ".caf",
                byteCount: value.byteCount, sha256: value.sha256)
            let conflicting = SegmentManifest(id: value.id, sessionID: value.sessionID, sequence: 0,
                startedAt: value.startedAt.addingTimeInterval(1), endedAt: value.endedAt.addingTimeInterval(1), sampleRate: value.sampleRate,
                frameCount: value.frameCount, fileName: value.fileName, byteCount: value.byteCount, sha256: value.sha256)
            let context = WatchBacklogEvidence.Context(foreground: false, liveCapture: false, externalPower: true, opportunity: nil)
            observer.recordEnqueued(outside, context: context); observer.recordEnqueued(conflicting, context: context)
            observer.recordIdentityReadFailure(); try await self.drainBacklog(observer)
            let summary = try self.backlogSummary(root)
            try self.check(summary.sourceCount == 1 && summary.outsideCohortObservationCount == 1 && summary.identityConflictCount == 1,
                           "New sources never expand an already frozen cohort or match by ID alone")
            try self.check(summary.identityReadFailureCount == 1 && !summary.allNonHistoricalMembersACKConfirmed,
                           "A metadata lookup failure prevents complete-proof claims without affecting transfer")
        }
        await run("backlog_evidence_maximum_page_and_summary_encoding_stay_within_fixed_caps") { f in
            let context = WatchBacklogEvidence.Context(foreground: false, liveCapture: false, externalPower: true, opportunity: UInt64.max)
            var member = WatchBacklogEvidence.Member(segmentID: UUID(), sha256: String(repeating: "f", count: 64),
                byteCount: Int64.max, startedAtMS: Int64.max, sequence: Int.max,
                historicalACKMetadata: false, historicalReceiptMetadata: false)
            member.firstEnqueuedAtMS = Int64.max; member.lastEnqueuedAtMS = Int64.max; member.enqueueCount = UInt64.max
            member.lastEnqueueProcessRunID = UUID(); member.lastEnqueueContext = context
            member.firstACKConfirmedAtMS = Int64.max; member.lastACKConfirmedAtMS = Int64.max; member.acknowledgementCount = UInt64.max
            member.firstNewACKCommittedAtMS = Int64.max; member.firstNewACKProcessRunID = UUID(); member.firstNewACKContext = context
            member.lastACKProcessRunID = UUID(); member.lastACKContext = context
            let page = WatchBacklogEvidence.Page(schemaVersion: 1, role: "watch", sourceSetID: UUID(), generation: UInt64.max,
                build: String(repeating: "x", count: 32), processRunID: UUID(), index: 439, sourceCount: 12_288,
                members: Array(repeating: member, count: WatchBacklogEvidence.sourcesPerPage))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try self.check(try encoder.encode(page).count <= 32_768, "A fully populated worst-case progress page must fit 32 KiB")
        }
        await run("backlog_evidence_status_query_or_headless_start_never_captures_catalogue") { f in
            _ = try f.sealHistorical(1)
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.bridge.resynchronize(); try await self.drainQueuedWork(f)
            try self.check(!FileManager.default.fileExists(atPath: f.watch.root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog.json").path),
                           "Headless background work cannot capture a full catalogue")
            f.bridge.foregroundDidChange(true); f.bridge.setMaintenanceAllowed(true, foreground: true, liveCapture: false)
            f.bridge.resynchronize(); try await self.drainQueuedWork(f)
            try await self.eventually("first ordinary foreground catalogue exists") {
                FileManager.default.fileExists(atPath: f.watch.root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog.json").path)
            }
            let original = try self.backlogSummary(f.watch.root)
            try self.check(original.sourceCount == 1 && original.sourceSetComplete, "Foreground capture includes every source manifest")
        }
    }
    func XCTUnwrapProbe<T>(_ value: T?) throws -> T {
        guard let value else { throw ProbeFailure.failed("Expected synthetic evidence member missing") }; return value
    }

    func executeD3Cases() async {
        await run("d3_one_hundred_fresh_segments_use_bounded_battery_batches_with_missing_and_late_callbacks") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let values = try (1...100).map(f.seal)
            f.restartBridge(maintenanceAllowed: false)
            var opportunities = 0, accepted = 0
            var delayedCallbacks: [WCSessionFileTransfer] = []
            var restarted = false
            while accepted < values.count {
                if f.session.state.current.files.isEmpty {
                    let before = f.session.state.current.allEnqueued.count
                    try await self.receiptOpportunity(f); opportunities += 1
                    try self.check(f.session.state.current.allEnqueued.count - before <= 3,
                        "A real battery WK opportunity remains bounded to three registrations.")
                }
                let batch = f.session.state.current.files
                try self.check(!batch.isEmpty && batch.count <= 3,
                    "Real ACK callbacks may refill after WK release, always within three physical native tasks.")
                for old in delayedCallbacks {
                    f.bridge.session(f.session, didFinish: old, error: NSError(domain: "DelayedOldCompletion", code: 1))
                }
                delayedCallbacks.removeAll()
                for task in batch {
                    let value = task.manifest!
                    try self.check(try FileManager.default.fileExists(atPath: f.watch.audioURL(for: value).path)
                        && !f.watch.hasDurableAcknowledgement(for: value),
                        "Native registration and delayed callbacks retain every unacknowledged source.")
                    f.session.removeFromSystemQueue(task)
                    if value.sequence % 2 == 0 { delayedCallbacks.append(task) }
                }
                let head = try f.watch.freshTransferSnapshot().head!.id
                for task in batch.reversed() {
                    let value = task.manifest!
                    try f.deliver(f.receipt(value), route: value.sequence)
                    try await self.drainQueuedWork(f)
                    if value.id != head {
                        try self.check(try f.watch.freshTransferSnapshot().head?.id == head,
                            "An out-of-order receipt cannot advance over the batch's unacknowledged head.")
                    }
                    accepted += 1
                }
                if accepted >= 50 && !restarted { f.restartBridge(maintenanceAllowed: false); restarted = true }
            }
            for old in delayedCallbacks { f.bridge.session(f.session, didFinish: old, error: nil) }
            try await self.drainQueuedWork(f)
            try self.check(opportunities > 0 && opportunities <= 34 && f.session.state.current.maximumOutstanding == 3,
                "One hundred sources progress through real WK/ACK callbacks without exceeding the battery native bound.")
            try self.check(f.session.state.current.allEnqueued.count == 100
                && Set(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id }).count == 100,
                "Lost or stale callbacks and a process restart must not create duplicate registrations.")
            for value in values {
                try self.check(try f.watch.hasDurableAcknowledgement(for: value),
                    "All hundred successes require their own exact durable phone receipt.")
            }
        }

        for bounded in [false, true] {
            await run("d3_battery_history_reserves_fresh_capacity_bounded_\(bounded)") { f in
                let history = try (1...8).map(f.sealHistorical)
                if bounded {
                    f.restartBridge(maintenanceAllowed: false)
                    try await self.receiptOpportunity(f)
                } else {
                    f.update(); try await self.drainQueuedWork(f)
                }
                try self.check(f.session.state.current.files.count == 2 && f.session.state.current.maximumOutstanding == 2,
                    "A battery history backlog occupies two native slots and keeps the third slot reserved for fresh work.")
                for value in history {
                    try self.check(try FileManager.default.fileExists(atPath: f.watch.audioURL(for: value).path)
                        && !f.watch.hasDurableAcknowledgement(for: value),
                        "Increasing history capacity does not turn admission into acknowledgement or cleanup.")
                }
            }
        }

        for mode in ["low_capacity", "unknown_capacity", "deadline"] {
            await run("d3_battery_batch_retains_handoff_guard_\(mode)") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                let values = try (1...5).map(f.seal)
                f.restartBridge(maintenanceAllowed: false)
                if mode == "low_capacity" { f.availableCapacity.access { $0 = 32 * 1_024 * 1_024 - 1 } }
                if mode == "unknown_capacity" { f.availableCapacity.access { $0 = nil } }
                if mode == "deadline" {
                    f.capacityReadAction.access { $0 = { f.handoffTime.access { $0 = 2 } } }
                }
                try await self.receiptOpportunity(f)
                try self.check(f.session.state.current.allEnqueued.isEmpty,
                    "A wider battery batch cannot bypass disk availability or the preparation deadline.")
                for value in values {
                    try self.check(try FileManager.default.fileExists(atPath: f.watch.audioURL(for: value).path)
                        && !f.watch.hasDurableAcknowledgement(for: value),
                        "Rejected handoff keeps the source and its pending ACK state.")
                }
            }
        }

        await run("d3_unplug_during_first_registration_clamps_remaining_battery_batch") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            _ = try (1...16).map(f.seal)
            f.charging.access { $0 = true }
            f.restartBridge(maintenanceAllowed: false)
            f.session.fileEnqueueAction.access { $0 = {
                f.charging.access { $0 = false }
                f.session.fileEnqueueAction.access { $0 = nil }
            } }
            try await self.receiptOpportunity(f)
            try self.check(f.session.state.current.allEnqueued.count == 3 && f.session.state.current.maximumOutstanding == 3,
                "Unplugging after one charged registration clamps the same opportunity to three total registrations.")
        }

        for mode in ["unchanged", "restart", "progress", "clock_rollback", "short_background", "exact_ack"] {
            await run("d3_persisted_idle_recovery_requires_exact_receipt_first_\(mode)") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                let value = try f.seal(1)
                f.restartBridge(maintenanceAllowed: mode != "short_background",
                    recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
                // Keep the synthetic recovery interval in the past so the
                // independent production retry backoff has elapsed when the
                // fake system eventually removes a cancelled attempt.
                f.recoveryTime.access { $0.date = $0.date.addingTimeInterval(-300) }
                let start = f.recoveryTime.current
                let task = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(value),
                    "diagnosticEnqueuedAt": start.date.addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970,
                    "fileTransferAttemptID": UUID().uuidString
                ])
                let source = try FileIdentity(f.watch.audioURL(for: value))
                if mode == "short_background" { try await self.receiptOpportunity(f) }
                else { f.update(); try await self.drainQueuedWork(f) }
                try self.check(task.cancellationCount.current == 0,
                    "An old native enqueue timestamp alone cannot establish a stalled attempt.")
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(61), start.uptime + 61) }
                if mode == "restart" { f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15) }
                if mode == "short_background" { try await self.receiptOpportunity(f) }
                else { f.update(); try await self.drainQueuedWork(f) }
                try self.check(task.cancellationCount.current == 0,
                    "A no-progress candidate must first request its exact receipt and retain the native task during the reply grace.")
                try self.check(try f.receiptRequests.contains { try f.requestTarget($0)?.matches(value) == true },
                    "Recovery must have a real system-owned request bound to this segment, size and digest.")
                if mode == "progress" { task.progress.completedUnitCount = 20 }
                if mode == "clock_rollback" {
                    f.recoveryTime.access { $0 = (start.date.addingTimeInterval(-120), start.uptime + 62) }
                    f.update(); try await self.drainQueuedWork(f)
                }
                if mode == "exact_ack" {
                    let wrong = SegmentReceipt(segmentID: value.id, sha256: String(repeating: "0", count: 64), byteCount: value.byteCount)
                    try f.deliver(wrong); try await self.drainQueuedWork(f)
                    try self.check(try task.cancellationCount.current == 0 && !f.watch.hasDurableAcknowledgement(for: value),
                        "A mismatched reply cannot authorize recovery, acknowledgement, or source deletion.")
                    try f.deliver(f.receipt(value)); try await self.drainQueuedWork(f)
                    try self.check(try f.watch.hasDurableAcknowledgement(for: value),
                        "A genuine response commits its own durable ACK before duplicate-native cleanup.")
                }
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(77), start.uptime + 77) }
                if mode == "short_background" { try await self.receiptOpportunity(f) }
                else { f.update(); try await self.drainQueuedWork(f) }
                let shouldCancel = ["unchanged", "restart", "exact_ack"].contains(mode)
                try self.check(task.cancellationCount.current == (shouldCancel ? 1 : 0),
                    "Only continuous unchanged observations after the exact receipt grace permit full-maintenance cancellation; ACK cleanup remains independent.")
                try self.check(f.session.state.current.files.count == 1 && f.session.state.current.allEnqueued.isEmpty,
                    "A cancel request still occupies native capacity and cannot register a replacement before actual removal.")
                if mode != "exact_ack" {
                    try self.check(try FileIdentity(f.watch.audioURL(for: value)) == source
                        && !f.watch.hasDurableAcknowledgement(for: value),
                        "Observation and stalled cancellation preserve original source bytes and cannot invent an ACK.")
                }
                if mode == "unchanged" || mode == "restart" {
                    f.update(); try await self.drainQueuedWork(f)
                    try self.check(task.cancellationCount.current == 1,
                        "Repeated owner signals cannot repeatedly cancel the same native attempt.")
                    f.session.removeFromSystemQueue(task)
                    f.update()
                    try await self.eventually("actual native removal permits one safe replacement") {
                        f.session.state.current.allEnqueued.count == 1
                    }
                    try await self.drainQueuedWork(f)
                    let replacement = f.session.state.current.allEnqueued[0]
                    try self.check(replacement.manifest == value
                        && replacement.file.metadata?["fileTransferAttemptID"] as? String
                            != task.file.metadata?["fileTransferAttemptID"] as? String,
                        "Recovery resubmits the same verified source under a new native attempt identity.")
                    let retry = try FileIdentity(f.retryURL)
                    f.bridge.session(f.session, didFinish: task, error: nil)
                    f.bridge.session(f.session, didFinish: task, error: NSError(domain: "LateStalledCancellation", code: 1))
                    try await self.drainQueuedWork(f)
                    try self.check(try FileIdentity(f.retryURL) == retry,
                        "Late success or failure of the cancelled attempt cannot change the replacement's retry identity.")
                    try self.check(f.session.state.current.maximumOutstanding == 1,
                        "Recovery never overlaps the cancelled object with its replacement.")
                }
            }
        }

        for mode in ["foreign", "acknowledged"] {
            await run("d3_unrecoverable_native_prefix_does_not_hide_stalled_attempt_\(mode)") { f in
                let prefix = try f.sealHistorical(1), value = try f.sealHistorical(2)
                f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
                let start = f.recoveryTime.current
                let firstManifest: SegmentManifest
                if mode == "acknowledged" {
                    try f.watch.acknowledge(f.receipt(prefix), pruneAudio: true)
                    firstManifest = prefix
                } else {
                    firstManifest = SegmentManifest(id: UUID(), sessionID: prefix.sessionID, sequence: prefix.sequence,
                        startedAt: prefix.startedAt, endedAt: prefix.endedAt, sampleRate: prefix.sampleRate,
                        frameCount: prefix.frameCount, fileName: "foreign.caf", byteCount: prefix.byteCount, sha256: prefix.sha256)
                }
                let first = f.session.addLegacyTask(url: f.watch.audioURL(for: firstManifest), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(firstManifest),
                    "fileTransferAttemptID": UUID().uuidString])
                let stalled = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(value),
                    "fileTransferAttemptID": UUID().uuidString])
                f.update(); try await self.drainQueuedWork(f)
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(61), start.uptime + 61) }
                f.receiptRequestUptime.access { $0 += BackgroundReceiptRequestPolicy.interval + 1 }
                f.update(); try await self.drainQueuedWork(f)
                try self.check(try f.receiptRequests.contains { try f.requestTarget($0)?.matches(value) == true },
                    "An already-ACKed or unknown prefix cannot prevent querying the later exact stalled source.")
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(77), start.uptime + 77) }
                f.update(); try await self.drainQueuedWork(f)
                try self.check(stalled.cancellationCount.current == 1,
                    "Bounded recovery must reach the healthy second candidate after skipping an ineligible native prefix.")
                if mode == "foreign" {
                    try self.check(first.cancellationCount.current == 0,
                        "Skipping an unknown source must not authorize cancelling it.")
                }
                try self.check(f.session.state.current.files.count == 2 && f.session.state.current.allEnqueued.isEmpty,
                    "Both native objects still consume capacity after any cancellation request.")
                try self.check(try !f.watch.hasDurableAcknowledgement(for: value),
                    "The prefix's ACK can never become acknowledgement authority for the stalled source.")
            }
        }

        for mode in ["progress", "maintenance_revoked", "source_removed", "query_failed"] {
            await run("d3_final_cancel_recheck_rolls_back_unissued_intent_\(mode)") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                let value = try f.seal(1)
                f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
                if mode == "query_failed" { f.session.isReachable = false }
                let start = f.recoveryTime.current
                let task = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(value),
                    "fileTransferAttemptID": UUID().uuidString])
                let source = try FileIdentity(f.watch.audioURL(for: value))
                f.update(); try await self.drainQueuedWork(f)
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(61), start.uptime + 61) }
                f.update(); try await self.drainQueuedWork(f)
                let retryBeforeRejectedCancellation = try f.retryState()
                let triggered = Locked(false)
                let progressURL = f.watch.root.appendingPathComponent("transfer-progress-state.json")
                f.session.outstandingReadAction.access { $0 = { _ in
                    guard !triggered.current,
                          let data = try? Data(contentsOf: progressURL),
                          let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let observations = state["observations"] as? [String: [String: Any]],
                          observations.values.contains(where: { $0["cancellationRequested"] as? Bool == true }) else { return }
                    triggered.access { $0 = true }
                    switch mode {
                    case "progress": task.progress.completedUnitCount = 20
                    case "maintenance_revoked": f.bridge.setMaintenanceAllowed(false)
                    case "query_failed":
                        if let query = f.session.state.current.userInfo.first(where: {
                            (try? f.requestTarget($0.userInfo)?.matches(value)) == true
                        }) {
                            f.session.removeFromSystemQueue(query)
                            f.bridge.session(f.session, didFinish: query, error: NSError(domain: "QueryFailedDuringFinalCheck", code: 1))
                        }
                    default: try? FileManager.default.removeItem(at: f.watch.audioURL(for: value))
                    }
                } }
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(77), start.uptime + 77) }
                f.update(); try await self.drainQueuedWork(f)
                f.session.outstandingReadAction.access { $0 = nil }
                try self.check(triggered.current && task.cancellationCount.current == 0,
                    "Progress, owner withdrawal, source removal or query failure after intent persistence must prevent native cancel.")
                try self.check(try f.retryState() == retryBeforeRejectedCancellation,
                    "An unissued cancel must preserve the exact retry phase, failure count, identity and deadline.")
                let state = try JSONSerialization.jsonObject(with: Data(contentsOf: progressURL)) as! [String: Any]
                let observations = state["observations"] as! [String: [String: Any]]
                try self.check(observations.values.allSatisfy { $0["cancellationRequested"] as? Bool == false },
                    "An unissued cancel intent must not remain a persistent tombstone that prevents future recovery.")
                if mode == "source_removed" { try source.data.write(to: f.watch.audioURL(for: value)) }
                f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
                f.update(); try await self.drainQueuedWork(f)
                // The restarted bridge cannot inherit the previous process's
                // runtime query authority. Give its new idle observation a
                // genuine fresh request opportunity after ordinary startup.
                f.receiptRequestUptime.access { $0 += BackgroundReceiptRequestPolicy.interval + 1 }
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(138), start.uptime + 138) }
                f.update(); try await self.drainQueuedWork(f)
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(154), start.uptime + 154) }
                f.update(); try await self.drainQueuedWork(f)
                try self.check(task.cancellationCount.current == 1,
                    "After restart and fresh continuous evidence the unchanged source can recover; an aborted intent cannot wedge it forever.")
                try self.check(try !f.watch.hasDurableAcknowledgement(for: value)
                    && FileIdentity(f.watch.audioURL(for: value)).data == source.data,
                    "A recovered cancellation still retains the unacknowledged synthetic source.")
            }
        }

        await run("d3_superseded_exact_receipt_packet_cannot_start_recovery_grace") { f in
            let old = try f.sealHistorical(1)
            f.restartBridge(maintenanceAllowed: false, recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
            f.session.isReachable = false
            let start = f.recoveryTime.current
            let native = f.session.addLegacyTask(url: f.watch.audioURL(for: old), metadata: [
                TransportCodec.manifestKey: try TransportCodec.encode(old), "fileTransferAttemptID": UUID().uuidString])
            let stale = f.session.transferUserInfo([TransportCodec.requestSyncKey: true,
                TransportCodec.targetedReceiptRequestKey: try TransportCodec.encode(TargetedReceiptRequest(manifest: old))])
            _ = f.session.transferUserInfo([TransportCodec.requestSyncKey: true])
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
            let fresh = try f.seal(2)
            try await self.receiptOpportunity(f)
            try self.check(stale.cancellationCount.current == 1,
                "The current fresh receipt plan must first supersede the old queued exact packet.")
            try f.watch.acknowledge(f.receipt(fresh), pruneAudio: true)
            try f.watch.closePriorityCapture()
            f.recoveryTime.access { $0 = (start.date.addingTimeInterval(61), start.uptime + 61) }
            f.bridge.setMaintenanceAllowed(true); f.update(); try await self.drainQueuedWork(f)
            f.recoveryTime.access { $0 = (start.date.addingTimeInterval(77), start.uptime + 77) }
            f.update(); try await self.drainQueuedWork(f)
            try self.check(native.cancellationCount.current == 0,
                "A superseded exact request still occupying a native slot is not evidence that an ACK query remains deliverable.")
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf:
                f.watch.root.appendingPathComponent("transfer-progress-state.json"))) as! [String: Any]
            let observations = state["observations"] as! [String: [String: Any]]
            try self.check(observations.values.allSatisfy { $0["receiptRequestedUptime"] == nil },
                "Without a live queued or immediate exact request, recovery cannot persist a reply grace start.")
            try self.check(try !f.watch.hasDurableAcknowledgement(for: old),
                "Neither the fresh source's real ACK nor a cancelled request acknowledges the old source.")
        }

        await run("d3_restart_revalidates_native_cancellation_intent_before_reissuing") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let value = try f.seal(1)
            f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
            let start = f.recoveryTime.current
            let task = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                TransportCodec.manifestKey: try TransportCodec.encode(value), "fileTransferAttemptID": UUID().uuidString])
            for elapsed in [0.0, 61, 77] {
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(elapsed), start.uptime + elapsed) }
                f.update(); try await self.drainQueuedWork(f)
            }
            try self.check(task.cancellationCount.current == 1, "The first verified stalled attempt has a durable cancel intent.")
            // A process may disappear after persistence or native cancel while
            // the same task remains in the OS queue. It must not be wedged by
            // the restored tombstone, and cannot reuse stale reply authority.
            f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
            f.update(); try await self.drainQueuedWork(f)
            try self.check(task.cancellationCount.current == 1, "Restart cannot immediately replay an old cancellation certificate.")
            f.recoveryTime.access { $0 = (start.date.addingTimeInterval(91), start.uptime + 91) }
            f.update(); try await self.drainQueuedWork(f)
            try self.check(task.cancellationCount.current == 1, "A renewed exact receipt query must get its reply grace after restart.")
            f.recoveryTime.access { $0 = (start.date.addingTimeInterval(93), start.uptime + 93) }
            f.update(); try await self.drainQueuedWork(f)
            try self.check(task.cancellationCount.current == 2 && f.session.state.current.allEnqueued.isEmpty,
                "Only renewed observations, exact query grace and source verification may reissue cancel for the still-occupied attempt.")
            try self.check(FileManager.default.fileExists(atPath: f.watch.audioURL(for: value).path)
                && !FileManager.default.fileExists(atPath: f.ackURL(value).path),
                "Reissuing cancellation preserves the source and cannot manufacture its durable receipt.")
        }

        await run("d3_reused_attempt_identifier_cannot_suppress_another_manifest_callback") { f in
            let values = try (1...2).map(f.sealHistorical)
            f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
            let start = f.recoveryTime.current, sharedAttemptID = UUID().uuidString
            let tasks = try values.map { value in
                f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(value),
                    "fileTransferAttemptID": sharedAttemptID])
            }
            tasks[1].progress.completedUnitCount = tasks[1].progress.totalUnitCount
            for elapsed in [0.0, 61, 77] {
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(elapsed), start.uptime + elapsed) }
                f.update(); try await self.drainQueuedWork(f)
            }
            try self.check(tasks[0].cancellationCount.current == 1 && tasks[1].cancellationCount.current == 0,
                "The stalled cancellation identity binds its manifest as well as the native attempt string.")
            f.complete(tasks[1]); try await self.drainQueuedWork(f)
            try self.check(try f.watch.events().contains {
                $0.kind == "file_delivered_waiting_ack" && $0.detail.contains(values[1].id.uuidString)
            }, "A reused attempt string must not classify another source's real completion as the stalled source's obsolete callback.")
            for value in values {
                try self.check(try !f.watch.hasDurableAcknowledgement(for: value)
                    && FileManager.default.fileExists(atPath: f.watch.audioURL(for: value).path),
                    "Neither cancellation nor the independent completion fabricates receipts or prunes either source.")
            }
        }
    }

    func executeD3FollowupCases() async {
        for mode in ["recover", "expire"] {
            await run("stalled_full_queue_recovers_in_watchkit_background_\(mode)") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                let values = try (1...12).map(f.seal)
                try f.watch.closePriorityCapture()
                let head = values[0]
                let source = try FileIdentity(f.watch.audioURL(for: head))
                f.restartBridge(maintenanceAllowed: false, recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
                f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
                f.session.isReachable = false
                let tasks = try values.map { value in
                    f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                        TransportCodec.manifestKey: try TransportCodec.encode(value),
                        "fileTransferAttemptID": UUID().uuidString])
                }
                let start = f.recoveryTime.current
                for elapsed in [0.0, 61] {
                    f.recoveryTime.access { $0 = (start.date.addingTimeInterval(elapsed), start.uptime + elapsed) }
                    try await self.receiptOpportunity(f)
                }
                try self.check(tasks.allSatisfy { $0.cancellationCount.current == 0 },
                    "The full native queue must still wait for an exact phone receipt query and its grace.")
                try self.check(f.session.state.current.userInfo.contains {
                    (try? f.requestTarget($0.userInfo)?.matches(head)) == true
                }, "The receipt query must bind the stalled head.")

                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(77), start.uptime + 77) }
                f.bridge.resynchronize()
                try await self.drainQueuedWork(f)
                try self.check(tasks.allSatisfy { $0.cancellationCount.current == 0 },
                    "A sync request outside WatchKit execution cannot cancel an unacknowledged background task.")

                let progressURL = f.watch.root.appendingPathComponent("transfer-progress-state.json")
                if mode == "expire" {
                    let taskID = UUID()
                    let expired = Locked(false)
                    f.session.outstandingReadAction.access { $0 = { _ in
                        guard !expired.current,
                              let bytes = try? Data(contentsOf: progressURL),
                              let state = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                              let observations = state["observations"] as? [String: [String: Any]],
                              observations.values.contains(where: { $0["cancellationRequested"] as? Bool == true })
                        else { return }
                        expired.access { $0 = true }
                        f.bridge.expireBackgroundConnectivityTask(id: taskID)
                    } }
                    f.bridge.performBackgroundConnectivityTask(id: taskID) {}
                    try await self.eventually("WatchKit grant expired during final native check") { expired.current }
                    try await self.drainQueuedWork(f)
                    f.session.outstandingReadAction.access { $0 = nil }
                    try self.check(tasks.allSatisfy { $0.cancellationCount.current == 0 },
                        "Expiration after intent persistence must leave the original task alone.")
                }
                try await self.receiptOpportunity(f)
                try self.check(tasks[0].cancellationCount.current == 1
                    && tasks.dropFirst().allSatisfy { $0.cancellationCount.current == 0 },
                    "A live background grant may recover one verified stalled task, including after a revoked grant.")
                try self.check(f.session.state.current.files.count == 12 && f.session.state.current.allEnqueued.isEmpty,
                    "A cancelled native task still occupies its slot until actual removal.")
                try self.check(try FileIdentity(f.watch.audioURL(for: head)) == source
                    && !f.watch.hasDurableAcknowledgement(for: head),
                    "Recovery retains the source and cannot invent a durable phone receipt.")
                try self.check(try f.watch.events().contains {
                    $0.kind == "file_stalled_transfer_cancel_requested" && $0.detail.contains("watchKitTask=true")
                }, "A successful bounded cancel records the WatchKit execution context.")
            }
        }

        for mode in ["unchanged", "query_failed", "progress"] {
            await run("d3_bounded_query_grace_survives_foreground_handoff_\(mode)") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                let value = try f.seal(1)
                f.restartBridge(maintenanceAllowed: false, recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
                f.session.isReachable = false
                let bridgeIdentity = ObjectIdentifier(f.bridge)
                let start = f.recoveryTime.current
                let task = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(value),
                    "fileTransferAttemptID": UUID().uuidString])
                let source = try FileIdentity(f.watch.audioURL(for: value))
                try await self.receiptOpportunity(f)
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(61), start.uptime + 61) }
                try await self.receiptOpportunity(f)
                guard let query = f.session.state.current.userInfo.first(where: {
                    (try? f.requestTarget($0.userInfo)?.matches(value)) == true
                }) else { throw ProbeFailure.failed("The bounded idle observation must establish an exact native ACK query.") }
                let progressURL = f.watch.root.appendingPathComponent("transfer-progress-state.json")
                let requestedState = try JSONSerialization.jsonObject(with: Data(contentsOf: progressURL)) as! [String: Any]
                let requestedObservations = requestedState["observations"] as! [String: [String: Any]]
                guard let requestedAt = requestedObservations.values.compactMap({ $0["receiptRequestedUptime"] as? Double }).first else {
                    throw ProbeFailure.failed("The live exact bounded query must open its own persisted grace.")
                }
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(77), start.uptime + 77) }
                try await self.receiptOpportunity(f)
                let elapsedState = try JSONSerialization.jsonObject(with: Data(contentsOf: progressURL)) as! [String: Any]
                let elapsedObservations = elapsedState["observations"] as! [String: [String: Any]]
                try self.check(elapsedObservations.values.contains { $0["receiptRequestedUptime"] as? Double == requestedAt },
                    "Another bounded opportunity must retain the original exact-query grace instead of sliding it.")
                try self.check(task.cancellationCount.current == 0,
                    "Even a complete exact-query grace cannot permit unacknowledged cancellation during bounded execution.")
                if mode == "query_failed" {
                    f.session.removeFromSystemQueue(query)
                    f.bridge.session(f.session, didFinish: query, error: NSError(domain: "SyntheticBoundedHandoffQueryFailure", code: 1))
                    try await self.drainQueuedWork(f)
                } else if mode == "progress" {
                    task.progress.completedUnitCount = 20
                }
                f.bridge.setMaintenanceAllowed(true, foreground: true, liveCapture: false)
                f.update(); try await self.drainQueuedWork(f)
                try self.check(ObjectIdentifier(f.bridge) == bridgeIdentity && f.recoveryTime.current.uptime == start.uptime + 77,
                    "The handoff must reuse the same bridge and observation time without restarting or granting another grace interval.")
                try self.check(task.cancellationCount.current == (mode == "unchanged" ? 1 : 0),
                    "Foreground may immediately complete a continuously valid bounded query grace; failed query authority or resumed progress must block cancellation.")
                try self.check(f.session.state.current.files.count == 1 && f.session.state.current.allEnqueued.isEmpty,
                    "The retained native attempt still occupies its slot; neither handoff nor cancellation invents physical vacancy.")
                try self.check(try FileIdentity(f.watch.audioURL(for: value)) == source && !f.watch.hasDurableAcknowledgement(for: value),
                    "Foreground handoff and invalidation preserve the unacknowledged synthetic source and cannot invent a durable ACK.")
            }
        }

        for bounded in [false, true] {
            await run("d3_handoff_deadline_starts_after_metadata_preparation_bounded_\(bounded)") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                _ = try (1...5).map(f.seal)
                f.restartBridge(maintenanceAllowed: !bounded)
                // A catalogue/native metadata read consumes synthetic elapsed
                // time before the first source admission even begins.
                f.session.outstandingReadAction.access { $0 = { _ in f.handoffTime.access { $0 = 20 } } }
                if bounded { try await self.receiptOpportunity(f) }
                else { f.update(); try await self.drainQueuedWork(f) }
                try self.check(f.session.state.current.allEnqueued.count == 3,
                    "Metadata preparation before admission cannot consume the fresh batch's two-second handoff budget.")
                try self.check(f.session.state.current.maximumOutstanding == 3,
                    "Starting the deadline later must preserve the three-task battery bound.")
            }
        }

        for mode in ["background_error", "disappeared", "restart"] {
            await run("d3_receipt_query_authority_expires_\(mode)") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                let value = try f.seal(1)
                f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
                f.session.isReachable = false
                let start = f.recoveryTime.current
                let task = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(value), "fileTransferAttemptID": UUID().uuidString])
                for elapsed in [0.0, 61] {
                    f.recoveryTime.access { $0 = (start.date.addingTimeInterval(elapsed), start.uptime + elapsed) }
                    f.update(); try await self.drainQueuedWork(f)
                }
                guard let request = f.session.state.current.userInfo.first(where: {
                    (try? f.requestTarget($0.userInfo)?.matches(value)) == true
                }) else { throw ProbeFailure.failed("Recovery must create an exact background query before the failure.") }
                let progressURL = f.watch.root.appendingPathComponent("transfer-progress-state.json")
                let initial = try JSONSerialization.jsonObject(with: Data(contentsOf: progressURL)) as! [String: Any]
                let observations = initial["observations"] as! [String: [String: Any]]
                try self.check(observations.values.contains { $0["receiptRequestedUptime"] != nil },
                    "The invalidation scenario starts only after an actual exact query has opened the receipt grace.")
                if mode == "restart" {
                    // Native cancellation is asynchronous; a restarted owner
                    // cannot distinguish this cancelled object from a live one.
                    request.cancel()
                    f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
                } else {
                    f.session.removeFromSystemQueue(request)
                    if mode == "background_error" {
                        f.bridge.session(f.session, didFinish: request, error: NSError(domain: "SyntheticReceiptQueryFailure", code: 1))
                    }
                }
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(77), start.uptime + 77) }
                f.update(); try await self.drainQueuedWork(f)
                try self.check(task.cancellationCount.current == 0,
                    "A failed, disappeared or inherited uncertain query cannot authorize cancellation after its old grace.")
                try self.check(try !f.watch.hasDurableAcknowledgement(for: value)
                    && FileManager.default.fileExists(atPath: f.watch.audioURL(for: value).path),
                    "Losing query authority preserves the exact unacknowledged source.")
                f.session.removeFromSystemQueue(request)
                f.receiptRequestUptime.access { $0 += BackgroundReceiptRequestPolicy.interval + 1 }
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(78), start.uptime + 78) }
                f.update(); try await self.drainQueuedWork(f)
                try self.check(task.cancellationCount.current == 0,
                    "A new valid query must start a fresh grace rather than inheriting the cancelled query's deadline.")
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(94), start.uptime + 94) }
                f.update(); try await self.drainQueuedWork(f)
                try self.check(task.cancellationCount.current == 1,
                    "After a genuinely new exact query and complete grace the still-stalled source can recover.")
            }
        }

        for mode in ["pending", "error", "reply"] {
            await run("d3_immediate_receipt_query_requires_successful_reply_\(mode)") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                let value = try f.seal(1)
                f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
                _ = f.session.transferUserInfo([TransportCodec.requestSyncKey: true])
                _ = f.session.transferUserInfo([TransportCodec.requestSyncKey: true])
                let messages = Locked<[ProbeMessage]>([])
                f.session.messageAction.access { $0 = { message in messages.access { $0.append(message) } } }
                let start = f.recoveryTime.current
                let task = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(value), "fileTransferAttemptID": UUID().uuidString])
                f.update(); try await self.drainQueuedWork(f)
                f.receiptRequestUptime.access { $0 += BackgroundReceiptRequestPolicy.interval + 1 }
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(61), start.uptime + 61) }
                f.update(); try await self.drainQueuedWork(f)
                guard let query = messages.current.last else { throw ProbeFailure.failed("Expected controllable immediate exact query.") }
                try self.check(try f.requestTarget(query.payload)?.matches(value) == true,
                    "The immediate-query probe must bind the exact segment, size and digest.")
                if mode == "error" { query.fail?(NSError(domain: "SyntheticImmediateQueryFailure", code: 1)) }
                if mode == "reply" { query.reply?(["requestReceived": true]) }
                try await self.drainQueuedWork(f)
                f.update(); try await self.drainQueuedWork(f)
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(77), start.uptime + 77) }
                f.update(); try await self.drainQueuedWork(f)
                try self.check(task.cancellationCount.current == (mode == "reply" ? 1 : 0),
                    "Only a successful immediate transport reply can open an ACK query grace; sending, pending and error are insufficient.")
                try self.check(try !f.watch.hasDurableAcknowledgement(for: value)
                    && FileManager.default.fileExists(atPath: f.watch.audioURL(for: value).path),
                    "Even the successful immediate query reply is not a SegmentReceipt and cannot delete the source.")
                if mode == "error" {
                    f.receiptRequestUptime.access { $0 += BackgroundReceiptRequestPolicy.interval + 1 }
                    f.recoveryTime.access { $0 = (start.date.addingTimeInterval(78), start.uptime + 78) }
                    f.update(); try await self.drainQueuedWork(f)
                    guard let replacement = messages.current.last, replacement !== query else {
                        throw ProbeFailure.failed("Expected a new immediate query after the failed attempt cooldown.")
                    }
                    replacement.reply?(["requestReceived": true])
                    query.fail?(NSError(domain: "DelayedOldImmediateFailure", code: 1))
                    try await self.drainQueuedWork(f)
                    f.update(); try await self.drainQueuedWork(f)
                    f.recoveryTime.access { $0 = (start.date.addingTimeInterval(94), start.uptime + 94) }
                    f.update(); try await self.drainQueuedWork(f)
                    try self.check(task.cancellationCount.current == 1,
                        "A late failure of an old immediate request must not erase a newer successful exact-query proof.")
                }
            }
        }

        await run("d3_receipt_grace_starts_when_blocked_query_actually_becomes_valid") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let value = try f.seal(1)
            f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
            _ = f.session.transferUserInfo([TransportCodec.requestSyncKey: true])
            _ = f.session.transferUserInfo([TransportCodec.requestSyncKey: true])
            f.session.messageAction.access { $0 = { _ in } }
            let start = f.recoveryTime.current
            let task = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                TransportCodec.manifestKey: try TransportCodec.encode(value), "fileTransferAttemptID": UUID().uuidString])
            f.update(); try await self.drainQueuedWork(f)
            f.receiptRequestUptime.access { $0 += BackgroundReceiptRequestPolicy.interval + 1 }
            f.session.messageAction.access { $0 = { message in
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(161), start.uptime + 161) }
                message.reply?(["requestReceived": true])
            } }
            f.recoveryTime.access { $0 = (start.date.addingTimeInterval(61), start.uptime + 61) }
            f.update(); try await self.drainQueuedWork(f)
            f.recoveryTime.access { $0 = (start.date.addingTimeInterval(175), start.uptime + 175) }
            f.update(); try await self.drainQueuedWork(f)
            try self.check(task.cancellationCount.current == 0,
                "Time blocked before actual query proof cannot consume the phone's fifteen-second response grace.")
            f.recoveryTime.access { $0 = (start.date.addingTimeInterval(177), start.uptime + 177) }
            f.update(); try await self.drainQueuedWork(f)
            try self.check(task.cancellationCount.current == 1,
                "The still-stalled attempt becomes recoverable only after the full grace measured from valid proof.")
        }

        await run("d3_background_query_error_before_registration_return_remains_invalid") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let value = try f.seal(1)
            f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
            f.session.isReachable = false
            f.session.userInfoEnqueueAction.access { $0 = { query in
                guard query.userInfo[TransportCodec.requestSyncKey] as? Bool == true else { return }
                f.bridge.session(f.session, didFinish: query, error: NSError(domain: "QueryCallbackBeforeRegistrationReturns", code: 1))
            } }
            let start = f.recoveryTime.current
            let task = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                TransportCodec.manifestKey: try TransportCodec.encode(value), "fileTransferAttemptID": UUID().uuidString])
            f.update(); try await self.drainQueuedWork(f)
            f.receiptRequestUptime.access { $0 += BackgroundReceiptRequestPolicy.interval + 1 }
            for elapsed in [61.0, 77] {
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(elapsed), start.uptime + elapsed) }
                f.update(); try await self.drainQueuedWork(f)
            }
            try self.check(!f.receiptRequests.isEmpty && task.cancellationCount.current == 0,
                "An error callback before transferUserInfo returns remains terminal even while its failed object still occupies the native queue.")
            try self.check(try !f.watch.hasDurableAcknowledgement(for: value)
                && FileManager.default.fileExists(atPath: f.watch.audioURL(for: value).path),
                "An early query failure cannot create an ACK or authorize source deletion.")
        }

        for mode in ["background_error", "disappeared"] {
            await run("d3_late_immediate_success_cannot_revive_invalid_background_query_grace_\(mode)") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                let value = try f.seal(1)
                f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
                f.session.isReachable = false
                let messages = Locked<[ProbeMessage]>([])
                f.session.messageAction.access { $0 = { message in messages.access { $0.append(message) } } }
                let start = f.recoveryTime.current
                let task = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(value), "fileTransferAttemptID": UUID().uuidString])
                f.update(); try await self.drainQueuedWork(f)
                f.session.isReachable = true
                f.receiptRequestUptime.access { $0 += BackgroundReceiptRequestPolicy.interval + 1 }
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(61), start.uptime + 61) }
                f.update(); try await self.drainQueuedWork(f)
                guard let immediate = messages.current.last,
                      let background = f.session.state.current.userInfo.first(where: {
                          (try? f.requestTarget($0.userInfo)?.matches(value)) == true
                      }) else { throw ProbeFailure.failed("Expected both channels of the exact recovery query.") }
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(63), start.uptime + 63) }
                f.session.removeFromSystemQueue(background)
                // Reserve both native receipt slots before the callback's queued
                // maintenance can start a genuinely new background query.
                _ = f.session.transferUserInfo([TransportCodec.requestSyncKey: true])
                _ = f.session.transferUserInfo([TransportCodec.requestSyncKey: true])
                if mode == "background_error" {
                    f.bridge.session(f.session, didFinish: background, error: NSError(domain: "BackgroundFailedBeforeImmediateReply", code: 1))
                }
                try await self.drainQueuedWork(f)
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(80), start.uptime + 80) }
                immediate.reply?(["requestReceived": true])
                try await self.drainQueuedWork(f)
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(81), start.uptime + 81) }
                f.update(); try await self.drainQueuedWork(f)
                try self.check(task.cancellationCount.current == 0,
                    "A late successful immediate reply cannot revive a query invalidated by background failure/disappearance or reuse its old receipt grace.")
                try self.check(try !f.watch.hasDurableAcknowledgement(for: value),
                    "A successful late transport reply never becomes the source's durable ACK.")
            }
        }

        await run("d3_superseding_query_after_grace_started_revokes_cancellation_authority") { f in
            let old = try f.sealHistorical(1)
            f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
            f.session.isReachable = false
            let start = f.recoveryTime.current
            let task = f.session.addLegacyTask(url: f.watch.audioURL(for: old), metadata: [
                TransportCodec.manifestKey: try TransportCodec.encode(old), "fileTransferAttemptID": UUID().uuidString])
            for elapsed in [0.0, 61] {
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(elapsed), start.uptime + elapsed) }
                f.update(); try await self.drainQueuedWork(f)
            }
            guard let oldQuery = f.session.state.current.userInfo.first(where: {
                (try? f.requestTarget($0.userInfo)?.matches(old)) == true
            }) else { throw ProbeFailure.failed("Expected exact old query before superseding it.") }
            _ = f.session.transferUserInfo([TransportCodec.requestSyncKey: true])
            f.bridge.setMaintenanceAllowed(false)
            try await self.drainQueuedWork(f)
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
            let fresh = try f.seal(2)
            try await self.receiptOpportunity(f)
            try self.check(oldQuery.cancellationCount.current == 1,
                "A new FIFO head must genuinely supersede the old exact query after its grace has already started.")
            try f.watch.acknowledge(f.receipt(fresh), pruneAudio: true)
            try f.watch.closePriorityCapture()
            f.bridge.setMaintenanceAllowed(true)
            f.recoveryTime.access { $0 = (start.date.addingTimeInterval(77), start.uptime + 77) }
            f.update(); try await self.drainQueuedWork(f)
            try self.check(task.cancellationCount.current == 0,
                "Persisted grace cannot authorize native cancellation after its exact query was superseded in the same process.")
            try self.check(try !f.watch.hasDurableAcknowledgement(for: old)
                && FileManager.default.fileExists(atPath: f.watch.audioURL(for: old).path),
                "The new head's ACK cannot stand in for the old source's missing receipt.")
        }

        await run("d3_cancel_before_retry_commit_crash_cutoff_preserves_disappearance_grace") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let value = try f.seal(1), attemptID = UUID().uuidString
            let enqueuedAt = Date().addingTimeInterval(-1_000)
            var retry = FileTransferRetryPolicy()
            retry.noteEnqueued(value, attemptID: attemptID, at: enqueuedAt)
            try TransportCodec.encode(retry).write(to: f.retryURL)
            f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
            let start = f.recoveryTime.current
            let task = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                TransportCodec.manifestKey: try TransportCodec.encode(value), "fileTransferAttemptID": attemptID,
                "diagnosticEnqueuedAt": enqueuedAt.timeIntervalSince1970])
            for elapsed in [0.0, 61] {
                f.recoveryTime.access { $0 = (start.date.addingTimeInterval(elapsed), start.uptime + elapsed) }
                f.update(); try await self.drainQueuedWork(f)
            }
            let beforeCancel = try Data(contentsOf: f.retryURL)
            let atNativeCancel = Locked<Data?>(nil)
            task.cancellationAction.access { $0 = { atNativeCancel.access { $0 = try? Data(contentsOf: f.retryURL) } } }
            f.recoveryTime.access { $0 = (start.date.addingTimeInterval(77), start.uptime + 77) }
            f.update(); try await self.drainQueuedWork(f)
            try self.check(task.cancellationCount.current == 1 && atNativeCancel.current == beforeCancel,
                "The actual native cancel must happen before any retry failure transaction is persisted.")
            // Restore the exact bytes observed at native cancel to emulate a
            // process ending at that write boundary, using synthetic metadata.
            try beforeCancel.write(to: f.retryURL)
            f.session.removeFromSystemQueue(task)
            let restoredAt = Date()
            f.restartBridge(recoveryIdleInterval: 60, recoveryReceiptGrace: 15)
            f.update(); try await self.drainQueuedWork(f)
            let attempt = try f.retryAttempt(value)
            try self.check(attempt["phase"] as? String == "enqueued" && attempt["failures"] as? Int == 0,
                "The pre-commit crash cutoff cannot invent a failed retry phase or failure count on restart.")
            var restoredRetry = try f.retryState()
            let deadline = try XCTUnwrapProbe(restoredRetry.nextRetryDate(pending: [value]))
            try self.check(f.session.state.current.allEnqueued.isEmpty
                && deadline.timeIntervalSince(restoredAt) >= FileTransferRetryPolicy.disappearanceGrace - 1,
                "A vanished native task after the crash still gets the ordinary persisted disappearance grace before replacement.")
            try self.check(try !f.watch.hasDurableAcknowledgement(for: value)
                && FileManager.default.fileExists(atPath: f.watch.audioURL(for: value).path),
                "The crash cutoff preserves the unacknowledged source without overlap or a fabricated receipt.")
        }

        for mode in ["success", "error"] {
            await run("d3_corrupt_optional_progress_state_preserves_file_completion_\(mode)") { f in
                let value = try f.sealHistorical(1), attemptID = UUID().uuidString
                let start = Date()
                var retry = FileTransferRetryPolicy()
                retry.recordDelivery(of: value, attemptID: attemptID, at: start.addingTimeInterval(-10))
                retry.recordDelivery(of: value, attemptID: attemptID, at: start)
                try TransportCodec.encode(retry).write(to: f.retryURL)
                let corrupt = Data("preserve-corrupt-optional-progress-ledger".utf8)
                let progressURL = f.watch.root.appendingPathComponent("transfer-progress-state.json")
                try corrupt.write(to: progressURL)
                f.restartBridge(maintenanceAllowed: false)
                let task = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(value), "fileTransferAttemptID": attemptID])
                f.complete(task, error: mode == "error" ? NSError(domain: "UnclassifiedNativeCompletion", code: 1) : nil)
                try await self.drainQueuedWork(f)
                let attempt = try f.retryAttempt(value)
                try self.check(attempt["phase"] as? String == "waitingForAcknowledgement"
                    && attempt["deliveries"] as? Int == (mode == "success" ? 3 : 2)
                    && attempt["failures"] as? Int == 0 && attempt["attemptID"] as? String == attemptID,
                    "A corrupt optional progress ledger cannot swallow success, invent a delivery for errors, or reset the exact retry attempt.")
                var completedRetry = try f.retryState()
                let deadline = try XCTUnwrapProbe(completedRetry.nextRetryDate(pending: [value]))
                try self.check(deadline.timeIntervalSince(start) >= (mode == "success" ? 1_199 : 599),
                    "Success advances the existing exponential ACK wait; unclassified errors retain the longer existing ACK window.")
                try self.check(try Data(contentsOf: progressURL) == corrupt,
                    "Completion processing preserves the unreadable optional state byte for byte.")
                try self.check(try !f.watch.hasDurableAcknowledgement(for: value)
                    && FileManager.default.fileExists(atPath: f.watch.audioURL(for: value).path),
                    "Neither completion path fabricates an ACK or removes the source.")
            }
        }
    }

    func executeW2PCases() async {
        await run("w2p_diagnostic_recent_packet_not_starved_by_legacy_replay") { f in
            for _ in 0..<65 { try f.watch.appendEvent(RecordingEvent(kind: "audio_started", detail: "synthetic")) }
            let legacy = RecordingEvent(kind: "audio_started", detail: "synthetic queued")
            let packet = WCSessionUserInfoTransfer([TransportCodec.eventsKey: try TransportCodec.encode([legacy])])
            try self.check(WatchDiagnosticTransferPolicy.mayTransfer(legacy), "The historical packet is eligible under the production privacy policy.")
            let source = try f.seal(1)
            let receipt = WCSessionUserInfoTransfer([TransportCodec.requestSyncKey: true,
                TransportCodec.targetedReceiptRequestKey: try TransportCodec.encode(TargetedReceiptRequest(manifest: source))])
            f.session.state.access { $0.userInfo = [packet, receipt] }
            f.update()
            try await self.eventually("native audio admitted before optional diagnostic assertions") { f.session.state.current.files.count == 1 }
            try await self.drainQueuedWork(f)
            f.session.state.access { $0.userInfo.removeAll { $0 === packet } }
            f.bridge.session(f.session, didFinish: packet, error: nil)
            try await self.drainQueuedWork(f)
            let packets = f.session.state.current.userInfo
            let typed = packets.filter { transfer in
                let events = WatchDiagnosticTransferPolicy.transferableBatch(from: transfer.userInfo[TransportCodec.eventsKey] as? Data) ?? []
                return !events.isEmpty && events.allSatisfy { WatchTransferDiagnostic.parse($0) != nil }
            }
            try self.check(typed.count == 1, "A completed historical packet must give current diagnostics a turn before the remaining legacy journal.")
            try self.check(packets.count == 2 && packets.contains { $0 === receipt },
                "Only one optional event slot is occupied, leaving receipt replacement room without removing the existing request.")
            try self.check(packet.cancellationCount.current == 0 && receipt.cancellationCount.current == 0,
                "Diagnostic fairness never cancels legacy or receipt requests.")
            try self.check(f.session.state.current.files.count == 1 && (try !f.watch.hasDurableAcknowledgement(for: source)),
                "Diagnostic traffic neither blocks native audio admission nor fabricates an ACK.")
            var legacyResumed = false
            for _ in 0..<12 {
                guard let next = f.session.state.current.userInfo.first(where: { $0.userInfo[TransportCodec.eventsKey] != nil }) else { break }
                let events = WatchDiagnosticTransferPolicy.transferableBatch(from: next.userInfo[TransportCodec.eventsKey] as? Data) ?? []
                if events.contains(where: { WatchTransferDiagnostic.parse($0) == nil }) { legacyResumed = true; break }
                try self.check(f.session.state.current.userInfo.count <= 2,
                    "Typed replay keeps the unused slot available for receipt replacement.")
                f.session.state.access { $0.userInfo.removeAll { $0 === next } }
                f.bridge.session(f.session, didFinish: next, error: nil)
                try await self.drainQueuedWork(f)
            }
            if !legacyResumed {
                _ = try f.seal(2)
                f.update()
                try await self.eventually("second real source admitted") { f.session.state.current.files.count == 2 }
                try await self.drainQueuedWork(f)
                legacyResumed = f.session.state.current.userInfo.contains { packet in
                    let events = WatchDiagnosticTransferPolicy.transferableBatch(from: packet.userInfo[TransportCodec.eventsKey] as? Data) ?? []
                    return events.contains { WatchTransferDiagnostic.parse($0) == nil }
                }
            }
            try self.check(legacyResumed, "The next ordinary opportunity resumes lifecycle replay even when it also creates new transfer diagnostics.")
        }
        await run("w2p_diagnostic_long_stasis_and_restart_replay_are_bounded") { f in
            _ = try (1...3).map(f.seal)
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: true)
            f.update()
            try await self.eventually("initial native queue reaches three") { f.session.state.current.files.count == 3 }
            try await self.drainQueuedWork(f)
            f.recoveryTime.access { $0.date.addTimeInterval(60) }
            f.update(observedAt: f.recoveryTime.current.date)
            try await self.drainQueuedWork(f)
            let journal = f.watch.root.appendingPathComponent("events")
            let initialJournal = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
            let initialIdentity = try Dictionary(uniqueKeysWithValues: initialJournal.map { ($0.lastPathComponent, try FileIdentity($0)) })
            let initialProgress = f.transferEvents().compactMap(WatchTransferDiagnostic.parse).compactMap(\.attempt).filter { $0.phase == .progress }
            for _ in 0..<360 {
                f.recoveryTime.access { $0.date.addTimeInterval(10) }
                f.update(observedAt: f.recoveryTime.current.date)
                try await self.drainQueuedWork(f)
            }
            let values = f.transferEvents().compactMap(WatchTransferDiagnostic.parse)
            let refusals = values.compactMap(\.refusal)
            try self.check(refusals.count <= 4 && (refusals.map { $0.observationCount ?? 1 }.max() ?? 0) >= 350,
                "An hour of unchanged rounds retains cumulative waiting states, not one journal file per observation.")
            let progress = values.compactMap(\.attempt).filter { $0.phase == .progress }
            try self.check(progress == initialProgress, "Unchanged native progress cannot manufacture periodic revisions.")
            try self.check(f.transferDiagnostics.statistics.eventCount <= 12 && f.transferDiagnostics.statistics.writeCount <= 70,
                "Repeated waiting observations have bounded rows and at most one aggregate write per minute after initial facts.")
            try self.check(f.transferDiagnostics.statistics.persistedBytes <= WatchTransferDiagnosticStore.maximumBytes,
                "The replacement snapshot has a hard encoded byte ceiling.")
            let finalJournal = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
            try self.check(Set(finalJournal.map(\.lastPathComponent)) == Set(initialIdentity.keys)
                && finalJournal.allSatisfy { (try? FileIdentity($0)) == initialIdentity[$0.lastPathComponent] },
                "Typed diagnostics add no permanent journal files and preserve every existing lifecycle event byte/inode/mtime.")
            try self.check(f.session.state.current.files.count == 3 && f.session.state.current.allEnqueued.count == 3
                && f.session.state.current.files.allSatisfy { $0.cancellationCount.current == 0 },
                "Diagnostic aggregation cannot cancel or re-enqueue unchanged native ownership.")
            f.session.state.access { $0.userInfo.removeAll() }
            f.restartBridge(maintenanceAllowed: false)
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: true)
            f.update(observedAt: f.recoveryTime.current.date)
            try await self.drainQueuedWork(f)
            let reads = f.transferDiagnostics.statistics.readCount
            var batches = 0, replayIDs = Set<UUID>()
            for _ in 0..<12 {
                let packets = f.session.state.current.userInfo.filter { $0.userInfo[TransportCodec.eventsKey] != nil }
                if packets.isEmpty { break }
                for packet in packets {
                    let events = WatchDiagnosticTransferPolicy.transferableBatch(from: packet.userInfo[TransportCodec.eventsKey] as? Data) ?? []
                    replayIDs.formUnion(events.map(\.id)); batches += 1
                    f.session.state.access { $0.userInfo.removeAll { $0 === packet } }
                    f.bridge.session(f.session, didFinish: packet, error: nil)
                }
                try await self.drainQueuedWork(f)
            }
            try self.check(reads == 1 && f.transferDiagnostics.statistics.readCount == reads && batches > 0 && batches <= 9,
                "Restart loads one bounded snapshot; native completions replay in-memory batches without rereading history.")
            try self.check(replayIDs.count <= WatchTransferDiagnosticStore.maximumEvents
                && f.session.state.current.userInfo.allSatisfy { $0.userInfo[TransportCodec.eventsKey] == nil },
                "Diagnostic replay drains and cannot create its own successor observations.")
            let delivered = Mirror(reflecting: f.bridge).children.first { $0.label == "deliveredTransferDiagnosticIDs" }!.value as! Set<UUID>
            try self.check(delivered.count <= f.transferDiagnostics.statistics.eventCount,
                "Delivered diagnostic revisions do not accumulate beyond retained evidence.")
        }

        await run("w2p_typed_diagnostic_completion_does_not_scan_legacy_journal") { f in
            let oldTyped = RecordingEvent(kind: "watch.transfer_refusal", detail: WatchTransferRefusalDiagnostic(
                reason: .nativeOccupied, observedAtMS: 1_700_000_000_000, generation: 0,
                foreground: false, liveCapture: false, nativeCount: 3).detail()!)
            let lifecycle = RecordingEvent(kind: "user_paused", detail: "paused")
            try f.watch.appendEvent(oldTyped); try f.watch.appendEvent(lifecycle)
            let oldURL = f.watch.root.appendingPathComponent("events").appendingPathComponent(oldTyped.id.uuidString.lowercased() + ".json")
            let oldIdentity = try FileIdentity(oldURL)
            _ = try f.seal(1); f.update()
            try await self.eventually("native source enqueued") { f.session.state.current.files.count == 1 }
            try await self.drainQueuedWork(f)
            // Drain the ordinary legacy event packet, allowing the typed snapshot
            // to be selected by the independent bounded forwarding path.
            var typed: WCSessionUserInfoTransfer?
            var deliveredLifecycle = false
            for _ in 0..<10 {
                guard let packet = f.session.state.current.userInfo.first(where: { $0.userInfo[TransportCodec.eventsKey] != nil }) else { break }
                let events = WatchDiagnosticTransferPolicy.transferableBatch(from: packet.userInfo[TransportCodec.eventsKey] as? Data) ?? []
                try self.check(!events.contains { $0.id == oldTyped.id }, "Old typed journal rows remain local instead of re-entering the bounded snapshot replay.")
                deliveredLifecycle = deliveredLifecycle || events.contains { $0.id == lifecycle.id }
                if !events.isEmpty && events.allSatisfy({ WatchTransferDiagnostic.parse($0) != nil }) { typed = packet; break }
                f.session.state.access { $0.userInfo.removeAll { $0 === packet } }
                f.bridge.session(f.session, didFinish: packet, error: nil)
                try await self.drainQueuedWork(f)
            }
            guard let typed else { throw ProbeFailure.failed("Typed diagnostic snapshot packet missing") }
            try self.check((try FileIdentity(oldURL)) == oldIdentity
                && FileManager.default.fileExists(atPath: f.watch.root.appendingPathComponent("events").appendingPathComponent(lifecycle.id.uuidString.lowercased() + ".json").path),
                "Prior typed and lifecycle journal evidence stays intact when current diagnostics receive the first free event slot.")
            let events = f.watch.root.appendingPathComponent("events"), saved = f.watch.root.appendingPathComponent("saved-events")
            try FileManager.default.moveItem(at: events, to: saved)
            try Data("synthetic inaccessible history".utf8).write(to: events)
            defer { try? FileManager.default.removeItem(at: events); try? FileManager.default.moveItem(at: saved, to: events) }
            let issueCount = f.issues.current.count
            f.session.state.access { $0.userInfo.removeAll { $0 === typed } }
            f.bridge.session(f.session, didFinish: typed, error: nil)
            try await self.drainQueuedWork(f)
            try self.check(f.issues.current.count == issueCount,
                "Completing only typed diagnostics cannot enumerate an unavailable legacy journal or raise a journal failure.")
            try self.check(f.session.state.current.files.count == 1 && f.session.state.current.files[0].cancellationCount.current == 0,
                "Independent diagnostic replay preserves the native file and its ACK wait.")
        }

        await run("w2p_diagnostic_snapshot_failure_does_not_block_native_handoff") { f in
            let manifest = try f.seal(1)
            let path = f.watch.root.appendingPathComponent("ConnectivityDiagnostics/watch-transfer-v1.json")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let sentinel = path.appendingPathComponent("preserve-evidence")
            try Data("synthetic obstruction".utf8).write(to: sentinel)
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.update()
            try await self.eventually("snapshot fault preserves native handoff") { f.session.state.current.files.count == 1 }
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.files[0].manifest == manifest && !f.watch.hasDurableAcknowledgement(for: manifest),
                "Snapshot persistence failure cannot prevent native enqueue or manufacture receipt authority.")
            try self.check(try Data(contentsOf: sentinel) == Data("synthetic obstruction".utf8),
                "An unsafe diagnostic target is preserved rather than overwritten.")
        }

        await run("w2p_background_edge_recovers_interrupted_foreground_handoff") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            _ = try (1...21).map(f.seal)
            try f.watch.closePriorityCapture()
            f.bridge.foregroundDidChange(true)
            try await self.drainQueuedWork(f)
            let interrupted = Locked(false)
            f.capacityReadAction.access { $0 = {
                let first = interrupted.access { value -> Bool in
                    guard !value else { return false }; value = true; return true
                }
                guard first else { return }
                f.bridge.foregroundDidChange(false)
                f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
                f.bridge.enteredBackground()
            } }
            defer { f.capacityReadAction.access { $0 = nil } }
            f.update()
            try await self.eventually("background edge refills without a timer, phone request or another native callback") {
                f.session.state.current.files.count == 12
            }
            try self.check(interrupted.current && f.session.state.current.allEnqueued.count == 12,
                "A foreground handoff interrupted at its first admission resumes once within the bounded native limit.")
            try self.check(try f.watch.pendingSegments().count == 21,
                "Enqueue is not acknowledgement and preserves every synthetic source.")
        }

        await run("w2p_pause_dark_sixty_refills_from_real_callbacks") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let sources = try (1...60).map(f.seal)
            try f.watch.closePriorityCapture()
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.bridge.update(RecorderSnapshot(state: .paused, sessionID: f.recordingSession.id,
                lastSealedAt: sources.last!.endedAt))
            try await self.eventually("pause hands twelve sealed sources to native queue") { f.session.state.current.files.count == 12 }
            try self.check(f.session.state.current.files.allSatisfy { $0.cancellationCount.current == 0 }, "Pause cannot cancel existing file transfers.")
            var observed = Dictionary(uniqueKeysWithValues: f.transferEvents().map { ($0.id, $0) })
            for _ in 0..<60 {
                try await self.eventually("a real completion has another queued source") { !f.session.state.current.files.isEmpty }
                let task = f.session.state.current.files[0]
                let manifest = task.manifest!
                let receipt = try f.receipt(manifest)
                f.complete(task)
                try f.deliver(receipt)
                try await self.drainQueuedWork(f)
                for event in f.transferEvents() { observed[event.id] = event }
            }
            try await self.eventually("all sixty receive durable exact ACKs") { try f.watch.pendingSegments().isEmpty }
            try self.check(f.session.state.current.allEnqueued.count == 60, "Every sealed source is handed off once with only real WC callback opportunities.")
            try self.check(f.session.state.current.maximumOutstanding == 12, "Native count stays bounded even while callback opportunities refill.")
            let diagnostics = observed.values.compactMap(WatchTransferDiagnostic.parse)
            try self.check(f.transferEvents().count <= WatchTransferDiagnosticStore.maximumEvents, "Real throughput also obeys bounded diagnostic retention.")
            try self.check(diagnostics.compactMap(\.attempt).filter { $0.phase == .enqueue }.count == 60,
                "Every native enqueue has per-attempt metadata without requiring Watch foreground.")
            try self.check(diagnostics.compactMap(\.attempt).allSatisfy { $0.sourceCategory == .normal && $0.foreground == false && $0.liveCapture == false },
                "Provenance and actual maintenance context remain explicit during a dark paused backlog.")
        }

        await run("w2p_diagnostic_failure_during_sealed_handoff_preserves_admission") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let sources = try (1...12).map(f.seal)
            try f.watch.closePriorityCapture()
            let event = RecordingEvent(kind: "watch.transfer_refusal", detail: WatchTransferRefusalDiagnostic(
                reason: .nativeOccupied, observedAtMS: 1_700_000_000_000, generation: 0,
                foreground: false, liveCapture: false, nativeCount: 12).detail()!)
            let packet = WCSessionUserInfoTransfer([TransportCodec.eventsKey: try TransportCodec.encode([event])])
            f.session.state.access { $0.userInfo.append(packet) }
            let fired = Locked(false)
            f.capacityReadAction.access { $0 = {
                let first = fired.access { value -> Bool in guard !value else { return false }; value = true; return true }
                guard first else { return }
                f.session.removeFromSystemQueue(packet)
                f.bridge.session(f.session, didFinish: packet, error: NSError(domain: "SyntheticDiagnosticFailure", code: 1))
            } }
            defer { f.capacityReadAction.access { $0 = nil } }
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.bridge.update(RecorderSnapshot(state: .paused, sessionID: f.recordingSession.id,
                lastSealedAt: sources.last!.endedAt))
            try await self.eventually("diagnostic failure still permits the sealed twelve-file handoff") {
                f.session.state.current.files.count == 12
            }
            try await self.drainQueuedWork(f)
            try self.check(fired.current && f.session.state.current.allEnqueued.count == 12,
                "A failed optional event packet cannot revoke an existing callback's admission or require another wake.")
            try self.check(f.session.state.current.files.allSatisfy { $0.cancellationCount.current == 0 },
                "Diagnostic channel failure cannot cancel or duplicate native audio ownership.")
            for source in sources { try self.check(try !f.watch.hasDurableAcknowledgement(for: source),
                "Diagnostic channel failure cannot manufacture durable acknowledgement.") }
        }

        await run("w2p_eleven_owned_tasks_survive_twelve_to_three_shrink") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            _ = try (1...20).map(f.seal)
            f.charging.access { $0 = true }; f.update()
            try await self.eventually("charging queue reaches twelve") { f.session.state.current.files.count == 12 }
            let first = f.session.state.current.files[0], firstReceipt = try f.receipt(first.manifest!)
            f.charging.access { $0 = false }
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: true)
            f.complete(first); try f.deliver(firstReceipt)
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.files.count == 11 && f.session.state.current.files.allSatisfy { $0.cancellationCount.current == 0 },
                "The eleven native tasks survive a battery cap shrink untouched.")
            let report = try f.backgroundSyncReport(), admission = report["admission"] as? [String: Any]
            try self.check(admission?["reason"] as? String == "native_occupied", "Owned tasks outside the smaller lookahead must not become foreign.")
            for _ in 0..<9 {
                let task = f.session.state.current.files[0], receipt = try f.receipt(task.manifest!)
                f.complete(task); try f.deliver(receipt); try await self.drainQueuedWork(f)
            }
            try await self.eventually("battery queue refills as soon as actual occupancy permits") { f.session.state.current.files.count == 3 }
            try self.check(f.session.state.current.allEnqueued.count == 13, "The first released battery slot refills without cancelling remaining tasks.")
        }

        await run("w2p_expired_wk_then_real_wc_receive_hands_off_without_foreground") { f in
            _ = try f.sealHistorical(1)
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.session.activationState = .notActivated
            let oldID = UUID(), oldDone = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: oldID) { oldDone.access { $0 += 1 } }
            try await self.drainQueuedWork(f)
            f.bridge.expireBackgroundConnectivityTask(id: oldID)
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.allEnqueued.isEmpty, "Expired WK permission cannot enqueue.")
            f.session.activationState = .activated
            f.bridge.session(f.session, didReceiveUserInfo: [TransportCodec.requestSyncKey: true])
            try await self.eventually("new real WC callback owns a fresh bounded generation") { f.session.state.current.allEnqueued.count == 1 }
            try self.check(oldDone.current == 0, "An old expired task is never completed again or lent new runtime.")
            let events = f.transferEvents().compactMap(WatchTransferDiagnostic.parse)
            let expiry = events.compactMap(\.opportunity).first { $0.phase == .expired }
            let enqueue = events.compactMap(\.attempt).first { $0.phase == .enqueue }
            try self.check(expiry != nil && (enqueue?.generation ?? 0) > expiry!.generation, "Diagnostics distinguish old expiry from new admission generation.")
            try self.check(expiry?.processRunID == ProbeRuntimeDiagnostics.shared.processRunID && enqueue?.processRunID == expiry?.processRunID,
                "WK expiry and its later admission retain explicit same-process generation scope.")
        }

        await run("w2p_stale_pause_snapshot_and_duplicate_expiry_do_not_revoke_new_wc_generation") { f in
            _ = try f.sealHistorical(1)
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.session.activationState = .notActivated
            let paused = RecorderSnapshot(state: .paused, sessionID: f.recordingSession.id)
            f.bridge.update(paused); try await self.drainQueuedWork(f)
            let oldID = UUID()
            f.bridge.performBackgroundConnectivityTask(id: oldID) {}
            try await self.drainQueuedWork(f)
            f.bridge.expireBackgroundConnectivityTask(id: oldID)
            try await self.drainQueuedWork(f)
            f.bridge.update(paused)
            try await self.drainQueuedWork(f)
            f.session.activationState = .activated
            f.bridge.resynchronize(); try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.allEnqueued.isEmpty, "A repeated stale pause observation cannot reopen expired execution.")
            // Hold cleanup so a duplicate expiration of the old task can race
            // with a synchronously registered new WC callback generation.
            f.session.activationState = .notActivated
            let secondID = UUID()
            f.bridge.performBackgroundConnectivityTask(id: secondID) {}
            try await self.drainQueuedWork(f)
            let entered = Locked(false), gate = DispatchSemaphore(value: 0)
            let queue = Mirror(reflecting: f.bridge).children.first { $0.label == "work" }!.value as! DispatchQueue
            queue.async { entered.access { $0 = true }; _ = gate.wait(timeout: .now() + 10) }
            try await self.eventually("worker holds old expiration cleanup") { entered.current }
            f.bridge.expireBackgroundConnectivityTask(id: secondID)
            f.session.activationState = .activated
            f.bridge.session(f.session, didReceiveUserInfo: [TransportCodec.requestSyncKey: true])
            f.bridge.expireBackgroundConnectivityTask(id: secondID)
            gate.signal()
            try await self.eventually("duplicate old expiry cannot fence the real new callback") { f.session.state.current.allEnqueued.count == 1 }
        }

        await run("w2p_queued_pause_before_wk_expiry_cannot_revive_expired_runtime") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let source = try f.seal(1); try f.watch.closePriorityCapture()
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.session.activationState = .notActivated
            let taskID = UUID()
            f.bridge.performBackgroundConnectivityTask(id: taskID) {}
            try await self.drainQueuedWork(f)
            let entered = Locked(false), gate = DispatchSemaphore(value: 0)
            let queue = Mirror(reflecting: f.bridge).children.first { $0.label == "work" }!.value as! DispatchQueue
            queue.async { entered.access { $0 = true }; _ = gate.wait(timeout: .now() + 10) }
            try await self.eventually("worker blocks queued final-seal signal") { entered.current }
            f.bridge.update(RecorderSnapshot(state: .paused, sessionID: f.recordingSession.id, lastSealedAt: source.endedAt))
            f.bridge.expireBackgroundConnectivityTask(id: taskID)
            f.session.activationState = .activated
            gate.signal(); try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.allEnqueued.isEmpty, "A writer signal queued before expiry cannot grant new runtime after expiry.")
            let done = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("real new WK grant can hand off the sealed source") { done.current == 1 && f.session.state.current.files.count == 1 }
        }

        await run("w2p_genuine_new_pause_callback_after_expiry_hands_off_sealed_tail") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.session.activationState = .notActivated
            let taskID = UUID()
            f.bridge.performBackgroundConnectivityTask(id: taskID) {}
            try await self.drainQueuedWork(f)
            f.bridge.expireBackgroundConnectivityTask(id: taskID)
            try await self.drainQueuedWork(f)
            let tail = try f.seal(1); try f.watch.closePriorityCapture()
            f.session.activationState = .activated
            f.bridge.update(RecorderSnapshot(state: .paused, sessionID: f.recordingSession.id, lastSealedAt: tail.endedAt))
            try await self.eventually("genuine post-expiry final seal uses its own callback") { f.session.state.current.files.count == 1 }
            try self.check(f.session.state.current.files[0].manifest == tail, "Only the genuinely new sealed tail signal receives new bounded admission.")
        }

        await run("w2p_diagnostic_completions_cannot_create_endless_successors") { f in
            _ = try f.seal(1)
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.update()
            try await self.eventually("bounded native task and diagnostics") {
                f.session.state.current.files.count == 1 && f.session.state.current.userInfo.contains { $0.userInfo[TransportCodec.eventsKey] != nil }
            }
            let before = f.transferEvents().filter { $0.kind.hasPrefix("watch.transfer_") }.count
            for _ in 0..<20 {
                let events = f.session.state.current.userInfo.filter { $0.userInfo[TransportCodec.eventsKey] != nil }
                if events.isEmpty { break }
                for event in events {
                    f.session.state.access { $0.userInfo.removeAll { $0 === event } }
                    f.bridge.session(f.session, didFinish: event, error: nil)
                }
                try await self.drainQueuedWork(f)
            }
            try self.check(f.session.state.current.userInfo.allSatisfy { $0.userInfo[TransportCodec.eventsKey] == nil },
                "Pure diagnostic completion must drain, not manufacture another event packet.")
            try self.check(f.transferEvents().filter { $0.kind.hasPrefix("watch.transfer_") }.count == before,
                "Diagnostic transport callbacks cannot create diagnostic successors.")
            try self.check(f.session.state.current.files.count == 1, "The native audio task remains system-owned while diagnostic packets drain.")
        }

        await run("w2p_real_enqueue_during_diagnostic_callback_keeps_attempt_evidence") { f in
            _ = try (1...5).map(f.seal)
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.update()
            try await self.eventually("initial bounded batch") { f.session.state.current.files.count == 3 }
            try await self.drainQueuedWork(f)
            let freed = f.session.state.current.files[0]
            f.session.state.access { $0.files.removeAll { $0 === freed } }
            guard let event = f.session.state.current.userInfo.first(where: { $0.userInfo[TransportCodec.eventsKey] != nil }) else { throw ProbeFailure.failed("Initial diagnostics missing") }
            f.session.state.access { $0.userInfo.removeAll { $0 === event } }
            f.bridge.session(f.session, didFinish: event, error: nil)
            try await self.eventually("event callback refills genuinely free native slot") { f.session.state.current.allEnqueued.count == 4 }
            try await self.drainQueuedWork(f)
            let attempts = f.transferEvents().compactMap(WatchTransferDiagnostic.parse).compactMap(\.attempt).filter { $0.phase == .enqueue }
            try self.check(attempts.count == 4, "Suppressing diagnostic echoes must preserve every real enqueue's attempt record.")
            try self.check(attempts.allSatisfy { $0.processRunID == ProbeRuntimeDiagnostics.shared.processRunID },
                "All attempt generations are scoped to the same actual Watch process.")
        }

        await run("w2p_diagnostic_journal_failure_does_not_block_native_handoff") { f in
            let manifest = try f.seal(1)
            let events = f.watch.root.appendingPathComponent("events"), saved = f.watch.root.appendingPathComponent("saved-events")
            try FileManager.default.moveItem(at: events, to: saved)
            try Data("synthetic obstruction".utf8).write(to: events)
            defer { try? FileManager.default.removeItem(at: events); try? FileManager.default.moveItem(at: saved, to: events) }
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.update()
            try await self.eventually("journal fault preserves native file handoff") { f.session.state.current.files.count == 1 }
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.files[0].manifest == manifest && !f.watch.hasDurableAcknowledgement(for: manifest),
                "Diagnostic I/O cannot change native source identity or manufacture a receipt.")
            let forwarded = f.session.state.current.userInfo.flatMap { transfer in
                WatchDiagnosticTransferPolicy.transferableBatch(from: transfer.userInfo[TransportCodec.eventsKey] as? Data) ?? []
            }
            try self.check(forwarded.contains { WatchTransferDiagnostic.parse($0)?.attempt?.phase == .enqueue },
                "A failed local diagnostic journal may still forward safe metadata during the real opportunity.")
        }

        await run("w2p_progress_late_callback_and_safe_forwarded_attempts") { f in
            let manifest = try f.seal(1); f.update()
            try await self.eventually("source enqueued") { f.session.state.current.files.count == 1 }
            let task = f.session.state.current.files[0]
            task.progress.completedUnitCount = 42
            f.recoveryTime.access { $0.date = Date().addingTimeInterval(60) }
            f.bridge.resynchronize(); try await self.drainQueuedWork(f)
            let receipt = try f.receipt(manifest)
            try f.deliver(receipt); try await self.drainQueuedWork(f)
            f.complete(task, error: NSError(domain: "/private/forbidden-transcript", code: 7))
            try await self.drainQueuedWork(f)
            let diagnostics = f.transferEvents().compactMap(WatchTransferDiagnostic.parse).compactMap(\.attempt)
            try self.check(diagnostics.contains { $0.phase == .progress && $0.completed == 42 }, "Actual native progress must be captured for the same attempt.")
            try self.check(diagnostics.contains { $0.phase == .completion && $0.outcome == .failed && $0.observedAtMS >= $0.enqueuedAtMS! }, "A late callback records its time and fixed outcome even after durable ACK.")
            try self.check(try f.watch.hasDurableAcknowledgement(for: manifest), "Late transport failure cannot undo durable receipt or revive a source.")
            var forwarded: [RecordingEvent] = []
            for _ in 0..<20 {
                guard let packet = f.session.state.current.userInfo.first(where: { $0.userInfo[TransportCodec.eventsKey] != nil }) else { break }
                forwarded += WatchDiagnosticTransferPolicy.transferableBatch(from: packet.userInfo[TransportCodec.eventsKey] as? Data) ?? []
                f.session.state.access { $0.userInfo.removeAll { $0 === packet } }
                f.bridge.session(f.session, didFinish: packet, error: nil)
                try await self.drainQueuedWork(f)
            }
            try self.check(forwarded.contains { $0.kind == "watch.transfer_attempt" }, "Attempt metadata uses the existing allowlisted diagnostic transport.")
            try self.check(forwarded.allSatisfy { !$0.detail.contains("forbidden-transcript") }, "Native free-text failures never enter forwarded diagnostics.")
        }
    }

    func execute() async {
        await run("runtime_observation_bypasses_event_queue_without_recorder_authority") { f in
            let oldEvent = RecordingEvent(kind: "file_transfer_enqueued", detail: "historical")
            let eventPacket = WCSessionUserInfoTransfer([TransportCodec.eventsKey: try TransportCodec.encode([oldEvent])])
            let opaque1 = WCSessionUserInfoTransfer(["opaque": 1])
            let opaque2 = WCSessionUserInfoTransfer(["opaque": 2])
            f.session.state.access { $0.userInfo = [eventPacket, opaque1, opaque2] }
            f.bridge.setMaintenanceAllowed(false)
            f.bridge.resynchronize()
            try await self.settle(f)
            let context = f.session.state.current.contexts.last ?? [:]
            let bytes = context[TransportCodec.watchRuntimeKey] as? Data
            let runtime = bytes.flatMap(WatchRuntimeObservation.decode)
            try self.check(runtime != nil, "A real bounded opportunity must publish a compact runtime observation")
            try self.check(context[TransportCodec.snapshotKey] == nil, "No writer observation may be fabricated")
            try self.check((bytes?.count ?? Int.max) <= WatchRuntimeObservation.maximumBytes, "Runtime context must stay bounded")
            try self.check(f.session.state.current.allEnqueued.isEmpty, "Diagnostic publication must not invent audio transfers")
            try self.check(try f.publishedSnapshots().isEmpty, "Runtime context must have no recorder authority")
            try self.check([eventPacket, opaque1, opaque2].allSatisfy { $0.cancellationCount.current == 0 },
                "Runtime publication cannot cancel retained or unknown native messages")
            // The first context can precede native admission. One later real
            // observation may legitimately replace unknown queue with known zero.
            f.bridge.resynchronize(); try await self.settle(f)
            let attempts = f.session.state.current.contextAttempts
            f.bridge.resynchronize(); try await self.settle(f)
            try self.check(f.session.state.current.contextAttempts == attempts,
                "An already observed unchanged queue is deduplicated on the next real trigger")
        }
        await executeW2PCases()
        await executeD3Cases()
        await executeD3FollowupCases()
        await run("actual_cold_start_headless_waits_for_foreground_and_first_writer_status") { f in
            let source = f.root.appendingPathComponent("cold-start-library")
            let repository = try RecordingRepository(root: source)
            var session = try repository.createSession()
            session.state = .paused
            try repository.saveSession(session)
            ProbeColdStartEnvironment.repositoryRoot = source
            ProbeColdStartupDiagnostics.shared.events.access { $0.removeAll() }
            WCSession.default = WCSession()
            WKApplication.shared().refreshRequests = []
            WKApplication.shared().applicationState = .background
            let model = ProbeColdStartModel()
            try self.check(model.repository != nil && model.bridge != nil && model.writer == nil,
                "Real headless setup opens the bounded transfer owner without constructing a writer.")
            try self.check(!model.initialized && model.isBusy && !model.pendingCountIsKnown,
                "Before a writer status, a successful headless open is still unknown, not an empty ready library.")
            try self.check(model.pendingCountText == "暂无法核对",
                "An unknown inventory must not display a count.")
            let answer = Locked((count: 0, snapshot: Optional<RecorderSnapshot>.none))
            model.bridge?.onStatusQuery? { value in answer.access { $0.count += 1; $0.snapshot = value } }
            try await self.eventually("headless status query returns unknown") { answer.current.count == 1 }
            try self.check(answer.current.snapshot == nil && model.writer == nil,
                "A read-only status query cannot synthesize an empty snapshot or create the audio writer.")
            WKApplication.shared().applicationState = .active
            model.observeLifecycle(source: .scene, phase: .active)
            guard let writer = model.writer else { throw ProbeFailure.failed("Real foreground preparation must create its writer adapter.") }
            try self.check(writer.loadCount == 1 && model.audioSessionObserverCount == 1,
                "The extracted foreground method wires and loads one writer, with one audio-session observer setup.")
            try self.check(!model.initialized && model.isBusy && model.recordingLocation.interfaceReadyCount == 0,
                "Creating/loading the writer is not a first status or a ready UI.")
            model.observeLifecycle(source: .delegateDidBecomeActive, phase: .active)
            model.observeLifecycle(source: .scene, phase: .active)
            try self.check(model.writer === writer && writer.loadCount == 1,
                "Duplicate active callbacks cannot create or load a second writer.")
            let status = WatchRecordingStatus(revision: 1, session: session, effectiveDuration: 59,
                pendingCount: 3, pendingCountIsKnown: true, syncWarning: nil, recoveryMessage: nil,
                sealedCount: 7, freeBytes: 1_000_000, firstAudioAt: nil, detail: nil)
            writer.deliver(status)
            try await self.eventually("actual first writer receiver initializes the UI") { model.initialized }
            try self.check(!model.isBusy && model.snapshot.state == .paused && model.sealedCount == 7
                && model.pendingCountIsKnown && model.snapshot.pendingCount == 3,
                "The real first-status receiver preserves the saved session and reported counts.")
            model.syncFeedback.recordFailure("A previous receipt could not be matched.")
            try self.check(model.pendingCountText == "3 段" && model.syncFeedback.phase == .failed,
                "An independent sync failure must not hide a known count or clear the error.")
            try self.check(model.recordingLocation.interfaceReadyCount == 1
                && ProbeColdStartupDiagnostics.shared.events.current.contains(.firstWriterStatusReceived),
                "Only a delivered writer result opens the location UI gate and first-status marker.")
            writer.deliver(status)
            for _ in 0..<3 { await Task.yield() }
            try self.check(model.recordingLocation.interfaceReadyCount == 1 && model.lastStatusRevision == 1,
                "A duplicate queued status does not initialize the UI twice.")
            WKApplication.shared().applicationState = .background
            model.observeLifecycle(source: .delegateDidEnterBackground, phase: .background)
            WKApplication.shared().applicationState = .active
            model.observeLifecycle(source: .delegateDidBecomeActive, phase: .active)
            try self.check(model.writer === writer && writer.loadCount == 1 && writer.refreshCount == 1,
                "A later genuine foreground entry refreshes the existing writer instead of reconstructing it.")
            try self.check(model.engine == nil && !model.wantsRecording && model.captureEffects == 0,
                "Cold start, read-only query, first status and re-entry never start or restart capture.")
            writer.deliver(WatchRecordingStatus(revision: 2, session: session, effectiveDuration: 59,
                pendingCount: 3, pendingCountIsKnown: false, pendingCountIsRefreshing: true,
                syncWarning: nil, recoveryMessage: nil,
                sealedCount: 7, freeBytes: 1_000_000, firstAudioAt: nil, detail: nil))
            try await self.eventually("writer starts inventory refresh") { model.pendingCountIsRefreshing }
            try self.check(model.pendingCountText == "3 段" && !model.snapshot.pendingCountIsKnown,
                "A recheck keeps the last positive count visible without treating it as fresh transfer evidence.")
            let warning = "Synthetic count read failure"
            writer.deliver(WatchRecordingStatus(revision: 3, session: session, effectiveDuration: 59,
                pendingCount: 3, pendingCountIsKnown: false, syncWarning: warning, recoveryMessage: nil,
                sealedCount: 7, freeBytes: 1_000_000, firstAudioAt: nil, detail: nil))
            try await self.eventually("writer reports count failure") { model.syncWarning == warning }
            try self.check(model.pendingCountText == "3 段" && !model.pendingCountIsRefreshing && !model.pendingCountIsKnown,
                "A failed recheck retains the previous number and exposes the warning separately.")
            writer.deliver(WatchRecordingStatus(revision: 4, session: session, effectiveDuration: 59,
                pendingCount: 0, pendingCountIsKnown: true, syncWarning: nil, recoveryMessage: nil,
                sealedCount: 7, freeBytes: 1_000_000, firstAudioAt: nil, detail: nil))
            try await self.eventually("writer verifies the empty pending queue") { model.pendingCountIsKnown }
            try self.check(model.pendingCountText == "0 段", "Fresh evidence can show zero pending.")
            writer.deliver(WatchRecordingStatus(revision: 5, session: session, effectiveDuration: 59,
                pendingCount: 0, pendingCountIsKnown: false, pendingCountIsRefreshing: true,
                syncWarning: nil, recoveryMessage: nil,
                sealedCount: 7, freeBytes: 1_000_000, firstAudioAt: nil, detail: nil))
            try await self.eventually("writer rechecks previously empty queue") { model.pendingCountIsRefreshing }
            try self.check(model.pendingCountText == "核对中" && !model.hasDisplayablePendingCount,
                "Cached zero must never suggest every segment has been confirmed.")
        }

        await run("actual_cold_start_storage_failure_retries_without_empty_library_or_duplicate_writer") { f in
            let source = f.root.appendingPathComponent("cold-start-library")
            let preserved = f.root.appendingPathComponent("preserved-cold-start-library")
            let repository = try RecordingRepository(root: source)
            var session = try repository.createSession()
            session.state = .paused
            try repository.saveSession(session)
            // Keep the synthetic saved session intact while denying the real
            // initializer a directory at its exact configured root.
            try FileManager.default.moveItem(at: source, to: preserved)
            let blocker = Data("synthetic-storage-unavailable".utf8)
            try blocker.write(to: source)
            ProbeColdStartEnvironment.repositoryRoot = source
            WCSession.default = WCSession()
            WKApplication.shared().refreshRequests = []
            WKApplication.shared().refreshError = nil
            WKApplication.shared().applicationState = .background
            let model = ProbeColdStartModel()
            try self.check(model.transferInitializationFailed && model.snapshot.state == .failed
                && model.errorMessage != nil && !model.initialized && !model.isBusy,
                "A real failed repository open remains an explicit unavailable state, never a ready empty library.")
            try self.check(model.repository == nil && model.bridge == nil && model.writer == nil
                && !model.pendingCountIsKnown && WKApplication.shared().refreshRequests.count == 1,
                "Failed setup creates no partial owner/writer and requests one bounded recovery opportunity.")
            WKApplication.shared().applicationState = .active
            model.observeLifecycle(source: .delegateDidBecomeActive, phase: .active)
            try self.check(model.transferInitializationFailed && model.writer == nil
                && WKApplication.shared().refreshRequests.count == 1 && model.snapshot.state == .failed,
                "An unsuccessful real foreground retry preserves the failure and does not duplicate scheduling.")
            try self.check(try Data(contentsOf: source) == blocker,
                "Neither failed initialization nor a foreground retry replaces inaccessible synthetic storage.")
            try FileManager.default.removeItem(at: source)
            try FileManager.default.moveItem(at: preserved, to: source)
            WKApplication.shared().applicationState = .inactive
            model.observeLifecycle(source: .delegateWillResignActive, phase: .inactive)
            model.observeLifecycle(source: .scene, phase: .inactive)
            WKApplication.shared().applicationState = .active
            model.observeLifecycle(source: .scene, phase: .active)
            guard let writer = model.writer, let recoveredRepository = model.repository else {
                throw ProbeFailure.failed("The next genuine foreground edge must retry the production setup.")
            }
            try self.check(!model.transferInitializationFailed && model.errorMessage == nil
                && model.storageRecoveryRefreshDate == nil && model.isBusy && !model.initialized,
                "Successful setup clears only the old storage failure; UI readiness still waits for the writer result.")
            try self.check(try recoveredRepository.sessions().map(\.id) == [session.id],
                "Retry opens the preserved library rather than replacing its saved session with an empty one.")
            let status = WatchRecordingStatus(revision: 1, session: session, effectiveDuration: 12,
                pendingCount: 2, pendingCountIsKnown: true, syncWarning: nil, recoveryMessage: nil,
                sealedCount: 2, freeBytes: nil, firstAudioAt: nil, detail: nil)
            writer.deliver(status)
            try await self.eventually("retried setup receives its first status") { model.initialized }
            model.observeLifecycle(source: .delegateDidBecomeActive, phase: .active)
            try self.check(model.snapshot.state == .paused && model.snapshot.sessionID == session.id
                && model.writer === writer && writer.loadCount == 1 && model.audioSessionObserverCount == 1,
                "The saved paused session becomes ready once; duplicate activation cannot create another writer.")
            try self.check(model.engine == nil && !model.wantsRecording && model.captureEffects == 0,
                "Storage recovery and deferred UI setup do not start a microphone or finish the saved recording.")
        }

        await run("actual_lifecycle_dispatcher_delegate_and_scene_edges_are_idempotent") { f in
            let model = WatchRecorderModel.shared
            model.bridge = f.bridge
            defer { model.bridge = nil; model.isForeground = false }
            let delegate = WatchApplicationDelegate()
            WKApplication.shared().applicationState = .background
            delegate.applicationDidEnterBackground()
            try self.check(model.foregroundEffectCount == 0 && !model.isForeground,
                "A real background callback cannot initialize the foreground writer shell.")
            WKApplication.shared().applicationState = .active
            delegate.applicationDidBecomeActive()
            model.observeLifecycle(source: .scene, phase: .active)
            delegate.applicationDidBecomeActive()
            try self.check(model.foregroundEffectCount == 1 && model.isForeground,
                "Delegate and scene duplicates execute the foreground effect only once.")
            model.observeLifecycle(source: .scene, phase: .inactive)
            try self.check(model.isForeground,
                "A late scene inactive cannot override a currently active WatchKit state.")
            delegate.applicationWillResignActive()
            try self.check(!model.isForeground && !model.recordingLocation.isForeground,
                "Will-resign retires the owner even before WatchKit's sampled state changes.")
            model.observeLifecycle(source: .scene, phase: .active)
            try self.check(!model.isForeground && model.foregroundEffectCount == 1,
                "A delayed scene active while resigning cannot restart foreground effects.")
            WKApplication.shared().applicationState = .background
            delegate.applicationDidEnterBackground()
            delegate.applicationDidEnterBackground()
            try self.check(!model.isForeground,
                "Repeated background callbacks never grant foreground maintenance.")
        }

        await run("actual_lifecycle_dispatcher_scene_fallback_after_observed_inactive") { f in
            let model = WatchRecorderModel.shared
            model.bridge = f.bridge
            defer { model.bridge = nil; model.isForeground = false }
            WKApplication.shared().applicationState = .inactive
            model.observeLifecycle(source: .scene, phase: .inactive)
            WKApplication.shared().applicationState = .active
            model.observeLifecycle(source: .scene, phase: .active)
            WatchApplicationDelegate().applicationWillResignActive()
            WKApplication.shared().applicationState = .inactive
            model.observeLifecycle(source: .scene, phase: .inactive)
            WKApplication.shared().applicationState = .active
            model.observeLifecycle(source: .scene, phase: .active)
            try self.check(model.foregroundEffectCount == 2 && model.isForeground,
                "A genuine observed nonactive-to-active scene edge recovers without a delegate active callback.")
        }

        await executeBacklogEvidenceCases()
        await executeBacklogBuildPublicationCases()
        await executeVerifiedBacklogObservationCases()
        await run("automatic_context_missed_foreground_deadline_renews_only_on_real_background_edge") { f in
            _ = try f.sealHistorical(1)
            f.enableBackgroundRefresh()
            f.bridge.foregroundDidChange(true)
            f.bridge.resynchronize()
            try await self.eventually("initial foreground refresh accepted") { f.refreshRequests.current.count == 1 }
            try await self.drainQueuedWork(f)
            let first = f.refreshRequests.current[0]
            let transition = first.addingTimeInterval(1)
            f.bridge.foregroundDidChange(false)
            f.bridge.setMaintenanceAllowed(false)
            try await self.drainQueuedWork(f)
            try self.check(f.refreshRequests.current.count == 1, "Scene inactivity alone is not the actual WatchKit background edge.")
            f.bridge.enteredBackground(at: transition)
            try await self.eventually("foreground-missed request gets successor") { f.refreshRequests.current.count == 2 }
            let second = f.refreshRequests.current[1]
            try self.check(second.timeIntervalSince(transition) == 900 && second > first,
                "An ignored foreground deadline is retired once, with the normal preferred interval.")
            for _ in 0..<20 { f.bridge.enteredBackground(at: transition.addingTimeInterval(60)); f.bridge.resynchronize() }
            try await self.drainQueuedWork(f)
            try self.check(f.refreshRequests.current == [first, second], "Repeated background callbacks must not postpone the successor.")
            let bytes = try Data(contentsOf: f.refreshURL)
            let persisted = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            try self.check((persisted?["preferredDate"] as? NSNumber)?.doubleValue == second.timeIntervalSince1970 * 1_000,
                "The replacement is durable before calling the platform scheduler.")
        }

        await run("automatic_context_future_intent_and_cold_background_do_not_renew") { f in
            _ = try f.sealHistorical(1)
            f.enableBackgroundRefresh()
            f.bridge.resynchronize()
            try await self.eventually("future intent accepted") { f.refreshRequests.current.count == 1 }
            let original = f.refreshRequests.current[0]
            f.bridge.enteredBackground(at: original.addingTimeInterval(1))
            try await self.drainQueuedWork(f)
            try self.check(f.refreshRequests.current == [original], "A cold background event without observed foreground cannot replace an overdue accepted request.")
            f.bridge.foregroundDidChange(true)
            f.bridge.enteredBackground(at: original.addingTimeInterval(-1))
            try await self.drainQueuedWork(f)
            try self.check(f.refreshRequests.current == [original], "A still-future request survives a real foreground exit.")
        }

        await run("automatic_context_actual_delegate_background_edge_is_wired") { f in
            let overdue = Date().addingTimeInterval(-60)
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
                "preferredDate": Int64(overdue.timeIntervalSince1970 * 1_000)]).write(to: f.refreshURL)
            f.restartBridge(maintenanceAllowed: false)
            f.enableBackgroundRefresh()
            f.bridge.foregroundDidChange(true)
            WatchRecorderModel.shared.bridge = f.bridge
            defer { WatchRecorderModel.shared.bridge = nil }
            let delegate = WatchApplicationDelegate()
            delegate.applicationDidEnterBackground()
            try await self.eventually("real delegate forwards background transition") { f.refreshRequests.current.count == 1 }
            try self.check(f.refreshRequests.current[0].timeIntervalSinceNow > 895,
                "The production delegate forwards only the real system edge to the shared owner.")
        }

        for liveCapture in [false, true] {
            await run("actual_delegate_background_without_scene_hook_retires_owner_capture_\(liveCapture)") { f in
                let model = WatchRecorderModel.shared
                model.bridge = f.bridge
                model.isForeground = true
                model.initialized = true
                model.wantsRecording = liveCapture
                model.engine = liveCapture ? ProbeCaptureEngine() : nil
                model.recordingLocation.setForeground(true)
                defer {
                    model.bridge = nil; model.wantsRecording = false
                    model.engine = nil; model.isForeground = false
                }
                let manifests = try (1...2).map(f.sealHistorical)
                let receipt = try f.receipt(manifests[0])
                f.charging.access { $0 = true }
                f.bridge.foregroundDidChange(true)
                f.bridge.setMaintenanceAllowed(true, foreground: true, liveCapture: liveCapture)
                f.bridge.resynchronize()
                try await self.drainQueuedWork(f)
                try await self.eventually("foreground catalogue captured before delegate edge") {
                    FileManager.default.fileExists(atPath: f.watch.root.appendingPathComponent("ConnectivityDiagnostics/watch-backlog.json").path)
                }
                // Deliberately do not send scenePhase / becameInactive. Execute
                // the actual production delegate and extracted model methods.
                WatchApplicationDelegate().applicationDidEnterBackground()
                try self.check(!model.isForeground && !model.recordingLocation.isForeground,
                    "The real system background callback retires model/location foreground state without a scene hook.")
                try f.deliver(receipt)
                let report = try await self.report(f, "delegate-only receipt metadata has background context") {
                    $0["durableACKCommittedCount"] as? Int == 1
                }
                let context = report["context"] as? [String: Any]
                try self.check(context?["foreground"] as? Bool == false,
                    "Background receipt diagnostics cannot retain an old foreground flag.")
                try self.check(context?["maintenanceOwnerAllowed"] as? Bool == liveCapture
                    && context?["liveCapture"] as? Bool == liveCapture,
                    "Paused background has no full owner; an actually running capture retains its independent permission.")
                try await self.drainReportWrites(f)
                try await self.eventually("first durable ACK uses system background observation") {
                    let summary = try self.backlogSummary(f.watch.root)
                    let members = try self.backlogPages(f.watch.root, summary).flatMap(\.members)
                    guard let member = members.first(where: { $0.segmentID == manifests[0].id }) else { return false }
                    return member.firstNewACKContext?.foreground == false
                        && member.firstNewACKContext?.liveCapture == liveCapture
                }
                model.becameInactive()
                try await self.drainQueuedWork(f)
                try self.check(!model.isForeground,
                    "A later duplicate scene transition is idempotent and cannot restore foreground ownership.")
            }
        }

        await run("automatic_context_schedule_report_tracks_real_start_acceptance_and_error") { f in
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            let date = Date().addingTimeInterval(900)
            f.bridge.backgroundRefreshSchedulingStarted(preferredDate: date)
            f.bridge.backgroundRefreshSchedulingCompleted(preferredDate: date, succeeded: false,
                errorDomain: "SyntheticWKErrorDomain", errorCode: 73)
            let failed = try await self.report(f, "schedule failure diagnostic saved") {
                ($0["refreshScheduling"] as? [String: Any])?["failedCount"] as? Int == 1
            }
            let first = failed["refreshScheduling"] as? [String: Any]
            try self.check(first?["requestedCount"] as? Int == 1 && first?["acceptedCount"] as? Int == 0
                && first?["lastAccepted"] as? Bool == false && first?["lastErrorDomain"] as? String == "SyntheticWKErrorDomain"
                && first?["lastErrorCode"] as? Int == 73, "Schedule acceptance and NSError identity remain separate from actual WK execution.")
            try self.check(failed["applicationRefreshTasksStarted"] as? Int == 0 && failed["fileEnqueuedCount"] as? Int == 0,
                "A registration callback never fabricates a task, file admission or ACK.")
            f.bridge.resynchronize(); try await self.settle(f)
            let compactFailure = (f.session.state.current.contexts.last?[TransportCodec.watchRuntimeKey] as? Data)
                .flatMap(WatchRuntimeObservation.decode)
            try self.check(compactFailure?.refresh?.errorKind == .other
                && compactFailure?.refresh?.errorCode == 73 && compactFailure?.refresh?.accepted == false,
                "Compact context preserves schedule failure without transmitting arbitrary NSError domains.")
            f.bridge.backgroundRefreshSchedulingStarted(preferredDate: date)
            f.bridge.backgroundRefreshSchedulingCompleted(preferredDate: date, succeeded: true)
            let accepted = try await self.report(f, "schedule success diagnostic saved") {
                ($0["refreshScheduling"] as? [String: Any])?["acceptedCount"] as? Int == 1
            }
            let last = accepted["refreshScheduling"] as? [String: Any]
            try self.check(last?["requestedCount"] as? Int == 2 && last?["failedCount"] as? Int == 1
                && last?["lastErrorDomain"] == nil && last?["lastErrorCode"] == nil,
                "The latest success clears error identity while preserving process totals.")
        }

        await run("automatic_context_valid_new_request_is_automatic_and_cross_channel_replay_is_passive") { f in
            let manifest = try f.sealHistorical(1)
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            let request = f.automaticRequest()
            f.bridge.session(f.session, didReceiveApplicationContext: request)
            try await self.eventually("new context admits bounded retained work") { f.session.state.current.allEnqueued.count == 1 }
            try await self.drainQueuedWork(f)
            let saved = try FileIdentity(f.automaticSyncURL)
            let retry = try FileIdentity(f.retryURL)
            let before = f.session.state.current
            f.bridge.session(f.session, didReceiveApplicationContext: request)
            f.bridge.session(f.session, didReceiveUserInfo: request)
            f.bridge.session(f.session, didReceiveMessage: request)
            try await self.drainQueuedWork(f)
            let report = try await self.report(f, "cross-channel replays observed") {
                ($0["automaticRequests"] as? [String: Any])?["replayCount"] as? Int == 3
            }
            try self.check((report["automaticRequests"] as? [String: Any])?["acceptedCount"] as? Int == 1,
                "One UUID is consumed once across context, deferred and immediate channels.")
            try self.check(f.session.state.current.outstandingReads == before.outstandingReads
                && f.session.state.current.allEnqueued.count == 1 && f.changes.current == 0,
                "Replayed controls cause no synchronization, UI repository refresh or new native admission.")
            try self.check(try FileIdentity(f.automaticSyncURL) == saved && FileIdentity(f.retryURL) == retry,
                "Deduplication and existing retry cooldown survive replays byte-for-byte.")
            try self.check(try !f.watch.hasDurableAcknowledgement(for: manifest), "A control request is never an audio ACK.")
            f.restartBridge(maintenanceAllowed: false)
            try await self.drainQueuedWork(f)
            let restarted = f.session.state.current
            f.bridge.session(f.session, didReceiveApplicationContext: request)
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.outstandingReads == restarted.outstandingReads
                && f.session.state.current.allEnqueued.count == 1,
                "A persisted context cannot resynchronize on every process restart.")
        }

        for variant in ["missing_id", "unknown_key", "status", "receipt", "old", "future", "fractional", "invalid_uuid", "numeric_bool", "bool_schema", "bool_time"] {
            await run("automatic_context_rejects_\(variant)_without_other_work") { f in
                _ = try f.sealHistorical(1)
                f.bridge.setMaintenanceAllowed(false)
                var request = f.automaticRequest()
                switch variant {
                case "missing_id": request.removeValue(forKey: "automaticSyncRequestID")
                case "unknown_key": request["extra"] = true
                case "status": request[TransportCodec.statusRequestKey] = Data()
                case "receipt": request[TransportCodec.receiptKey] = Data()
                case "old": request["automaticSyncRequestedAtMS"] = Int64(Date().addingTimeInterval(-8 * 24 * 60 * 60).timeIntervalSince1970 * 1_000)
                case "future": request["automaticSyncRequestedAtMS"] = Int64(Date().addingTimeInterval(600).timeIntervalSince1970 * 1_000)
                case "fractional": request["automaticSyncRequestedAtMS"] = Date().timeIntervalSince1970 * 1_000 + 0.5
                case "numeric_bool": request[TransportCodec.requestSyncKey] = NSNumber(value: 1)
                case "bool_schema": request["automaticSyncSchemaVersion"] = true
                case "bool_time": request["automaticSyncRequestedAtMS"] = true
                default: request["automaticSyncRequestID"] = "not-a-uuid"
                }
                let before = f.session.state.current
                f.bridge.session(f.session, didReceiveApplicationContext: request)
                try await self.drainQueuedWork(f)
                try self.check(f.session.state.current.outstandingReads == before.outstandingReads
                    && f.session.state.current.allEnqueued.isEmpty && f.changes.current == 0,
                    "Invalid/stale context cannot carry hidden sync, query, receipt or scan work.")
                try self.check(!FileManager.default.fileExists(atPath: f.automaticSyncURL.path), "Invalid controls never consume a durable request ID.")
            }
        }

        await run("automatic_context_failed_atomic_dedup_commit_does_not_consume_request") { f in
            _ = try f.sealHistorical(1)
            f.bridge.setMaintenanceAllowed(false)
            try Data("{\"schemaVersion\":1,\"requests\":[]}".utf8).write(to: f.automaticSyncURL)
            let original = try Data(contentsOf: f.automaticSyncURL)
            let request = f.automaticRequest()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.watch.root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.watch.root.path) }
            f.bridge.session(f.session, didReceiveApplicationContext: request)
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.allEnqueued.isEmpty && Data(contentsOf: f.automaticSyncURL) == original,
                "A failed atomic write cannot consume the control ID or start file synchronization.")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.watch.root.path)
            f.bridge.session(f.session, didReceiveApplicationContext: request)
            try await self.eventually("same request retries after metadata write access returns") { f.session.state.current.allEnqueued.count == 1 }
            let observed = try await self.report(f, "only durable dedup success is accepted") {
                ($0["automaticRequests"] as? [String: Any])?["acceptedCount"] as? Int == 1
            }
            try self.check((observed["automaticRequests"] as? [String: Any])?["stateUnavailableCount"] as? Int == 1,
                "Failed control durability stays visible without a fake accepted request.")
        }

        for variant in ["corrupt", "directory", "symlink", "oversize"] {
            await run("automatic_context_unavailable_dedup_\(variant)_preserves_state_then_recovers") { f in
                _ = try f.sealHistorical(1)
                f.bridge.setMaintenanceAllowed(false)
                let sentinel = f.root.appendingPathComponent("sentinel")
                let original = Data("retained-unknown-state".utf8)
                switch variant {
                case "directory": try FileManager.default.createDirectory(at: f.automaticSyncURL, withIntermediateDirectories: false)
                case "symlink":
                    try original.write(to: sentinel)
                    try FileManager.default.createSymbolicLink(at: f.automaticSyncURL, withDestinationURL: sentinel)
                case "oversize": try Data(repeating: 32, count: 8_193).write(to: f.automaticSyncURL)
                default: try original.write(to: f.automaticSyncURL)
                }
                let request = f.automaticRequest()
                f.bridge.session(f.session, didReceiveApplicationContext: request)
                try await self.drainQueuedWork(f)
                try self.check(f.session.state.current.allEnqueued.isEmpty, "Unknown dedup state is never treated as an empty ID set.")
                if variant == "corrupt" { try self.check(try Data(contentsOf: f.automaticSyncURL) == original, "Malformed dedup bytes are preserved.") }
                if variant == "symlink" { try self.check(try Data(contentsOf: sentinel) == original, "The bounded metadata reader must not follow symlinks.") }
                try FileManager.default.removeItem(at: f.automaticSyncURL)
                f.bridge.session(f.session, didReceiveApplicationContext: request)
                try await self.eventually("later real control retries unavailable dedup metadata") { f.session.state.current.allEnqueued.count == 1 }
                try self.check(try Data(contentsOf: f.automaticSyncURL).count <= 8_192, "Successful dedup state remains a fixed small file.")
            }
        }

        await run("automatic_context_dedup_window_and_native_progress_report_are_bounded") { f in
            f.bridge.setMaintenanceAllowed(false)
            for _ in 0..<40 { f.bridge.session(f.session, didReceiveApplicationContext: f.automaticRequest()) }
            try await self.drainQueuedWork(f)
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: f.automaticSyncURL)) as? [String: Any]
            try self.check((state?["requests"] as? [Any])?.count == 32 && Data(contentsOf: f.automaticSyncURL).count <= 8_192,
                "Only a bounded recent request window is persisted, never an unbounded history.")
            let manifest = try f.sealHistorical(1)
            for i in 0..<5 {
                let task = f.session.addLegacyTask(url: f.watch.audioURL(for: manifest), metadata: [TransportCodec.manifestKey: try TransportCodec.encode(manifest), "fileTransferAttemptID": UUID().uuidString])
                task.progress.completedUnitCount = Int64(i * 10)
                task.isTransferring = i % 2 == 0
            }
            f.bridge.resynchronize()
            let observed = try await self.report(f, "at most three real native progress entries observed") {
                ($0["nativeQueue"] as? [String: Any])?["count"] as? Int == 5
            }
            let sample = (observed["nativeQueue"] as? [String: Any])?["sample"] as? [[String: Any]]
            try self.check(sample?.count == 3 && sample?[1]["completed"] as? Int == 10
                && sample?[1]["isTransferring"] as? Bool == false,
                "Native sample reports real existing task metadata, without fabricating completion or spare capacity.")
            f.bridge.resynchronize(); try await self.settle(f)
            let compact = (f.session.state.current.contexts.last?[TransportCodec.watchRuntimeKey] as? Data)
                .flatMap(WatchRuntimeObservation.decode)
            try self.check(compact?.nativeQueueCount == 5 && compact?.queueSamples?.count == 3
                && compact?.queueSamples?[1].completedUnits == 10 && compact?.queueSamples?[1].totalUnits == 100
                && compact?.queueSamples?[1].isTransferring == false && compact?.queueSamples?[1].attemptID != nil,
                "Phone context receives bounded source progress and attempt identity, never all-queue progress inferred from a sample.")
            try self.check(try Data(contentsOf: f.backgroundSyncReportURL).count <= 8_192,
                "Expanded diagnostics retain the fixed report byte ceiling.")
            try self.check(f.session.state.current.files.allSatisfy { $0.cancellationCount.current == 0 },
                "A diagnostic progress sample cannot cancel old unacknowledged native tasks.")
        }

        await run("background_report_observes_charging_wk_enqueue_and_exact_durable_ack") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let manifests = try (1...12).map(f.seal)
            let receipt = try f.receipt(manifests[0])
            f.charging.access { $0 = true }
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.session.hasContentPending = true
            let task = UUID()
            f.bridge.performBackgroundConnectivityTask(id: task) {}
            _ = try await self.report(f, "charging opportunity recorded") {
                $0["fileEnqueuedCount"] as? Int == 12 && $0["liveTaskCount"] as? Int == 1
            }
            // Enqueue observation and budget accounting publish separate
            // revisions. Inspect the completed pass, not an intermediate row.
            try await self.drainReportWrites(f)
            let first = try f.backgroundSyncReport()
            let budget = first["budget"] as? [String: Any]
            try self.check(first["schemaVersion"] as? Int == 1 && first["role"] as? String == "watch"
                && first["lockState"] as? String == "not_observed", "The fixed report is versioned and never fabricates Watch lock state.")
            try self.check(first["connectivityTasksStarted"] as? Int == 1
                && budget?["externalPower"] as? Bool == true && budget?["enqueueLimit"] as? Int == 12
                && budget?["enqueueRemaining"] as? Int == 0,
                "Only a real registered WK task and sampled charging budget support the opportunity claim.")
            try self.check((first["context"] as? [String: Any])?["foreground"] as? Bool == false
                && (first["context"] as? [String: Any])?["liveCapture"] as? Bool == false,
                "Headless work must remain distinct from foreground and actual capture.")
            let mismatch = SegmentReceipt(segmentID: receipt.segmentID, sha256: String(repeating: "0", count: 64),
                byteCount: receipt.byteCount)
            try f.deliver(mismatch)
            let rejected = try await self.report(f, "mismatched ACK rejected without positive counter") {
                $0["acknowledgementUncommittedCount"] as? Int == 1 && $0["durableACKCommittedCount"] as? Int == 0
            }
            let failure = rejected["lastAcknowledgementFailure"] as? [String: Any]
            try self.check(failure?["stage"] as? String == "commit"
                && failure?["reason"] as? String == "receipt_mismatch"
                && failure?["foreground"] as? Bool == false,
                "Headless receipt mismatch retains its typed cause even while the general journal is suppressed.")
            f.complete(f.session.state.current.files[0])
            try await self.drainQueuedWork(f)
            try self.check(try f.backgroundSyncReport()["durableACKCommittedCount"] as? Int == 0,
                "WC transport completion alone must never increment durable ACK success.")
            try f.deliver(receipt)
            let accepted = try await self.report(f, "matching durable ACK without replenishing opportunity budget recorded") {
                $0["durableACKCommittedCount"] as? Int == 1 && $0["fileEnqueuedCount"] as? Int == 12
            }
            let sources = accepted["recentACKCommittedSources"] as? [[String: Any]]
            try self.check(sources?.last?["segmentID"] as? String == manifests[0].id.uuidString
                && sources?.last?["byteCount"] as? Int64 == manifests[0].byteCount,
                "Private source identities come only from the matching already committed receipt.")
            try f.deliver(receipt)
            _ = try await self.report(f, "durable replay is separate from a newly committed ACK") {
                $0["durableACKCommittedCount"] as? Int == 1 && $0["durableACKReplayedCount"] as? Int == 1
            }
            f.bridge.expireBackgroundConnectivityTask(id: task)
            f.bridge.expireBackgroundConnectivityTask(id: task)
            let ended = try await self.report(f, "expiration archives the actual opportunity once") {
                $0["tasksExpired"] as? Int == 1 && $0["liveTaskCount"] as? Int == 0 && $0["currentOpportunity"] == nil
            }
            try self.check((ended["lastOpportunity"] as? [String: Any])?["endReason"] as? String == "expired",
                "An expired last opportunity cannot be presented as currently live or successfully completed.")
            let raw = String(decoding: try Data(contentsOf: f.backgroundSyncReportURL), as: UTF8.self)
            for excluded in ["sha256", "fileName", "startedAt\"", "latitude", "transcript", "localizedDescription"] {
                try self.check(!raw.contains(excluded), "The small private report must not expose content digests, paths, capture times, locations or text.")
            }
        }

        await run("background_report_ack_decode_failure_is_bounded_and_content_free") { f in
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            let payload = [TransportCodec.receiptKey: Data("private-transcript /private/secret/path".utf8)]
            for _ in 0..<40 { f.bridge.session(f.session, didReceiveUserInfo: payload) }
            let report = try await self.report(f, "malformed replays counted without growing error history") {
                $0["acknowledgementUncommittedCount"] as? Int == 40
            }
            let failure = report["lastAcknowledgementFailure"] as? [String: Any]
            try self.check(failure?["stage"] as? String == "decode"
                && failure?["reason"] as? String == "decode_failed"
                && failure?["systemCode"] == nil && report["durableACKCommittedCount"] as? Int == 0,
                "Malformed payloads cannot claim a repository commit or durable ACK.")
            let raw = try Data(contentsOf: f.backgroundSyncReportURL)
            try self.check(raw.count <= 8_192 && !String(decoding: raw, as: UTF8.self).contains("private-transcript")
                && !String(decoding: raw, as: UTF8.self).contains("/private/secret"),
                "Only one replacement error sample is retained without raw payload or free-form error content.")
            f.bridge.resynchronize(); try await self.settle(f)
            let compact = (f.session.state.current.contexts.last?[TransportCodec.watchRuntimeKey] as? Data)
                .flatMap(WatchRuntimeObservation.decode)
            try self.check(compact?.lastACKFailure?.stage == .decode && compact?.lastACKFailure?.reason == .decodeFailed,
                "Malformed ACK cause reaches the Phone context rather than remaining trapped in the local report.")
        }

        await run("background_report_ack_os_failure_preserves_only_domain_class_and_code", fault: { point in
            if point == .beforeAcknowledgementCommit {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC),
                    userInfo: [NSLocalizedDescriptionKey: "/private/secret/path private-transcript"])
            }
        }) { f in
            let manifest = try f.sealHistorical(1), receipt = try f.receipt(manifest)
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            try f.deliver(receipt)
            let report = try await self.report(f, "OS commit failure classified") {
                $0["acknowledgementUncommittedCount"] as? Int == 1
            }
            let failure = report["lastAcknowledgementFailure"] as? [String: Any]
            try self.check(failure?["stage"] as? String == "commit"
                && failure?["reason"] as? String == "posix_io"
                && failure?["systemCode"] as? Int == Int(ENOSPC),
                "An actual OS commit error is distinguishable from a mismatched or malformed receipt.")
            let raw = String(decoding: try Data(contentsOf: f.backgroundSyncReportURL), as: UTF8.self)
            try self.check(!raw.contains("private-transcript") && !raw.contains("/private/secret")
                && !FileManager.default.fileExists(atPath: f.ackURL(manifest).path),
                "Error diagnostics neither expose NSError userInfo nor manufacture a durable acknowledgement.")
            f.bridge.resynchronize(); try await self.settle(f)
            let compact = (f.session.state.current.contexts.last?[TransportCodec.watchRuntimeKey] as? Data)
                .flatMap(WatchRuntimeObservation.decode)
            try self.check(compact?.lastACKFailure?.stage == .commit && compact?.lastACKFailure?.reason == .posixIO
                && compact?.lastACKFailure?.systemCode == Int(ENOSPC)
                && compact?.lastACKFailure?.operation == .acknowledgementWrite,
                "Compact context carries the actual durable commit failure classification and controlled OS code.")
        }

        await run("background_report_unknown_historical_receipts_reproduce_missing_manifest") { f in
            let manifest = try f.sealHistorical(1), receipt = try f.receipt(manifest)
            let native = f.session.addLegacyTask(url: f.watch.audioURL(for: manifest),
                metadata: [TransportCodec.manifestKey: try TransportCodec.encode(manifest)])
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            let unknown = SegmentReceipt(segmentID: UUID(), sha256: String(repeating: "a", count: 64), byteCount: 11_524_096)
            for route in 0..<24 { try f.deliver(unknown, route: route) }
            let report = try await self.report(f, "historical receipt without a Watch manifest reproduces device error") {
                $0["acknowledgementUncommittedCount"] as? Int == 24
            }
            let failure = report["lastAcknowledgementFailure"] as? [String: Any]
            try self.check(failure?["stage"] as? String == "commit"
                && failure?["reason"] as? String == "cocoa_io" && failure?["systemCode"] as? Int == 260
                && failure?["operation"] as? String == "manifest_read"
                && (failure?["segmentID"] as? String).flatMap(UUID.init(uuidString:)) == unknown.segmentID,
                "A missing local manifest reproduces the real build100 failure without reading or removing source audio.")
            try self.check(report["durableACKCommittedCount"] as? Int == 0
                && native.cancellationCount.current == 0
                && FileManager.default.fileExists(atPath: f.watch.audioURL(for: manifest).path),
                "Unrelated historical receipts neither acknowledge a current source nor cancel its native transfer.")
            try f.deliver(receipt)
            _ = try await self.report(f, "a matching receipt after unknown history still commits") {
                $0["durableACKCommittedCount"] as? Int == 1
            }
            try self.check(FileManager.default.fileExists(atPath: f.ackURL(manifest).path),
                "Unknown receipt errors alone do not prove that valid ACK processing is globally blocked.")
        }

        let ackCommitBlocked = Locked(true)
        await run("background_report_failed_ack_commit_never_claims_durable_success", fault: { point in
            if point == .beforeAcknowledgementCommit && ackCommitBlocked.current {
                throw NSError(domain: "SyntheticAcknowledgementFailure", code: 1)
            }
        }) { f in
            let manifest = try f.sealHistorical(1), receipt = try f.receipt(manifest)
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.session.hasContentPending = true
            f.bridge.performBackgroundConnectivityTask(id: UUID()) {}
            try f.deliver(receipt)
            _ = try await self.report(f, "failed ACK commit remains uncommitted") {
                $0["acknowledgementUncommittedCount"] as? Int == 1 && $0["durableACKCommittedCount"] as? Int == 0
            }
            try self.check(!FileManager.default.fileExists(atPath: f.ackURL(manifest).path), "The positive counter follows repository durability, never receipt arrival alone.")
            ackCommitBlocked.access { $0 = false }
            try f.deliver(receipt)
            _ = try await self.report(f, "later actual durable commit is counted once") { $0["durableACKCommittedCount"] as? Int == 1 }
        }

        await run("background_report_bounds_sources_and_binds_counter_epoch") { f in
            let manifests = try (1...14).map(f.sealHistorical)
            f.bridge.setMaintenanceAllowed(true, foreground: false, liveCapture: true)
            f.bridge.resynchronize()
            for index in manifests.indices {
                try await self.eventually("actual source \(index) admitted") { f.session.state.current.allEnqueued.count >= index + 1 && !f.session.state.current.files.isEmpty }
                let native = f.session.state.current.files[0]
                let receipt = try f.receipt(native.manifest!)
                f.complete(native)
                try f.deliver(receipt)
            }
            let old = try await self.report(f, "bounded source suffix after fourteen durable commits") {
                $0["fileEnqueuedCount"] as? Int == 14 && $0["durableACKCommittedCount"] as? Int == 14
            }
            try self.check((old["recentEnqueuedSources"] as? [Any])?.count == 8
                && (old["recentACKCommittedSources"] as? [Any])?.count == 8,
                "The report retains only eight recent source identities per direction.")
            try self.check((old["context"] as? [String: Any])?["foreground"] as? Bool == false
                && (old["context"] as? [String: Any])?["liveCapture"] as? Bool == true
                && old["currentOpportunity"] == nil,
                "Real live capture must not be relabeled as a WK background opportunity.")
            f.charging.access { $0 = true }
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.session.hasContentPending = true
            let firstTask = UUID()
            f.bridge.performBackgroundConnectivityTask(id: firstTask) {}
            _ = try await self.report(f, "first empty charged opportunity still has real budget observation") {
                ($0["currentOpportunity"] as? [String: Any])?["initialBudget"] != nil
            }
            f.bridge.expireBackgroundConnectivityTask(id: firstTask)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) {}
            let control = f.automaticRequest()
            try FileManager.default.createDirectory(at: f.automaticSyncURL, withIntermediateDirectories: false)
            f.bridge.session(f.session, didReceiveApplicationContext: control)
            try await self.drainQueuedWork(f)
            try FileManager.default.removeItem(at: f.automaticSyncURL)
            f.bridge.session(f.session, didReceiveApplicationContext: control)
            f.bridge.session(f.session, didReceiveUserInfo: control)
            f.bridge.session(f.session, didReceiveApplicationContext: [:])
            f.bridge.session(f.session, didReceiveApplicationContext: f.automaticRequest(at: Date().addingTimeInterval(-8 * 24 * 60 * 60)))
            let preferred = Date().addingTimeInterval(900)
            f.bridge.backgroundRefreshSchedulingStarted(preferredDate: preferred)
            f.bridge.backgroundRefreshSchedulingCompleted(preferredDate: preferred, succeeded: true)
            f.bridge.backgroundRefreshSchedulingStarted(preferredDate: preferred)
            f.bridge.backgroundRefreshSchedulingCompleted(preferredDate: preferred, succeeded: false,
                errorDomain: String(repeating: "\"", count: 300), errorCode: Int.max)
            for index in 0..<3 {
                let native = f.session.addLegacyTask(url: f.watch.audioURL(for: manifests[index]),
                    metadata: [TransportCodec.manifestKey: try TransportCodec.encode(manifests[index])])
                native.progress.totalUnitCount = Int64.max
                native.progress.completedUnitCount = -1
            }
            f.bridge.resynchronize()
            let maximal = try await self.report(f, "current and last opportunity coexist with both bounded source suffixes") {
                $0["currentOpportunity"] != nil && $0["lastOpportunity"] != nil
                    && ($0["currentOpportunity"] as? [String: Any])?["initialBudget"] != nil
                    && ($0["nativeQueue"] as? [String: Any])?["count"] as? Int == 3
                    && ($0["refreshScheduling"] as? [String: Any])?["failedCount"] as? Int == 1
                    && ($0["automaticRequests"] as? [String: Any])?["staleCount"] as? Int == 1
            }
            try self.check((maximal["recentEnqueuedSources"] as? [Any])?.count == 8
                && (maximal["recentACKCommittedSources"] as? [Any])?.count == 8,
                "Worst-case current/last context must fit alongside the complete bounded source suffixes.")
            let nativeSample = (maximal["nativeQueue"] as? [String: Any])?["sample"] as? [[String: Any]]
            try self.check(nativeSample?.count == 3 && nativeSample?.first?["completed"] as? Int64 == -1
                && nativeSample?.first?["total"] as? Int64 == Int64.max,
                "Unknown negative progress and large counts are preserved in the actual persisted sample.")
            try self.check(((maximal["refreshScheduling"] as? [String: Any])?["lastErrorDomain"] as? String)?.count == 96
                && (maximal["automaticRequests"] as? [String: Any])?["stateUnavailableCount"] as? Int == 1,
                "Maximal report includes bounded escaped error domain and every automatic-request counter.")
            let attributes = try FileManager.default.attributesOfItem(atPath: f.backgroundSyncReportURL.path)
            try self.check((attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 8_192
                && (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "The actual production file is bounded and private.")
            try await self.drainReportWrites(f)
            let maximalBytes = try Data(contentsOf: f.backgroundSyncReportURL)
            let persistedMaximum = try JSONSerialization.jsonObject(with: maximalBytes) as? [String: Any]
            try self.check(persistedMaximum?["reportWriteFailureCount"] as? Int == 0
                && (persistedMaximum?["nativeQueue"] as? [String: Any])?["count"] as? Int == 3
                && maximalBytes.count <= 8_192,
                "The complete maximal snapshot really reached disk without silently dropping an oversized report.")
            try maximalBytes.write(to: f.root.appendingPathComponent("maximal-background-sync-report.json"))
            f.restartBridge(maintenanceAllowed: false)
            let renewed = try await self.report(f, "new observer epoch cannot inherit old counters") {
                $0["observerEpochID"] as? String != old["observerEpochID"] as? String && $0["fileEnqueuedCount"] as? Int == 0
            }
            try self.check(renewed["processRunID"] as? String == old["processRunID"] as? String
                && renewed["counterScope"] as? String == "observer_epoch",
                "A bridge restart in one process has an explicit new counter epoch; consumers cannot subtract across epochs.")
        }

        await run("background_report_read_is_passive_and_does_not_refresh_observation") { f in
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            try await self.drainReportWrites(f)
            let initial = try f.backgroundSyncReport()
            let native = f.session.state.current
            for _ in 0..<25 { _ = try f.backgroundSyncReport() }
            let after = try f.backgroundSyncReport(), current = f.session.state.current
            try self.check(initial["reportSequence"] as? Int == after["reportSequence"] as? Int
                && initial["generatedAtMS"] as? Int64 == after["generatedAtMS"] as? Int64,
                "Copying the existing report cannot renew its observation time or sequence.")
            try self.check(native.outstandingReads == current.outstandingReads && current.allEnqueued.isEmpty
                && current.messages == native.messages && current.userInfo.count == native.userInfo.count,
                "Read-only report collection cannot inspect WC queues, request synchronization, or send a status probe.")
        }

        for alias in [false, true] {
            await run("background_report_write_failure_isolated_\(alias ? "symlink" : "directory")") { f in
                _ = try await self.report(f, "initial observer report exists") { $0["reportSequence"] as? Int != nil }
                let sentinel = f.root.appendingPathComponent("private-sentinel.json")
                let original = Data("unrelated_private_metadata".utf8)
                try original.write(to: sentinel)
                try FileManager.default.removeItem(at: f.backgroundSyncReportURL)
                if alias {
                    try FileManager.default.createSymbolicLink(at: f.backgroundSyncReportURL, withDestinationURL: sentinel)
                } else {
                    try FileManager.default.createDirectory(at: f.backgroundSyncReportURL, withIntermediateDirectories: false)
                }
                let manifest = try f.sealHistorical(1), receipt = try f.receipt(manifest)
                f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
                f.session.hasContentPending = true
                f.bridge.performBackgroundConnectivityTask(id: UUID()) {}
                try await self.eventually("report write failure cannot block a native enqueue") { f.session.state.current.allEnqueued.count == 1 }
                try f.deliver(receipt)
                try await self.eventually("report write failure cannot block actual durable ACK") { f.changes.current == 1 }
                try await self.drainQueuedWork(f)
                try self.check(try Data(contentsOf: sentinel) == original, "Report persistence must not follow an alias or overwrite unrelated metadata.")
                try self.check(try f.watch.hasDurableAcknowledgement(for: manifest), "Diagnostics are independent from the real transfer and durable ACK.")
                try FileManager.default.removeItem(at: f.backgroundSyncReportURL)
                f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
                _ = try await self.report(f, "later observation can persist after diagnostic storage recovers") {
                    $0["fileEnqueuedCount"] as? Int == 1 && $0["durableACKCommittedCount"] as? Int == 1
                        && ($0["reportWriteFailureCount"] as? Int ?? 0) > 0
                }
            }
        }

        await run("expired_waiter_cannot_fence_new_real_opportunity_before_cleanup") { f in
            let value = try f.sealHistorical(1)
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            guard let queue = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "work" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Worker queue missing")
            }
            let entered = Locked(false), gate = DispatchSemaphore(value: 0)
            queue.async { entered.access { $0 = true }; _ = gate.wait(timeout: .now() + 10) }
            try await self.eventually("worker blocked before first task registration") { entered.current }
            let oldID = UUID(), oldDone = Locked(0), newDone = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: oldID) { oldDone.access { $0 += 1 } }
            f.bridge.expireBackgroundConnectivityTask(id: oldID)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { newDone.access { $0 += 1 } }
            gate.signal()
            try await self.eventually("new opportunity completes despite retained expired waiter") { newDone.current == 1 }
            try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id } == [value.id],
                           "A real new live opportunity must reopen bounded admission before expired waiter cleanup.")
            try self.check(oldDone.current == 0, "The expired task's stale completion belongs to its application delegate.")
        }

        for pauseAtAdmission in [false, true] {
            await run("expired_inflight_generation_cannot_admit_using_new_task_permission_\(pauseAtAdmission ? "at_admission" : "early")") { f in
                _ = try (1...12).map(f.sealHistorical)
                f.enableBackgroundRefresh()
                f.bridge.setMaintenanceAllowed(false)
                f.session.hasContentPending = true
                let entered = Locked(false), qualifyingReads = Locked(0), gate = DispatchSemaphore(value: 0)
                f.session.outstandingReadAction.access { action in
                    action = { _ in
                        if pauseAtAdmission {
                            let checked = Mirror(reflecting: f.bridge).children
                                .first(where: { $0.label == "lightCandidatesChecked" })?.value as? Int ?? 0
                            guard checked > 0 else { return }
                            // After candidate validation, the first native read
                            // adopts attempts; the next is the final admission check.
                            guard qualifyingReads.access({ $0 += 1; return $0 }) == 2 else { return }
                        }
                        let pause = entered.access { value -> Bool in
                            guard !value else { return false }; value = true; return true
                        }
                        if pause { _ = gate.wait(timeout: .now() + 10) }
                    }
                }
                let oldID = UUID(), newID = UUID(), oldDone = Locked(0), newDone = Locked(0)
                f.bridge.performBackgroundConnectivityTask(id: oldID) { oldDone.access { $0 += 1 } }
                try await self.eventually("old bounded pass pauses inside native queue inspection") { entered.current }
                f.bridge.expireBackgroundConnectivityTask(id: oldID)
                f.bridge.performBackgroundRefreshTask(id: newID) { newDone.access { $0 += 1 } }
                f.session.outstandingReadAction.access { $0 = nil }
                gate.signal()
                try await self.eventually("new generation finishes bounded preparation") { newDone.current == 1 }
                let events = try f.watch.events()
                let newStart = events.firstIndex { $0.kind == "watch.background_connectivity_started" && $0.detail.contains(newID.uuidString) }
                let firstEnqueue = events.firstIndex { $0.kind == "file_transfer_enqueued" }
                try self.check(newStart != nil && firstEnqueue != nil && newStart! < firstEnqueue!,
                               "The paused expired pass cannot send before the newer task's own worker entry establishes its opportunity.")
                try self.check(f.session.state.current.allEnqueued.count == 2 && oldDone.current == 0,
                               "Only the new bounded generation admits two historical files; the old completion stays expired.")
            }
        }

        await run("expired_generation_cannot_spend_receipt_cooldown_after_native_read") { f in
            _ = try (1...12).map(f.sealHistorical)
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            let entered = Locked(false), gate = DispatchSemaphore(value: 0)
            f.session.userInfoReadAction.access { action in
                action = {
                    guard f.session.state.current.allEnqueued.count == 2 else { return }
                    let pause = entered.access { value -> Bool in
                        guard !value else { return false }; value = true; return true
                    }
                    if pause { _ = gate.wait(timeout: .now() + 10) }
                }
            }
            let oldID = UUID(), newID = UUID(), newDone = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: oldID) {}
            try await self.eventually("old receipt planning pauses during native inspection") { entered.current }
            f.bridge.expireBackgroundConnectivityTask(id: oldID)
            guard let queue = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "work" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Worker queue missing")
            }
            let trafficBeforeNewEntry = Locked<(background: Int, immediate: Int)?>(nil)
            queue.async {
                let state = f.session.state.current
                trafficBeforeNewEntry.access { $0 = (
                    state.userInfo.filter { $0.userInfo[TransportCodec.requestSyncKey] as? Bool == true }.count,
                    state.messages) }
            }
            f.bridge.performBackgroundRefreshTask(id: newID) { newDone.access { $0 += 1 } }
            f.session.userInfoReadAction.access { $0 = nil }
            gate.signal()
            try await self.eventually("new opportunity drains receipt planning") { newDone.current == 1 }
            try self.check(trafficBeforeNewEntry.current?.background == 0 && trafficBeforeNewEntry.current?.immediate == 0,
                           "An expired pass must not spend the receipt cooldown or send on the newer opportunity's permission.")
            try self.check(f.session.state.current.userInfo.filter { $0.userInfo[TransportCodec.requestSyncKey] as? Bool == true }.count == 1
                           && f.session.state.current.messages == 1,
                           "The new task retains its one background and immediate receipt request after the old read is fenced.")
        }

        await run("new_overlapping_tasks_share_fresh_budget_despite_duplicate_old_expiry") { f in
            _ = try (1...12).map(f.sealHistorical)
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            let oldID = UUID(), firstDone = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: oldID) { firstDone.access { $0 += 1 } }
            try await self.eventually("first opportunity fills two history slots") { f.session.state.current.allEnqueued.count == 2 }
            // transferFile becomes visible before its enclosing pass finishes.
            // Complete that pass before simulating ACK-driven refill, so freeing
            // a slot cannot legitimately consume its third enqueue mid-pass.
            try await self.drainQueuedWork(f)
            while !f.session.state.current.files.isEmpty {
                let first = f.session.state.current.files[0]
                try f.deliver(f.receipt(first.manifest!)); f.complete(first)
                try await self.drainQueuedWork(f)
            }
            try self.check(f.session.state.current.allEnqueued.count == 2, "The first opportunity retains its two historical admissions within the bounded candidate budget.")
            guard let queue = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "work" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Worker queue missing")
            }
            let entered = Locked(false), gate = DispatchSemaphore(value: 0)
            queue.async { entered.access { $0 = true }; _ = gate.wait(timeout: .now() + 10) }
            try await self.eventually("worker blocked while expired waiter still registered") { entered.current }
            f.bridge.expireBackgroundConnectivityTask(id: oldID)
            let newDone = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { newDone.access { $0 += 1 } }
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { newDone.access { $0 += 1 } }
            f.bridge.expireBackgroundConnectivityTask(id: oldID)
            f.bridge.expireBackgroundConnectivityTask(id: oldID)
            gate.signal()
            try await self.eventually("new shared opportunity fills its two history slots") { f.session.state.current.allEnqueued.count == 4 }
            try await self.drainQueuedWork(f)
            let second = f.session.state.current.files[0]
            try f.deliver(f.receipt(second.manifest!)); f.complete(second)
            for _ in 0..<20 { f.bridge.resynchronize() }
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.allEnqueued.count == 4 && firstDone.current == 0,
                           "Duplicate old expiry and two overlapping live tasks neither fence the new opportunity nor grant a second budget.")
            f.session.hasContentPending = false
            try await self.eventually("both new live waiters drain once") { newDone.current == 2 }
            try self.check(f.session.state.current.maximumOutstanding == 2,
                           "Replacing an expired opportunity preserves two battery history slots.")
        }

        await run("charging_cold_background_activation_prequeues_twelve_without_foreground") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let values = try (1...12).map(f.seal)
            f.charging.access { $0 = true }
            f.session.activationState = .notActivated
            f.restartBridge(maintenanceAllowed: false)
            f.enableBackgroundRefresh()
            let done = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.drainQueuedWork(f)
            try self.check(done.current == 0 && f.session.state.current.allEnqueued.isEmpty,
                           "Cold charging launch waits for real activation without inventing foreground runtime.")
            f.session.activationState = .activated
            try await self.eventually("cold charged refresh completes local preparation") { done.current == 1 }
            try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id } == values.map(\.id),
                           "One charged system opportunity prepares twelve FIFO candidates without any transport or ACK callback.")
            try self.check(f.feedback.current.isEmpty && (try f.publishedSnapshots()).isEmpty,
                           "No scene, writer observation, or UI state is fabricated by a charged headless launch.")
            try self.check(f.refreshRequests.current.count == 1, "Persistent backlog requests one system successor.")
            let preferredDelay = f.refreshRequests.current[0].timeIntervalSinceNow
            try self.check(preferredDelay > 0 && preferredDelay <= 65,
                           "Charging requests an earlier successor without claiming guaranteed system runtime.")
            for value in values {
                try self.check(try !f.watch.hasDurableAcknowledgement(for: value), "Submission never fabricates an ACK.")
            }
        }

        await run("charging_ack_refill_shares_twelve_enqueue_budget_across_callback_storm") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let values = try (1...24).map(f.seal)
            f.charging.access { $0 = true }
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            let done = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("charged twelve-file handoff") { f.session.state.current.allEnqueued.count == 12 }
            let first = f.session.state.current.files
            // Out-of-order ACK must leave the first durable head in place.
            try f.deliver(f.receipt(values[11]))
            try await self.eventually("later ACK is durable") { try f.watch.hasDurableAcknowledgement(for: values[11]) }
            try self.check(try f.watch.freshTransferSnapshot().head == values[0], "A later ACK does not jump over earlier holes in a twelve-member window.")
            for task in first { f.complete(task) }
            for task in first where task.manifest!.id != values[11].id { try f.deliver(f.receipt(task.manifest!)) }
            for _ in 0..<30 { f.bridge.resynchronize() }
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.allEnqueued.count == 12 && f.session.state.current.maximumOutstanding == 12,
                           "ACK bursts cannot replenish the twelve-enqueue whole-opportunity budget.")
            try self.check(done.current == 0, "Only genuine pending incoming content retains the WC opportunity.")
            f.session.hasContentPending = false
            try await self.eventually("incoming content drained") { done.current == 1 }
        }

        await run("charging_unplug_mid_opportunity_clamps_budget_without_reset") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            _ = try (1...24).map(f.seal)
            f.charging.access { $0 = true }
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            let id = UUID(), done = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: id) { done.access { $0 += 1 } }
            try await self.eventually("charged slots before unplug") { f.session.state.current.allEnqueued.count == 12 }
            f.charging.access { $0 = false }
            let first = f.session.state.current.files
            let receipts = try first.map { try f.receipt($0.manifest!) }
            for task in first { f.complete(task) }
            for receipt in receipts { try f.deliver(receipt) }
            for _ in 0..<15 { f.bridge.resynchronize() }
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.allEnqueued.count == 12,
                           "Unplugging preserves consumed counts and immediately blocks further battery-funded admission.")
            f.bridge.expireBackgroundConnectivityTask(id: id)
            f.charging.access { $0 = true }
            for _ in 0..<15 { f.bridge.resynchronize() }
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.allEnqueued.count == 12 && done.current == 0,
                           "Recharging cannot reopen an expired opportunity; only a new real task may do so.")
        }

        await run("charging_legacy_backlog_fills_twelve_and_keeps_unknown_native_task_blocking") { f in
            _ = try (1...12).map(f.sealHistorical)
            f.charging.access { $0 = true }
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            let done = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("charged legacy bounded preparation completes") { done.current == 1 }
            try self.check(f.session.state.current.files.count == 12 && f.session.state.current.maximumOutstanding == 12,
                           "Historical backlog can register twelve system-owned files while charging without a history-wide audio read.")
            try await self.eventually("charging history requests an early continuation") { !f.refreshRequests.current.isEmpty }
            let preferred = f.refreshRequests.current[0].timeIntervalSinceNow
            try self.check(preferred > 0 && preferred <= 65,
                           "Charging historical backlog requests a one-minute continuation instead of fifteen minutes; scheduling is not delivery.")
            for task in f.session.state.current.files { f.session.removeFromSystemQueue(task) }
            _ = f.session.addLegacyTask(url: f.watch.root.appendingPathComponent("unknown.caf"), metadata: nil)
            let again = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { again.access { $0 += 1 } }
            try await self.eventually("foreign task opportunity completes") { again.current == 1 }
            try self.check(f.session.state.current.allEnqueued.count == 12,
                           "An unknown native task never becomes spare capacity merely because external power is present.")
        }

        for bounded in [true, false] {
            for mode in ["candidate_capacity", "queued_bytes", "source_metadata_race"] {
                await run("charging_history_skips_local_refusal_\(mode)_bounded_\(bounded)") { f in
                    let healthy = try (1...2).map(f.sealHistorical)
                    let rejected = try f.sealHistorical(3, byteCount: mode == "source_metadata_race" ? 4_096 : 17 * 1_024 * 1_024)
                    let rejectedURL = f.watch.audioURL(for: rejected)
                    let original = try FileIdentity(rejectedURL)
                    f.charging.access { $0 = true }
                    if mode == "candidate_capacity" { f.availableCapacity.access { $0 = 32 * 1_024 * 1_024 } }
                    if mode == "queued_bytes" {
                        let original = healthy[0]
                        let queued = SegmentManifest(id: original.id, sessionID: original.sessionID, sequence: original.sequence,
                            startedAt: original.startedAt, endedAt: original.endedAt, sampleRate: original.sampleRate,
                            frameCount: original.frameCount, fileName: original.fileName,
                            byteCount: WatchTransferHandoffPolicy(isCharging: true).maximumQueuedBytes - 16 * 1_024 * 1_024, sha256: original.sha256)
                        _ = f.session.addLegacyTask(url: f.watch.audioURL(for: original), metadata: [
                            TransportCodec.manifestKey: try TransportCodec.encode(queued)])
                    }
                    if mode == "source_metadata_race" {
                        let removed = Locked(false)
                        f.capacityReadAction.access { $0 = {
                            let first = removed.access { old -> Bool in defer { old = true }; return !old }
                            if first { try? FileManager.default.removeItem(at: rejectedURL) }
                        } }
                    }
                    if bounded {
                        f.bridge.setMaintenanceAllowed(false)
                        let done = Locked(0)
                        f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
                        try await self.eventually("local refusal does not consume every historical vacancy") { done.current == 1 }
                    } else {
                        f.update()
                        try await self.eventually("foreground local refusal leaves healthy history eligible") {
                            !f.session.state.current.allEnqueued.isEmpty
                        }
                        try await self.drainQueuedWork(f)
                    }
                    let submitted = f.session.state.current.allEnqueued.compactMap { $0.manifest?.id }
                    try self.check(!submitted.isEmpty && !submitted.contains(rejected.id),
                        "A candidate-local refusal must retain that source while allowing healthy history into real vacancies.")
                    try self.check(Set(submitted).isSubset(of: Set(healthy.map(\.id))) && f.session.state.current.maximumOutstanding <= 12,
                        "Skipping never expands the native count bound or invents a different source.")
                    try self.check(try !f.watch.hasDurableAcknowledgement(for: rejected),
                        "A local admission refusal cannot create a durable receipt or consume the source.")
                    let report = try await self.report(f, "local refusal has a bounded metadata reason") {
                        ($0["admission"] as? [String: Any])?["candidateSkippedCount"] as? Int ?? 0 > 0
                    }
                    let admission = report["admission"] as? [String: Any]
                    let expected = mode == "candidate_capacity" ? "candidateCapacity" : mode == "queued_bytes" ? "queuedBytes" : "source_metadata_unavailable"
                    try self.check(admission?["lastHandoffRefusal"] as? String == expected,
                        "Diagnostics distinguish the actual local refusal from retry backoff, native occupancy and the deadline.")
                    if mode == "source_metadata_race" {
                        try original.data.write(to: rejectedURL)
                        f.capacityReadAction.access { $0 = nil }
                    } else {
                        try self.check(try FileIdentity(rejectedURL) == original,
                            "The refused synthetic source remains byte-for-byte unchanged; admission is metadata-only.")
                    }
                }
            }
        }

        await run("closed_foreground_on_battery_prequeues_twelve_without_ack_callbacks") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let values = try (1...18).map(f.seal)
            try f.watch.closePriorityCapture()
            f.update()
            try await self.eventually("paused foreground prepares twelve files") { f.session.state.current.allEnqueued.count == 12 }
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id } == Array(values.prefix(12)).map(\.id),
                "Closing capture permits a bounded FIFO batch before any charging opportunity.")
            for task in f.session.state.current.files { f.complete(task) }
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.allEnqueued.count == 12, "Transport completion without ACK cannot expand the logical twelve-member window.")
            try self.check(try f.watch.freshTransferSnapshot().head == values[0], "Prequeue and transport completion leave the durable head intact.")
        }

        for mode in ["unknown_capacity", "low_capacity", "deadline_on_first_capacity_read", "deadline_on_final_capacity_read", "native_bytes_full", "native_oversized"] {
            await run("charging_handoff_admission_blocks_\(mode)") { f in
                let values = try (1...16).map(f.sealHistorical)
                f.charging.access { $0 = true }
                f.bridge.setMaintenanceAllowed(false)
                if mode == "unknown_capacity" { f.availableCapacity.access { $0 = nil } }
                if mode == "low_capacity" { f.availableCapacity.access { $0 = 32 * 1_024 * 1_024 - 1 } }
                if mode.hasPrefix("deadline_") {
                    let reads = Locked(0)
                    let target = mode == "deadline_on_first_capacity_read" ? 1 : 2
                    f.capacityReadAction.access { $0 = {
                        let current = reads.access { $0 += 1; return $0 }
                        if current >= target { f.handoffTime.access { $0 = 2 } }
                    } }
                }
                if mode == "native_bytes_full" {
                    let value = values[0]
                    let large = SegmentManifest(id: value.id, sessionID: value.sessionID, sequence: value.sequence,
                        startedAt: value.startedAt, endedAt: value.endedAt, sampleRate: value.sampleRate,
                        frameCount: value.frameCount, fileName: value.fileName, byteCount: WatchTransferHandoffPolicy(isCharging: true).maximumQueuedBytes, sha256: value.sha256)
                    _ = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [TransportCodec.manifestKey: try TransportCodec.encode(large)])
                }
                if mode == "native_oversized" {
                    for value in values.prefix(13) {
                        _ = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [TransportCodec.manifestKey: try TransportCodec.encode(value)])
                    }
                }
                let originalCount = f.session.state.current.files.count
                let done = Locked(0)
                f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
                try await self.eventually("bounded rejected admission releases local WK work") { done.current == 1 }
                try self.check(f.session.state.current.allEnqueued.isEmpty, "Count, byte, space, and elapsed limits are checked before handing any new source to the system.")
                try self.check(f.session.state.current.files.count == originalCount, "Rejected expansion does not cancel or erase existing system-owned tasks.")
                for value in values { try self.check(try !f.watch.hasDurableAcknowledgement(for: value), "A rejected handoff never fabricates an ACK.") }
            }
        }

        await run("bounded_ack_rotation_cancels_every_duplicate_object_without_cross_version_cancel") { f in
            let value = try f.sealHistorical(1)
            let valid = try TransportCodec.encode(value)
            let duplicates = (0..<7).map { _ in f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [TransportCodec.manifestKey: valid]) }
            let differentVersion = SegmentManifest(id: value.id, sessionID: value.sessionID, sequence: value.sequence,
                startedAt: value.startedAt, endedAt: value.endedAt, sampleRate: value.sampleRate,
                frameCount: value.frameCount, fileName: value.fileName, byteCount: value.byteCount + 1, sha256: String(repeating: "f", count: 64))
            let mismatched = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [TransportCodec.manifestKey: try TransportCodec.encode(differentVersion)])
            try f.watch.acknowledge(f.receipt(value))
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            let done = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            for _ in 0..<8 { f.bridge.resynchronize(); try await self.drainQueuedWork(f) }
            try await self.eventually("all native duplicates across rotated groups cancelled") { duplicates.allSatisfy { $0.cancellationCount.current == 1 } }
            for _ in 0..<8 { f.bridge.resynchronize(); try await self.drainQueuedWork(f) }
            try self.check(duplicates.allSatisfy { $0.cancellationCount.current == 1 }, "Same-source duplicates are tracked per native object across inspection groups and never repeatedly cancelled.")
            try self.check(mismatched.cancellationCount.current == 0, "A durable receipt cannot cancel a different manifest version reusing the same segment ID.")
            try self.check(f.session.state.current.files.count == 8 && f.session.state.current.allEnqueued.isEmpty, "Cancellation requests do not manufacture native vacancy.")
            f.session.hasContentPending = false
            try await self.eventually("rotation test releases its WK task") { done.current == 1 }
        }

        let ownerACKAction = Locked<(() -> Void)?>(nil)
        await run("ack_duplicate_cleanup_stops_revoked_pass_foreground_owner", fault: { point in
            guard point == .beforeAcknowledgementSync else { return }
            let action = ownerACKAction.access { current -> (() -> Void)? in defer { current = nil }; return current }
            action?()
        }) { f in
            let values = try (1...4).map(f.sealHistorical)
            let tasks = try values.map { f.session.addLegacyTask(url: f.watch.audioURL(for: $0),
                metadata: [TransportCodec.manifestKey: try TransportCodec.encode($0)]) }
            for value in values { try f.watch.acknowledge(f.receipt(value), pruneAudio: false) }
            f.bridge.setMaintenanceAllowed(true, foreground: true, liveCapture: false)
            f.charging.access { $0 = false }
            guard let queue = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "work" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Production queue missing")
            }
            let reached = Locked(false), observedCancellations = Locked(-1)
            ownerACKAction.access { $0 = {
                f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
                queue.async {
                    observedCancellations.access { $0 = tasks.reduce(0) { $0 + $1.cancellationCount.current } }
                    reached.access { $0 = true }
                }
            } }
            f.bridge.resynchronize()
            try await self.eventually("owner-revoked pass boundary") { reached.current }
            try self.check(observedCancellations.current == 3,
                "After foreground owner withdrawal, an old full scan cannot cancel more than the fresh battery bounded inspection limit.")
        }
        await run("ack_duplicate_cleanup_stops_revoked_pass_bounded_owner_grant") { f in
            let values = try (1...4).map(f.sealHistorical)
            let tasks = try values.map { f.session.addLegacyTask(url: f.watch.audioURL(for: $0),
                metadata: [TransportCodec.manifestKey: try TransportCodec.encode($0)]) }
            for value in values { try f.watch.acknowledge(f.receipt(value), pruneAudio: false) }
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.charging.access { $0 = false }
            guard let queue = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "work" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Production queue missing")
            }
            let entered = Locked(false), reached = Locked(false), observedCancellations = Locked(-1)
            tasks[0].cancellationAction.access { $0 = {
                let first = entered.access { value -> Bool in guard !value else { return false }; value = true; return true }
                guard first else { return }
                f.bridge.setMaintenanceAllowed(true, foreground: true, liveCapture: false)
                queue.async {
                    observedCancellations.access { $0 = tasks.reduce(0) { $0 + $1.cancellationCount.current } }
                    reached.access { $0 = true }
                }
            } }
            f.bridge.resynchronize()
            try await self.eventually("bounded pass with owner grant boundary") { reached.current }
            tasks[0].cancellationAction.access { $0 = nil }
            try self.check(observedCancellations.current == 3,
                "A bounded battery pass cannot expand its already-started inspection scope when a foreground owner arrives.")
        }

        for mode in ["during_ack_sync", "between_duplicates", "new_generation_during_ack_sync"] {
            let ackSyncAction = Locked<(() -> Void)?>(nil), ackSyncReads = Locked(0)
            await run("ack_duplicate_cleanup_stops_revoked_pass_\(mode)", fault: { point in
                guard point == .beforeAcknowledgementSync else { return }
                ackSyncReads.access { $0 += 1 }
                let action = ackSyncAction.access { current -> (() -> Void)? in
                    defer { current = nil }; return current
                }
                action?()
            }) { f in
                let values = try (1...4).map(f.sealHistorical)
                let tasks = try values.map { value in
                    f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                        TransportCodec.manifestKey: try TransportCodec.encode(value)])
                }
                for value in values { try f.watch.acknowledge(f.receipt(value), pruneAudio: false) }
                let originalProofs = try values.map { try FileIdentity(f.ackURL($0)) }
                ackSyncReads.access { $0 = 0 }
                f.charging.access { $0 = true }
                f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
                f.session.hasContentPending = true
                let oldID = UUID(), nextID = UUID(), reachedBoundary = Locked(false)
                let cancellationsAtBoundary = Locked(-1), readsAtBoundary = Locked(-1)
                guard let queue = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "work" })?.value as? DispatchQueue else {
                    throw ProbeFailure.failed("Production bridge serial queue not found")
                }
                let revoke: () -> Void = {
                    f.bridge.expireBackgroundConnectivityTask(id: oldID)
                    if mode == "new_generation_during_ack_sync" {
                        f.bridge.performBackgroundConnectivityTask(id: nextID) {}
                    }
                    // This marker runs after the revoked pass and task registration,
                    // before the newly registered opportunity's own sync closure.
                    queue.async {
                        cancellationsAtBoundary.access { $0 = tasks.reduce(0) { $0 + $1.cancellationCount.current } }
                        readsAtBoundary.access { $0 = ackSyncReads.current }
                        reachedBoundary.access { $0 = true }
                    }
                }
                if mode == "between_duplicates" {
                    tasks[0].cancellationAction.access { $0 = revoke }
                } else { ackSyncAction.access { $0 = revoke } }
                f.bridge.performBackgroundConnectivityTask(id: oldID) {}
                try await self.eventually("revoked duplicate pass reaches serial boundary") { reachedBoundary.current }
                let expectedCancellations = mode == "between_duplicates" ? 1 : 0
                try self.check(cancellationsAtBoundary.current == expectedCancellations,
                    "A revoked duplicate-cleanup pass must not cancel after ACK I/O or borrow a newer execution generation.")
                try self.check(readsAtBoundary.current == 1,
                    "Revocation must stop optional ACK fsync checks before inspecting another duplicate.")
                try self.check(f.session.state.current.files.count == 4 && f.session.state.current.allEnqueued.isEmpty,
                    "Cancellation requests must preserve native occupancy and cannot fabricate refill capacity.")
                for (index, value) in values.enumerated() {
                    try self.check(try FileIdentity(f.ackURL(value)) == originalProofs[index],
                        "Stopping optional cleanup must preserve the exact existing durable ACK bytes.")
                    try self.check(FileManager.default.fileExists(atPath: f.watch.audioURL(for: value).path),
                        "Duplicate cancellation must not prune retained synthetic source files.")
                }
                if mode == "new_generation_during_ack_sync" {
                    try await self.eventually("new opportunity independently resumes durable duplicate cleanup") {
                        tasks.allSatisfy { $0.cancellationCount.current == 1 }
                    }
                }
                tasks[0].cancellationAction.access { $0 = nil }
                f.session.hasContentPending = false
                if mode == "new_generation_during_ack_sync" { f.bridge.expireBackgroundConnectivityTask(id: nextID) }
                try await self.drainQueuedWork(f)
            }
        }

        await run("charging_ack_scan_cancels_positions_four_through_twelve_and_refills_only_actual_vacancies") { f in
            let values = try (1...16).map(f.sealHistorical)
            let tasks = try values.prefix(12).map { value in
                f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(value),
                    "diagnosticEnqueuedAt": Date().timeIntervalSince1970,
                    "fileTransferAttemptID": UUID().uuidString])
            }
            for value in values[3..<12] { try f.watch.acknowledge(f.receipt(value), pruneAudio: false) }
            f.charging.access { $0 = true }
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            let done = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("one charging wake cancels every durable ACK beyond the first three") {
                tasks.dropFirst(3).allSatisfy { $0.cancellationCount.current == 1 }
            }
            try await self.drainQueuedWork(f)
            try self.check(tasks.prefix(3).allSatisfy { $0.cancellationCount.current == 0 },
                           "Unacknowledged first three tasks remain system-owned.")
            try self.check(f.session.state.current.files.count == 12 && f.session.state.current.allEnqueued.isEmpty,
                           "Nine cancel calls cannot create a physical vacancy or a new enqueue.")
            f.complete(tasks[3], error: NSError(domain: "CancelledAcknowledged", code: 1))
            try await self.eventually("one actual native removal admits one replacement") { f.session.state.current.allEnqueued.count == 1 }
            try self.check(f.session.state.current.files.count == 12,
                           "The charging queue remains bounded while the other eight cancellations are still pending.")
            for task in tasks.dropFirst(4) { f.complete(task, error: NSError(domain: "CancelledAcknowledged", code: 1)) }
            try await self.eventually("all remaining eligible history receives the freed capacity") { f.session.state.current.allEnqueued.count == 4 }
            try self.check(Set(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id }) == Set(values.suffix(4).map(\.id)),
                           "Only genuinely unacknowledged new sources refill the actual released slots.")
            try self.check(f.session.state.current.maximumOutstanding == 12,
                           "Neither cancellation callbacks nor refill may exceed the twelve-file charging bound.")
            // Native enqueue happens before the same worker pass commits its
            // retry metadata. Freeze only the fully drained pre-duplicate state.
            try await self.drainQueuedWork(f)
            let saved = try FileIdentity(f.retryURL)
            for task in tasks.dropFirst(3) { f.bridge.session(f.session, didFinish: task, error: NSError(domain: "LateDuplicateCancellation", code: 1)) }
            try await self.drainQueuedWork(f)
            try self.check(try FileIdentity(f.retryURL) == saved, "Late cancellation failures cannot back off already durable acknowledged sources.")
            f.session.hasContentPending = false
            try await self.eventually("charging cancellation opportunity finishes") { done.current == 1 }
        }

        await run("charging_overdue_persistent_refresh_renews_once_after_restart") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            _ = try (1...6).map(f.seal)
            f.charging.access { $0 = true }
            let overdue = Date().addingTimeInterval(-3_600)
            let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
                "preferredDate": overdue.timeIntervalSince1970 * 1_000])
            try bytes.write(to: f.refreshURL)
            f.restartBridge(maintenanceAllowed: false)
            f.enableBackgroundRefresh()
            f.bridge.resynchronize()
            try await self.eventually("overdue continuation is renewed") { f.refreshRequests.current.count == 1 }
            let renewed = f.refreshRequests.current[0]
            try self.check(renewed.timeIntervalSinceNow > 0 && renewed.timeIntervalSinceNow <= 65,
                           "An actual charging execution opportunity renews overdue intent with the shorter preferred interval.")
            for _ in 0..<20 { f.bridge.resynchronize() }
            try await self.drainQueuedWork(f)
            try self.check(f.refreshRequests.current == [renewed], "Repeated callbacks cannot slide the renewed date forward.")
            f.restartBridge(maintenanceAllowed: false)
            f.bridge.resynchronize()
            try await self.eventually("restarted bridge reuses renewed intent") { f.refreshRequests.current.count == 2 }
            try self.check(f.refreshRequests.current == [renewed, renewed], "A second restart retains the renewed durable deadline.")
        }

        for stateName in ["retry", "scheduling", "refresh"] {
            await run("unreadable_\(stateName)_metadata_blocks_admission_preserves_bytes_then_recovers") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                let value = try f.seal(1)
                let url = stateName == "retry" ? f.retryURL : stateName == "scheduling" ? f.schedulingURL : f.refreshURL
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                let marker = url.appendingPathComponent("protected-state-marker")
                try Data("do-not-overwrite".utf8).write(to: marker)
                f.charging.access { $0 = true }
                f.restartBridge(maintenanceAllowed: false)
                f.enableBackgroundRefresh()
                for _ in 0..<15 { f.bridge.resynchronize() }
                try await self.drainQueuedWork(f)
                try self.check(f.session.state.current.allEnqueued.isEmpty && f.refreshRequests.current.count == 1,
                               "Unreadable metadata cannot default to an empty cooldown/order/continuation and admit files.")
                try self.check(f.refreshRequests.current[0].timeIntervalSinceNow > 895,
                               "Unavailable storage requests one standard system recovery opportunity without replacing unreadable disk state.")
                try self.check(try Data(contentsOf: marker) == Data("do-not-overwrite".utf8),
                               "Unavailable metadata remains untouched rather than overwritten by defaults.")
                try self.check(try !f.watch.hasDurableAcknowledgement(for: value), "Metadata failure is never a segment ACK.")
                try FileManager.default.removeItem(at: url)
                if stateName == "retry" {
                    var policy = FileTransferRetryPolicy()
                    policy.noteEnqueued(value)
                    try TransportCodec.encode(policy).write(to: url)
                } else if stateName == "scheduling" {
                    try TransportCodec.encode(FileTransferSchedulingPolicy()).write(to: url)
                }
                f.bridge.resynchronize()
                try await self.drainQueuedWork(f)
                if stateName == "retry" {
                    try self.check(f.session.state.current.allEnqueued.isEmpty,
                                   "Restored persisted retry cooldown remains binding after unavailable storage recovers.")
                } else {
                    try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id } == [value.id],
                                   "The same headless owner resumes automatically when metadata becomes readable.")
                }
            }
        }

        await run("unreadable_metadata_scheduled_opportunity_waits_for_successor_scheduling_result") { f in
            _ = try f.sealHistorical(1)
            try FileManager.default.createDirectory(at: f.retryURL, withIntermediateDirectories: false)
            f.restartBridge(maintenanceAllowed: false)
            f.enableBackgroundRefresh(autoAccept: false)
            let done = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("unavailable-state recovery request reaches scheduler") { f.refreshRequests.current.count == 1 }
            try await self.drainQueuedWork(f)
            try self.check(done.current == 0 && f.session.state.current.allEnqueued.isEmpty,
                           "A scheduled task waits only for successor registration, never audio transport or a fabricated empty state.")
            f.bridge.backgroundRefreshSchedulingCompleted(preferredDate: f.refreshRequests.current[0], succeeded: true)
            try await self.eventually("recovery successor registration releases scheduled task") { done.current == 1 }
            try self.check(f.refreshRequests.current.count == 1, "One unavailable-state opportunity cannot multiply recovery schedules.")
        }

        await run("status_only_activation_failure_foreground_retry_is_bounded") { f in
            f.bridge.setMaintenanceAllowed(false)
            f.session.activationState = .notActivated
            f.bridge.session(f.session, activationDidCompleteWith: .notActivated,
                error: NSError(domain: "WCActivationProbe", code: 7004))
            try await self.drainQueuedWork(f)
            let afterInitialCallbackEvents = try f.watch.events().count
            f.bridge.foregroundDidChange(true)
            try self.check(f.session.activationCalls.current == 1, "The initial five-second cooldown forbids an immediate retry.")
            try await Task.sleep(nanoseconds: 5_100_000_000)
            f.bridge.foregroundDidChange(true)
            try self.check(f.session.activationCalls.current == 2, "A failed initial activation may retry on a later foreground entry.")
            f.bridge.foregroundDidChange(true)
            try self.check(f.session.activationCalls.current == 2, "An activation already in flight cannot start another attempt.")
            try self.check(try f.watch.events().count == afterInitialCallbackEvents,
                           "Foreground activation control itself cannot start repository work.")
            f.session.activationState = .activated
            f.session.isReachable = false
            f.bridge.session(f.session, activationDidCompleteWith: .activated, error: nil)
            try await self.drainQueuedWork(f)
            let afterCompletedCallbackEvents = try f.watch.events().count
            f.bridge.foregroundDidChange(true)
            try self.check(f.session.activationCalls.current == 2, "Activated but unreachable must never trigger activation retries.")
            let url = f.watch.root.appendingPathComponent("ConnectivityDiagnostics/watch.json")
            try await self.eventually("final bounded WC metadata") {
                guard let bytes = try? Data(contentsOf: url), bytes.count <= 4_096,
                      let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
                return value["activationAttemptCount"] as? Int == 2 && value["activationState"] as? Int == 2
                    && (value["lastActivationError"] as? [String: Any])?["code"] as? Int == 7004
            }
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            try self.check(value["delegateMatches"] as? Bool == true && value["foreground"] as? Bool == true,
                           "Metadata must bind to the live delegate and foreground observation.")
            try self.check(try f.watch.events().count == afterCompletedCallbackEvents,
                           "WC-only observation adds no events beyond the separately triggered preexisting activation callback.")
        }
        await run("status_only_metadata_bypasses_blocked_transfer_worker") { f in
            f.bridge.setMaintenanceAllowed(false)
            guard let queue = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "work" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Production transfer worker missing")
            }
            let gate = DispatchSemaphore(value: 0)
            let entered = Locked(false)
            queue.async { entered.access { $0 = true }; _ = gate.wait(timeout: .now() + 8) }
            defer { gate.signal() }
            try await self.eventually("transfer worker blocked") { entered.current }
            let before = f.session.state.current
            f.session.isReachable = false
            f.bridge.foregroundDidChange(true)
            let url = f.watch.root.appendingPathComponent("ConnectivityDiagnostics/watch.json")
            try await self.eventually("metadata writes without transfer worker") {
                guard let bytes = try? Data(contentsOf: url), bytes.count <= 4_096,
                      let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
                return value["trigger"] as? String == "foreground" && value["reachable"] as? Bool == false
            }
            try self.check(f.session.activationCalls.current == 1, "An active unreachable session must not be reactivated.")
            try self.check(f.session.state.current.outstandingReads == before.outstandingReads
                && f.session.state.current.messages == before.messages && f.session.state.current.contexts.count == before.contexts.count,
                "The metadata writer must not inspect transfer queues, send messages, or publish context.")
            try self.check(try f.watch.events().isEmpty, "No event scan or write is initiated by metadata capture.")
        }
        for mode in ["live", "stale", "headless", "malformed", "mixed", "deferred"] {
            await run("status_only_\(mode)_does_not_touch_transfer_or_repository") { f in
                let observation = RecorderSnapshot(state: .paused, sessionID: f.recordingSession.id,
                    observedAt: Date().addingTimeInterval(mode == "stale" ? -600 : 0),
                    pendingCount: 7, pendingCountIsKnown: false)
                let queryCalls = Locked(0)
                if mode != "headless" {
                    f.bridge.onStatusQuery = { completion in
                        queryCalls.access { $0 += 1 }
                        completion(observation)
                    }
                }
                let before = f.session.state.current
                let eventsBefore = try f.watch.events()
                let changedBefore = f.changes.current
                let feedbackBefore = f.feedback.current.count
                let request = RecorderStatusRequest(requestID: UUID())
                let requestData = mode == "malformed" ? Data("{".utf8) : try TransportCodec.encode(request)
                var payload: [String: Any] = [TransportCodec.statusRequestKey: requestData]
                if mode == "mixed" {
                    payload[TransportCodec.requestSyncKey] = true
                    payload[TransportCodec.receiptKey] = Data("invalid synthetic receipt".utf8)
                }
                let replies = Locked<[[String: Any]]>([])
                if mode == "deferred" {
                    f.bridge.session(f.session, didReceiveUserInfo: payload)
                    f.bridge.session(f.session, didReceiveMessage: payload)
                } else {
                    f.bridge.session(f.session, didReceiveMessage: payload, replyHandler: { reply in
                        replies.access { $0.append(reply) }
                    })
                    try await self.eventually("read-only status reply") { replies.current.count == 1 }
                }
                try await self.drainQueuedWork(f)
                if ["live", "stale", "headless"].contains(mode) {
                    guard let data = replies.current[0][TransportCodec.statusResponseKey] as? Data else {
                        throw ProbeFailure.failed("A status response must use the dedicated envelope")
                    }
                    let response = try TransportCodec.decode(RecorderStatusResponse.self, from: data)
                    try self.check(response.schemaVersion == 1 && response.requestID == request.requestID,
                                   "Only the current request identity may be echoed")
                    try self.check(response.snapshot == (mode == "headless" ? nil : observation),
                                   "A stale observation must stay stale; headless must not invent a writer")
                } else if mode != "deferred" {
                    try self.check(replies.current[0].isEmpty, "Malformed/mixed packets must be rejected without processing sync/receipt")
                }
                try self.check(queryCalls.current == (["live", "stale"].contains(mode) ? 1 : 0),
                               "Invalid or noninteractive requests must not query the writer")
                let after = f.session.state.current
                try self.check(after.outstandingReads == before.outstandingReads
                    && after.contextAttempts == before.contextAttempts && after.messages == before.messages
                    && after.userInfo.count == before.userInfo.count && after.allEnqueued.count == before.allEnqueued.count,
                               "Status must not inspect transfer queues, enqueue files/receipts, or publish application context")
                try self.check(try f.watch.events() == eventsBefore && f.changes.current == changedBefore
                    && f.feedback.current.count == feedbackBefore && f.refreshRequests.current.isEmpty,
                               "No repository write, model refresh, owner signal or background request may follow status")
                try self.check(!FileManager.default.fileExists(atPath: f.retryURL.path)
                    && !FileManager.default.fileExists(atPath: f.schedulingURL.path),
                               "No retry/candidate maintenance state should be created")
            }
        }
        for bounded in [false, true] {
            let mode = bounded ? "bounded" : "full"
            await run("fresh_priority_\(mode)_publishes_existing_writer_snapshot") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id,
                                                 nextSequence: 1, newEpoch: true)
                _ = try f.seal(1)
                if bounded { f.bridge.setMaintenanceAllowed(false) }
                let observedAt = Date(timeIntervalSince1970: 1_700_000_100)
                let snapshot = RecorderSnapshot(state: .recording, sessionID: f.recordingSession.id,
                    observedAt: observedAt, lastAudioAt: observedAt,
                    lastSealedAt: observedAt.addingTimeInterval(-1), pendingCount: 7,
                    detail: "Existing writer observation")
                f.bridge.update(snapshot)
                try await self.eventually("fresh head is admitted") {
                    f.session.state.current.allEnqueued.count == 1
                }
                try await self.settle(f)
                guard let data = f.session.state.current.contexts.last?[TransportCodec.snapshotKey] as? Data else {
                    throw ProbeFailure.failed("Fresh priority must publish the existing writer snapshot before returning.")
                }
                let published = try TransportCodec.decode(RecorderSnapshot.self, from: data)
                try self.check(published == WatchDiagnosticTransferPolicy.snapshotForTransfer(snapshot),
                    "Fresh work must preserve writer state, timestamps and cached total instead of substituting its own queue count.")
            }
        }

        for bounded in [false, true] {
            for condition in ["capture_open_without_head", "paused_unresolved_tail", "fresh_state_read_failure"] {
                await run("\(bounded ? "bounded" : "full")_\(condition)_publishes_writer_metadata") { f in
                    try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                    let paused = condition == "paused_unresolved_tail"
                    if paused {
                        try f.watch.beginAudioSegment(OpenAudioSegment(id: UUID(), sessionID: f.recordingSession.id,
                            sequence: 1, startedAt: Date(), sampleRate: 16_000, channelCount: 1,
                            pcmFormat: .int16, interleaved: true, timeZoneIdentifier: nil))
                        try f.watch.closePriorityCapture()
                    } else if condition == "fresh_state_read_failure" {
                        try Data("broken fresh state".utf8).write(to: f.watch.root.appendingPathComponent("fresh-transfer/state.json"))
                    }
                    if bounded { f.bridge.setMaintenanceAllowed(false) }
                    let instant = Date(timeIntervalSince1970: 1_700_000_100)
                    let snapshot = RecorderSnapshot(state: paused ? .paused : .recording,
                        sessionID: f.recordingSession.id, observedAt: instant,
                        lastAudioAt: instant.addingTimeInterval(-1), lastSealedAt: instant.addingTimeInterval(-2),
                        pendingCount: 7, pendingCountIsKnown: false, detail: condition)
                    f.bridge.update(snapshot)
                    try await self.eventually("early return publishes the real writer observation") { f.session.state.current.contexts.count == 1 }
                    try await self.settle(f)
                    try self.check(try f.publishedSnapshots() == [WatchDiagnosticTransferPolicy.snapshotForTransfer(snapshot)], "An open, unresolved or unreadable queue must retain all writer fields and unknown count provenance.")
                    try self.check(f.session.state.current.allEnqueued.isEmpty, "Metadata publication cannot invent a transferable head.")
                }
            }
        }

        await run("bounded_writer_snapshot_skips_corrupt_history_and_events") { f in
            let old = try f.sealHistorical(1)
            let audio = try FileIdentity(f.watch.audioURL(for: old))
            for directory in ["manifests", "events"] {
                try Data("unrelated corrupt history".utf8).write(to: f.watch.root.appendingPathComponent(directory + "/" + UUID().uuidString.lowercased() + ".json"))
            }
            f.bridge.setMaintenanceAllowed(false)
            let snapshot = RecorderSnapshot(state: .recording, sessionID: f.recordingSession.id,
                observedAt: Date(timeIntervalSince1970: 1_700_000_100), pendingCount: 23,
                pendingCountIsKnown: false, detail: "Cached writer count")
            f.bridge.update(snapshot)
            try await self.eventually("cached metadata is sent without decoding corrupt history") { f.session.state.current.contexts.count == 1 }
            try await self.settle(f)
            try self.check(try f.publishedSnapshots() == [WatchDiagnosticTransferPolicy.snapshotForTransfer(snapshot)], "Bounded publication must use cached writer metadata unchanged.")
            try self.check(try FileIdentity(f.watch.audioURL(for: old)) == audio, "Metadata publication must not mutate retained source audio.")
            try self.check(f.session.state.current.maximumOutstanding <= 1, "Snapshot publication must preserve the native admission bound.")
            try self.check(f.issues.current.isEmpty, "Bounded snapshot publication must not decode unrelated malformed manifests or events.")
        }

        await run("full_scan_failure_still_publishes_cached_writer_snapshot") { f in
            try Data("broken historical manifest".utf8).write(to: f.watch.root.appendingPathComponent("manifests/" + UUID().uuidString.lowercased() + ".json"))
            let snapshot = RecorderSnapshot(state: .recording, sessionID: f.recordingSession.id,
                observedAt: Date(timeIntervalSince1970: 1_700_000_100), pendingCount: 9,
                pendingCountIsKnown: false, detail: "Count refresh unavailable")
            f.bridge.update(snapshot)
            try await self.eventually("scan failure cannot hide writer state") { f.session.state.current.contexts.count == 1 }
            try await self.settle(f)
            try self.check(try f.publishedSnapshots() == [WatchDiagnosticTransferPolicy.snapshotForTransfer(snapshot)], "A failed scan cannot promote cached count to verified or refresh the writer timestamp.")
            try self.check(!f.issues.current.isEmpty, "Publishing writer metadata must retain the scan failure report.")
        }

        await run("full_verified_count_survives_bounded_and_identical_writer_refresh") { f in
            _ = try (1...3).map(f.sealHistorical)
            let snapshot = RecorderSnapshot(state: .recording, sessionID: f.recordingSession.id,
                observedAt: Date(timeIntervalSince1970: 1_700_000_100), pendingCount: 99,
                pendingCountIsKnown: false, detail: "Before full count")
            f.bridge.update(snapshot)
            try await self.eventually("full scan publishes its verified total") { f.session.state.current.contexts.count == 1 }
            try await self.settle(f)
            var verified = snapshot
            verified.pendingCount = 3
            verified.pendingCountIsKnown = true
            try self.check(try f.publishedSnapshots() == [WatchDiagnosticTransferPolicy.snapshotForTransfer(verified)], "Only the completed full scan may refine the total and mark it known.")
            f.bridge.setMaintenanceAllowed(false)
            f.bridge.sessionReachabilityDidChange(f.session)
            f.bridge.update(snapshot)
            try await self.settle(f)
            try self.check(try f.publishedSnapshots().allSatisfy { $0 == WatchDiagnosticTransferPolicy.snapshotForTransfer(verified) }, "Runtime updates may repeat but never revert the verified recorder total.")
            var latest = snapshot
            latest.observedAt = latest.observedAt.addingTimeInterval(1)
            latest.pendingCount = 7
            f.bridge.update(latest)
            try await self.eventually("a new writer observation replaces the retained publication candidate") { try f.publishedSnapshots().last?.observedAt == latest.observedAt }
            try self.check(try f.publishedSnapshots().last == WatchDiagnosticTransferPolicy.snapshotForTransfer(latest), "A new writer observation must retain its own count provenance and timestamp.")
        }

        await run("known_only_same_timestamp_transitions_publish_then_deduplicate") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            f.bridge.setMaintenanceAllowed(false)
            var snapshot = RecorderSnapshot(state: .recording, sessionID: f.recordingSession.id,
                observedAt: Date(timeIntervalSince1970: 1_700_000_100), pendingCount: 0,
                pendingCountIsKnown: false, detail: "Same observed instant")
            var expected: [RecorderSnapshot] = []
            for known in [false, true, false] {
                snapshot.pendingCountIsKnown = known
                expected.append(snapshot)
                f.bridge.update(snapshot)
                let count = expected.count
                try await self.eventually("known-only transition is published") { f.session.state.current.contexts.count == count }
                try await self.settle(f)
            }
            for _ in 0..<20 { f.bridge.sessionReachabilityDidChange(f.session) }
            try await self.settle(f)
            try self.check(try f.publishedSnapshots() == expected.map(WatchDiagnosticTransferPolicy.snapshotForTransfer), "Full-payload comparison must preserve known-only changes at the same timestamp and suppress identical retries.")
            try self.check(f.session.state.current.contextAttempts == 3, "Successful duplicate publications must not consume platform calls.")
        }

        for bounded in [false, true] {
            await run("\(bounded ? "bounded" : "full")_snapshot_failure_retries_next_trigger_once") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                if bounded { f.bridge.setMaintenanceAllowed(false) }
                f.session.state.access { $0.remainingContextFailures = 1 }
                let snapshot = RecorderSnapshot(state: .recording, sessionID: f.recordingSession.id,
                    observedAt: Date(timeIntervalSince1970: 1_700_000_100), pendingCount: 4,
                    pendingCountIsKnown: false)
                f.bridge.update(snapshot)
                try await self.eventually("first publication fails") { f.session.state.current.contextAttempts == 1 }
                try await self.settle(f)
                try self.check(f.session.state.current.contexts.isEmpty && f.session.state.current.contextAttempts == 1,
                    "A failed attempt must neither mark the payload published nor retry within the same trigger.")
                f.bridge.resynchronize()
                try await self.eventually("next real trigger retries the payload") { f.session.state.current.contexts.count == 1 }
                try await self.settle(f)
                try self.check(try f.publishedSnapshots() == [WatchDiagnosticTransferPolicy.snapshotForTransfer(snapshot)], "Retry must preserve original writer evidence.")
                let prior = (f.session.state.current.contexts.last?[TransportCodec.watchRuntimeKey] as? Data)
                    .flatMap(WatchRuntimeObservation.decode)
                f.bridge.sessionReachabilityDidChange(f.session)
                try await self.settle(f)
                let after = f.session.state.current
                if after.contextAttempts > 2 {
                    let last = after.contexts.last ?? [:]
                    let next = (last[TransportCodec.watchRuntimeKey] as? Data).flatMap(WatchRuntimeObservation.decode)
                    try self.check(after.contextAttempts == 3 && last[TransportCodec.snapshotKey] == nil
                        && next != nil && prior != nil && !next!.hasSameProgress(as: prior!),
                        "Only changed source diagnostics may add one context after a successful snapshot; unchanged recorder evidence must not replay.")
                }
                f.bridge.sessionReachabilityDidChange(f.session); try await self.settle(f)
                let newest = (f.session.state.current.contexts.last?[TransportCodec.watchRuntimeKey] as? Data)
                    .flatMap(WatchRuntimeObservation.decode)
                let previousRuntime = (after.contexts.last?[TransportCodec.watchRuntimeKey] as? Data)
                    .flatMap(WatchRuntimeObservation.decode)
                try self.check(f.session.state.current.contextAttempts == after.contextAttempts,
                    "Subsequent triggers must deduplicate: before=\(String(describing: previousRuntime)) after=\(String(describing: newest))")
            }
        }

        await run("context_failure_and_later_event_error_do_not_retry_same_trigger") { f in
            try Data("broken historical event".utf8).write(to: f.watch.root.appendingPathComponent("events/" + UUID().uuidString.lowercased() + ".json"))
            f.session.state.access { $0.remainingContextFailures = 2 }
            f.update()
            try await self.eventually("the initial context call fails") { f.session.state.current.contextAttempts == 1 }
            try await self.settle(f)
            try self.check(f.session.state.current.contextAttempts == 1 && f.session.state.current.contexts.isEmpty,
                "The outer synchronization error handler must not immediately retry a failed context call.")
        }

        await run("snapshot_waits_for_activation_without_inventing_headless_state") { f in
            f.bridge.setMaintenanceAllowed(false)
            f.bridge.resynchronize()
            try await self.settle(f)
            try self.check(try f.publishedSnapshots().isEmpty, "A bridge without a writer observation cannot invent an idle snapshot.")
            let initialAttempts = f.session.state.current.contextAttempts
            f.session.activationState = .notActivated
            let snapshot = RecorderSnapshot(state: .recording, sessionID: f.recordingSession.id,
                observedAt: Date(timeIntervalSince1970: 1_700_000_100), pendingCount: 0,
                pendingCountIsKnown: false)
            f.bridge.update(snapshot)
            try await self.settle(f)
            try self.check(f.session.state.current.contextAttempts == initialAttempts, "An inactive WCSession cannot publish the retained writer value.")
            f.session.activationState = .activated
            f.bridge.session(f.session, activationDidCompleteWith: .activated, error: nil)
            try await self.eventually("activation publishes the retained value") { try !f.publishedSnapshots().isEmpty }
            try self.check(try f.publishedSnapshots() == [WatchDiagnosticTransferPolicy.snapshotForTransfer(snapshot)], "Activation may not freshen the original observation time or count provenance.")
        }

        await run("manual_and_activation_recovery_resend_same_snapshot_once") { f in
            _ = try (1...3).map(f.sealHistorical)
            let writer = RecorderSnapshot(state: .paused, sessionID: f.recordingSession.id,
                observedAt: Date(timeIntervalSince1970: 1_700_000_100), pendingCount: 99,
                pendingCountIsKnown: false)
            f.bridge.update(writer)
            try await self.eventually("initial full snapshot published") { f.session.state.current.contexts.count == 1 }
            try await self.settle(f)
            var expected = writer
            expected.pendingCount = 3
            expected.pendingCountIsKnown = true
            f.bridge.setMaintenanceAllowed(false)
            f.bridge.resynchronize()
            try await self.eventually("local explicit recovery resends cached publication") { f.session.state.current.contexts.count == 2 }
            try await self.settle(f)
            f.bridge.session(f.session, didReceiveUserInfo: [TransportCodec.requestSyncKey: true])
            try await self.eventually("phone recovery request resends cached publication") { f.session.state.current.contexts.count == 3 }
            try await self.settle(f)
            f.bridge.session(f.session, activationDidCompleteWith: .activated, error: nil)
            try await self.eventually("successful reactivation resends cached publication") { f.session.state.current.contexts.count == 4 }
            try await self.settle(f)
            for _ in 0..<20 { f.bridge.sessionReachabilityDidChange(f.session) }
            try await self.settle(f)
            try self.check(try f.publishedSnapshots() == Array(repeating: expected, count: 4),
                "Explicit recovery must resend the refined count and original writer time; ordinary triggers must still deduplicate.")
            try self.check(f.session.state.current.contextAttempts == 4, "Each explicit recovery trigger gets exactly one context call.")
        }

        for reachable in [false, true] {
            await run("bounded_fresh_head_replaces_obsolete_receipts_after_real_slot_release_reachable_\(reachable)") { f in
                let history = try f.sealHistorical(1)
                f.session.isReachable = reachable
                let legacy = f.session.transferUserInfo([TransportCodec.requestSyncKey: true])
                let oldExact = f.session.transferUserInfo([TransportCodec.requestSyncKey: true,
                    TransportCodec.targetedReceiptRequestKey: try TransportCodec.encode(TargetedReceiptRequest(manifest: history))])
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
                let head = try f.seal(2)
                let next = try f.seal(3)
                f.bridge.setMaintenanceAllowed(false)
                f.session.hasContentPending = true
                let done = Locked(0)
                f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
                try await self.eventually("obsolete receipt requests are superseded") {
                    legacy.cancellationCount.current == 1 && oldExact.cancellationCount.current == 1
                }
                try await self.drainQueuedWork(f)
                try self.check(f.receiptRequests.count == 2, "Cancel is asynchronous: both old requests still occupy the two receipt slots.")
                try self.check(f.session.state.current.messagePayloads.count == (reachable ? 1 : 0), "Only a reachable session gets one immediate attempt.")
                f.session.removeFromSystemQueue(legacy)
                f.bridge.session(f.session, didFinish: legacy, error: NSError(domain: "WCErrorDomain", code: 7_001))
                try await self.eventually("native completion replans the fresh head without a manual retry") {
                    try f.receiptRequests.contains { try f.requestTarget($0)?.matches(head) == true }
                }
                try self.check(f.receiptRequests.count == 2, "One actual vacancy replaces one obsolete request while leaving the event reservation intact.")
                try self.check(try f.requestTarget(f.receiptRequests.last!)?.matches(head) == true, "The new system-owned request must name the exact fresh head even while unreachable.")
                if !reachable {
                    f.session.isReachable = true
                    f.bridge.sessionReachabilityDidChange(f.session)
                    try await self.eventually("reachability recovery retains its unspent immediate opportunity") { f.session.state.current.messagePayloads.count == 1 }
                }
                f.session.removeFromSystemQueue(oldExact)
                f.bridge.session(f.session, didFinish: oldExact, error: NSError(domain: "WCErrorDomain", code: 7_001))
                for _ in 0..<5 { f.bridge.sessionReachabilityDidChange(f.session) }
                try await self.drainQueuedWork(f)
                try self.check(f.receiptRequests.count == 1, "Repeated callbacks must deduplicate the exact head request after replacement.")
                try self.check(legacy.cancellationCount.current == 1 && oldExact.cancellationCount.current == 1, "Each old native object is cancelled once despite callback reordering.")
                try self.check(try f.requestTarget(f.session.state.current.messagePayloads[0])?.matches(head) == true, "The immediate request must use the same exact plan.")
                try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id } == [head.id, next.id], "Exact requests must not change the bounded admission budget.")
                try self.check(!FileManager.default.fileExists(atPath: f.ackURL(head).path), "Request delivery cannot manufacture a durable ACK.")
                f.session.hasContentPending = false
                try await self.eventually("bounded exact request and transfer complete their opportunity") { done.current == 1 }
                try self.check(try f.watch.events().contains { $0.kind == "watch.background_connectivity_finished" && $0.detail.contains("enqueued=2") }, "Receipt replacement and callback rechecks retain the two-file batch for the entire opportunity.")
            }
        }

        await run("fresh_receipt_replacement_preserves_unknown_packets_and_shared_capacity") { f in
            f.session.isReachable = false
            let legacy = f.session.transferUserInfo([TransportCodec.requestSyncKey: true])
            let mixed = f.session.transferUserInfo([TransportCodec.requestSyncKey: true, "unrecognized": true])
            let unrelated = f.session.transferUserInfo(["other": "retain"])
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let head = try f.seal(1)
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            let done = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("only the known legacy receipt is superseded") { legacy.cancellationCount.current == 1 }
            try self.check(mixed.cancellationCount.current == 0 && unrelated.cancellationCount.current == 0,
                           "Unknown or mixed traffic must not be cancelled to manufacture capacity.")
            try self.check(f.session.state.current.userInfo.count == 3,
                           "The shared bound includes the cancelled object until actual removal.")
            f.session.removeFromSystemQueue(legacy)
            f.bridge.session(f.session, didFinish: legacy, error: nil)
            try await self.eventually("the one real vacancy admits one current exact request") {
                try f.receiptRequests.contains { try f.requestTarget($0)?.matches(head) == true }
            }
            try self.check(f.session.state.current.userInfo.count == 3 && f.receiptRequests.count == 2,
                           "Replacement obeys both the physical shared bound and receipt per-kind allowance.")
            f.session.hasContentPending = false
            try await self.eventually("replacement opportunity ends") { done.current == 1 }
        }

        await run("queued_exact_head_deduplicates_background_without_suppressing_immediate") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let head = try f.seal(1)
            let payload: [String: Any] = [TransportCodec.requestSyncKey: true,
                TransportCodec.targetedReceiptRequestKey: try TransportCodec.encode(TargetedReceiptRequest(manifest: head))]
            f.session.transferUserInfo(payload)
            f.update(); try await self.settle(f)
            try self.check(f.receiptRequests.count == 1, "An identical exact request already owned by the system must not be duplicated.")
            try self.check(f.session.state.current.messagePayloads.count == 1, "Queued background work must not suppress the independent immediate attempt.")
            try self.check(try f.requestTarget(f.session.state.current.messagePayloads[0])?.matches(head) == true, "Immediate retry must preserve exact identity.")
        }

        await run("native_outstanding_metadata_is_exact_fallback_without_history_scan") { f in
            let history = try f.sealHistorical(1)
            // Fill the battery native capacity so this case isolates receipt
            // planning from an otherwise legitimate vacant history-slot scan.
            for _ in 0..<3 {
                _ = f.session.addLegacyTask(url: f.watch.audioURL(for: history), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(history),
                    "diagnosticEnqueuedAt": Date().timeIntervalSince1970])
            }
            f.bridge.setMaintenanceAllowed(false)
            let done = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("native metadata fallback request") { done.current == 1 }
            try self.check(f.receiptRequests.count == 1, "One exact receipt request is sufficient for the native task.")
            try self.check(try f.requestTarget(f.receiptRequests[0])?.matches(history) == true, "The fallback must identify the actual native transfer.")
            try self.check(f.session.state.current.allEnqueued.isEmpty, "An occupied native slot cannot be bypassed by receipt planning.")
            try self.check(try f.watch.events().contains { $0.kind == "watch.background_connectivity_finished" && $0.detail.contains("candidatesChecked=0 enqueued=0") }, "Native request selection must not scan historical candidates when physical slots are occupied.")
        }

        await run("unknown_native_metadata_keeps_legacy_recovery_without_guessing_target") { f in
            _ = f.session.addLegacyTask(url: f.root.appendingPathComponent("unknown-system-file.caf"), metadata: nil)
            f.bridge.setMaintenanceAllowed(false)
            let done = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("unknown native metadata retains legacy request") { done.current == 1 }
            try self.check(f.receiptRequests.count == 1, "Unknown history still needs bounded legacy recovery.")
            try self.check(try f.requestTarget(f.receiptRequests[0]) == nil, "No exact target may be fabricated from an unknown native task.")
            try self.check(f.session.state.current.allEnqueued.isEmpty, "Unknown native tasks still occupy capacity.")
        }

        await run("historical_receipt_rotation_reaches_all_twelve_native_tasks_without_head_ack") { f in
            let sources = try (1...12).map { try f.sealHistorical($0) }
            for source in sources {
                _ = f.session.addLegacyTask(url: f.watch.audioURL(for: source), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(source),
                    "diagnosticEnqueuedAt": Date().timeIntervalSince1970])
            }
            f.bridge.setMaintenanceAllowed(false)
            for index in sources.indices {
                f.session.state.access { $0.userInfo.removeAll() }
                try await self.receiptOpportunity(f)
                try self.check(f.receiptRequests.count == 1, "Each admitted opportunity must emit at most one background request.")
                try self.check(try f.requestTarget(f.receiptRequests[0])?.matches(sources[index]) == true,
                    "A never-acknowledged head must not starve later native receipt identities.")
                try self.check(f.session.state.current.messagePayloads.count == index + 1,
                    "Each opportunity must retain the single independent immediate request limit.")
                try self.check(!FileManager.default.fileExists(atPath: f.ackURL(sources[0]).path),
                    "Selection progress is not acknowledgement authority.")
                f.receiptRequestUptime.access { $0 += BackgroundReceiptRequestPolicy.interval + 1 }
            }
            let lastReceipt = try f.receipt(sources[11])
            try f.deliver(lastReceipt); try await self.drainQueuedWork(f)
            try self.check(try f.watch.hasDurableAcknowledgement(for: sources[11]),
                "A later exact receipt must commit independently while the queue head still has no ACK.")
            try self.check(!FileManager.default.fileExists(atPath: f.ackURL(sources[0]).path),
                "A later receipt must not acknowledge the stalled head.")
            try self.check(f.session.state.current.allEnqueued.isEmpty, "Receipt rotation must never submit another audio transfer.")
        }

        await run("historical_receipt_rotation_cooldown_and_restart_preserve_next_position") { f in
            let sources = try (1...4).map { try f.sealHistorical($0) }
            for source in sources {
                _ = f.session.addLegacyTask(url: f.watch.audioURL(for: source), metadata: [TransportCodec.manifestKey: try TransportCodec.encode(source)])
            }
            f.bridge.setMaintenanceAllowed(false)
            try await self.receiptOpportunity(f)
            let committed = try FileIdentity(f.receiptCursorURL)
            for _ in 0..<4 { try await self.receiptOpportunity(f) }
            try self.check(f.receiptRequests.count == 1 && f.session.state.current.messagePayloads.count == 1,
                "Repeated callbacks inside the cooldown must emit no extra requests.")
            try self.check(try FileIdentity(f.receiptCursorURL) == committed,
                "Cooldown-rejected plans must not advance or rewrite the saved position.")
            f.session.state.access { $0.userInfo.removeAll() }
            f.restartBridge(maintenanceAllowed: false)
            try await self.receiptOpportunity(f)
            try self.check(try f.requestTarget(f.receiptRequests[0])?.matches(sources[1]) == true,
                "A restarted process must continue after the previously requested source.")
            f.receiptRequestUptime.access { $0 += BackgroundReceiptRequestPolicy.interval + 1 }
            try await self.receiptOpportunity(f)
            try self.check(f.receiptRequests.count == 2, "A queued different exact target must not block a later target's bounded request.")
            try self.check(try f.requestTarget(f.receiptRequests[1])?.matches(sources[2]) == true,
                "The next accepted opportunity must continue rotation rather than return to prefix zero.")
            try self.check(f.session.state.current.allEnqueued.isEmpty, "Restart recovery must remain metadata/request only.")
        }

        await run("historical_receipt_rotation_invalid_prefix_cannot_force_legacy_or_starve_tail") { f in
            let tail = try f.sealHistorical(7)
            for index in 0..<6 {
                var data = Data("invalid".utf8)
                if index == 1 || index == 4 {
                    // Decodable SegmentManifest metadata still cannot create
                    // an exact request with an invalid digest or byte count.
                    let invalid = SegmentManifest(id: UUID(), sessionID: tail.sessionID, sequence: index,
                        startedAt: tail.startedAt, endedAt: tail.endedAt, sampleRate: tail.sampleRate,
                        frameCount: tail.frameCount, fileName: "invalid.caf",
                        byteCount: index == 1 ? -1 : tail.byteCount, sha256: index == 4 ? "bad" : tail.sha256)
                    data = try TransportCodec.encode(invalid)
                }
                _ = f.session.addLegacyTask(url: f.root.appendingPathComponent("unknown-\(index).caf"), metadata: [TransportCodec.manifestKey: data])
            }
            _ = f.session.addLegacyTask(url: f.watch.audioURL(for: tail), metadata: [TransportCodec.manifestKey: try TransportCodec.encode(tail)])
            f.bridge.setMaintenanceAllowed(false)
            for _ in 0..<4 {
                if !f.receiptRequests.isEmpty { break }
                try await self.receiptOpportunity(f)
            }
            try self.check(f.receiptRequests.count == 1, "Bounded metadata windows must eventually reach the valid tail.")
            try self.check(try f.requestTarget(f.receiptRequests[0])?.matches(tail) == true,
                "An invalid prefix must not turn a larger modern queue into legacy whole-history recovery.")
            try self.check(f.session.state.current.messagePayloads.count == 1,
                "Skipping invalid metadata must consume no request cooldown or immediate request.")
            try self.check(f.session.state.current.allEnqueued.isEmpty, "Invalid native metadata cannot authorize source resending.")
        }

        await run("historical_receipt_rotation_fresh_head_precedes_hint_and_does_not_advance_it") { f in
            let history = try f.sealHistorical(1)
            _ = f.session.addLegacyTask(url: f.watch.audioURL(for: history), metadata: [TransportCodec.manifestKey: try TransportCodec.encode(history)])
            f.bridge.setMaintenanceAllowed(false)
            try await self.receiptOpportunity(f)
            let position = try FileIdentity(f.receiptCursorURL)
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
            let head = try f.seal(2)
            f.receiptRequestUptime.access { $0 += BackgroundReceiptRequestPolicy.interval + 1 }
            f.session.state.access { $0.userInfo.removeAll() }
            try await self.receiptOpportunity(f)
            try self.check(try f.requestTarget(f.receiptRequests[0])?.matches(head) == true,
                "A fresh FIFO head must override the historical cursor's next identity.")
            try self.check(try FileIdentity(f.receiptCursorURL) == position, "Fresh work must not consume the independent historical position.")
            try self.check(try f.watch.freshTransferSnapshot().head?.id == head.id, "A targeted request must not advance the fresh FIFO.")
        }

        for failure in ["corrupt", "directory", "symlink", "oversized"] {
            await run("historical_receipt_rotation_\(failure)_hint_refuses_history_but_keeps_fresh") { f in
                let history = try f.sealHistorical(1)
                _ = f.session.addLegacyTask(url: f.watch.audioURL(for: history), metadata: [TransportCodec.manifestKey: try TransportCodec.encode(history)])
                let protected = f.root.appendingPathComponent("protected-hint.json")
                try Data("untouched".utf8).write(to: protected)
                switch failure {
                case "directory": try FileManager.default.createDirectory(at: f.receiptCursorURL, withIntermediateDirectories: false)
                case "symlink": try FileManager.default.createSymbolicLink(at: f.receiptCursorURL, withDestinationURL: protected)
                case "oversized": try Data(repeating: 32, count: 4_097).write(to: f.receiptCursorURL)
                default: try Data("invalid-json".utf8).write(to: f.receiptCursorURL)
                }
                f.bridge.setMaintenanceAllowed(false)
                try await self.receiptOpportunity(f)
                try self.check(f.receiptRequests.isEmpty && f.session.state.current.messagePayloads.isEmpty,
                    "An unreadable/corrupt hint must not reset rotation or issue legacy replay.")
                try self.check(!FileManager.default.fileExists(atPath: f.ackURL(history).path), "Hint failure must preserve ACK authority.")
                try self.check(try Data(contentsOf: protected) == Data("untouched".utf8), "No hint operation may follow a symbolic link.")
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
                let head = try f.seal(2)
                try await self.receiptOpportunity(f)
                try self.check(f.receiptRequests.count == 1, "A broken historical hint must not block fresh exact recovery.")
                try self.check(try f.requestTarget(f.receiptRequests[0])?.matches(head) == true, "Fresh recovery must preserve its real manifest identity.")
            }
        }

        await run("historical_receipt_rotation_failed_hint_commit_does_not_spend_request_cooldown") { f in
            let history = try f.sealHistorical(1)
            _ = f.session.addLegacyTask(url: f.watch.audioURL(for: history), metadata: [TransportCodec.manifestKey: try TransportCodec.encode(history)])
            let original = Data("{\"schemaVersion\":1,\"nextNativeOffset\":0}".utf8)
            try original.write(to: f.receiptCursorURL)
            let blocked = Locked(false)
            f.session.userInfoReadAction.access { action in
                action = {
                    let cursor = Mirror(reflecting: f.bridge).children.first { $0.label == "historicalReceiptCursor" }?.value
                    guard let cursor, String(describing: cursor) != "nil", !blocked.current else { return }
                    blocked.access { $0 = true }
                    try? FileManager.default.removeItem(at: f.receiptCursorURL)
                    try? FileManager.default.createDirectory(at: f.receiptCursorURL, withIntermediateDirectories: false)
                }
            }
            f.bridge.setMaintenanceAllowed(false)
            try await self.receiptOpportunity(f)
            try self.check(blocked.current, "The fault must occur after real cursor loading and before its commit.")
            try self.check(f.receiptRequests.isEmpty && f.session.state.current.messagePayloads.isEmpty,
                "Failed cursor persistence must emit no request and consume neither request opportunity.")
            f.session.userInfoReadAction.access { $0 = nil }
            try FileManager.default.removeItem(at: f.receiptCursorURL)
            try original.write(to: f.receiptCursorURL)
            try await self.receiptOpportunity(f)
            try self.check(f.receiptRequests.count == 1 && f.session.state.current.messagePayloads.count == 1,
                "Repair at the same uptime must retain both unconsumed request opportunities.")
            try self.check(try f.requestTarget(f.receiptRequests[0])?.matches(history) == true,
                "A failed cursor write cannot skip the exact source that still needs recovery.")
            try self.check(f.session.state.current.allEnqueued.isEmpty, "Hint retry cannot add audio traffic.")
        }

        await run("historical_receipt_rotation_real_atomic_write_failure_keeps_position_and_cooldown") { f in
            let history = try f.sealHistorical(1)
            _ = f.session.addLegacyTask(url: f.watch.audioURL(for: history), metadata: [TransportCodec.manifestKey: try TransportCodec.encode(history)])
            try Data("{\"schemaVersion\":1,\"nextNativeOffset\":0}".utf8).write(to: f.receiptCursorURL)
            let original = try FileIdentity(f.receiptCursorURL)
            // The real Data.atomic rename must fail, rather than substituting a
            // synthetic error or preventing the preceding successful hint read.
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: f.receiptCursorURL.path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: f.receiptCursorURL.path) }
            f.bridge.setMaintenanceAllowed(false)
            try await self.receiptOpportunity(f)
            try self.check(f.receiptRequests.isEmpty && f.session.state.current.messagePayloads.isEmpty,
                "An actual atomic hint-write failure must emit no background or immediate request.")
            try self.check(try FileIdentity(f.receiptCursorURL) == original,
                "The failed atomic replacement must preserve the exact prior hint.")
            let retainedError = Mirror(reflecting: f.bridge).children.first { $0.label == "lastHistoricalReceiptCursorError" }
                .flatMap { Mirror(reflecting: $0.value).children.first?.value as? String }
            try self.check(retainedError?.isEmpty == false,
                "The production failure path must retain its error instead of silently resetting; headless journal filtering remains unchanged.")
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: f.receiptCursorURL.path)
            try await self.receiptOpportunity(f)
            try self.check(f.receiptRequests.count == 1 && f.session.state.current.messagePayloads.count == 1,
                "The same uptime must still admit both requests after actual storage repair.")
            try self.check(try f.requestTarget(f.receiptRequests[0])?.matches(history) == true,
                "Actual write failure must not skip the source or request legacy history.")
            try self.check(f.session.state.current.allEnqueued.isEmpty, "Storage recovery must not send another audio file.")
        }

        for mode in ["completed", "preempted", "obsolete"] {
            await run("\(mode)_callback_resolves_current_fresh_head_before_request_cooldown") { f in
                let history = try f.sealHistorical(1)
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
                let head = try f.seal(2)
                let oldAttempt = UUID().uuidString
                let task = WCSessionFileTransfer(fileURL: f.watch.audioURL(for: history), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(history),
                    "diagnosticEnqueuedAt": Date().addingTimeInterval(-60).timeIntervalSince1970,
                    "fileTransferAttemptID": oldAttempt])
                if mode == "preempted" {
                    let epoch = try f.watch.freshTransferSnapshot().headEpochID!
                    try f.watch.persistPreemptionIntent(FileTransferPreemptionIntent(manifest: history,
                        attemptID: oldAttempt, epochID: epoch, freshHeadID: head.id))
                } else if mode == "obsolete" {
                    var retry = FileTransferRetryPolicy()
                    retry.noteEnqueued(history, attemptID: UUID().uuidString)
                    try TransportCodec.encode(retry).write(to: f.retryURL)
                    f.restartBridge()
                }
                f.bridge.setMaintenanceAllowed(false)
                f.bridge.session(f.session, didFinish: task, error: nil)
                try await self.settle(f)
                try self.check(f.receiptRequests.count == 1, "The callback must defer to one unified request plan.")
                try self.check(try f.requestTarget(f.receiptRequests[0])?.matches(head) == true, "An old callback must not consume the opportunity with legacy or obsolete identity.")
                try self.check(try f.watch.freshTransferSnapshot().head?.id == head.id, "Transport callbacks and request planning cannot advance the FIFO.")
                try f.deliver(f.receipt(history)); try await self.settle(f)
                try self.check(try f.watch.hasDurableAcknowledgement(for: history), "A valid late historical ACK must remain accepted despite a different current exact target.")
                try self.check(try f.watch.freshTransferSnapshot().head?.id == head.id, "An old ACK cannot advance the unrelated fresh head.")
            }
        }

        let failIntent = Locked(true)
        await run("intent_persistence_failure_never_cancels_then_retry_is_exact", fault: { point in
            if case .beforePreemptionIntentCommit = point, failIntent.current { throw ProbeFailure.failed("Synthetic intent write failure") }
        }) { f in
            let old = try f.sealHistorical(1); f.update()
            try await self.eventually("history queued before intent failure") { f.session.state.current.files.count == 1 }
            let task = f.session.state.current.files[0]
            let original = try FileIdentity(f.watch.audioURL(for: old))
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
            let fresh = try f.seal(2); f.update(); try await self.settle(f)
            try self.check(task.cancellationCount.current == 0, "Failed durable intent prohibits cancel.")
            try self.check(f.session.state.current.allEnqueued.count == 1, "No physical vacancy can be assumed after failed intent.")
            failIntent.access { $0 = false }; f.update()
            try await self.eventually("successful durable intent permits one cancellation") { task.cancellationCount.current == 1 }
            let key = task.file.metadata!["fileTransferAttemptID"] as! String
            try self.check(try f.watch.preemptionIntent(attemptID: key)?.freshHeadID == fresh.id, "Intent must name exact fresh head and old attempt.")
            try self.check(try FileIdentity(f.watch.audioURL(for: old)) == original, "Intent and cancellation never mutate old source.")
        }

        await run("restart_replays_exact_preemption_and_late_callbacks_do_not_mutate_retry") { f in
            _ = try f.sealHistorical(1); f.update()
            try await self.eventually("old native task exists") { f.session.state.current.files.count == 1 }
            let oldTask = f.session.state.current.files[0]
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
            let fresh = try f.seal(2); f.update()
            try await self.eventually("first process persists yield") { oldTask.cancellationCount.current == 1 }
            f.restartBridge(); f.update()
            try await self.eventually("restart revalidates source and repeats same attempt cancel") { oldTask.cancellationCount.current == 2 }
            f.session.removeFromSystemQueue(oldTask); f.update()
            try await self.eventually("fresh head follows native removal") { f.session.state.current.files.first?.manifest?.id == fresh.id }
            try await self.settle(f)
            let saved = try FileIdentity(f.retryURL)
            f.bridge.session(f.session, didFinish: oldTask, error: nil)
            f.bridge.session(f.session, didFinish: oldTask, error: NSError(domain: "LateOldCancellation", code: 1))
            try await self.settle(f)
            try self.check(try FileIdentity(f.retryURL) == saved, "Old exact-intent success/failure cannot change current retry bookkeeping.")
            try self.check(try f.watch.freshTransferSnapshot().head?.id == fresh.id, "Cancelled historical callbacks do not advance fresh head.")
            try self.check(!FileManager.default.fileExists(atPath: f.ackURL(fresh).path), "Preemption callback cannot manufacture ACK.")
        }

        await run("legacy_without_stable_attempt_identity_waits_without_preemption") { f in
            let old = try f.sealHistorical(1)
            let task = f.session.addLegacyTask(url: f.watch.audioURL(for: old), metadata: [TransportCodec.manifestKey: try TransportCodec.encode(old)])
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
            _ = try f.seal(2); f.update(); try await self.settle(f)
            try self.check(task.cancellationCount.current == 0, "An object pointer is not a persistent cancellation identity.")
            try self.check(f.session.state.current.allEnqueued.isEmpty, "Unidentifiable actual native task still owns the slot.")
        }

        await run("headless_restart_cannot_treat_intent_as_audio_hash_certificate") { f in
            let old = try f.sealHistorical(1); f.update()
            try await self.eventually("historical task initially exists") { f.session.state.current.files.count == 1 }
            let task = f.session.state.current.files[0]
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
            let fresh = try f.seal(2); f.update()
            try await self.eventually("historical yield initially requested") { task.cancellationCount.current == 1 }
            WCSession.default = f.session
            f.bridge = WatchTransferBridge(repository: f.watch, maintenanceAllowed: false)
            f.installCallbacks()
            let done = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("headless restart finishes bounded metadata work") { done.current == 1 }
            try self.check(task.cancellationCount.current == 1, "Persisted intent alone cannot certify source bytes after restart.")
            try self.check(f.session.state.current.allEnqueued.count == 1, "The actual old task continues blocking new file admission.")
            try self.check(FileManager.default.fileExists(atPath: f.watch.audioURL(for: old).path), "Unconfirmed historical source stays present.")
            try self.check(try f.watch.freshTransferSnapshot().head?.id == fresh.id, "The unsent fresh head remains intact.")
        }

        let headGate = DispatchSemaphore(value: 0)
        let headEntered = Locked(false)
        await run("background_arrival_during_fresh_head_scan_shares_sixtyfour_closed_backlog_check_budget", fault: { point in
            if case .beforeFreshHeadCommit = point {
                let first = headEntered.access { value -> Bool in if value { return false }; value = true; return true }
                if first, headGate.wait(timeout: .now() + 10) != .success { throw ProbeFailure.failed("Head gate timed out") }
            }
        }) { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let manifests = try (1...80).map(f.seal)
            for manifest in manifests { try f.watch.acknowledge(f.receipt(manifest), pruneAudio: true) }
            try f.watch.closePriorityCapture()
            f.update()
            try await self.eventually("full head scan paused within first ACK transition") { headEntered.current }
            let done = Locked(0)
            f.session.hasContentPending = true
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            headGate.signal()
            try await self.settle(f)
            f.session.hasContentPending = false
            try await self.eventually("interrupted fresh scan drains WK opportunity") { done.current == 1 }
            let data = try Data(contentsOf: f.watch.root.appendingPathComponent("fresh-transfer/state.json"))
            let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try self.check(state["head"] as? Int == 64, "Full-to-WK handoff may advance at most sixty-four exact ACK heads in one opportunity.")
            try self.check(f.session.state.current.allEnqueued.isEmpty, "Budget exhaustion must not restore historical admission.")
            try self.check(try f.watch.events().contains { $0.kind == "watch.background_connectivity_finished" && $0.detail.contains("candidatesChecked=64 enqueued=0") }, "Whole opportunity must account for overlapping full work.")
        }

        await run("failed_eighth_fresh_candidate_consumes_shared_wk_budget") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let manifests = try (1...9).map(f.seal)
            for manifest in manifests.prefix(7) { try f.watch.acknowledge(f.receipt(manifest), pruneAudio: true) }
            let damagedEntry = f.watch.root.appendingPathComponent("fresh-transfer/" + manifests[7].id.uuidString.lowercased() + ".json")
            try Data("synthetic-invalid-candidate".utf8).write(to: damagedEntry)
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            let done = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.settle(f)
            for _ in 0..<3 {
                f.bridge.sessionReachabilityDidChange(f.session)
                try await self.settle(f)
            }
            f.session.hasContentPending = false
            try await self.eventually("failed-candidate opportunity drains after repeated callbacks") { done.current == 1 }
            try self.check(try f.watch.events().contains { $0.kind == "watch.background_connectivity_finished" && $0.detail.contains("candidatesChecked=8 enqueued=0") }, "A thrown eighth read must remain charged across all callbacks in the same WK opportunity.")
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: f.watch.root.appendingPathComponent("fresh-transfer/state.json"))) as! [String: Any]
            try self.check(state["head"] as? Int == 7, "Only seven exact ACKs can advance before the damaged eighth candidate.")
            try self.check(f.session.state.current.allEnqueued.isEmpty, "Exhausted failed-read budget cannot admit a later or historical file.")
            try self.check(!FileManager.default.fileExists(atPath: f.ackURL(manifests[7]).path), "A failed candidate read is never ACK evidence.")
        }

        for mode in ["fresh", "historical"] {
            await run("wk_arrival_inside_\(mode)_native_enqueue_shares_bounded_batch") { f in
                if mode == "fresh" {
                    try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                }
                _ = try (1...3).map { mode == "fresh" ? try f.seal($0) : try f.sealHistorical($0) }
                let done = Locked(0)
                f.session.fileEnqueueAction.access { $0 = {
                    f.session.fileEnqueueAction.access { $0 = nil }
                    f.session.hasContentPending = true
                    f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
                } }
                f.update()
                try await self.eventually("full enqueue overlaps new WK registration") { f.session.state.current.allEnqueued.count == (mode == "fresh" ? 3 : 2) }
                try await self.settle(f)
                let first = f.session.state.current.files[0]
                try f.deliver(f.receipt(first.manifest!))
                f.complete(first)
                try await self.settle(f)
                try self.check(f.session.state.current.allEnqueued.count == 3, "An ACK and actual queue removal cannot exceed three total registrations inside the overlapping WK opportunity.")
                f.session.hasContentPending = false
                try await self.eventually("overlapping enqueue opportunity finishes") { done.current == 1 }
                try self.check(try f.watch.events().contains { $0.kind == "watch.background_connectivity_finished" && $0.detail.contains("enqueued=3") }, "The native enqueue that overlaps WK registration must be charged exactly once.")
                try self.check(f.session.state.current.maximumOutstanding == (mode == "fresh" ? 3 : 2), "Whole-opportunity accounting must preserve the physical fresh/history slot limits.")
                f.update()
                try await self.eventually("later explicit owner signal permits ordinary refill") { f.session.state.current.allEnqueued.count == 3 }
            }
        }

        await run("pipeline_transport_completions_and_restart_do_not_release_more_than_three_unacknowledged_members") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let values = try (1...7).map(f.seal)
            let source = try FileIdentity(f.watch.audioURL(for: values[0]))
            f.update()
            try await self.eventually("initial three-member pipeline fills") { f.session.state.current.allEnqueued.count == 3 }
            try await self.settle(f)
            try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id } == Array(values.prefix(3)).map(\.id), "Initial native submissions follow committed seal order.")
            for task in f.session.state.current.files { f.complete(task) }
            try await self.settle(f)
            try self.check(f.session.state.current.allEnqueued.count == 3, "Three transport successes without receipts cannot expand the logical window.")
            f.restartBridge(); f.update(); try await self.settle(f)
            try self.check(f.session.state.current.allEnqueued.count == 3, "Persisted delivery backoff survives restart without replay or sending a fourth unacknowledged member.")
            try f.deliver(f.receipt(values[2]))
            try await self.eventually("out-of-order durable ACK admits the next member") { f.session.state.current.allEnqueued.count == 4 }
            try self.check(f.session.state.current.allEnqueued.last?.manifest?.id == values[3].id, "Only the next sealed member may fill the released logical slot.")
            try self.check(try f.watch.freshTransferSnapshot().head == values[0], "A later durable ACK cannot move the head across earlier holes.")
            try self.check(try FileIdentity(f.watch.audioURL(for: values[0])) == source, "An unacknowledged head retains its exact original source.")
            try self.check(f.session.state.current.maximumOutstanding == 3, "Neither callbacks nor restart exceed three native attempts.")
        }

        for mode in ["unchanged", "progress_resumed", "source_corrupt", "bounded"] {
            await run("fresh_stall_recovery_\(mode)_preserves_source_and_actual_queue") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                let value = try f.seal(1)
                let initial = f.recoveryTime.current
                let task = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(value),
                    "diagnosticEnqueuedAt": initial.date.addingTimeInterval(-3 * 60 * 60).timeIntervalSince1970,
                    "fileTransferAttemptID": UUID().uuidString
                ])
                if mode == "source_corrupt" { try Data(repeating: 219, count: 4_096).write(to: f.watch.audioURL(for: value)) }
                let preserved = try FileIdentity(f.watch.audioURL(for: value))
                if mode == "bounded" { f.bridge.setMaintenanceAllowed(false) }
                f.update(); try await self.settle(f)
                try self.check(task.cancellationCount.current == 0, "An old enqueue timestamp alone cannot trigger cancellation without local idle observation.")
                if mode == "progress_resumed" { task.progress.completedUnitCount = 25; task.isTransferring = true }
                f.recoveryTime.access { $0 = (initial.date.addingTimeInterval(1_801), initial.uptime + 1_801) }
                f.update(); try await self.settle(f)
                try self.check(task.cancellationCount.current == 0, "The idle candidate first retains its native attempt while its exact ACK request gets a reply opportunity.")
                f.recoveryTime.access { $0 = (initial.date.addingTimeInterval(1_862), initial.uptime + 1_862) }
                f.update(); try await self.settle(f)
                try self.check(task.cancellationCount.current == (mode == "unchanged" ? 1 : 0), "Only a fully verified unchanged source with a genuinely observed idle attempt can be cancelled; progress and bounded execution remain protected.")
                try self.check(f.session.state.current.allEnqueued.isEmpty, "A cancellation request never creates physical vacancy or an immediate replacement attempt.")
                try self.check(f.session.state.current.files.count == 1, "The native task remains counted until actual system removal.")
                try self.check(try FileIdentity(f.watch.audioURL(for: value)) == preserved, "Watchdog and failed source verification leave exact local bytes intact.")
                try self.check(!FileManager.default.fileExists(atPath: f.ackURL(value).path), "Stall recovery never invents a phone ACK.")
                try self.check(try f.watch.freshTransferSnapshot().head == value, "Stall cancellation cannot advance the durable head.")
                if mode == "unchanged" {
                    f.bridge.resynchronize(); try await self.settle(f)
                    try self.check(task.cancellationCount.current == 1, "Repeated triggers do not repeatedly cancel one attempt.")
                    try self.check(try f.watch.events().contains { $0.kind == "file_stalled_transfer_cancel_requested" }, "Fresh-owned stalled attempts now reach the production recovery path.")
                }
            }
        }

        await run("fresh_three_member_pipeline_sends_all_eleven_in_seal_order_and_preserves_ack_head") { f in
            let history = try (1...4).map(f.sealHistorical)
            let originals = try history.map { try FileIdentity(f.watch.audioURL(for: $0)) }
            f.update()
            try await self.eventually("one historical task enqueued") { f.session.state.current.allEnqueued.count == 2 }
            let oldTasks = f.session.state.current.files
            let old = oldTasks[0]
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 5, newEpoch: true)
            f.update(); try await self.settle(f)
            try self.check(old.cancellationCount.current == 0, "Starting capture cannot cancel history before a durable fresh seal.")
            let fresh = try (5...15).map(f.seal)
            f.update()
            try await self.eventually("historical attempt yields after durable fresh head") { oldTasks.allSatisfy { $0.cancellationCount.current == 1 } }
            try self.check(f.session.state.current.allEnqueued.count == 2, "Cancel request cannot free the native slot.")
            for old in oldTasks { f.complete(old, error: NSError(domain: "PriorityCancelled", code: 1)) }
            for (index, manifest) in fresh.enumerated() {
                try await self.eventually("fresh head \(index) enters single native slot") {
                    f.session.state.current.files.first?.manifest?.id == manifest.id
                }
                try await self.settle(f)
                let task = f.session.state.current.files[0]
                let count = f.session.state.current.allEnqueued.count
                f.complete(task); try await self.settle(f)
                try self.check(f.session.state.current.allEnqueued.count == count, "Transport didFinish cannot advance the fresh FIFO head.")
                try f.deliver(f.receipt(manifest))
            }
            try await self.settle(f)
            try self.check(f.session.state.current.allEnqueued.dropFirst(2).compactMap { $0.manifest?.id } == fresh.map(\.id),
                           "All eleven fresh entries, including middle entries, must transmit in seal order.")
            try self.check(f.session.state.current.files.isEmpty, "Open capture with no current head cannot refill history.")
            try f.watch.closePriorityCapture(); f.update()
            try await self.eventually("closed and drained fresh FIFO restores two history tasks") { f.session.state.current.files.count == 2 }
            try self.check(history.contains(f.session.state.current.files[0].manifest!), "History resumes only after close plus exact ACK drain.")
            try self.check(f.session.state.current.maximumOutstanding == 3, "The pipeline holds at most three native audio tasks while ACKs independently preserve FIFO head.")
            for (manifest, original) in zip(history, originals) {
                try self.check(try FileIdentity(f.watch.audioURL(for: manifest)) == original, "Preemption never prunes historical source bytes.")
            }
        }

        await run("three_legacy_tasks_yield_durably_but_all_count_until_removed") { f in
            let history = try (1...5).map(f.sealHistorical)
            let tasks = try history.prefix(3).map { manifest in
                f.session.addLegacyTask(url: f.watch.audioURL(for: manifest), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(manifest),
                    "diagnosticEnqueuedAt": Date().addingTimeInterval(-600).timeIntervalSince1970,
                    "fileTransferAttemptID": UUID().uuidString
                ])
            }
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 6, newEpoch: true)
            let fresh = try f.seal(6); f.update()
            try await self.eventually("three exact attempts have durable cancellation requests") { tasks.allSatisfy { $0.cancellationCount.current == 1 } }
            for task in tasks {
                let identity = task.file.metadata!["fileTransferAttemptID"] as! String
                try self.check(try f.watch.preemptionIntent(attemptID: identity)?.manifest == task.manifest, "Every cancelled attempt requires durable exact-manifest intent.")
            }
            try self.check(f.session.state.current.allEnqueued.isEmpty, "All old native tasks still consume admission.")
            for task in tasks.prefix(2) { f.session.removeFromSystemQueue(task); f.update(); try await self.settle(f) }
            try self.check(f.session.state.current.allEnqueued.isEmpty, "One remaining legacy task blocks single-flight admission.")
            f.session.removeFromSystemQueue(tasks[2]); f.update()
            try await self.eventually("fresh head admitted after actual queue empties") { f.session.state.current.allEnqueued.count == 1 }
            try self.check(f.session.state.current.files[0].manifest?.id == fresh.id, "The durable fresh FIFO head owns the next task.")
            try self.check(f.session.state.current.maximumOutstanding == 3, "Upgrade never adds to an oversized legacy queue.")
        }

        await run("twelve_legacy_tasks_preempt_through_tail_then_admit_fresh_only_after_actual_removal") { f in
            let history = try (1...12).map(f.sealHistorical)
            let sources = try history.map { try FileIdentity(f.watch.audioURL(for: $0)) }
            let tasks = try history.map { value in
                f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(value),
                    "diagnosticEnqueuedAt": Date().timeIntervalSince1970,
                    "fileTransferAttemptID": UUID().uuidString])
            }
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 13, newEpoch: true)
            let head = try f.seal(13)
            f.update()
            try await self.eventually("production preemption certifies and cancels all twelve native tasks") {
                tasks.allSatisfy { $0.cancellationCount.current == 1 }
            }
            for task in tasks {
                let key = task.file.metadata!["fileTransferAttemptID"] as! String
                let intent = try f.watch.preemptionIntent(attemptID: key)
                try self.check(intent?.manifest == task.manifest && intent?.freshHeadID == head.id,
                               "Every cancelled tail task needs its exact persisted source and current head binding.")
            }
            try self.check(f.session.state.current.allEnqueued.isEmpty, "Cancellation of twelve tasks does not yet grant admission.")
            for task in tasks.prefix(11) { f.complete(task, error: NSError(domain: "PriorityCancelled", code: 1)) }
            try await self.settle(f)
            try self.check(f.session.state.current.allEnqueued.isEmpty && f.session.state.current.files.count == 1,
                           "Even the final old tail task blocks mixing epochs until it truly leaves.")
            f.complete(tasks[11], error: NSError(domain: "PriorityCancelled", code: 1))
            try await self.eventually("the exact fresh head enters after the last old task leaves") {
                f.session.state.current.files.first?.manifest?.id == head.id
            }
            try self.check(f.session.state.current.allEnqueued.count == 1,
                           "Completion coalescing schedules the head once rather than replaying cancelled history.")
            for (value, source) in zip(history, sources) {
                try self.check(try FileIdentity(f.watch.audioURL(for: value)) == source, "Tail preemption never modifies or deletes unacknowledged source bytes.")
                try self.check(try !f.watch.hasDurableAcknowledgement(for: value), "Native cancellation cannot create a durable ACK.")
            }
        }

        await run("queue_removal_before_callback_has_persisted_nonsliding_grace") { f in
            let manifest = try f.sealHistorical(1)
            let original = try FileIdentity(f.watch.audioURL(for: manifest))
            let oldTime = Date().addingTimeInterval(-600)
            let identity = UUID().uuidString
            let task = f.session.addLegacyTask(url: f.watch.audioURL(for: manifest), metadata: [
                TransportCodec.manifestKey: try TransportCodec.encode(manifest),
                "diagnosticEnqueuedAt": oldTime.timeIntervalSince1970,
                "fileTransferAttemptID": identity
            ])
            var seed = FileTransferRetryPolicy()
            seed.noteEnqueued(manifest, attemptID: identity, at: oldTime)
            try TransportCodec.encode(seed).write(to: f.retryURL)
            f.restartBridge()
            f.update()
            try await self.settle(f)
            f.session.removeFromSystemQueue(task)
            f.bridge.resynchronize()
            try await self.eventuallyOnBridgeQueue(f, "disappearance grace persisted") {
                try f.watch.events().contains { $0.kind == "file_transfer_disappeared_grace" }
            }
            try await self.settle(f)
            let persisted = try FileIdentity(f.retryURL)
            try self.check(f.session.state.current.allEnqueued.isEmpty, "An expired enqueue deadline cannot bypass first disappearance grace.")
            f.restartBridge()
            for _ in 0..<5 { f.update(); f.bridge.resynchronize() }
            try await self.settle(f)
            try self.check(try FileIdentity(f.retryURL) == persisted, "Restart and repeated sync must not extend or rewrite disappearance grace.")
            f.bridge.session(f.session, didFinish: task, error: nil)
            try await self.eventuallyOnBridgeQueue(f, "delayed matching completion accepted") {
                try f.watch.events().contains { $0.kind == "file_delivered_waiting_ack" }
            }
            try await self.settle(f)
            try self.check(f.session.state.current.allEnqueued.isEmpty, "A delayed callback within grace must not create a duplicate transfer.")
            try self.check(try FileIdentity(f.watch.audioURL(for: manifest)) == original, "A completion callback must retain exact audio.")
            try self.check(!FileManager.default.fileExists(atPath: f.ackURL(manifest).path), "Grace or delivery is not a durable ACK.")
        }

        await run("expired_grace_recovers_and_obsolete_callbacks_cannot_override_new_attempt") { f in
            let manifest = try f.sealHistorical(1)
            let original = try FileIdentity(f.watch.audioURL(for: manifest))
            let oldTime = Date().addingTimeInterval(-600)
            let oldIdentity = UUID().uuidString
            let oldTask = WCSessionFileTransfer(fileURL: f.watch.audioURL(for: manifest), metadata: [
                TransportCodec.manifestKey: try TransportCodec.encode(manifest),
                "diagnosticEnqueuedAt": oldTime.timeIntervalSince1970,
                "fileTransferAttemptID": oldIdentity
            ])
            var seed = FileTransferRetryPolicy()
            seed.noteEnqueued(manifest, attemptID: oldIdentity, at: oldTime)
            seed.recordDisappearedTransfers(outstandingIDs: [], at: Date().addingTimeInterval(-120))
            try TransportCodec.encode(seed).write(to: f.retryURL)
            f.restartBridge()
            f.update()
            try await self.eventually("expired finite grace re-enqueues once") { f.session.state.current.allEnqueued.count == 1 }
            try await self.settle(f)
            let currentTask = f.session.state.current.files[0]
            let persisted = try FileIdentity(f.retryURL)
            f.bridge.session(f.session, didFinish: oldTask, error: nil)
            f.bridge.session(f.session, didFinish: oldTask, error: NSError(domain: "SyntheticOldCallback", code: 1))
            try await self.settle(f)
            try self.check(try FileIdentity(f.retryURL) == persisted, "Old success/failure must not alter the new attempt or its retry deadline.")
            try self.check(f.feedback.current.last?.awaitingConfirmationCount == 0, "An obsolete success must not mark the current task delivered.")
            f.restartBridge()
            f.bridge.session(f.session, didFinish: oldTask, error: nil)
            f.bridge.session(f.session, didFinish: oldTask, error: NSError(domain: "SyntheticOldCallback", code: 2))
            try await self.settle(f)
            try self.check(try FileIdentity(f.retryURL) == persisted, "Persisted attempt identity must reject stale callbacks after restart.")
            try await self.eventually("every rejected obsolete callback is diagnosable") {
                (try? f.watch.events().filter { $0.kind == "file_transfer_obsolete_callback" }.count == 4) == true
            }
            try self.check(f.issues.current.isEmpty, "Obsolete failures must not show a failure for the current task.")
            f.complete(currentTask)
            try await self.eventually("current callback still accepted") {
                // This predicate polls while the production event writer is
                // active. A transient incomplete directory view is not yet
                // the requested event; a lasting error still times out.
                (try? f.watch.events().contains { $0.kind == "file_delivered_waiting_ack" }) == true
            }
            try self.check(try FileIdentity(f.watch.audioURL(for: manifest)) == original, "Neither stale nor current delivery can prune unacknowledged audio.")
            try self.check(f.changes.current == 0, "Callbacks alone cannot claim a durable receipt.")
        }

        await run("background_arrival_interrupts_running_full_sync_without_resetting_budget_twice") { f in
            _ = try (1...20).map(f.seal)
            let gate = DispatchSemaphore(value: 0)
            f.session.contextGate.access { $0 = gate }
            f.update()
            try await self.eventually("full maintenance entered context step") { f.session.contextGateEntered.current }
            let done = Locked(0)
            f.session.hasContentPending = true
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            gate.signal()
            try await self.eventually("in-flight maintenance switches to bounded fill") { f.session.state.current.allEnqueued.count == 3 }
            try await self.settle(f)
            try self.check(f.session.state.current.allEnqueued.count == 3,
                           "The pre-registration light pass and task registration must share the three-enqueue budget.")
            try self.check(f.session.outstandingUserInfoTransfers.allSatisfy { transfer in
                guard let data = transfer.userInfo[TransportCodec.eventsKey] as? Data else { return true }
                return WatchDiagnosticTransferPolicy.transferableBatch(from: data)?.allSatisfy { WatchTransferDiagnostic.parse($0) != nil } == true
            },
                           "Revoked full maintenance can forward current typed diagnostics but cannot scan or transmit historical events.")
            f.session.hasContentPending = false
            try await self.eventually("interrupted full scan opportunity drains") { done.current == 1 }
        }

        for mode in ["manifest", "ack", "manifest_validation", "ack_identity"] {
            await run("history_candidate_scan_damage_falls_back_\(mode)") { f in
                let damaged = try f.sealHistorical(1), healthy = try f.sealHistorical(2)
                _ = try f.watch.refreshTransferCandidates()
                let index = f.watch.root.appendingPathComponent("transfer-candidates.ids")
                let ready = f.watch.root.appendingPathComponent("transfer-candidates.ready")
                let originalIndex = try FileIdentity(index), originalReady = try FileIdentity(ready)
                let damagedURL = mode.hasPrefix("manifest")
                    ? f.watch.root.appendingPathComponent("manifests/" + damaged.id.uuidString.lowercased() + ".json")
                    : f.ackURL(damaged)
                let validBytes = mode.hasPrefix("manifest") ? try Data(contentsOf: damagedURL) : nil
                if mode == "manifest_validation" {
                    var object = try JSONSerialization.jsonObject(with: validBytes!) as! [String: Any]
                    object["sampleRate"] = 0
                    try JSONSerialization.data(withJSONObject: object).write(to: damagedURL)
                } else if mode == "ack_identity" {
                    try TransportCodec.encode(SegmentReceipt(segmentID: damaged.id, sha256: String(repeating: "0", count: 64),
                        byteCount: damaged.byteCount)).write(to: damagedURL)
                } else { try Data("{synthetic damaged metadata".utf8).write(to: damagedURL) }
                let damagedBytes = try FileIdentity(damagedURL)
                defer {
                    if let validBytes { try? validBytes.write(to: damagedURL) }
                    else { try? FileManager.default.removeItem(at: damagedURL) }
                }
                f.update()
                try await self.eventually("healthy source survives unrelated damaged history") {
                    f.session.state.current.allEnqueued.compactMap { $0.manifest?.id } == [healthy.id]
                }
                try await self.drainQueuedWork(f)
                try self.check(try FileIdentity(index) == originalIndex && FileIdentity(ready) == originalReady,
                    "A failed full scan cannot publish a partial complete candidate baseline; bounded traversal keeps the original index.")
                try self.check(try FileIdentity(damagedURL) == damagedBytes,
                    "Per-source fallback preserves the original damaged evidence instead of repairing or deleting it.")
                try self.check(f.session.state.current.maximumOutstanding == 1,
                    "Foreground fallback uses the existing bounded battery queue limit.")
                try self.check(f.feedback.current.last?.phase == .failed && !f.issues.current.isEmpty,
                    "Useful partial transfer must retain an explicit failure and cannot present a completed full-library count.")
                try self.check(!FileManager.default.fileExists(atPath: f.ackURL(healthy).path),
                    "Healthy handoff does not create a receipt or acknowledge the damaged neighbour.")
                try self.check(FileManager.default.fileExists(atPath: f.watch.audioURL(for: damaged).path),
                    "The damaged source's synthetic audio remains untouched.")
                try self.check(try f.watch.events().contains { $0.kind == "file_transfer_candidate_scan_deferred" },
                    "The narrow fallback remains distinguishable from a complete successful catalogue scan.")
            }
        }

        for mode in ["directory_permission", "candidate_index_write"] {
            await run("history_candidate_scan_global_failure_does_not_fallback_\(mode)") { f in
                let healthy = try f.sealHistorical(1)
                _ = try f.watch.refreshTransferCandidates()
                let index = f.watch.root.appendingPathComponent("transfer-candidates.ids")
                let directory = f.watch.root.appendingPathComponent("manifests")
                let originalIndex = try FileIdentity(index)
                if mode == "directory_permission" {
                    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
                } else {
                    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: index.path)
                }
                defer {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                    try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: index.path)
                }
                f.update()
                try await self.drainQueuedWork(f)
                try self.check(f.session.state.current.allEnqueued.isEmpty,
                    "Global directory or candidate-index write failure must not be downgraded into usable partial-library evidence.")
                try self.check(try FileIdentity(index) == originalIndex,
                    "A global failure preserves the existing candidate baseline.")
                try self.check(try !f.watch.events().contains { $0.kind == "file_transfer_candidate_scan_deferred" },
                    "Only classified per-source evidence damage may enter bounded fallback.")
                try self.check(!FileManager.default.fileExists(atPath: f.ackURL(healthy).path),
                    "A failed full scan cannot fabricate an ACK.")
            }
        }

        await run("headless_index_bootstrap_skips_corrupt_history_and_event_decoding") { f in
            f.bridge.setMaintenanceAllowed(false)
            for _ in 0..<100 {
                let id = UUID().uuidString.lowercased()
                try Data("corrupt historical metadata".utf8).write(to: f.watch.root.appendingPathComponent("manifests/" + id + ".json"))
                try Data("corrupt event".utf8).write(to: f.watch.root.appendingPathComponent("events/" + id + ".json"))
            }
            let latest = try f.seal(1)
            let done = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("bounded headless task completes") { done.current == 1 }
            try self.check(f.session.state.current.allEnqueued.map { $0.manifest?.id } == [latest.id],
                           "The latest tail hint must be sent despite unrelated corrupt history/events.")
            try self.check(f.feedback.current.isEmpty && (try f.publishedSnapshots()).isEmpty,
                           "Headless maintenance cannot publish a fabricated snapshot or rescan UI state.")
            try self.check(f.session.outstandingUserInfoTransfers.allSatisfy { transfer in
                guard let data = transfer.userInfo[TransportCodec.eventsKey] as? Data else { return true }
                return WatchDiagnosticTransferPolicy.transferableBatch(from: data)?.allSatisfy { WatchTransferDiagnostic.parse($0) != nil } == true
            },
                           "A bounded wake can forward newly observed safe metadata without decoding historical events.")
            // Remove synthetic corruption before the harness's normal final checks.
            for directory in ["manifests", "events"] {
                for url in try FileManager.default.contentsOfDirectory(at: f.watch.root.appendingPathComponent(directory), includingPropertiesForKeys: nil) {
                    if (try? Data(contentsOf: url)) == Data("corrupt historical metadata".utf8)
                        || (try? Data(contentsOf: url)) == Data("corrupt event".utf8) { try FileManager.default.removeItem(at: url) }
                }
            }
            let events = try f.watch.events()
            try self.check(events.contains { $0.kind == "transfer_candidate_index_bootstrap" && $0.detail.contains("filenames=101") },
                           "Filename-only bootstrap cost and count must remain explicit.")
            try self.check(events.contains { $0.kind == "watch.background_connectivity_finished" && $0.detail.contains("candidatesChecked=8 enqueued=1") },
                           "The whole wake must keep the eight-candidate/one-enqueue budget.")
        }

        await run("active_owner_ack_burst_stays_bounded_for_entire_background_task") { f in
            let manifests = try (1...20).map(f.seal)
            let receipt = try f.receipt(manifests[0])
            let done = Locked(0)
            f.session.hasContentPending = true
            // Fixture defaults to maintenanceAllowed=true. The WK opportunity
            // still overrides that permission synchronously.
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("first bounded fill") { f.session.state.current.allEnqueued.count == 3 }
            for _ in 0..<30 {
                try f.deliver(receipt)
                f.bridge.sessionReachabilityDidChange(f.session)
            }
            try await self.settle(f)
            try self.check(f.session.state.current.allEnqueued.count == 3, "Callback storms cannot multiply the per-opportunity enqueue budget.")
            try self.check(try f.watch.hasDurableAcknowledgement(for: manifests[0]), "Every valid ACK still reaches durable exact-ID processing.")
            try self.check(f.changes.current == 1, "Identical ACK replay cannot manufacture repository changes.")
            f.session.hasContentPending = false
            try await self.eventually("ACK burst drains") { done.current == 1 }
            f.bridge.sessionReachabilityDidChange(f.session)
            try await self.settle(f)
            try self.check(f.session.state.current.allEnqueued.count == 3, "Task completion alone cannot launch deferred full maintenance.")
            try self.check(try f.publishedSnapshots().isEmpty, "No full history snapshot is published during the receive cycle.")
        }

        await run("bounded_historical_outstanding_task_retains_retry_observation") { f in
            let value = try f.sealHistorical(1)
            let original = try FileIdentity(f.watch.audioURL(for: value))
            let native = f.session.addLegacyTask(url: f.watch.audioURL(for: value), metadata: [
                TransportCodec.manifestKey: try TransportCodec.encode(value),
                "diagnosticEnqueuedAt": Date().timeIntervalSince1970,
                "fileTransferAttemptID": UUID().uuidString
            ])
            f.bridge.setMaintenanceAllowed(false)
            f.bridge.resynchronize()
            try await self.drainQueuedWork(f)
            try self.check(self.retryWake(f) != nil,
                           "An outstanding historical task must retain a future in-process observation without a new delegate callback.")
            try await self.fireRetryWake(f)
            try self.check(self.retryWake(f) != nil,
                           "An observation that finds the same occupied slot must install its successor.")
            try self.check(f.session.state.current.allEnqueued.isEmpty && native.cancellationCount.current == 0,
                           "An observation timer cannot replace or cancel the actual occupied native slot.")
            try self.check(try FileIdentity(f.watch.audioURL(for: value)) == original,
                           "Retry observation preserves the exact unacknowledged source.")
        }

        await run("background_decision_three_native_slots_are_observation_only_and_private") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let values = try (1...4).map(f.seal)
            f.update()
            try await self.eventually("three native fresh slots exist before the background opportunity") {
                f.session.state.current.files.count == 3
            }
            try await self.drainQueuedWork(f)
            let originals = try values.map { try FileIdentity(f.watch.audioURL(for: $0)) }
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            let done = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("native occupancy diagnostic completes bounded preparation") { done.current == 1 }
            let decisions = try f.watch.events().filter { $0.kind == "watch.background_transfer_decision" }
            try self.check(decisions.count == 1, "One real background opportunity emits one decision event.")
            let event = decisions[0]
            try self.check(event.detail.contains("reason=native_occupied ")
                           && event.detail.contains("observedNative=3 nativeSample=3 nativeZeroProgress=3 nativeFinishedProgress=0"),
                           "Three unfinished zero-progress native tasks must explain the occupied admission without claiming network activity.")
            try self.check(event.detail.contains("enqueued=0 scheduledTasks=1") && event.sessionID == nil,
                           "Decision metadata must distinguish a scheduled task from native submission and omit session identity.")
            try self.check(!event.detail.lowercased().contains(f.recordingSession.id.uuidString.lowercased())
                           && !event.detail.contains(f.watch.root.path)
                           && values.allSatisfy { !event.detail.lowercased().contains($0.id.uuidString.lowercased()) },
                           "The decision cannot contain recording IDs, a session ID or audio paths.")
            try self.check(f.session.state.current.allEnqueued.count == 3
                           && f.session.state.current.files.allSatisfy { $0.cancellationCount.current == 0 },
                           "Observing a full native window cannot enqueue, cancel or manufacture room.")
            for (value, original) in zip(values, originals) {
                try self.check(try FileIdentity(f.watch.audioURL(for: value)) == original,
                               "Diagnostic sampling must retain every unacknowledged source unchanged.")
            }
        }

        await run("background_decision_foreign_native_task_is_not_an_empty_slot") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let value = try f.seal(1)
            let foreign = f.session.addLegacyTask(url: f.root.appendingPathComponent("opaque-native-task"), metadata: nil)
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            let done = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("foreign native task decision finishes") { done.current == 1 }
            let events = try f.watch.events().filter { $0.kind == "watch.background_transfer_decision" }
            try self.check(events.count == 1 && events[0].detail.contains("reason=foreign_native ")
                           && events[0].detail.contains("observedForeignPresent=1"),
                           "An opaque system task must be explained as foreign, without decoding or naming it in diagnostics.")
            try self.check(f.session.state.current.allEnqueued.isEmpty && foreign.cancellationCount.current == 0,
                           "Diagnostics cannot cancel an unknown task or admit an overlapping source.")
            try self.check(try !f.watch.hasDurableAcknowledgement(for: value), "A diagnostic is not a durable receipt.")
        }

        await run("background_decision_retry_backoff_keeps_source_and_attempt") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let value = try f.seal(1)
            var retry = FileTransferRetryPolicy()
            retry.recordDelivery(of: value, at: Date())
            try TransportCodec.encode(retry).write(to: f.retryURL)
            f.restartBridge()
            let original = try FileIdentity(f.watch.audioURL(for: value))
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            let done = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("persisted ACK wait decision finishes") { done.current == 1 }
            let events = try f.watch.events().filter { $0.kind == "watch.background_transfer_decision" }
            try self.check(events.count == 1 && events[0].detail.contains("reason=retry_backoff ")
                           && events[0].detail.contains("lastCandidateEligible=0"),
                           "A future persisted receipt retry must be distinguished from native occupancy.")
            try self.check(f.session.state.current.allEnqueued.isEmpty && f.session.state.current.files.isEmpty,
                           "Explaining retry backoff cannot shorten it or enqueue an attempt.")
            try self.check(try FileIdentity(f.watch.audioURL(for: value)) == original
                           && !f.watch.hasDurableAcknowledgement(for: value),
                           "A retry decision retains exact audio and does not create an ACK.")
        }

        await run("background_decision_sixtyfour_closed_backlog_ack_checks_exhaust_candidate_budget") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let values = try (1...80).map(f.seal)
            for value in values { try f.watch.acknowledge(f.receipt(value), pruneAudio: true) }
            try f.watch.closePriorityCapture()
            let proof = try FileIdentity(f.ackURL(values[64]))
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            let done = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("bounded ACK prefix decision finishes") { done.current == 1 }
            let events = try f.watch.events().filter { $0.kind == "watch.background_transfer_decision" }
            try self.check(events.count == 1 && events[0].detail.contains("reason=candidate_budget ")
                           && events[0].detail.contains("candidateBudget=0"),
                           "An exhausted sixty-four-check opportunity must not be mistaken for an empty recording library.")
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: f.watch.root.appendingPathComponent("fresh-transfer/state.json"))) as! [String: Any]
            try self.check(state["head"] as? Int == 64 && f.session.state.current.allEnqueued.isEmpty,
                           "Decision recording cannot scan a sixty-fifth member or invent an enqueue.")
            try self.check(try FileIdentity(f.ackURL(values[64])) == proof, "Diagnostic recording must not rewrite existing receipt proof.")
        }

        await run("background_decision_success_reports_submission_without_claiming_ack") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let value = try f.seal(1)
            let original = try FileIdentity(f.watch.audioURL(for: value))
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            let done = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("bounded fresh submission decision finishes") { done.current == 1 }
            let events = try f.watch.events().filter { $0.kind == "watch.background_transfer_decision" }
            try self.check(events.count == 1 && events[0].detail.contains("reason=enqueued ")
                           && events[0].detail.contains("enqueued=1 scheduledTasks=1"),
                           "A successful local native submission must remain distinguishable from system delivery.")
            try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id } == [value.id],
                           "The observation preserves the one-enqueue opportunity budget.")
            try self.check(try FileIdentity(f.watch.audioURL(for: value)) == original
                           && !f.watch.hasDurableAcknowledgement(for: value),
                           "Task completion and its decision event cannot acknowledge or prune original audio.")
        }

        await run("scheduled_refresh_fresh_backlog_is_bounded_and_finishes_before_incoming_drains") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let values = try (1...12).map(f.seal)
            let original = try FileIdentity(f.watch.audioURL(for: values[0]))
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            let done = Locked(0)
            let started = Date()
            f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("scheduled refresh completes bounded local work") { done.current == 1 }
            try self.check(f.session.hasContentPending, "A scheduled refresh must finish without holding the task for incoming content or outgoing transport.")
            try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id } == Array(values.prefix(3)).map(\.id),
                           "A scheduled battery opportunity admits a bounded three-file FIFO batch.")
            try self.check(f.refreshRequests.current.count == 1, "The observed persistent fresh backlog requests one system successor.")
            let date = f.refreshRequests.current[0]
            try self.check(date.timeIntervalSince(started) >= 899 && date.timeIntervalSince(started) <= 903,
                           "The preferred refresh is fifteen minutes away, not a claimed immediate wake.")
            try self.check(f.feedback.current.isEmpty && (try f.publishedSnapshots()).isEmpty,
                           "Headless application refresh cannot create recorder UI state or start full history maintenance.")
            try self.check(try FileIdentity(f.watch.audioURL(for: values[0])) == original && !FileManager.default.fileExists(atPath: f.ackURL(values[0]).path),
                           "A scheduling acceptance or file submission never acknowledges or alters source audio.")
            try self.check(try f.watch.events().contains { $0.kind == "watch.background_connectivity_finished" && $0.detail.contains("candidatesChecked=3 enqueued=3") },
                           "Application refresh uses the same accounted eight-candidate/three-enqueue ceiling.")
        }

        await run("scheduled_refresh_intent_survives_restart_without_postponing_single_system_request") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            _ = try (1...5).map(f.seal)
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            f.bridge.resynchronize()
            try await self.eventually("first persisted refresh request") { f.refreshRequests.current.count == 1 }
            try await self.drainQueuedWork(f)
            let date = f.refreshRequests.current[0]
            let persisted = try FileIdentity(f.refreshURL)
            for _ in 0..<30 { f.bridge.resynchronize() }
            try await self.drainQueuedWork(f)
            try self.check(f.refreshRequests.current == [date], "Repeated callbacks must not replace the single accepted system request.")
            try self.check(try FileIdentity(f.refreshURL) == persisted, "Coalescing must not rewrite durable scheduling intent.")
            f.restartBridge(); f.bridge.setMaintenanceAllowed(false); f.bridge.resynchronize()
            try await self.eventually("relaunch reconfirms original preferred date") { f.refreshRequests.current.count == 2 }
            try self.check(f.refreshRequests.current == [date, date], "A relaunched process preserves the original deadline rather than pushing it into the future.")
            try self.check(try FileIdentity(f.refreshURL) == persisted, "Relaunch reads rather than replaces pending intent.")
        }

        await run("scheduled_refresh_and_connectivity_overlap_share_budget_and_distinct_completion_rules") { f in
            _ = try (1...20).map(f.sealHistorical)
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            let refreshDone = Locked(0), connectivityDone = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { connectivityDone.access { $0 += 1 } }
            f.bridge.performBackgroundRefreshTask(id: UUID()) { refreshDone.access { $0 += 1 } }
            try await self.eventually("application-only work drains") { refreshDone.current == 1 }
            try self.check(connectivityDone.current == 0, "The incoming WC task remains owned until its content drains.")
            try self.check(try !f.watch.events().contains { $0.kind == "watch.background_transfer_decision" },
                           "Completing only the refresh subset cannot publish shared-opportunity counters as final.")
            try self.check(f.session.state.current.allEnqueued.count == 2, "Overlapping task types cannot multiply the shared wake budget and two history slots.")
            try await self.fireRetryWake(f)
            try self.check(self.retryWake(f) != nil && f.session.state.current.allEnqueued.count == 2,
                           "An occupied or exhausted wake keeps a later retry without another admission.")
            f.session.hasContentPending = false
            try await self.eventually("connectivity finally drains") { connectivityDone.current == 1 }
            try self.check(f.feedback.current.isEmpty, "Neither task completion reopens full foreground maintenance.")
            try self.check(try f.watch.events().filter { $0.kind == "watch.background_transfer_decision" }.count == 1,
                           "Overlapping refresh and WC task completions must not duplicate shared-opportunity diagnostics.")
            try self.check(try f.watch.events().contains {
                $0.kind == "watch.background_transfer_decision"
                    && $0.detail.contains("completionStage=opportunity_drained")
                    && $0.detail.contains("incomingPending=false")
            }, "The final diagnostic must identify its completed shared opportunity and the actual incoming drain.")
        }

        await run("background_decision_registration_ahead_of_worker_defers_final_sample") { f in
            _ = try f.sealHistorical(1)
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            let firstDone = Locked(0), nextDone = Locked(0), registered = Locked(false)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { firstDone.access { $0 += 1 } }
            try await self.eventually("first task holds its incoming opportunity") {
                f.session.state.current.allEnqueued.count == 1
            }
            try await self.drainQueuedWork(f)
            f.session.outstandingReadAction.access { action in
                action = { _ in
                    let insert = registered.access { value -> Bool in
                        if value { return false }; value = true; return true
                    }
                    if insert {
                        f.bridge.performBackgroundConnectivityTask(id: UUID()) { nextDone.access { $0 += 1 } }
                    }
                }
            }
            f.session.hasContentPending = false
            try await self.eventually("the queued second registration and both task drains finish") {
                firstDone.current == 1 && nextDone.current == 1
            }
            let events = try f.watch.events()
            let decisions = events.filter { $0.kind == "watch.background_transfer_decision" }
            try self.check(registered.current && decisions.count == 1,
                           "An already registered but not yet worker-owned waiter shares one final diagnostic.")
            let starts = events.filter { $0.kind == "watch.background_connectivity_started" }
            try self.check(starts.count == 2 && starts.allSatisfy { $0.timestamp <= decisions[0].timestamp },
                           "A final diagnostic must follow both registered waiters' worker entry, not the earlier subset completion.")
            try self.check(f.session.state.current.allEnqueued.count == 1,
                           "Late worker entry cannot reset the shared one-enqueue budget.")
        }

        await run("scheduled_refresh_waits_for_scheduling_result_and_rejects_stale_completion") { f in
            _ = try f.sealHistorical(1)
            f.enableBackgroundRefresh(autoAccept: false)
            f.bridge.setMaintenanceAllowed(false)
            let id = UUID(), done = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: id) { done.access { $0 += 1 } }
            try await self.eventually("system scheduling request becomes pending") { f.refreshRequests.current.count == 1 }
            try await self.drainQueuedWork(f)
            try self.check(done.current == 0, "A refresh keeps ownership until its successor request receives an acceptance/failure result.")
            let date = f.refreshRequests.current[0]
            f.bridge.backgroundRefreshSchedulingCompleted(preferredDate: date.addingTimeInterval(1), succeeded: true)
            try await self.drainQueuedWork(f)
            try self.check(done.current == 0, "A mismatched scheduling result cannot release the current task.")
            f.bridge.backgroundRefreshSchedulingCompleted(preferredDate: date, succeeded: false)
            try await self.eventually("failed scheduling also releases task") { done.current == 1 }
            f.bridge.resynchronize(); try await self.drainQueuedWork(f)
            try self.check(f.refreshRequests.current.count == 1 && self.retryWake(f) != nil,
                           "Failure has an in-process retry and cooldown, never a tight system scheduling loop.")
            try self.check(try !f.watch.hasDurableAcknowledgement(for: f.watch.manifests()[0]),
                           "Failed or stale system scheduling callbacks are not audio receipts.")
        }

        await run("scheduled_refresh_empty_library_does_not_create_periodic_work") { f in
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            let done = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("empty scheduled opportunity finishes") { done.current == 1 }
            try self.check(f.refreshRequests.current.isEmpty && self.retryWake(f) == nil,
                           "No durable pending source means no periodic wake or retry timer.")
            try self.check(!FileManager.default.fileExists(atPath: f.refreshURL.path), "An empty library cannot manufacture scheduling intent.")
        }

        await run("scheduled_refresh_prior_pending_intent_survives_temporarily_unreadable_fresh_state") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let value = try f.seal(1)
            let original = try FileIdentity(f.watch.audioURL(for: value))
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            f.bridge.resynchronize()
            try await self.eventually("initial factual pending intent accepted") { f.refreshRequests.current.count == 1 }
            try await self.drainQueuedWork(f)
            let stateURL = f.watch.root.appendingPathComponent("fresh-transfer/state.json")
            let state = try Data(contentsOf: stateURL)
            try Data("invalid synthetic fresh state".utf8).write(to: stateURL)
            let done = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("read failure keeps a future system opportunity") { done.current == 1 }
            try self.check(f.refreshRequests.current.count == 2,
                           "A transient state-read failure cannot discard the consumed intent based on previously observed pending work.")
            try self.check(try FileIdentity(f.watch.audioURL(for: value)) == original && !FileManager.default.fileExists(atPath: f.ackURL(value).path),
                           "Recovery scheduling never claims a receipt or changes the original source.")
            try state.write(to: stateURL)
        }

        await run("scheduled_refresh_cold_activation_kvo_prepares_file_before_task_completion") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let value = try f.seal(1)
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            f.session.activationState = .notActivated
            let done = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.drainQueuedWork(f)
            try self.check(done.current == 0 && f.session.state.current.allEnqueued.isEmpty,
                           "A cold task cannot complete before activation has given its bounded work an opportunity.")
            try self.check(f.refreshRequests.current.count == 1, "Durable fresh backlog can schedule a successor while activation is pending.")
            // No delegate callback is supplied: KVO alone must order local work
            // before task completion, even when activation notification wins.
            f.session.activationState = .activated
            try await self.eventually("activation KVO drains bounded work") { done.current == 1 }
            try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id } == [value.id],
                           "KVO activation must actually prepare the FIFO file before completing the task.")
            try self.check(try !f.watch.hasDurableAcknowledgement(for: value), "Neither activation nor task completion is a receipt.")
        }

        await run("scheduled_refresh_actual_application_delegate_routes_refresh_and_wc_separately") { f in
            _ = try (1...20).map(f.sealHistorical)
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            WatchRecorderModel.shared.bridge = f.bridge
            let delegate = WatchApplicationDelegate()
            delegate.applicationDidFinishLaunching()
            let refresh = WKApplicationRefreshBackgroundTask()
            let connectivity = WKWatchConnectivityRefreshBackgroundTask()
            delegate.handle([refresh, connectivity])
            try await self.eventually("real delegate completes only application task") { refresh.completionCount == 1 }
            try self.check(connectivity.completionCount == 0 && f.session.state.current.allEnqueued.count == 2,
                           "Production routing shares the bounded history admission while keeping WC incoming ownership separate.")
            try self.check(refresh.expirationHandler == nil && connectivity.expirationHandler != nil,
                           "Only a completed task has its expiration handler removed.")
            f.session.hasContentPending = false
            try await self.eventually("real delegate completes WC after content drain") { connectivity.completionCount == 1 }
            try self.check(connectivity.expirationHandler == nil, "The production delegate clears completed WC expiration state.")
            try await self.drainQueuedWork(f)
            try self.check(refresh.completionCount == 1 && connectivity.completionCount == 1,
                           "Repeated worker/KVO checks cannot complete either task twice.")
        }

        await run("scheduled_refresh_activation_failure_finishes_without_claiming_delivery") { f in
            _ = try f.sealHistorical(1)
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            f.session.activationState = .notActivated
            let done = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.drainQueuedWork(f)
            try self.check(done.current == 0, "Before a known failure the cold task still owns activation preparation.")
            f.bridge.session(f.session, activationDidCompleteWith: .notActivated,
                             error: NSError(domain: "SyntheticActivation", code: 1))
            try await self.eventually("known activation failure ends task") { done.current == 1 }
            try self.check(f.session.state.current.allEnqueued.isEmpty && f.refreshRequests.current.count == 1,
                           "Activation failure preserves the persistent future opportunity and does not invent a native submission.")
            let decisions = try f.watch.events().filter { $0.kind == "watch.background_transfer_decision" }
            try self.check(decisions.count == 1 && decisions[0].detail.contains("reason=awaiting_activation completion=activation_failed")
                           && decisions[0].sessionID == nil,
                           "Known activation failure must be explicit in the bounded decision rather than resemble an empty queue.")
        }

        await run("scheduled_refresh_expiration_fences_already_queued_work_and_next_opportunity_recovers") { f in
            let value = try f.sealHistorical(1)
            let original = try FileIdentity(f.watch.audioURL(for: value))
            f.enableBackgroundRefresh()
            f.bridge.setMaintenanceAllowed(false)
            guard let queue = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "work" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Production worker queue missing")
            }
            let entered = Locked(false), gate = DispatchSemaphore(value: 0)
            queue.async { entered.access { $0 = true }; _ = gate.wait(timeout: .now() + 10) }
            try await self.eventually("worker held before task registration drains") { entered.current }
            let id = UUID(), expiredDone = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: id) { expiredDone.access { $0 += 1 } }
            f.bridge.expireBackgroundConnectivityTask(id: id)
            gate.signal()
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.allEnqueued.isEmpty && f.refreshRequests.current.isEmpty,
                           "Synchronous expiration must fence an already queued task before native admission or scheduling work.")
            try self.check(expiredDone.current == 0, "The application delegate, not a stale waiter, completes an expired task.")
            try self.check(try FileIdentity(f.watch.audioURL(for: value)) == original, "Expiration leaves exact source bytes intact.")
            let recovered = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { recovered.access { $0 += 1 } }
            try await self.eventually("new actual opportunity recovers") { recovered.current == 1 }
            try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id } == [value.id],
                           "Only a later real system opportunity may reopen bounded work after expiration.")
        }

        await run("closed_fifo_arms_refresh_before_short_wc_grant_expires_during_queue_inspection") { f in
            f.bridge.setMaintenanceAllowed(false)
            f.charging.access { $0 = true }
            f.session.hasContentPending = true
            try await self.drainQueuedWork(f)
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let source = try f.seal(1)
            try f.watch.closePriorityCapture()
            let original = try FileIdentity(f.watch.audioURL(for: source))
            f.enableBackgroundRefresh()
            let id = UUID(), expired = Locked(false), done = Locked(0)
            f.session.outstandingReadAction.access { $0 = { _ in
                guard !expired.current else { return }
                expired.access { $0 = true }
                f.bridge.expireBackgroundConnectivityTask(id: id)
            } }
            f.bridge.performBackgroundConnectivityTask(id: id) { done.access { $0 += 1 } }
            try await self.eventually("native inspection expires the real WC grant") { expired.current }
            try await self.drainQueuedWork(f)
            f.session.outstandingReadAction.access { $0 = nil }
            try self.check(f.refreshRequests.current.count == 1,
                           "The short grant must request one successor before inspecting the native queue.")
            let continuation = f.watch.root.appendingPathComponent("transfer-background-refresh-state.json")
            let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: continuation)) as? [String: Any]
            try self.check(persisted?["preferredDate"] != nil, "Expiration retains the durable continuation.")
            try self.check(done.current == 0 && f.session.state.current.allEnqueued.isEmpty,
                           "Expired work cannot enqueue or complete its native task a second time.")
            try self.check(try FileIdentity(f.watch.audioURL(for: source)) == original
                           && !f.watch.hasDurableAcknowledgement(for: source),
                           "The continuation preserves the source and proves no receipt.")
            let nextDone = Locked(0)
            f.bridge.performBackgroundRefreshTask(id: UUID()) { nextDone.access { $0 += 1 } }
            try await self.eventually("next real grant admits the same source") { nextDone.current == 1 }
            try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id } == [source.id],
                           "The delivered successor resumes bounded FIFO admission.")
        }

        await run("foreground_owner_tick_recovers_after_background_completion_without_new_writer_status") { f in
            _ = try (1...20).map(f.seal)
            let done = Locked(0)
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("bounded task starts before foreground owner") {
                f.session.state.current.allEnqueued.count == 3
            }
            // The user and both paused writer observations arrive while the WK
            // task still owns the gate. Known pending state has no writer poll.
            f.bridge.setMaintenanceAllowed(true)
            f.bridge.update(RecorderSnapshot(state: .paused, sessionID: f.recordingSession.id,
                pendingCount: 20, pendingCountIsKnown: true))
            try await self.settle(f)
            try self.check(f.feedback.current.isEmpty, "Foreground arrival cannot override an active WK task.")
            f.session.hasContentPending = false
            try await self.eventually("background task completes after foreground observations") { done.current == 1 }
            try await self.settle(f)
            try self.check(f.feedback.current.isEmpty, "BG completion alone must leave full maintenance deferred.")
            // Model has freshly confirmed active + foreground + initialized.
            // No new writer status, audio, ACK, or delegate callback is supplied.
            f.bridge.renewForegroundMaintenance()
            try await self.eventually("fresh foreground owner tick restores coalesced full synchronization") {
                !f.feedback.current.isEmpty
            }
            try self.check(f.feedback.current.last?.pendingCount == 20, "Restored feedback must observe the real retained backlog.")
            try await self.drainQueuedWork(f)
            let reads = f.session.state.current.outstandingReads
            let retry = try FileIdentity(f.retryURL)
            for _ in 0..<100 { f.bridge.renewForegroundMaintenance() }
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.outstandingReads == reads,
                           "Already-open foreground ticks must not request another synchronization or full scan.")
            try self.check(try FileIdentity(f.retryURL) == retry,
                           "Foreground renewal cannot rewrite or clear persisted delivery/ACK backoff.")
        }

        await run("foreground_owner_renewal_during_new_background_task_stays_bounded_until_next_confirmation") { f in
            _ = try (1...20).map(f.seal)
            let done = Locked(0)
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("new background task is bounded") { f.session.state.current.allEnqueued.count == 3 }
            f.bridge.update(RecorderSnapshot(state: .paused, sessionID: f.recordingSession.id,
                pendingCount: 20, pendingCountIsKnown: true))
            for _ in 0..<30 { f.bridge.renewForegroundMaintenance() }
            try await self.drainQueuedWork(f)
            try self.check(f.feedback.current.isEmpty && f.session.state.current.allEnqueued.count == 3,
                           "Foreground confirmations cannot override a new active WK task or multiply its enqueue budget.")
            f.session.hasContentPending = false
            try await self.eventually("new background task drains") { done.current == 1 }
            try await self.drainQueuedWork(f)
            try self.check(f.feedback.current.isEmpty, "An earlier owner confirmation cannot become a completion-time grant.")
            f.bridge.renewForegroundMaintenance()
            try await self.eventually("a later actual foreground confirmation reopens the gate") { !f.feedback.current.isEmpty }
        }

        await run("foreground_owner_queued_renewal_cannot_cross_inactive_or_background_reentry") { f in
            _ = try (1...20).map(f.seal)
            let done = Locked(0)
            f.bridge.setMaintenanceAllowed(false)
            f.session.hasContentPending = true
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("initial background fill") { f.session.state.current.allEnqueued.count == 3 }
            f.bridge.setMaintenanceAllowed(true)
            f.bridge.update(RecorderSnapshot(state: .paused, sessionID: f.recordingSession.id,
                pendingCount: 20, pendingCountIsKnown: true))
            try await self.drainQueuedWork(f)
            f.session.hasContentPending = false
            try await self.eventually("initial background task drains") { done.current == 1 }
            try await self.drainQueuedWork(f)
            guard let queue = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "work" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Production bridge serial queue not found")
            }
            let held = DispatchSemaphore(value: 0), entered = Locked(false)
            queue.async { entered.access { $0 = true }; _ = held.wait(timeout: .now() + 5) }
            try await self.eventually("serial worker held before foreground renewal") { entered.current }
            f.bridge.renewForegroundMaintenance()
            f.bridge.setMaintenanceAllowed(false)
            held.signal()
            try await self.drainQueuedWork(f)
            try self.check(f.feedback.current.isEmpty,
                           "A synchronous inactive transition must fence off an already queued foreground renewal.")
            let reentryDone = Locked(0)
            f.session.hasContentPending = true
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { reentryDone.access { $0 += 1 } }
            try await self.drainQueuedWork(f)
            try self.check(f.feedback.current.isEmpty && f.session.state.current.allEnqueued.count == 3,
                           "Background reentry must retain bounded processing and the occupied native slot.")
            f.session.hasContentPending = false
            try await self.eventually("reentered background task drains") { reentryDone.current == 1 }
            try await self.drainQueuedWork(f)
            try self.check(f.feedback.current.isEmpty, "An inactive owner stays blocked after background completion.")
            f.bridge.renewForegroundMaintenance()
            try await self.eventually("fresh active owner can finally recover") { !f.feedback.current.isEmpty }
        }

        await run("paused_inactive_tail_uses_preverified_source_then_waits_for_removal") { f in
            _ = try (1...10).map(f.sealHistorical); f.update()
            try await self.eventually("two history tasks occupied") { f.session.state.current.allEnqueued.count == 2 }
            let oldTasks = f.session.state.current.files
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 20, newEpoch: true)
            f.update(); try await self.settle(f)
            f.bridge.setMaintenanceAllowed(false)
            let tail = try f.seal(20); try f.watch.closePriorityCapture()
            f.bridge.update(RecorderSnapshot(state: .paused, sessionID: f.recordingSession.id, lastSealedAt: tail.endedAt))
            try await self.eventually("paused tail yields using prepared source") { oldTasks.allSatisfy { $0.cancellationCount.current == 1 } }
            try self.check(f.session.state.current.allEnqueued.count == 2, "Inactive cancel does not create physical capacity.")
            for old in oldTasks { f.complete(old, error: NSError(domain: "PriorityCancelled", code: 1)) }
            try await self.eventually("paused tail enters empty native queue") { f.session.state.current.allEnqueued.count == 3 }
            try self.check(f.session.state.current.files.first?.manifest?.id == tail.id, "Committed paused tail remains fresh work.")
            try self.check(f.session.state.current.maximumOutstanding == 2, "Paused tail keeps cancelled history counted until actual removal.")
        }

        for writerName in ["backgroundSyncDiagnostics", "backlogEvidence"] {
            await run("background_metadata_flush_retains_real_wk_lease_\(writerName)") { f in
                let value = try f.sealHistorical(1), receipt = try f.receipt(value)
                f.bridge.setMaintenanceAllowed(true, foreground: true, liveCapture: false)
                f.update()
                try await self.eventually("original metadata cohort captured") {
                    (try? self.backlogSummary(f.watch.root).sourceCount) == 1
                }
                let original = try self.backlogSummary(f.watch.root)
                try await self.drainReportWrites(f)
                f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
                f.charging.access { $0 = true }
                f.session.hasContentPending = true
                WatchRecorderModel.shared.bridge = f.bridge
                let delegate = WatchApplicationDelegate(), task = WKWatchConnectivityRefreshBackgroundTask()
                delegate.handle([task])
                try await self.drainQueuedWork(f)
                guard let observer = Mirror(reflecting: f.bridge).children.first(where: { $0.label == writerName })?.value,
                      let queue = Mirror(reflecting: observer).children.first(where: { $0.label == "io" })?.value as? DispatchQueue else {
                    throw ProbeFailure.failed("Expected actual production metadata writer queue")
                }
                let gate = DispatchSemaphore(value: 0), entered = Locked(false)
                queue.async { entered.access { $0 = true }; _ = gate.wait(timeout: .now() + 10) }
                defer { gate.signal() }
                try await self.eventually("metadata writer held after initialization") { entered.current }
                try f.deliver(receipt)
                f.session.hasContentPending = false
                try await self.drainQueuedWork(f)
                try await self.eventually("real durable ACK exists while report writer is held") {
                    try f.watch.hasDurableAcknowledgement(for: value)
                }
                try await Task.sleep(nanoseconds: 30_000_000)
                try self.check(task.completionCount == 0,
                    "The actual WatchKit delegate must not release its execution lease before already observed ACK metadata persists.")
                gate.signal()
                try await self.eventually("real WK task completes after both small writers drain") { task.completionCount == 1 }
                let final = try self.backlogSummary(f.watch.root)
                let report = try f.backgroundSyncReport()
                try self.check(final.sourceSetID == original.sourceSetID && final.catalogSHA256 == original.catalogSHA256
                    && final.sourceCount == 1 && final.newACKCommittedMemberCount == 1,
                    "The original frozen source identity and real committed ACK must be on disk when the lease ends.")
                try self.check(report["durableACKCommittedCount"] as? Int == 1 && report["tasksCompleted"] as? Int == 1,
                    "Completed-task and ACK observations must both reach the bounded report before the native callback returns.")
                try self.check(task.expirationHandler == nil && !FileManager.default.fileExists(atPath: f.watch.audioURL(for: value).path),
                    "The unchanged delegate completes once, clears expiration and only a real receipt permits source cleanup.")
            }
        }

        await run("background_metadata_flush_late_ack_requires_its_own_drain") { f in
            let values = try (1...2).map(f.sealHistorical), receipts = try values.map(f.receipt)
            f.bridge.setMaintenanceAllowed(true, foreground: true, liveCapture: false)
            f.update()
            try await self.eventually("two-source catalogue captured before delayed ACK") {
                (try? self.backlogSummary(f.watch.root).sourceCount) == 2
            }
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.session.hasContentPending = true
            let done = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.drainQueuedWork(f)
            guard let observer = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "backlogEvidence" })?.value,
                  let queue = Mirror(reflecting: observer).children.first(where: { $0.label == "io" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Expected production cohort queue")
            }
            let firstGate = DispatchSemaphore(value: 0), secondGate = DispatchSemaphore(value: 0)
            let firstEntered = Locked(false), secondEntered = Locked(false)
            defer { firstGate.signal(); secondGate.signal() }
            queue.async { firstEntered.access { $0 = true }; _ = firstGate.wait(timeout: .now() + 10) }
            try await self.eventually("first metadata barrier held") { firstEntered.current }
            try f.deliver(receipts[0])
            f.session.hasContentPending = false
            try await self.eventually("first completion flush is queued") {
                Mirror(reflecting: f.bridge).children.first(where: { $0.label == "backgroundMetadataFlushInFlight" })?.value as? Bool == true
            }
            // This block follows the first flush but precedes the later ACK's
            // observation. A stale flush token therefore cannot cover ACK two.
            queue.async { secondEntered.access { $0 = true }; _ = secondGate.wait(timeout: .now() + 10) }
            try f.deliver(receipts[1])
            try await self.drainQueuedWork(f)
            try self.check(try values.allSatisfy { try f.watch.hasDurableAcknowledgement(for: $0) },
                "Both repository ACKs are real before either delayed metadata write is released.")
            firstGate.signal()
            try await self.eventually("second metadata barrier holds only the later observation") { secondEntered.current }
            try await Task.sleep(nanoseconds: 30_000_000)
            try self.check(done.current == 0,
                "A late ACK must renew the flush revision instead of borrowing an earlier completed diagnostic barrier.")
            secondGate.signal()
            try await self.eventually("later ACK metadata reaches disk before completion") { done.current == 1 }
            try self.check(try self.backlogSummary(f.watch.root).newACKCommittedMemberCount == 2,
                "Every actual durable ACK admitted during a pending flush is represented when the WK lease ends.")
        }

        await run("background_metadata_flush_idempotent_ack_replay_renews_drained_revision") { f in
            let value = try f.sealHistorical(1), receipt = try f.receipt(value)
            f.bridge.setMaintenanceAllowed(true, foreground: true, liveCapture: false)
            f.update()
            try await self.eventually("replay cohort initialized") {
                (try? self.backlogSummary(f.watch.root).sourceCount) == 1
            }
            try f.deliver(receipt)
            try await self.eventually("first ACK committed and source audio pruned") {
                try f.watch.hasDurableAcknowledgement(for: value)
                    && !FileManager.default.fileExists(atPath: f.watch.audioURL(for: value).path)
            }
            try await self.drainQueuedWork(f)
            try await self.drainReportWrites(f)
            let originalChanges = f.changes.current
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.session.hasContentPending = true
            WatchRecorderModel.shared.bridge = f.bridge
            let delegate = WatchApplicationDelegate(), task = WKWatchConnectivityRefreshBackgroundTask()
            delegate.handle([task])
            try await self.eventually("old revision has already completed its metadata barrier") {
                let fields = Mirror(reflecting: f.bridge).children
                let current = fields.first { $0.label == "backgroundWorkRevision" }?.value as? UInt64
                let flushed = fields.first { $0.label == "backgroundMetadataFlushedRevision" }?.value as? UInt64?
                return current != nil && flushed == current
            }
            try await self.drainQueuedWork(f)
            guard let observer = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "backlogEvidence" })?.value,
                  let queue = Mirror(reflecting: observer).children.first(where: { $0.label == "io" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Expected production cohort writer queue")
            }
            let gate = DispatchSemaphore(value: 0), entered = Locked(false)
            queue.async { entered.access { $0 = true }; _ = gate.wait(timeout: .now() + 10) }
            defer { gate.signal() }
            try await self.eventually("backlog writer held after old flush") { entered.current }
            let before = try self.backlogSummary(f.watch.root)
            let beforeMember = try XCTUnwrapProbe(self.backlogPages(f.watch.root, before).flatMap(\.members).first)
            try f.deliver(receipt)
            f.session.hasContentPending = false
            try await self.drainQueuedWork(f)
            try await Task.sleep(nanoseconds: 30_000_000)
            try self.check(task.completionCount == 0,
                "An idempotent ACK replay must await its new cohort observation even after the earlier work revision was flushed.")
            try self.check(f.changes.current == originalChanges,
                "The replay does not manufacture recording changes merely to keep its metadata lease alive.")
            gate.signal()
            try await self.eventually("replay metadata reaches disk before real WK completion") { task.completionCount == 1 }
            let after = try self.backlogSummary(f.watch.root)
            let afterMember = try XCTUnwrapProbe(self.backlogPages(f.watch.root, after).flatMap(\.members).first)
            try self.check(after.sourceSetID == before.sourceSetID && after.catalogSHA256 == before.catalogSHA256
                && after.newACKCommittedMemberCount == 1
                && afterMember.acknowledgementCount == beforeMember.acknowledgementCount + 1,
                "Replay durability is persisted without creating another newly committed ACK or replacing the frozen cohort.")
            try self.check(task.expirationHandler == nil && task.completionCount == 1,
                "The actual WatchKit delegate releases the renewed observation exactly once.")
        }

        for expireDuringFinalFlush in [false, true] {
            await run("background_final_flush_late_replay_\(expireDuringFinalFlush ? "expiration" : "drains_both_writers")") { f in
                let value = try f.sealHistorical(1), receipt = try f.receipt(value)
                f.bridge.setMaintenanceAllowed(true, foreground: true, liveCapture: false)
                f.update()
                try await self.eventually("final-flush cohort initialized") {
                    (try? self.backlogSummary(f.watch.root).sourceCount) == 1
                }
                try f.deliver(receipt)
                try await self.eventually("real receipt has pruned the synthetic source") {
                    try f.watch.hasDurableAcknowledgement(for: value)
                        && !FileManager.default.fileExists(atPath: f.watch.audioURL(for: value).path)
                }
                try await self.drainQueuedWork(f); try await self.drainReportWrites(f)
                f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
                f.session.hasContentPending = true
                WatchRecorderModel.shared.bridge = f.bridge
                let delegate = WatchApplicationDelegate(), task = WKWatchConnectivityRefreshBackgroundTask()
                delegate.handle([task])
                try await self.drainQueuedWork(f); try await self.drainReportWrites(f)
                guard let diagnostic = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "backgroundSyncDiagnostics" })?.value,
                      let diagnosticIO = Mirror(reflecting: diagnostic).children.first(where: { $0.label == "io" })?.value as? DispatchQueue,
                      let backlog = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "backlogEvidence" })?.value,
                      let backlogIO = Mirror(reflecting: backlog).children.first(where: { $0.label == "io" })?.value as? DispatchQueue else {
                    throw ProbeFailure.failed("Expected both production metadata writers")
                }
                let firstGate = DispatchSemaphore(value: 0), finalGate = DispatchSemaphore(value: 0), backlogGate = DispatchSemaphore(value: 0)
                let firstEntered = Locked(false), finalEntered = Locked(false), backlogEntered = Locked(false)
                defer { firstGate.signal(); finalGate.signal(); backlogGate.signal() }
                diagnosticIO.async { firstEntered.access { $0 = true }; _ = firstGate.wait(timeout: .now() + 10) }
                try await self.eventually("preflush diagnostic writer held") { firstEntered.current }
                f.session.hasContentPending = false
                try await self.eventually("precompletion flush queued ahead of final counter write") {
                    Mirror(reflecting: f.bridge).children.first(where: { $0.label == "backgroundMetadataFlushInFlight" })?.value as? Bool == true
                }
                diagnosticIO.async { finalEntered.access { $0 = true }; _ = finalGate.wait(timeout: .now() + 10) }
                firstGate.signal()
                try await self.eventually("only final counter I/O remains held") { finalEntered.current }
                try await self.eventually("final task finish selected on the transfer worker") {
                    (try? f.watch.events().contains { $0.kind == "watch.background_connectivity_finished" }) == true
                }
                backlogIO.async { backlogEntered.access { $0 = true }; _ = backlogGate.wait(timeout: .now() + 10) }
                try await self.eventually("late replay cohort write held after finish selection") { backlogEntered.current }
                let before = try self.backlogSummary(f.watch.root)
                let beforeMember = try XCTUnwrapProbe(self.backlogPages(f.watch.root, before).flatMap(\.members).first)
                let changes = f.changes.current
                try f.deliver(receipt)
                try await self.drainQueuedWork(f)
                finalGate.signal()
                try await Task.sleep(nanoseconds: 30_000_000)
                try self.check(task.completionCount == 0,
                    "An ACK observed during final completion I/O must not lose its WK lease before the new backlog observation drains.")
                try self.check(f.changes.current == changes,
                    "The narrow-window replay keeps its lease without inventing a recording mutation.")
                if expireDuringFinalFlush {
                    task.expirationHandler?()
                    try await self.eventually("native expiration ends the final-flush lease without waiting for I/O") { task.completionCount == 1 }
                }
                backlogGate.signal()
                try await self.eventually("final flush settles once") { task.completionCount == 1 }
                try await self.drainQueuedWork(f); try await self.drainReportWrites(f)
                if expireDuringFinalFlush {
                    // Native expiration intentionally does not await the writer.
                    // Drain it only to inspect later synthetic persistence, not
                    // as proof that expiration retained an execution lease.
                    try await self.drainBacklog(try XCTUnwrapProbe(backlog as? WatchBacklogEvidence))
                }
                let after = try self.backlogSummary(f.watch.root)
                let afterMember = try XCTUnwrapProbe(self.backlogPages(f.watch.root, after).flatMap(\.members).first)
                try self.check(after.sourceSetID == before.sourceSetID && after.catalogSHA256 == before.catalogSHA256
                    && afterMember.acknowledgementCount == beforeMember.acknowledgementCount + 1
                    && after.newACKCommittedMemberCount == 1,
                    "The final-flush replay persists once while preserving the original frozen source cohort and first ACK.")
                try self.check(task.completionCount == 1 && task.expirationHandler == nil,
                    "A released final-writer callback cannot complete the real WatchKit task twice, including after expiration.")
            }
        }

        await run("background_metadata_flush_does_not_outlive_native_expiration") { f in
            let value = try f.sealHistorical(1), receipt = try f.receipt(value)
            f.bridge.setMaintenanceAllowed(true, foreground: true, liveCapture: false)
            f.update()
            try await self.eventually("cohort ready before expiration test") {
                (try? self.backlogSummary(f.watch.root).sourceCount) == 1
            }
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.session.hasContentPending = true
            WatchRecorderModel.shared.bridge = f.bridge
            let delegate = WatchApplicationDelegate(), task = WKWatchConnectivityRefreshBackgroundTask()
            delegate.handle([task])
            try await self.drainQueuedWork(f)
            guard let observer = Mirror(reflecting: f.bridge).children.first(where: { $0.label == "backlogEvidence" })?.value,
                  let queue = Mirror(reflecting: observer).children.first(where: { $0.label == "io" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Expected backlog writer queue")
            }
            let gate = DispatchSemaphore(value: 0), entered = Locked(false)
            queue.async { entered.access { $0 = true }; _ = gate.wait(timeout: .now() + 10) }
            defer { gate.signal() }
            try await self.eventually("hold metadata I/O before durable receipt") { entered.current }
            try f.deliver(receipt)
            f.session.hasContentPending = false
            try await self.drainQueuedWork(f)
            try self.check(task.completionCount == 0, "The lease is pending on metadata, not outgoing delivery.")
            task.expirationHandler?()
            try await self.eventually("native expiration bypasses pending diagnostic flush") { task.completionCount == 1 }
            gate.signal()
            try await self.drainQueuedWork(f)
            try await Task.sleep(nanoseconds: 30_000_000)
            try self.check(task.completionCount == 1 && task.expirationHandler == nil,
                "An old metadata completion cannot finish an expired native task a second time.")
            try self.check(try f.watch.hasDurableAcknowledgement(for: value),
                "Expiration does not undo or manufacture the repository's exact receipt commit.")
        }

        let acknowledgementGate = DispatchSemaphore(value: 0)
        let acknowledgementEntered = Locked(false)
        await run("background_task_waits_for_pending_content_and_durable_ack", fault: { point in
            if case .beforeAcknowledgementSync = point {
                let first = acknowledgementEntered.access { value -> Bool in
                    guard !value else { return false }; value = true; return true
                }
                if first, acknowledgementGate.wait(timeout: .now() + 10) != .success {
                    throw ProbeFailure.failed("Synthetic ACK gate was not released")
                }
            }
        }) { f in
            let manifest = try f.seal(1)
            let receipt = try f.receipt(manifest)
            let completions = Locked(0)
            f.session.hasContentPending = true
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { completions.access { $0 += 1 } }
            try await self.eventually("background-only queue refill") { f.session.state.current.allEnqueued.count == 1 }
            try self.check(completions.current == 0, "Pending incoming content must retain the background opportunity.")
            try f.deliver(receipt)
            try await self.eventually("ACK fsync is in progress") { acknowledgementEntered.current }
            f.session.hasContentPending = false
            try await Task.sleep(nanoseconds: 30_000_000)
            try self.check(completions.current == 0, "No pending WC content cannot complete a task before local ACK fsync.")
            acknowledgementGate.signal()
            try await self.eventually("durable ACK drains the background task") { completions.current == 1 }
            try self.check(try f.watch.hasDurableAcknowledgement(for: manifest), "Background completion must observe durable ACK proof.")
            try self.check(!FileManager.default.fileExists(atPath: f.watch.audioURL(for: manifest).path),
                           "Only that valid ACK may prune the background-delivered audio.")
            try self.check(try f.publishedSnapshots().isEmpty,
                           "A background-only launch cannot fabricate a foreground recorder snapshot.")
        }

        await run("background_task_kvo_drains_without_another_delegate_callback") { f in
            let completions = Locked(0)
            f.session.activationState = .notActivated
            f.session.hasContentPending = true
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { completions.access { $0 += 1 } }
            try await self.eventually("background task registered before activation") {
                (try? f.watch.events().contains { $0.kind == "watch.background_connectivity_started" }) == true
            }
            f.session.hasContentPending = false
            try await self.settle(f)
            try self.check(completions.current == 0, "An inactive session is not evidence of a drained incoming queue.")
            f.session.activationState = .activated
            try await self.eventually("activation KVO completes a content-free task") { completions.current == 1 }
            f.session.hasContentPending = true
            f.session.hasContentPending = false
            try await self.settle(f)
            try self.check(completions.current == 1, "Repeated KVO changes must not complete a system task twice.")
        }

        await run("background_expiration_removes_only_its_own_waiter_and_preserves_audio") { f in
            let manifest = try f.seal(1)
            let source = try FileIdentity(f.watch.audioURL(for: manifest))
            let expiredID = UUID(), remainingID = UUID()
            let expiredCompletions = Locked(0), remainingCompletions = Locked(0)
            f.session.hasContentPending = true
            f.bridge.performBackgroundConnectivityTask(id: expiredID) { expiredCompletions.access { $0 += 1 } }
            f.bridge.performBackgroundConnectivityTask(id: remainingID) { remainingCompletions.access { $0 += 1 } }
            try await self.eventually("both background tasks registered") {
                (try? f.watch.events().filter { $0.kind == "watch.background_connectivity_started" }.count) == 2
            }
            f.bridge.expireBackgroundConnectivityTask(id: expiredID)
            try await self.eventually("expired task removed") {
                (try? f.watch.events().filter { $0.kind == "watch.background_connectivity_expired" }.count) == 1
            }
            f.session.hasContentPending = false
            try await self.eventually("remaining task completes") { remainingCompletions.current == 1 }
            try self.check(expiredCompletions.current == 0, "The app delegate owns expired-task completion; a stale waiter must not complete it again.")
            try self.check(try FileIdentity(f.watch.audioURL(for: manifest)) == source,
                           "Background expiration or content drain cannot acknowledge or mutate source audio.")
        }

        await run("background_activation_failure_releases_task_without_acknowledging_audio") { f in
            let manifest = try f.seal(1)
            let completions = Locked(0)
            f.session.activationState = .notActivated
            f.session.hasContentPending = true
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { completions.access { $0 += 1 } }
            // The production event append and its atomic file replacement
            // must finish before the synthetic test enumerates event JSON.
            try await self.drainQueuedWork(f)
            try await self.eventually("task starts before failed activation") {
                (try? f.watch.events().contains { $0.kind == "watch.background_connectivity_started" }) == true
            }
            f.bridge.session(f.session, activationDidCompleteWith: .notActivated,
                             error: NSError(domain: "SyntheticActivation", code: 1))
            try await self.eventually("failed activation releases its task") { completions.current == 1 }
            try self.check(FileManager.default.fileExists(atPath: f.watch.audioURL(for: manifest).path),
                           "Activation failure must retain unconfirmed source audio.")
            try self.check(try !f.watch.hasDurableAcknowledgement(for: manifest), "Task completion is never an audio ACK.")
        }

        await run("durable_duplicate_ack_storm_preserves_file_and_notifies_once") { f in
            let manifest = try f.seal(1)
            let receipt = try f.receipt(manifest)
            f.update()
            try await self.eventually("initial transfer") { f.session.state.current.allEnqueued.count == 1 }
            try f.deliver(receipt)
            try await self.eventually("first ACK refresh") { f.changes.current == 1 }
            try await self.settle(f)
            let proof = try FileIdentity(f.ackURL(manifest))
            let retry = try FileIdentity(f.retryURL)
            let confirmedAt = f.feedback.current.last?.lastConfirmedAt
            let operations = f.session.state.current
            for index in 0..<300 {
                try f.deliver(receipt, route: index)
            }
            try await self.settle(f)
            try self.check(f.changes.current == 1, "Durable duplicate ACKs must not refresh the recording library.")
            try self.check(try FileIdentity(f.ackURL(manifest)) == proof, "ACK replay must preserve bytes, inode and mtime.")
            try self.check(try FileIdentity(f.retryURL) == retry, "Duplicate ACKs must not churn retry-state storage.")
            try self.check(f.feedback.current.last?.confirmedCount == 1, "Duplicate ACKs cannot count as new progress.")
            try self.check(f.feedback.current.last?.lastConfirmedAt == confirmedAt, "Duplicate ACKs cannot refresh progress time.")
            try self.check(try f.watch.events().filter { $0.kind == "phone_durable_ack" }.count == 1,
                           "Only one durable ACK event may be recorded.")
            try self.check(f.session.state.current.contexts.count - operations.contexts.count <= 2,
                           "Duplicate ACK storms must not repeat complete synchronizations.")
            try self.check(!FileManager.default.fileExists(atPath: f.watch.audioURL(for: manifest).path),
                           "The valid receipt must permit the original audio prune.")
            try self.check(f.session.state.current.allEnqueued.count == 1, "A duplicate ACK cannot enqueue another attempt.")
        }

        await run("mismatched_ack_cannot_release_slots_or_prune_source") { f in
            let manifests = try (1...5).map(f.seal)
            f.update()
            try await self.eventually("single active transfer") { f.session.state.current.allEnqueued.count == 3 }
            let task = f.session.state.current.files[0]
            let manifest = task.manifest!
            let source = try FileIdentity(f.watch.audioURL(for: manifest))
            let invalid = [
                SegmentReceipt(segmentID: manifest.id, sha256: String(repeating: "0", count: 64), byteCount: manifest.byteCount),
                SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount + 1),
                SegmentReceipt(segmentID: UUID(), sha256: manifest.sha256, byteCount: manifest.byteCount),
            ]
            for (index, receipt) in invalid.enumerated() { try f.deliver(receipt, route: index) }
            try await self.settle(f)
            try self.check(f.changes.current == 0, "Rejected receipts must not publish a library mutation.")
            try self.check(try FileIdentity(f.watch.audioURL(for: manifest)) == source, "Invalid ACKs must retain exact audio.")
            try self.check(!FileManager.default.fileExists(atPath: f.ackURL(manifest).path), "Invalid ACKs cannot create local proof.")
            try self.check(f.session.state.current.allEnqueued.count == 3, "Invalid ACKs must not free queue capacity.")
            try self.check(f.session.state.current.files.allSatisfy { $0.cancellationCount.current == 0 },
                           "No task can be cancelled without a matching durable ACK.")
            try self.check(try Set(f.watch.pendingSegments().map(\.id)) == Set(manifests.map(\.id)), "Every source remains pending.")
            try self.check(!f.issues.current.isEmpty, "Receipt verification failure must be visible.")
        }

        await run("cancelled_task_still_counts_until_system_removal") { f in
            _ = try (1...7).map(f.seal)
            f.update()
            try await self.eventually("full three-task queue") { f.session.state.current.files.count == 3 }
            let task = f.session.state.current.files[0]
            let receipt = try f.receipt(task.manifest!)
            try f.deliver(receipt)
            try await self.eventually("one cancellation requested") { task.cancellationCount.current == 1 }
            for _ in 0..<50 { f.bridge.resynchronize() }
            try await self.settle(f)
            try self.check(f.session.state.current.allEnqueued.count == 3, "Cancel() alone must not free a system queue slot.")
            try self.check(f.session.state.current.files.count == 3, "The controlled cancelled task must remain outstanding.")
            try self.check(task.cancellationCount.current == 1, "The same cancelled task must not be cancelled repeatedly.")
            f.complete(task, error: NSError(domain: "ProbeCancelled", code: 1))
            try await self.eventually("released slot filled") { f.session.state.current.allEnqueued.count == 4 }
            try await self.settle(f)
            try self.check(f.session.state.current.maximumOutstanding == 3, "Real outstanding file tasks remain within three battery slots.")
            // Duplicate, delayed cancellation completions cannot penalize an
            // already acknowledged segment or enqueue a replacement of it.
            f.bridge.session(f.session, didFinish: task, error: NSError(domain: "ProbeCancelled", code: 1))
            try await self.settle(f)
            try self.check(f.session.state.current.allEnqueued.filter { $0.manifest?.id == receipt.segmentID }.count == 1,
                           "A late cancellation completion cannot retransmit an acknowledged segment.")
        }

        await run("new_epoch_preempts_old_fresh_only_after_seal_then_preserves_each_epoch_fifo") { f in
            _ = try f.sealHistorical(1)
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
            let fresh = try (2...4).map(f.seal); f.update()
            try await self.eventually("first fresh head enqueued") { f.session.state.current.files.first?.manifest?.id == fresh[0].id }
            try await self.settle(f)
            let oldTasks = f.session.state.current.files
            let headTask = oldTasks[0]
            let oldSource = try FileIdentity(f.watch.audioURL(for: fresh[0]))
            try f.deliver(f.receipt(fresh[2])); try await self.settle(f)
            try self.check(try f.watch.freshTransferSnapshot().head?.id == fresh[0].id, "Later ACK cannot jump unacknowledged head.")
            try f.watch.closePriorityCapture()
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 5, newEpoch: true)
            f.update(); try await self.settle(f)
            try self.check(headTask.cancellationCount.current == 0, "An empty new epoch must not cancel an older fresh native task.")
            let resumed = try f.seal(5); f.update()
            try await self.eventually("sealed current epoch requests old fresh yield") { headTask.cancellationCount.current == 1 }
            try self.check(f.session.state.current.allEnqueued.count == 3, "All older window tasks still consume native admission after cancellation is requested.")
            let key = headTask.file.metadata!["fileTransferAttemptID"] as! String
            try self.check(try f.watch.preemptionIntent(attemptID: key)?.freshHeadID == resumed.id, "Older fresh cancellation must persist an intent for the exact current head.")
            try self.check(try FileIdentity(f.watch.audioURL(for: fresh[0])) == oldSource, "Preempting an older epoch cannot prune its unacknowledged source.")
            for oldTask in oldTasks { f.complete(oldTask, error: NSError(domain: "CancelledOlderEpoch", code: 1)) }
            try await self.eventually("current epoch enters the vacated native slot") { f.session.state.current.files.first?.manifest?.id == resumed.id }
            let resumedTask = f.session.state.current.files[0]
            try f.deliver(f.receipt(fresh[0])); try await self.settle(f)
            try self.check(try f.watch.freshTransferSnapshot().head?.id == resumed.id, "A late old-epoch ACK cannot advance the current priority head.")
            try f.watch.closePriorityCapture()
            try f.deliver(f.receipt(resumed)); f.complete(resumedTask)
            try await self.settle(f)
            try self.check(try f.watch.freshTransferSnapshot().head == fresh[1], "Closed priority returns to the exact earlier unacknowledged head.")
            var stillWaiting = try f.retryState()
            try self.check(!stillWaiting.isEligible(fresh[1]), "A preempted window member retains its finite disappearance grace instead of immediately creating a duplicate attempt.")
            // Advance persisted retry evidence to a genuinely elapsed attempt;
            // no production timer or wall-clock wait is bypassed by the bridge.
            var elapsed = FileTransferRetryPolicy()
            let priorIdentity = oldTasks[1].file.metadata!["fileTransferAttemptID"] as! String
            elapsed.noteEnqueued(fresh[1], attemptID: priorIdentity, at: Date().addingTimeInterval(-600))
            elapsed.recordDisappearedTransfers(outstandingIDs: [], at: Date().addingTimeInterval(-120))
            try TransportCodec.encode(elapsed).write(to: f.retryURL)
            f.restartBridge(); f.update()
            try await self.eventually("closed drained current epoch returns to eligible older backlog") { f.session.state.current.files.first?.manifest?.id == fresh[1].id }
            try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id } == fresh.map(\.id) + [resumed.id, fresh[1].id], "A new epoch leads, while older unacknowledged middle entries remain recoverable.")
            try self.check(try f.watch.hasDurableAcknowledgement(for: fresh[2]), "An out-of-order old ACK remains valid during priority changes.")
        }

        await run("old_epoch_waiting_ack_does_not_block_new_priority_or_its_exact_request") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let old = try f.seal(1); f.update()
            try await self.eventually("old epoch native task enqueued") { f.session.state.current.files.count == 1 }
            f.complete(f.session.state.current.files[0]); try await self.settle(f)
            var retry = try f.retryState()
            try self.check(!retry.isEligible(old), "Old transport delivery must retain its own ACK backoff.")
            try f.watch.closePriorityCapture()
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
            let current = try f.seal(2)
            f.restartBridge(); f.update()
            try await self.eventually("new priority bypasses older ACK wait without deleting it") { f.session.state.current.files.first?.manifest?.id == current.id }
            try self.check(try f.requestTarget(f.receiptRequests.last!)?.matches(current) == true, "The first new-process request must target the current epoch head, not the old ACK wait.")
            try self.check(FileManager.default.fileExists(atPath: f.watch.audioURL(for: old).path), "Old unacknowledged audio must remain available.")
            try self.check(!FileManager.default.fileExists(atPath: f.ackURL(old).path), "Priority replacement must not manufacture an old ACK.")
            let task = f.session.state.current.files[0]
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 3, newEpoch: false)
            _ = try f.seal(3); f.update(); try await self.settle(f)
            try self.check(task.cancellationCount.current == 0, "Automatic continuation in the same epoch cannot preempt its current native head.")
            try self.check(try f.watch.freshTransferSnapshot().head?.id == current.id, "Automatic continuation preserves current-epoch FIFO.")
        }

        await run("new_resume_between_source_preparation_and_cancel_rejects_stale_priority") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let old = try f.seal(1); f.update()
            try await self.eventually("old native task ready for priority race") { f.session.state.current.files.count == 1 }
            let task = f.session.state.current.files[0]
            try f.watch.closePriorityCapture()
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
            _ = try f.seal(2)
            let switchAt = f.session.state.current.outstandingReads + 3
            let switched = Locked(false)
            let switchFailure = Locked<String?>(nil)
            f.session.outstandingReadAction.access { $0 = { count in
                guard count == switchAt else { return }
                do {
                    try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 3, newEpoch: true)
                    switched.access { $0 = true }
                } catch { switchFailure.access { $0 = String(describing: error) } }
            } }
            f.update(); try await self.settle(f)
            f.session.outstandingReadAction.access { $0 = nil }
            try self.check(switched.current && switchFailure.current == nil, "Synthetic explicit resume must occur after preparation and before cancellation.")
            try self.check(task.cancellationCount.current == 0, "A stale prepared priority cannot cancel while the latest epoch has no sealed head.")
            let key = task.file.metadata!["fileTransferAttemptID"] as! String
            try self.check(try f.watch.preemptionIntent(attemptID: key) == nil, "Stale identity must fail before writing a cancellation intent.")
            try self.check(FileManager.default.fileExists(atPath: f.watch.audioURL(for: old).path), "Rejected preemption preserves the old source.")
            let latest = try f.seal(3); f.update()
            try await self.eventually("latest durable head permits fresh verification and cancellation") { task.cancellationCount.current == 1 }
            try self.check(try f.watch.preemptionIntent(attemptID: key)?.freshHeadID == latest.id, "A certificate from the superseded epoch cannot choose the new intent head.")
        }

        for mode in ["unknown_epoch", "late_old_entry", "changed_source", "missing_attempt_identity"] {
            await run("older_fresh_preemption_rejects_\(mode)") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                let old = try f.seal(1)
                try f.watch.closePriorityCapture()
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
                let current = try f.seal(2)
                let candidate = mode == "late_old_entry" ? try f.seal(1) : old
                if mode == "unknown_epoch" {
                    let url = f.watch.root.appendingPathComponent("fresh-transfer/" + old.id.uuidString.lowercased() + ".json")
                    var value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                    var boundary = value["boundary"] as! [String: Any]
                    boundary["epochID"] = UUID().uuidString
                    value["boundary"] = boundary
                    try JSONSerialization.data(withJSONObject: value).write(to: url)
                } else if mode == "changed_source" {
                    try Data(repeating: 239, count: 4_096).write(to: f.watch.audioURL(for: old))
                }
                var metadata: [String: Any] = [TransportCodec.manifestKey: try TransportCodec.encode(candidate)]
                if mode != "missing_attempt_identity" {
                    metadata["fileTransferAttemptID"] = UUID().uuidString
                    metadata["diagnosticEnqueuedAt"] = Date().addingTimeInterval(-60).timeIntervalSince1970
                }
                let task = f.session.addLegacyTask(url: f.watch.audioURL(for: candidate), metadata: metadata)
                f.update(); try await self.settle(f)
                try self.check(task.cancellationCount.current == 0, "Unknown epoch, late entry, invalid source or unknown native identity cannot authorize cancellation.")
                try self.check(f.session.state.current.allEnqueued.isEmpty, "The retained native task continues to consume the single slot.")
                try self.check(try f.watch.freshTransferSnapshot().head?.id == current.id, "Rejected preemption must preserve the current priority head.")
                try self.check(!FileManager.default.fileExists(atPath: f.ackURL(candidate).path), "Refusal cannot acknowledge the retained native source.")
            }
        }

        for mode in ["legacy", "drained_priority"] {
            await run("\(mode)_fallback_head_retains_historical_preemption") { f in
                let history = try f.sealHistorical(1)
                let task = f.session.addLegacyTask(url: f.watch.audioURL(for: history), metadata: [
                    TransportCodec.manifestKey: try TransportCodec.encode(history),
                    "fileTransferAttemptID": UUID().uuidString,
                    "diagnosticEnqueuedAt": Date().addingTimeInterval(-60).timeIntervalSince1970])
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
                let older = try f.seal(2)
                try f.watch.closePriorityCapture()
                if mode == "legacy" {
                    let url = f.watch.root.appendingPathComponent("fresh-transfer/state.json")
                    var value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                    for key in ["priorityEpochID", "prioritySessionID", "priorityStartPosition", "priorityCursor"] { value.removeValue(forKey: key) }
                    try JSONSerialization.data(withJSONObject: value).write(to: url)
                } else {
                    try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 3, newEpoch: true)
                    let latest = try f.seal(3)
                    try f.watch.acknowledge(f.receipt(latest), pruneAudio: true)
                    try f.watch.closePriorityCapture()
                }
                let snapshot = try f.watch.freshTransferSnapshot()
                try self.check(snapshot.head?.id == older.id && snapshot.priorityIdentity == nil, "The fixture must select an actual legacy/global fallback head.")
                f.update()
                try await self.eventually("fallback fresh head requests proven historical yield") { task.cancellationCount.current == 1 }
                let key = task.file.metadata!["fileTransferAttemptID"] as! String
                try self.check(try f.watch.preemptionIntent(attemptID: key)?.freshHeadID == older.id, "Legacy history preemption must retain the exact fallback head in its durable intent.")
                try self.check(f.session.state.current.allEnqueued.isEmpty, "Legacy cancellation still waits for actual native queue removal.")
                f.session.removeFromSystemQueue(task); f.update()
                try await self.eventually("fallback head enters the truly empty queue") { f.session.state.current.files.first?.manifest?.id == older.id }
            }
        }

        for mode in ["priority", "fallback"] {
            await run("explicit_resume_before_\(mode)_admission_rejects_stale_head") { f in
                try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
                let old = try f.seal(1)
                try f.watch.closePriorityCapture()
                var nextSequence = 2
                if mode == "fallback" {
                    try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
                    let drained = try f.seal(2)
                    try f.watch.acknowledge(f.receipt(drained), pruneAudio: true)
                    try f.watch.closePriorityCapture()
                    nextSequence = 3
                }
                let switchAt = f.session.state.current.outstandingReads + 3
                let latest = Locked<SegmentManifest?>(nil)
                let switchFailure = Locked<String?>(nil)
                f.session.outstandingReadAction.access { $0 = { count in
                    guard count == switchAt else { return }
                    do {
                        try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: nextSequence, newEpoch: true)
                        latest.access { $0 = try? f.seal(nextSequence) }
                    } catch { switchFailure.access { $0 = String(describing: error) } }
                } }
                f.update()
                try await self.eventually("new current head survives the admission race") {
                    guard let current = latest.current else { return false }
                    return f.session.state.current.files.first?.manifest?.id == current.id
                }
                f.session.outstandingReadAction.access { $0 = nil }
                try self.check(switchFailure.current == nil, "The synthetic explicit resume must succeed.")
                try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id } == [latest.current!.id], "An old snapshot cannot enqueue after a new explicit priority begin.")
                try self.check(FileManager.default.fileExists(atPath: f.watch.audioURL(for: old).path), "Refusing stale admission must preserve the older backlog.")
            }
        }

        await run("fallback_history_certificate_cannot_cancel_after_empty_new_resume") { f in
            let history = try f.sealHistorical(1)
            let task = f.session.addLegacyTask(url: f.watch.audioURL(for: history), metadata: [
                TransportCodec.manifestKey: try TransportCodec.encode(history),
                "fileTransferAttemptID": UUID().uuidString,
                "diagnosticEnqueuedAt": Date().addingTimeInterval(-60).timeIntervalSince1970])
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
            _ = try f.seal(2)
            try f.watch.closePriorityCapture()
            let stateURL = f.watch.root.appendingPathComponent("fresh-transfer/state.json")
            var value = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
            for key in ["priorityEpochID", "prioritySessionID", "priorityStartPosition", "priorityCursor"] { value.removeValue(forKey: key) }
            try JSONSerialization.data(withJSONObject: value).write(to: stateURL)
            let switchAt = f.session.state.current.outstandingReads + 3
            let switched = Locked(false)
            f.session.outstandingReadAction.access { $0 = { count in
                guard count == switchAt else { return }
                do {
                    try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 3, newEpoch: true)
                    switched.access { $0 = true }
                } catch {}
            } }
            f.update(); try await self.settle(f)
            f.session.outstandingReadAction.access { $0 = nil }
            try self.check(switched.current, "An empty new epoch must replace the fallback after historical hash preparation.")
            try self.check(task.cancellationCount.current == 0, "Fallback head revalidation must reject cancellation after a newer empty begin.")
            let key = task.file.metadata!["fileTransferAttemptID"] as! String
            try self.check(try f.watch.preemptionIntent(attemptID: key) == nil, "A stale fallback cannot create an intent for a superseded head.")
        }

        await run("older_fresh_restart_requires_certificate_and_ignores_late_cancel_callbacks") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let old = try f.seal(1); f.update()
            try await self.eventually("old fresh native task exists") { f.session.state.current.files.count == 1 }
            let task = f.session.state.current.files[0]
            try f.watch.closePriorityCapture()
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
            let current = try f.seal(2); f.update()
            try await self.eventually("older fresh intent and cancellation exist") { task.cancellationCount.current == 1 }
            f.restartBridge(); f.bridge.setMaintenanceAllowed(false)
            let done = Locked(0)
            f.bridge.performBackgroundConnectivityTask(id: UUID()) { done.access { $0 += 1 } }
            try await self.eventually("headless restart drains bounded opportunity") { done.current == 1 }
            try self.check(task.cancellationCount.current == 1, "A persisted old-fresh intent is not a new-process audio certificate.")
            try self.check(f.session.state.current.allEnqueued.count == 1, "A short WK opportunity cannot bypass the occupied native slot.")
            f.session.removeFromSystemQueue(task); f.update()
            try await self.eventually("current priority uses the released native slot") { f.session.state.current.files.first?.manifest?.id == current.id }
            try await self.settle(f)
            let saved = try FileIdentity(f.retryURL)
            f.bridge.session(f.session, didFinish: task, error: nil)
            f.bridge.session(f.session, didFinish: task, error: NSError(domain: "LateOldFreshCancellation", code: 1))
            try await self.settle(f)
            try self.check(try FileIdentity(f.retryURL) == saved, "Late cancelled old-epoch callbacks cannot mutate the new attempt across restart.")
            try self.check(try f.watch.freshTransferSnapshot().head?.id == current.id, "Late transport callbacks cannot advance current priority.")
            try f.deliver(f.receipt(old)); try await self.settle(f)
            try self.check(try f.watch.hasDurableAcknowledgement(for: old), "A valid late old-epoch receipt remains acceptable after restart.")
            try self.check(try f.watch.freshTransferSnapshot().head?.id == current.id, "Accepting old proof cannot release the unacknowledged current head.")
        }

        let changedPreemptionSource = Locked<URL?>(nil)
        await run("source_change_during_intent_commit_prevents_old_fresh_cancel", fault: { point in
            if case .beforePreemptionIntentCommit = point, let source = changedPreemptionSource.current {
                try Data(repeating: 237, count: 4_096).write(to: source, options: .atomic)
            }
        }) { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let old = try f.seal(1); f.update()
            try await self.eventually("old source queued before signature race") { f.session.state.current.files.count == 1 }
            let task = f.session.state.current.files[0]
            try f.watch.closePriorityCapture()
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 2, newEpoch: true)
            _ = try f.seal(2)
            changedPreemptionSource.access { $0 = f.watch.audioURL(for: old) }
            f.update(); try await self.settle(f)
            changedPreemptionSource.access { $0 = nil }
            try self.check(task.cancellationCount.current == 0, "A durable intent cannot authorize cancellation after the verified source signature changes.")
            try self.check(f.session.state.current.allEnqueued.count == 1, "Source validation failure must not create capacity or another native task.")
            try self.check(!FileManager.default.fileExists(atPath: f.ackURL(old).path), "Source validation failure cannot manufacture an ACK.")
        }

        await run("new_enqueue_retry_state_persists_and_delivery_is_not_ack") { f in
            let manifest = try f.seal(1)
            f.update()
            try await self.eventually("new task and persisted attempt") {
                f.session.state.current.allEnqueued.count == 1 && FileManager.default.fileExists(atPath: f.retryURL.path)
            }
            try await self.settle(f)
            var policy = try f.retryState()
            try self.check(!policy.isEligible(manifest), "Newly enqueued work must retain bounded retry backoff on disk.")
            let task = f.session.state.current.files[0]
            f.complete(task)
            try await self.eventually("delivery event") { (try? f.watch.events().contains { $0.kind == "file_delivered_waiting_ack" }) == true }
            try await self.settle(f)
            try self.check(FileManager.default.fileExists(atPath: f.watch.audioURL(for: manifest).path),
                           "System delivery without a phone ACK must retain audio.")
            try self.check(!FileManager.default.fileExists(atPath: f.ackURL(manifest).path), "System completion is not acknowledgement.")
            try self.check(f.changes.current == 0, "Transport completion must not publish a repository change.")
            try self.check(f.feedback.current.last?.awaitingConfirmationCount == 1, "Delivery remains awaiting phone confirmation.")
            policy = try f.retryState()
            try self.check(!policy.isEligible(manifest), "Delivered work must wait for a receipt before retry.")
            f.bridge.resynchronize(requestedAt: Date())
            f.update()
            try await self.settle(f)
            try self.check(f.session.state.current.allEnqueued.count == 1, "Manual sync and status updates cannot bypass retry cooldown.")
            try f.deliver(f.receipt(manifest))
            try await self.eventually("durable ACK clears retry") { f.changes.current == 1 }
            try await self.settle(f)
            policy = try f.retryState()
            try self.check(policy.isEligible(manifest), "Valid acknowledgement must remove its saved retry attempt.")
        }

        await run("snapshot_burst_coalesces_and_preserves_latest_observation") { f in
            let gate = DispatchSemaphore(value: 0)
            f.session.contextGate.access { $0 = gate }
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            f.update(observedAt: start, detail: "initial")
            try await self.eventually("platform context gate entered") { f.session.contextGateEntered.current }
            for index in 1...200 {
                f.update(observedAt: start.addingTimeInterval(Double(index)), detail: "snapshot-\(index)")
            }
            gate.signal()
            try await self.eventually("last snapshot delivered") {
                guard let data = f.session.state.current.contexts.last?[TransportCodec.snapshotKey] as? Data,
                      let snapshot = try? TransportCodec.decode(RecorderSnapshot.self, from: data) else { return false }
                return snapshot.observedAt == start.addingTimeInterval(200) && snapshot.detail == nil
            }
            try await self.settle(f)
            try self.check(f.session.state.current.contexts.count <= 3, "Queued status bursts must coalesce complete synchronizations.")
            let data = f.session.state.current.contexts.last![TransportCodec.snapshotKey] as! Data
            let snapshot = try TransportCodec.decode(RecorderSnapshot.self, from: data)
            try self.check(snapshot.observedAt == start.addingTimeInterval(200), "Coalescing must preserve the final writer timestamp.")
            try self.check(snapshot.state == .recording, "Coalescing cannot fabricate a different capture state.")
            try self.check(f.session.state.current.allEnqueued.isEmpty, "Status-only updates cannot invent transfer work.")
        }

        await run("unknown_system_tasks_block_single_flight_without_unsafe_preemption") { f in
            try f.watch.beginPriorityCapture(sessionID: f.recordingSession.id, nextSequence: 1, newEpoch: true)
            let fresh = try f.seal(1)
            let unknown = f.session.addLegacyTask(url: f.root.appendingPathComponent("opaque-system-task"), metadata: nil)
            f.update(); try await self.settle(f)
            try self.check(f.session.state.current.allEnqueued.isEmpty, "Opaque tasks consume the single slot.")
            try self.check(unknown.cancellationCount.current == 0, "Unknown metadata cannot authorize cancellation.")
            f.session.removeFromSystemQueue(unknown); f.update()
            try await self.eventually("fresh follows actual unknown task removal") { f.session.state.current.files.first?.manifest?.id == fresh.id }
            try self.check(f.session.state.current.maximumOutstanding == 1, "Unknown tasks count against single-flight admission.")
        }

        let cleanupSource = Locked<URL?>(nil), cleanupSyncCount = Locked(0), cleanupFailureInjected = Locked(false)
        await run("ack_cleanup_failure_retains_real_commit_and_does_not_block_refill", fault: { point in
            if case .beforeAcknowledgementSync = point, let source = cleanupSource.current {
                let count = cleanupSyncCount.access { value -> Int in value += 1; return value }
                if count == 2 {
                    // The first exact ACK has already completed fsync. Only its
                    // second, independently validated cleanup now fails to unlink
                    // this synthetic immutable file (never a device recording).
                    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: source.path)
                    cleanupFailureInjected.access { $0 = true }
                }
            }
        }) { f in
            _ = try (1...3).map(f.sealHistorical)
            f.update()
            try await self.eventually("two original native tasks queued") { f.session.state.current.files.count == 2 }
            let original = f.session.state.current.files[0]
            let manifest = try XCTUnwrapProbe(original.manifest), receipt = try f.receipt(manifest)
            let source = f.watch.audioURL(for: manifest), before = try FileIdentity(source)
            cleanupSource.access { $0 = source }
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: source.path) }
            f.bridge.setMaintenanceAllowed(false, foreground: false, liveCapture: false)
            f.session.hasContentPending = true
            f.bridge.performBackgroundConnectivityTask(id: UUID()) {}
            try f.deliver(receipt)
            try await self.eventually("cleanup failure remains a successful durable receipt") { f.changes.current == 1 }
            try await self.eventually("committed ACK cancels duplicate despite failed audio unlink") { original.cancellationCount.current == 1 }
            let report = try await self.report(f, "bounded report distinguishes commit from failed cleanup") {
                $0["durableACKCommittedCount"] as? Int == 1 && $0["acknowledgedCleanupDeferredCount"] as? Int == 1
            }
            try self.check(cleanupFailureInjected.current && report["acknowledgementUncommittedCount"] as? Int == 0,
                "A real cleanup failure after successful fsync is not an uncommitted or rejected receipt.")
            try self.check(try f.watch.hasDurableAcknowledgement(for: manifest) && FileIdentity(source) == before,
                "The exact original synthetic audio is retained while its real ACK remains durable.")
            try self.check(f.issues.current.isEmpty,
                "Local unlink failure cannot replace a valid phone receipt with an integrity-rejection error.")
            f.complete(original, error: NSError(domain: "SyntheticAcknowledgedCancellation", code: 1))
            try await self.eventually("other backlog can refill after real native removal") { f.session.state.current.allEnqueued.count == 3 }
            try self.check(f.session.state.current.files.first?.manifest?.id != manifest.id,
                "An already acknowledged but locally retained file cannot block or retransmit ahead of another pending source.")
            cleanupSource.access { $0 = nil }
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: source.path)
            try f.deliver(receipt)
            try await self.eventually("later exact receipt can finish deferred cleanup") {
                !FileManager.default.fileExists(atPath: source.path)
            }
            try self.check(try f.watch.hasDurableAcknowledgement(for: manifest), "Cleanup retry never replaces the exact durable receipt.")
        }

        let failSync = Locked(true)
        await run("visible_ack_requires_durable_sync_before_prune_or_cancel", fault: {
            if case .beforeAcknowledgementSync = $0, failSync.current {
                throw ProbeFailure.failed("Synthetic acknowledgement fsync failure")
            }
        }) { f in
            let manifest = try f.seal(1)
            let receipt = try f.receipt(manifest)
            f.update()
            try await self.eventually("source queued before fsync failure") { f.session.state.current.files.count == 1 }
            let task = f.session.state.current.files[0]
            try f.deliver(receipt)
            try await self.eventually("fsync error reported") { !f.issues.current.isEmpty }
            try await self.settle(f)
            let visible = try FileIdentity(f.ackURL(manifest))
            try self.check(FileManager.default.fileExists(atPath: f.watch.audioURL(for: manifest).path),
                           "A visible ACK with failed durability must not prune audio.")
            try self.check(task.cancellationCount.current == 0, "A failed fsync cannot authorize duplicate cancellation.")
            try self.check(f.changes.current == 0, "Failed ACK processing must not publish success.")
            failSync.access { $0 = false }
            try f.deliver(receipt)
            try await self.eventually("identical ACK recovery refreshes once") { f.changes.current == 1 }
            try await self.eventually("durable recovery permits cancellation") { task.cancellationCount.current == 1 }
            try await self.settle(f)
            try self.check(try FileIdentity(f.ackURL(manifest)) == visible, "Recovery should synchronize the existing identical proof.")
            try self.check(!FileManager.default.fileExists(atPath: f.watch.audioURL(for: manifest).path),
                           "Only the successful durability retry may prune audio.")
        }

        await run("restart_replay_checks_disk_without_rewriting_or_refreshing_library") { f in
            let manifest = try f.seal(1)
            let receipt = try f.receipt(manifest)
            f.update()
            try await self.eventually("first process enqueues") { f.session.state.current.files.count == 1 }
            try f.deliver(receipt)
            try await self.eventually("first process acknowledges") { f.changes.current == 1 }
            try await self.settle(f)
            let proof = try FileIdentity(f.ackURL(manifest))
            f.restartBridge()
            for index in 0..<100 { try f.deliver(receipt, route: index) }
            try await self.settle(f)
            try self.check(f.changes.current == 1, "Replayed durable ACKs after restart must not trigger library changes.")
            try self.check(try FileIdentity(f.ackURL(manifest)) == proof, "Restart must recognize an identical durable disk proof.")
            try self.check(f.session.state.current.allEnqueued.count == 1, "Restart ACK replay cannot retransmit pruned audio.")
            // Removal of the proof must not be hidden by an in-memory ID cache.
            try FileManager.default.removeItem(at: f.ackURL(manifest))
            try f.deliver(receipt)
            try await self.eventually("removed ACK repaired from current valid receipt") { f.changes.current == 2 }
            try await self.settle(f)
            try self.check(try TransportCodec.decode(SegmentReceipt.self, from: Data(contentsOf: f.ackURL(manifest))) == receipt,
                           "A newly missing ACK must be validated and reconstructed.")
        }

        let remainingFailures = Locked(1)
        await run("same_batch_ack_failure_then_success_clears_only_recovered_issue", fault: { point in
            if case .beforeAcknowledgementSync = point {
                let shouldFail = remainingFailures.access { value -> Bool in
                    guard value > 0 else { return false }; value -= 1; return true
                }
                if shouldFail { throw ProbeFailure.failed("Synthetic one-time acknowledgement fsync failure") }
            }
        }) { f in
            let manifest = try f.seal(1)
            let receipt = try f.receipt(manifest)
            let gate = DispatchSemaphore(value: 0)
            f.session.contextGate.access { $0 = gate }
            f.update()
            try await self.eventually("sync held before queued ACK callbacks") { f.session.contextGateEntered.current }
            try f.deliver(receipt)
            try f.deliver(receipt, route: 1)
            gate.signal()
            try await self.eventually("same batch recovery completes") { f.changes.current == 1 }
            try await self.settle(f)
            try self.check(try f.watch.events().filter { $0.kind == "phone_ack_rejected" }.count == 1,
                           "The controlled first ACK must actually fail once before recovery.")
            try self.check(try f.watch.hasDurableAcknowledgement(for: manifest), "The second receipt must establish durability.")
            try self.check(!FileManager.default.fileExists(atPath: f.watch.audioURL(for: manifest).path),
                           "Successful retry should prune after its durability boundary.")
            try self.check(f.feedback.current.last?.phase == .completed,
                           "An ACK recovered in the same coalesced batch must not retain the preceding failed feedback.")
            try self.check(f.feedback.current.last?.message == nil, "Recovered ACK error text must be cleared.")
        }

        await run("malformed_receipt_then_valid_durable_replay_clears_rejection_without_library_churn") { f in
            let manifest = try f.seal(1)
            let receipt = try f.receipt(manifest)
            f.update()
            try await self.eventually("initial source transfer") { f.session.state.current.files.count == 1 }
            try f.deliver(receipt)
            try await self.eventually("initial durable acceptance") { f.changes.current == 1 }
            try await self.settle(f)
            let proof = try FileIdentity(f.ackURL(manifest))
            let gate = DispatchSemaphore(value: 0)
            f.session.contextGate.access { $0 = gate }
            f.session.contextGateEntered.access { $0 = false }
            f.update()
            try await self.eventually("sync blocked before malformed replay") { f.session.contextGateEntered.current }
            f.bridge.session(f.session, didReceiveUserInfo: [TransportCodec.receiptKey: Data("not-json".utf8)])
            try f.deliver(receipt)
            gate.signal()
            try await self.settle(f)
            try self.check(try f.watch.events().filter { $0.kind == "phone_ack_rejected" }.count == 1,
                           "The malformed receipt must actually exercise the decode failure.")
            try self.check(f.feedback.current.last?.phase == .completed,
                           "A later valid durable replay must clear a malformed receipt rejection.")
            try self.check(f.feedback.current.last?.message == nil, "Malformed-receipt rejection text must be cleared on recovery.")
            try self.check(f.changes.current == 1, "Recovering a decode error with a duplicate must not refresh the library again.")
            try self.check(try FileIdentity(f.ackURL(manifest)) == proof, "Error recovery must not rewrite an identical durable ACK.")
            try self.check(try f.watch.events().filter { $0.kind == "phone_durable_ack" }.count == 1,
                           "Error recovery must not emit another durable-ACK event.")
        }

        let otherIDFailures = Locked(1)
        await run("one_successful_ack_cannot_clear_another_id_failure", fault: { point in
            if case .beforeAcknowledgementSync = point {
                let shouldFail = otherIDFailures.access { value -> Bool in
                    guard value > 0 else { return false }; value -= 1; return true
                }
                if shouldFail { throw ProbeFailure.failed("Synthetic first-ID acknowledgement fsync failure") }
            }
        }) { f in
            let first = try f.seal(1), second = try f.seal(2)
            let firstReceipt = try f.receipt(first), secondReceipt = try f.receipt(second)
            let gate = DispatchSemaphore(value: 0)
            f.session.contextGate.access { $0 = gate }
            f.update()
            try await self.eventually("sync held before two different receipts") { f.session.contextGateEntered.current }
            try f.deliver(firstReceipt)
            try f.deliver(secondReceipt)
            gate.signal()
            try await self.eventually("only second receipt completed") { f.changes.current == 1 }
            try await self.settle(f)
            try self.check(f.feedback.current.last?.phase == .failed,
                           "A successful receipt for another ID must not erase the unresolved first-ID error.")
            try self.check(FileManager.default.fileExists(atPath: f.watch.audioURL(for: first).path),
                           "The first incomplete ACK handler must retain its source audio.")
            try self.check(!FileManager.default.fileExists(atPath: f.watch.audioURL(for: second).path),
                           "The independently successful second receipt may prune its own source.")
            try f.deliver(firstReceipt)
            try await self.eventually("first ID recovers independently") { f.changes.current == 2 }
            try await self.settle(f)
            try self.check(f.feedback.current.last?.phase == .completed,
                           "The receipt error should clear only after the remaining failed ID recovers.")
        }

        await run("valid_ack_replay_does_not_clear_an_event_transport_failure") { f in
            let manifest = try f.seal(1)
            let receipt = try f.receipt(manifest)
            f.update()
            try await self.eventually("original task ready") { f.session.state.current.files.count == 1 }
            try f.deliver(receipt)
            try await self.eventually("original receipt committed") { f.changes.current == 1 }
            try await self.settle(f)
            let proof = try FileIdentity(f.ackURL(manifest))
            let gate = DispatchSemaphore(value: 0)
            f.session.contextGate.access { $0 = gate }
            f.session.contextGateEntered.access { $0 = false }
            f.update()
            try await self.eventually("sync held before event failure") { f.session.contextGateEntered.current }
            f.bridge.session(f.session, didFinish: WCSessionUserInfoTransfer([:]),
                             error: NSError(domain: "SyntheticEventTransport", code: 7))
            try f.deliver(receipt)
            gate.signal()
            try await self.settle(f)
            try self.check(f.feedback.current.last?.phase == .failed,
                           "An ACK replay must not clear an unrelated transport error.")
            try self.check(f.feedback.current.last?.message?.contains("事件日志") == true,
                           "The unrelated event-delivery error must remain visible.")
            try self.check(f.changes.current == 1, "An unrelated error and duplicate ACK must not change the library.")
            try self.check(try FileIdentity(f.ackURL(manifest)) == proof, "Error-source isolation must retain the durable ACK file.")
        }

        await run("corrupt_scheduling_state_blocks_defaults_without_touching_audio_then_reloads") { f in
            let manifests = try (1...6).map(f.seal)
            let originals = try manifests.map { try FileIdentity(f.watch.audioURL(for: $0)) }
            let corrupt = Data("{\"nextTurn\":99}".utf8)
            try corrupt.write(to: f.schedulingURL)
            f.restartBridge()
            f.update()
            try await self.drainQueuedWork(f)
            try self.check(f.session.state.current.allEnqueued.isEmpty && (try Data(contentsOf: f.schedulingURL)) == corrupt,
                           "An unreadable order record blocks admission and is never replaced by defaults.")
            try TransportCodec.encode(FileTransferSchedulingPolicy()).write(to: f.schedulingURL)
            f.bridge.resynchronize()
            try await self.eventually("repaired metadata resumes the bounded batch") { f.session.state.current.allEnqueued.count == 3 }
            try await self.settle(f)
            try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id }
                           == [manifests[5].id, manifests[0].id, manifests[1].id],
                           "Fallback preserves one-newest/two-oldest fairness within three battery tasks.")
            try self.check(try f.watch.events().filter { $0.kind == "file_transfer_state_load_failed" }.count == 1,
                           "Corrupt scheduling state must leave one diagnostic event.")
            for (manifest, original) in zip(manifests, originals) {
                try self.check(try FileIdentity(f.watch.audioURL(for: manifest)) == original,
                               "Scheduling-state repair must not modify or delete audio.")
            }
            try self.check(f.changes.current == 0, "Scheduling fallback is not a recording-library mutation.")
            _ = try TransportCodec.decode(FileTransferSchedulingPolicy.self, from: Data(contentsOf: f.schedulingURL))
        }

        await run("scheduling_save_failure_keeps_memory_rotation_and_original_audio") { f in
            var manifests = try (1...12).map(f.seal)
            var originals = try manifests.map { try FileIdentity(f.watch.audioURL(for: $0)) }
            // This synthetic destination cannot be replaced by a JSON file.
            try FileManager.default.createDirectory(at: f.schedulingURL, withIntermediateDirectories: false)
            f.update()
            try await self.eventually("initial unsaved rotation") { f.session.state.current.allEnqueued.count == 3 }
            try await self.drainQueuedWork(f)
            var replacementSequences: [Int] = []
            for sequence in 13...18 {
                let manifest = try f.seal(sequence)
                manifests.append(manifest)
                originals.append(try FileIdentity(f.watch.audioURL(for: manifest)))
                let task = f.session.state.current.files[0]
                let before = f.session.state.current.allEnqueued.count
                // System completion frees a slot but never authorizes audio cleanup.
                f.complete(task)
                try await self.eventually("memory rotation fills one slot after failed save") {
                    f.session.state.current.allEnqueued.count == before + 1
                }
                try await self.drainQueuedWork(f)
                replacementSequences.append(f.session.state.current.allEnqueued.last!.manifest!.sequence)
            }
            try await self.settle(f)
            try self.check(replacementSequences == [13, 3, 4, 16, 5, 6],
                           "Failed persistence preserves one-newest/two-oldest memory rotation within three native slots.")
            try self.check(try f.watch.events().contains { $0.kind == "file_scheduling_state_save_failed" },
                           "Failed scheduling persistence must be diagnosable.")
            for (manifest, original) in zip(manifests, originals) {
                try self.check(try FileIdentity(f.watch.audioURL(for: manifest)) == original,
                               "Scheduling persistence failures and transport completions must retain exact source audio.")
            }
            try self.check(try f.watch.pendingSegments().count == manifests.count,
                           "No scheduling error or transport completion may acknowledge a segment.")
            try self.check(f.session.state.current.maximumOutstanding == 3, "Save failure cannot exceed the real system bound.")
            try self.check(f.changes.current == 0, "Save failures cannot publish a successful recording mutation.")
        }

        await run("candidate_missing_after_pending_snapshot_does_not_consume_turn") { f in
            let manifests = try (1...6).map(f.seal)
            let newest = manifests.last!
            let source = f.watch.audioURL(for: newest)
            let preserved = f.root.appendingPathComponent("temporarily-preserved-source.caf")
            let original = try FileIdentity(source)
            let gate = DispatchSemaphore(value: 0)
            f.session.contextGate.access { $0 = gate }
            f.update()
            try await self.eventually("pending snapshot already read") { f.session.contextGateEntered.current }
            try FileManager.default.moveItem(at: source, to: preserved)
            defer {
                if FileManager.default.fileExists(atPath: preserved.path) {
                    try? FileManager.default.moveItem(at: preserved, to: source)
                }
            }
            gate.signal()
            try await self.eventually("missing candidate skipped") { f.session.state.current.allEnqueued.count == 3 }
            try self.check(f.session.state.current.allEnqueued.compactMap { $0.manifest?.id }
                           == [manifests[4].id, manifests[0].id, manifests[1].id],
                           "A missing newest candidate must not consume its turn; the next newest is followed by the two oldest candidates.")
            try self.check(f.session.state.current.allEnqueued.allSatisfy { $0.manifest?.id != newest.id },
                           "A missing file must never be submitted to the transport.")
            try FileManager.default.moveItem(at: preserved, to: source)
            try await self.settle(f)
            try self.check(try FileIdentity(source) == original, "The synthetic race must retain the exact original audio.")
            try self.check(f.changes.current == 0, "A skipped candidate cannot become an acknowledgement.")
            try self.check(f.session.state.current.maximumOutstanding == 3, "Skipping a candidate must preserve the slot bound.")
        }
    }
}

@main struct Main {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let probe = Probe(root: URL(fileURLWithPath: args[2]))
        await probe.execute()
        let failures = probe.cases.filter { $0["status"] as? String == "failed" }
        let result: [String: Any] = ["status": failures.isEmpty ? "passed" : "failed",
            "caseCount": probe.cases.count, "assertionCount": probe.assertions,
            "cases": probe.cases, "failures": failures]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: args[1]))
        print(String(data: data, encoding: .utf8)!)
        if !failures.isEmpty { exit(1) }
    }
}
