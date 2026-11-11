import Foundation
import Darwin

public enum CloudLibraryLedgerError: LocalizedError, Equatable {
    case unsupportedVersion, invalidLedger, emptySnapshot, duplicateSegment
    case noSnapshot, notAuthorized, changedManifest, accountNotBound, accountChanged, scopeChanged
    case invalidReceipt, audioNotSaved

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "iCloud 本机记录版本暂不支持，原始录音仍保留。"
        case .invalidLedger: return "iCloud 本机记录无法校验，已暂停上传，避免混用账户或录音。"
        case .emptySnapshot: return "请先选择要保存到 iCloud 的录音。"
        case .duplicateSegment: return "所选录音包含重复记录，尚未开始上传。"
        case .noSnapshot: return "尚未确定本次授权的录音范围。"
        case .notAuthorized: return "这段录音不在本次授权范围内，未上传。"
        case .changedManifest: return "所选录音的信息发生变化，已停止处理这段录音。"
        case .accountNotBound: return "尚未确认本次录音对应的 iCloud 账户。"
        case .accountChanged: return "iCloud 账户与这批录音原先绑定的账户不同，已暂停上传。请换回原账户。"
        case .scopeChanged: return "iCloud 容器或环境发生变化，已暂停使用原来的上传记录。"
        case .invalidReceipt: return "云端保存信息与所选录音不一致，未标记为已保存。"
        case .audioNotSaved: return "请先把这段原始录音保存到 iCloud，再上传转写文字。"
        }
    }
}

/// Identifiers are local account hashes, never an email address or raw CloudKit user ID.
public struct CloudLibraryScope: Codable, Equatable, Sendable {
    public let containerIdentifier: String
    public let environment: String
    public let ownerHash: String

    public init(containerIdentifier: String, environment: String, ownerHash: String) {
        self.containerIdentifier = containerIdentifier
        self.environment = environment
        self.ownerHash = ownerHash
    }
}

public struct CloudLibrarySnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let authorizedAt: Date
    public let manifests: [SegmentManifest]

    public var segmentIDs: Set<UUID> { Set(manifests.map(\.id)) }
}

public struct CloudTranscriptReceipt: Codable, Equatable, Sendable {
    public let contentSHA256: String
    public let cloudRecordName: String
    public let metadataVerifiedAt: Date
}

/// This confirms a successful cloud operation followed by record-metadata readback.
/// It does not assert a separate download and SHA-256 check of the remote audio asset,
/// and it never grants permission to acknowledge or delete Watch/iPhone audio.
public struct CloudLibraryReceipt: Codable, Equatable, Sendable {
    public let segmentID: UUID
    public let audioSHA256: String
    public let byteCount: Int64
    public let cloudRecordName: String
    public let metadataVerifiedAt: Date
    public fileprivate(set) var transcript: CloudTranscriptReceipt?
}

/// A small durable authorization ledger, independent of transport ACKs. The first
/// snapshot and account binding are immutable; retrying cannot expand or rebind them.
public struct CloudLibraryLedger: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public private(set) var snapshot: CloudLibrarySnapshot?
    public private(set) var scope: CloudLibraryScope?
    public private(set) var receipts: [CloudLibraryReceipt]

    public init() {
        schemaVersion = 1
        snapshot = nil
        scope = nil
        receipts = []
    }

    public var savedAudioCount: Int { receipts.count }
    public var savedTranscriptCount: Int { receipts.filter { $0.transcript != nil }.count }

    /// Only the first explicit selection is captured. Later library additions stay
    /// outside this authorization, including when a caller supplies a refreshed list.
    @discardableResult
    public mutating func captureInitialSnapshot(_ manifests: [SegmentManifest], at date: Date = Date()) throws -> CloudLibrarySnapshot {
        try validate()
        if let snapshot {
            let authorized = Dictionary(uniqueKeysWithValues: snapshot.manifests.map { ($0.id, $0) })
            for manifest in manifests {
                if let previous = authorized[manifest.id], previous != manifest {
                    throw CloudLibraryLedgerError.changedManifest
                }
            }
            return snapshot
        }
        guard !manifests.isEmpty else { throw CloudLibraryLedgerError.emptySnapshot }
        guard Self.isSafeDate(date) else { throw CloudLibraryLedgerError.invalidLedger }
        guard Set(manifests.map(\.id)).count == manifests.count else { throw CloudLibraryLedgerError.duplicateSegment }
        try manifests.forEach(Self.validateManifest)
        let captured = CloudLibrarySnapshot(id: UUID(), authorizedAt: Self.canonical(date),
            manifests: manifests.sorted {
                $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
            })
        snapshot = captured
        return captured
    }

    /// There is intentionally no reset or rebind API. Signing out or cancellation
    /// must not make an old account's recordings eligible for another account.
    public mutating func bind(to proposed: CloudLibraryScope) throws {
        try validate()
        try Self.validateScope(proposed)
        guard snapshot != nil else { throw CloudLibraryLedgerError.noSnapshot }
        if scope != nil { try requireScope(proposed) }
        else { scope = proposed }
    }

    public func requireScope(_ proposed: CloudLibraryScope) throws {
        try Self.validateScope(proposed)
        guard let scope else { throw CloudLibraryLedgerError.accountNotBound }
        guard scope.containerIdentifier == proposed.containerIdentifier,
              scope.environment == proposed.environment else { throw CloudLibraryLedgerError.scopeChanged }
        guard scope.ownerHash == proposed.ownerHash else { throw CloudLibraryLedgerError.accountChanged }
    }

    public func requireAuthorized(_ manifest: SegmentManifest) throws {
        guard let snapshot else { throw CloudLibraryLedgerError.noSnapshot }
        guard let authorized = snapshot.manifests.first(where: { $0.id == manifest.id }) else {
            throw CloudLibraryLedgerError.notAuthorized
        }
        guard authorized == manifest else { throw CloudLibraryLedgerError.changedManifest }
    }

    public func receipt(for segmentID: UUID) -> CloudLibraryReceipt? {
        receipts.first { $0.segmentID == segmentID }
    }

    public static func audioRecordName(for segmentID: UUID) -> String {
        "segment-" + segmentID.uuidString.lowercased()
    }

    public static func transcriptRecordName(for segmentID: UUID, contentSHA256: String) -> String {
        "transcript-" + segmentID.uuidString.lowercased() + "-" + contentSHA256
    }

    /// Call only after a successful cloud save (or an identical existing record)
    /// has been fetched again and its metadata has been checked against this manifest.
    public mutating func recordAudioSaved(_ manifest: SegmentManifest, in proposed: CloudLibraryScope,
                                          cloudRecordName: String, at date: Date = Date()) throws {
        try validate()
        try requireScope(proposed)
        try requireAuthorized(manifest)
        guard cloudRecordName == Self.audioRecordName(for: manifest.id) else {
            throw CloudLibraryLedgerError.invalidReceipt
        }
        if let existing = receipt(for: manifest.id) {
            guard existing.audioSHA256 == manifest.sha256, existing.byteCount == manifest.byteCount,
                  existing.cloudRecordName == cloudRecordName else { throw CloudLibraryLedgerError.invalidReceipt }
            return
        }
        guard Self.isSafeDate(date) else { throw CloudLibraryLedgerError.invalidReceipt }
        receipts.append(CloudLibraryReceipt(segmentID: manifest.id, audioSHA256: manifest.sha256,
            byteCount: manifest.byteCount, cloudRecordName: cloudRecordName,
            metadataVerifiedAt: Self.canonical(date), transcript: nil))
        receipts.sort { $0.segmentID.uuidString < $1.segmentID.uuidString }
    }

    /// Transcript records are content-addressed versions. Saving a later transcript
    /// never overwrites a different cloud transcript or changes the audio receipt.
    public mutating func recordTranscriptSaved(for manifest: SegmentManifest, in proposed: CloudLibraryScope,
                                               contentSHA256: String, cloudRecordName: String,
                                               at date: Date = Date()) throws {
        try validate()
        try requireScope(proposed)
        try requireAuthorized(manifest)
        guard Self.isDigest(contentSHA256),
              cloudRecordName == Self.transcriptRecordName(for: manifest.id, contentSHA256: contentSHA256) else {
            throw CloudLibraryLedgerError.invalidReceipt
        }
        guard let index = receipts.firstIndex(where: { $0.segmentID == manifest.id }) else {
            throw CloudLibraryLedgerError.audioNotSaved
        }
        guard receipts[index].audioSHA256 == manifest.sha256,
              receipts[index].byteCount == manifest.byteCount else { throw CloudLibraryLedgerError.invalidReceipt }
        if let previous = receipts[index].transcript,
           previous.contentSHA256 == contentSHA256, previous.cloudRecordName == cloudRecordName { return }
        guard Self.isSafeDate(date) else { throw CloudLibraryLedgerError.invalidReceipt }
        receipts[index].transcript = CloudTranscriptReceipt(contentSHA256: contentSHA256,
            cloudRecordName: cloudRecordName, metadataVerifiedAt: Self.canonical(date))
    }

    public static func load(from url: URL) throws -> CloudLibraryLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return CloudLibraryLedger() }
        let ledger = try TransportCodec.decode(CloudLibraryLedger.self, from: Data(contentsOf: url))
        try ledger.validate()
        return ledger
    }

    /// The caller should mutate a copy, persist it, then replace its in-memory state.
    /// A failed write therefore cannot make the UI claim a durable cloud receipt.
    public func persist(to url: URL) throws {
        try validate()
        let directory = url.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS) || os(watchOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        try TransportCodec.encode(self).write(to: url, options: .atomic)
        #if os(iOS) || os(watchOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw CloudLibraryLedgerError.invalidLedger }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CloudLibraryLedgerError.invalidLedger }
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw CloudLibraryLedgerError.unsupportedVersion }
        guard let snapshot else {
            guard scope == nil, receipts.isEmpty else { throw CloudLibraryLedgerError.invalidLedger }
            return
        }
        guard !snapshot.manifests.isEmpty,
              Self.isSafeDate(snapshot.authorizedAt),
              Set(snapshot.manifests.map(\.id)).count == snapshot.manifests.count else {
            throw CloudLibraryLedgerError.invalidLedger
        }
        try snapshot.manifests.forEach(Self.validateManifest)
        if let scope { try Self.validateScope(scope) }
        guard receipts.isEmpty || scope != nil,
              Set(receipts.map(\.segmentID)).count == receipts.count else { throw CloudLibraryLedgerError.invalidLedger }
        for receipt in receipts {
            guard let manifest = snapshot.manifests.first(where: { $0.id == receipt.segmentID }),
                  receipt.audioSHA256 == manifest.sha256, receipt.byteCount == manifest.byteCount,
                  receipt.cloudRecordName == Self.audioRecordName(for: manifest.id),
                  Self.isSafeDate(receipt.metadataVerifiedAt) else { throw CloudLibraryLedgerError.invalidLedger }
            if let transcript = receipt.transcript {
                guard Self.isDigest(transcript.contentSHA256),
                      transcript.cloudRecordName == Self.transcriptRecordName(for: manifest.id, contentSHA256: transcript.contentSHA256),
                      Self.isSafeDate(transcript.metadataVerifiedAt) else { throw CloudLibraryLedgerError.invalidLedger }
            }
        }
    }

    private static func validateManifest(_ manifest: SegmentManifest) throws {
        guard manifest.schemaVersion == 1, manifest.sequence >= 0,
              manifest.sampleRate.isFinite, manifest.sampleRate > 0,
              manifest.frameCount > 0, manifest.byteCount > 0,
              isSafeDate(manifest.startedAt), isSafeDate(manifest.endedAt),
              manifest.endedAt >= manifest.startedAt,
              manifest.fileName == manifest.id.uuidString.lowercased() + ".caf",
              isDigest(manifest.sha256) else { throw CloudLibraryLedgerError.changedManifest }
    }

    private static func validateScope(_ scope: CloudLibraryScope) throws {
        guard scope.containerIdentifier.hasPrefix("iCloud."), scope.containerIdentifier.count > 7,
              !scope.containerIdentifier.contains("$("),
              !scope.containerIdentifier.contains(where: { $0.isWhitespace }),
              ["Development", "Production"].contains(scope.environment),
              isDigest(scope.ownerHash) else { throw CloudLibraryLedgerError.invalidLedger }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isSafeDate(_ date: Date) -> Bool {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        return milliseconds.isFinite && milliseconds >= 0 && milliseconds <= 253_402_300_799_999
    }

    private static func canonical(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }
}
