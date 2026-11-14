import Foundation
import Darwin

public enum AutomaticDeliveryLedgerError: LocalizedError, Equatable {
    case unsupportedVersion, invalidLedger, invalidAuthorization, scopeChanged, duplicateManifest
    case changedManifest, unknownDelivery, invalidTransition, retryNotDue, invalidArchive
    case invalidReceipt, capacityExceeded, unsafeFile

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "自动交付记录版本暂不支持。"
        case .invalidLedger: return "自动交付记录无法校验，已暂停处理。"
        case .invalidAuthorization: return "自动交付授权范围无效。"
        case .scopeChanged: return "接收端或配对授权已改变，不能沿用原交付记录。"
        case .duplicateManifest: return "录音清单包含重复项目。"
        case .changedManifest: return "已授权录音的原始信息发生变化，已暂停交付。"
        case .unknownDelivery: return "未找到这次交付记录。"
        case .invalidTransition: return "这次交付当前不能执行此操作。"
        case .retryNotDue: return "尚未到达下次自动重试时间。"
        case .invalidArchive: return "交付包信息无法校验，原录音仍保留。"
        case .invalidReceipt: return "接收回执与本次交付不一致，未标记成功。"
        case .capacityExceeded: return "自动交付记录或交付包已超过容量限制。"
        case .unsafeFile: return "交付记录文件不安全或无法持久保存。"
        }
    }
}

/// A grant is immutable. A replacement pairing gets a separate ledger directory.
/// Bearer credentials intentionally have no representation in this ledger.
public struct AutomaticDeliveryScope: Codable, Equatable, Sendable {
    public let receiverID: UUID
    public let pairingID: UUID
    public let grantEpoch: UUID
    public let sourceInstallationID: UUID
    public let endpoint: String
    public let certificateSHA256: String

    public init(receiverID: UUID, pairingID: UUID, grantEpoch: UUID, sourceInstallationID: UUID,
                endpoint: String, certificateSHA256: String) {
        self.receiverID = receiverID
        self.pairingID = pairingID
        self.grantEpoch = grantEpoch
        self.sourceInstallationID = sourceInstallationID
        self.endpoint = endpoint
        self.certificateSHA256 = certificateSHA256
    }
}

public enum AutomaticDeliveryState: String, Codable, Sendable {
    case queued, preparing, uploading, retryWaiting, delivered, blocked
}

public struct AutomaticDeliveryArchive: Codable, Equatable, Sendable {
    /// A single safe ZIP filename relative to the grant's private archive directory.
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int64

    public init(relativePath: String, sha256: String, byteCount: Int64) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

/// A receiver's durable storage receipt; this is never a Watch/audio deletion ACK.
public struct AutomaticDeliveryReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let receiverID: UUID
    public let deliveryID: UUID
    public let archiveSHA256: String
    public let recordingIDs: [UUID]
    public let storedAt: Date

    public init(schemaVersion: Int = 1, receiverID: UUID, deliveryID: UUID, archiveSHA256: String,
                recordingIDs: [UUID], storedAt: Date) {
        self.schemaVersion = schemaVersion
        self.receiverID = receiverID
        self.deliveryID = deliveryID
        self.archiveSHA256 = archiveSHA256
        self.recordingIDs = recordingIDs
        self.storedAt = AutomaticDeliveryLedger.canonical(storedAt)
    }
}

public struct AutomaticDeliveryJob: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var deliveryID: UUID { id }
    public let scope: AutomaticDeliveryScope
    public let manifest: SegmentManifest
    public let transcriptSHA256: String?
    public let createdAt: Date
    public fileprivate(set) var updatedAt: Date
    public fileprivate(set) var state: AutomaticDeliveryState
    public fileprivate(set) var archive: AutomaticDeliveryArchive?
    public fileprivate(set) var attemptCount: Int
    public fileprivate(set) var nextAttemptAt: Date?
    public fileprivate(set) var lastError: String?
    public fileprivate(set) var receipt: AutomaticDeliveryReceipt?
}

/// Pure metadata and state transitions. The caller verifies transcript/source bytes,
/// creates and fingerprints the ZIP, and persists each mutation BEFORE side effects.
/// Mutate a copy, save it successfully, then publish that copy as current state.
public struct AutomaticDeliveryLedger: Codable, Equatable, Sendable {
    public static let maximumAuthorizedRecordings = 10_000
    public static let maximumJobs = 10_000
    public static let maximumArchiveBytes: Int64 = 130 * 1_024 * 1_024
    public static let maximumAttempts = 32
    public static let maximumLedgerBytes = 32 * 1_024 * 1_024

    public private(set) var schemaVersion: Int
    public let scope: AutomaticDeliveryScope
    public let baselineIDs: Set<UUID>
    public private(set) var selectedExistingIDs: Set<UUID>
    public private(set) var includeFuture: Bool
    public let createdAt: Date
    public private(set) var eligibleFutureIDs: Set<UUID>
    public private(set) var jobs: [AutomaticDeliveryJob]

    public var authorizedIDs: Set<UUID> { selectedExistingIDs.union(eligibleFutureIDs) }

    /// New grants always include every known recording and all recordings received
    /// later. An empty library is valid; metadata and durable receipts may arrive
    /// separately, and neither recording dates nor a selection filter restrict it.
    public init(scope: AutomaticDeliveryScope, knownRecordingIDs: Set<UUID>, createdAt: Date = Date()) throws {
        self.schemaVersion = 2
        self.scope = scope
        self.baselineIDs = knownRecordingIDs
        self.selectedExistingIDs = knownRecordingIDs
        self.includeFuture = true
        self.createdAt = Self.canonical(createdAt)
        self.eligibleFutureIDs = []
        self.jobs = []
        try validate()
    }

    /// Legacy schema-1 construction is retained for compatibility and migration
    /// fixtures. Product setup must use the all-recordings initializer above.
    public init(scope: AutomaticDeliveryScope, baselineIDs: Set<UUID>, selectedExistingIDs: Set<UUID>,
                includeFuture: Bool, createdAt: Date = Date()) throws {
        self.schemaVersion = 1
        self.scope = scope
        self.baselineIDs = baselineIDs
        self.selectedExistingIDs = selectedExistingIDs
        self.includeFuture = includeFuture
        self.createdAt = Self.canonical(createdAt)
        self.eligibleFutureIDs = []
        self.jobs = []
        try validate()
    }

    /// Upgrades only the authorization policy. Scope, timestamps, captured
    /// manifests, stable delivery/ZIP identities, retry state and receipts remain
    /// unchanged. Enabled/paused is owned by the caller and is never inferred here.
    /// Persist this mutation before creating a client or reconciling more jobs.
    @discardableResult
    public mutating func migrateToAllRecordings() throws -> Bool {
        try validate()
        guard schemaVersion == 1 else { return false }
        var candidate = self
        candidate.schemaVersion = 2
        candidate.selectedExistingIDs = baselineIDs
        candidate.includeFuture = true
        try candidate.validate()
        self = candidate
        return true
    }

    public func requireScope(_ proposed: AutomaticDeliveryScope) throws {
        try Self.validateScope(proposed)
        guard scope == proposed else { throw AutomaticDeliveryLedgerError.scopeChanged }
    }

    public func job(for deliveryID: UUID) -> AutomaticDeliveryJob? {
        jobs.first { $0.id == deliveryID }
    }

    /// Schema 2 includes every known or newly received ID; each job still requires
    /// both metadata and a durable receipt. Legacy schema 1 retains its old range
    /// until explicitly migrated. Captured manifests and delivery versions never
    /// change when metadata, receipts or transcript caches arrive later.
    @discardableResult
    public mutating func reconcile(manifests: [SegmentManifest], receivedSegmentIDs: Set<UUID>,
                                   transcriptHashes: [UUID: String] = [:], now: Date = Date()) throws -> [UUID] {
        try validate()
        let date = try Self.validatedDate(now)
        guard manifests.count <= Self.maximumAuthorizedRecordings,
              receivedSegmentIDs.count <= Self.maximumAuthorizedRecordings,
              transcriptHashes.count <= Self.maximumAuthorizedRecordings else {
            throw AutomaticDeliveryLedgerError.capacityExceeded
        }
        guard Set(manifests.map(\.id)).count == manifests.count else {
            throw AutomaticDeliveryLedgerError.duplicateManifest
        }
        var candidate = self
        if includeFuture {
            candidate.eligibleFutureIDs.formUnion(receivedSegmentIDs.subtracting(baselineIDs))
        }
        let authorized = candidate.authorizedIDs
        guard authorized.count <= Self.maximumAuthorizedRecordings else {
            throw AutomaticDeliveryLedgerError.capacityExceeded
        }
        var originals: [UUID: SegmentManifest] = [:]
        var versions: [UUID: Set<String>] = [:]
        for job in jobs {
            originals[job.manifest.id] = job.manifest
            versions[job.manifest.id, default: []].insert(job.transcriptSHA256 ?? "")
        }
        var added: [UUID] = []
        for manifest in manifests.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            // Detect changed captured metadata even if a caller temporarily omits
            // its durable receipt; lack of a receipt never authorizes a replacement.
            if let original = originals[manifest.id], original != manifest {
                throw AutomaticDeliveryLedgerError.changedManifest
            }
            guard authorized.contains(manifest.id), receivedSegmentIDs.contains(manifest.id) else { continue }
            try Self.validateManifest(manifest)
            let transcriptHash = transcriptHashes[manifest.id]
            if let transcriptHash, !Self.isDigest(transcriptHash) {
                throw AutomaticDeliveryLedgerError.invalidLedger
            }
            let existing = versions[manifest.id, default: []]
            if existing.contains(transcriptHash ?? "") || (transcriptHash == nil && !existing.isEmpty) { continue }
            guard candidate.jobs.count < Self.maximumJobs else { throw AutomaticDeliveryLedgerError.capacityExceeded }
            let job = AutomaticDeliveryJob(id: UUID(), scope: scope, manifest: manifest,
                transcriptSHA256: transcriptHash, createdAt: date, updatedAt: date, state: .queued,
                archive: nil, attemptCount: 0, nextAttemptAt: nil, lastError: nil, receipt: nil)
            candidate.jobs.append(job)
            versions[manifest.id, default: []].insert(transcriptHash ?? "")
            originals[manifest.id] = manifest
            added.append(job.id)
        }
        try candidate.validate()
        self = candidate
        return added
    }

    public mutating func beginPreparation(deliveryID: UUID, now: Date = Date()) throws {
        try mutateJob(deliveryID, now: now) { job, date in
            try Self.requireReady(job, at: date)
            guard job.archive == nil else { throw AutomaticDeliveryLedgerError.invalidTransition }
            job.state = .preparing
            job.nextAttemptAt = nil
        }
    }

    /// Once recorded, archive identity cannot be replaced, even after a failure.
    /// Retry must fingerprint and reuse this exact file and delivery ID.
    public mutating func recordPreparedArchive(deliveryID: UUID, relativePath: String, sha256: String,
                                               byteCount: Int64, now: Date = Date()) throws {
        let archive = AutomaticDeliveryArchive(relativePath: relativePath, sha256: sha256, byteCount: byteCount)
        try Self.validateArchive(archive)
        try mutateJob(deliveryID, now: now) { job, _ in
            if let previous = job.archive {
                guard previous == archive else { throw AutomaticDeliveryLedgerError.invalidArchive }
                return
            }
            guard job.state == .preparing else { throw AutomaticDeliveryLedgerError.invalidTransition }
            job.archive = archive
            job.state = .queued
            job.nextAttemptAt = nil
        }
    }

    public mutating func beginUpload(deliveryID: UUID, now: Date = Date()) throws {
        try mutateJob(deliveryID, now: now) { job, date in
            try Self.requireReady(job, at: date)
            guard job.archive != nil else { throw AutomaticDeliveryLedgerError.invalidArchive }
            job.attemptCount += 1
            job.state = .uploading
            job.nextAttemptAt = nil
        }
    }

    /// Supply a bounded user-facing description, never a credential or request dump.
    /// Authentication rejection and exhausted attempts require explicit repair; the
    /// automatic scheduler cannot reset them or silently create another delivery.
    public mutating func recordFailure(deliveryID: UUID, statusCode: Int? = nil, message: String,
                                       now: Date = Date()) throws {
        try mutateJob(deliveryID, now: now) { job, date in
            guard job.state != .delivered, job.state != .blocked else {
                throw AutomaticDeliveryLedgerError.invalidTransition
            }
            Self.applyFailure(to: &job, statusCode: statusCode, message: message, at: date)
        }
    }

    public mutating func acceptReceipt(_ receipt: AutomaticDeliveryReceipt, forScope proposed: AutomaticDeliveryScope,
                                       now: Date = Date()) throws {
        try validate()
        try requireScope(proposed)
        try mutateJob(receipt.deliveryID, now: now) { job, _ in
            try Self.validateReceipt(receipt, for: job)
            if let previous = job.receipt {
                guard previous == receipt else { throw AutomaticDeliveryLedgerError.invalidReceipt }
                return
            }
            // A matching receipt may arrive after suspension, a retry timeout or
            // the final attempt becoming blocked. A receipt confirms storage; it
            // never resumes sending or rebinds this grant, even when blocked.
            // Require at least one persisted upload attempt in this exact grant.
            guard job.attemptCount > 0, job.archive != nil,
                  [.uploading, .retryWaiting, .queued, .blocked].contains(job.state) else {
                throw AutomaticDeliveryLedgerError.invalidTransition
            }
            job.receipt = receipt
            job.state = .delivered
            job.nextAttemptAt = nil
            job.lastError = nil
        }
    }

    /// Retained background URLSession tasks remain in-flight. Interrupted attempts
    /// retain their archive/delivery identity and enter the ordinary backoff path.
    public mutating func recoverInterruptedJobs(activeDeliveryIDs: Set<UUID> = [], now: Date = Date()) throws {
        try validate()
        let date = try Self.validatedDate(now)
        var candidate = self
        for index in candidate.jobs.indices {
            guard !activeDeliveryIDs.contains(candidate.jobs[index].id),
                  [.preparing, .uploading].contains(candidate.jobs[index].state) else { continue }
            Self.applyFailure(to: &candidate.jobs[index], statusCode: nil,
                              message: "上次交付中断，将自动重试。", at: date)
            candidate.jobs[index].updatedAt = date
        }
        try candidate.validate()
        self = candidate
    }

    public static func retryDelay(afterAttempt attempt: Int) -> TimeInterval {
        min(3_600, 15 * pow(2, Double(min(max(attempt, 1), 9) - 1)))
    }

    public func save(to url: URL) throws { try persist(to: url) }

    /// Uses an exclusive temporary regular file, fsync, atomic rename and directory
    /// fsync. The final directory and ledger file cannot be symlinks. Never stores
    /// source audio or modifies a recording repository or its transfer receipts.
    public func persist(to url: URL) throws {
        try validate()
        let data = try TransportCodec.encode(self)
        guard data.count <= Self.maximumLedgerBytes else { throw AutomaticDeliveryLedgerError.capacityExceeded }
        let directory = url.deletingLastPathComponent()
        let descriptor = try Self.openDirectory(for: url, create: true)
        defer { Darwin.close(descriptor) }
        try Self.requireRegularDestination(url.lastPathComponent, in: descriptor, allowMissing: true)
        let temporaryName = ".automatic-delivery-" + UUID().uuidString.lowercased() + ".tmp"
        let temporaryURL = directory.appendingPathComponent(temporaryName)
        let temporaryDescriptor = Darwin.openat(descriptor, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard temporaryDescriptor >= 0 else { throw AutomaticDeliveryLedgerError.unsafeFile }
        defer {
            Darwin.close(temporaryDescriptor)
            Darwin.unlinkat(descriptor, temporaryName, 0)
        }
        let handle = FileHandle(fileDescriptor: temporaryDescriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        #if os(iOS) || os(watchOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                             ofItemAtPath: temporaryURL.path)
        #else
        _ = temporaryURL
        #endif
        try handle.synchronize()
        try Self.requireRegularDestination(url.lastPathComponent, in: descriptor, allowMissing: true)
        guard Darwin.renameat(descriptor, temporaryName, descriptor, url.lastPathComponent) == 0,
              Darwin.fsync(descriptor) == 0 else { throw AutomaticDeliveryLedgerError.unsafeFile }
    }

    public static func load(from url: URL, expectedScope: AutomaticDeliveryScope) throws -> AutomaticDeliveryLedger {
        try validateScope(expectedScope)
        let directoryDescriptor = try openDirectory(for: url, create: false)
        defer { Darwin.close(directoryDescriptor) }
        let descriptor = Darwin.openat(directoryDescriptor, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw AutomaticDeliveryLedgerError.unsafeFile }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size > 0, information.st_size <= maximumLedgerBytes else {
            throw AutomaticDeliveryLedgerError.unsafeFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: maximumLedgerBytes + 1),
              !data.isEmpty, data.count <= maximumLedgerBytes else { throw AutomaticDeliveryLedgerError.unsafeFile }
        let ledger = try TransportCodec.decode(Self.self, from: data)
        try ledger.validate()
        try ledger.requireScope(expectedScope)
        return ledger
    }

    public func validate() throws {
        guard schemaVersion == 1 || schemaVersion == 2 else { throw AutomaticDeliveryLedgerError.unsupportedVersion }
        try Self.validateScope(scope)
        guard schemaVersion != 2 || (selectedExistingIDs == baselineIDs && includeFuture) else {
            throw AutomaticDeliveryLedgerError.invalidAuthorization
        }
        guard Self.isSafeCanonicalDate(createdAt), selectedExistingIDs.isSubset(of: baselineIDs),
              eligibleFutureIDs.isDisjoint(with: baselineIDs), includeFuture || eligibleFutureIDs.isEmpty else {
            throw AutomaticDeliveryLedgerError.invalidAuthorization
        }
        guard baselineIDs.count <= Self.maximumAuthorizedRecordings,
              authorizedIDs.count <= Self.maximumAuthorizedRecordings, jobs.count <= Self.maximumJobs else {
            throw AutomaticDeliveryLedgerError.capacityExceeded
        }
        var deliveryIDs: Set<UUID> = []
        var originals: [UUID: SegmentManifest] = [:]
        var versions: [UUID: Set<String>] = [:]
        var archivePaths: Set<String> = []
        let authorized = authorizedIDs
        for job in jobs {
            guard deliveryIDs.insert(job.id).inserted, job.scope == scope,
                  authorized.contains(job.manifest.id), Self.isSafeCanonicalDate(job.createdAt),
                  Self.isSafeCanonicalDate(job.updatedAt), job.createdAt >= createdAt,
                  job.updatedAt >= job.createdAt, (0...Self.maximumAttempts).contains(job.attemptCount),
                  job.lastError.map({ $0.utf8.count <= 2_048 && $0.count <= 512 }) ?? true else {
                throw AutomaticDeliveryLedgerError.invalidLedger
            }
            try Self.validateManifest(job.manifest)
            if let previous = originals[job.manifest.id], previous != job.manifest {
                throw AutomaticDeliveryLedgerError.changedManifest
            }
            originals[job.manifest.id] = job.manifest
            if let hash = job.transcriptSHA256, !Self.isDigest(hash) { throw AutomaticDeliveryLedgerError.invalidLedger }
            guard versions[job.manifest.id, default: []].insert(job.transcriptSHA256 ?? "").inserted else {
                throw AutomaticDeliveryLedgerError.invalidLedger
            }
            if let archive = job.archive {
                try Self.validateArchive(archive)
                // The default Apple filesystem is case-insensitive. Distinct jobs
                // must not reference names which resolve to the same ZIP there.
                guard archivePaths.insert(archive.relativePath.lowercased()).inserted else { throw AutomaticDeliveryLedgerError.invalidArchive }
            }
            if let nextAttemptAt = job.nextAttemptAt {
                guard Self.isSafeCanonicalDate(nextAttemptAt), nextAttemptAt >= job.updatedAt,
                      job.state == .retryWaiting else { throw AutomaticDeliveryLedgerError.invalidLedger }
            }
            switch job.state {
            case .queued:
                guard job.nextAttemptAt == nil, job.receipt == nil,
                      job.attemptCount < Self.maximumAttempts else { throw AutomaticDeliveryLedgerError.invalidLedger }
            case .preparing:
                guard job.archive == nil, job.nextAttemptAt == nil, job.receipt == nil,
                      job.attemptCount < Self.maximumAttempts else { throw AutomaticDeliveryLedgerError.invalidLedger }
            case .uploading:
                guard job.archive != nil, job.attemptCount > 0, job.nextAttemptAt == nil,
                      job.receipt == nil else { throw AutomaticDeliveryLedgerError.invalidLedger }
            case .retryWaiting:
                guard job.nextAttemptAt != nil, job.receipt == nil, job.attemptCount > 0,
                      job.attemptCount < Self.maximumAttempts else { throw AutomaticDeliveryLedgerError.invalidLedger }
            case .delivered:
                guard let receipt = job.receipt, job.attemptCount > 0,
                      job.nextAttemptAt == nil else { throw AutomaticDeliveryLedgerError.invalidLedger }
                try Self.validateReceipt(receipt, for: job)
            case .blocked:
                guard job.receipt == nil, job.nextAttemptAt == nil,
                      job.attemptCount > 0 else { throw AutomaticDeliveryLedgerError.invalidLedger }
            }
        }
    }

    private mutating func mutateJob(_ deliveryID: UUID, now: Date,
                                    _ mutation: (inout AutomaticDeliveryJob, Date) throws -> Void) throws {
        try validate()
        let date = try Self.validatedDate(now)
        guard let index = jobs.firstIndex(where: { $0.id == deliveryID }) else { throw AutomaticDeliveryLedgerError.unknownDelivery }
        guard date >= jobs[index].createdAt else { throw AutomaticDeliveryLedgerError.invalidLedger }
        var candidate = self
        let before = candidate.jobs[index]
        try mutation(&candidate.jobs[index], date)
        if candidate.jobs[index] != before { candidate.jobs[index].updatedAt = date }
        try candidate.validate()
        self = candidate
    }

    private static func requireReady(_ job: AutomaticDeliveryJob, at date: Date) throws {
        guard [.queued, .retryWaiting].contains(job.state), job.attemptCount < maximumAttempts else {
            throw AutomaticDeliveryLedgerError.invalidTransition
        }
        if let next = job.nextAttemptAt, next > date { throw AutomaticDeliveryLedgerError.retryNotDue }
    }

    private static func applyFailure(to job: inout AutomaticDeliveryJob, statusCode: Int?, message: String, at date: Date) {
        if job.state != .uploading { job.attemptCount = min(maximumAttempts, job.attemptCount + 1) }
        job.lastError = String(message.prefix(512))
        if statusCode == 401 || statusCode == 403 || job.attemptCount >= maximumAttempts {
            job.state = .blocked
            job.nextAttemptAt = nil
        } else {
            job.state = .retryWaiting
            job.nextAttemptAt = canonical(date.addingTimeInterval(retryDelay(afterAttempt: job.attemptCount)))
        }
    }

    private static func validateReceipt(_ receipt: AutomaticDeliveryReceipt, for job: AutomaticDeliveryJob) throws {
        guard receipt.schemaVersion == 1, receipt.receiverID == job.scope.receiverID,
              receipt.deliveryID == job.id, let archive = job.archive,
              receipt.archiveSHA256 == archive.sha256, receipt.recordingIDs == [job.manifest.id],
              isSafeCanonicalDate(receipt.storedAt) else { throw AutomaticDeliveryLedgerError.invalidReceipt }
    }

    private static func validateScope(_ scope: AutomaticDeliveryScope) throws {
        guard scope.endpoint.utf8.count <= 2_048,
              let components = URLComponents(string: scope.endpoint), components.scheme == "https",
              let host = components.host, !host.isEmpty, components.url != nil,
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, components.port.map({ (1...65_535).contains($0) }) ?? true,
              isDigest(scope.certificateSHA256) else { throw AutomaticDeliveryLedgerError.invalidAuthorization }
    }

    private static func validateManifest(_ manifest: SegmentManifest) throws {
        guard manifest.schemaVersion == 1, manifest.sequence >= 0,
              manifest.sampleRate.isFinite, manifest.sampleRate > 0,
              manifest.frameCount > 0, manifest.byteCount > 0,
              isSafeCanonicalDate(manifest.startedAt), isSafeCanonicalDate(manifest.endedAt),
              manifest.endedAt >= manifest.startedAt,
              manifest.fileName == manifest.id.uuidString.lowercased() + ".caf",
              isDigest(manifest.sha256) else { throw AutomaticDeliveryLedgerError.changedManifest }
    }

    private static func validateArchive(_ archive: AutomaticDeliveryArchive) throws {
        let path = archive.relativePath
        guard !path.isEmpty, path.utf8.count <= 255, !path.hasPrefix("."), path.hasSuffix(".zip"),
              path.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
              isDigest(archive.sha256), archive.byteCount > 0, archive.byteCount <= maximumArchiveBytes else {
            throw AutomaticDeliveryLedgerError.invalidArchive
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isSafeCanonicalDate(_ date: Date) -> Bool {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        return milliseconds.isFinite && milliseconds >= 0 && milliseconds <= 253_402_300_799_999 && canonical(date) == date
    }

    fileprivate static func canonical(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    private static func validatedDate(_ date: Date) throws -> Date {
        let result = canonical(date)
        guard isSafeCanonicalDate(result) else { throw AutomaticDeliveryLedgerError.invalidLedger }
        return result
    }

    private static func openDirectory(for url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL, !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".", url.lastPathComponent != "..",
              !url.hasDirectoryPath else { throw AutomaticDeliveryLedgerError.unsafeFile }
        let directory = url.deletingLastPathComponent()
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AutomaticDeliveryLedgerError.unsafeFile }
        #if os(iOS) || os(watchOS)
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                 ofItemAtPath: directory.path)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        #endif
        return descriptor
    }

    private static func requireRegularDestination(_ name: String, in directory: Int32, allowMissing: Bool) throws {
        var information = stat()
        if Darwin.fstatat(directory, name, &information, AT_SYMLINK_NOFOLLOW) != 0 {
            if allowMissing && errno == ENOENT { return }
            throw AutomaticDeliveryLedgerError.unsafeFile
        }
        guard information.st_mode & S_IFMT == S_IFREG else { throw AutomaticDeliveryLedgerError.unsafeFile }
    }
}
