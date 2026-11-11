import Combine
import CryptoKit
import Foundation
import RecordingCore

// Only the UIKit bridge is replaced. Production queueing, receipt validation,
// credential collection migration, archive building and persistence run unchanged.
@MainActor
final class AutomaticDeliveryBackgroundEvents {
    static let shared = AutomaticDeliveryBackgroundEvents()
    let gate = BackgroundSessionRestorationGate(isForeground: { true })
    private(set) var registrations = 0
    private(set) var completions: [String] = []
    func registerStore(_ store: PhoneAutomaticDeliveryStore) { registrations += 1 }
    func finish(_ identifier: String, token: UUID?) { completions.append(identifier) }
}

enum ProbeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case let .failed(message): return message } }
}

final class MemoryKeychain: AutomaticReceiverKeychainStorage {
    var values: [String: Data] = [:]
    var failWrites: Set<String> = []
    var failRemovals: Set<String> = []
    private(set) var removedAccounts: [String] = []
    func read(_ account: String) throws -> Data? { values[account] }
    func write(_ data: Data, account: String) throws {
        guard !failWrites.contains(account) else { throw AutomaticReceiverError.credentialsUnavailable }
        values[account] = data
    }
    func remove(_ account: String) throws {
        guard !failRemovals.contains(account) else { throw AutomaticReceiverError.credentialsUnavailable }
        values.removeValue(forKey: account)
        removedAccounts.append(account)
    }
}

final class SyntheticTransferClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ interval: TimeInterval) { lock.lock(); date.addTimeInterval(interval); lock.unlock() }
}

final class SyntheticDeliveryLease: AutomaticDeliveryExecutionLease, @unchecked Sendable {
    private let lock = NSLock()
    private var permitted: Bool
    private var ended = 0
    init(permitted: Bool = true) { self.permitted = permitted }
    var hasTimeRemaining: Bool { lock.lock(); defer { lock.unlock() }; return permitted && ended == 0 }
    var endCount: Int { lock.lock(); defer { lock.unlock() }; return ended }
    func end() { lock.lock(); ended += 1; lock.unlock() }
}

final class DeliveryLeaseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<(any AutomaticDeliveryExecutionLease)?, Never>] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return waiting.count }
    func acquire() async -> (any AutomaticDeliveryExecutionLease)? {
        await withCheckedContinuation { continuation in
            lock.lock(); waiting.append(continuation); lock.unlock()
        }
    }
    func release(_ lease: SyntheticDeliveryLease, at index: Int = 0) {
        lock.lock(); let continuation = waiting.remove(at: index); lock.unlock()
        continuation.resume(returning: lease)
    }
}

final class ControlledTransport: AutomaticReceiverTransport, @unchecked Sendable {
    struct Upload: Sendable {
        let id: UUID
        let archiveURL: URL
        let sha256: String
        let attemptCount: Int
    }
    let credentials: AutomaticReceiverCredentials
    let identifier: String
    private let complete: @Sendable (AutomaticReceiverTransferResult) async -> Void
    private let finished: @Sendable (BackgroundSessionEvent) -> Void
    private let events = AutomaticReceiverEventDrain()
    private let uploadErrorCode: Int?
    private let uploadError: Error?
    private let lock = NSLock()
    private var uploadsValue: [Upload] = []
    private var activeValue: Set<UUID> = []
    private var cancellationValue = 0
    private var cancelledIDsValue: Set<UUID> = []
    private var progressValue: [UUID: Int64] = [:]
    private var advancesBeforeCancellation: Set<UUID> = []
    func progressBeforeCancellation(_ id: UUID) { locked { _ = advancesBeforeCancellation.insert(id) } }
    var cancelledDeliveryIDs: Set<UUID> { locked { cancelledIDsValue } }
    var uploads: [Upload] { locked { uploadsValue } }
    var cancellationCount: Int { locked { cancellationValue } }
    var activeIDs: Set<UUID> { locked { activeValue } }

    init(credentials: AutomaticReceiverCredentials, activeIDs: Set<UUID> = [], uploadErrorCode: Int? = nil,
         uploadError: Error? = nil,
         complete: @escaping @Sendable (AutomaticReceiverTransferResult) async -> Void,
         finished: @escaping @Sendable (BackgroundSessionEvent) -> Void) {
        self.finished = finished
        self.credentials = credentials
        self.complete = complete
        self.uploadErrorCode = uploadErrorCode
        self.uploadError = uploadError
        activeValue = activeIDs
        identifier = AutomaticReceiverClient.sessionIdentifier(for: credentials.scope)
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func activeDeliveryIDs() async -> Set<UUID> { activeIDs }
    func activeTransfers() async -> [AutomaticDeliveryTransferProgress] {
        locked { activeValue.map { id in
            .init(deliveryID: id, bytesSent: progressValue[id] ?? 0, bytesReceived: 0,
                  attemptCount: uploadsValue.last(where: { $0.id == id })?.attemptCount)
        } }
    }
    func cancelTransfer(ifUnchanged progress: AutomaticDeliveryTransferProgress) async -> Bool {
        // The real session delivers cancellation asynchronously. Keep the task
        // until the probe emits that callback so ledger ordering is exercised.
        locked {
            if advancesBeforeCancellation.remove(progress.deliveryID) != nil { progressValue[progress.deliveryID] = 1 }
            guard activeValue.contains(progress.deliveryID),
                  (progressValue[progress.deliveryID] ?? 0) == progress.bytesSent,
                  uploadsValue.last(where: { $0.id == progress.deliveryID })?.attemptCount == progress.attemptCount else { return false }
            cancelledIDsValue.insert(progress.deliveryID)
            return true
        }
    }
    func upload(deliveryID: UUID, attemptCount: Int, archiveURL: URL, sha256: String) throws {
        if let uploadError { throw uploadError }
        if let uploadErrorCode {
            throw NSError(domain: NSURLErrorDomain, code: uploadErrorCode,
                userInfo: [NSLocalizedDescriptionKey: "synthetic-private-host.local /synthetic/private/path"])
        }
        locked {
            uploadsValue.append(.init(id: deliveryID, archiveURL: archiveURL, sha256: sha256, attemptCount: attemptCount))
            activeValue.insert(deliveryID)
        }
    }
    func cancelAll() { locked { cancellationValue += 1; activeValue.removeAll() } }
    func cancelTransfers() async { cancelAll() }
    private let invalidation = AutomaticReceiverInvalidationBarrier()
    var holdInvalidation = false
    func invalidateAndDrain() async {
        invalidation.request { cancelAll() }
        if !holdInvalidation { releaseInvalidation() }
        await invalidation.wait()
    }
    func releaseInvalidation() {
        let invalidation = invalidation
        events.append { invalidation.complete() }
    }
    func emit(_ result: AutomaticReceiverTransferResult) {
        locked {
            let activeAttempt = uploadsValue.last(where: { $0.id == result.deliveryID })?.attemptCount
            if result.attemptCount == nil || result.attemptCount == activeAttempt {
                _ = activeValue.remove(result.deliveryID)
            }
        }
        let complete = complete
        events.append { await complete(result) }
    }
    func finishEvents() {
        let finished = finished
        let event = BackgroundSessionEventTracker.shared.capture(identifier)
        events.append { finished(event) }
    }
    func acknowledge(_ upload: Upload, recordingID: UUID, storedAt: Date = Date()) {
        let receipt = AutomaticDeliveryReceipt(receiverID: credentials.scope.receiverID, deliveryID: upload.id,
            archiveSHA256: upload.sha256, recordingIDs: [recordingID], storedAt: storedAt)
        emit(.init(scope: credentials.scope, deliveryID: upload.id, receipt: receipt,
                   statusCode: 200, message: nil, requiresRepair: false, attemptCount: upload.attemptCount))
    }
}

final class ControlledFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [ControlledTransport] = []
    var holdNewInvalidation = false
    private let restoredActiveIDs: [UUID: Set<UUID>]
    private let uploadErrorCode: Int?
    private let uploadError: Error?
    init(restoredActiveIDs: [UUID: Set<UUID>] = [:], uploadErrorCode: Int? = nil, uploadError: Error? = nil) {
        self.restoredActiveIDs = restoredActiveIDs; self.uploadErrorCode = uploadErrorCode
        self.uploadError = uploadError
    }
    func make(_ credentials: AutomaticReceiverCredentials,
              _ complete: @escaping @Sendable (AutomaticReceiverTransferResult) async -> Void,
              _ finished: @escaping @Sendable (BackgroundSessionEvent) -> Void) throws -> any AutomaticReceiverTransport {
        let transport = ControlledTransport(credentials: credentials,
            activeIDs: restoredActiveIDs[credentials.scope.grantEpoch] ?? [], uploadErrorCode: uploadErrorCode,
            uploadError: uploadError,
            complete: complete, finished: finished)
        transport.holdInvalidation = holdNewInvalidation
        lock.lock(); transports.append(transport); lock.unlock()
        return transport
    }
    func clients(for id: UUID) -> [ControlledTransport] {
        lock.lock(); defer { lock.unlock() }
        return transports.filter { $0.credentials.scope.receiverID == id }
    }
    var all: [ControlledTransport] { lock.lock(); defer { lock.unlock() }; return transports }
}

@MainActor
final class Fixture {
    let root: URL
    let repository: RecordingRepository
    let storage = MemoryKeychain()
    let vault: AutomaticReceiverCredentialVault
    var factory = ControlledFactory()
    var store: PhoneAutomaticDeliveryStore?
    var requestedRetryDates: [Date] = []
    var returnedTranscriptIDs: [UUID] = []
    var draftURL: URL { root.appendingPathComponent("AutomaticDeliveryPairing.json") }

    init(root: URL) throws {
        self.root = root
        repository = try RecordingRepository(root: root.appendingPathComponent("phone-library"))
        vault = AutomaticReceiverCredentialVault(storage: storage)
    }
    func start(transcripts: TranscriptRepository? = nil,
               transcriptFactory: @escaping AutomaticReceiverTranscriptClientFactory = {
                   try AutomaticReceiverTranscriptClient(credentials: $0)
               }) {
        let factory = self.factory
        store = PhoneAutomaticDeliveryStore(repository: repository, transcriptRepository: transcripts, vault: vault,
            observesNetwork: false, schedulesRetries: false, registersBackgroundEvents: false,
            requestBackgroundRetry: { [weak self] in self?.requestedRetryDates.append($0) },
            pairingDraftURL: draftURL,
            onTranscriptDidSave: { [weak self] in self?.returnedTranscriptIDs.append($0.id) },
            transcriptClientFactory: transcriptFactory,
            clientFactory: { try factory.make($0, $1, $2) })
    }
    @discardableResult
    func writeDraft(_ payload: AutomaticReceiverPairingPayload) throws -> Data {
        let data = try JSONEncoder().encode(payload)
        try data.write(to: draftURL, options: .atomic)
        return data
    }
    func discover() throws {
        try store?.discover(manifests: repository.manifests(), receivedSegmentIDs: repository.receivedSegmentIDs())
    }
    func worker(_ id: UUID) throws -> PhoneReceiverDeliveryStore {
        guard let worker = store?.receivers.first(where: { $0.id == id }) else {
            throw ProbeFailure.failed("Expected receiver row is missing")
        }
        return worker
    }
    func pairing(_ id: UUID) throws -> AutomaticReceiverStoredPairing {
        guard let value = try vault.loadAll().first(where: { $0.credentials.scope.receiverID == id }) else {
            throw ProbeFailure.failed("Expected active credential is missing")
        }
        return value
    }
    func ledger(_ id: UUID) throws -> AutomaticDeliveryLedger {
        let scope = try pairing(id).credentials.scope
        return try AutomaticDeliveryLedger.load(from: grantDirectory(scope).appendingPathComponent("ledger.json"), expectedScope: scope)
    }
    func grantDirectory(_ scope: AutomaticDeliveryScope) -> URL {
        repository.root.appendingPathComponent("AutomaticDelivery").appendingPathComponent(scope.grantEpoch.uuidString.lowercased())
    }
    func addRecording(_ sequence: Int) throws -> SegmentManifest {
        var bytes = Data([0x63, 0x61, 0x66, 0x66, 0, 1, 0, 0])
        func big<T: FixedWidthInteger>(_ value: T) -> Data {
            var encoded = value.bigEndian
            return withUnsafeBytes(of: &encoded) { Data($0) }
        }
        var description = big(Double(16_000).bitPattern)
        description.append(Data("lpcm".utf8))
        for value: UInt32 in [12, 2, 1, 1, 16] { description.append(big(value)) }
        bytes.append(Data("desc".utf8)); bytes.append(big(UInt64(description.count))); bytes.append(description)
        var pcm = Data()
        for index in 0..<160 {
            var value = Int16((sin(Double(index + sequence + 1) * 0.2) * 4_000).rounded()).littleEndian
            pcm.append(withUnsafeBytes(of: &value) { Data($0) })
        }
        bytes.append(Data("data".utf8)); bytes.append(big(UInt64(pcm.count + 4))); bytes.append(big(UInt32(0))); bytes.append(pcm)
        let id = UUID()
        let incoming = root.appendingPathComponent("synthetic-\(sequence).caf")
        try bytes.write(to: incoming)
        let start = Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence))
        let manifest = SegmentManifest(id: id, sessionID: UUID(), sequence: sequence, startedAt: start,
            endedAt: start.addingTimeInterval(0.01), sampleRate: 16_000, frameCount: 160,
            fileName: id.uuidString.lowercased() + ".caf", byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        _ = try repository.acceptIncomingFile(at: incoming, manifest: manifest)
        return manifest
    }
    func legacy(_ payload: AutomaticReceiverPairingPayload, recordings: [SegmentManifest], paused: Bool,
                deliveredFirst: Bool) throws -> AutomaticDeliveryLedger {
        let scope = AutomaticDeliveryScope(receiverID: payload.receiverID, pairingID: UUID(), grantEpoch: UUID(),
            sourceInstallationID: try vault.installationID(), endpoint: payload.endpoint,
            certificateSHA256: payload.certificateSHA256)
        let credentials = AutomaticReceiverCredentials(scope: scope, token: payload.token)
        storage.values["active-pairing"] = try TransportCodec.encode(credentials)
        var ledger = try AutomaticDeliveryLedger(scope: scope, baselineIDs: Set(recordings.map(\.id)),
            selectedExistingIDs: [recordings[0].id], includeFuture: false, createdAt: Date())
        let job = try ledger.reconcile(manifests: recordings, receivedSegmentIDs: Set(recordings.map(\.id)))[0]
        if deliveredFirst {
            try ledger.beginPreparation(deliveryID: job)
            try ledger.recordPreparedArchive(deliveryID: job, relativePath: job.uuidString.lowercased() + ".zip",
                sha256: String(repeating: "d", count: 64), byteCount: 100)
            try ledger.beginUpload(deliveryID: job)
            try ledger.acceptReceipt(.init(receiverID: scope.receiverID, deliveryID: job,
                archiveSHA256: String(repeating: "d", count: 64), recordingIDs: [recordings[0].id], storedAt: Date()),
                forScope: scope)
        }
        let directory = grantDirectory(scope)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ledger.persist(to: directory.appendingPathComponent("ledger.json"))
        let settings: [String: Any] = ["schemaVersion": 1, "grantEpoch": scope.grantEpoch.uuidString, "enabled": !paused]
        try JSONSerialization.data(withJSONObject: settings).write(to: directory.appendingPathComponent("settings.json"))
        return ledger
    }
    func isolatedWorker(_ payload: AutomaticReceiverPairingPayload,
                        restorationGate: BackgroundSessionRestorationGate? = nil,
                        transferCheckDate: @escaping @Sendable () -> Date = { Date() },
                        healthDate: @escaping @Sendable () -> Date = { Date() },
                        healthCheck: @escaping AutomaticReceiverHealthCheck = { _ in .reachable },
                        clientFactory: AutomaticReceiverClientFactory? = nil,
                        beginExecution: @escaping @Sendable (@escaping @Sendable (String) -> Void) async -> (any AutomaticDeliveryExecutionLease)?) throws -> PhoneReceiverDeliveryStore {
        let scope = AutomaticDeliveryScope(receiverID: payload.receiverID, pairingID: UUID(), grantEpoch: UUID(),
            sourceInstallationID: try vault.installationID(), endpoint: payload.endpoint,
            certificateSHA256: payload.certificateSHA256)
        let credentials = AutomaticReceiverCredentials(scope: scope, token: payload.token)
        let pairing = AutomaticReceiverStoredPairing(displayName: "Synthetic background", credentials: credentials, enabled: true)
        try PhoneReceiverDeliveryStore.prepareNewGrant(credentials, repository: repository,
            knownRecordingIDs: Set(try repository.manifests().map(\.id)))
        try vault.saveAll([pairing])
        let factory = factory, vault = vault
        return PhoneReceiverDeliveryStore(pairing: pairing, repository: repository, transcriptRepository: nil,
            persistEnabled: { enabled in
                var values = try vault.loadAll(); values[0].enabled = enabled; try vault.saveAll(values)
            }, schedulesRetries: false,
            requestBackgroundRetry: { [weak self] in self?.requestedRetryDates.append($0) },
            healthCheck: healthCheck, healthDate: healthDate,
            transferCheckDate: transferCheckDate, beginExecution: beginExecution,
            restorationGate: restorationGate,
            clientFactory: clientFactory ?? { try factory.make($0, $1, $2) })
    }
    func stop() {
        storage.failWrites = []; storage.failRemovals = []
        if let store { for id in store.receivers.map(\.id) { _ = store.removeReceiver(id) } }
        store = nil
    }
}

@MainActor
final class Probe {
    let fixtures: URL
    var assertionCount = 0
    var cases: [String] = []
    var failures: [String] = []
    init(fixtures: URL) { self.fixtures = fixtures }
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertionCount += 1
        guard try condition() else { throw ProbeFailure.failed(message) }
    }
    func eventually(_ message: String, _ predicate: () throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !(try predicate()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProbeFailure.failed("Timed out: " + message) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        assertionCount += 1
    }
    func settle() async throws { for _ in 0..<10 { await Task.yield() }; try await Task.sleep(nanoseconds: 30_000_000) }
    func run(_ name: String, _ body: (Fixture) async throws -> Void) async {
        if let filter = ProcessInfo.processInfo.environment["RFA_PROBE_CASE_FILTER"], !name.contains(filter) { return }
        cases.append(name)
        do {
            let fixture = try Fixture(root: fixtures.appendingPathComponent(name))
            defer { fixture.stop() }
            try await body(fixture)
        } catch { failures.append(name + ": " + String(describing: error)) }
    }
    func payload(_ label: String, id: UUID = UUID(), seed: UInt8 = 1) -> AutomaticReceiverPairingPayload {
        let token = Data(repeating: seed, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return .init(schemaVersion: 1, endpoint: "https://" + label + ".invalid:9443", receiverID: id,
                     token: token, certificateSHA256: String(repeating: "a", count: 64))
    }
    func pair(_ value: AutomaticReceiverPairingPayload, name: String, in f: Fixture) throws {
        try check(f.store?.pair(value, name: name) == true, "Pairing should succeed for a new receiver")
    }
    func uploaded(_ id: UUID, in f: Fixture) async throws -> (ControlledTransport, ControlledTransport.Upload) {
        try await eventually("receiver upload is registered") { f.factory.clients(for: id).last?.uploads.isEmpty == false }
        guard let client = f.factory.clients(for: id).last, let upload = client.uploads.last else {
            throw ProbeFailure.failed("Transport upload disappeared")
        }
        return (client, upload)
    }
    func retryAfterBackoff(_ id: UUID, in f: Fixture) async throws -> (ControlledTransport, ControlledTransport.Upload) {
        try await eventually("Interrupted transfer enters durable backoff") {
            try f.ledger(id).jobs.contains { $0.state == .retryWaiting }
        }
        guard let job = try f.ledger(id).jobs.first(where: { $0.state == .retryWaiting }), let due = job.nextAttemptAt else {
            throw ProbeFailure.failed("Interrupted transfer has no retry time")
        }
        try check(due.timeIntervalSinceNow > 0 && due.timeIntervalSinceNow <= 16,
                  "Interrupted first attempt must enter the bounded 15-second backoff")
        try check(f.factory.clients(for: id).last?.uploads.isEmpty == true, "Recovery must not send before the retry time")
        while due.timeIntervalSinceNow > 0 {
            try await Task.sleep(nanoseconds: UInt64(max(0.001, min(due.timeIntervalSinceNow + 0.002, 0.2)) * 1_000_000_000))
        }
        try f.worker(id).resume()
        return try await uploaded(id, in: f)
    }

    func execute() async {
        await run("pairing_draft_can_arrive_after_first_read") { f in
            let a = self.payload("draft-a")
            f.start(); try f.discover()
            try self.check(try f.store?.loadPairingDraft() == nil, "Missing draft must be a retryable absence")
            let bytes = try f.writeDraft(a)
            try self.check(try f.store?.loadPairingDraft() == String(data: bytes, encoding: .utf8),
                           "A later read must discover a newly copied draft")
            try self.check(f.store?.receivers.isEmpty == true && f.factory.all.isEmpty,
                           "Reading a draft must not create a pairing or transport")
            try self.check(try Data(contentsOf: f.draftURL) == bytes, "Reading a draft must preserve its file")
            try self.pair(a, name: "Draft A", in: f)
            try self.check(!FileManager.default.fileExists(atPath: f.draftURL.path),
                           "Successfully adopting the unchanged draft must consume its file")
        }
        await run("manual_pairing_preserves_unselected_draft") { f in
            let a = self.payload("draft-a"), b = self.payload("manual-b", seed: 2)
            let bytes = try f.writeDraft(a)
            f.start(); try f.discover()
            try self.check(try f.store?.loadPairingDraft() != nil, "Draft A should load")
            try self.pair(b, name: "Manual B", in: f)
            try self.check(try Data(contentsOf: f.draftURL) == bytes,
                           "Pairing manually supplied B must preserve the unused draft A")
            try self.check(f.store?.receivers.map(\.receiverID) == [b.receiverID],
                           "Only the manually selected receiver may be authorized")
            try self.pair(a, name: "Draft A", in: f)
            try self.check(!FileManager.default.fileExists(atPath: f.draftURL.path),
                           "The preserved draft can be consumed only after its own successful pairing")
        }
        await run("same_receiver_with_different_token_preserves_draft") { f in
            let a = self.payload("draft-a")
            let edited = self.payload("draft-a", id: a.receiverID, seed: 2)
            let bytes = try f.writeDraft(a)
            f.start(); try f.discover()
            try self.check(try f.store?.loadPairingDraft() != nil, "Draft should load before editing its credential")
            try self.pair(edited, name: "Edited credential", in: f)
            try self.check(try Data(contentsOf: f.draftURL) == bytes,
                           "Matching receiver identity alone must not consume a draft containing a different token")
            try self.check(try f.pairing(a.receiverID).credentials.token == edited.token,
                           "The user's explicitly selected credential must be the one saved")
        }
        await run("replaced_pairing_draft_is_not_consumed") { f in
            let a = self.payload("draft-a"), b = self.payload("draft-b", seed: 2)
            try f.writeDraft(a)
            f.start(); try f.discover()
            try self.check(try f.store?.loadPairingDraft() != nil, "Original draft should load")
            let replacement = try f.writeDraft(b)
            try self.pair(a, name: "Previously read A", in: f)
            try self.check(try Data(contentsOf: f.draftURL) == replacement,
                           "Pairing a previously read draft must preserve a newer file at the same path")
            try self.check(try f.store?.loadPairingDraft() == String(data: replacement, encoding: .utf8),
                           "The replacement draft should remain available to read")
            try self.pair(b, name: "Replacement B", in: f)
            try self.check(!FileManager.default.fileExists(atPath: f.draftURL.path),
                           "The replacement can be consumed after it is read and successfully adopted")
        }
        await run("rewritten_pairing_draft_bytes_are_preserved") { f in
            let a = self.payload("draft-a")
            let bytes = try f.writeDraft(a)
            f.start(); try f.discover()
            try self.check(try f.store?.loadPairingDraft() != nil, "Original draft should load")
            var replacement = bytes
            replacement.append(Data("\n".utf8))
            try replacement.write(to: f.draftURL, options: .atomic)
            try self.pair(a, name: "Draft A", in: f)
            try self.check(try Data(contentsOf: f.draftURL) == replacement,
                           "Even an equivalent payload must be preserved when the draft file bytes changed after reading")
        }
        await run("failed_pairing_keeps_draft_for_retry") { f in
            let a = self.payload("draft-a")
            let bytes = try f.writeDraft(a)
            f.start(); try f.discover()
            try self.check(try f.store?.loadPairingDraft() != nil, "Draft should load before a save failure")
            f.storage.failWrites.insert("receiver-pairings-v1")
            try self.check(f.store?.pair(a, name: "Draft A") == false, "Failed credential persistence must reject pairing")
            try self.check(try Data(contentsOf: f.draftURL) == bytes,
                           "A failed pairing must preserve the exact draft for retry")
            try self.check(f.store?.receivers.isEmpty == true && f.factory.all.isEmpty,
                           "A failed pairing must not activate a receiver")
            f.storage.failWrites.removeAll()
            try self.pair(a, name: "Draft A", in: f)
            try self.check(!FileManager.default.fileExists(atPath: f.draftURL.path),
                           "Only the successful retry may consume the unchanged selected draft")
        }
        await run("receiver_connection_status_is_metadata_only_and_never_infers_live_reachability") { f in
            let a = self.payload("connection-status")
            f.start(); try f.discover(); try self.pair(a, name: "Saved receiver", in: f)
            let worker = try f.worker(a.receiverID)
            await worker.waitForPreparation()
            let saved = try f.pairing(a.receiverID)
            let ledger = try f.ledger(a.receiverID)
            let clients = f.factory.all.count
            for _ in 0..<10 {
                try self.check(worker.pairingStatusTitle == "配对已保存"
                    && worker.reachabilityTitle == "当前可达性未确认",
                    "Saved credentials and an enabled setting cannot establish current reachability.")
                try self.check(worker.connectionSummary == "自动同步已开启 · 可达性未确认"
                    && worker.lastReceiptAt == nil && worker.lastIncompleteDeliveryAt == nil,
                    "An empty queue is not a successful connection or a saved receipt.")
            }
            try self.check(f.factory.all.count == clients && f.factory.all.allSatisfy { $0.uploads.isEmpty },
                "Reading connection status cannot create a transport, check recordings or send a request.")
            worker.setEnabled(false)
            try self.check(worker.pairingStatusTitle == "配对已保存"
                && worker.connectionSummary == "自动同步已暂停 · 可达性未确认",
                "A paused setting preserves pairing without claiming that the computer disconnected.")
            try self.check(try f.pairing(a.receiverID).credentials.scope == saved.credentials.scope
                && f.ledger(a.receiverID).scope == ledger.scope,
                "Status presentation and pause preserve the exact existing grant.")
        }
        await run("receiver_connection_status_tracks_persisted_failure_and_late_receipt_without_online_claim") { f in
            let recording = try f.addRecording(0), a = self.payload("connection-failure")
            f.start(); try f.discover(); try self.pair(a, name: "Saved receiver", in: f)
            let worker = try f.worker(a.receiverID)
            let (client, upload) = try await self.uploaded(a.receiverID, in: f)
            let failureMessage = AutomaticReceiverFailureCategory.timeout.title + "。" + AutomaticReceiverFailureCategory.timeout.hint
            client.emit(.init(scope: client.credentials.scope, deliveryID: upload.id, receipt: nil,
                statusCode: nil, message: "synthetic-private-host.local /synthetic/private/path", requiresRepair: false,
                attemptCount: upload.attemptCount, failureCategory: .timeout))
            try await self.eventually("The actual failure is durably projected") {
                worker.lastIncompleteDeliveryAt != nil && worker.lastIncompleteDeliveryMessage == failureMessage
            }
            try self.check(worker.isEnabled && worker.connectionSummary == "配对已保存 · 最近传输失败"
                && worker.reachabilityTitle == "当前可达性未确认" && worker.lastReceiptAt == nil
                && worker.connectionWarning && worker.lastTransferFailure == .timeout
                && worker.lastTransferDeliveryID == upload.id && worker.lastTransferAt != nil,
                "A timeout exposes its delivery failure and keeps automatic retry, without guessing current offline status.")
            let job = try f.ledger(a.receiverID).jobs[0]
            try self.check(worker.lastIncompleteDeliveryAt == job.updatedAt && job.state == .retryWaiting,
                "The shown time is the persisted delivery event, not a fabricated current check time.")
            let receiptTime = Date(timeIntervalSince1970: 1_792_750_100)
            client.acknowledge(upload, recordingID: recording.id, storedAt: receiptTime)
            try await self.eventually("The original late receipt replaces the incomplete delivery") {
                worker.lastReceiptAt == receiptTime && worker.lastIncompleteDeliveryAt == nil
                    && worker.lastIncompleteDeliveryMessage == nil
            }
            try self.check(worker.connectionSummary == "自动同步已开启 · 可达性未确认"
                && worker.reachabilityTitle == "当前可达性未确认" && worker.deliveredCount == 1
                && worker.lastTransferFailure == nil && worker.lastTransferDeliveryID == upload.id && !worker.connectionWarning,
                "A durable past receipt proves saved delivery, never the computer's current reachability.")
            try self.check(try f.ledger(a.receiverID).scope == client.credentials.scope
                && f.factory.clients(for: a.receiverID).flatMap(\.uploads).count == 1,
                "Status updates preserve the grant and never initiate an extra upload or retry.")
        }
        await run("receiver_connection_status_inflight_retry_preserves_failure_warning_until_receipt") { f in
            let recording = try f.addRecording(0), a = self.payload("connection-retry")
            f.start(); try f.discover(); try self.pair(a, name: "Saved receiver", in: f)
            let worker = try f.worker(a.receiverID)
            let (firstClient, firstUpload) = try await self.uploaded(a.receiverID, in: f)
            let failureMessage = AutomaticReceiverFailureCategory.timeout.title + "。" + AutomaticReceiverFailureCategory.timeout.hint
            firstClient.emit(.init(scope: firstClient.credentials.scope, deliveryID: firstUpload.id, receipt: nil,
                statusCode: nil, message: failureMessage, requiresRepair: false, attemptCount: firstUpload.attemptCount,
                failureCategory: .timeout))
            try await self.eventually("First attempt enters durable backoff") {
                try f.ledger(a.receiverID).job(for: firstUpload.id)?.state == .retryWaiting
                    && worker.lastIncompleteDeliveryMessage == failureMessage
            }
            let failed = try f.ledger(a.receiverID).job(for: firstUpload.id)!
            let firstFailureAt = worker.lastTransferAt
            guard let due = failed.nextAttemptAt else { throw ProbeFailure.failed("Failed delivery has no retry date") }
            try self.check(worker.connectionSummary == "配对已保存 · 最近传输失败"
                && failed.attemptCount == 1 && worker.lastIncompleteDeliveryAt == failed.updatedAt,
                "Before its due date, the persisted failure is shown as waiting to retry.")
            worker.resume()
            await worker.waitForPreparation()
            try self.check(f.factory.clients(for: a.receiverID).flatMap(\.uploads).count == 1,
                "Reading or refreshing status cannot bypass the actual retry backoff.")
            while due.timeIntervalSinceNow > 0 {
                try await Task.sleep(nanoseconds: UInt64(max(0.001, min(due.timeIntervalSinceNow + 0.002, 0.2)) * 1_000_000_000))
            }
            worker.resume()
            try await self.eventually("Due second attempt registers and remains in flight") {
                try f.ledger(a.receiverID).job(for: firstUpload.id)?.state == .uploading
                    && f.factory.clients(for: a.receiverID).flatMap(\.uploads).count == 2
            }
            await worker.waitForPreparation()
            guard let retryClient = f.factory.clients(for: a.receiverID).last,
                  let retryUpload = retryClient.uploads.last else { throw ProbeFailure.failed("Retry upload is missing") }
            let retry = try f.ledger(a.receiverID).job(for: firstUpload.id)!
            try self.check(retryUpload.id == firstUpload.id && retryUpload.attemptCount == 2
                && retry.archive == failed.archive && retry.state == .uploading && retry.receipt == nil,
                "The controlled second sender stays unresolved with the original delivery and archive identity.")
            for _ in 0..<10 {
                try self.check(worker.connectionSummary == "配对已保存 · 最近传输失败"
                    && worker.uploadingCount == 1 && worker.lastReceiptAt == nil && worker.connectionWarning,
                    "An unresolved retry cannot hide its earlier failure warning or claim a receipt.")
            }
            try self.check(worker.lastIncompleteDeliveryMessage == failureMessage && retry.lastError == failureMessage,
                "Retry registration preserves the earlier error for inspection until a valid receipt arrives.")
            try self.check(worker.lastIncompleteDeliveryAt == retry.updatedAt && retry.updatedAt > failed.updatedAt,
                "The displayed delivery-record time advances at retry registration; it is not the first failure time.")
            try self.check(worker.lastTransferAt == firstFailureAt && worker.lastTransferFailure == .timeout,
                "The separate last transfer result retains its actual failure time during retry registration.")
            firstClient.emit(.init(scope: firstClient.credentials.scope, deliveryID: firstUpload.id, receipt: nil,
                statusCode: 401, message: "synthetic obsolete failure", requiresRepair: true,
                attemptCount: firstUpload.attemptCount, failureCategory: .unauthorized))
            try await self.settle()
            try self.check(worker.lastTransferAt == firstFailureAt && worker.lastTransferFailure == .timeout
                && worker.uploadingCount == 1,
                "A stale attempt failure cannot replace the last valid result or block its active retry.")
            try self.check(f.factory.clients(for: a.receiverID).flatMap(\.uploads).count == 2,
                "Repeated status reads do not start a third sender.")
            let receiptTime = Date(timeIntervalSince1970: 1_792_750_200)
            retryClient.acknowledge(retryUpload, recordingID: recording.id, storedAt: receiptTime)
            try await self.eventually("Valid second-attempt receipt clears historical error") {
                worker.lastReceiptAt == receiptTime && worker.lastIncompleteDeliveryAt == nil
                    && worker.lastIncompleteDeliveryMessage == nil && worker.uploadingCount == 0
            }
            let delivered = try f.ledger(a.receiverID).job(for: firstUpload.id)!
            try self.check(delivered.state == .delivered && delivered.lastError == nil && delivered.attemptCount == 2
                && worker.connectionSummary == "自动同步已开启 · 可达性未确认" && worker.deliveredCount == 1,
                "Only the validated receipt finishes delivery and clears the old error; reachability remains unverified.")
            try self.check(try f.ledger(a.receiverID).scope == firstClient.credentials.scope
                && f.factory.clients(for: a.receiverID).flatMap(\.uploads).count == 2,
                "Retry and receipt projection preserve the grant and create no extra delivery.")
        }
        await run("independent_receipts_for_same_recording") { f in
            let recording = try f.addRecording(0), a = self.payload("a"), b = self.payload("b", seed: 2)
            f.start(); try f.discover(); try self.pair(a, name: "Agent A", in: f); try self.pair(b, name: "Agent B", in: f)
            let (ac, au) = try await self.uploaded(a.receiverID, in: f)
            let (bc, bu) = try await self.uploaded(b.receiverID, in: f)
            try self.check(au.id != bu.id, "Each receiver must have an independent delivery identity")
            try self.check(au.archiveURL != bu.archiveURL, "Each receiver must own its archive path")
            try self.check(try f.ledger(a.receiverID).jobs[0].manifest.id == recording.id, "A must queue the original recording")
            try self.check(try f.ledger(b.receiverID).jobs[0].manifest.id == recording.id, "B must queue the same original recording")
            let receiptTime = Date(timeIntervalSince1970: 1_792_750_000)
            ac.acknowledge(au, recordingID: recording.id, storedAt: receiptTime)
            try await self.eventually("A receipt commits") { try f.worker(a.receiverID).deliveredCount == 1 }
            try self.check(try f.worker(a.receiverID).deliveredSegmentIDs == [recording.id]
                           && f.worker(a.receiverID).lastReceiptAt == receiptTime,
                           "Dashboard progress must expose the exact durable receiver receipt IDs and time")
            try self.check(try f.worker(b.receiverID).deliveredCount == 0, "A receipt must not acknowledge B")
            try self.check(try f.worker(b.receiverID).deliveredSegmentIDs.isEmpty
                           && f.worker(b.receiverID).lastReceiptAt == nil,
                           "An in-flight receiver must not inherit another receiver's dashboard progress")
            try self.check(try f.ledger(b.receiverID).jobs[0].state == .uploading, "B remains independently in flight")
            bc.acknowledge(bu, recordingID: recording.id)
            try await self.eventually("B receipt commits") { try f.worker(b.receiverID).deliveredCount == 1 }
            try self.check(try f.repository.manifests().count == 1, "Fan-out must not duplicate the source library")
            try self.check(try RecordingRepository.fingerprint(of: f.repository.audioURL(for: recording)).sha256 == recording.sha256,
                           "Receiver receipts must not delete or modify source audio")
        }
        await run("pause_a_does_not_pause_b") { f in
            let recording = try f.addRecording(0), a = self.payload("a"), b = self.payload("b", seed: 2)
            f.start(); try f.discover(); try self.pair(a, name: "Agent A", in: f); try self.pair(b, name: "Agent B", in: f)
            let (ac, au) = try await self.uploaded(a.receiverID, in: f)
            let (bc, bu) = try await self.uploaded(b.receiverID, in: f)
            let bCancellations = bc.cancellationCount
            try f.worker(a.receiverID).setEnabled(false)
            try self.check(try !f.worker(a.receiverID).isEnabled, "A must be paused")
            try self.check(try f.worker(b.receiverID).isEnabled, "B must remain enabled")
            try self.check(ac.cancellationCount > 0, "Pausing A must cancel only A transport")
            try self.check(bc.cancellationCount == bCancellations && bc.activeIDs.contains(bu.id), "B's active upload must remain")
            bc.acknowledge(bu, recordingID: recording.id)
            try await self.eventually("B finishes while A paused") { try f.worker(b.receiverID).deliveredCount == 1 }
            try f.worker(a.receiverID).setEnabled(true)
            ac.acknowledge(au, recordingID: recording.id)
            try await self.settle()
            try self.check(try f.worker(a.receiverID).deliveredCount == 0,
                           "Cancelled A client callback must not acknowledge the resumed client of the same grant")
            try self.check(try f.worker(b.receiverID).deliveredCount == 1,
                           "Stale same-grant A callback must not disturb B's committed receipt")
            let (resumed, upload) = try await self.retryAfterBackoff(a.receiverID, in: f)
            try self.check(upload.id == au.id && upload.sha256 == au.sha256, "Resume must reuse A's durable delivery and archive")
            resumed.acknowledge(upload, recordingID: recording.id)
            try await self.eventually("A finishes after its own resume") { try f.worker(a.receiverID).deliveredCount == 1 }
            try self.check(bc.uploads.count == 1, "Resuming A must not resend B")
        }
        await run("remove_and_late_callback_cannot_cross_receivers") { f in
            let recording = try f.addRecording(0), a = self.payload("a"), b = self.payload("b", seed: 2)
            f.start(); try f.discover(); try self.pair(a, name: "Agent A", in: f); try self.pair(b, name: "Agent B", in: f)
            let (old, oldUpload) = try await self.uploaded(a.receiverID, in: f)
            let (bc, bu) = try await self.uploaded(b.receiverID, in: f)
            let oldWorker = try f.worker(a.receiverID), oldScope = old.credentials.scope
            try self.check(f.store?.removeReceiver(a.receiverID) == true, "Remove A must commit")
            try self.check(f.store?.receivers.map(\.id) == [b.receiverID], "Only A must disappear")
            try self.check(try f.vault.loadAll().map { $0.credentials.scope.receiverID } == [b.receiverID], "Only A credential must disappear")
            try self.check(!oldWorker.isPaired && !oldWorker.isEnabled, "A's retained UI object must be retired")
            try self.check(f.store?.restoreBackgroundSession(old.identifier) == false, "Removed background grant must not reactivate")
            try self.check(f.store?.restoreBackgroundSession(bc.identifier) == true, "B background session must remain routable")
            let newA = self.payload("a", id: a.receiverID, seed: 3)
            try self.pair(newA, name: "Agent A replacement", in: f)
            let (fresh, freshUpload) = try await self.uploaded(a.receiverID, in: f)
            try self.check(fresh.credentials.scope.grantEpoch != oldScope.grantEpoch, "Re-pair must have a new grant")
            old.acknowledge(oldUpload, recordingID: recording.id)
            try await self.settle()
            try self.check(try f.worker(a.receiverID).deliveredCount == 0, "Old A receipt must not acknowledge new A")
            try self.check(try f.worker(b.receiverID).deliveredCount == 0, "Old A receipt must not acknowledge B")
            try self.check(try f.ledger(a.receiverID).jobs[0].id == freshUpload.id, "Late callback must not replace new A queue")
            bc.acknowledge(bu, recordingID: recording.id); fresh.acknowledge(freshUpload, recordingID: recording.id)
            try await self.eventually("Remaining current grants finish") {
                try f.worker(a.receiverID).deliveredCount == 1 && f.worker(b.receiverID).deliveredCount == 1
            }
            try self.check(FileManager.default.fileExists(atPath: f.repository.audioURL(for: recording).path), "Unpairing must preserve source audio")
            try self.check(FileManager.default.fileExists(atPath: f.grantDirectory(oldScope).appendingPathComponent("ledger.json").path),
                           "Unpairing must preserve historical queue evidence")
        }
        await run("duplicate_pairing_preserves_pause_and_queues") { f in
            _ = try f.addRecording(0); let a = self.payload("a"), b = self.payload("b", seed: 2)
            f.start(); try f.discover(); try self.pair(a, name: "Agent A", in: f); try self.pair(b, name: "Agent B", in: f)
            _ = try await self.uploaded(a.receiverID, in: f); _ = try await self.uploaded(b.receiverID, in: f)
            try f.worker(a.receiverID).setEnabled(false)
            let oldA = try f.ledger(a.receiverID), oldB = try f.ledger(b.receiverID)
            let bytes = f.storage.values["receiver-pairings-v1"], clientCount = f.factory.all.count
            try self.check(f.store?.pair(a, name: "Duplicate") == false, "Duplicate receiver ID must be rejected")
            let changed = self.payload("changed-endpoint", id: a.receiverID, seed: 4)
            try self.check(f.store?.pair(changed, name: "Replacement without removal") == false, "Changed credentials cannot silently replace a receiver")
            try self.check(f.storage.values["receiver-pairings-v1"] == bytes, "Rejected pair must not change credential collection")
            try self.check(try f.ledger(a.receiverID) == oldA && f.ledger(b.receiverID) == oldB, "Rejected pair must not reset either queue")
            try self.check(try !f.worker(a.receiverID).isEnabled && f.worker(b.receiverID).isEnabled, "Rejected pair must preserve each pause state")
            try self.check(f.factory.all.count == clientCount, "Rejected pair must not create background transports")
        }
        await run("legacy_paused_pairing_and_receipt_migrate_without_resend") { f in
            let first = try f.addRecording(0), second = try f.addRecording(1), a = self.payload("legacy")
            let legacy = try f.legacy(a, recordings: [first, second], paused: true, deliveredFirst: true)
            let legacyJob = legacy.jobs[0]
            f.start(); try f.discover()
            try await self.eventually("Legacy paused queue reconciles") { try f.ledger(a.receiverID).jobs.count == 2 }
            let migrated = try f.ledger(a.receiverID), pairing = try f.pairing(a.receiverID)
            try self.check(migrated.scope == legacy.scope, "Migration must preserve pairing, grant and source installation identity")
            try self.check(migrated.jobs.first { $0.id == legacyJob.id } == legacyJob, "Migration must preserve delivered job and receipt")
            try self.check(pairing.credentials.token == a.token, "Migration must preserve the exact credential")
            try self.check(try !f.worker(a.receiverID).isEnabled, "Legacy saved pause must survive migration")
            try self.check(try f.worker(a.receiverID).deliveredCount == 1 && f.worker(a.receiverID).queuedCount == 1,
                           "Existing receipt and newly authorized backlog must remain distinguishable")
            try self.check(f.factory.all.flatMap(\.uploads).isEmpty, "Migration must not start sending a paused grant")
            try self.check(f.storage.values["active-pairing"] == nil && f.storage.values["receiver-pairings-v1"] != nil,
                           "Legacy credential must move only after durable collection creation")
            f.store = nil; f.factory = ControlledFactory(); f.start(); try f.discover(); try await self.settle()
            try self.check(try !f.worker(a.receiverID).isEnabled && f.worker(a.receiverID).deliveredCount == 1, "Restart must preserve migrated pause and receipt")
            try self.check(f.factory.all.flatMap(\.uploads).isEmpty, "Restart must not enable paused legacy grant")
        }
        await run("legacy_enabled_pairing_remains_enabled") { f in
            let recording = try f.addRecording(0), a = self.payload("legacy-enabled")
            let before = try f.legacy(a, recordings: [recording], paused: false, deliveredFirst: false)
            f.start(); try f.discover()
            let (client, upload) = try await self.uploaded(a.receiverID, in: f)
            try self.check(try f.worker(a.receiverID).isEnabled, "Migration must preserve an explicitly enabled legacy grant")
            try self.check(client.credentials.scope == before.scope && upload.id == before.jobs[0].id, "Legacy queue identity must survive enabled migration")
            client.acknowledge(upload, recordingID: recording.id)
            try await self.eventually("Migrated grant accepts receipt") { try f.worker(a.receiverID).deliveredCount == 1 }
        }
        await run("failed_credential_migration_keeps_legacy_bytes") { f in
            let recording = try f.addRecording(0), a = self.payload("legacy-write-failure")
            _ = try f.legacy(a, recordings: [recording], paused: true, deliveredFirst: false)
            let original = f.storage.values["active-pairing"]
            f.storage.failWrites.insert("receiver-pairings-v1")
            var rejected = false
            do { _ = try f.vault.loadAll() } catch { rejected = true }
            try self.check(rejected, "Failed collection commit must not report migration success")
            try self.check(f.storage.values["active-pairing"] == original, "Failed migration must retain exact old credential bytes")
            try self.check(f.storage.values["receiver-pairings-v1"] == nil && f.storage.removedAccounts.isEmpty,
                           "Failed migration must not remove legacy before the new collection commits")
            f.storage.failWrites = []
            let restored = try f.vault.loadAll()
            try self.check(restored.count == 1 && restored[0].credentials.token == a.token, "Retry must recover original pairing")
            try self.check(restored[0].enabled == nil, "Credential migration must defer legacy pause to existing settings")
        }
        await run("empty_collection_prevents_legacy_resurrection") { f in
            let recording = try f.addRecording(0), a = self.payload("legacy-tombstone")
            _ = try f.legacy(a, recordings: [recording], paused: true, deliveredFirst: false)
            f.storage.failRemovals.insert("active-pairing")
            try self.check(try f.vault.loadAll().count == 1, "Collection commit must tolerate legacy cleanup failure")
            try self.check(f.storage.values["active-pairing"] != nil, "Fixture must preserve stale legacy bytes for this crash boundary")
            try f.vault.saveAll([])
            try self.check(try f.vault.loadAll().isEmpty, "An empty committed collection must not resurrect stale legacy credential")
            f.start(); try f.discover(); try await self.settle()
            try self.check(f.store?.receivers.isEmpty == true && f.factory.all.isEmpty, "Restart after removing last receiver must not silently pair")
        }
        await run("restart_preserves_each_switch_receipt_and_inflight_identity") { f in
            let recording = try f.addRecording(0), a = self.payload("a"), b = self.payload("b", seed: 2)
            f.start(); try f.discover(); try self.pair(a, name: "Agent A", in: f); try self.pair(b, name: "Agent B", in: f)
            let (ac, au) = try await self.uploaded(a.receiverID, in: f)
            let (_, bu) = try await self.uploaded(b.receiverID, in: f)
            ac.acknowledge(au, recordingID: recording.id)
            try await self.eventually("A committed before restart") { try f.worker(a.receiverID).deliveredCount == 1 }
            try f.worker(a.receiverID).setEnabled(false)
            let aScope = try f.pairing(a.receiverID).credentials.scope, bScope = try f.pairing(b.receiverID).credentials.scope
            f.store = nil; f.factory = ControlledFactory(); f.start(); try f.discover()
            let (restoredB, resumed) = try await self.retryAfterBackoff(b.receiverID, in: f)
            try self.check(try f.pairing(a.receiverID).credentials.scope == aScope && f.pairing(b.receiverID).credentials.scope == bScope,
                           "Restart must retain both grants")
            try self.check(try !f.worker(a.receiverID).isEnabled && f.worker(a.receiverID).deliveredCount == 1,
                           "A must retain its own paused state and receipt")
            let restoredReceipt = try f.ledger(a.receiverID).jobs.first { $0.manifest.id == recording.id }?.receipt
            try self.check(try f.worker(a.receiverID).deliveredSegmentIDs == [recording.id]
                           && f.worker(a.receiverID).lastReceiptAt == restoredReceipt?.storedAt,
                           "Restart must restore dashboard progress from persisted receipts")
            try self.check(f.factory.clients(for: a.receiverID).flatMap(\.uploads).isEmpty, "Restart must not resend A's delivered recording")
            try self.check(resumed.id == bu.id && resumed.sha256 == bu.sha256 && resumed.archiveURL == bu.archiveURL,
                           "B recovery must reuse its original delivery ID and archive")
            try self.check(try f.worker(b.receiverID).lastTransferFailure == .unknown
                && f.worker(b.receiverID).lastTransferDeliveryID == bu.id
                && f.worker(b.receiverID).lastTransferAt != nil && f.worker(b.receiverID).connectionWarning,
                "A vanished native task records interrupted delivery failure even while its same-ID retry is active")
            let beforeLateError = try f.ledger(b.receiverID)
            restoredB.emit(.init(scope: restoredB.credentials.scope, deliveryID: resumed.id, receipt: nil,
                statusCode: 403, message: "late prior-attempt failure", requiresRepair: true, attemptCount: bu.attemptCount))
            try await self.settle()
            try self.check(try f.ledger(b.receiverID) == beforeLateError && restoredB.activeIDs.contains(resumed.id),
                           "A prior attempt's late failure must not block or cancel the active retry with the same delivery ID")
            let staleWrongReceipt = AutomaticDeliveryReceipt(receiverID: a.receiverID, deliveryID: resumed.id,
                archiveSHA256: resumed.sha256, recordingIDs: [recording.id], storedAt: Date())
            restoredB.emit(.init(scope: restoredB.credentials.scope, deliveryID: resumed.id, receipt: staleWrongReceipt,
                statusCode: 200, message: nil, requiresRepair: false, attemptCount: bu.attemptCount))
            try await self.settle()
            try self.check(try f.ledger(b.receiverID) == beforeLateError && restoredB.activeIDs.contains(resumed.id),
                           "An invalid older receipt must not block or mutate the currently uploading attempt")
            restoredB.acknowledge(resumed, recordingID: recording.id)
            try await self.eventually("Recovered B commits") { try f.worker(b.receiverID).deliveredCount == 1 }
        }
        await run("wrong_receiver_receipt_blocks_only_its_origin_queue") { f in
            let recording = try f.addRecording(0), a = self.payload("a"), b = self.payload("b", seed: 2)
            f.start(); try f.discover(); try self.pair(a, name: "Agent A", in: f); try self.pair(b, name: "Agent B", in: f)
            let (ac, au) = try await self.uploaded(a.receiverID, in: f)
            let (bc, bu) = try await self.uploaded(b.receiverID, in: f)
            let wrong = AutomaticDeliveryReceipt(receiverID: b.receiverID, deliveryID: au.id,
                archiveSHA256: au.sha256, recordingIDs: [recording.id], storedAt: Date())
            ac.emit(.init(scope: ac.credentials.scope, deliveryID: au.id, receipt: wrong, statusCode: 200, message: nil, requiresRepair: false, attemptCount: au.attemptCount))
            try await self.eventually("Wrong receiver receipt rejected") { try f.worker(a.receiverID).blockedCount == 1 }
            try self.check(try f.worker(a.receiverID).deliveredCount == 0 && f.worker(b.receiverID).blockedCount == 0,
                           "An invalid A receipt must not count as delivery or block B")
            try self.check(try f.worker(a.receiverID).deliveredSegmentIDs.isEmpty
                           && f.worker(a.receiverID).lastReceiptAt == nil,
                           "A rejected receipt must never appear as successful dashboard progress")
            bc.acknowledge(bu, recordingID: recording.id)
            try await self.eventually("B still succeeds") { try f.worker(b.receiverID).deliveredCount == 1 }
        }
        await run("restart_preserves_live_background_b_and_cancels_paused_a") { f in
            let recording = try f.addRecording(0), a = self.payload("a"), b = self.payload("b", seed: 2)
            f.start(); try f.discover(); try self.pair(a, name: "Agent A", in: f); try self.pair(b, name: "Agent B", in: f)
            let (ac, au) = try await self.uploaded(a.receiverID, in: f)
            let (bc, bu) = try await self.uploaded(b.receiverID, in: f)
            try f.worker(a.receiverID).setEnabled(false)
            // Simulate URLSession tasks that outlive process termination, including
            // one whose previous pause cancellation was not delivered before exit.
            let active: [UUID: Set<UUID>] = [ac.credentials.scope.grantEpoch: [au.id], bc.credentials.scope.grantEpoch: [bu.id]]
            f.store = nil; f.factory = ControlledFactory(restoredActiveIDs: active); f.start(); try f.discover()
            try await self.eventually("Paused receiver cancels its surviving background task") {
                f.factory.clients(for: a.receiverID).last?.cancellationCount ?? 0 > 0
            }
            try await self.settle()
            guard let restoredA = f.factory.clients(for: a.receiverID).last,
                  let restoredB = f.factory.clients(for: b.receiverID).last else { throw ProbeFailure.failed("Restored clients missing") }
            try self.check(restoredA.activeIDs.isEmpty && restoredA.uploads.isEmpty,
                           "Paused A must cancel its surviving task and create no replacement")
            try self.check(restoredB.activeIDs == [bu.id] && restoredB.uploads.isEmpty && restoredB.cancellationCount == 0,
                           "B's surviving task must remain active without cancellation or duplicate upload")
            let bJob = try f.ledger(b.receiverID).jobs[0]
            try self.check(bJob.id == bu.id && bJob.state == .uploading && bJob.attemptCount == 1,
                           "A surviving B transfer must not enter retry or receive a new identity")
            restoredB.acknowledge(bu, recordingID: recording.id)
            try await self.eventually("Surviving B transfer completes through restored client") { try f.worker(b.receiverID).deliveredCount == 1 }
            try self.check(try !f.worker(a.receiverID).isEnabled && f.worker(a.receiverID).deliveredCount == 0,
                           "B completion must leave paused A untouched")
        }
        await run("failed_removal_does_not_erase_other_receivers") { f in
            _ = try f.addRecording(0); let a = self.payload("a"), b = self.payload("b", seed: 2)
            f.start(); try f.discover(); try self.pair(a, name: "Agent A", in: f); try self.pair(b, name: "Agent B", in: f)
            _ = try await self.uploaded(a.receiverID, in: f); let (bc, bu) = try await self.uploaded(b.receiverID, in: f)
            let before = f.storage.values["receiver-pairings-v1"]
            f.storage.failWrites.insert("receiver-pairings-v1")
            try self.check(f.store?.removeReceiver(a.receiverID) == false, "Failed credential commit must not claim receiver removal")
            try self.check(f.store?.receivers.count == 2 && f.storage.values["receiver-pairings-v1"] == before,
                           "Failed removal must preserve the stored receiver collection")
            try self.check(try f.worker(b.receiverID).isEnabled && bc.activeIDs.contains(bu.id), "A removal failure must not pause B")
            f.storage.failWrites = []
            try self.check(f.store?.removeReceiver(a.receiverID) == true, "Removal should succeed once storage recovers")
            try self.check(try f.vault.loadAll().map { $0.credentials.scope.receiverID } == [b.receiverID], "Retry must remove only A")
        }
        await run("paused_setting_survives_one_store_write_failure") { f in
            _ = try f.addRecording(0); let a = self.payload("a"), b = self.payload("b", seed: 2)
            f.start(); try f.discover(); try self.pair(a, name: "Agent A", in: f); try self.pair(b, name: "Agent B", in: f)
            _ = try await self.uploaded(a.receiverID, in: f); _ = try await self.uploaded(b.receiverID, in: f)
            f.storage.failWrites.insert("receiver-pairings-v1")
            try f.worker(a.receiverID).setEnabled(false)
            try self.check(try !f.worker(a.receiverID).isEnabled, "A must stop immediately when pause credential write fails")
            try self.check(try f.worker(b.receiverID).isEnabled, "A pause persistence error must not stop B")
            f.storage.failWrites = []
            f.store = nil; f.factory = ControlledFactory(); f.start(); try f.discover(); try await self.settle()
            try self.check(try !f.worker(a.receiverID).isEnabled, "Durable settings pause must override stale enabled Keychain state on restart")
            try self.check(f.factory.clients(for: a.receiverID).flatMap(\.uploads).isEmpty, "Failed Keychain update must not cause unrequested sending after restart")
            try self.check(try f.worker(b.receiverID).isEnabled, "B state must survive A's failed Keychain update")
        }
        await run("receiver_names_fallback_without_accepting_unsafe_names") { f in
            let a = self.payload("fallback"), b = self.payload("named", seed: 2)
            f.start(); try f.discover()
            try self.pair(a, name: " \n\t ", in: f)
            try self.check(try f.worker(a.receiverID).displayName == "fallback.invalid:9443", "Blank name must use endpoint host and explicit port")
            try self.pair(b, name: "  Research Agent  ", in: f)
            try self.check(try f.worker(b.receiverID).displayName == "Research Agent", "User name must be trimmed and preserved")
            let bytes = f.storage.values["receiver-pairings-v1"]
            try self.check(f.store?.pair(self.payload("too-long"), name: String(repeating: "界", count: 100)) == false,
                           "Names exceeding the UTF-8 limit must be rejected")
            try self.check(f.store?.pair(self.payload("control"), name: "Agent\u{0000}hidden") == false,
                           "Embedded control characters must be rejected")
            try self.check(f.storage.values["receiver-pairings-v1"] == bytes && f.store?.receivers.count == 2,
                           "Invalid receiver names must not change existing pairings")
        }
        await run("invalid_collection_does_not_fall_back_to_stale_legacy") { f in
            let recording = try f.addRecording(0), a = self.payload("legacy-corruption")
            _ = try f.legacy(a, recordings: [recording], paused: true, deliveredFirst: false)
            let legacy = f.storage.values["active-pairing"]
            f.storage.values["receiver-pairings-v1"] = Data("not valid JSON".utf8)
            var rejected = false
            do { _ = try f.vault.loadAll() } catch { rejected = true }
            try self.check(rejected, "A corrupt authoritative collection must fail closed instead of reviving legacy")
            try self.check(f.storage.values["active-pairing"] == legacy, "Failed collection validation must preserve legacy bytes for recovery")
            f.start(); try f.discover(); try await self.settle()
            try self.check(f.store?.receivers.isEmpty == true && f.factory.all.isEmpty, "Corrupt credentials must not start any transfer")
            try self.check(f.store?.error != nil, "Corrupt collection must expose a recoverable error")
        }
        await run("background_completion_persists_receipt_and_registers_next_without_scene") { f in
            let first = try f.addRecording(0), second = try f.addRecording(1), a = self.payload("background-chain")
            f.start(); try f.discover(); try self.pair(a, name: "Background", in: f)
            let (client, upload) = try await self.uploaded(a.receiverID, in: f)
            let firstJob = try f.ledger(a.receiverID).job(for: upload.id)!
            client.acknowledge(upload, recordingID: firstJob.manifest.id)
            client.finishEvents()
            try await self.eventually("UIKit completion waits for next registration") {
                AutomaticDeliveryBackgroundEvents.shared.completions.contains(client.identifier)
            }
            try self.check(try f.ledger(a.receiverID).job(for: upload.id)?.state == .delivered,
                           "Background completion must follow durable receipt persistence")
            try self.check(client.uploads.count == 2 && client.activeIDs.count == 1,
                           "The next upload must be registered without a foreground resume")
            try self.check(Set(try f.ledger(a.receiverID).jobs.map { $0.manifest.id }) == [first.id, second.id],
                           "Background chaining must preserve exact recording membership")
        }
        await run("stalled_upload_is_cancelled_without_blocking_queued_files_or_losing_archive") { f in
            _ = try f.addRecording(0); _ = try f.addRecording(1)
            let a = self.payload("stalled-background"), clock = SyntheticTransferClock()
            let worker = try f.isolatedWorker(a, transferCheckDate: { clock.now() }, beginExecution: { _ in nil })
            defer { worker.retire() }
            worker.discover(manifests: try f.repository.manifests(), receivedSegmentIDs: try f.repository.receivedSegmentIDs())
            let (client, upload) = try await self.uploaded(a.receiverID, in: f)
            clock.advance(AutomaticDeliveryTransferLiveness.startTimeout + 1)
            worker.resume()
            await worker.waitForPreparation()
            try self.check(client.cancelledDeliveryIDs == [upload.id], "Only the stalled upload must be cancelled")
            try self.check(try f.ledger(a.receiverID).job(for: upload.id)?.state == .uploading,
                           "Cancellation alone is not a receipt or a second persisted failure")
            try self.check(client.uploads.count == 1 && FileManager.default.fileExists(atPath: upload.archiveURL.path),
                           "The original ZIP must remain while the cancellation callback is pending")
            client.emit(.init(scope: client.credentials.scope, deliveryID: upload.id, receipt: nil,
                              statusCode: nil, message: "synthetic stalled cancellation", requiresRepair: false))
            try await self.eventually("Queued recording continues while the stalled delivery backs off") { client.uploads.count == 2 }
            let retry = try f.ledger(a.receiverID).job(for: upload.id)!
            try self.check(retry.state == .retryWaiting && retry.attemptCount == 1 && retry.nextAttemptAt != nil,
                           "Stalled task must retain its original attempt and enter ordinary backoff")
            try self.check(FileManager.default.fileExists(atPath: upload.archiveURL.path), "Retry must retain the exact prepared ZIP")
            let before = try f.ledger(a.receiverID)
            client.emit(.init(scope: client.credentials.scope, deliveryID: upload.id, receipt: nil,
                              statusCode: nil, message: "duplicate cancellation", requiresRepair: false))
            try await self.settle()
            try self.check(try f.ledger(a.receiverID) == before, "A duplicate late failure cannot consume another retry attempt")
            client.acknowledge(upload, recordingID: retry.manifest.id)
            try await self.eventually("A matching late durable receipt still resolves the original delivery") { worker.deliveredCount == 1 }
            try self.check(try f.ledger(a.receiverID).job(for: upload.id)?.state == .delivered,
                           "Late matching receipt remains authoritative after stall recovery")
        }
        await run("reconnection_between_snapshot_and_cancel_keeps_progressing_upload") { f in
            _ = try f.addRecording(0)
            let a = self.payload("reconnecting-background"), clock = SyntheticTransferClock()
            let worker = try f.isolatedWorker(a, transferCheckDate: { clock.now() }, beginExecution: { _ in nil })
            defer { worker.retire() }
            worker.discover(manifests: try f.repository.manifests(), receivedSegmentIDs: try f.repository.receivedSegmentIDs())
            let (client, upload) = try await self.uploaded(a.receiverID, in: f)
            client.progressBeforeCancellation(upload.id)
            clock.advance(AutomaticDeliveryTransferLiveness.startTimeout + 1)
            worker.resume(); await worker.waitForPreparation()
            try self.check(client.cancelledDeliveryIDs.isEmpty && client.activeIDs == [upload.id],
                           "Progress after the snapshot must be rechecked before cancellation")
            try self.check(try f.ledger(a.receiverID).job(for: upload.id)?.attemptCount == 1,
                           "A recovering connection must retain its current upload attempt")
        }
        await run("last_upload_keeps_progress_check_scheduled_without_queued_tail") { f in
            _ = try f.addRecording(0); let a = self.payload("last-background-upload")
            f.start(); try f.discover(); try self.pair(a, name: "Background", in: f)
            let (client, _) = try await self.uploaded(a.receiverID, in: f)
            await f.store?.waitForPreparation()
            try self.check(!f.requestedRetryDates.isEmpty, "An uploading-only queue still needs a liveness wake")
            let now = Date()
            try self.check(f.requestedRetryDates.contains { (20...40).contains($0.timeIntervalSince(now)) },
                           "An active upload must be observed at a bounded cadence, not every two seconds")
            try self.check(client.cancelledDeliveryIDs.isEmpty, "A newly registered upload must remain active")
        }
        await run("background_discovery_registers_upload_without_ui_reload") { f in
            let a = self.payload("background-discovery")
            f.start(); try f.discover(); try self.pair(a, name: "Background", in: f)
            let recording = try f.addRecording(0)
            let handedOff = await f.store?.prepareBackgroundDelivery()
            try self.check(handedOff == true, "Local preparation completes without waiting for network receipt")
            let (_, upload) = try await self.uploaded(a.receiverID, in: f)
            try self.check(try f.ledger(a.receiverID).job(for: upload.id)?.manifest.id == recording.id,
                           "A background launch must discover the newly received recording itself")
            try self.check(f.store?.hasPendingDelivery == true, "In-flight upload remains pending until a receipt")
        }
        await run("failed_upload_requests_system_retry_without_timer") { f in
            _ = try f.addRecording(0); let a = self.payload("background-retry")
            f.start(); try f.discover(); try self.pair(a, name: "Background", in: f)
            let (client, upload) = try await self.uploaded(a.receiverID, in: f)
            client.emit(.init(scope: client.credentials.scope, deliveryID: upload.id, receipt: nil,
                              statusCode: 503, message: "synthetic retry", requiresRepair: false))
            try await self.eventually("failed request persisted backoff and requested system wake") {
                guard let due = try f.ledger(a.receiverID).job(for: upload.id)?.nextAttemptAt else { return false }
                return f.requestedRetryDates.contains { abs($0.timeIntervalSince(due)) < 0.001 }
            }
            try self.check(client.uploads.count == 1, "Background retry scheduling must not bypass durable backoff")
            let completed = await f.store?.prepareBackgroundDelivery()
            try self.check(completed == true && client.uploads.count == 1,
                           "A wake before backoff is due must preserve the job without early upload")
        }
        await run("background_discovery_does_not_enable_paused_grant") { f in
            let a = self.payload("background-paused")
            f.start(); try f.discover(); try self.pair(a, name: "Paused", in: f)
            try f.worker(a.receiverID).setEnabled(false)
            _ = try f.addRecording(0)
            let completed = await f.store?.prepareBackgroundDelivery()
            f.store?.resume()
            try await self.settle()
            try self.check(completed == true && f.factory.clients(for: a.receiverID).flatMap(\.uploads).isEmpty,
                           "Background discovery and resume must not send from a paused grant")
            try self.check(try f.pairing(a.receiverID).enabled == false && !f.worker(a.receiverID).isEnabled,
                           "Background execution must preserve the saved pause setting")
        }
        await run("unavailable_background_execution_preserves_audio_and_requests_wake") { f in
            let recording = try f.addRecording(0), a = self.payload("refused-lease")
            let lease = SyntheticDeliveryLease(permitted: false)
            let worker = try f.isolatedWorker(a, beginExecution: { _ in lease })
            defer { worker.retire() }
            worker.discover(manifests: try f.repository.manifests(), receivedSegmentIDs: try f.repository.receivedSegmentIDs())
            await worker.waitForPreparation()
            try await self.settle()
            try self.check(f.factory.clients(for: a.receiverID).flatMap(\.uploads).isEmpty,
                           "A denied or expired execution lease must never register a new upload")
            try self.check(!worker.preparationSucceeded && worker.hasPendingDelivery,
                           "Unfinished discovery must remain pending and cannot report success")
            try self.check(!f.requestedRetryDates.isEmpty && lease.endCount > 0,
                           "Unavailable execution time must release its lease and ask the system for a later wake")
            try self.check(FileManager.default.fileExists(atPath: f.repository.audioURL(for: recording).path),
                           "Execution expiry must retain the original recording")
        }
        await run("late_cancelled_lease_cannot_replace_new_generation") { f in
            _ = try f.addRecording(0); let a = self.payload("late-lease")
            let gate = DeliveryLeaseGate()
            let worker = try f.isolatedWorker(a, beginExecution: { _ in await gate.acquire() })
            defer { worker.retire() }
            worker.discover(manifests: try f.repository.manifests(), receivedSegmentIDs: try f.repository.receivedSegmentIDs())
            try await self.eventually("first preparation waits for execution grant") { gate.count == 1 }
            worker.setEnabled(false)
            worker.setEnabled(true)
            try await self.eventually("new generation waits independently") { gate.count == 2 }
            let newLease = SyntheticDeliveryLease()
            gate.release(newLease, at: 1)
            _ = try await self.uploaded(a.receiverID, in: f)
            let oldLease = SyntheticDeliveryLease()
            gate.release(oldLease)
            try await self.settle()
            try self.check(oldLease.endCount == 1, "A late cancelled grant must be ended without installing it")
            try self.check(f.factory.clients(for: a.receiverID).flatMap(\.uploads).count == 1,
                           "An old generation cannot register a second upload after resume")
            try self.check(worker.preparationSucceeded, "The new generation's completed handoff must remain authoritative")
        }
        await run("cancelled_background_discovery_does_not_start_new_work") { f in
            let a = self.payload("cancelled-discovery")
            f.start(); try f.discover(); try self.pair(a, name: "Cancelled", in: f)
            try await self.settle()
            _ = try f.addRecording(0)
            let completed = await f.store?.prepareBackgroundDelivery(isCancelled: { true })
            try self.check(completed == false && f.factory.clients(for: a.receiverID).flatMap(\.uploads).isEmpty,
                           "An expired system task must not discover or enqueue a new recording")
            try self.check(try f.ledger(a.receiverID).jobs.isEmpty,
                           "Cancelled discovery must preserve its previous durable ledger")
        }
        await executeHealthCases()
        await executeHealthClientCases()
        await executeRestorationGateCases()
        await executeTranscriptReturnCases()
        await executeNativeTranscriptCases()
        do { try check(AutomaticDeliveryBackgroundEvents.shared.registrations == 0, "Probe must never register UIKit background sessions") }
        catch { failures.append(String(describing: error)) }
    }
}

@main
struct PhoneMultiReceiverProbe {
    @MainActor static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { print("Expected report and synthetic fixture directory paths"); exit(2) }
        let probe = Probe(fixtures: URL(fileURLWithPath: arguments[2], isDirectory: true))
        await probe.execute()
        let report: [String: Any] = ["status": probe.failures.isEmpty ? "passed" : "failed",
            "caseCount": probe.cases.count, "assertionCount": probe.assertionCount,
            "cases": probe.cases, "failures": probe.failures,
            "actualProductionCoordinator": true, "actualPerReceiverStore": true, "actualCredentialMigration": true,
            "actualArchiveBuilder": true, "realKeychainAccess": false, "realNetwork": false,
            "realRecordings": false, "realChatMessages": false]
        do {
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: URL(fileURLWithPath: arguments[1]))
            print(String(decoding: bytes, as: UTF8.self))
        } catch { print("Could not write isolated report: \(error)"); exit(2) }
        exit(probe.failures.isEmpty ? 0 : 1)
    }
}
