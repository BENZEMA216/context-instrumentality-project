import CryptoKit
import Darwin
import Foundation
import RecordingCore

/// Upload responses are only hints to re-read Google's metadata. No response in
/// this component can create a Drive verified receipt or change the user's grant.
struct GoogleDriveUploadHandoff: Error {}
struct GoogleDriveUploadRetryDeferred: Error {}

struct GoogleDriveUploadTaskInfo: Sendable {
    let id: Int
    let nonce: String?
    let url: String?
    let method: String?
    let contentRange: String?
    let isSuspended: Bool
    init(id: Int, nonce: String?, url: String?, method: String?, contentRange: String?, isSuspended: Bool = false) {
        self.id = id; self.nonce = nonce; self.url = url; self.method = method
        self.contentRange = contentRange; self.isSuspended = isSuspended
    }
}

struct GoogleDriveUploadCompletion: Sendable {
    let task: GoogleDriveUploadTaskInfo
    let responseURL: String?
    let status: Int?
    let transportFailed: Bool
    let diagnostic: GoogleDriveTransportDiagnostic?

    init(task: GoogleDriveUploadTaskInfo, responseURL: String?, status: Int?, transportFailed: Bool,
         diagnostic: GoogleDriveTransportDiagnostic? = nil) {
        self.task = task; self.responseURL = responseURL; self.status = status
        self.transportFailed = transportFailed; self.diagnostic = diagnostic
    }
}

@MainActor
protocol GoogleDriveUploadTransport: AnyObject {
    var identifier: String { get }
    func tasks() async -> [GoogleDriveUploadTaskInfo]
    func prepareForNewRequests(allowSessionMigration: Bool) async throws
    func create(_ request: URLRequest, file: URL, nonce: String) throws -> Int
    func resume(_ taskID: Int)
    func cancel(_ taskIDs: Set<Int>) async
    func invalidateAndCancel() async
}

extension GoogleDriveUploadTransport {
    func prepareForNewRequests(allowSessionMigration: Bool) async throws { }
}

/// A background attempt is bound to the same durable grant and immutable
/// artifact as the foreground uploader. OAuth values are not representable here.
struct GoogleDriveUploadContext: Codable, Equatable, Sendable {
    let libraryID: UUID
    let accountID: String
    let folderID: String
    let authorizedAt: Date
    let recordingScope: GoogleDriveRecordingScope
    let manifest: SegmentManifest
    let artifact: GoogleDriveArtifact

    /// Rebuilt from durable metadata after native callbacks or process recovery.
    /// A callback's task-local state is unrelated to the job that staged it.
    var uploadCorrelation: GoogleDriveUploadCorrelation {
        .init(segmentID: manifest.id, kind: artifact.kind, manifestSHA256: manifest.sha256)
    }

    init(ledger: GoogleDriveLibraryLedger, manifest: SegmentManifest, artifact: GoogleDriveArtifact) throws {
        try ledger.validate()
        guard ledger.enabled, !ledger.revokedLocally, let accountID = ledger.accountID,
              let folderID = ledger.folderID, let authorizedAt = ledger.authorizedAt,
              let recordingScope = ledger.recordingScope,
              artifact.verifiedAt == nil, artifact.fileID != nil, let uploadURL = artifact.uploadURL,
              GoogleDriveLibraryLedger.validUploadURL(uploadURL),
              ledger.jobs.contains(where: { $0.manifest == manifest && $0.artifacts.contains(artifact) })
        else { throw GoogleDriveLibraryError.notAuthorized }
        libraryID = ledger.libraryID; self.accountID = accountID; self.folderID = folderID
        self.authorizedAt = authorizedAt; self.recordingScope = recordingScope
        self.manifest = manifest; self.artifact = artifact
    }

    func isAuthorized(in ledger: GoogleDriveLibraryLedger) -> Bool {
        ledger.enabled && !ledger.revokedLocally && ledger.libraryID == libraryID
            && ledger.accountID == accountID && ledger.folderID == folderID
            && ledger.authorizedAt == authorizedAt && ledger.recordingScope == recordingScope
            && ledger.jobs.contains { job in
                job.manifest == manifest && job.artifacts.contains { current in
                    current.kind == artifact.kind && current.sha256 == artifact.sha256
                        && current.byteCount == artifact.byteCount && current.fileID == artifact.fileID
                        && current.uploadURL == artifact.uploadURL && current.verifiedAt == nil
                }
            }
    }
}

/// A bounded set of immutable bodies is durably handed to the native session.
/// Completion is uncertainty until each exact artifact has normal remote readback.
@MainActor
final class GoogleDriveBackgroundUploads {
    struct Record: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let nonce: UUID
        let context: GoogleDriveUploadContext
        let offset: Int64
        let bodyByteCount: Int64
        let bodySHA256: String
        var taskID: Int?
        var completed = false
        var cancelled = false

        var bodyName: String { nonce.uuidString.lowercased() + ".body" }
        var contentRange: String {
            "bytes \(offset)-\(context.artifact.byteCount - 1)/\(context.artifact.byteCount)"
        }
        func matches(_ task: GoogleDriveUploadTaskInfo) -> Bool {
            task.nonce == nonce.uuidString.lowercased() && (taskID == nil || taskID == task.id)
                && task.url == context.artifact.uploadURL && task.method == "PUT"
                && task.contentRange == contentRange
        }
    }

    typealias Factory = @MainActor (String, @escaping @Sendable (GoogleDriveUploadCompletion) -> Void,
                                    @escaping @Sendable (BackgroundSessionEvent) -> Void) throws -> any GoogleDriveUploadTransport
    let identifier: String
    private let directory: URL
    private let libraryID: UUID
    private let stateURL: URL
    private let legacyURL: URL
    static let maximumTasks = 8
    static let maximumRecords = 16
    static let maximumRetryEntries = 40_000
    static let maximumRoundOperations = 16
    static let maximumBodyBytes: Int64 = 64 * 1_024 * 1_024
    static let maximumSingleBodyBytes: Int64 = 130 * 1_024 * 1_024
    private struct State: Codable {
        let schemaVersion: Int
        let records: [Record]
        var retries: [ItemRetry]? = nil
        var sourceTurns: SourceTurns? = nil
    }
    /// Three opportunities for sources recorded after this exact grant, then
    /// one for its historical backlog. Commit before awaiting any provider so
    /// a cancelled lease or process reconstruction cannot reset the old debt.
    private struct SourceTurns: Codable, Equatable {
        let accountID: String
        let folderID: String
        let authorizedAt: Date
        let recordingScope: GoogleDriveRecordingScope
        var recent: Int
        init?(ledger: GoogleDriveLibraryLedger, recent: Int) {
            guard let accountID = ledger.accountID, let folderID = ledger.folderID,
                  let authorizedAt = ledger.authorizedAt, let scope = ledger.recordingScope else { return nil }
            self.accountID = accountID; self.folderID = folderID
            self.authorizedAt = authorizedAt; recordingScope = scope; self.recent = recent
        }
        func matches(_ ledger: GoogleDriveLibraryLedger) -> Bool {
            accountID == ledger.accountID && folderID == ledger.folderID
                && authorizedAt == ledger.authorizedAt && recordingScope == ledger.recordingScope
        }
        func validate() throws {
            guard (0...3).contains(recent), authorizedAt.timeIntervalSince1970.isFinite,
                  !accountID.isEmpty, !folderID.isEmpty else { throw GoogleDriveLibraryError.invalidState }
        }
    }
    private var sourceTurns: SourceTurns?
    struct ItemRetry: Codable, Equatable {
        let segmentID: UUID
        let artifactKey: String
        let bindingSHA256: String
        let failures: Int
        let retryAfter: Date
        let attemptNonce: UUID?
        /// Set when the artifact itself failed validation. It is not a network retry.
        var terminal: Bool? = nil
        enum FailureReason: String, Codable { case sourceChanged, artifactInvalid, sourceUnauthorized, metadataIncomplete, remoteConflict }
        // Old artifactInvalid entries did not distinguish absent fields from
        // proven conflicts. They may only recover through strict readback.
        var failureReason: FailureReason? = nil
        var legacyProbeAfter: Date? = nil
        var retryFailureKind: GoogleDriveRetryFailureKind? = nil
        var recoveryProbeAt: Date? = nil
        var lastFailureAt: Date? = nil
        var requiresMetadataReadback: Bool {
            failureReason == .metadataIncomplete || (terminal == true && (failureReason == nil || failureReason == .artifactInvalid))
        }
    }
    private struct RetryBinding: Codable {
        let libraryID: UUID
        let accountID: String
        let folderID: String
        let authorizedAt: Date
        let recordingScope: GoogleDriveRecordingScope
        let manifest: SegmentManifest
        let kind: GoogleDriveArtifact.Kind
        let sha256: String
        let byteCount: Int64
        let fileID: String?
        init?(ledger: GoogleDriveLibraryLedger, segmentID: UUID, artifactKey: String) {
            guard !ledger.revokedLocally, let accountID = ledger.accountID, let folderID = ledger.folderID,
                  let authorizedAt = ledger.authorizedAt, let scope = ledger.recordingScope,
                  let job = ledger.jobs.first(where: { $0.id == segmentID }),
                  let artifact = job.artifacts.first(where: { $0.key == artifactKey && $0.verifiedAt == nil }) else { return nil }
            libraryID = ledger.libraryID; self.accountID = accountID; self.folderID = folderID
            self.authorizedAt = authorizedAt; recordingScope = scope; manifest = job.manifest
            kind = artifact.kind; sha256 = artifact.sha256; byteCount = artifact.byteCount; fileID = artifact.fileID
        }
        init(_ context: GoogleDriveUploadContext) {
            libraryID = context.libraryID; accountID = context.accountID; folderID = context.folderID
            authorizedAt = context.authorizedAt; recordingScope = context.recordingScope; manifest = context.manifest
            kind = context.artifact.kind; sha256 = context.artifact.sha256; byteCount = context.artifact.byteCount; fileID = context.artifact.fileID
        }
        func digest() throws -> String { GoogleDriveLibraryLedger.digest(try TransportCodec.encode(self)) }
    }
    private(set) var itemRetries: [ItemRetry] = []
    private let now: @Sendable () -> Date
    private let factory: Factory
    private let changed: () -> Void
    private let finishedEvents: (BackgroundSessionEvent) -> Void
    private let diagnostic: (String, String) -> Void
    private let transportDiagnostic: (GoogleDriveTransportDiagnostic) -> Void
    private enum Event: Sendable { case completion(GoogleDriveUploadCompletion), finished(BackgroundSessionEvent), barrier(CheckedContinuation<Void, Never>) }
    private var eventTask: Task<Void, Never>?
    private var eventsContinuation: AsyncStream<Event>.Continuation?
    private var handingOff = false
    private var operationRevision: UInt64 = 0
    private var registrationRevision: UInt64 = 0
    private var transport: (any GoogleDriveUploadTransport)?
    private(set) var records: [Record] = []
    // Compatibility for callers inspecting a single completed attempt.
    var record: Record? { records.first }
    private var stagingReservations: [UUID: (bytes: Int64, key: String)] = [:]
    private(set) var isReconciling = false
    private var recoveryInFlight = false
    private var nativeTaskIDs = Set<Int>()
    private var completedNativeTasks = Set<String>()
    private var rejectedNativeTaskIDs = Set<Int>()
    private var failedClosed = false
    private(set) var metadataFailure: Error?
    private var metadataFailureRevision: UInt64 = 0
    enum MetadataOperation { case persist, recoveryRead }
    private let metadataFault: ((MetadataOperation) throws -> Void)?

    init(directory: URL, libraryID: UUID,
         changed: @escaping () -> Void, finishedEvents: @escaping (BackgroundSessionEvent) -> Void,
         diagnostic: @escaping (String, String) -> Void = { _, _ in },
         transportDiagnostic: @escaping (GoogleDriveTransportDiagnostic) -> Void = { _ in },
         now: @escaping @Sendable () -> Date = { Date() },
         metadataFault: ((MetadataOperation) throws -> Void)? = nil,
         factory: @escaping Factory = { identifier, complete, finished in
             try GoogleDriveUploadSession(identifier: identifier, complete: complete, finished: finished)
         }) throws {
        self.directory = directory; self.libraryID = libraryID
        stateURL = directory.appendingPathComponent("pipeline.json")
        legacyURL = directory.appendingPathComponent("attempt.json")
        identifier = (Bundle.main.bundleIdentifier ?? "dev.benzema.WristRecord")
            + ".google-drive-upload." + libraryID.uuidString.lowercased()
        self.factory = factory; self.changed = changed; self.finishedEvents = finishedEvents; self.now = now
        self.diagnostic = diagnostic
        self.transportDiagnostic = transportDiagnostic
        self.metadataFault = metadataFault
        try Self.prepare(directory)
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let state = try TransportCodec.decode(State.self, from: Self.read(stateURL, maximum: 16 * 1_024 * 1_024))
            guard state.schemaVersion == 2 else { throw GoogleDriveLibraryError.invalidState }
            records = state.records; itemRetries = state.retries ?? []; sourceTurns = state.sourceTurns
            try sourceTurns?.validate()
        }
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            let legacy = try TransportCodec.decode(Record.self, from: Self.read(legacyURL, maximum: 64 * 1_024))
            if records.isEmpty { records = [legacy] }
            else {
                guard let migrated = records.first(where: { $0.nonce == legacy.nonce }),
                      try TransportCodec.encode(migrated) == TransportCodec.encode(legacy) else {
                    throw GoogleDriveLibraryError.invalidState
                }
            }
            try validateRecords(records, libraryID: libraryID)
            try persist(records) // durable new authority before retiring the legacy pointer
            try Self.removePrivateFile(legacyURL); try Self.sync(directory)
        }
        try validateRecords(records, libraryID: libraryID)
        try validateRetries(itemRetries)
        isReconciling = !records.isEmpty
        try Self.cleanOrphans(directory, keeping: Set(records.map(\.bodyName)))
    }

    private func validateRecords(_ values: [Record], libraryID: UUID) throws {
        guard values.count <= Self.maximumRecords, values.filter({ !$0.completed }).count <= Self.maximumTasks, Set(values.map(\.nonce)).count == values.count,
              Set(values.map { key($0.context) }).count == values.count,
              Set(values.compactMap(\.taskID)).count == values.compactMap(\.taskID).count else {
            throw GoogleDriveLibraryError.invalidState
        }
        var bytes: Int64 = 0
        for saved in values {
            guard saved.schemaVersion == 1, saved.context.libraryID == libraryID,
                  saved.offset >= 0, saved.offset < saved.context.artifact.byteCount,
                  saved.context.artifact.byteCount <= Self.maximumSingleBodyBytes,
                  saved.bodyByteCount == saved.context.artifact.byteCount - saved.offset,
                  saved.bodyByteCount > 0, saved.bodySHA256.utf8.count == 64,
                  saved.bodySHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  saved.context.artifact.fileID.map(GoogleDriveLibraryLedger.validFileID) == true,
                  saved.context.artifact.uploadURL.map(GoogleDriveLibraryLedger.validUploadURL) == true,
                  saved.taskID.map({ $0 > 0 }) ?? true else { throw GoogleDriveLibraryError.invalidState }
            bytes += saved.bodyByteCount
        }
        guard bytes <= Self.maximumBodyBytes || (values.count == 1 && bytes <= Self.maximumSingleBodyBytes) else {
            throw GoogleDriveLibraryError.invalidState
        }
    }

    private func validateRetries(_ retries: [ItemRetry]) throws {
        guard retries.count <= Self.maximumRetryEntries,
              Set(retries.map { $0.segmentID.uuidString.lowercased() + "/" + $0.artifactKey }).count == retries.count,
              retries.allSatisfy({ $0.artifactKey.utf8.count <= 128 && !$0.artifactKey.isEmpty && (1...16).contains($0.failures)
                && ($0.terminal == nil || $0.terminal == true)
                && ($0.failureReason == nil || $0.terminal == true || $0.failureReason == .metadataIncomplete)
                && ($0.legacyProbeAfter == nil || $0.requiresMetadataReadback)
                && ($0.legacyProbeAfter?.timeIntervalSince1970.isFinite ?? true)
                && ($0.recoveryProbeAt?.timeIntervalSince1970.isFinite ?? true)
                && $0.retryAfter.timeIntervalSince1970.isFinite && ($0.lastFailureAt?.timeIntervalSince1970.isFinite ?? true) && $0.bindingSHA256.utf8.count == 64
                && $0.bindingSHA256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) else {
            throw GoogleDriveLibraryError.invalidState
        }
    }

    deinit { eventTask?.cancel() }

    var hasActiveUpload: Bool { handingOff || isReconciling || !nativeTaskIDs.isEmpty || records.contains { !$0.completed } }
    var hasUnverifiedCompletedAttempt: Bool { records.contains { $0.completed && !$0.cancelled } }
    var needsRecovery: Bool { !records.isEmpty }
    var isUnavailable: Bool { failedClosed }
    var canRecoverMetadata: Bool { (metadataFailure as? GoogleDriveMetadataIOError)?.isTemporary == true }
    var nativeActiveCount: Int { records.filter { !$0.completed && !$0.cancelled }.count }
    var pendingReadbackCount: Int { records.filter { $0.completed && !$0.cancelled }.count }
    var stagedBodyBytes: Int64 { records.reduce(0) { $0 + $1.bodyByteCount } + stagingReservations.values.reduce(0) { $0 + $1.bytes } }
    var readyReadbackCount: Int { records.filter { $0.completed && !$0.cancelled && !isDeferred($0.context.manifest.id, $0.context.artifact.key) }.count }
    var canProcess: Bool { !handingOff && !isReconciling && !failedClosed && (readyReadbackCount > 0 || canReserve(bytes: 1)) }
    func earliestRetryAt(in ledger: GoogleDriveLibraryLedger) -> Date? {
        itemRetries.filter { retryMatches($0, in: ledger) }.compactMap { retry in
            if retry.failureReason == .metadataIncomplete { return max(retry.retryAfter, retry.legacyProbeAfter ?? retry.retryAfter) }
            if retry.requiresMetadataReadback { return retry.legacyProbeAfter ?? now() }
            if retry.terminal != true { return retry.retryAfter }
            return nil
        }.min()
    }
    /// A bounded scalar projection; item identity and resumable capabilities
    /// never enter connection presentation or its diagnostics.
    func retryPresentation(in ledger: GoogleDriveLibraryLedger) -> (networkFailure: Bool, lastFailureAt: Date?) {
        let matching = itemRetries.filter { retryMatches($0, in: ledger) }
        return (matching.contains { $0.terminal != true && !$0.requiresMetadataReadback && $0.retryFailureKind == .recoverableNetwork },
                matching.compactMap(\.lastFailureAt).max())
    }
    /// Call only after a finite round or before network preparation. A durable
    /// future wait is used only when no healthy item can run now; it must never
    /// turn a full set of deferred records into periodic account/folder reads.
    func nextWorkDate(in ledger: GoogleDriveLibraryLedger, progress: GoogleDriveSyncProgress,
                      fallback: Date) throws -> Date? {
        guard !hasActiveUpload else { return nil } // native completion owns the next wake
        if progress.needsDiscovery { return fallback }
        let next = try nextUpload(in: ledger, progress: progress, allowPipelineFill: true)
        if legacyQuarantineCandidate(in: ledger) != nil || next != nil {
            return fallback
        }
        return [earliestRetryAt(in: ledger), progress.issueRetryAt].compactMap { $0 }.min()
    }
    private func isDeferred(_ segmentID: UUID, _ artifactKey: String) -> Bool {
        itemRetries.contains { $0.segmentID == segmentID && $0.artifactKey == artifactKey
            && ($0.terminal == true || $0.requiresMetadataReadback || $0.retryAfter > now()) }
    }
    private func retryMatches(_ retry: ItemRetry, in ledger: GoogleDriveLibraryLedger) -> Bool {
        guard let binding = RetryBinding(ledger: ledger, segmentID: retry.segmentID, artifactKey: retry.artifactKey),
              let digest = try? binding.digest() else { return false }
        return digest == retry.bindingSHA256
    }

    private func key(_ context: GoogleDriveUploadContext) -> String {
        context.manifest.id.uuidString.lowercased() + "/" + context.artifact.key
    }
    func canReserve(bytes: Int64) -> Bool {
        guard bytes > 0, bytes <= Self.maximumSingleBodyBytes,
              records.count + stagingReservations.count < Self.maximumRecords,
              max(nativeTaskIDs.count, records.filter({ !$0.completed }).count) + stagingReservations.count < Self.maximumTasks,
              rejectedNativeTaskIDs.isEmpty else { return false }
        let total = stagedBodyBytes
        return bytes <= Self.maximumBodyBytes - min(Self.maximumBodyBytes, total)
            || (records.isEmpty && stagingReservations.isEmpty && bytes <= Self.maximumSingleBodyBytes)
    }
    func hasRegisteredRecord(for segmentID: UUID, artifactKey: String, in ledger: GoogleDriveLibraryLedger) -> Bool {
        records.contains { $0.taskID != nil && !$0.cancelled && $0.context.isAuthorized(in: ledger)
            && $0.context.manifest.id == segmentID && $0.context.artifact.key == artifactKey }
    }
    func completedRecord(for segmentID: UUID, artifactKey: String) -> Record? {
        records.first { $0.completed && !$0.cancelled && $0.context.manifest.id == segmentID && $0.context.artifact.key == artifactKey }
    }

    private func session() throws -> any GoogleDriveUploadTransport {
        if let transport { return transport }
        let (events, continuation) = AsyncStream<Event>.makeStream()
        // URLSession's serial delegate queue yields completion before drained.
        // One consumer preserves that order across the hop to the main actor.
        let value = try factory(identifier, { result in continuation.yield(.completion(result)) },
                                { identifier in continuation.yield(.finished(identifier)) })
        guard value.identifier == identifier else { continuation.finish(); throw GoogleDriveLibraryError.invalidState }
        transport = value; eventsContinuation = continuation
        eventTask = Task { @MainActor [weak self] in
            // This consumer outlives the job that first opened the session.
            // Each native completion restores its own durable identity below.
            await GoogleDriveUploadTrace.$current.withValue(nil) {
                for await event in events {
                    guard let self else { break }
                    switch event {
                    case .completion(let result): self.receive(result)
                    case .finished(let identifier):
                        self.diagnostic("events_drained", self.metadata())
                        self.finishedEvents(identifier)
                    case .barrier(let continuation): continuation.resume()
                    }
                }
            }
        }
        return value
    }

    /// Exact session restoration only attaches callbacks. A fresh live ledger
    /// fence is checked separately before any subsequent request is registered.
    func recognizes(_ identifier: String) -> Bool { self.identifier == identifier }

    private func markUnavailable(_ error: Error) {
        failedClosed = true; metadataFailure = error; metadataFailureRevision &+= 1
    }

    /// Re-read the exact durable state; never recreate a missing nonempty
    /// pipeline or accept a new grant/body/session after a storage interruption.
    func validateRecoveryMetadata(in ledger: GoogleDriveLibraryLedger) throws {
        try GoogleDriveMetadataIO.validateDirectory(directory.deletingLastPathComponent())
        try GoogleDriveMetadataIO.validateDirectory(directory)
        try metadataFault?(.recoveryRead)
        var info = stat()
        if Darwin.lstat(legacyURL.path, &info) == 0 { throw GoogleDriveLibraryError.invalidState }
        guard errno == ENOENT else { throw GoogleDriveMetadataIO.syscallFailure() }
        let diskRecords: [Record], diskRetries: [ItemRetry], diskSourceTurns: SourceTurns?
        if Darwin.lstat(stateURL.path, &info) == 0 {
            let state = try TransportCodec.decode(State.self, from: GoogleDriveMetadataIO.read(stateURL, maximum: 16 * 1_024 * 1_024))
            guard state.schemaVersion == 2 else { throw GoogleDriveLibraryError.invalidState }
            diskRecords = state.records; diskRetries = state.retries ?? []; diskSourceTurns = state.sourceTurns
        } else {
            guard errno == ENOENT else { throw GoogleDriveMetadataIO.syscallFailure() }
            guard records.isEmpty, itemRetries.isEmpty, sourceTurns == nil else { throw GoogleDriveLibraryError.invalidState }
            diskRecords = []; diskRetries = []; diskSourceTurns = nil
        }
        try validateRecords(diskRecords, libraryID: libraryID); try validateRetries(diskRetries); try diskSourceTurns?.validate()
        guard diskRecords == records, diskRetries == itemRetries, diskSourceTurns == sourceTurns,
              diskRecords.allSatisfy({ !$0.cancelled && $0.context.isAuthorized(in: ledger) }),
              diskRetries.allSatisfy({ retryMatches($0, in: ledger) }) else { throw GoogleDriveLibraryError.invalidState }
    }

    /// One native enumeration in the *existing* session, with no create,
    /// resume, cancellation, body reads or receipt credit. An unknown task is a
    /// hard conflict, not permission to cancel a task while repairing metadata.
    func recoverMetadata(in ledger: GoogleDriveLibraryLedger, check: @MainActor () throws -> Void) async throws {
        guard !handingOff, !recoveryInFlight, stagingReservations.isEmpty else { throw CancellationError() }
        if failedClosed && !canRecoverMetadata { throw GoogleDriveLibraryError.invalidState }
        let revision = operationRevision, registration = registrationRevision, failureRevision = metadataFailureRevision
        recoveryInFlight = true
        defer { recoveryInFlight = false }
        try check(); try validateRecoveryMetadata(in: ledger)
        let before = records
        let native = try session()
        let tasks = await native.tasks().filter { !completedNativeTasks.contains(Self.completionKey($0)) }
        try check()
        guard operationRevision == revision, registrationRevision == registration, !handingOff,
              metadataFailureRevision == failureRevision, records == before else { throw CancellationError() }
        try validateRecoveryMetadata(in: ledger)
        var accepted = Set<UUID>()
        for task in tasks {
            guard let saved = records.first(where: { $0.matches(task) }),
                  saved.context.isAuthorized(in: ledger), !saved.cancelled, !task.isSuspended,
                  accepted.insert(saved.nonce).inserted else { throw GoogleDriveLibraryError.invalidState }
        }
        var candidate = records
        for index in candidate.indices {
            if let task = tasks.first(where: { candidate[index].matches($0) }) {
                guard !candidate[index].completed else { throw GoogleDriveLibraryError.invalidState }
                candidate[index].taskID = task.id
            } else { candidate[index].completed = true }
        }
        try check()
        try persist(candidate)
        records = candidate; nativeTaskIDs = Set(tasks.map(\.id)); rejectedNativeTaskIDs.removeAll()
        // The enclosing Library recovery still rechecks ledger/preflight after
        // this await before clearing its own unavailable flag.
        failedClosed = false; metadataFailure = nil; isReconciling = false
    }

    func recover(in ledger: GoogleDriveLibraryLedger, check: () throws -> Void = {}) async {
        guard !failedClosed, !handingOff, !recoveryInFlight else { return }
        let revision = operationRevision
        isReconciling = true; recoveryInFlight = true
        var finished = false
        defer {
            recoveryInFlight = false
            if operationRevision == revision {
                isReconciling = !finished
                diagnostic("recover", metadata() + " native_count=\(nativeTaskIDs.count) failed_closed=\(failedClosed) finished=\(finished)")
                if finished { changed() }
            }
        }
        do {
            try check()
            let session = try session()
            // A completion can arrive while getAllTasks is in flight. Do not
            // resurrect that task from an older enumeration result.
            let tasks = await session.tasks().filter { !completedNativeTasks.contains(Self.completionKey($0)) }
            try check()
            guard operationRevision == revision, !handingOff else { return }
            nativeTaskIDs = Set(tasks.map(\.id))
            var invalid = Set<Int>(), accepted = Set<UUID>()
            for task in tasks {
                if let saved = records.first(where: { $0.matches(task) }),
                   saved.context.isAuthorized(in: ledger), !saved.cancelled, !task.isSuspended,
                   accepted.insert(saved.nonce).inserted { }
                else { invalid.insert(task.id) }
            }
            rejectedNativeTaskIDs = invalid
            if !invalid.isEmpty { await session.cancel(invalid) }
            try check()
            guard operationRevision == revision, !handingOff else { return }
            var candidate = records
            for index in candidate.indices {
                if !candidate[index].context.isAuthorized(in: ledger) { candidate[index].cancelled = true }
                if let task = tasks.first(where: { candidate[index].matches($0) && !invalid.contains($0.id) }) {
                    candidate[index].taskID = task.id
                } else {
                    // Missing/suspended tasks retain their original file/session for readback.
                    candidate[index].completed = true
                }
            }
            try persist(candidate); records = candidate
            try cleanupCancelledIfDrained(); finished = true
        } catch is CancellationError {
            // A real finite lease can expire during native enumeration. Leave
            // reconciliation required, without failing the queue or inventing
            // another wake; the next actual execution window may retry it.
        } catch { if operationRevision == revision { markUnavailable(error); finished = true } }
    }

    /// A late UIKit handler needs a new, observable native queue boundary, not
    /// an old drained event. Invalidation reports only after native task events;
    /// the stream barrier then commits every preceding event on the main actor.
    func handoffForPendingEvents() async throws {
        guard !handingOff else { throw GoogleDriveLibraryError.invalidState }
        handingOff = true; operationRevision &+= 1
        defer { handingOff = false }
        let native = try session()
        await native.invalidateAndCancel()
        await withCheckedContinuation { continuation in
            eventsContinuation?.yield(.barrier(continuation))
        }
        nativeTaskIDs.removeAll(); rejectedNativeTaskIDs.removeAll(); isReconciling = false
        if !records.isEmpty {
            var candidate = records
            for index in candidate.indices { candidate[index].completed = true }
            do { try persist(candidate); records = candidate; try cleanupCancelledIfDrained() }
            catch { markUnavailable(error) }
        }
        eventsContinuation?.finish(); eventsContinuation = nil
        eventTask?.cancel(); eventTask = nil; transport = nil
        diagnostic("handoff_invalidated", metadata())
    }

    /// Read back the exact completed native attempt before a newly discovered
    /// transcript can change normal queue priority. It remains uncertainty until
    /// the ordinary client verifies its original file/session. Invalidated grant
    /// or source bindings are cancelled locally, never forced into the queue.
    func nextUpload(in ledger: GoogleDriveLibraryLedger, progress: GoogleDriveSyncProgress, allowPipelineFill: Bool = false, preflight: GoogleDrivePreflightPin? = nil) throws -> GoogleDriveSyncProgress.UploadChoice? {
        guard !failedClosed else { throw GoogleDriveLibraryError.invalidState }
        guard !handingOff, !isReconciling else { return nil }
        for saved in records where saved.completed && (saved.cancelled || !saved.context.isAuthorized(in: ledger)) {
            var candidate = records
            if let index = candidate.firstIndex(where: { $0.nonce == saved.nonce }) { candidate[index].cancelled = true }
            try persist(candidate); records = candidate
        }
        try cleanupCancelledIfDrained()
        let completed = records.filter { $0.completed && !$0.cancelled && $0.context.isAuthorized(in: ledger)
            && !isDeferred($0.context.manifest.id, $0.context.artifact.key) }
        func readback(_ saved: Record) -> GoogleDriveSyncProgress.UploadChoice {
            let derived = ledger.jobs.first { $0.id == saved.context.manifest.id }?.artifacts.contains {
                ($0.kind == .transcriptJSON || $0.kind == .transcriptText) && $0.verifiedAt == nil
            } == true
            return .init(segmentID: saved.context.manifest.id, artifactKey: saved.context.artifact.key,
                         isPrioritySmall: saved.context.artifact.kind != .audio && derived)
        }
        // Keep at least a small real native pipeline before spending the next
        // finite window on completed-item metadata. Never fabricate a receipt.
        let blockedSources = Set(records.filter { $0.cancelled && (!$0.completed || $0.taskID.map(nativeTaskIDs.contains) == true) }.map { $0.context.manifest.id })
        let deferred = Set(itemRetries.filter { ($0.terminal == true || $0.requiresMetadataReadback || $0.retryAfter > now()) && retryMatches($0, in: ledger) }
            .map { $0.segmentID.uuidString.lowercased() + "/" + $0.artifactKey })
        let occupied = Set(records.map { key($0.context) }).union(stagingReservations.values.map(\.key)).union(deferred)
        let reservations = records.filter { !$0.cancelled }.map(readback)
        let validPreflight = try preflight?.reconciled(in: ledger)
        func isRecent(_ manifest: SegmentManifest) -> Bool {
            ledger.authorizedAt.map { manifest.startedAt > $0 } ?? false
        }
        func choice(recent: Bool) -> GoogleDriveSyncProgress.UploadChoice? {
            let completed = completed.first { isRecent($0.context.manifest) == recent }
            let jobs = ledger.jobs.filter { !blockedSources.contains($0.id) && isRecent($0.manifest) == recent }
            // A prepared pin cannot cross the source-age fairness boundary.
            // Completed native work keeps its durable readback rotation. New
            // source admission cannot reset that cancellation-safe ordering.
            let preferred = (validPreflight?.choice).flatMap { pin in jobs.contains { $0.id == pin.segmentID } ? pin : nil }
            if preferred != nil, let completed { return readback(completed) }
            let candidate: GoogleDriveSyncProgress.UploadChoice?
            if recent {
                // A prepared file/session remains durable, but its preparation
                // is not permission to delay a newer post-authorization source.
                // Keep the small-artifact/audio order within the chosen source.
                let newestFirst = jobs.sorted {
                    $0.manifest.startedAt == $1.manifest.startedAt
                        ? $0.id.uuidString < $1.id.uuidString : $0.manifest.startedAt > $1.manifest.startedAt
                }
                var next: GoogleDriveSyncProgress.UploadChoice?
                for job in newestFirst {
                    if let selected = progress.nextUpload(in: [job], excluding: occupied, preferred: preferred, reservations: reservations,
                        reservationJobs: ledger.jobs,
                        mayReserve: { canReserve(bytes: $0) }) {
                        next = selected; break
                    }
                }
                candidate = next
            } else {
                candidate = progress.nextUpload(in: jobs, excluding: occupied, preferred: preferred, reservations: reservations,
                    reservationJobs: ledger.jobs,
                    mayReserve: { canReserve(bytes: $0) })
            }
            if let completed, !allowPipelineFill || nativeActiveCount >= 2 || candidate == nil { return readback(completed) }
            return candidate ?? completed.map(readback)
        }
        let owedHistoricalTurn = sourceTurns?.matches(ledger) == true && sourceTurns?.recent == 3
        return choice(recent: !owedHistoricalTurn) ?? choice(recent: owedHistoricalTurn)
    }

    /// Persist the exact invalidation before asking native to cancel. Other
    /// sources remain independent; this source stays blocked until its real task
    /// completion is consumed, not merely until cancel() was requested.
    func cancelUnauthorized(in ledger: GoogleDriveLibraryLedger) throws {
        var candidate = records, ids = Set<Int>(), changedAny = false
        for index in candidate.indices where !candidate[index].completed && !candidate[index].cancelled {
            guard !candidate[index].context.isAuthorized(in: ledger) else { continue }
            candidate[index].cancelled = true; changedAny = true
            if let id = candidate[index].taskID { ids.insert(id) }
        }
        let retainedRetries = itemRetries.filter { retryMatches($0, in: ledger) }
        guard changedAny || retainedRetries.count != itemRetries.count else { return }
        do { try persist(candidate, retries: retainedRetries); records = candidate; itemRetries = retainedRetries }
        catch { markUnavailable(error); throw error }
        diagnostic("authorization_cancelled", "task_count=\(ids.count) record_count=\(records.count)")
        if let transport, !ids.isEmpty { Task { await transport.cancel(ids) } }
    }

    /// The actual finite production loop: a native handoff fills one slot, not
    /// the whole execution round. Other errors/cancellation still stop promptly.
    @discardableResult
    func runAvailable(ledger: () -> GoogleDriveLibraryLedger, progress: () -> GoogleDriveSyncProgress,
                      check: () throws -> Void,
                      preflight: () -> GoogleDrivePreflightPin? = { nil },
                      maximumOperations: Int = GoogleDriveBackgroundUploads.maximumRoundOperations,
                      perform: (GoogleDriveSyncProgress.UploadChoice) async throws -> Void) async throws -> Int {
        var registered = 0, operations = 0
        let operationLimit = min(Self.maximumRoundOperations, max(0, maximumOperations))
        while registered < Self.maximumTasks && operations < operationLimit {
            try check()
            try cancelUnauthorized(in: ledger())
            guard let selected = try nextUpload(in: ledger(), progress: progress(), allowPipelineFill: true, preflight: preflight()) else { break }
            operations += 1
            try rotateCompletedReadback(selected)
            try recordSourceTurn(selected, in: ledger())
            do { try await perform(selected) }
            catch is GoogleDriveUploadHandoff { registered += 1 }
            catch is GoogleDriveUploadRetryDeferred { /* only this durable item waits */ }
            catch {
                if let failure = error as? GoogleDriveLibraryError, failure.syncFailureScope == .failItemOnly {
                    try quarantineItemFailure(segmentID: selected.segmentID, artifactKey: selected.artifactKey,
                        error: failure, in: ledger())
                    continue
                }
                guard Self.isRetryableItemError(error) else { throw error }
                try recordItemRetry(for: selected.segmentID, artifactKey: selected.artifactKey, error: error, in: ledger())
            }
        }
        return registered
    }

    /// One strict readback gets a turn before cold source/transcript discovery
    /// or any new body preparation. One is a hard fairness bound: discovery and
    /// native refill retain the remainder of this same, never-renewed lease.
    @discardableResult
    func runCompletedReadback(ledger: () -> GoogleDriveLibraryLedger, progress: () -> GoogleDriveSyncProgress,
                              check: () throws -> Void,
                              perform: (GoogleDriveSyncProgress.UploadChoice) async throws -> Void) async throws -> Bool {
        try check()
        try cancelUnauthorized(in: ledger())
        guard let selected = try nextUpload(in: ledger(), progress: progress()),
              completedRecord(for: selected.segmentID, artifactKey: selected.artifactKey) != nil else { return false }
        // Commit queue order before any await. A network await can consume the
        // entire lease and become CancellationError, which must not be counted
        // as a network failure. Cold restart must still give a healthy peer its
        // next turn instead of replaying the same slow head forever.
        try rotateCompletedReadback(selected)
        try recordSourceTurn(selected, in: ledger())
        do { try await perform(selected) }
        catch is GoogleDriveUploadRetryDeferred { }
        catch {
            if let failure = error as? GoogleDriveLibraryError, failure.syncFailureScope == .failItemOnly {
                try quarantineItemFailure(segmentID: selected.segmentID, artifactKey: selected.artifactKey,
                    error: failure, in: ledger())
            } else {
                guard Self.isRetryableItemError(error) else { throw error }
                try recordItemRetry(for: selected.segmentID, artifactKey: selected.artifactKey, error: error, in: ledger())
            }
        }
        return true
    }

    enum ScheduleAdmission { case ready, waitingNative, waitingSelection }
    /// Metadata repair has no staging reservation and may run even when retained
    /// completed bodies occupy all capacity. This never admits a new body.
    func hasDueLegacyMetadataWork(in ledger: GoogleDriveLibraryLedger) -> Bool {
        !handingOff && !isReconciling && !failedClosed && legacyQuarantineCandidate(in: ledger) != nil
    }

    private func legacyQuarantineCandidate(in ledger: GoogleDriveLibraryLedger) -> ItemRetry? {
        guard ledger.enabled, !ledger.revokedLocally else { return nil }
        return itemRetries.first { $0.requiresMetadataReadback
            && ($0.failureReason != .metadataIncomplete || $0.retryAfter <= now())
            && ($0.legacyProbeAfter.map { $0 <= now() } ?? true) && retryMatches($0, in: ledger) }
    }
    /// Only the old reason-free folder-failure migration may requeue an absent
    /// remote file. Incomplete metadata and old artifactInvalid retain their
    /// original ID/session and remain read-only even when a later GET is 404.
    func permitsMissingRemoteRequeue(for segmentID: UUID, artifactKey: String,
                                     in ledger: GoogleDriveLibraryLedger) -> Bool {
        itemRetries.contains { $0.segmentID == segmentID && $0.artifactKey == artifactKey
            && $0.terminal == true && $0.failureReason == nil && retryMatches($0, in: ledger) }
    }
    /// One incomplete or ambiguous pre-fix entry per execution opportunity. Persist
    /// its next check before awaiting network, so cancellation/cold launch cannot
    /// create an account/folder polling loop. The closure may clear it only after
    /// current source/grant and account/folder checks plus exact file metadata.
    @discardableResult
    func runLegacyQuarantineReadback(ledger: () -> GoogleDriveLibraryLedger, check: () throws -> Void,
                                    perform: (GoogleDriveSyncProgress.UploadChoice) async throws -> Void) async throws -> Bool {
        try check()
        try cancelUnauthorized(in: ledger())
        guard let retry = legacyQuarantineCandidate(in: ledger()),
              let index = itemRetries.firstIndex(of: retry) else { return false }
        var candidate = itemRetries
        var deferred = candidate.remove(at: index)
        let delay = retry.failureReason == .metadataIncomplete ? min(3_600, 15 * pow(2, Double(min(retry.failures, 9) - 1))) : 3_600
        deferred.legacyProbeAfter = now().addingTimeInterval(delay)
        candidate.append(deferred)
        try persist(records, retries: candidate); itemRetries = candidate
        let selected = GoogleDriveSyncProgress.UploadChoice(segmentID: retry.segmentID,
            artifactKey: retry.artifactKey, isPrioritySmall: false)
        do { try await perform(selected) }
        catch {
            if let value = error as? GoogleDriveLibraryError, value.syncFailureScope == .failItemOnly {
                try quarantineItemFailure(segmentID: retry.segmentID, artifactKey: retry.artifactKey, error: value, in: ledger())
            } else { throw error }
        }
        return true
    }

    func hasNetworkRecoveryCandidate(in ledger: GoogleDriveLibraryLedger) -> Bool {
        let date = now()
        return networkRecoveryOpportunityDate(in: ledger, at: date).map { $0 <= date } ?? false
    }

    /// A matching network retry remains eligible for a retained signal while
    /// its own probe cooldown is pending. Readiness is checked separately.
    func networkRecoveryOpportunityDate(in ledger: GoogleDriveLibraryLedger, at date: Date) -> Date? {
        guard ledger.enabled, !ledger.revokedLocally, !failedClosed, !isReconciling, !handingOff else { return nil }
        return itemRetries.compactMap { retry -> Date? in
            guard retry.terminal != true, !retry.requiresMetadataReadback, retry.retryFailureKind == .recoverableNetwork,
                  retry.retryAfter > date, retryMatches(retry, in: ledger) else { return nil }
            return retry.recoveryProbeAt.map { max(date, $0.addingTimeInterval(GoogleDriveRetryFailureKind.recoveryCooldown)) } ?? date
        }.min()
    }

    /// An external foreground/path opportunity may probe one transport failure.
    /// Persist cooldown without shortening its deadline. The supplied operation
    /// is read-only; only a matching successful observation clears this item.
    @discardableResult
    func runNetworkRecovery(ledger: () -> GoogleDriveLibraryLedger, check: () throws -> Void,
                            perform: (GoogleDriveSyncProgress.UploadChoice) async throws -> Void) async throws -> Bool {
        try check()
        guard ledger().enabled, !ledger().revokedLocally, !failedClosed, !isReconciling, !handingOff else { return false }
        try cancelUnauthorized(in: ledger())
        guard let index = itemRetries.firstIndex(where: {
            $0.terminal != true && !$0.requiresMetadataReadback && $0.retryFailureKind == .recoverableNetwork
                && $0.retryAfter > now() && retryMatches($0, in: ledger())
                && GoogleDriveRetryFailureKind.cooldownElapsed(since: $0.recoveryProbeAt, at: now())
        }) else { return false }
        var candidate = itemRetries
        candidate[index].recoveryProbeAt = now()
        let reserved = candidate[index]
        try persist(records, retries: candidate); itemRetries = candidate
        let selected = GoogleDriveSyncProgress.UploadChoice(segmentID: reserved.segmentID,
            artifactKey: reserved.artifactKey, isPrioritySmall: false)
        do {
            try await perform(selected)
            try check()
            if ledger().enabled, retryMatches(reserved, in: ledger()), itemRetries.contains(reserved) {
                try clearItemRetry(for: reserved.segmentID, artifactKey: reserved.artifactKey)
            }
        } catch {
            try check()
            guard ledger().enabled, retryMatches(reserved, in: ledger()) else { throw CancellationError() }
            if let value = error as? GoogleDriveLibraryError, value.syncFailureScope == .failItemOnly {
                try quarantineItemFailure(segmentID: reserved.segmentID, artifactKey: reserved.artifactKey,
                    error: value, in: ledger())
            } else if Self.isRetryableItemError(error) {
                try recordItemRetry(for: reserved.segmentID, artifactKey: reserved.artifactKey, error: error, in: ledger())
            } else { throw error }
        }
        return true
    }

    private func rotateCompletedReadback(_ selected: GoogleDriveSyncProgress.UploadChoice) throws {
        guard let saved = completedRecord(for: selected.segmentID, artifactKey: selected.artifactKey),
              let index = records.firstIndex(where: { $0.nonce == saved.nonce }), index != records.count - 1 else { return }
        var candidate = records; candidate.remove(at: index); candidate.append(saved)
        try persist(candidate); records = candidate
        diagnostic("readback_turn", "ready_readback_count=\(readyReadbackCount) native_count=\(nativeActiveCount)")
    }

    private func recordSourceTurn(_ selected: GoogleDriveSyncProgress.UploadChoice, in ledger: GoogleDriveLibraryLedger) throws {
        guard let job = ledger.jobs.first(where: { $0.id == selected.segmentID }), let authorizedAt = ledger.authorizedAt else { return }
        let prior = sourceTurns?.matches(ledger) == true ? sourceTurns?.recent ?? 0 : 0
        let recent = job.manifest.startedAt > authorizedAt ? min(3, prior + 1) : 0
        guard let candidate = SourceTurns(ledger: ledger, recent: recent) else { return }
        try persist(records, sourceTurns: candidate); sourceTurns = candidate
    }

    private static func isRetryableItemError(_ error: Error) -> Bool {
        if (error as NSError).domain == NSURLErrorDomain { return (error as NSError).code != NSURLErrorCancelled }
        if let error = error as? GoogleDriveError {
            switch error {
            case .http(let status): return status == 408 || status == 429 || (500...599).contains(status)
            case .apiFailure(let status, let reason): return reason.isRateLimit || status == 408 || status == 429 || (500...599).contains(status)
            // A bad acknowledgement belongs to this resumable session. Retain
            // its identity for a later query without delaying healthy peers.
            // Generic invalidResponse still covers account/endpoint validation.
            case .expiredSession, .invalidResumableOffset: return true
            default: return false
            }
        }
        return false
    }

    /// Network readback failures keep the completed body. A confirmed incomplete
    /// session can retire that body only after its own durable backoff exists.
    /// A non-retryable artifact failure stays on that artifact. Revocation still
    /// escapes so the library grant can stop. The completed body is dropped
    /// only after the terminal mark is durable; dropping it is not verification.
    private func quarantineItemFailure(segmentID: UUID, artifactKey: String, error: GoogleDriveLibraryError,
                                       in ledger: GoogleDriveLibraryLedger) throws {
        if ledger.revokedLocally || ledger.accountID == nil { throw GoogleDriveLibraryError.changedAccount }
        guard let binding = RetryBinding(ledger: ledger, segmentID: segmentID, artifactKey: artifactKey) else { return }
        let digest = try binding.digest()
        let previous = itemRetries.first { $0.segmentID == segmentID && $0.artifactKey == artifactKey && $0.bindingSHA256 == digest }
        if error == .metadataIncomplete {
            let failures = min(16, (previous?.failures ?? 0) + 1)
            let retry = ItemRetry(segmentID: segmentID, artifactKey: artifactKey, bindingSHA256: digest,
                failures: failures, retryAfter: now().addingTimeInterval(min(3_600, 15 * pow(2, Double(min(failures, 9) - 1)))),
                attemptNonce: completedRecord(for: segmentID, artifactKey: artifactKey)?.nonce ?? previous?.attemptNonce,
                failureReason: .metadataIncomplete, lastFailureAt: now())
            var candidate = itemRetries.filter { $0.segmentID != segmentID || $0.artifactKey != artifactKey }
            candidate.append(retry)
            try persist(records, retries: candidate); itemRetries = candidate
            diagnostic("item_metadata_incomplete", "failure_count=\(failures) native_count=\(nativeActiveCount)")
            return
        }
        let failures = min(16, max(1, (previous?.failures ?? 0) + (previous?.terminal == true ? 0 : 1)))
        let nonce = completedRecord(for: segmentID, artifactKey: artifactKey)?.nonce
        let reason: ItemRetry.FailureReason
        switch error {
        case .changedManifest: reason = .sourceChanged
        case .notAuthorized: reason = .sourceUnauthorized
        case .invalidRemoteFile: reason = .remoteConflict
        default: throw error // library/folder errors must never poison an item
        }
        let retry = ItemRetry(segmentID: segmentID, artifactKey: artifactKey, bindingSHA256: digest,
            failures: failures, retryAfter: Date(timeIntervalSince1970: 253_402_300_799), attemptNonce: nonce,
            terminal: true, failureReason: reason, lastFailureAt: now())
        var candidate = itemRetries.filter { $0.segmentID != segmentID || $0.artifactKey != artifactKey }
        candidate.append(retry)
        try persist(records, retries: candidate)
        itemRetries = candidate
        if let nonce {
            do { try discardCompleted(nonce: nonce) }
            catch { diagnostic("item_terminal_body_retained", "native_count=\(nativeActiveCount)") }
        }
        diagnostic("item_terminal", "failure_count=\(failures) native_count=\(nativeActiveCount) ready_readback_count=\(readyReadbackCount)")
    }
    private func recordItemRetry(for segmentID: UUID, artifactKey: String, error: Error, in ledger: GoogleDriveLibraryLedger) throws {
        guard let binding = RetryBinding(ledger: ledger, segmentID: segmentID, artifactKey: artifactKey) else {
            throw GoogleDriveLibraryError.notAuthorized
        }
        let digest = try binding.digest(), old = itemRetries.first { $0.segmentID == segmentID && $0.artifactKey == artifactKey && $0.bindingSHA256 == digest }
        let nsError = error as NSError
        try saveItemRetry(segmentID: segmentID, artifactKey: artifactKey, binding: digest,
            failures: min(16, (old?.failures ?? 0) + 1), nonce: completedRecord(for: segmentID, artifactKey: artifactKey)?.nonce,
            failureKind: GoogleDriveRetryFailureKind.classify(errorDomain: nsError.domain, code: nsError.code), recoveryProbeAt: old?.recoveryProbeAt)
    }
    private func saveItemRetry(segmentID: UUID, artifactKey: String, binding: String, failures: Int, nonce: UUID?,
                               failureKind: GoogleDriveRetryFailureKind? = nil, recoveryProbeAt: Date? = nil) throws {
        let retry = ItemRetry(segmentID: segmentID, artifactKey: artifactKey, bindingSHA256: binding,
            failures: failures, retryAfter: now().addingTimeInterval(min(3_600, 5 * pow(2, Double(failures)))), attemptNonce: nonce,
            retryFailureKind: failureKind, recoveryProbeAt: recoveryProbeAt, lastFailureAt: now())
        var candidate = itemRetries.filter { $0.segmentID != segmentID || $0.artifactKey != artifactKey }; candidate.append(retry)
        try persist(records, retries: candidate); itemRetries = candidate
        diagnostic("item_deferred", "failure_count=\(failures) retry_delay_seconds=\(Int(retry.retryAfter.timeIntervalSince(now()))) native_count=\(nativeActiveCount) ready_readback_count=\(readyReadbackCount)")
    }
    func deferUnverifiedRetry(for segmentID: UUID, artifactKey: String) throws {
        guard let saved = completedRecord(for: segmentID, artifactKey: artifactKey) else {
            if hasUnverifiedCompletedAttempt { throw GoogleDriveLibraryError.invalidState }
            return
        }
        let digest = try RetryBinding(saved.context).digest()
        if let old = itemRetries.first(where: { $0.segmentID == segmentID && $0.artifactKey == artifactKey && $0.bindingSHA256 == digest }),
           old.attemptNonce == saved.nonce {
            guard old.retryAfter <= now() else { throw GoogleDriveUploadRetryDeferred() }
            try discardCompleted(nonce: saved.nonce)
            return // this attempt already spent its one backoff before this due readback
        }
        let failures = min(16, (itemRetries.first { $0.segmentID == segmentID && $0.artifactKey == artifactKey && $0.bindingSHA256 == digest }?.failures ?? 0) + 1)
        try saveItemRetry(segmentID: segmentID, artifactKey: artifactKey, binding: digest, failures: failures, nonce: saved.nonce)
        try discardCompleted(nonce: saved.nonce)
        throw GoogleDriveUploadRetryDeferred()
    }
    func clearItemRetry(for segmentID: UUID, artifactKey: String) throws {
        let candidate = itemRetries.filter { $0.segmentID != segmentID || $0.artifactKey != artifactKey }
        guard candidate.count != itemRetries.count else { return }
        try persist(records, retries: candidate); itemRetries = candidate
    }

    /// Stage a suffix from already fully fingerprinted local content. Hash it
    /// again while copying; the native process receives only this immutable file.
    func start(request: URLRequest, file: URL, offset: Int64, context: GoogleDriveUploadContext,
               isAuthorized: () -> Bool, check: @escaping @Sendable () throws -> Void) async throws {
        guard !failedClosed, !handingOff, !isReconciling, isAuthorized(), offset >= 0,
              offset < context.artifact.byteCount, request.httpMethod == "PUT",
              request.url?.absoluteString == context.artifact.uploadURL,
              request.httpBody == nil && request.httpBodyStream == nil,
              request.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(context.artifact.byteCount - 1)/\(context.artifact.byteCount)",
              request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
        else { throw GoogleDriveLibraryError.notAuthorized }
        guard !isDeferred(context.manifest.id, context.artifact.key) else { throw GoogleDriveUploadRetryDeferred() }
        let expected = context.artifact.byteCount - offset, identity = key(context)
        guard canReserve(bytes: expected), !records.contains(where: { key($0.context) == identity }),
              !stagingReservations.values.contains(where: { $0.key == identity }) else { throw GoogleDriveLibraryError.invalidState }
        try Self.prepare(directory)
        let revision = operationRevision, registration = registrationRevision
        let nonce = UUID(), body = directory.appendingPathComponent(nonce.uuidString.lowercased() + ".body")
        stagingReservations[nonce] = (expected, identity)
        defer { stagingReservations.removeValue(forKey: nonce) }
        let transport = try session()
        // A legacy session may change its immutable network configuration only
        // after both native tasks and durable records have drained. Include
        // completed records here: their task IDs must not collide with a new
        // URLSession generation. No source content is read while this waits.
        try await transport.prepareForNewRequests(allowSessionMigration: records.isEmpty && stagingReservations.count == 1)
        try check(); try Task.checkCancellation()
        guard operationRevision == revision, registrationRevision == registration,
              isAuthorized(), !handingOff, !isReconciling else { throw CancellationError() }
        let staging = Task.detached(priority: .utility) {
            try check(); try Task.checkCancellation()
            let sourceFD = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard sourceFD >= 0 else { throw GoogleDriveLibraryError.changedManifest }
            let source = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
            defer { try? source.close() }
            var before = stat()
            guard Darwin.fstat(sourceFD, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_nlink == 1, before.st_size == context.artifact.byteCount else {
                throw GoogleDriveLibraryError.changedManifest
            }
            let fd = Darwin.open(body.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw GoogleDriveLibraryError.invalidState }
            let target = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? target.close() }
            var hasher = SHA256(), fullHasher = SHA256(), scanned: Int64 = 0, copied: Int64 = 0
            while scanned < context.artifact.byteCount {
                try check(); try Task.checkCancellation()
                let count = Int(min(1_048_576, context.artifact.byteCount - scanned))
                guard let bytes = try source.read(upToCount: count), bytes.count == count else {
                    throw GoogleDriveLibraryError.changedManifest
                }
                fullHasher.update(data: bytes)
                if scanned + Int64(count) > offset {
                    let suffix = bytes.dropFirst(Int(max(0, offset - scanned)))
                    try target.write(contentsOf: suffix); hasher.update(data: suffix); copied += Int64(suffix.count)
                }
                scanned += Int64(count)
            }
            var after = stat()
            guard Darwin.fstat(sourceFD, &after) == 0, before.st_dev == after.st_dev,
                  before.st_ino == after.st_ino, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  copied == expected,
                  fullHasher.finalize().map({ String(format: "%02x", $0) }).joined() == context.artifact.sha256 else {
                throw GoogleDriveLibraryError.changedManifest
            }
            try target.synchronize()
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: body.path)
            #endif
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        var registeredID: Int?
        do {
            let hash = try await withTaskCancellationHandler { try await staging.value } onCancel: { staging.cancel() }
            try check(); try Task.checkCancellation()
            guard operationRevision == revision, registrationRevision == registration, isAuthorized(), !handingOff, !isReconciling,
                  request.value(forHTTPHeaderField: "Content-Length") == String(expected) else { throw CancellationError() }
            var saved = Record(schemaVersion: 1, nonce: nonce, context: context, offset: offset,
                               bodyByteCount: expected, bodySHA256: hash)
            try persist(records + [saved]); records.append(saved) // before native creation/resume
            stagingReservations.removeValue(forKey: nonce)
            try check(); try Task.checkCancellation()
            guard isAuthorized() else { throw CancellationError() }
            let taskID = try transport.create(request, file: body, nonce: nonce.uuidString.lowercased())
            registeredID = taskID; nativeTaskIDs.insert(taskID); rejectedNativeTaskIDs.remove(taskID)
            saved.taskID = taskID
            try replace(saved)
            try check(); try Task.checkCancellation()
            guard isAuthorized() else { throw CancellationError() }
            transport.resume(taskID)
            diagnostic("register", metadata(saved))
        } catch {
            if var saved = records.first(where: { $0.nonce == nonce }) {
                // Failed registration retains the original resumable URL, but
                // must not leave an unsent body occupying the slot forever.
                saved.cancelled = true
                if registeredID == nil { saved.completed = true }
                do { try replace(saved) }
                catch { markUnavailable(error) }
                if let registeredID { await transport.cancel([registeredID]) }
                if saved.completed { try? discardCompleted(nonce: saved.nonce) }
            } else { try? FileManager.default.removeItem(at: body) }
            throw error
        }
    }

    func cancel() {
        registrationRevision &+= 1
        guard !records.isEmpty else { return }
        var candidate = records
        for index in candidate.indices { candidate[index].cancelled = true }
        do { try persist(candidate); records = candidate }
        catch { markUnavailable(error) }
        let ids = nativeTaskIDs
        if let transport { Task { await transport.cancel(ids) } }
    }

    private static func completionKey(_ task: GoogleDriveUploadTaskInfo) -> String {
        String(task.id) + ":" + (task.nonce ?? "none")
    }

    private func receive(_ result: GoogleDriveUploadCompletion) {
        completedNativeTasks.insert(Self.completionKey(result.task))
        guard var saved = records.first(where: { $0.matches(result.task) }) else {
            if rejectedNativeTaskIDs.remove(result.task.id) != nil || !records.contains(where: { $0.taskID == result.task.id }) {
                nativeTaskIDs.remove(result.task.id)
            }
            do { try cleanupCancelledIfDrained() } catch { markUnavailable(error) }
            changed(); return
        }
        nativeTaskIDs.remove(result.task.id); rejectedNativeTaskIDs.remove(result.task.id)
        guard result.responseURL == nil || result.responseURL == saved.context.artifact.uploadURL else {
            markUnavailable(GoogleDriveLibraryError.invalidState); changed(); return
        }
        let attributedDiagnostic = result.diagnostic?.withUploadCorrelation(saved.context.uploadCorrelation)
        GoogleDriveUploadTrace.$current.withValue(saved.context.uploadCorrelation) {
            diagnostic("http_completion", metadata(saved) + " http_status=\(result.status.map(String.init) ?? "none") transport_failed=\(result.transportFailed)"
                + (attributedDiagnostic.map { " " + $0.logFields } ?? ""))
            if let value = attributedDiagnostic { transportDiagnostic(value) }
        }
        saved.completed = true
        do { try replace(saved); try cleanupCancelledIfDrained() }
        catch { markUnavailable(error) }
        changed()
    }

    private func cleanupCancelledIfDrained() throws {
        guard rejectedNativeTaskIDs.isEmpty else { return }
        for saved in records where saved.cancelled && saved.completed && saved.taskID.map({ !nativeTaskIDs.contains($0) }) != false {
            try discardCompleted(nonce: saved.nonce)
        }
    }

    /// Independent remote verification retires only this exact completed body.
    func discardCompleted(nonce: UUID? = nil) throws {
        guard let saved = nonce.flatMap({ id in records.first { $0.nonce == id } }) ?? (nonce == nil ? records.first : nil) else { return }
        guard saved.completed, saved.taskID.map({ !nativeTaskIDs.contains($0) }) != false,
              rejectedNativeTaskIDs.isEmpty else { throw GoogleDriveLibraryError.invalidState }
        try Self.removePrivateFile(directory.appendingPathComponent(saved.bodyName))
        let candidate = records.filter { $0.nonce != saved.nonce }
        try persist(candidate); records = candidate
    }

    private func metadata(_ saved: Record? = nil) -> String {
        let counts = " native_count=\(nativeActiveCount) record_count=\(records.count) staged_bytes=\(stagedBodyBytes)"
        guard let record = saved ?? records.first else { return "attempt=none" + counts }
        return "attempt=\(record.nonce.uuidString.lowercased()) task=\(record.taskID.map(String.init) ?? "none")"
            + " " + record.context.uploadCorrelation.logFields
            + " offset=\(record.offset) bytes=\(record.bodyByteCount)" + counts
    }

    private func replace(_ value: Record) throws {
        guard let index = records.firstIndex(where: { $0.nonce == value.nonce }) else { throw GoogleDriveLibraryError.invalidState }
        var candidate = records; candidate[index] = value
        try persist(candidate); records = candidate
    }
    private func persist(_ values: [Record], retries: [ItemRetry]? = nil, sourceTurns: SourceTurns? = nil) throws {
        try metadataFault?(.persist)
        try GoogleDriveMetadataIO.perform { try persistMetadata(values, retries: retries, sourceTurns: sourceTurns) }
    }
    private func persistMetadata(_ values: [Record], retries: [ItemRetry]? = nil, sourceTurns: SourceTurns? = nil) throws {
        let retryValues = retries ?? itemRetries
        let turnValues = sourceTurns ?? self.sourceTurns
        try turnValues?.validate()
        try validateRecords(values, libraryID: libraryID); try validateRetries(retryValues)
        try Self.prepare(directory)
        if values.isEmpty && retryValues.isEmpty && turnValues == nil {
            try Self.removePrivateFile(stateURL); try Self.sync(directory); return
        }
        let bytes = try TransportCodec.encode(State(schemaVersion: 2, records: values, retries: retryValues.isEmpty ? nil : retryValues,
                                                   sourceTurns: turnValues))
        guard bytes.count <= 16 * 1_024 * 1_024 else { throw GoogleDriveLibraryError.invalidState }
        if FileManager.default.fileExists(atPath: stateURL.path) { _ = try Self.read(stateURL, maximum: 16 * 1_024 * 1_024) }
        let temporary = directory.appendingPathComponent(".pipeline-" + UUID().uuidString.lowercased())
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
        #endif
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: bytes); try handle.synchronize()
        guard Darwin.rename(temporary.path, stateURL.path) == 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
        try Self.sync(directory)
    }
    private static func prepare(_ directory: URL) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw GoogleDriveLibraryError.invalidState }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
    }
    private static func removePrivateFile(_ path: URL) throws {
        var info = stat()
        if Darwin.lstat(path.path, &info) != 0 {
            guard errno == ENOENT else { throw GoogleDriveMetadataIO.syscallFailure() }; return
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw GoogleDriveLibraryError.invalidState }
        guard Darwin.unlink(path.path) == 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
    }
    private static func cleanOrphans(_ directory: URL, keeping: Set<String>) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.count <= 4_096 else { throw GoogleDriveLibraryError.invalidState }
        for name in names where !keeping.contains(name) {
            let nonce: String
            if name.hasSuffix(".body") { nonce = String(name.dropLast(5)) }
            else if name.hasPrefix(".attempt-") { nonce = String(name.dropFirst(9)) }
            else if name.hasPrefix(".pipeline-") { nonce = String(name.dropFirst(10)) }
            else { continue }
            guard UUID(uuidString: nonce)?.uuidString.lowercased() == nonce else { continue }
            try removePrivateFile(directory.appendingPathComponent(name))
        }
        try sync(directory)
    }
    private static func read(_ path: URL, maximum: Int) throws -> Data {
        try GoogleDriveMetadataIO.read(path, maximum: maximum)
    }
    private static func sync(_ directory: URL) throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
    }
}

/// The only adapter that submits network bytes. Tests substitute this adapter,
/// while exercising the actual persisted coordinator and grant fences above.
@MainActor
final class GoogleDriveUploadSession: GoogleDriveUploadTransport {
    let identifier: String
    private var delegate: GoogleDriveUploadSessionDelegate!
    private var session: URLSession!
    private let networkSettings: GoogleDriveNetworkSettings
    private let configuration: URLSessionConfiguration
    private let complete: @Sendable (GoogleDriveUploadCompletion) -> Void
    private let finished: @Sendable (BackgroundSessionEvent) -> Void
    private var created: [Int: URLSessionUploadTask] = [:]
    private var invalidation = GoogleDriveSessionInvalidation()
    private var usesRequestPolicy: Bool
    private var migrating = false
    // Closing is terminal for this adapter. A UIKit handoff must never adopt a
    // session rebuilt by a migration that was suspended in the old generation.
    private var closed = false
    private var migrationInvalidationStarted = false
    private let sessionFactory: (URLSessionConfiguration, URLSessionDelegate) -> URLSession
    init(identifier: String, complete: @escaping @Sendable (GoogleDriveUploadCompletion) -> Void,
         finished: @escaping @Sendable (BackgroundSessionEvent) -> Void,
         networkSettings: GoogleDriveNetworkSettings = .shared,
         configuration: URLSessionConfiguration? = nil,
         sessionFactory: @escaping (URLSessionConfiguration, URLSessionDelegate) -> URLSession = {
             URLSession(configuration: $0, delegate: $1, delegateQueue: nil)
         }) throws {
        self.identifier = identifier
        self.networkSettings = networkSettings; self.sessionFactory = sessionFactory
        self.complete = complete; self.finished = finished
        usesRequestPolicy = networkSettings.nativeSessionUsesRequestPolicy(identifier)
        let config: URLSessionConfiguration
        if let configuration { config = configuration }
        else {
            #if os(iOS)
            config = URLSessionConfiguration.background(withIdentifier: identifier)
            config.sessionSendsLaunchEvents = true; config.isDiscretionary = false
            config.waitsForConnectivity = true
            #else
            throw GoogleDriveError.unavailable // synthetic tests must inject a configuration or transport
            #endif
        }
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 3_600
        self.configuration = config
        rebuildSession()
    }
    private func rebuildSession() {
        let invalidation = self.invalidation
        delegate = GoogleDriveUploadSessionDelegate(complete: complete, finished: finished,
                                                    invalidated: { invalidation.finish() })
        // Until the legacy session fully drains, preserve its historical false
        // ceiling even though old original requests defaulted to true.
        configuration.allowsCellularAccess = usesRequestPolicy
        session = sessionFactory(configuration, delegate)
    }
    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }
    func prepareForNewRequests(allowSessionMigration: Bool) async throws {
        try checkOpen()
        guard !usesRequestPolicy else { return }
        guard !migrating else { throw GoogleDriveUploadRetryDeferred() }
        guard allowSessionMigration else {
            // A cancelled migration may already have invalidated its session.
            // Keep that boundary until a new eligible opportunity can finish it.
            guard !migrationInvalidationStarted else { throw GoogleDriveUploadRetryDeferred() }
            return
        }
        migrating = true; defer { migrating = false }
        if !migrationInvalidationStarted {
            let outstanding = await tasks()
            try checkOpen()
            guard outstanding.isEmpty, created.isEmpty else { return }
            // No cancellation, replay, task mutation or new resumable identity.
            migrationInvalidationStarted = true
            session.finishTasksAndInvalidate()
        }
        let retiring = invalidation
        await retiring.wait()
        try checkOpen()
        // No suspension between the lifetime check, policy commit and rebuild.
        usesRequestPolicy = true
        networkSettings.markNativeSessionUsesRequestPolicy(identifier)
        invalidation = GoogleDriveSessionInvalidation()
        migrationInvalidationStarted = false
        rebuildSession()
    }
    func tasks() async -> [GoogleDriveUploadTaskInfo] {
        guard !closed else { return [] }
        return await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0.map(GoogleDriveUploadSessionDelegate.info)) }
        }
    }
    func create(_ request: URLRequest, file: URL, nonce: String) throws -> Int {
        try checkOpen()
        guard !migrating, !migrationInvalidationStarted else { throw GoogleDriveUploadRetryDeferred() }
        var request = request
        // Permission is an upper bound. Legacy sessions keep accepting healthy
        // peers over Wi-Fi even when an incomplete remote readback prevents
        // the old queue from draining and the user has allowed cellular.
        request.allowsCellularAccess = usesRequestPolicy && networkSettings.allowsCellularAccess
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = nonce; created[task.taskIdentifier] = task
        return task.taskIdentifier
    }
    func resume(_ taskID: Int) {
        guard !closed, !migrationInvalidationStarted else { return }
        created.removeValue(forKey: taskID)?.resume()
    }
    func cancel(_ taskIDs: Set<Int>) async {
        guard !closed else { return }
        for id in taskIDs { created.removeValue(forKey: id)?.cancel() }
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                tasks.filter { taskIDs.contains($0.taskIdentifier) }.forEach { $0.cancel() }
                continuation.resume()
            }
        }
    }
    func invalidateAndCancel() async {
        // Fence before the first await, including another waiter on a graceful
        // migration invalidation. Repeated closes wait on the same old latch.
        let retiring = invalidation
        if !closed {
            closed = true
            session.invalidateAndCancel()
        }
        await retiring.wait()
        created.removeAll()
    }
}

private final class GoogleDriveSessionInvalidation: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished { lock.unlock(); continuation.resume() }
            else { waiting.append(continuation); lock.unlock() }
        }
    }
    func finish() {
        lock.lock(); finished = true; let callbacks = waiting; waiting.removeAll(); lock.unlock()
        callbacks.forEach { $0.resume() }
    }
}

private final class GoogleDriveUploadSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let complete: @Sendable (GoogleDriveUploadCompletion) -> Void
    private let finished: @Sendable (BackgroundSessionEvent) -> Void
    private let invalidated: @Sendable () -> Void
    private let lock = NSLock()
    private var receivedBytes: [Int: Int] = [:]
    private var metrics: [Int: GoogleDriveTransportMetrics] = [:]
    init(complete: @escaping @Sendable (GoogleDriveUploadCompletion) -> Void,
         finished: @escaping @Sendable (BackgroundSessionEvent) -> Void, invalidated: @escaping @Sendable () -> Void) {
        self.complete = complete; self.finished = finished; self.invalidated = invalidated
    }
    static func info(_ task: URLSessionTask) -> GoogleDriveUploadTaskInfo {
        let request = task.originalRequest
        return .init(id: task.taskIdentifier, nonce: task.taskDescription, url: request?.url?.absoluteString,
                     method: request?.httpMethod, contentRange: request?.value(forHTTPHeaderField: "Content-Range"), isSuspended: task.state == .suspended)
    }
    // Background URLSession may follow redirects without this callback. This is
    // only a non-background/controlled-adapter safeguard, never a native host fence.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); let count = (receivedBytes[dataTask.taskIdentifier] ?? 0) + data.count
        receivedBytes[dataTask.taskIdentifier] = count; lock.unlock()
        if count > 1_048_576 { dataTask.cancel() } // response bytes are never parsed or retained
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting taskMetrics: URLSessionTaskMetrics) {
        guard let value = GoogleDriveTransportMetrics.capture(taskMetrics) else { return }
        lock.lock(); metrics[task.taskIdentifier] = value; lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); receivedBytes.removeValue(forKey: task.taskIdentifier)
        let taskMetrics = metrics.removeValue(forKey: task.taskIdentifier); lock.unlock()
        let response = task.response as? HTTPURLResponse
        complete(.init(task: Self.info(task), responseURL: response?.url?.absoluteString,
                       status: response?.statusCode, transportFailed: error != nil,
                       diagnostic: .capture(error: error, request: task.originalRequest, phase: .nativeUpload,
                                            httpStatus: response?.statusCode, metrics: taskMetrics, origin: .natural)))
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) { invalidated() }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let identifier = session.configuration.identifier {
            // Stamp the native delegate ingress, before actor hops or a held
            // persistence operation can introduce a later UIKit handler.
            finished(BackgroundSessionEventTracker.shared.capture(identifier))
        }
    }
}

/// UIKit completion must not wait for a user-facing OAuth flow. Only a round
/// already protected by a finite execution lease can delay event drainage.
@MainActor
enum GoogleDriveBackgroundEventDrain {
    static func finish(work: Task<Void, Never>?, hasBoundedExecution: Bool, completion: () -> Void) async {
        if hasBoundedExecution, let work { await work.value }
        completion()
    }
}
