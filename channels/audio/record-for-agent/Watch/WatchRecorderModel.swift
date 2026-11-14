import AVFoundation
import Combine
import Foundation
import OSLog
import RecordingCore
import WatchKit

/// Read-only presentation of existing capture evidence and operations.
/// Preparing an engine is never sufficient to present a live recording.
enum WatchRecorderUIPhase {
    case idle, checking, starting, recording, paused, saving, ended, recovering, interrupted
}

@MainActor
final class WatchRecorderModel: ObservableObject {
    // Background launches and the SwiftUI scene must share one WCSession owner.
    // A headless WC launch only creates the bounded transfer receiver. Audio
    // recovery, history statistics and audio-session observers wait for the UI.
    static let shared: WatchRecorderModel = {
        WatchStartupDiagnostics.shared.recordOnce(.modelConstructionStarted)
        let model = WatchRecorderModel()
        WatchStartupDiagnostics.shared.recordOnce(.modelConstructionCompleted)
        return model
    }()
    @Published private(set) var observationPreparationMessage = "检查现有同步记录；是否可用于观察，以电脑端检查结果为准。"
    private var observationPreparationRequest = UUID()
    private var observationPreparationCooldownSeconds = 0
    @Published private(set) var snapshot = RecorderSnapshot(state: .idle)
    @Published private(set) var effectiveDuration: TimeInterval = 0
    @Published private(set) var sealedCount = 0
    @Published private(set) var freeBytes: Int64?
    @Published private(set) var isBusy = true
    @Published private(set) var activityText = "正在检查本地录音"
    @Published private(set) var errorMessage: String?
    @Published private(set) var syncWarning: String?
    @Published private(set) var recoveryMessage: String?
    @Published private(set) var pendingCountIsKnown = false
    @Published private(set) var pendingCountIsRefreshing = false
    @Published private(set) var transferMessage: String?
    @Published private(set) var syncFeedback = SyncFeedback()
    @Published private(set) var syncTapCoolingDown = false
    @Published private(set) var batteryLevel: Float = -1
    @Published private(set) var integrityAuditMessage: String?
    @Published private(set) var isForeground = false
    // This controller keeps local UI state only; its system driver waits for
    // real foreground entry and the first initialized UI status.
    let recordingLocation = RecordingLocationManager()
    let waveform = WatchRecordingWaveform()

    private var repository: RecordingRepository?
    private var writer: AudioSegmentWriter?
    private var bridge: WatchTransferBridge?
    private var engine: AVAudioEngine?
    private var engineStartedAt: Date?
    private var tapInstalled = false
    private var wantsRecording = false
    private var interruptionActive = false
    private var recoveryPolicy = AudioRecoveryPolicy()
    private var activeAttempt: CaptureAttempt?
    private var pendingStart: CaptureAttempt?
    private var pendingRetry: (permit: AudioRecoveryPolicy.RetryPermit, reason: String)?
    private var retryTask: Task<Void, Never>?
    private var finishing = false
    private var operation = UUID()
    private var initialized = false
    private var lifecyclePolicy = WatchLifecyclePolicy()
    private var lastSyncedAudioAt: Date?
    private var lastSyncedState: CaptureState?
    private var lastSyncedPendingCount: Int?
    private var lastSyncedPendingCountIsKnown: Bool?
    private var lastSyncedSealedAt: Date?
    private var lastStatusRevision: UInt64 = 0
    private var forceNextStatusSync = false
    private var lastBatteryLoggedSegmentCount = -1
    private var observers: [NSObjectProtocol] = []
    private var syncFeedbackTask: Task<Void, Never>?
    private var syncTapTask: Task<Void, Never>?
    private var userRequestedSyncFeedback = false
    private var integrityAudit: WatchIntegrityAuditCoordinator?
    private var integrityPollTask: Task<Void, Never>?
    private var transferInitializationFailed = false
    private var storageRecoveryRefreshDate: Date?
    private let logger = Logger(subsystem: "WristRecord", category: "watch-capture")

    init() {
        WatchStartupDiagnostics.shared.recordOnce(.modelInitBodyEntered)
        WatchRuntimeDiagnostics.shared.record(.modelInitializing)
        prepareTransferRuntimeIfNeeded()
    }

    /// A pre-first-unlock launch can fail to open protected storage. Retry only
    /// this lightweight owner at the next real lifecycle/background opportunity;
    /// creating the audio writer or scanning/recovering recordings waits for UI.
    @discardableResult
    private func prepareTransferRuntimeIfNeeded() -> Bool {
        guard bridge == nil else { return true }
        WatchRuntimeDiagnostics.shared.record(.transferInitializationStarted)
        do {
            WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
            let root = RecordingRepository.defaultRoot()
            let repository = try RecordingRepository(root: root, recoveryFailureHandling: .preserveAndReport,
                recoverTransactionsOnInitialization: false)
            let bridge = WatchTransferBridge(repository: repository, maintenanceAllowed: false,
                powerStateProvider: {
                    let state = WKInterfaceDevice.current().batteryState
                    return state == .charging || state == .full
                })
            self.repository = repository
            self.bridge = bridge
            bridge.onStatusQuery = { [weak self] completion in
                Task { @MainActor in
                    // A headless launch may not create/recover the writer merely
                    // to answer a status request. Unknown remains unknown.
                    guard let self, self.initialized, let writer = self.writer else {
                        completion(nil); return
                    }
                    writer.queryStatus(completion: completion)
                }
            }
            let integrityAudit = WatchIntegrityAuditCoordinator(sourceRoot: root)
            self.integrityAudit = integrityAudit
            integrityAudit.onMessage = { [weak self] message in
                Task { @MainActor in self?.integrityAuditMessage = message }
            }
            integrityAudit.acceptLaunchArguments(ProcessInfo.processInfo.arguments)
            bridge.onRepositoryChanged = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.forceNextStatusSync = true
                    // A replayed ACK must not restart a full pending-count scan
                    // during a short WC wake, even after an earlier UI launch.
                    // Live recording already refreshes its counts when sealing.
                    guard self.isForeground, self.initialized else { return }
                    self.writer?.refreshStatus()
                }
            }
            bridge.onIssue = { [weak self] message in
                Task { @MainActor in self?.transferMessage = message }
            }
            bridge.onSyncFeedback = { [weak self] value in
                Task { @MainActor in self?.receiveSyncFeedback(value) }
            }
            bridge.onBackgroundRefreshRequested = { [weak bridge] preferredDate in
                Task { @MainActor in
                    WatchRuntimeDiagnostics.shared.record(.refreshSchedulingStarted)
                    bridge?.backgroundRefreshSchedulingStarted(preferredDate: preferredDate)
                    WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: preferredDate,
                        userInfo: nil) { error in
                            let value = error as NSError?
                        WatchRuntimeDiagnostics.shared.record(error == nil
                            ? .refreshSchedulingSucceeded : .refreshSchedulingFailed, error: error)
                            bridge?.backgroundRefreshSchedulingCompleted(preferredDate: preferredDate,
                                succeeded: error == nil, errorDomain: value?.domain, errorCode: value?.code)
                        }
                }
            }
            if transferInitializationFailed {
                transferInitializationFailed = false
                storageRecoveryRefreshDate = nil
                errorMessage = nil
                snapshot = RecorderSnapshot(state: .idle)
                isBusy = true
            }
            WatchRuntimeDiagnostics.shared.record(.transferInitializationSucceeded)
            return true
        } catch {
            WatchRuntimeDiagnostics.shared.record(.transferInitializationFailed, error: error)
            transferInitializationFailed = true
            isBusy = false
            errorMessage = "本地存储不可用：\(error.localizedDescription)"
            snapshot = RecorderSnapshot(state: .failed, detail: errorMessage)
            requestStorageRecoveryRefreshIfNeeded()
            return false
        }
    }

    private func requestStorageRecoveryRefreshIfNeeded() {
        guard storageRecoveryRefreshDate == nil else { return }
        let date = WatchBackgroundTransferPolicy.preferredRefreshDate(existing: nil, now: Date())
        storageRecoveryRefreshDate = date
        // Storage may be protected before first unlock, so do not write a
        // replacement intent. The OS alone decides whether/when this runs.
        WatchRuntimeDiagnostics.shared.record(.refreshSchedulingStarted)
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: date, userInfo: nil) { [weak self] error in
            WatchRuntimeDiagnostics.shared.record(error == nil
                ? .refreshSchedulingSucceeded : .refreshSchedulingFailed, error: error)
            guard error != nil else { return }
            Task { @MainActor in
                guard self?.storageRecoveryRefreshDate == date else { return }
                self?.storageRecoveryRefreshDate = nil
            }
        }
    }

    private func prepareForegroundRuntimeIfNeeded() {
        guard writer == nil, let repository else { return }
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        recordingLocation.isActuallyRecording = { [weak self] in self?.hasCurrentAudioEvidence == true }
        recordingLocation.onLocation = { [weak self] location in
            guard let self, self.hasCurrentAudioEvidence else { return }
            self.writer?.updateLocation(location)
        }
        recordingLocation.onClearLocation = { [weak self] in self?.writer?.updateLocation(nil) }
        let writer = AudioSegmentWriter(repository: repository, root: repository.root, waveform: waveform)
        self.writer = writer
        writer.onStatus = { [weak self] status in
            Task { @MainActor in self?.receive(status) }
        }
        writer.onFailure = { [weak self] message in
            Task { @MainActor in self?.fail(message) }
        }
        observeAudioSession()
        // load() performs the deferred transaction and tail recovery before the
        // first ready status. No background launch can start the microphone.
        writer.load()
    }

    private func updateTransferMaintenanceAvailability() {
        // Recovery backoff can remain active after the audio session stops.
        // That waiting state is not a grant for full background maintenance.
        let liveCapture = wantsRecording && engine?.isRunning == true
        bridge?.setMaintenanceAllowed((isForeground && initialized) || liveCapture,
            foreground: isForeground, liveCapture: liveCapture)
        updateIntegrityAvailability()
    }

    private var integrityCaptureActive: Bool {
        wantsRecording || engine != nil || finishing || recoveryPolicy.isActive
            || pendingStart != nil || activeAttempt != nil || pendingRetry != nil
    }

    var canRequestIntegrityAudit: Bool { initialized && !isBusy && !integrityCaptureActive }

    func requestIntegrityAudit(mode: RecordingIntegrityMode) {
        updateIntegrityAvailability()
        integrityAudit?.requestFromDiagnostics(mode: mode)
    }

    private func updateIntegrityAvailability(forceCaptureActive: Bool = false) {
        func preference(_ key: String) -> String {
            guard let value = UserDefaults.standard.object(forKey: key) as? Bool else { return "unset" }
            return value ? "true" : "false"
        }
        let microphone: String
        switch AVAudioApplication.shared.recordPermission {
        case .granted: microphone = "granted"
        case .denied: microphone = "denied"
        case .undetermined: microphone = "undetermined"
        @unknown default: microphone = "unknown"
        }
        integrityAudit?.setAvailability(foreground: isForeground,
            ready: initialized && writer != nil && !isBusy,
            captureActive: forceCaptureActive || integrityCaptureActive,
            criticalSettings: [
                "recordingRequested": wantsRecording ? "true" : "false",
                "recordingState": snapshot.state.rawValue,
                "recordLocations": preference("RecordForAgent.recordLocations"),
                "locationIntroductionHandled": preference("RecordForAgent.locationIntroductionHandled"),
                "microphoneAuthorization": microphone
            ])
    }

    private func startIntegrityPolling() {
        guard integrityPollTask == nil else { return }
        integrityPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isForeground else { return }
                self.updateIntegrityAvailability()
                self.integrityAudit?.pollMailbox()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    var canStart: Bool { !isBusy && writer != nil && engine == nil && !finishing && !recoveryPolicy.isActive }
    var canSynchronize: Bool { bridge != nil && !syncTapCoolingDown }
    var pendingCountText: String {
        guard hasDisplayablePendingCount else { return pendingCountIsRefreshing ? "核对中" : "暂无法核对" }
        return "\(snapshot.pendingCount) 段"
    }
    var hasDisplayablePendingCount: Bool {
        pendingCountIsKnown || snapshot.pendingCount > 0
    }
    var canEnd: Bool {
        guard !finishing else { return false }
        return engine != nil || (snapshot.sessionID != nil
            && (snapshot.state == .interrupted || activeAttempt?.isAutomatic == true))
    }

    func uiPhase(at date: Date = Date()) -> WatchRecorderUIPhase {
        if finishing { return .saving }
        if !initialized && isBusy { return .checking }
        if audioNeedsConfirmation(at: date) { return .interrupted }
        if hasCurrentAudioEvidence { return .recording }
        if wantsRecording && !interruptionActive {
            if activeAttempt?.isAutomatic == true || pendingStart?.isAutomatic == true
                || pendingRetry != nil || retryTask != nil {
                return .recovering
            }
            if activeAttempt != nil || isBusy || engine != nil { return .starting }
        }
        if isBusy { return .starting }
        if errorMessage != nil && snapshot.state != .ended { return .interrupted }
        switch snapshot.state {
        case .idle: return .idle
        case .starting: return .starting
        case .recording, .interrupted, .failed: return .interrupted
        case .paused: return .paused
        case .ended: return .ended
        }
    }

    func audioNeedsConfirmation(at date: Date = Date()) -> Bool {
        guard !isBusy, !finishing, let engine, let engineStartedAt else { return false }
        let lastEvidence = max(engineStartedAt, snapshot.lastAudioAt ?? engineStartedAt)
        return !engine.isRunning || date.timeIntervalSince(lastEvidence) > 5
    }

    func recoverStalledCapture() {
        guard audioNeedsConfirmation() else { return }
        updateIntegrityAvailability(forceCaptureActive: true)
        wantsRecording = true
        cancelCaptureAttempts(reason: "user_reconnect")
        finishCapture(state: .interrupted, detail: "音频状态待确认，你已选择重新连接麦克风。")
        requestAutomaticResume(reason: "user_reconnect")
    }

    func startOrResume() {
        guard canStart else { return }
        let requestedAt = ContinuousClock.now
        wantsRecording = true
        interruptionActive = false
        cancelCaptureAttempts(reason: "user_start")
        guard let token = recoveryPolicy.begin(.manual) else { return }
        beginCapture(CaptureAttempt(token: token, reason: "user_start", isAutomatic: false, requestedAt: requestedAt))
    }

    func end() {
        guard canEnd else { return }
        wantsRecording = false
        cancelCaptureAttempts(reason: "user_end")
        errorMessage = nil
        finishCapture(state: .ended, detail: "本次录音已结束。已保存片段会继续等待手机确认。")
    }

    func synchronize() {
        guard canSynchronize else { return }
        let requestedAt = Date()
        guard syncFeedback.beginRequest(at: requestedAt) else { return }
        transferMessage = nil
        userRequestedSyncFeedback = true
        syncTapCoolingDown = true
        WKInterfaceDevice.current().play(.click)
        syncTapTask?.cancel()
        syncTapTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            self?.syncTapCoolingDown = false
        }
        forceNextStatusSync = true
        writer?.refreshStatus()
        bridge?.resynchronize(requestedAt: requestedAt)
        startSyncFeedbackUpdates()
    }

    func performBackgroundConnectivityTask(id: UUID, completion: @escaping @Sendable () -> Void) {
        prepareTransferRuntimeIfNeeded()
        guard let bridge else { completion(); return }
        bridge.performBackgroundConnectivityTask(id: id, completion: completion)
    }

    func expireBackgroundConnectivityTask(id: UUID) {
        bridge?.expireBackgroundConnectivityTask(id: id)
    }

    func performBackgroundRefreshTask(id: UUID, completion: @escaping @Sendable () -> Void) {
        storageRecoveryRefreshDate = nil
        prepareTransferRuntimeIfNeeded()
        guard let bridge else { completion(); return }
        bridge.performBackgroundRefreshTask(id: id, completion: completion)
    }

    /// Both lifecycle APIs converge here before any writer or transfer effects.
    /// In particular, a late scene value cannot undo WatchKit's resign edge.
    func observeLifecycle(source: WatchLifecyclePolicy.Source, phase: WatchLifecyclePolicy.Phase) {
        let applicationPhase: WatchLifecyclePolicy.Phase
        switch WKApplication.shared().applicationState {
        case .active: applicationPhase = .active
        case .inactive: applicationPhase = .inactive
        case .background: applicationPhase = .background
        @unknown default: applicationPhase = .unknown
        }
        let decision = lifecyclePolicy.observe(source: source, phase: phase, applicationPhase: applicationPhase)
        WatchRuntimeDiagnostics.shared.record(.lifecycleObserved, lifecycle: decision)
        if decision.forwardBackground {
            enteredBackground()
        } else if decision.action == .enterForeground {
            becameActive()
        } else if decision.action == .leaveForeground {
            becameInactive()
        }
    }

    private func becameActive() {
        WatchRuntimeDiagnostics.shared.record(.becameActive)
        prepareTransferRuntimeIfNeeded()
        bridge?.foregroundDidChange(true)
        isForeground = true
        prepareForegroundRuntimeIfNeeded()
        recordingLocation.setForeground(true)
        recordingLocation.refreshAuthorization()
        updateTransferMaintenanceAvailability()
        bridge?.observeDiagnosticEvidence()
        startIntegrityPolling()
        guard initialized else { return }
        startSyncFeedbackUpdates()
        forceNextStatusSync = true
        writer?.refreshStatus()
        bridge?.resynchronize()
        // Inspect the writer's current evidence after its pending buffers, since the
        // foreground UI may still be displaying an older queued status callback.
        let token = operation
        writer?.inspectAudioFreshness { [weak self] lastAudioAt, checkedAt in
            Task { @MainActor in
                guard let self, self.operation == token, self.wantsRecording,
                      let engine = self.engine, let startedAt = self.engineStartedAt,
                      !self.isBusy else { return }
                let lastEvidence = max(startedAt, lastAudioAt ?? startedAt)
                guard !engine.isRunning || checkedAt.timeIntervalSince(lastEvidence) > 5 else { return }
                // Foreground entry never silently restarts an unconfirmed microphone.
                self.wantsRecording = false
                self.cancelCaptureAttempts(reason: "foreground_audio_unconfirmed")
                self.errorMessage = nil
                self.finishCapture(state: .interrupted, detail: "未收到新的麦克风音频，录音已中断，请点击继续。")
            }
        }
    }

    /// Existing diagnostic owners only; no lifecycle transition or sync request.
    func prepareObservationSnapshots() {
        let request = UUID(); observationPreparationRequest = request
        observationPreparationCooldownSeconds = 0
        observationPreparationMessage = "已请求检查现有同步记录；是否可用于观察，以电脑端检查结果为准。"
        let onThrottle: @Sendable (Int) -> Void = { [weak self] seconds in
            Task { @MainActor in
                guard let self, self.observationPreparationRequest == request else { return }
                self.observationPreparationCooldownSeconds = max(self.observationPreparationCooldownSeconds, seconds)
                self.observationPreparationMessage = "刚刚已准备，\(self.observationPreparationCooldownSeconds) 秒后可再次准备。"
            }
        }
        bridge?.observeDiagnosticEvidence(onThrottle: onThrottle)
        WatchRuntimeDiagnostics.shared.prepareObservationSnapshot(onThrottle: onThrottle)
    }

    private func becameInactive() {
        WatchRuntimeDiagnostics.shared.record(.becameInactive)
        relinquishForegroundOwnership()
    }

    private func relinquishForegroundOwnership() {
        bridge?.foregroundDidChange(false)
        isForeground = false
        waveform.setVisible(false)
        updateTransferMaintenanceAvailability()
        recordingLocation.setForeground(false)
        syncFeedbackTask?.cancel()
        syncFeedbackTask = nil
        integrityPollTask?.cancel()
        integrityPollTask = nil
    }

    private func enteredBackground() {
        WatchRuntimeDiagnostics.shared.record(.enteredBackground)
        // WatchKit can deliver this edge without a SwiftUI scene transition.
        // Retire the foreground owner before queued receipts or maintenance can
        // observe it; an actually running capture keeps its separate permission.
        relinquishForegroundOwnership()
        bridge?.enteredBackground()
    }

    private func receiveSyncFeedback(_ value: SyncFeedback) {
        // An already-queued callback must not erase the tap's immediate response.
        if let request = syncFeedback.lastRequestedAt,
           value.lastRequestedAt == nil || value.lastRequestedAt! < request { return }
        let previousPhase = syncFeedback.phase
        syncFeedback = value
        // A successful observation removes stale transfer warnings. A failure's
        // message comes from the same bridge observation as its state.
        transferMessage = value.message
        guard userRequestedSyncFeedback, WKApplication.shared().applicationState == .active else { return }
        if value.phase == .completed && previousPhase != .completed,
           pendingCountIsKnown, snapshot.pendingCount == 0 {
            WKInterfaceDevice.current().play(.success)
            userRequestedSyncFeedback = false
        } else if value.phase == .failed && previousPhase != .failed {
            WKInterfaceDevice.current().play(.failure)
            userRequestedSyncFeedback = false
        } else if value.phase == .idle {
            userRequestedSyncFeedback = false
        }
    }

    private func startSyncFeedbackUpdates() {
        guard syncFeedbackTask == nil else { return }
        syncFeedbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard WKApplication.shared().applicationState == .active,
                      self.isForeground, self.initialized else {
                    self.syncFeedbackTask = nil
                    return
                }
                self.bridge?.renewForegroundMaintenance()
                if !self.pendingCountIsKnown {
                    self.writer?.retrySyncStatusIfNeeded()
                }
                if !self.pendingCountIsKnown || self.syncFeedback.phase == .failed
                    || (self.syncFeedback.pendingCount ?? self.snapshot.pendingCount) > 0 {
                    self.bridge?.refreshFeedback()
                }
            }
        }
    }

    private func beginCapture(_ attempt: CaptureAttempt) {
        guard writer != nil, wantsRecording, !finishing, !isBusy, engine == nil,
              !interruptionActive, recoveryPolicy.isCurrent(attempt.token) else { return }
        updateIntegrityAvailability(forceCaptureActive: true)
        operation = UUID()
        let token = operation
        activeAttempt = attempt
        isBusy = true
        activityText = "正在准备麦克风"
        errorMessage = nil
        logCapture("capture_attempt_started", attempt: attempt, detail: "stage=permission")
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            continueAfterMicrophonePermission(true, attempt: attempt, operation: token)
        case .denied:
            continueAfterMicrophonePermission(false, attempt: attempt, operation: token)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    self?.continueAfterMicrophonePermission(granted, attempt: attempt, operation: token)
                }
            }
        @unknown default:
            continueAfterMicrophonePermission(false, attempt: attempt, operation: token)
        }
    }

    private func continueAfterMicrophonePermission(_ granted: Bool, attempt: CaptureAttempt, operation token: UUID) {
        guard operation == token, wantsRecording, let writer else { return }
        guard granted else {
            wantsRecording = false
            cancelCaptureAttempts(reason: "microphone_permission_denied")
            isBusy = false
            errorMessage = "未获得麦克风权限。请在手表设置中允许 WristRecord 使用麦克风。"
            writer.log(kind: "microphone_permission_denied", detail: "用户未授权麦克风")
            // Closing a recovery epoch never clears its unacknowledged files.
            writer.closePriorityCapture()
            return
        }
        let permissionMS = attempt.elapsedMS
        writer.prepare(startNewPriorityEpoch: !attempt.isAutomatic) { [weak self] result in
            Task { @MainActor in
                guard let self, self.operation == token, self.wantsRecording else { return }
                switch result {
                case .success: self.startEngine(attempt, permissionMS: permissionMS)
                case .failure(let error):
                    self.logCapture("capture_attempt_error", attempt: attempt,
                                    detail: "stage=writer_prepare elapsed_ms=\(attempt.elapsedMS) \(self.describe(error))")
                    // Storage failures are not audio-session recovery candidates.
                    self.fail("无法开始录音：\(error.localizedDescription)")
                }
            }
        }
    }

    private func startEngine(_ attempt: CaptureAttempt, permissionMS: Int64) {
        guard let writer, wantsRecording, !interruptionActive,
              recoveryPolicy.isCurrent(attempt.token) else { return }
        let writerReadyMS = attempt.elapsedMS
        var stage = "set_category"
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .default, options: [])
            stage = "activate_session"
            try audioSession.setActive(true)
            stage = "input_format"
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CaptureError.unavailableMicrophone
            }
            self.engine = engine
            input.installTap(onBus: 0, bufferSize: 8_192, format: format) { buffer, time in
                writer.receive(buffer, at: time)
            }
            tapInstalled = true
            engine.prepare()
            let captureBoundary = Date()
            writer.enableInput()
            stage = "start_engine"
            try engine.start()
            engineStartedAt = captureBoundary
            updateTransferMaintenanceAvailability()
            isBusy = false
            activityText = "等待实际音频"
            logCapture("capture_engine_started", attempt: attempt,
                       detail: "stage=awaiting_audio permission_ms=\(permissionMS) writer_ready_ms=\(writerReadyMS) engine_ready_ms=\(attempt.elapsedMS) rate=\(format.sampleRate) channels=\(format.channelCount)")
            logger.info("Engine started: rate=\(format.sampleRate), channels=\(format.channelCount)")
            // No timer changes the state to recording. Only received, written audio does that.
        } catch { handleStartFailure(error, stage: stage, attempt: attempt) }
    }

    private func finishCapture(state: CaptureState, detail: String) {
        operation = UUID() // Cancel any outstanding permission / preparation continuation.
        guard !finishing else { return }
        finishing = true
        isBusy = true
        updateIntegrityAvailability(forceCaptureActive: true)
        activityText = "正在保存最后一段"
        stopEngine()
        guard let writer else { finishing = false; isBusy = false; return }
        // The writer closes priority only after its tail transaction is durable.
        // Temporary audio interruptions retain the same logical capture epoch.
        writer.finish(state: state, detail: detail, priorityCaptureContinues: wantsRecording) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.finishing = false
                self.isBusy = false
                self.updateIntegrityAvailability()
                // A terminal error can revoke recording intent while the tail
                // is draining. The writer revalidates durability before closing.
                if !self.wantsRecording { self.writer?.closePriorityCapture() }
                self.continueRecoveryIfReady()
            }
        }
    }

    private func stopEngine() {
        recordingLocation.setRecordingActive(false)
        writer?.disableInput()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine?.stop()
        engine = nil
        engineStartedAt = nil
        updateTransferMaintenanceAvailability()
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { logCapture("capture_deactivation_error", detail: "stage=deactivate_session \(describe(error))") }
    }

    private func fail(_ message: String) {
        wantsRecording = false
        cancelCaptureAttempts(reason: "capture_failed")
        errorMessage = message
        logger.error("Capture failure: \(message, privacy: .private)")
        if !finishing { finishCapture(state: .failed, detail: message) }
    }

    private func requestAutomaticResume(reason: String) {
        guard wantsRecording, !interruptionActive, engine == nil,
              let token = recoveryPolicy.begin(.automaticRecovery) else { return }
        let attempt = CaptureAttempt(token: token, reason: reason, isAutomatic: true, requestedAt: .now)
        pendingStart = attempt
        logCapture("automatic_resume_attempt", attempt: attempt, detail: "authorized=true")
        continueRecoveryIfReady()
    }

    private func handleStartFailure(_ error: Error, stage: String, attempt: CaptureAttempt) {
        logCapture("capture_attempt_error", attempt: attempt, detail: "stage=\(stage) \(describe(error))")
        let message = "麦克风暂时不可用：\(error.localizedDescription)"
        switch recoveryPolicy.failed(attempt.token) {
        case .ignored:
            return
        case .stop:
            if !attempt.isAutomatic {
                fail(message)
                return
            }
            wantsRecording = false
            let retries = recoveryPolicy.retryCount
            cancelCaptureAttempts(reason: "automatic_resume_exhausted")
            let detail = "自动恢复未成功，录音已中断。请点击继续录音。\(message)"
            errorMessage = detail
            logCapture("automatic_resume_exhausted", attempt: attempt,
                       detail: "requires_user=true retries=\(retries)")
            finishCapture(state: .interrupted, detail: detail)
        case .retry(let permit):
            activeAttempt = nil
            pendingRetry = (permit, attempt.reason)
            let detail = "录音已中断，\(Int(permit.delay)) 秒后尝试恢复；等待期间不计入录音时长。"
            errorMessage = detail
            // Drain and seal before scheduling; retries never overlap the previous writer operation.
            finishCapture(state: .interrupted, detail: detail)
        }
    }

    private func continueRecoveryIfReady() {
        guard wantsRecording, !interruptionActive, !finishing, !isBusy, engine == nil else { return }
        if let attempt = pendingStart {
            pendingStart = nil
            beginCapture(attempt)
            return
        }
        guard retryTask == nil, let retry = pendingRetry else { return }
        pendingRetry = nil
        let token = operation
        logCapture("automatic_resume_scheduled", detail: "delay=\(retry.permit.delay) reason=\(retry.reason)")
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(retry.permit.delay * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled, self.operation == token else { return }
            self.retryTask = nil
            guard self.wantsRecording, !self.interruptionActive, !self.finishing,
                  !self.isBusy, self.engine == nil,
                  let next = self.recoveryPolicy.consume(retry.permit) else { return }
            self.beginCapture(CaptureAttempt(token: next, reason: retry.reason, isAutomatic: true, requestedAt: .now))
        }
    }

    private func cancelCaptureAttempts(reason: String) {
        if recoveryPolicy.isActive {
            logCapture("capture_attempts_cancelled", detail: "reason=\(reason)")
        }
        operation = UUID()
        retryTask?.cancel()
        retryTask = nil
        pendingStart = nil
        pendingRetry = nil
        activeAttempt = nil
        recoveryPolicy.cancel()
    }

    private struct CaptureAttempt: Sendable {
        let id = UUID()
        let token: AudioRecoveryPolicy.Attempt
        let reason: String
        let isAutomatic: Bool
        let requestedAt: ContinuousClock.Instant

        var elapsedMS: Int64 {
            let duration = requestedAt.duration(to: .now).components
            return duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
        }
    }

    private func logCapture(_ kind: String, attempt: CaptureAttempt? = nil, detail: String) {
        let context = "appState=\(applicationState) wantsRecording=\(wantsRecording) interruption=\(interruptionActive) engineRunning=\(engine?.isRunning ?? false) retryCount=\(recoveryPolicy.retryCount)"
        let identity = attempt.map { "attempt=\($0.id.uuidString) reason=\($0.reason) automatic=\($0.isAutomatic) " } ?? ""
        let value = identity + detail + " " + context
        writer?.log(kind: kind, detail: value)
        logger.info("\(kind, privacy: .public): \(value, privacy: .private)")
    }

    private var applicationState: String {
        switch WKApplication.shared().applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private func describe(_ error: Error, depth: Int = 0) -> String {
        let value = error as NSError
        var result = "domain=\(value.domain) code=\(value.code) description=\(value.localizedDescription)"
        if depth < 3, let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
            result += " underlying={\(describe(underlying, depth: depth + 1))}"
        }
        return result
    }

    private func receive(_ status: WatchRecordingStatus) {
        guard status.revision > lastStatusRevision else { return }
        lastStatusRevision = status.revision
        snapshot = status.snapshot
        effectiveDuration = status.effectiveDuration
        sealedCount = status.sealedCount
        freeBytes = status.freeBytes
        // Warning state travels with the same revision as the capture snapshot.
        // It must never overwrite or clear a genuine microphone/storage failure.
        syncWarning = status.syncWarning
        recoveryMessage = status.recoveryMessage
        pendingCountIsKnown = status.pendingCountIsKnown
        pendingCountIsRefreshing = status.pendingCountIsRefreshing
        if !initialized {
            WatchStartupDiagnostics.shared.recordOnce(.firstWriterStatusReceived)
            initialized = true
            isBusy = false
            recordingLocation.setInterfaceReady()
            if isForeground, WKApplication.shared().applicationState == .active { startSyncFeedbackUpdates() }
            // recoveredInterruptedSessions marks the previous session; never auto-start it.
        }
        updateTransferMaintenanceAvailability()
        if status.session?.state == .recording && !finishing {
            activityText = "正在录音"
            // Old queued statuses cannot claim a new recovery succeeded. Require audio
            // captured after this engine started, not merely engine.start() returning.
            if let attempt = activeAttempt, let startedAt = engineStartedAt,
               let lastAudioAt = status.session?.lastAudioAt, lastAudioAt >= startedAt,
               let firstAudioAt = status.firstAudioAt,
               recoveryPolicy.succeeded(attempt.token) {
                logCapture("capture_attempt_audio_confirmed", attempt: attempt,
                           detail: "firstAudioAt=\(firstAudioAt.timeIntervalSince1970) lastAudioAt=\(lastAudioAt.timeIntervalSince1970) confirmed_ms=\(attempt.elapsedMS)")
                activeAttempt = nil
                errorMessage = nil
            }
        }
        recordingLocation.setRecordingActive(hasCurrentAudioEvidence)
        let hasNewAudio = status.session?.lastAudioAt.map {
            lastSyncedAudioAt == nil || $0.timeIntervalSince(lastSyncedAudioAt!) >= 10
        } ?? false
        if forceNextStatusSync || snapshot.state != lastSyncedState || hasNewAudio
            || snapshot.pendingCount != lastSyncedPendingCount
            || snapshot.pendingCountIsKnown != lastSyncedPendingCountIsKnown
            || snapshot.lastSealedAt != lastSyncedSealedAt {
            bridge?.update(snapshot)
            lastSyncedState = snapshot.state
            lastSyncedAudioAt = snapshot.lastAudioAt
            lastSyncedPendingCount = snapshot.pendingCount
            lastSyncedPendingCountIsKnown = snapshot.pendingCountIsKnown
            lastSyncedSealedAt = snapshot.lastSealedAt
            forceNextStatusSync = false
        }
        if status.sealedCount != lastBatteryLoggedSegmentCount {
            lastBatteryLoggedSegmentCount = status.sealedCount
            batteryLevel = WKInterfaceDevice.current().batteryLevel
            let value = "battery=\(batteryLevel) effectiveSeconds=\(status.effectiveDuration)"
            writer?.log(kind: "capture_telemetry", detail: value)
            // Capacity observations stay in the Watch's local diagnostics.
            let localValue = "\(value) freeBytes=\(status.freeBytes ?? -1)"
            writer?.log(kind: "capture_storage_telemetry", detail: localValue)
            logger.info("\(localValue, privacy: .private)")
        }
    }

    private var hasCurrentAudioEvidence: Bool {
        guard wantsRecording, !isBusy, !finishing, !interruptionActive,
              engine?.isRunning == true, let engineStartedAt,
              snapshot.state == .recording, let lastAudioAt = snapshot.lastAudioAt,
              lastAudioAt >= engineStartedAt else { return false }
        return Date().timeIntervalSince(lastAudioAt) <= 5
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.interruption(type: type, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor in self?.routeChanged(reason: reason) }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: nil, queue: nil) { [weak self] notification in
            guard let changedEngine = notification.object as? AVAudioEngine else { return }
            let identity = ObjectIdentifier(changedEngine)
            // Hop off the engine notification queue before destroying or rebuilding the engine.
            Task { @MainActor in self?.configurationChanged(engineID: identity) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantsRecording else { return }
                self.wantsRecording = false
                self.cancelCaptureAttempts(reason: "media_services_reset")
                self.errorMessage = nil
                self.finishCapture(state: .interrupted, detail: "系统音频服务已重置，请点击继续。")
            }
        })
    }

    private func interruption(type rawType: UInt?, options rawOptions: UInt) {
        logCapture("audio_interruption", detail: "type=\(rawType.map { String($0) } ?? "missing") options=\(rawOptions)")
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            interruptionActive = true
            guard wantsRecording else { return }
            cancelCaptureAttempts(reason: "system_interruption_began")
            finishCapture(state: .interrupted, detail: "麦克风被系统或其他应用占用；未录到的时间会保留为缺口。")
        case .ended:
            interruptionActive = false
            guard wantsRecording else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            guard options.contains(.shouldResume) else {
                wantsRecording = false
                cancelCaptureAttempts(reason: "system_resume_not_recommended")
                errorMessage = "系统未给出自动恢复提示，请点击继续。"
                writer?.log(kind: "resume_requires_user", detail: "中断结束，未收到 shouldResume 提示")
                writer?.closePriorityCapture()
                return
            }
            requestAutomaticResume(reason: "system_should_resume")
        @unknown default: break
        }
    }

    private func routeChanged(reason: UInt) {
        logCapture("audio_route_changed", detail: "reason=\(reason)")
        guard wantsRecording, let engine, !engine.isRunning, !isBusy, !interruptionActive else { return }
        recoverStoppedEngine(reason: "route_changed", detail: "音频输入发生变化，正在尝试恢复。")
    }

    private func configurationChanged(engineID: ObjectIdentifier) {
        guard let engine, ObjectIdentifier(engine) == engineID else { return }
        logCapture("audio_engine_configuration_changed", detail: "current_engine=true")
        guard wantsRecording, !engine.isRunning, !isBusy, !interruptionActive else { return }
        recoverStoppedEngine(reason: "configuration_changed", detail: "音频硬件格式发生变化，正在重新连接。")
    }

    private func recoverStoppedEngine(reason: String, detail: String) {
        if let attempt = activeAttempt, recoveryPolicy.isCurrent(attempt.token) {
            // A new engine stopping before its first confirmed audio uses the same
            // recovery budget; notifications must not keep creating fresh retry chains.
            handleStartFailure(CaptureError.engineStopped, stage: reason, attempt: attempt)
            return
        }
        finishCapture(state: .interrupted, detail: detail)
        requestAutomaticResume(reason: reason)
    }

    private enum CaptureError: LocalizedError {
        case unavailableMicrophone, engineStopped
        var errorDescription: String? {
            switch self {
            case .unavailableMicrophone: return "没有可用的麦克风输入"
            case .engineStopped: return "收到实际音频前，音频引擎已停止"
            }
        }
    }
}
