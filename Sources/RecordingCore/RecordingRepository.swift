import Foundation
import CryptoKit
import Darwin

public enum RepositoryError: LocalizedError, Equatable {
    case invalidManifest(String)
    case checksumMismatch
    case conflictingSegment
    case receiptMismatch
    case missingAudio
    case invalidStagingPath
    case persistenceFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): return "录音清单无效：\(reason)"
        case .checksumMismatch: return "音频完整性校验失败，保留原文件等待重传。"
        case .conflictingSegment: return "同一片段出现不同内容，已拒绝覆盖。"
        case .receiptMismatch: return "接收确认与原始片段不一致，未清理表端音频。"
        case .missingAudio: return "录音清单对应的音频文件缺失。"
        case .invalidStagingPath: return "录音临时文件路径无效。"
        case .persistenceFailure(let detail): return "保存失败：\(detail)"
        }
    }
}

/// Fault boundaries exercise the same on-disk recovery used after process termination.
public enum RepositoryFaultPoint: Sendable {
    case afterAudioCommit, afterManifestCommit, beforeReceiptCommit, afterReceiptWriteBeforeSync
    case beforeAcknowledgementCommit, beforeAcknowledgementSync
    case beforeFreshAppend, afterFreshAppend, beforeFreshHeadCommit, afterFreshHeadCommit
    case beforeFreshCaptureCommit, beforeFreshCloseCommit, afterFreshCloseCommit
    case beforePreemptionIntentCommit, afterPreemptionIntentWriteBeforeSync
}

public enum RepositoryRecoveryFailureHandling: Sendable {
    case strict
    /// Keep damaged historical transactions available for diagnosis while allowing capture.
    case preserveAndReport
}

public struct RecordingInventoryIssue: Equatable, Sendable {
    public let fileName: String
    public let reason: String
}

/// A best-effort history snapshot, never authority to acknowledge or delete audio.
public struct RecordingInventory: Sendable {
    public let sessions: [RecordingSession]
    public let manifests: [SegmentManifest]
    public let issues: [RecordingInventoryIssue]
}

/// Existing metadata for diagnosis, never authority to acknowledge or delete audio.
/// The stored hashes and receipts are historical records, not a new content check.
public struct RecordingMetadataSnapshot: Sendable {
    public let manifests: [SegmentManifest]
    public let receipts: [SegmentReceipt]
    public let events: [RecordingEvent]
    public let eventSelection: RecordingDiagnosticEventSelection
}

/// A locked metadata catalogue for transfer evidence, never a content audit.
/// An acknowledgement here is historical JSON, not a new durability confirmation.
/// No events, audio, file synchronization, transaction recovery or repair is read/run.
public struct RecordingTransferEvidenceSnapshot: Sendable {
    public let manifests: [SegmentManifest]
    public let receipts: [SegmentReceipt]
    public let acknowledgements: [SegmentReceipt]
}

/// Returned only after the exact receipt is durable and requested cleanup succeeds.
/// These flags describe actual content changes, not receipt arrival or transport progress.
public struct AcknowledgementResult: Equatable, Sendable {
    public let acknowledgementChanged: Bool
    public let audioPruned: Bool
    public var didChange: Bool { acknowledgementChanged || audioPruned }
}

/// Fixed operation names only; never receipt authority, paths or file contents.
public enum AcknowledgementOperation: String, Codable, Sendable {
    case manifestRead = "manifest_read", manifestValidate = "manifest_validate"
    case receiptValidate = "receipt_validate", acknowledgementWrite = "ack_write"
    case acknowledgementProtection = "ack_protection", acknowledgementFileSync = "ack_file_sync"
    case acknowledgementDirectorySync = "ack_directory_sync"
    case audioPrune = "audio_prune", audioDirectorySync = "audio_directory_sync"
}

public struct TransferCandidateBatch: Sendable {
    public let ids: [UUID]
    public let bootstrapCount: Int?
    public let bootstrapDuration: TimeInterval
    /// Scheduling evidence for this bounded page, never receipt/audio authority.
    public let indexStamp: String?
    public let recordCount: Int
    public let selectedRecordCount: Int
    public let startCursor: Int
    public let nextCursor: Int
    public let cursorSteps: Int
}

/// All mutations are serialized. A transport ACK is issued only after audio, manifest,
/// and receipt are written and synchronized. Call from a non-real-time serial queue.
public final class RecordingRepository: @unchecked Sendable {
    public let root: URL
    private let lock = NSRecursiveLock()
    private let fm = FileManager.default
    private let faultInjector: ((RepositoryFaultPoint) throws -> Void)?
    private let recoveryFailureHandling: RepositoryRecoveryFailureHandling
    private var transactionRecoveryIssues: [RecordingInventoryIssue] = []
    private var diagnosticEventIndex: RecordingDiagnosticEventIndex?
    var freshPriorityFailure: String?
    var freshFault: ((RepositoryFaultPoint) throws -> Void)? { faultInjector }
    private var audioDirectory: URL { root.appendingPathComponent("segments", isDirectory: true) }
    private var stagingDirectory: URL { root.appendingPathComponent("staging", isDirectory: true) }
    private var manifestsDirectory: URL { root.appendingPathComponent("manifests", isDirectory: true) }
    private var sessionsDirectory: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    private var receiptsDirectory: URL { root.appendingPathComponent("receipts", isDirectory: true) }
    private var acknowledgementsDirectory: URL { root.appendingPathComponent("acknowledgements", isDirectory: true) }
    private var eventsDirectory: URL { root.appendingPathComponent("events", isDirectory: true) }

    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WristRecord", isDirectory: true)
    }

    public init(root: URL, faultInjector: ((RepositoryFaultPoint) throws -> Void)? = nil,
                recoveryFailureHandling: RepositoryRecoveryFailureHandling = .strict,
                recoverTransactionsOnInitialization: Bool = true) throws {
        self.root = root.standardizedFileURL
        self.faultInjector = faultInjector
        self.recoveryFailureHandling = recoveryFailureHandling
        for directory in [self.root, audioDirectory, stagingDirectory, manifestsDirectory,
                          sessionsDirectory, receiptsDirectory, acknowledgementsDirectory, eventsDirectory] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try applyFileProtection(directory)
        }
        if recoverTransactionsOnInitialization {
            try recoverTransactions(failureHandling: recoveryFailureHandling)
        }
    }

    public func createSession(at date: Date = Date()) throws -> RecordingSession {
        let session = RecordingSession(startedAt: date)
        try saveSession(session)
        return session
    }

    public func saveSession(_ session: RecordingSession) throws {
        try synchronized { try persist(session, at: jsonURL(session.id, in: sessionsDirectory)) }
    }

    public func sessions() throws -> [RecordingSession] {
        try synchronized {
            try loadAll(RecordingSession.self, from: sessionsDirectory).sorted { $0.startedAt < $1.startedAt }
        }
    }

    /// Parse each historical item independently. Directory failures still throw, since
    /// an unreadable library must not be mistaken for an empty one. These atomic-file
    /// reads deliberately do not hold the recording mutation lock for the full scan.
    public func recordingInventory() throws -> RecordingInventory {
        var issues = synchronized { transactionRecoveryIssues }
        var validSessions: [RecordingSession] = []
        var validManifests: [SegmentManifest] = []
        for url in try jsonFiles(in: sessionsDirectory) {
            do {
                let session = try load(RecordingSession.self, at: url)
                // Directory enumeration can resolve /var to /private/var while
                // root retains its original alias. Validate the identity-bearing
                // filename within this known directory, not URL representation.
                guard url.lastPathComponent == session.id.uuidString.lowercased() + ".json",
                      [session.startedAt, session.updatedAt].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
                      [session.endedAt, session.lastAudioAt, session.lastSealedAt, session.currentSegmentStartedAt]
                        .compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }) else {
                    throw RepositoryError.invalidManifest("会话标识或时间不合法")
                }
                validSessions.append(session)
            } catch { issues.append(inventoryIssue(for: url, error: error)) }
        }
        for url in try jsonFiles(in: manifestsDirectory) {
            do {
                let manifest = try load(SegmentManifest.self, at: url)
                try validate(manifest)
                guard url.lastPathComponent == manifest.id.uuidString.lowercased() + ".json" else {
                    throw RepositoryError.invalidManifest("清单文件名与片段标识不一致")
                }
                validManifests.append(manifest)
            } catch { issues.append(inventoryIssue(for: url, error: error)) }
        }
        return RecordingInventory(sessions: validSessions.sorted { $0.startedAt < $1.startedAt },
            manifests: sortedManifests(validManifests), issues: issues)
    }

    /// Retry preserved transactions before starting capture or rebuilding open audio.
    /// The configured policy applies again; successful retries clear their old issues.
    public func recoverPendingTransactions() throws {
        try synchronized {
            transactionRecoveryIssues = []
            try recoverTransactions(failureHandling: recoveryFailureHandling)
        }
    }

    public func stagingURL(for id: UUID) -> URL {
        stagingDirectory.appendingPathComponent(id.uuidString.lowercased() + ".caf")
    }

    public func audioURL(for manifest: SegmentManifest) -> URL {
        // Deliberately derive from UUID instead of trusting the transmitted fileName.
        audioDirectory.appendingPathComponent(manifest.id.uuidString.lowercased() + ".caf")
    }

    public func sealSegment(stagedURL: URL, id: UUID, sessionID: UUID, sequence: Int,
                            startedAt: Date, endedAt: Date, sampleRate: Double,
                            frameCount: Int64, timeZoneIdentifier: String? = nil,
                            location: SegmentLocation? = nil, recordingGroup: RecordingGroup? = nil) throws -> SegmentManifest {
        try synchronized {
            guard stagedURL.standardizedFileURL == stagingURL(for: id).standardizedFileURL else {
                throw RepositoryError.invalidStagingPath
            }
            try synchronizeFile(stagedURL)
            let fingerprint = try Self.fingerprint(of: stagedURL)
            let manifest = SegmentManifest(id: id, sessionID: sessionID, sequence: sequence,
                startedAt: startedAt, endedAt: endedAt, sampleRate: sampleRate,
                frameCount: frameCount, fileName: id.uuidString.lowercased() + ".caf",
                byteCount: fingerprint.byteCount, sha256: fingerprint.sha256,
                timeZoneIdentifier: timeZoneIdentifier, location: location, recordingGroup: recordingGroup)
            try validate(manifest)
            try commitAudio(at: stagedURL, manifest: manifest)
            noteTransferSourceProvenance(manifest, category: .normal)
            return manifest
        }
    }

    public func manifests() throws -> [SegmentManifest] {
        let values = try loadAll(SegmentManifest.self, from: manifestsDirectory)
        try values.forEach(validate)
        return sortedManifests(values)
    }

    /// Exact-ID metadata lookup used during a short background callback.
    public func manifest(id: UUID) throws -> SegmentManifest {
        try synchronized {
            let value = try load(SegmentManifest.self, at: jsonURL(id, in: manifestsDirectory))
            try validate(value)
            guard value.id == id else { throw RepositoryError.conflictingSegment }
            return value
        }
    }

    /// A hint never substitutes for the current manifest, ACK, or source file.
    public func pendingSegment(id: UUID) throws -> SegmentManifest? {
        try synchronized {
            let value = try manifest(id: id)
            if try hasDurableAcknowledgement(for: value) { return nil }
            let audio = audioURL(for: value)
            guard fm.fileExists(atPath: audio.path) else { throw RepositoryError.missingAudio }
            let size = try fm.attributesOfItem(atPath: audio.path)[.size] as? NSNumber
            guard size?.int64Value == value.byteCount else { throw RepositoryError.checksumMismatch }
            return value
        }
    }

    /// Keep the exact manifest and missing-ACK check stable while the transport
    /// owner commits a cancellation intent. Hashing belongs outside this lock.
    @discardableResult
    public func withPendingTransfer(_ manifest: SegmentManifest, _ body: () throws -> Void) throws -> Bool {
        try synchronized {
            guard try pendingSegment(id: manifest.id) == manifest else { return false }
            try body()
            return true
        }
    }

    private var transferCandidateURL: URL { root.appendingPathComponent("transfer-candidates.ids") }
    private var transferCandidateReadyURL: URL { root.appendingPathComponent("transfer-candidates.ready") }
    private var transferCandidateCursorURL: URL { root.appendingPathComponent("transfer-candidates.cursor") }
    private static let candidateRecordSize = 37 // canonical UUID and one newline

    /// Rebuild only in ordinary maintenance, after a complete pending scan.
    /// The repository lock prevents a newly sealed hint being overwritten.
    @discardableResult
    public func refreshTransferCandidates(while shouldContinue: () -> Bool = { true }) throws -> [SegmentManifest]? {
        try synchronized {
            var pending: [SegmentManifest] = []
            for url in try jsonFiles(in: manifestsDirectory) {
                // A WK task can revoke maintenance while this scan is running.
                // Stop between individual metadata reads, without publishing a
                // partial snapshot or replacing the complete candidate baseline.
                guard shouldContinue() else { return nil }
                let value = try load(SegmentManifest.self, at: url)
                try validate(value)
                if try isPending(value) { pending.append(value) }
            }
            guard shouldContinue() else { return nil }
            pending = sortedManifests(pending)
            try writeTransferCandidates(pending.map(\.id))
            return pending
        }
    }

    public func invalidateTransferCandidates() throws {
        try synchronized {
            if try RecordingMetadataAccess.exists(at: transferCandidateReadyURL) {
                try fm.removeItem(at: transferCandidateReadyURL)
            }
        }
    }

    private func candidateScalarIfPresent(at url: URL) throws -> Data? {
        do { return try RecordingMetadataAccess.readIfPresent(at: url, maximumBytes: 128) }
        catch RecordingMetadataAccessError.sizeLimitExceeded {
            // Oversized scalar contents are a malformed hint, like bad UTF-8 or
            // a non-number. Access failures are never converted to this value.
            return Data()
        }
    }

    private func writeTransferCandidates(_ ids: [UUID]) throws {
        let data = Data(ids.map { $0.uuidString.lowercased() + "\n" }.joined().utf8)
        try data.write(to: transferCandidateURL, options: .atomic)
        try synchronizeFile(transferCandidateURL)
        try Data("0".utf8).write(to: transferCandidateCursorURL, options: .atomic)
        try Data(String(data.count).utf8).write(to: transferCandidateReadyURL, options: .atomic)
        try synchronizeDirectory(root)
    }

    /// Write before publishing a manifest. A crash may leave an extra hint, but
    /// cannot publish new audio without its hint. Recovery repeats the append.
    private func appendTransferCandidate(_ id: UUID) throws {
        var marker = try candidateScalarIfPresent(at: transferCandidateReadyURL)
        if try !RecordingMetadataAccess.exists(at: transferCandidateURL) {
            // A surviving marker cannot make a newly created tail-only file a
            // complete historical baseline after cache deletion.
            try invalidateTransferCandidates()
            marker = nil
            guard fm.createFile(atPath: transferCandidateURL.path, contents: nil) else {
                throw RepositoryError.persistenceFailure("候选索引无法建立")
            }
        }
        let handle = try FileHandle(forWritingTo: transferCandidateURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if let markerData = marker {
            let baseline = String(data: markerData, encoding: .utf8).flatMap(UInt64.init)
            // Do not bless an earlier aligned truncation by replacing a larger
            // baseline with the shorter size after appending a fresh tail.
            if baseline == nil || baseline! > size || baseline! % UInt64(Self.candidateRecordSize) != 0 {
                try invalidateTransferCandidates()
                marker = nil
            }
        }
        if size % UInt64(Self.candidateRecordSize) != 0 {
            // Discard only a torn hint suffix. The source manifests remain intact.
            try handle.truncate(atOffset: size - size % UInt64(Self.candidateRecordSize))
            try handle.seekToEnd()
            try invalidateTransferCandidates()
            marker = nil
        }
        try handle.write(contentsOf: Data((id.uuidString.lowercased() + "\n").utf8))
        try handle.synchronize()
        if marker != nil {
            let completeSize = try handle.seekToEnd()
            try Data(String(completeSize).utf8).write(to: transferCandidateReadyURL, options: .atomic)
            try synchronizeFile(transferCandidateReadyURL)
        }
        try synchronizeDirectory(root)
    }

    /// At most `limit` UUID records are read: newest two first, then a persisted
    /// historical cursor. Bootstrap enumerates filenames only, never all JSON or
    /// audio. Its cost is reported separately, and is not a pending-count proof.
    public func transferCandidateBatch(limit: Int = 8) throws -> TransferCandidateBatch {
        try synchronized {
            let limit = max(0, min(limit, 64))
            guard limit > 0 else { return TransferCandidateBatch(ids: [], bootstrapCount: nil, bootstrapDuration: 0,
                indexStamp: nil, recordCount: 0, selectedRecordCount: 0, startCursor: 0, nextCursor: 0, cursorSteps: 0) }
            let started = Date()
            var bootstrapCount: Int?
            let size = ((try RecordingMetadataAccess.attributesIfPresent(at: transferCandidateURL))?[.size] as? NSNumber)?.uint64Value
            let marker = try candidateScalarIfPresent(at: transferCandidateReadyURL)
            // Read before a rebuild can replace the cursor. A protected or
            // temporarily unavailable cursor is not permission to reset it.
            var cursorData = try candidateScalarIfPresent(at: transferCandidateCursorURL)
            let baselineSize = marker.flatMap { String(data: $0, encoding: .utf8) }.flatMap(UInt64.init)
            let ready = baselineSize.map { $0 % UInt64(Self.candidateRecordSize) == 0 && (size ?? 0) >= $0 } ?? false
            if !ready || size == nil || size! % UInt64(Self.candidateRecordSize) != 0 {
                // Retain recent append hints after a missing-baseline bootstrap.
                let previousTail: [UUID]
                do { previousTail = try readCandidateRecords(indices: candidateTailIndices(size: size ?? 0, limit: 2)) }
                catch {
                    guard error is RepositoryError || RecordingMetadataAccess.isMissing(error) else { throw error }
                    previousTail = []
                }
                let names = try jsonFiles(in: manifestsDirectory).compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
                let existingIDs = Set(names)
                // A missing manifest hint must not survive every bootstrap and
                // repeatedly reset the historical cursor to its first page.
                let tail = previousTail.filter { existingIDs.contains($0) }
                let tailSet = Set(tail)
                let ids = names.filter { !tailSet.contains($0) } + tail.reversed()
                try writeTransferCandidates(ids)
                cursorData = Data("0".utf8)
                bootstrapCount = names.count
            }
            let actualSize = (try fm.attributesOfItem(atPath: transferCandidateURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
            let count = Int(actualSize / UInt64(Self.candidateRecordSize))
            guard count > 0 else {
                return TransferCandidateBatch(ids: [], bootstrapCount: bootstrapCount,
                                              bootstrapDuration: bootstrapCount == nil ? 0 : Date().timeIntervalSince(started),
                    indexStamp: try transferCandidateStamp(), recordCount: 0, selectedRecordCount: 0,
                    startCursor: 0, nextCursor: 0, cursorSteps: 0)
            }
            var cursor = max(0, Int(cursorData.flatMap { String(data: $0, encoding: .utf8) } ?? "0") ?? 0) % count
            let startCursor = cursor
            var cursorSteps = 0
            var indices = candidateTailIndices(size: actualSize, limit: min(2, limit))
            while indices.count < min(count, limit) {
                if !indices.contains(cursor) { indices.append(cursor) }
                cursor = (cursor + 1) % count
                cursorSteps += 1
            }
            do {
                let ids = try readCandidateRecords(indices: indices)
                try Data(String(cursor).utf8).write(to: transferCandidateCursorURL, options: .atomic)
                return TransferCandidateBatch(ids: ids.reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } },
                    bootstrapCount: bootstrapCount, bootstrapDuration: bootstrapCount == nil ? 0 : Date().timeIntervalSince(started),
                    indexStamp: try transferCandidateStamp(), recordCount: count, selectedRecordCount: indices.count,
                    startCursor: startCursor, nextCursor: cursor, cursorSteps: cursorSteps)
            } catch {
                // A malformed hint never becomes empty-library evidence. Next
                // opportunity bootstraps filenames; the current pass does no fill.
                if error is RepositoryError || RecordingMetadataAccess.isMissing(error) {
                    try invalidateTransferCandidates()
                }
                throw error
            }
        }
    }

    /// O(1) generation fence for a scheduling hint, including a concurrent new
    /// fresh owner. Atime is excluded; an index replacement/append is a new pass.
    private func transferCandidateStamp() throws -> String {
        let paths = [transferCandidateURL, transferCandidateReadyURL, manifestsDirectory, acknowledgementsDirectory,
            root.appendingPathComponent("fresh-transfer"),
            root.appendingPathComponent("fresh-transfer/state.json"),
            root.appendingPathComponent("fresh-transfer.initialized")]
        return try paths.map { url in
            var value = stat()
            guard Darwin.lstat(url.path, &value) == 0 else {
                if errno == ENOENT { return "absent" }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let kind = value.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else {
                throw RepositoryError.persistenceFailure("同步候选索引身份不合法")
            }
            return [String(value.st_dev), String(value.st_ino), String(value.st_mode),
                String(value.st_nlink), String(value.st_size), String(value.st_mtimespec.tv_sec),
                String(value.st_mtimespec.tv_nsec), String(value.st_ctimespec.tv_sec),
                String(value.st_ctimespec.tv_nsec)].joined(separator: ":")
        }.joined(separator: "|")
    }

    /// Recheck the exact candidate generation/cursor under the mutation lock.
    /// Only permits changing a refresh hint; never ACKs, hashes, or prunes audio.
    @discardableResult
    public func withCurrentTransferCandidateBatch(_ batch: TransferCandidateBatch,
                                                  _ body: () throws -> Void) throws -> Bool {
        guard let stamp = batch.indexStamp else { return false }
        return try withCurrentTransferCandidateCheckpoint(indexStamp: stamp,
            recordCount: batch.recordCount, nextCursor: batch.nextCursor, body)
    }

    /// A completed cache sweep is only a scheduling hint. Revalidate it in O(1)
    /// before suppressing another empty pass. Repository manifest/ACK writes use
    /// atomic replacement, so their directory generations revoke this hint too.
    @discardableResult
    public func withCurrentTransferCandidateCheckpoint(indexStamp: String, recordCount: Int,
            nextCursor: Int, _ body: () throws -> Void) throws -> Bool {
        try synchronized {
            guard recordCount >= 0, indexStamp == (try transferCandidateStamp()) else { return false }
            let size = (try fm.attributesOfItem(atPath: transferCandidateURL.path)[.size] as? NSNumber)?.uint64Value
            guard let size, size % UInt64(Self.candidateRecordSize) == 0,
                  size / UInt64(Self.candidateRecordSize) == UInt64(recordCount) else { return false }
            if recordCount > 0 {
                let data = try Data(contentsOf: transferCandidateCursorURL)
                let cursor = Int(String(data: data, encoding: .utf8) ?? "")
                guard cursor == nextCursor else { return false }
            } else if nextCursor != 0 { return false }
            try body()
            return true
        }
    }

    private func candidateTailIndices(size: UInt64, limit: Int) -> [Int] {
        let count = Int(size / UInt64(Self.candidateRecordSize))
        return (0..<min(count, limit)).map { count - 1 - $0 }
    }

    private func readCandidateRecords(indices: [Int]) throws -> [UUID] {
        guard !indices.isEmpty else { return [] }
        let handle = try FileHandle(forReadingFrom: transferCandidateURL)
        defer { try? handle.close() }
        return try indices.map { index in
            try handle.seek(toOffset: UInt64(index * Self.candidateRecordSize))
            guard let data = try handle.read(upToCount: Self.candidateRecordSize),
                  data.count == Self.candidateRecordSize, data.last == 10,
                  let text = String(data: data.dropLast(), encoding: .utf8),
                  let id = UUID(uuidString: text) else {
                throw RepositoryError.persistenceFailure("候选索引损坏，等待文件名重建")
            }
            return id
        }
    }

    public func manifests(while shouldContinue: () -> Bool) throws -> [SegmentManifest]? {
        var values: [SegmentManifest] = []
        for url in try jsonFiles(in: manifestsDirectory) {
            guard shouldContinue() else { return nil }
            let value = try load(SegmentManifest.self, at: url)
            try validate(value)
            values.append(value)
        }
        guard shouldContinue() else { return nil }
        return sortedManifests(values)
    }

    public func pendingSegments(while shouldContinue: () -> Bool) throws -> [SegmentManifest]? {
        guard let values = try manifests(while: shouldContinue) else { return nil }
        var pending: [SegmentManifest] = []
        for value in values {
            guard shouldContinue() else { return nil }
            if try isPending(value) { pending.append(value) }
        }
        guard shouldContinue() else { return nil }
        return pending
    }

    public func pendingSegments() throws -> [SegmentManifest] {
        try manifests().filter { try isPending($0) }
    }

    private func isPending(_ manifest: SegmentManifest) throws -> Bool {
        let receiptURL = jsonURL(manifest.id, in: acknowledgementsDirectory)
        if fm.fileExists(atPath: receiptURL.path) {
            let receipt = try load(SegmentReceipt.self, at: receiptURL)
            try validate(receipt, for: manifest)
            return false
        }
        guard fm.fileExists(atPath: audioURL(for: manifest).path) else {
            // acknowledge() writes the ACK before pruning. Re-read it if audio
            // disappeared after the first check, instead of reporting data loss.
            if fm.fileExists(atPath: receiptURL.path) {
                let receipt = try load(SegmentReceipt.self, at: receiptURL)
                try validate(receipt, for: manifest)
                return false
            }
            throw RepositoryError.missingAudio
        }
        return true
    }

    public func acceptIncomingFile(at temporaryURL: URL, manifest: SegmentManifest) throws -> SegmentReceipt {
        try synchronized {
            try validate(manifest)
            try verifyAudio(at: temporaryURL, manifest: manifest)
            try validatePendingTransaction(manifest)
            let existingURL = jsonURL(manifest.id, in: manifestsDirectory)
            if fm.fileExists(atPath: existingURL.path) {
                let existing = try load(SegmentManifest.self, at: existingURL)
                guard existing == manifest else { throw RepositoryError.conflictingSegment }
                do {
                    try verifyAudio(at: audioURL(for: existing), manifest: existing)
                } catch {
                    // The sender still has an unacknowledged valid copy. Repair a missing
                    // or damaged destination without changing the committed identity.
                    let staged = stagingURL(for: manifest.id)
                    if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
                    try fm.copyItem(at: temporaryURL, to: staged)
                    try applyFileProtection(staged)
                    try synchronizeFile(staged)
                    guard Darwin.rename(staged.path, audioURL(for: existing).path) == 0 else {
                        throw RepositoryError.persistenceFailure(String(cString: strerror(errno)))
                    }
                }
                // Re-establish durability even if a prior call wrote the visible files
                // and failed during synchronization before it could issue a receipt.
                try synchronizeFile(audioURL(for: existing))
                try synchronizeDirectory(audioDirectory)
                try persist(existing, at: existingURL)
            } else {
                let staged = stagingURL(for: manifest.id)
                // The framework owns its temporary URL. Copy before the callback returns.
                // A previous staging copy may exist after a failed transfer; only replace
                // it after this received file has passed the full integrity check above.
                if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
                try fm.copyItem(at: temporaryURL, to: staged)
                try applyFileProtection(staged)
                try synchronizeFile(staged)
                try commitAudio(at: staged, manifest: manifest)
            }
            let receiptURL = jsonURL(manifest.id, in: receiptsDirectory)
            if fm.fileExists(atPath: receiptURL.path) {
                let receipt = try load(SegmentReceipt.self, at: receiptURL)
                try validate(receipt, for: manifest)
                try persist(receipt, at: receiptURL)
                return receipt
            }
            try faultInjector?(.beforeReceiptCommit)
            let receipt = SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256,
                                         byteCount: manifest.byteCount)
            try persist(receipt, at: receiptURL)
            return receipt
        }
    }

    @discardableResult
    // The observer runs synchronously under the repository lock. It may record
    // the operation in memory only; it must not re-enter the repository.
    public func acknowledge(_ receipt: SegmentReceipt, pruneAudio: Bool = true,
                            observingOperation: ((AcknowledgementOperation) -> Void)? = nil) throws -> AcknowledgementResult {
        try synchronized {
            observingOperation?(.manifestRead)
            let manifest = try load(SegmentManifest.self, at: jsonURL(receipt.segmentID, in: manifestsDirectory))
            observingOperation?(.manifestValidate)
            try validate(manifest)
            observingOperation?(.receiptValidate)
            try validate(receipt, for: manifest)
            let acknowledgementURL = jsonURL(receipt.segmentID, in: acknowledgementsDirectory)
            // Read the current disk record on every call. An in-memory UUID cache
            // would hide a removed/corrupt ACK or changed local manifest.
            let existing = try? load(SegmentReceipt.self, at: acknowledgementURL)
            let changed = existing != receipt
            if changed {
                // A valid incoming receipt may repair a missing or damaged ACK,
                // but only after matching the current, valid local manifest above.
                observingOperation?(.acknowledgementWrite)
                try faultInjector?(.beforeAcknowledgementCommit)
                try persist(receipt, at: acknowledgementURL, observingAcknowledgementOperation: observingOperation)
            } else {
                // Visible identical bytes may follow an earlier failed fsync.
                // Re-establish durability without replacing the atomic file.
                try synchronizeAcknowledgement(at: acknowledgementURL, observingOperation: observingOperation)
            }
            var audioPruned = false
            if pruneAudio {
                if fm.fileExists(atPath: audioURL(for: manifest).path) {
                    observingOperation?(.audioPrune)
                    try fm.removeItem(at: audioURL(for: manifest))
                    audioPruned = true
                }
                // Also finish a prior unlink whose directory synchronization failed.
                observingOperation?(.audioDirectorySync)
                try synchronizeDirectory(audioDirectory)
            }
            return AcknowledgementResult(acknowledgementChanged: changed, audioPruned: audioPruned)
        }
    }

    /// Permission to cancel a duplicate transfer requires this exact committed
    /// manifest and a durable local ACK. Phone receipts or missing audio are not ACKs.
    public func hasDurableAcknowledgement(for manifest: SegmentManifest) throws -> Bool {
        try synchronized {
            let acknowledgementURL = jsonURL(manifest.id, in: acknowledgementsDirectory)
            guard fm.fileExists(atPath: acknowledgementURL.path) else { return false }
            try validate(manifest)
            let committed = try load(SegmentManifest.self, at: jsonURL(manifest.id, in: manifestsDirectory))
            try validate(committed)
            guard committed == manifest else { throw RepositoryError.conflictingSegment }
            let acknowledgement = try load(SegmentReceipt.self, at: acknowledgementURL)
            try validate(acknowledgement, for: committed)
            // A prior atomic write may have become visible before synchronization
            // failed. Establish durability again without touching pruned audio.
            try synchronizeAcknowledgement(at: acknowledgementURL)
            return true
        }
    }

    public func receipts() throws -> [SegmentReceipt] {
        try synchronized {
            let values = try loadAll(SegmentReceipt.self, from: receiptsDirectory)
            // Re-sending an old ACK is allowed only while its durable copy still exists.
            for receipt in values {
                let manifestURL = jsonURL(receipt.segmentID, in: manifestsDirectory)
                let manifest = try load(SegmentManifest.self, at: manifestURL)
                try validate(receipt, for: manifest)
                try verifyAudio(at: audioURL(for: manifest), manifest: manifest)
                try synchronizeFile(audioURL(for: manifest))
                try synchronizeDirectory(audioDirectory)
                try persist(manifest, at: manifestURL)
                try persist(receipt, at: jsonURL(receipt.segmentID, in: receiptsDirectory))
            }
            return values.sorted { $0.receivedAt < $1.receivedAt }
        }
    }

    /// Read one metadata snapshot under the repository mutation lock. This never
    /// opens audio, hashes content, synchronizes files, repairs or persists state.
    /// Any malformed JSON, identity mismatch or orphan receipt rejects the whole
    /// snapshot instead of silently exporting an apparently complete subset.
    /// Each metadata JSON must be an independent regular file of at most 1 MiB.
    public func metadataSnapshot() throws -> RecordingMetadataSnapshot {
        try synchronized {
            let manifests = try diagnosticMetadata(SegmentManifest.self, in: manifestsDirectory, id: { $0.id })
            try manifests.forEach(validate)
            let byID = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
            let receipts = try diagnosticMetadata(SegmentReceipt.self, in: receiptsDirectory, id: { $0.segmentID })
            for receipt in receipts {
                guard let manifest = byID[receipt.segmentID], receipt.receivedAt.timeIntervalSince1970.isFinite else {
                    throw RepositoryError.receiptMismatch
                }
                try validate(receipt, for: manifest)
            }
            let events = try diagnosticMetadata(RecordingEvent.self, in: eventsDirectory, id: { $0.id })
            for event in events {
                guard [event.timestamp, event.intervalStart, event.intervalEnd].compactMap({ $0 })
                    .allSatisfy({ $0.timeIntervalSince1970.isFinite }),
                      event.intervalStart == nil || event.intervalEnd == nil || event.intervalStart! <= event.intervalEnd! else {
                    throw RepositoryError.invalidManifest("事件时间不合法")
                }
            }
            return RecordingMetadataSnapshot(manifests: sortedManifests(manifests),
                receipts: receipts.sorted { $0.receivedAt < $1.receivedAt },
                events: events.sorted { $0.timestamp < $1.timestamp },
                eventSelection: .fullHistory(count: events.count))
        }
    }

    /// Read all identity-bearing transfer metadata under the mutation lock. Reject
    /// the whole catalogue on an orphan/mismatch or an aliased/malformed JSON;
    /// never silently turn a partial catalogue into complete-source evidence.
    public func transferEvidenceSnapshot() throws -> RecordingTransferEvidenceSnapshot {
        try synchronized {
            let manifests = try diagnosticMetadata(SegmentManifest.self, in: manifestsDirectory, id: { $0.id })
            try manifests.forEach(validate)
            let byID = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
            func readReceipts(_ directory: URL) throws -> [SegmentReceipt] {
                let values = try diagnosticMetadata(SegmentReceipt.self, in: directory, id: { $0.segmentID })
                for value in values {
                    guard let manifest = byID[value.segmentID], value.receivedAt.timeIntervalSince1970.isFinite else {
                        throw RepositoryError.receiptMismatch
                    }
                    try validate(value, for: manifest)
                }
                return values.sorted { $0.segmentID.uuidString < $1.segmentID.uuidString }
            }
            return RecordingTransferEvidenceSnapshot(manifests: sortedManifests(manifests),
                receipts: try readReceipts(receiptsDirectory),
                acknowledgements: try readReceipts(acknowledgementsDirectory))
        }
    }

    /// Exact metadata-only lookup for a successful ACK observer. Unlike the
    /// ordinary library loader, aliases and non-regular metadata are refused.
    public func transferEvidenceManifest(id: UUID) throws -> SegmentManifest {
        try synchronized {
            let descriptor = Darwin.open(manifestsDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
            defer { Darwin.close(descriptor) }
            let value = try diagnosticMetadataEntry(SegmentManifest.self, directory: descriptor,
                name: id.uuidString.lowercased() + ".json", id: { $0.id })
            try validate(value)
            return value
        }
    }

    /// Default diagnostics retain the same manifest/receipt checks, then read a
    /// bounded recent event selection without holding the recording mutation
    /// lock for the historical event enumeration or decoding. The two portions
    /// are observations at separate times, not a whole-library atomic snapshot.
    public func diagnosticMetadataSnapshot(at date: Date = Date(),
                                           while shouldContinue: () -> Bool = { true }) throws -> RecordingMetadataSnapshot {
        guard shouldContinue() else { throw CancellationError() }
        let metadata = try synchronized { () -> ([SegmentManifest], [SegmentReceipt]) in
            let manifests = try diagnosticMetadata(SegmentManifest.self, in: manifestsDirectory, id: { $0.id })
            try manifests.forEach(validate)
            let byID = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
            let receipts = try diagnosticMetadata(SegmentReceipt.self, in: receiptsDirectory, id: { $0.segmentID })
            for receipt in receipts {
                guard let manifest = byID[receipt.segmentID], receipt.receivedAt.timeIntervalSince1970.isFinite else {
                    throw RepositoryError.receiptMismatch
                }
                try validate(receipt, for: manifest)
            }
            return (sortedManifests(manifests), receipts.sorted { $0.receivedAt < $1.receivedAt })
        }
        let recent = try recentEventsSnapshot(at: date, limit: RecordingDiagnosticEventPolicy.defaultEventCount,
                                              while: shouldContinue)
        return .init(manifests: metadata.0, receipts: metadata.1, events: recent.events,
                     eventSelection: recent.eventSelection)
    }

    /// Candidate selection uses filesystem modification times only as a bounded
    /// hint. Decoded timestamps are checked against the requested 24 hours; this
    /// does not establish complete 24-hour or historical fault coverage.
    public func recentEventsSnapshot(at date: Date = Date(), limit: Int = 100,
                                     while shouldContinue: () -> Bool = { true }) throws -> RecordingDiagnosticEventSnapshot {
        guard date.timeIntervalSince1970.isFinite, (1...500).contains(limit) else {
            throw RepositoryError.invalidManifest("诊断事件范围或数量无效")
        }
        guard shouldContinue() else { throw CancellationError() }
        let descriptor = Darwin.open(eventsDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { Darwin.close(descriptor) }
        let before = try diagnosticDirectoryStamp(descriptor)
        let cached = synchronized { diagnosticEventIndex.flatMap { $0.stamp == before && $0.stable ? $0 : nil } }
        let index = try cached ?? diagnosticEventCandidates(descriptor: descriptor, while: shouldContinue)
        let source: RecordingDiagnosticEventSelection.IndexSource = cached == nil ? .coldDirectoryMetadata : .warmInMemory
        let start = date.addingTimeInterval(-86_400)
        let maximumCandidates = min(RecordingDiagnosticEventPolicy.defaultCandidateCount, limit * 2)
        let candidates = Array(index.candidates.prefix(maximumCandidates))
        var values: [RecordingEvent] = [], bytesRead = 0, decoded = 0, byteLimitReached = false
        for candidate in candidates {
            guard shouldContinue() else { throw CancellationError() }
            guard candidate.byteCount > 0, candidate.byteCount <= 1_048_576 else {
                throw RepositoryError.invalidManifest("诊断元数据文件超过大小限制或为空")
            }
            // Never open the next file when its metadata size exceeds the
            // remaining aggregate budget. A selected malformed file still fails.
            guard candidate.byteCount <= RecordingDiagnosticEventPolicy.maximumBytes - bytesRead else {
                byteLimitReached = true; break
            }
            let (event, bytes) = try diagnosticEvent(candidate, descriptor: descriptor)
            bytesRead += bytes; decoded += 1
            if event.timestamp >= start && event.timestamp <= date { values.append(event) }
        }
        guard shouldContinue() else { throw CancellationError() }
        let after = try diagnosticDirectoryStamp(descriptor)
        let stable = index.stable && before == after
        if cached == nil && stable {
            synchronized {
                // A local append between enumeration and this cache commit must
                // not be lost. The mutation lock is held only for this stamp.
                if (try? diagnosticDirectoryStamp(descriptor)) == after { diagnosticEventIndex = index }
            }
        }
        let selected = RecordingDiagnosticEventPolicy.select(values, limit: limit)
        let total = stable ? index.totalEventFileCount : nil
        let omitted = total.map { max(0, $0 - selected.events.count) }
        let candidateLimited = index.totalEventFileCount.map { $0 > candidates.count } ?? true
        let selection = RecordingDiagnosticEventSelection(scope: .recent, requestedStartAt: start, requestedEndAt: date,
            returnedEventCount: selected.events.count, decodedFileCount: decoded, eventBytesRead: bytesRead,
            totalEventFileCount: total, omittedEventFileCount: omitted,
            truncated: omitted.map { $0 > 0 } ?? true, historyCoverageKnown: false,
            candidateLimitReached: candidateLimited, byteLimitReached: byteLimitReached,
            eventLimitReached: values.count > limit, metadataEnumerationLimitReached: index.enumerationLimited,
            indexSource: source, selectionBasis: .fileModificationTime,
            inspectedDirectoryEntryCount: cached == nil ? index.inspectedDirectoryEntryCount : 0,
            invalidMetadataFileCount: index.invalidMetadataFileCount, candidateMetadataStable: stable,
            maximumCandidateCount: maximumCandidates,
            maximumEventBytes: RecordingDiagnosticEventPolicy.maximumBytes, faultKindRuleVersion: 1,
            recognizedFaultCandidateCount: selected.faultCount,
            recognizedFaultsIncludedCount: selected.includedFaultCount,
            faultContextEventCount: selected.contextCount, faultContextWindowSeconds: 60)
        return .init(events: selected.events, eventSelection: selection)
    }

    /// Cheap replay candidates in stable UUID order. This reads filenames only:
    /// a candidate can still be corrupt, missing, or not durably synchronized.
    /// Call verifiedReceipt(for:) immediately before issuing each ACK. Keeping
    /// enumeration separate lets background work stop between individual files.
    public func receiptIDsForReplay() throws -> [UUID] {
        try synchronized {
            try jsonFiles(in: receiptsDirectory).compactMap { url in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      url.lastPathComponent == id.uuidString.lowercased() + ".json" else { return nil }
                return id
            }
        }
    }

    /// Re-establish the integrity and durability of one ACK. Failures affect only
    /// this candidate, so callers can report it and continue with other IDs.
    /// A previously issued receipt alone never authorizes replay or audio cleanup.
    public func verifiedReceipt(for segmentID: UUID) throws -> SegmentReceipt {
        try synchronized {
            let receiptURL = jsonURL(segmentID, in: receiptsDirectory)
            let receipt = try load(SegmentReceipt.self, at: receiptURL)
            guard receipt.segmentID == segmentID else { throw RepositoryError.receiptMismatch }
            let manifestURL = jsonURL(segmentID, in: manifestsDirectory)
            let manifest = try load(SegmentManifest.self, at: manifestURL)
            try validate(manifest)
            try validate(receipt, for: manifest)
            try verifyAudio(at: audioURL(for: manifest), manifest: manifest)
            // Visible atomic writes may have preceded a failed synchronization.
            // Repeat every durability boundary before returning permission to ACK.
            try synchronizeFile(audioURL(for: manifest))
            try synchronizeDirectory(audioDirectory)
            try persist(manifest, at: manifestURL)
            try persist(receipt, at: receiptURL)
            return receipt
        }
    }

    /// Display metadata only. Do not use this as permission to delete or issue ACKs.
    /// Avoid hashing every historical audio file whenever a list refreshes.
    public func receivedSegmentIDs() throws -> Set<UUID> {
        try synchronized {
            Set(try loadAll(SegmentReceipt.self, from: receiptsDirectory).map(\.segmentID))
        }
    }

    public func appendEvent(_ event: RecordingEvent) throws {
        try synchronized {
            let url = jsonURL(event.id, in: eventsDirectory)
            if fm.fileExists(atPath: url.path) {
                guard try load(RecordingEvent.self, at: url) == event else {
                    throw RepositoryError.persistenceFailure("事件标识重复且内容不同")
                }
                return
            }
            let previousStamp = diagnosticEventIndex == nil ? nil : try? diagnosticDirectoryStamp(at: eventsDirectory)
            try persist(event, at: url)
            if var index = diagnosticEventIndex, index.stamp == previousStamp,
               let candidate = try? diagnosticCandidate(name: url.lastPathComponent, at: url),
               let stamp = try? diagnosticDirectoryStamp(at: eventsDirectory) {
                index.noteAppend(candidate, stamp: stamp)
                diagnosticEventIndex = index
            } else {
                diagnosticEventIndex = nil
            }
        }
    }

    public func events(while shouldContinue: () -> Bool = { true }) throws -> [RecordingEvent] {
        var values: [RecordingEvent] = []
        for url in try jsonFiles(in: eventsDirectory) {
            guard shouldContinue() else { return [] }
            values.append(try load(RecordingEvent.self, at: url))
        }
        guard shouldContinue() else { return [] }
        return values.sorted { $0.timestamp < $1.timestamp }
    }

    @discardableResult
    public func recoverInterruptedSessions(at now: Date = Date()) throws -> [RecordingSession] {
        try synchronized {
            var recovered: [RecordingSession] = []
            for var session in try sessions() where session.state == .recording || session.state == .starting {
                let sealedBoundary = try manifests().filter { $0.sessionID == session.id }.map(\.endedAt).max()
                let provisionalStart = session.currentSegmentStartedAt ?? session.lastSealedAt ?? session.startedAt
                // A heartbeat proves samples arrived, not that the open CAF was sealed.
                // Include the entire unsealed tail in the unknown interval.
                let start = max(provisionalStart, sealedBoundary ?? session.startedAt)
                // Persist the event before changing the state. A crash can duplicate a
                // diagnostic event, but cannot erase the evidence of an unfinished run.
                try appendEvent(RecordingEvent(kind: "recovered_unknown_interval",
                    detail: "上次采集未正常结束，此区间待核对；请主动继续录音。",
                    sessionID: session.id, timestamp: now, intervalStart: start, intervalEnd: now))
                session.state = .interrupted
                session.updatedAt = now
                try saveSession(session)
                recovered.append(session)
            }
            return recovered
        }
    }

    public static func fingerprint(of url: URL, while shouldContinue: () -> Bool = { true }) throws -> (byteCount: Int64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while true {
            guard shouldContinue() else { throw CancellationError() }
            // FileHandle can retain autoreleased read buffers until the caller's
            // pool drains. Release each chunk before reading the next one.
            let hasData = try autoreleasepool { () throws -> Bool in
                guard let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty else { return false }
                byteCount += Int64(data.count)
                hasher.update(data: data)
                return true
            }
            if !hasData { break }
        }
        return (byteCount, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    func commitAudio(at staged: URL, manifest: SegmentManifest) throws {
        let manifestURL = jsonURL(manifest.id, in: manifestsDirectory)
        if fm.fileExists(atPath: manifestURL.path) {
            guard try load(SegmentManifest.self, at: manifestURL) == manifest else {
                throw RepositoryError.conflictingSegment
            }
            try verifyAudio(at: audioURL(for: manifest), manifest: manifest)
            return
        }
        let transactionURL = stagingDirectory.appendingPathComponent(manifest.id.uuidString.lowercased() + ".pending.json")
        try validatePendingTransaction(manifest)
        let destination = audioURL(for: manifest)
        if fm.fileExists(atPath: destination.path) { try verifyAudio(at: destination, manifest: manifest) }
        // The write-ahead manifest makes a rename-before-manifest crash recoverable.
        var priority: FreshTransferEntry?
        var priorityBlocked = false
        do { priority = try priorityEntry(for: manifest) }
        catch { priorityBlocked = true; blockPriorityCapture(error) }
        let transaction = AudioCommitTransaction(manifest: manifest, freshEntry: priority, priorityBlocked: priorityBlocked)
        try persist(transaction, at: transactionURL)
        if fm.fileExists(atPath: destination.path) {
            try verifyAudio(at: destination, manifest: manifest)
        } else {
            try fm.moveItem(at: staged, to: destination)
            try applyFileProtection(destination)
            try synchronizeFile(destination)
            try synchronizeDirectory(audioDirectory)
        }
        try faultInjector?(.afterAudioCommit)
        try appendTransferCandidate(manifest.id)
        var priorityCommitted = !priorityBlocked
        if let priority {
            do { try appendFreshEntry(priority) }
            catch { priorityCommitted = false; blockPriorityCapture(error, pendingTransactionCanRepair: true) }
        }
        try persist(manifest, at: manifestURL)
        if priorityCommitted {
            do { try notePrioritySegmentCommitted(manifest) }
            catch { priorityCommitted = false; blockPriorityCapture(error, pendingTransactionCanRepair: true) }
        }
        try faultInjector?(.afterManifestCommit)
        if priorityCommitted, fm.fileExists(atPath: transactionURL.path) { try fm.removeItem(at: transactionURL) }
        if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
        try synchronizeDirectory(stagingDirectory)
    }

    private func validatePendingTransaction(_ manifest: SegmentManifest) throws {
        let url = stagingDirectory.appendingPathComponent(manifest.id.uuidString.lowercased() + ".pending.json")
        if fm.fileExists(atPath: url.path), try load(SegmentManifest.self, at: url) != manifest {
            throw RepositoryError.conflictingSegment
        }
    }

    private func recoverTransactions(failureHandling: RepositoryRecoveryFailureHandling) throws {
        for url in try fm.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasSuffix(".pending.json") {
            do { try recoverTransaction(at: url) }
            catch {
                switch failureHandling {
                case .strict: throw error
                case .preserveAndReport:
                    recordTransactionIssue(for: url, error: error)
                }
            }
        }
        do { try finishPriorityRecovery(succeeded: transactionRecoveryIssues.isEmpty) }
        catch { blockPriorityCapture(error) }
    }

    private func recoverTransaction(at url: URL) throws {
        let transaction = try load(AudioCommitTransaction.self, at: url)
        let manifest = transaction.manifest
        var priorityCommitted = !transaction.priorityBlocked
        if transaction.priorityBlocked { blockPriorityCapture(RepositoryError.persistenceFailure("新录音事务顺序需要人工核对")) }
        try validate(manifest)
        guard url.lastPathComponent == manifest.id.uuidString.lowercased() + ".pending.json" else {
            throw RepositoryError.invalidManifest("事务文件名与片段标识不一致")
        }
        let destination = audioURL(for: manifest)
        let recoveryDirectory = root.appendingPathComponent("recovery-staging", isDirectory: true)
        let original = stagingURL(for: manifest.id)
        // A rebuilt candidate can happen to have identical bytes to the original.
        // Prefer committing the candidate so its source remains available to archive.
        let sources = [recoveryDirectory.appendingPathComponent(manifest.id.uuidString.lowercased() + ".caf"),
                       original]
        let final = jsonURL(manifest.id, in: manifestsDirectory)
        // Reject conflicting metadata before moving any preserved audio.
        if fm.fileExists(atPath: final.path) {
            guard try load(SegmentManifest.self, at: final) == manifest else {
                throw RepositoryError.conflictingSegment
            }
            if !fm.fileExists(atPath: destination.path), try hasDurableAcknowledgement(for: manifest) {
                // A previous commit can become visible to transfer before its pending
                // journal is removed. An exact durable ACK proves a later legal prune;
                // never resurrect audio from a leftover candidate in that situation.
                for source in sources where fm.fileExists(atPath: source.path) {
                    do { try verifyAudio(at: source, manifest: manifest) }
                    catch { recordTransactionIssue(for: source, error: error) }
                }
                if let entry = transaction.freshEntry {
                    do { try appendFreshEntry(entry) }
                    catch { priorityCommitted = false; blockPriorityCapture(error, pendingTransactionCanRepair: true); recordTransactionIssue(for: url, error: error) }
                }
                if priorityCommitted {
                    do { try notePrioritySegmentCommitted(manifest) }
                    catch { priorityCommitted = false; blockPriorityCapture(error, pendingTransactionCanRepair: true); recordTransactionIssue(for: url, error: error) }
                }
                guard priorityCommitted else {
                    recordTransactionIssue(for: url, error: RepositoryError.persistenceFailure("新录音发送顺序待恢复"))
                    return
                }
                try fm.removeItem(at: url)
                try synchronizeDirectory(stagingDirectory)
                return
            }
        }
        if fm.fileExists(atPath: destination.path) {
            try verifyAudio(at: destination, manifest: manifest)
        } else {
            var matchingSource: URL?
            var sourceFailure: Error?
            for source in sources where fm.fileExists(atPath: source.path) {
                do {
                    try verifyAudio(at: source, manifest: manifest)
                    if matchingSource == nil { matchingSource = source }
                } catch {
                    sourceFailure = error
                    recordTransactionIssue(for: source, error: error)
                }
            }
            guard let matchingSource else { throw sourceFailure ?? RepositoryError.missingAudio }
            try fm.moveItem(at: matchingSource, to: destination)
            try synchronizeDirectory(matchingSource.deletingLastPathComponent())
        }
        // A file visible after an earlier failed fsync is not yet durability proof.
        try synchronizeFile(destination)
        try synchronizeDirectory(audioDirectory)
        try appendTransferCandidate(manifest.id)
        if let entry = transaction.freshEntry {
            do { try appendFreshEntry(entry) }
            catch { priorityCommitted = false; blockPriorityCapture(error, pendingTransactionCanRepair: true); recordTransactionIssue(for: url, error: error) }
        }
        try persist(manifest, at: final)
        noteTransferSourceProvenance(manifest, category: .recovery)
        if priorityCommitted {
            do { try notePrioritySegmentCommitted(manifest) }
            catch { priorityCommitted = false; blockPriorityCapture(error, pendingTransactionCanRepair: true); recordTransactionIssue(for: url, error: error) }
        }
        for source in sources where fm.fileExists(atPath: source.path) {
            do { try verifyAudio(at: source, manifest: manifest) }
            catch {
                recordTransactionIssue(for: source, error: error)
                continue
            }
            // Hash equality is not permission to discard a recovery original. Its
            // open identity journal delegates preservation to completeAudioSegment.
            // A normal seal with only staging available was moved above as before.
            if source == original, fm.fileExists(atPath: openSegmentURL(for: manifest.id).path) { continue }
            try fm.removeItem(at: source)
            try synchronizeDirectory(source.deletingLastPathComponent())
        }
        if priorityCommitted { try fm.removeItem(at: url) }
        else { recordTransactionIssue(for: url, error: RepositoryError.persistenceFailure("新录音发送顺序待恢复")) }
        try synchronizeDirectory(stagingDirectory)
    }

    private func recordTransactionIssue(for url: URL, error: Error) {
        let issue = inventoryIssue(for: url, error: error)
        if !transactionRecoveryIssues.contains(issue) { transactionRecoveryIssues.append(issue) }
    }

    func validate(_ manifest: SegmentManifest) throws {
        try Self.validateManifest(manifest)
    }

    static func validateManifest(_ manifest: SegmentManifest) throws {
        guard manifest.schemaVersion == 1 else { throw RepositoryError.invalidManifest("不支持的版本") }
        do { try manifest.validateCaptureMetadata() }
        catch { throw RepositoryError.invalidManifest("录音时区或定位信息不合法") }
        guard manifest.sequence >= 0, manifest.frameCount > 0, manifest.byteCount > 0,
              manifest.sampleRate.isFinite, manifest.sampleRate > 0, manifest.sampleRate <= 384_000,
              manifest.startedAt.timeIntervalSince1970.isFinite,
              manifest.endedAt.timeIntervalSince1970.isFinite, manifest.endedAt >= manifest.startedAt else {
            throw RepositoryError.invalidManifest("时间或音频参数不合法")
        }
        guard manifest.fileName == manifest.id.uuidString.lowercased() + ".caf" else {
            throw RepositoryError.invalidManifest("文件名与片段标识不一致")
        }
        guard manifest.sha256.count == 64,
              manifest.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw RepositoryError.invalidManifest("校验码不合法")
        }
    }

    private func validate(_ receipt: SegmentReceipt, for manifest: SegmentManifest) throws {
        guard receipt.segmentID == manifest.id, receipt.sha256 == manifest.sha256,
              receipt.byteCount == manifest.byteCount else { throw RepositoryError.receiptMismatch }
    }

    private func verifyAudio(at url: URL, manifest: SegmentManifest) throws {
        guard fm.fileExists(atPath: url.path) else { throw RepositoryError.missingAudio }
        let actual = try Self.fingerprint(of: url)
        guard actual.byteCount == manifest.byteCount, actual.sha256 == manifest.sha256 else {
            throw RepositoryError.checksumMismatch
        }
    }

    private func jsonURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func load<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try TransportCodec.decode(type, from: Data(contentsOf: url))
    }

    private func loadAll<T: Decodable>(_ type: T.Type, from directory: URL) throws -> [T] {
        try jsonFiles(in: directory).map { try load(type, at: $0) }
    }

    private func diagnosticDirectoryStamp(_ descriptor: Int32) throws -> RecordingDiagnosticEventDirectoryStamp {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileReadNoPermission)
        }
        return .init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                     modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                     changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    private func diagnosticDirectoryStamp(at directory: URL) throws -> RecordingDiagnosticEventDirectoryStamp {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { Darwin.close(descriptor) }
        return try diagnosticDirectoryStamp(descriptor)
    }

    private func diagnosticCandidate(name: String, info: stat) -> RecordingDiagnosticEventCandidate {
        .init(name: name, modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
              modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
              byteCount: Int64(info.st_size), inode: UInt64(info.st_ino))
    }

    private func diagnosticCandidate(name: String, at url: URL) throws -> RecordingDiagnosticEventCandidate {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw RepositoryError.invalidManifest("诊断元数据不是独立普通文件")
        }
        return diagnosticCandidate(name: name, info: info)
    }

    /// Cold bootstrap enumerates names/stat only; it does not decode 57k old
    /// bodies merely to choose a bounded recent window. It never writes an index.
    private func diagnosticEventCandidates(descriptor: Int32,
                                            while shouldContinue: () -> Bool) throws -> RecordingDiagnosticEventIndex {
        let before = try diagnosticDirectoryStamp(descriptor)
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { throw CocoaError(.fileReadNoPermission) }
        guard let directory = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate); throw CocoaError(.fileReadNoPermission)
        }
        defer { Darwin.closedir(directory) }
        var heap = RecordingDiagnosticEventCandidateHeap(limit: RecordingDiagnosticEventIndex.maximumCandidates)
        var total = 0, inspected = 0, invalid = 0, limited = false
        while true {
            guard shouldContinue() else { throw CancellationError() }
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                guard errno == 0 else { throw CocoaError(.fileReadUnknown) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard inspected < RecordingDiagnosticEventIndex.maximumDirectoryEntries else { limited = true; break }
            inspected += 1
            guard name.hasSuffix(".json") else { continue }
            total += 1
            guard let id = UUID(uuidString: String(name.dropLast(5))), name == id.uuidString.lowercased() + ".json" else {
                invalid += 1; continue
            }
            var info = stat()
            guard Darwin.fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw CocoaError(.fileReadNoPermission)
            }
            if info.st_mode & S_IFMT != S_IFREG || info.st_nlink != 1 { invalid += 1 }
            heap.insert(diagnosticCandidate(name: name, info: info))
        }
        let after = try diagnosticDirectoryStamp(descriptor)
        return .init(stamp: after, candidates: heap.values.sorted { $0.newer(than: $1) },
                     totalEventFileCount: limited ? nil : total,
                     inspectedDirectoryEntryCount: inspected, invalidMetadataFileCount: invalid,
                     enumerationLimited: limited, stable: before == after)
    }

    private func diagnosticEvent(_ candidate: RecordingDiagnosticEventCandidate,
                                 descriptor: Int32) throws -> (RecordingEvent, Int) {
        let file = Darwin.openat(descriptor, candidate.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard Darwin.fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else {
            throw RepositoryError.invalidManifest("诊断元数据不是独立普通文件")
        }
        guard before.st_size > 0, before.st_size <= 1_048_576 else {
            throw RepositoryError.invalidManifest("诊断元数据文件超过大小限制或为空")
        }
        guard diagnosticCandidate(name: candidate.name, info: before) == candidate else {
            throw RepositoryError.invalidManifest("诊断元数据在读取期间发生变化")
        }
        // Read exactly the budgeted file length, then detect growth via fstat;
        // a concurrently enlarged file cannot spend another unbudgeted MiB.
        let bytes = try handle.read(upToCount: Int(before.st_size)) ?? Data()
        var after = stat()
        guard Darwin.fstat(file, &after) == 0, bytes.count == Int(before.st_size),
              diagnosticCandidate(name: candidate.name, info: after) == candidate,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw RepositoryError.invalidManifest("诊断元数据在读取期间发生变化")
        }
        let event = try TransportCodec.decode(RecordingEvent.self, from: bytes)
        guard event.id == UUID(uuidString: String(candidate.name.dropLast(5))) else {
            throw RepositoryError.invalidManifest("元数据文件名与标识不一致")
        }
        guard [event.timestamp, event.intervalStart, event.intervalEnd].compactMap({ $0 })
            .allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              event.intervalStart == nil || event.intervalEnd == nil || event.intervalStart! <= event.intervalEnd! else {
            throw RepositoryError.invalidManifest("事件时间不合法")
        }
        return (event, bytes.count)
    }

    /// Refuse metadata aliases before decoding, so a symlink or hard link cannot
    /// turn this metadata-only path into a read of recording content.
    private func diagnosticMetadata<T: Decodable>(_ type: T.Type, in directory: URL,
                                                  id: (T) -> UUID) throws -> [T] {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { Darwin.close(descriptor) }
        return try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted().map { name in
            guard let fileID = UUID(uuidString: String(name.dropLast(5))),
                  name == fileID.uuidString.lowercased() + ".json" else {
                throw RepositoryError.invalidManifest("元数据文件名与标识不一致")
            }
            return try diagnosticMetadataEntry(type, directory: descriptor, name: name, id: id)

        }
    }

    private func diagnosticMetadataEntry<T: Decodable>(_ type: T.Type, directory: Int32,
                                                       name: String, id: (T) -> UUID) throws -> T {
        guard let fileID = UUID(uuidString: String(name.dropLast(5))),
              name == fileID.uuidString.lowercased() + ".json" else {
            throw RepositoryError.invalidManifest("元数据文件名与标识不一致")
        }
        // A damaged entry can be a FIFO: do not block before fstat rejects it.
        let file = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard Darwin.fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1 else {
            throw RepositoryError.invalidManifest("诊断元数据不是独立普通文件")
        }
        let maximumBytes = 1_048_576
        guard before.st_size > 0, before.st_size <= maximumBytes else {
            throw RepositoryError.invalidManifest("诊断元数据文件超过大小限制或为空")
        }
        let bytes = try handle.read(upToCount: Int(before.st_size)) ?? Data()
        var after = stat()
        guard Darwin.fstat(file, &after) == 0, bytes.count == Int(before.st_size),
              before.st_size == after.st_size, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw RepositoryError.invalidManifest("诊断元数据在读取期间发生变化")
        }
        let value = try TransportCodec.decode(type, from: bytes)
        guard id(value) == fileID else { throw RepositoryError.invalidManifest("元数据文件名与标识不一致") }
        return value
    }

    private func jsonFiles(in directory: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func sortedManifests(_ values: [SegmentManifest]) -> [SegmentManifest] {
        values.sorted {
            if $0.startedAt == $1.startedAt { return $0.sequence < $1.sequence }
            return $0.startedAt < $1.startedAt
        }
    }

    private func inventoryIssue(for url: URL, error: Error) -> RecordingInventoryIssue {
        RecordingInventoryIssue(fileName: url.deletingLastPathComponent().lastPathComponent
            + "/" + url.lastPathComponent, reason: String(error.localizedDescription.prefix(160)))
    }

    func persist<T: Encodable>(_ value: T, at url: URL,
                             observingAcknowledgementOperation: ((AcknowledgementOperation) -> Void)? = nil) throws {
        observingAcknowledgementOperation?(.acknowledgementWrite)
        let data = try TransportCodec.encode(value)
        try data.write(to: url, options: .atomic)
        if url.deletingLastPathComponent() == receiptsDirectory {
            try faultInjector?(.afterReceiptWriteBeforeSync)
        }
        observingAcknowledgementOperation?(.acknowledgementProtection)
        try applyFileProtection(url)
        if url.deletingLastPathComponent() == acknowledgementsDirectory {
            try synchronizeAcknowledgement(at: url, observingOperation: observingAcknowledgementOperation)
        } else {
            try synchronizeFile(url)
            try synchronizeDirectory(url.deletingLastPathComponent())
        }
    }

    private func synchronizeAcknowledgement(at url: URL,
                                            observingOperation: ((AcknowledgementOperation) -> Void)? = nil) throws {
        observingOperation?(.acknowledgementFileSync)
        try faultInjector?(.beforeAcknowledgementSync)
        try synchronizeFile(url)
        observingOperation?(.acknowledgementDirectorySync)
        try synchronizeDirectory(acknowledgementsDirectory)
    }

    func synchronizeFile(_ url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw RepositoryError.persistenceFailure(String(cString: strerror(errno))) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw RepositoryError.persistenceFailure(String(cString: strerror(errno)))
        }
    }

    func applyFileProtection(_ url: URL) throws {
        #if os(iOS) || os(watchOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                             ofItemAtPath: url.path)
        #endif
    }

    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
