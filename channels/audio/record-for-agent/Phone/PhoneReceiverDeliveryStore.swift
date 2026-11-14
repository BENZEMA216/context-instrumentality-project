import Combine
import CryptoKit
import Darwin
import Foundation
import RecordingCore

protocol AutomaticDeliveryExecutionLease: Sendable {
    var hasTimeRemaining: Bool { get }
    func end()
}

@MainActor
final class PhoneReceiverDeliveryStore: ObservableObject, Identifiable {
    let id: UUID
    var receiverID: UUID { id }
    let displayName: String
    @Published private(set) var isEnabled = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isPaired = false
    @Published private(set) var receiverName = ""
    @Published private(set) var availableRecordings: [SegmentManifest] = []
    @Published private(set) var receivedSegmentIDs: Set<UUID> = []
    @Published private(set) var hasLibrarySnapshot = false
    @Published private(set) var deliveredCount = 0
    /// UI-only projection of this receiver's validated, durably persisted receipts.
    /// `receivedSegmentIDs` above refers to Phone storage, not Agent delivery.
    @Published private(set) var deliveredSegmentIDs: Set<UUID> = []
    @Published private(set) var lastReceiptAt: Date?
    @Published private(set) var isCheckingConnection = false
    @Published private(set) var lastProbeAt: Date?
    @Published private(set) var lastProbeFailure: AutomaticReceiverFailureCategory?
    @Published private(set) var isProbeUnsupported = false
    @Published private(set) var lastTransferAt: Date?
    @Published private(set) var lastTransferFailure: AutomaticReceiverFailureCategory?
    @Published private(set) var lastTransferDeliveryID: UUID?
    /// Persisted delivery history, never a live reachability observation.
    /// This is the job update time, including retry registration, not its first failure time.
    @Published private(set) var lastIncompleteDeliveryAt: Date?
    @Published private(set) var lastIncompleteDeliveryMessage: String?
    @Published private(set) var queuedCount = 0
    @Published private(set) var uploadingCount = 0
    @Published private(set) var blockedCount = 0
    @Published private(set) var blockedReason: String?
    @Published private(set) var activity = "已有和新增录音会独立同步到此接收端。"
    @Published private(set) var error: String?

    private let repository: RecordingRepository
    private let transcriptRepository: TranscriptRepository?
    private let root: URL
    private let persistEnabled: (Bool) throws -> Void
    private let clientFactory: AutomaticReceiverClientFactory
    private let healthCheck: AutomaticReceiverHealthCheck
    private let healthDate: @Sendable () -> Date
    private let transcriptClientFactory: AutomaticReceiverTranscriptClientFactory
    private let onTranscriptDidSave: (SegmentManifest) -> Void
    private let schedulesRetries: Bool
    private let requestBackgroundRetry: (Date) -> Void
    private let diagnostic: @Sendable (String, String) -> Void
    private let transferCheckDate: @Sendable () -> Date
    private let beginExecution: @Sendable (@escaping @Sendable (String) -> Void) async -> (any AutomaticDeliveryExecutionLease)?
    private let restorationGate: BackgroundSessionRestorationGate?
    private var handoffTask: Task<Void, Never>?
    private var transportEpoch = UUID()
    private var constructingTransport = false
    private var recoveringTransport = false
    private var executionLease: (any AutomaticDeliveryExecutionLease)?
    private var storedEnabled: Bool?
    private var retired = false
    private var credentials: AutomaticReceiverCredentials?
    private var ledger: AutomaticDeliveryLedger?
    private var client: (any AutomaticReceiverTransport)?
    private var transcriptReturn: PhoneReceiverTranscriptReturn?
    private var workTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var reconcilePending = false
    private var isReconciling = false
    private var workRequested = false
    private var generation: UInt64 = 0
    private var uploadLiveness = AutomaticDeliveryTransferLiveness()
    private var restored = false
    private var lastProbeStartedAt: Date?
    private var localTransferError: (deliveryID: UUID, message: String)?
    private(set) var preparationSucceeded = true

    private struct Settings: Codable {
        let schemaVersion: Int
        let grantEpoch: UUID
        let enabled: Bool
    }

    /// Metadata only, scoped to the existing grant. No endpoint, error text,
    /// recording path, token or request/response body is stored here.
    private struct ConnectionHistory: Codable {
        let schemaVersion: Int
        let grantEpoch: UUID
        let probeAt: Date?
        let probeFailure: AutomaticReceiverFailureCategory?
        let probeUnsupported: Bool?
        let transferAt: Date?
        let transferFailure: AutomaticReceiverFailureCategory?
        let transferDeliveryID: UUID?
    }
    private static let historySaveError = "连接状态记录未能保存，请检查手机存储后重试。"
    private static let historyRestoreError = "连接状态记录暂不可用，请重新检查连接。配对和交付队列仍保留。"
    private static let repairRequiredMessage = AutomaticReceiverFailureCategory.pairingRepairRequired.title
        + "。" + AutomaticReceiverFailureCategory.pairingRepairRequired.hint
    private static let naturalProbeInterval: TimeInterval = 30

    init(pairing: AutomaticReceiverStoredPairing, repository: RecordingRepository,
         transcriptRepository: TranscriptRepository?,
         persistEnabled: @escaping (Bool) throws -> Void,
         schedulesRetries: Bool = true,
         requestBackgroundRetry: @escaping (Date) -> Void = { _ in },
         diagnostic: @escaping @Sendable (String, String) -> Void = { _, _ in },
         healthCheck: @escaping AutomaticReceiverHealthCheck = { await AutomaticReceiverHealthClient.check($0) },
         healthDate: @escaping @Sendable () -> Date = { Date() },
         transferCheckDate: @escaping @Sendable () -> Date = { Date() },
         beginExecution: @escaping @Sendable (@escaping @Sendable (String) -> Void) async -> (any AutomaticDeliveryExecutionLease)? = {
             await PhoneReceiverDeliveryStore.systemExecutionLease(diagnostic: $0)
         },
         restorationGate: BackgroundSessionRestorationGate? = nil,
         onTranscriptDidSave: @escaping (SegmentManifest) -> Void = { _ in },
         transcriptClientFactory: @escaping AutomaticReceiverTranscriptClientFactory = {
             try AutomaticReceiverTranscriptClient(credentials: $0)
         },
         clientFactory: @escaping AutomaticReceiverClientFactory = { credentials, complete, finished in
             try AutomaticReceiverClient(credentials: credentials, complete: complete, finishedEvents: finished)
         }) {
        #if os(iOS)
        self.restorationGate = restorationGate ?? AutomaticDeliveryBackgroundEvents.shared.gate
        #else
        self.restorationGate = restorationGate
        #endif
        self.repository = repository
        self.transcriptRepository = transcriptRepository
        self.persistEnabled = persistEnabled
        self.clientFactory = clientFactory
        self.healthCheck = healthCheck
        self.healthDate = healthDate
        self.transcriptClientFactory = transcriptClientFactory
        self.onTranscriptDidSave = onTranscriptDidSave
        self.schedulesRetries = schedulesRetries
        self.requestBackgroundRetry = requestBackgroundRetry
        self.diagnostic = diagnostic
        self.beginExecution = beginExecution
        self.transferCheckDate = transferCheckDate
        storedEnabled = pairing.enabled
        credentials = pairing.credentials
        id = pairing.credentials.scope.receiverID
        displayName = pairing.displayName
        root = repository.root.appendingPathComponent("AutomaticDelivery", isDirectory: true)
        restore()
    }

    deinit { workTask?.cancel(); retryTask?.cancel() }

    static func prepareNewGrant(_ credentials: AutomaticReceiverCredentials, repository: RecordingRepository,
                                knownRecordingIDs: Set<UUID>) throws {
        let scope = credentials.scope
        let directory = repository.root.appendingPathComponent("AutomaticDelivery", isDirectory: true)
            .appendingPathComponent(scope.grantEpoch.uuidString.lowercased(), isDirectory: true)
        let fresh = try AutomaticDeliveryLedger(scope: scope, knownRecordingIDs: knownRecordingIDs, createdAt: Date())
        try preparePrivateDirectory(directory)
        try fresh.persist(to: directory.appendingPathComponent("ledger.json"))
        try writePrivate(TransportCodec.encode(Settings(schemaVersion: 1, grantEpoch: scope.grantEpoch, enabled: true)),
                         to: directory.appendingPathComponent("settings.json"))
    }

    var availableReceivedCount: Int {
        availableRecordings.filter { receivedSegmentIDs.contains($0.id) }.count
    }
    var endpoint: String? { credentials?.scope.endpoint }
    var certificateSHA256: String? { credentials?.scope.certificateSHA256 }
    var pairingStatusTitle: String { isPaired ? "配对已保存" : "配对尚未恢复" }
    var reachabilityTitle: String {
        if isCheckingConnection { return "正在检查连接" }
        guard lastProbeAt != nil else { return "当前可达性未确认" }
        if isProbeUnsupported { return AutomaticReceiverFailureCategory.unsupportedProbe.title }
        if let failure = lastProbeFailure { return "连接检查：\(failure.title)" }
        return "检查时可连接"
    }
    var lastTransferTitle: String {
        guard lastTransferAt != nil else { return "尚无传输结果记录" }
        if let failure = lastTransferFailure { return "失败 · \(failure.title)" }
        return "成功 · 保存回执已核对"
    }
    var connectionWarning: Bool {
        lastProbeFailure != nil || lastTransferFailure != nil || error != nil
            || blockedCount > 0 || lastIncompleteDeliveryAt != nil
    }
    var connectionHint: String? {
        if let failure = lastProbeFailure ?? lastTransferFailure { return failure.hint }
        if let blockedReason { return blockedReason }
        return isProbeUnsupported ? AutomaticReceiverFailureCategory.unsupportedProbe.hint : nil
    }
    var connectionSummary: String {
        guard isPaired else { return pairingStatusTitle }
        if lastProbeFailure != nil { return "配对已保存 · 连接检查失败" }
        if lastTransferFailure != nil { return "配对已保存 · 最近传输失败" }
        if error != nil || blockedCount > 0 { return "配对已保存 · 同步需处理" }
        if isCheckingConnection { return "配对已保存 · 正在检查连接" }
        if isProbeUnsupported { return AutomaticReceiverFailureCategory.unsupportedProbe.title }
        if !isEnabled { return lastProbeAt == nil ? "自动同步已暂停 · 可达性未确认" : "自动同步已暂停 · 检查时可连接" }
        // A registered retry is still awaiting a receipt. New typed failures
        // above retain their warning; legacy ledger history stays in details.
        if uploadingCount > 0 { return "正在交付到接收端 · 等待保存回执" }
        if lastIncompleteDeliveryAt != nil { return "有交付未完成 · 等待重试" }
        if lastProbeAt != nil { return "自动同步已开启 · 检查时可连接" }
        return "自动同步已开启 · 可达性未确认"
    }
    var statusTitle: String {
        if !isPaired { return "接收端尚未恢复" }
        if !isEnabled { return "已暂停自动发送" }
        if blockedCount > 0 { return "部分交付需要检查" }
        if uploadingCount > 0 { return "正在交付到接收端" }
        if isPreparing { return "正在准备交付" }
        if queuedCount > 0 { return "等待接收端接收" }
        return "自动同步已开启"
    }

    /// Called only after PhoneStore finishes a successful metadata+receipt read.
    /// Watch transport acknowledgements remain entirely owned by PhoneConnectivity.
    func discover(manifests: [SegmentManifest], receivedSegmentIDs: Set<UUID>) {
        availableRecordings = manifests
        self.receivedSegmentIDs = receivedSegmentIDs
        hasLibrarySnapshot = true
        reconcilePending = true
        scheduleWork()
        synchronizeTranscriptReturn()
    }

    func requestDeliveryCheck() {
        guard isPaired, isEnabled else { return }
        activity = "已请求同步到此电脑。仅发送这台 iPhone 已收到的录音，等待电脑确认保存。"
        Task { await checkConnection() }
        resume()
    }

    /// A bounded status-only request on page entry or an explicit action. This
    /// does not discover recordings, prepare archives, resume delivery or retry.
    /// A paused grant can still be checked without changing its send setting.
    func checkConnectionIfNeeded() async {
        if let lastAttempt = [lastProbeAt, lastProbeStartedAt].compactMap({ $0 }).max() {
            let age = healthDate().timeIntervalSince(lastAttempt)
            if age >= 0 && age < Self.naturalProbeInterval { return }
        }
        await checkConnection()
    }

    /// Explicit checks intentionally bypass the page-entry interval.
    func checkConnection() async {
        guard !retired, isPaired, !isCheckingConnection, let credentials else { return }
        lastProbeStartedAt = healthDate()
        isCheckingConnection = true
        defer { isCheckingConnection = false }
        let result = await healthCheck(credentials)
        guard !Task.isCancelled, !retired, self.credentials?.scope == credentials.scope else { return }
        if result == .failed(.cancelled) { return }
        lastProbeAt = healthDate()
        switch result {
        case .reachable:
            lastProbeFailure = nil; isProbeUnsupported = false
        case .unsupportedProbe, .failed(.unsupportedProbe):
            lastProbeFailure = nil; isProbeUnsupported = true
        case .failed(let failure):
            lastProbeFailure = failure; isProbeUnsupported = false
        }
        saveConnectionHistory()
        diagnostic("phone.receiver_connection_checked", "category=\(isProbeUnsupported ? "unsupportedProbe" : lastProbeFailure?.rawValue ?? "reachable")")
    }

    func resume() {
        if !restored { restore() }
        reconcilePending = true
        scheduleWork()
        synchronizeTranscriptReturn()
    }

    var hasPendingDelivery: Bool {
        isEnabled && (isReconciling || reconcilePending || ledger?.jobs.contains {
            ![.delivered, .blocked].contains($0.state)
        } == true || transcriptReturn?.hasPendingWork == true)
    }

    /// Wait only for local preparation and URLSession registration, never for
    /// network delivery. The operating system owns a registered upload afterward.
    func waitForPreparation(isCancelled: @escaping @Sendable () -> Bool = { false }) async {
        while let current = workTask {
            if isCancelled() { cancelPreparation() }
            await current.value
            if isCancelled() { return }
        }
    }

    /// A real BGProcessing parent also owns the bounded transcript read started
    /// by preparation's defer. Finishing after upload registration alone could
    /// release system execution while that reply was still in flight. Wait for
    /// one current query, never for remote ASR completion or a retry timer.
    func waitForBackgroundDelivery(isCancelled: @escaping @Sendable () -> Bool = { false }) async {
        await waitForPreparation(isCancelled: isCancelled)
        guard !isCancelled() else { cancelPreparation(); return }
        await transcriptReturn?.waitForCurrentQuery()
        if isCancelled() { cancelPreparation() }
    }

    func cancelPreparation() {
        workTask?.cancel()
        executionLease?.end()
        transcriptReturn?.suspendProcessWork()
    }

    nonisolated private static func systemExecutionLease(
        diagnostic: @escaping @Sendable (String) -> Void
    ) async -> (any AutomaticDeliveryExecutionLease)? {
        #if os(iOS)
        return await withCheckedContinuation { continuation in
            PhoneBackgroundLease.begin(name: "automatic-delivery", diagnostic: diagnostic) {
                continuation.resume(returning: $0)
            }
        }
        #else
        return nil
        #endif
    }

    func setEnabled(_ enabled: Bool) {
        guard !retired, let credentials else { error = AutomaticReceiverError.notConfigured.localizedDescription; return }
        if !enabled {
            stopCurrentWork()
            var credentialFailure: Error?
            var settingsFailure: Error?
            do { try persistEnabled(false); storedEnabled = false }
            catch { credentialFailure = error }
            do { try saveSettings(enabled: false, scope: credentials.scope) }
            catch { settingsFailure = error }
            // Restore requires both stores to allow sending. A durable pause in
            // either survives restart if the other store is temporarily unavailable.
            if let failure = credentialFailure ?? settingsFailure { fail(failure) }
            else { error = nil }
            activity = "已暂停向此接收端发送。原录音和该端队列仍保留，其他接收端不受影响。"
            return
        }
        if !restored { restore() }
        guard restored else { return }
        guard !isEnabled else { return }
        do {
            // First establish a durable disabled fence, including migrated grants
            // whose Keychain override is nil. Partial enable writes cannot revive it.
            try persistEnabled(false)
            storedEnabled = false
            try saveSettings(enabled: true, scope: credentials.scope)
            restoreTransportIfPermitted()
            try persistEnabled(true)
            storedEnabled = true
            isEnabled = true
            error = nil
            activity = "自动同步已恢复，接收端可达时会继续交付。"
            reconcilePending = true
            scheduleWork()
        } catch {
            stopCurrentWork()
            fail(error)
        }
    }

    /// Called only after the coordinator has durably removed this exact grant.
    func retire() {
        retired = true
        transcriptReturn?.retire()
        if let credentials, let gate = restorationGate {
            let identifier = AutomaticReceiverClient.sessionIdentifier(for: credentials.scope)
            if !constructingTransport, gate.hasPendingCompletion(identifier) {
                // Keep the exact owner registered until its native invalidation
                // drains. Removing it first would make the unknown-ID fallback
                // construct a second session with the same identifier.
                beginBackgroundHandoff(identifier)
            }
            if constructingTransport {
                // The factory has not returned its native owner yet. Retain
                // registration until that exact unpublished owner is fenced
                // and drained; an unknown-ID fallback must not create another.
                Task { @MainActor [weak self] in
                    await self?.handoffTask?.value
                    gate.unregisterRestore(identifier)
                }
            } else if let draining = handoffTask {
                Task { await draining.value; gate.unregisterRestore(identifier) }
            } else { gate.unregisterRestore(identifier) }
        }
        stopCurrentWork()
        if let credentials { try? saveSettings(enabled: false, scope: credentials.scope) }
        credentials = nil
        ledger = nil
        deliveredSegmentIDs = []
        lastReceiptAt = nil
        lastIncompleteDeliveryAt = nil
        lastIncompleteDeliveryMessage = nil
        lastProbeAt = nil
        lastProbeFailure = nil
        lastTransferAt = nil
        lastTransferFailure = nil
        lastTransferDeliveryID = nil
        isPaired = false
        activity = "已解除此接收端。手机原录音及接收端已保存的文件仍保留。"
    }

    func restoreBackgroundSession(_ identifier: String) -> Bool {
        guard !retired, let credentials,
              AutomaticReceiverClient.sessionIdentifier(for: credentials.scope) == identifier else { return false }
        if !restored { restore() }
        guard restored else {
            restorationGate?.cancelUnrestorable(identifier)
            return true // Fail closed, without substituting another grant.
        }
        if constructingTransport {
            // A synchronous factory callback cannot construct a second owner.
            // Recheck the exact identifier after the first constructor returns.
            Task { @MainActor [weak self] in _ = self?.restoreBackgroundSession(identifier) }
            return true
        }
        if restorationGate?.hasPendingCompletion(identifier) == true,
           restorationGate?.requiresInvalidation(identifier) == true { beginBackgroundHandoff(identifier) }
        else { restoreTransportIfPermitted() }
        return true
    }

    private func restoreTransportIfPermitted() {
        guard restored, !retired, client == nil, handoffTask == nil, !constructingTransport,
              let credentials else { return }
        let identifier = AutomaticReceiverClient.sessionIdentifier(for: credentials.scope)
        guard restorationGate?.canRestore(identifier) != false else { return }
        do {
            let observedScope = credentials.scope
            let observedGeneration = generation
            let created = try makeClient(credentials)
            guard self.credentials?.scope == observedScope, generation == observedGeneration,
                  !retired, handoffTask == nil, client == nil,
                  restorationGate?.canRestore(identifier) != false else {
                beginBackgroundHandoff(identifier, discarding: created, scope: observedScope)
                return
            }
            client = created
            let epoch = transportEpoch
            let restoredClient = client
            recoveringTransport = true
            Task { [weak self] in
                guard let self else { return }
                let active = await restoredClient?.activeDeliveryIDs() ?? []
                guard self.credentials?.scope == observedScope, self.generation == observedGeneration,
                      self.transportEpoch == epoch else { return }
                self.recoveringTransport = false
                // A handoff invalidates this session before recovering its queue.
                guard self.handoffTask == nil else { return }
                do {
                    try self.recoverInterruptedTransfers(activeDeliveryIDs: active)
                    if !self.isEnabled { await restoredClient?.cancelTransfers() }
                    // An existing local worker will observe recovery's result.
                    // Starting another turn after it registers would reacquire
                    // execution time without any new queue work.
                    if !self.isReconciling { self.scheduleWork() }
                } catch { self.fail(error) }
            }
        } catch { fail(error) }
    }

    private func beginBackgroundHandoff(_ identifier: String,
                                        discarding unpublished: (any AutomaticReceiverTransport)? = nil,
                                        scope discardedScope: AutomaticDeliveryScope? = nil) {
        guard handoffTask == nil, let scope = discardedScope ?? credentials?.scope else { return }
        let gate = restorationGate
        let token = gate?.beginHandoff(identifier)
        let previousWork = workTask
        previousWork?.cancel()
        executionLease?.end()
        retryTask?.cancel(); retryTask = nil
        transcriptReturn?.suspendProcessWork()
        // Construct only after UIKit's handler is stored, including a cold
        // session whose prior events have not been delivered to this process.
        do {
            if let unpublished { client = unpublished }
            else if client == nil, let credentials { client = try makeClient(credentials) }
        }
        catch {
            fail(error)
            gate?.cancelUnrestorable(identifier)
            return
        }
        let oldClient = client
        handoffTask = Task { [weak self] in
            await previousWork?.value
            await oldClient?.invalidateAndDrain()
            guard let self else {
                if let token { gate?.completeHandoff(identifier, token: token) }
                return
            }
            self.client = nil
            self.recoveringTransport = false
            self.handoffTask = nil
            // Pairing/pause may change while invalidation drains. Never recreate
            // a retired grant or discard a new generation's transport.
            if !self.retired, self.credentials?.scope == scope, self.isEnabled {
                self.restoreTransportIfPermitted()
            }
            if let token { gate?.completeHandoff(identifier, token: token) }
            self.scheduleWork()
        }
    }

    private func restore() {
        guard !restored, !retired, let credentials else { return }
        do {
            var stored = try AutomaticDeliveryLedger.load(from: ledgerURL(for: credentials.scope), expectedScope: credentials.scope)
            let settings = try TransportCodec.decode(Settings.self, from: Self.safeData(at: settingsURL(for: credentials.scope), maximumBytes: 4096))
            guard settings.schemaVersion == 1, settings.grantEpoch == credentials.scope.grantEpoch else {
                throw AutomaticReceiverError.localStateUnavailable
            }
            // This product's explicit full-library authorization replaces the old
            // selection model. Keep the receiver, credentials, job/receipt identity
            // and saved pause switch; migration itself never enables sending.
            if try stored.migrateToAllRecordings() {
                try stored.persist(to: ledgerURL(for: credentials.scope))
            }
            self.credentials = credentials
            ledger = stored
            isEnabled = settings.enabled && (storedEnabled ?? true)
            isPaired = true
            if let transcriptRepository {
                do {
                    transcriptReturn = try PhoneReceiverTranscriptReturn(credentials: credentials,
                        repository: transcriptRepository,
                        stateURL: directory(for: credentials.scope).appendingPathComponent("transcript-return-state.json"),
                        schedulesRetries: schedulesRetries,
                        authorized: { [weak self] query in self?.isTranscriptQueryAuthorized(query) == true },
                        didSave: onTranscriptDidSave, requestBackgroundRetry: requestBackgroundRetry,
                        diagnostic: diagnostic, beginExecution: beginExecution, clientFactory: transcriptClientFactory,
                        restorationGate: restorationGate, initiallyEnabled: isEnabled)
                } catch { diagnostic("phone.transcript_return_unavailable", "retry_required=true") }
            }
            restored = true
            publish()
            restoreConnectionHistory()
            activity = isEnabled ? "已恢复配对与交付队列，正在核对未完成任务。" : "配对与队列已恢复，自动发送目前暂停。"
            let identifier = AutomaticReceiverClient.sessionIdentifier(for: credentials.scope)
            if let restorationGate {
                restorationGate.registerRestore(identifier) { [weak self] in _ = self?.restoreBackgroundSession(identifier) }
            } else { restoreTransportIfPermitted() }

        } catch {
            isEnabled = false
            fail(error)
        }
    }

    private func makeClient(_ credentials: AutomaticReceiverCredentials) throws -> any AutomaticReceiverTransport {
        guard !constructingTransport else { throw CancellationError() }
        constructingTransport = true
        defer { constructingTransport = false }
        let clientGeneration = generation
        let epoch = UUID()
        transportEpoch = epoch
        return try clientFactory(credentials, { [weak self] result in
            await self?.receive(result, generation: clientGeneration)
        }, { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { AutomaticDeliveryBackgroundEvents.shared.finish(event.identifier, token: event.token); return }
                guard self.transportEpoch == epoch else { return }
                await self.finishBackgroundEvents(event)
            }
        })
    }

    private func finishBackgroundEvents(_ event: BackgroundSessionEvent) async {
        let identifier = event.identifier
        let gate = restorationGate
        let deadline = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) }
            catch { return }
            if let gate { gate.finish(identifier, token: event.token) }
            else { AutomaticDeliveryBackgroundEvents.shared.finish(identifier, token: event.token) }
        }
        // Give the current one-file preparation a bounded chance to register the
        // next background upload before returning UIKit's background completion.
        if client?.identifier == identifier { await waitForPreparation() }
        deadline.cancel()
        diagnostic("phone.delivery_background_events_finished", "receiver=\(id.uuidString) pending=\(hasPendingDelivery)")
        if let gate { gate.finish(identifier, token: event.token) }
        else { AutomaticDeliveryBackgroundEvents.shared.finish(identifier, token: event.token) }
    }

    private func receive(_ result: AutomaticReceiverTransferResult, generation clientGeneration: UInt64) {
        guard generation == clientGeneration else { return }
        guard let current = credentials, current.scope == result.scope,
              let job = ledger?.job(for: result.deliveryID), job.state != .delivered,
              job.state != .blocked || result.receipt != nil else { return }
        let belongsToCurrentAttempt = result.attemptCount.map { $0 == job.attemptCount }
            ?? (job.attemptCount == 1)
        do {
            if let receipt = result.receipt {
                var candidate = ledger!
                do {
                    guard receipt.deliveryID == result.deliveryID,
                          receipt.recordingIDs == [job.manifest.id],
                          receipt.archiveSHA256 == job.archive?.sha256 else {
                        throw AutomaticReceiverError.invalidReceipt
                    }
                    try candidate.acceptReceipt(receipt, forScope: result.scope)
                } catch {
                    // Valid receipts from an older attempt still prove durable
                    // storage. An invalid old response cannot block a newer one.
                    guard belongsToCurrentAttempt else {
                        diagnostic("phone.delivery_stale_invalid_receipt",
                            "receiver=\(id.uuidString) delivery=\(job.id.uuidString) rejected=true")
                        return
                    }
                    if job.state != .blocked {
                        try mutate { try $0.recordFailure(deliveryID: result.deliveryID, statusCode: 403,
                            message: AutomaticReceiverError.invalidReceipt.localizedDescription) }
                    }
                    recordTransfer(deliveryID: job.id, failure: .invalidResponse)
                    self.error = AutomaticReceiverError.invalidReceipt.localizedDescription
                    return
                }
                // A disk failure here is not an invalid server receipt. Retain
                // the old state and ZIP so its original delivery can be retried.
                try candidate.persist(to: ledgerURL(for: result.scope))
                ledger = candidate
                uploadLiveness.forget(result.deliveryID)
                publish()
                if let localError = localTransferError, localError.deliveryID == job.id {
                    if self.error == localError.message { self.error = nil }
                    localTransferError = nil
                }
                recordTransfer(deliveryID: job.id, failure: nil)
                if self.error == AutomaticReceiverError.invalidReceipt.localizedDescription {
                    self.error = nil
                }
                diagnostic("phone.delivery_receipt_saved", "receiver=\(id.uuidString) delivery=\(job.id.uuidString)")
                if let archive = job.archive {
                    try? FileManager.default.removeItem(at: archiveDirectory(for: result.scope).appendingPathComponent(archive.relativePath))
                }
                activity = "接收端已确认保存。同一录音可供已接入的多个 Agent 读取。"
            } else {
                // Recovery may already have persisted this attempt's failure.
                // A delayed cancellation/error callback cannot count it twice or
                // overwrite a receipt accepted after the original timeout.
                guard job.state == .uploading, belongsToCurrentAttempt else { return }
                uploadLiveness.forget(result.deliveryID)
                let category = result.requiresRepair ? .pairingRepairRequired
                    : result.failureCategory ?? AutomaticReceiverFailureCategory.classify(error: nil, statusCode: result.statusCode)
                let message = category.title + "。" + category.hint
                try mutate { try $0.recordFailure(deliveryID: result.deliveryID,
                    statusCode: result.requiresRepair ? 403 : result.statusCode,
                    message: message) }
                if result.requiresRepair { self.error = Self.repairRequiredMessage }
                recordTransfer(deliveryID: job.id, failure: category)
                activity = message
            }
            scheduleWork()
        } catch {
            fail(error)
            scheduleWork()
        }
    }

    private func scheduleWork() {
        guard restored, !retired, credentials != nil, ledger != nil, handoffTask == nil else { return }
        guard !isReconciling else { workRequested = true; return }
        retryTask?.cancel(); retryTask = nil
        workRequested = false
        isReconciling = true
        let token = generation
        workTask = Task { [weak self] in
            guard let self else { return }
            var attemptedID: UUID?
            var mayContinue = true
            self.preparationSucceeded = false
            defer {
                if self.generation == token {
                    self.workTask = nil
                    self.isReconciling = false
                    self.isPreparing = false
                    self.executionLease?.end()
                    self.executionLease = nil
                    self.scheduleRetry()
                    if mayContinue && !Task.isCancelled { self.synchronizeTranscriptReturn() }
                    if !mayContinue && self.hasPendingDelivery {
                        self.requestBackgroundRetry(Date(timeIntervalSinceNow: 60))
                    }
                    if mayContinue && (self.workRequested || (self.reconcilePending && self.hasLibrarySnapshot)) {
                        self.scheduleWork()
                    }
                }
            }
            do {
                let diagnostic = self.diagnostic
                let lease = await self.beginExecution { detail in
                    diagnostic("phone.delivery_lease", detail)
                }
                guard self.generation == token, !Task.isCancelled,
                      lease?.hasTimeRemaining != false else {
                    lease?.end()
                    mayContinue = false
                    return
                }
                self.executionLease = lease
                if self.reconcilePending, self.hasLibrarySnapshot {
                    self.reconcilePending = false
                    try await self.reconcile(token: token)
                }
                guard self.isEnabled, let scope = self.credentials?.scope else {
                    self.preparationSucceeded = true
                    return
                }
                try self.requireScope(scope, generation: token)
                // Durable discovery is local work and must not depend on a
                // restored URLSession. Only transport creation needs admission.
                // An existing restorer remains the sole native recovery owner.
                guard !self.recoveringTransport else { self.preparationSucceeded = true; return }
                let identifier = AutomaticReceiverClient.sessionIdentifier(for: scope)
                let transportPermitted = self.restorationGate?.canRestore(identifier) != false
                    || self.executionLease?.hasTimeRemaining == true
                guard self.client != nil || transportPermitted else {
                    mayContinue = false
                    return
                }
                if self.restorationGate?.requiresInvalidation(identifier) == true {
                    // This captures/cancels our workTask. Return immediately;
                    // awaiting handoff here would make it wait for itself.
                    self.beginBackgroundHandoff(identifier)
                    mayContinue = false
                    return
                }
                if self.client == nil, let credentials = self.credentials {
                    let created = try self.makeClient(credentials)
                    do {
                        try self.requireScope(scope, generation: token)
                        guard self.isEnabled, !self.retired, self.handoffTask == nil,
                              self.client == nil else { throw CancellationError() }
                    } catch {
                        self.beginBackgroundHandoff(identifier, discarding: created, scope: scope)
                        throw error
                    }
                    self.client = created
                }
                // Factory callbacks can introduce a late handoff ambiguity.
                if self.restorationGate?.requiresInvalidation(identifier) == true {
                    self.beginBackgroundHandoff(identifier)
                    mayContinue = false
                    return
                }
                guard let sender = self.client else { throw CancellationError() }
                let epoch = self.transportEpoch
                try self.requireScope(scope, generation: token)
                let transfers = await sender.activeTransfers()
                try self.requireScope(scope, generation: token)
                guard self.transportEpoch == epoch, self.client === sender,
                      self.handoffTask == nil else { throw CancellationError() }
                let active = Set(transfers.map(\.deliveryID))
                for transfer in transfers {
                    self.diagnostic("phone.delivery_upload_progress",
                        "receiver=\(self.id.uuidString) delivery=\(transfer.deliveryID.uuidString)"
                        + " sent_bytes=\(transfer.bytesSent) received_bytes=\(transfer.bytesReceived)")
                }
                try self.recoverInterruptedTransfers(activeDeliveryIDs: active)
                let registrations = Dictionary(uniqueKeysWithValues: (self.ledger?.jobs ?? [])
                    .filter { $0.state == .uploading }.map { ($0.id, $0.updatedAt) })
                let stalled = self.uploadLiveness.stalledDeliveryIDs(transfers: transfers, registeredAt: registrations,
                    now: self.transferCheckDate())
                for id in stalled {
                    try self.requireScope(scope, generation: token)
                    guard let progress = transfers.first(where: { $0.deliveryID == id }) else { continue }
                    if await self.client?.cancelTransfer(ifUnchanged: progress) == true {
                        self.diagnostic("phone.delivery_stalled_upload_cancelled",
                            "receiver=\(self.id.uuidString) delivery=\(id.uuidString) retry_after_completion=true")
                    }
                }
                // Wait for the cancelled task's ordered completion to persist its
                // failure before reusing the same ZIP and delivery identity.
                guard active.isEmpty else { self.preparationSucceeded = true; return }
                guard let job = self.ledger?.jobs.first(where: {
                    ($0.state == .queued || $0.state == .retryWaiting) && ($0.nextAttemptAt ?? .distantPast) <= Date()
                }) else { self.preparationSucceeded = true; return }
                attemptedID = job.id
                if job.archive == nil { try await self.prepare(job, token: token) }
                try self.requireScope(scope, generation: token)
                guard let prepared = self.ledger?.job(for: job.id), let archive = prepared.archive else {
                    throw AutomaticReceiverError.invalidArchive
                }
                let file = self.archiveDirectory(for: scope).appendingPathComponent(archive.relativePath)
                let expected = archive
                try await Task.detached(priority: .utility) {
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { throw AutomaticReceiverError.invalidArchive }
                    let fingerprint = try RecordingRepository.fingerprint(of: file)
                    guard fingerprint.sha256 == expected.sha256, fingerprint.byteCount == expected.byteCount else {
                        throw AutomaticReceiverError.invalidArchive
                    }
                }.value
                try self.requireScope(scope, generation: token)
                guard self.isEnabled, let sender = self.client else { throw CancellationError() }
                try self.mutate { try $0.beginUpload(deliveryID: job.id) }
                guard let attempt = self.ledger?.job(for: job.id)?.attemptCount else {
                    throw AutomaticReceiverError.localStateUnavailable
                }
                try sender.upload(deliveryID: job.id, attemptCount: attempt, archiveURL: file, sha256: archive.sha256)
                self.preparationSucceeded = true
                self.diagnostic("phone.delivery_upload_registered", "receiver=\(self.id.uuidString) delivery=\(job.id.uuidString) segment=\(job.manifest.id.uuidString)")
                self.activity = "正在交付到此接收端；等待保存回执。"
            } catch is CancellationError {
                mayContinue = false
                // Persisted preparing/uploading states are recovered against the
                // background session on resume, never converted into success.
            } catch {
                guard self.generation == token else { return }
                var presentedFailure = false
                if let attemptedID, let job = self.ledger?.job(for: attemptedID),
                   job.state != .blocked && job.state != .delivered {
                    let wasUploading = job.state == .uploading
                    let networkFailure = AutomaticReceiverFailureCategory.networkFailure(error: error)
                    let category = networkFailure ?? .localState
                    do {
                        try self.mutate { try $0.recordFailure(deliveryID: job.id,
                            message: wasUploading ? category.title + "。" + category.hint : "准备或发送未完成，稍后会自动重试。") }
                        if wasUploading {
                            self.recordTransfer(deliveryID: job.id, failure: category)
                            if networkFailure == nil {
                                self.fail(error)
                                if let message = self.error {
                                    self.localTransferError = (job.id, message)
                                }
                            }
                            presentedFailure = true
                        }
                    } catch {
                        self.fail(error)
                        presentedFailure = true
                    }
                }
                if !presentedFailure { self.fail(error) }
            }
        }
    }

    private func reconcile(token: UInt64) async throws {
        guard let current = ledger else { return }
        let scope = current.scope
        let manifests = availableRecordings
        let received = receivedSegmentIDs
        let receivedManifests = manifests.filter { received.contains($0.id) }
        let transcriptRepository = transcriptRepository
        let destination = transcriptDirectory(for: scope)
        let hashes: [UUID: String] = try await Task.detached(priority: .utility) {
            let values = transcriptRepository?.availableTranscripts(for: receivedManifests).transcripts ?? [:]
            var hashes: [UUID: String] = [:]
            if !values.isEmpty { try Self.preparePrivateDirectory(destination) }
            for (id, transcript) in values {
                let bytes = try TransportCodec.encode(transcript)
                let hash = Self.digest(bytes)
                let url = destination.appendingPathComponent(hash + ".json")
                if FileManager.default.fileExists(atPath: url.path) {
                    guard Self.digest(try Self.safeData(at: url, maximumBytes: TranscriptRepository.maximumFileBytes)) == hash else {
                        throw AutomaticReceiverError.localStateUnavailable
                    }
                } else { try Self.writePrivate(bytes, to: url) }
                hashes[id] = hash
            }
            return hashes
        }.value
        try requireScope(scope, generation: token)
        // Recheck after the IO await: returned text may have been saved while
        // this snapshot was reading. Its exact origin version must not create a
        // second ZIP carrying the same audio back to that receiver.
        let returnedHashes = returnedTranscriptHashes()
        let deliveryHashes = hashes.filter { returnedHashes[$0.key] != $0.value }
        try mutate { _ = try $0.reconcile(manifests: manifests, receivedSegmentIDs: received, transcriptHashes: deliveryHashes) }
    }

    private func isTranscriptQueryAuthorized(_ query: AutomaticReceiverTranscriptQuery, requiresEnabled: Bool = true) -> Bool {
        guard !retired, (!requiresEnabled || isEnabled), let credentials, let ledger,
              ledger.scope == credentials.scope, ledger.authorizedIDs.contains(query.manifest.id),
              receivedSegmentIDs.contains(query.manifest.id),
              availableRecordings.contains(query.manifest),
              let job = ledger.job(for: query.receipt.deliveryID), job.state == .delivered,
              job.receipt == query.receipt, job.manifest == query.manifest else { return false }
        return true
    }

    private func transcriptQueries(requiresEnabled: Bool = true) -> [AutomaticReceiverTranscriptQuery] {
        var seen = Set<UUID>()
        return (ledger?.jobs ?? []).sorted {
            if $0.manifest.startedAt != $1.manifest.startedAt { return $0.manifest.startedAt > $1.manifest.startedAt }
            return $0.updatedAt > $1.updatedAt
        }.compactMap { job in
            guard let receipt = job.receipt else { return nil }
            let query = AutomaticReceiverTranscriptQuery(receipt: receipt, manifest: job.manifest)
            guard isTranscriptQueryAuthorized(query, requiresEnabled: requiresEnabled), seen.insert(job.manifest.id).inserted else { return nil }
            return query
        }
    }

    private func synchronizeTranscriptReturn() {
        transcriptReturn?.synchronize(transcriptQueries(), enabled: isEnabled)
    }

    private func returnedTranscriptHashes() -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: transcriptQueries(requiresEnabled: false).compactMap { query in
            guard let hash = transcriptReturn?.returnedTranscriptHash(for: query) else { return nil }
            return (query.manifest.id, hash)
        })
    }

    private func prepare(_ job: AutomaticDeliveryJob, token: UInt64) async throws {
        try requireScope(job.scope, generation: token)
        try mutate { try $0.beginPreparation(deliveryID: job.id) }
        isPreparing = true
        let repository = repository
        let archives = archiveDirectory(for: job.scope)
        let snapshots = transcriptDirectory(for: job.scope)
        let preparation = Task.detached(priority: .utility) {
            try Self.preparePrivateDirectory(archives)
            var transcripts: [UUID: SegmentTranscript] = [:]
            if let expectedHash = job.transcriptSHA256 {
                let bytes = try Self.safeData(at: snapshots.appendingPathComponent(expectedHash + ".json"), maximumBytes: TranscriptRepository.maximumFileBytes)
                guard Self.digest(bytes) == expectedHash else { throw AutomaticReceiverError.invalidArchive }
                let value = try TransportCodec.decode(SegmentTranscript.self, from: bytes)
                try value.validate(against: job.manifest)
                transcripts[job.manifest.id] = value
            }
            try Task.checkCancellation()
            let built = try AutomaticDeliveryArchiveBuilder.create(repository: repository, job: job,
                destinationDirectory: archives, transcript: transcripts[job.manifest.id])
            do {
                let fingerprint = try RecordingRepository.fingerprint(of: built)
                guard fingerprint.byteCount <= AutomaticDeliveryLedger.maximumArchiveBytes else { throw AutomaticReceiverError.invalidArchive }
                try Task.checkCancellation()
                return AutomaticDeliveryArchive(relativePath: built.lastPathComponent, sha256: fingerprint.sha256, byteCount: fingerprint.byteCount)
            } catch {
                try? FileManager.default.removeItem(at: built)
                throw error
            }
        }
        let prepared = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: { preparation.cancel() }
        do {
            try requireScope(job.scope, generation: token)
            try mutate { try $0.recordPreparedArchive(deliveryID: job.id, relativePath: prepared.relativePath,
                sha256: prepared.sha256, byteCount: prepared.byteCount) }
        } catch {
            // This attempt was never committed to the ledger, so cancellation or
            // a full disk must not leave a second retry archive behind.
            try? FileManager.default.removeItem(at: archives.appendingPathComponent(prepared.relativePath))
            throw error
        }
        isPreparing = false
    }

    private func scheduleRetry() {
        guard isEnabled, let ledger else { return }
        let pending = ledger.jobs.filter { $0.state == .queued || $0.state == .retryWaiting }
        let hasUpload = ledger.jobs.contains { $0.state == .uploading }
        // Queued files cannot run while a background task owns the single slot.
        // Check its progress at a bounded cadence, including when it is the last
        // file, instead of a two-second no-op loop or no wake request at all.
        let next: Date
        if hasUpload {
            next = Date(timeIntervalSinceNow: AutomaticDeliveryTransferLiveness.checkInterval)
        } else if let due = pending.map({ $0.nextAttemptAt ?? Date() }).min() {
            next = due
        } else { return }
        requestBackgroundRetry(next)
        diagnostic("phone.delivery_retry_requested", "receiver=\(id.uuidString) queued=\(pending.count) earliest_begin_at=\(ISO8601DateFormatter().string(from: next))")
        guard schedulesRetries else { return }
        // A completion callback resumes immediately. This timer is only a bounded
        // in-process retry hint; the ledger is the durable source after suspension.
        let delay = max(2, min(next.timeIntervalSinceNow, 3600))
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            self?.scheduleWork()
        }
    }

    private func mutate(_ body: (inout AutomaticDeliveryLedger) throws -> Void) throws {
        guard var candidate = ledger, let credentials else { throw AutomaticReceiverError.notConfigured }
        try candidate.requireScope(credentials.scope)
        try body(&candidate)
        try candidate.persist(to: ledgerURL(for: candidate.scope))
        ledger = candidate
        publish()
    }

    private func requireScope(_ scope: AutomaticDeliveryScope, generation token: UInt64) throws {
        try Task.checkCancellation()
        guard generation == token, credentials?.scope == scope else { throw AutomaticReceiverError.scopeChanged }
        guard executionLease?.hasTimeRemaining != false else { throw CancellationError() }
    }

    private func publish() {
        guard let ledger else { return }
        receiverName = URL(string: ledger.scope.endpoint)?.host ?? "接收端"
        let delivered = ledger.jobs.filter { $0.state == .delivered && $0.receipt != nil }
        deliveredSegmentIDs = Set(delivered.map { $0.manifest.id })
        lastReceiptAt = delivered.compactMap { $0.receipt?.storedAt }.max()
        let incomplete = ledger.jobs.filter { $0.state != .delivered && $0.lastError != nil }
            .max { $0.updatedAt < $1.updatedAt }
        lastIncompleteDeliveryAt = incomplete?.updatedAt
        lastIncompleteDeliveryMessage = incomplete?.lastError
        deliveredCount = deliveredSegmentIDs.count
        queuedCount = ledger.jobs.filter { [.queued, .preparing, .retryWaiting].contains($0.state) }.count
        uploadingCount = ledger.jobs.filter { $0.state == .uploading }.count
        let blocked = ledger.jobs.filter { $0.state == .blocked }
        blockedCount = blocked.count
        // The latest transfer can belong to a different job. Keep the blocked
        // job's durable reason visible until that job receives its own receipt.
        blockedReason = blocked.first(where: { $0.lastError == Self.repairRequiredMessage })?.lastError
            ?? blocked.max { $0.updatedAt < $1.updatedAt }?.lastError
        if blockedCount == 0 && error == Self.repairRequiredMessage { error = nil }
    }

    private func recordTransfer(deliveryID: UUID, failure: AutomaticReceiverFailureCategory?) {
        lastTransferAt = healthDate()
        lastTransferFailure = failure
        lastTransferDeliveryID = deliveryID
        saveConnectionHistory()
        diagnostic("phone.receiver_transfer_result", "category=\(failure?.rawValue ?? "receipt_verified") delivery=\(deliveryID.uuidString)")
    }

    private func recoverInterruptedTransfers(activeDeliveryIDs: Set<UUID>) throws {
        let interrupted = ledger?.jobs.filter { $0.state == .uploading && !activeDeliveryIDs.contains($0.id) }
            .max { $0.updatedAt < $1.updatedAt }
        try mutate { try $0.recoverInterruptedJobs(activeDeliveryIDs: activeDeliveryIDs) }
        if let interrupted {
            // The OS no longer owns the registered task. Its exact network cause
            // is unknown, but it must not leave a previous successful result up.
            recordTransfer(deliveryID: interrupted.id, failure: .unknown)
        }
    }

    private func saveConnectionHistory() {
        guard !retired, let scope = credentials?.scope else { return }
        do {
            let value = ConnectionHistory(schemaVersion: 1, grantEpoch: scope.grantEpoch,
                probeAt: lastProbeAt, probeFailure: lastProbeFailure,
                probeUnsupported: isProbeUnsupported ? true : nil,
                transferAt: lastTransferAt, transferFailure: lastTransferFailure,
                transferDeliveryID: lastTransferDeliveryID)
            try Self.writePrivate(TransportCodec.encode(value), to: connectionHistoryURL(for: scope))
            if self.error == Self.historySaveError || self.error == Self.historyRestoreError { self.error = nil }
        } catch {
            self.error = Self.historySaveError
            diagnostic("phone.receiver_status_persistence_failed", "operation=save")
        }
    }

    private func restoreConnectionHistory() {
        guard let scope = credentials?.scope else { return }
        let url = connectionHistoryURL(for: scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let value = try TransportCodec.decode(ConnectionHistory.self, from: Self.safeData(at: url, maximumBytes: 4096))
            guard value.schemaVersion == 1, value.grantEpoch == scope.grantEpoch,
                  value.probeAt != nil || value.probeFailure == nil,
                  value.probeAt != nil || value.probeUnsupported != true,
                  value.probeUnsupported != true || value.probeFailure == nil,
                  value.transferAt != nil || value.transferDeliveryID == nil,
                  value.transferAt != nil || value.transferFailure == nil else {
                throw AutomaticReceiverError.localStateUnavailable
            }
            lastProbeAt = value.probeAt
            isProbeUnsupported = value.probeUnsupported == true || value.probeFailure == .unsupportedProbe
            lastProbeFailure = isProbeUnsupported ? nil : value.probeFailure
            if let deliveryID = value.transferDeliveryID, let job = ledger?.job(for: deliveryID) {
                // The receipt ledger is authoritative if the process ended
                // between receipt persistence and this secondary status write.
                let delivered = job.state == .delivered && job.receipt != nil
                lastTransferAt = delivered && value.transferFailure != nil ? job.updatedAt : value.transferAt
                lastTransferFailure = delivered ? nil : (value.transferFailure ?? .unknown)
                lastTransferDeliveryID = deliveryID
            } else if value.transferAt != nil {
                // Retain the dated result after ledger compaction, without
                // pretending that it is still bound to a retained delivery.
                lastTransferAt = value.transferAt
                lastTransferFailure = value.transferFailure
                lastTransferDeliveryID = nil
                if value.transferDeliveryID != nil {
                    diagnostic("phone.receiver_transfer_binding_missing",
                        "category=\(value.transferFailure?.rawValue ?? "receipt_verified")")
                }
            }
        } catch {
            self.error = Self.historyRestoreError
            diagnostic("phone.receiver_status_persistence_failed", "operation=restore")
        }
    }

    private func stopCurrentWork() {
        isEnabled = false
        generation &+= 1
        workTask?.cancel(); workTask = nil
        executionLease?.end(); executionLease = nil
        retryTask?.cancel(); retryTask = nil
        client?.cancelAll(); client = nil
        recoveringTransport = false
        transcriptReturn?.stop()
        uploadLiveness = AutomaticDeliveryTransferLiveness()
        isPreparing = false; isReconciling = false; workRequested = false
    }

    private func fail(_ failure: Error) {
        if let failure = failure as? AutomaticReceiverError { error = failure.localizedDescription }
        else if let failure = failure as? AutomaticDeliveryLedgerError { error = failure.localizedDescription }
        else { error = "自动同步暂未完成，请检查此接收端连接与本机存储。原录音仍保留。" }
    }

    private func directory(for scope: AutomaticDeliveryScope) -> URL { root.appendingPathComponent(scope.grantEpoch.uuidString.lowercased(), isDirectory: true) }
    private func ledgerURL(for scope: AutomaticDeliveryScope) -> URL { directory(for: scope).appendingPathComponent("ledger.json") }
    private func settingsURL(for scope: AutomaticDeliveryScope) -> URL { directory(for: scope).appendingPathComponent("settings.json") }
    private func connectionHistoryURL(for scope: AutomaticDeliveryScope) -> URL { directory(for: scope).appendingPathComponent("connection-status.json") }
    private func archiveDirectory(for scope: AutomaticDeliveryScope) -> URL { directory(for: scope).appendingPathComponent("archives", isDirectory: true) }
    private func transcriptDirectory(for scope: AutomaticDeliveryScope) -> URL { directory(for: scope).appendingPathComponent("transcripts", isDirectory: true) }
    private func saveSettings(enabled: Bool, scope: AutomaticDeliveryScope) throws {
        try Self.writePrivate(TransportCodec.encode(Settings(schemaVersion: 1, grantEpoch: scope.grantEpoch, enabled: enabled)), to: settingsURL(for: scope))
    }

    nonisolated private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated private static func safeData(at url: URL, maximumBytes: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) == 1,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else { throw AutomaticReceiverError.localStateUnavailable }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw AutomaticReceiverError.localStateUnavailable }
        return data
    }
    nonisolated private static func preparePrivateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw AutomaticReceiverError.localStateUnavailable
            }
        } else {
            let parent = url.deletingLastPathComponent()
            try preparePrivateDirectory(parent)
            try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard parentFD >= 0 else { throw AutomaticReceiverError.localStateUnavailable }
            defer { Darwin.close(parentFD) }
            guard Darwin.fsync(parentFD) == 0 else { throw AutomaticReceiverError.localStateUnavailable }
        }
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    nonisolated private static func writePrivate(_ data: Data, to url: URL) throws {
        guard data.count <= TranscriptRepository.maximumFileBytes else { throw AutomaticReceiverError.localStateUnavailable }
        try preparePrivateDirectory(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try safeData(at: url, maximumBytes: TranscriptRepository.maximumFileBytes)
        }
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize(); try handle.close()
        let descriptor = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AutomaticReceiverError.localStateUnavailable }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw AutomaticReceiverError.localStateUnavailable }
    }
}
