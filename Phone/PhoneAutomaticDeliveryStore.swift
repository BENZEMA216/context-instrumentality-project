import Combine
import CryptoKit
import Foundation
import Network
import RecordingCore

/// Coordinates independent delivery grants over one original recording repository.
/// Agent readers may share a receiver; different receivers each retain their own
/// credentials, pause setting, queue, receipts, and background URLSession.
@MainActor
final class PhoneAutomaticDeliveryStore: ObservableObject {
    @Published private(set) var receivers: [PhoneReceiverDeliveryStore] = []
    @Published private(set) var availableRecordings: [SegmentManifest] = []
    @Published private(set) var receivedSegmentIDs: Set<UUID> = []
    @Published private(set) var hasLibrarySnapshot = false
    @Published private(set) var activity = "配对接收 AGENT；同一份录音可供多个 Agent 使用。"
    @Published private(set) var error: String?

    private let repository: RecordingRepository
    private let transcriptRepository: TranscriptRepository?
    private let vault: any AutomaticReceiverCredentialStorage
    private let schedulesRetries: Bool
    private let clientFactory: AutomaticReceiverClientFactory
    private let transcriptClientFactory: AutomaticReceiverTranscriptClientFactory
    private let onTranscriptDidSave: (SegmentManifest) -> Void
    private let requestBackgroundRetry: (Date) -> Void
    private let diagnostic: @Sendable (String, String) -> Void
    private let pairingDraftURL: URL?
    private var storedPairings: [AutomaticReceiverStoredPairing] = []
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var pathMonitor: NWPathMonitor?
    private var restored = false
    private var draftDigest: String?
    private var draftURL: URL?
    private var draftPayload: AutomaticReceiverPairingPayload?

    init(repository: RecordingRepository, transcriptRepository: TranscriptRepository?,
         vault: any AutomaticReceiverCredentialStorage = AutomaticReceiverCredentialVault(),
         observesNetwork: Bool = true, schedulesRetries: Bool = true,
         registersBackgroundEvents: Bool = true,
         requestBackgroundRetry: @escaping (Date) -> Void = { _ in },
         diagnostic: @escaping @Sendable (String, String) -> Void = { _, _ in },
         pairingDraftURL: URL? = nil,
         onTranscriptDidSave: @escaping (SegmentManifest) -> Void = { _ in },
         transcriptClientFactory: @escaping AutomaticReceiverTranscriptClientFactory = {
             try AutomaticReceiverTranscriptClient(credentials: $0)
         },
         clientFactory: @escaping AutomaticReceiverClientFactory = { credentials, complete, finished in
             try AutomaticReceiverClient(credentials: credentials, complete: complete, finishedEvents: finished)
         }) {
        self.repository = repository
        self.transcriptRepository = transcriptRepository
        self.vault = vault
        self.schedulesRetries = schedulesRetries
        self.clientFactory = clientFactory
        self.transcriptClientFactory = transcriptClientFactory
        self.onTranscriptDidSave = onTranscriptDidSave
        self.requestBackgroundRetry = requestBackgroundRetry
        self.diagnostic = diagnostic
        self.pairingDraftURL = pairingDraftURL
        if registersBackgroundEvents { AutomaticDeliveryBackgroundEvents.shared.registerStore(self) }
        if observesNetwork {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                Task { @MainActor [weak self] in self?.resume() }
            }
            monitor.start(queue: DispatchQueue(label: "RecordForAgent.automatic-network"))
            pathMonitor = monitor
        }
        restore()
    }

    deinit { pathMonitor?.cancel() }

    var isPaired: Bool { !receivers.isEmpty }
    var isPreparing: Bool { receivers.contains { $0.isPreparing } }
    var availableReceivedCount: Int {
        availableRecordings.filter { receivedSegmentIDs.contains($0.id) }.count
    }
    var statusTitle: String {
        guard !receivers.isEmpty else { return "尚未配对接收 AGENT" }
        let enabled = receivers.filter { $0.isEnabled }.count
        return "已配对 \(receivers.count) 个接收端 · \(enabled) 个自动同步中"
    }

    /// No audio is copied here. Every worker refers to the same immutable originals.
    func discover(manifests: [SegmentManifest], receivedSegmentIDs: Set<UUID>) {
        availableRecordings = manifests
        self.receivedSegmentIDs = receivedSegmentIDs
        hasLibrarySnapshot = true
        for receiver in receivers {
            receiver.discover(manifests: manifests, receivedSegmentIDs: receivedSegmentIDs)
        }
    }

    func resume() {
        if !restored { restore() }
        receivers.forEach { $0.resume() }
    }

    var hasPendingDelivery: Bool { receivers.contains { $0.hasPendingDelivery } }

    func cancelPreparation() { receivers.forEach { $0.cancelPreparation() } }

    func waitForPreparation(isCancelled: @escaping @Sendable () -> Bool = { false }) async {
        for worker in receivers {
            if isCancelled() { cancelPreparation(); return }
            await worker.waitForPreparation(isCancelled: isCancelled)
        }
    }

    /// BGProcessing launches need the same discovery as the foreground, without
    /// depending on a SwiftUI scene or an eventually scheduled UI reload.
    func prepareBackgroundDelivery(isCancelled: @escaping @Sendable () -> Bool = { false }) async -> Bool {
        guard !isCancelled() else { return false }
        if !restored { restore() }
        guard restored else { return false }
        do {
            let repository = repository
            let snapshot = try await Task.detached(priority: .utility) {
                guard !isCancelled() else { throw CancellationError() }
                let manifests = try repository.manifests()
                guard !isCancelled() else { throw CancellationError() }
                return (manifests, try repository.receivedSegmentIDs())
            }.value
            guard !isCancelled() else { cancelPreparation(); return false }
            availableRecordings = snapshot.0
            receivedSegmentIDs = snapshot.1
            hasLibrarySnapshot = true
            for worker in receivers {
                guard !isCancelled() else { cancelPreparation(); return false }
                worker.discover(manifests: snapshot.0, receivedSegmentIDs: snapshot.1)
            }
            for worker in receivers {
                guard !isCancelled() else { cancelPreparation(); return false }
                await worker.waitForBackgroundDelivery(isCancelled: isCancelled)
            }
            guard !isCancelled() else { cancelPreparation(); return false }
            return receivers.allSatisfy { !$0.isEnabled || $0.preparationSucceeded }
        } catch is CancellationError {
            cancelPreparation()
            return false
        } catch {
            diagnostic("phone.delivery_discovery_failed", "retry_required=true")
            requestBackgroundRetry(Date(timeIntervalSinceNow: 60))
            return false
        }
    }

    @discardableResult
    func pair(_ payload: AutomaticReceiverPairingPayload, name: String) -> Bool {
        if !restored { restore() }
        guard restored else { return false }
        guard hasLibrarySnapshot else {
            error = "正在读取本地录音，请稍后再配对。"
            return false
        }
        guard !storedPairings.contains(where: { $0.credentials.scope.receiverID == payload.receiverID }) else {
            error = AutomaticReceiverError.duplicateReceiver.localizedDescription
            return false
        }
        let requestedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = URL(string: payload.endpoint)
        let host = endpoint?.host ?? "接收端"
        let fallbackName = endpoint?.port.map { "\(host):\($0)" } ?? host
        let displayName = requestedName.isEmpty ? fallbackName : requestedName
        guard !displayName.isEmpty, displayName.utf8.count <= 256,
              !displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            error = AutomaticReceiverError.invalidReceiverName.localizedDescription
            return false
        }
        do {
            let latest = try repository.manifests()
            let received = try repository.receivedSegmentIDs()
            let known = Set(availableRecordings.map(\.id)).union(receivedSegmentIDs)
                .union(latest.map(\.id)).union(received)
            let scope = AutomaticDeliveryScope(receiverID: payload.receiverID, pairingID: UUID(), grantEpoch: UUID(),
                sourceInstallationID: try vault.installationID(), endpoint: payload.endpoint,
                certificateSHA256: payload.certificateSHA256)
            let credentials = AutomaticReceiverCredentials(scope: scope, token: payload.token)
            let entry = AutomaticReceiverStoredPairing(displayName: displayName, credentials: credentials, enabled: true)
            // Prepare an isolated grant before making it active. A failed Keychain
            // write leaves only an unreachable, token-free grant directory.
            try PhoneReceiverDeliveryStore.prepareNewGrant(credentials, repository: repository, knownRecordingIDs: known)
            let candidate = storedPairings + [entry]
            try vault.saveAll(candidate)
            storedPairings = candidate
            let worker = makeWorker(entry)
            receivers.append(worker)
            observe(worker)
            availableRecordings = latest
            receivedSegmentIDs = received
            worker.discover(manifests: latest, receivedSegmentIDs: received)
            consumePairingDraftIfUnchanged(for: payload)
            error = nil
            activity = "已添加接收端“\(displayName)”。已有和新增录音会独立同步，其他接收端保持原设置。"
            return true
        } catch {
            self.error = describe(error)
            return false
        }
    }

    @discardableResult
    func removeReceiver(_ id: UUID) -> Bool {
        guard let worker = receivers.first(where: { $0.id == id }),
              storedPairings.contains(where: { $0.credentials.scope.receiverID == id }) else { return false }
        // Pause this worker first. Failure to remove its credential must not leave
        // an active uploader, and must never clear another receiver's credential.
        worker.setEnabled(false)
        do {
            let candidate = storedPairings.filter { $0.credentials.scope.receiverID != id }
            try vault.saveAll(candidate)
            storedPairings = candidate
            worker.retire()
            subscriptions.removeValue(forKey: id)
            receivers.removeAll { $0.id == id }
            error = nil
            activity = "已解除此接收端。原录音、其他接收端及已交付文件均保留。"
            return true
        } catch {
            self.error = "此接收端已暂停，但解除配对尚未保存：" + describe(error)
            return false
        }
    }

    /// Only an exact currently registered grant may restore a background session.
    func restoreBackgroundSession(_ identifier: String) -> Bool {
        if !restored { restore() }
        return receivers.contains { $0.restoreBackgroundSession(identifier) }
    }

    private func restore() {
        guard !restored else { return }
        do {
            let entries = try vault.loadAll()
            storedPairings = entries
            receivers = entries.map(makeWorker)
            for worker in receivers {
                observe(worker)
                if hasLibrarySnapshot {
                    worker.discover(manifests: availableRecordings, receivedSegmentIDs: receivedSegmentIDs)
                }
            }
            restored = true
            error = nil
            if !entries.isEmpty { activity = "已恢复各接收端的独立队列与暂停设置。" }
        } catch {
            self.error = describe(error)
        }
    }

    private func makeWorker(_ entry: AutomaticReceiverStoredPairing) -> PhoneReceiverDeliveryStore {
        let scope = entry.credentials.scope
        return PhoneReceiverDeliveryStore(pairing: entry, repository: repository,
            transcriptRepository: transcriptRepository, persistEnabled: { [weak self] enabled in
                guard let self else { throw AutomaticReceiverError.notConfigured }
                try self.saveEnabled(enabled, for: scope)
            }, schedulesRetries: schedulesRetries, requestBackgroundRetry: requestBackgroundRetry,
            diagnostic: diagnostic, onTranscriptDidSave: onTranscriptDidSave,
            transcriptClientFactory: transcriptClientFactory, clientFactory: clientFactory)
    }

    private func saveEnabled(_ enabled: Bool, for scope: AutomaticDeliveryScope) throws {
        guard let index = storedPairings.firstIndex(where: { $0.credentials.scope == scope }) else {
            throw AutomaticReceiverError.scopeChanged
        }
        var candidate = storedPairings
        candidate[index].enabled = enabled
        try vault.saveAll(candidate)
        storedPairings = candidate
    }

    private func observe(_ worker: PhoneReceiverDeliveryStore) {
        subscriptions[worker.id] = worker.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
    }

    /// Optional setup draft; reading it grants no access and pairs no receiver.
    func loadPairingDraft() throws -> String? {
        draftURL = nil
        draftDigest = nil
        draftPayload = nil
        guard let url = pairingDraftURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AutomaticDeliveryPairing.json") else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Self.safeData(at: url, maximumBytes: 16_384)
        guard let text = String(data: data, encoding: .utf8) else { throw AutomaticReceiverError.invalidPairing }
        let payload = try AutomaticReceiverPairingPayload.parse(text)
        draftURL = url
        draftDigest = Self.digest(data)
        draftPayload = payload
        return text
    }

    private func consumePairingDraftIfUnchanged(for payload: AutomaticReceiverPairingPayload) {
        guard let draftURL, let draftDigest, let draftPayload,
              draftPayload.schemaVersion == payload.schemaVersion,
              draftPayload.endpoint == payload.endpoint,
              draftPayload.receiverID == payload.receiverID,
              draftPayload.token == payload.token,
              draftPayload.certificateSHA256 == payload.certificateSHA256,
              let data = try? Self.safeData(at: draftURL, maximumBytes: 16_384), Self.digest(data) == draftDigest else { return }
        try? FileManager.default.removeItem(at: draftURL)
        self.draftURL = nil
        self.draftDigest = nil
        self.draftPayload = nil
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? AutomaticReceiverError { return error.localizedDescription }
        if let error = error as? AutomaticDeliveryLedgerError { return error.localizedDescription }
        return "接收端配置暂未完成，请检查本机存储；其他接收端保持原设置。"
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func safeData(at url: URL, maximumBytes: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) == 1,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
            throw AutomaticReceiverError.localStateUnavailable
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw AutomaticReceiverError.localStateUnavailable }
        return data
    }
}
