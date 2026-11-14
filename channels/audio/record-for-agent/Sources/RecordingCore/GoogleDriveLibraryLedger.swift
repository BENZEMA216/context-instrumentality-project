import CryptoKit
import Foundation

/// Only allowlisted reason codes may leave a Google response. Never retain its
/// free-form message, URLs, account identifiers or complete body.
public enum GoogleDriveAPIReason: String, Codable, Sendable {
    case storageQuotaExceeded, rateLimitExceeded, userRateLimitExceeded, dailyLimitExceeded
    case insufficientFilePermissions, appNotAuthorizedToFile, domainPolicy
    case activeItemCreationLimitExceeded

    public static func parse(status: Int, data: Data) -> Self? {
        guard (400...599).contains(status), data.count <= 65_536 else { return nil }
        struct Envelope: Decodable {
            struct Failure: Decodable {
                struct Detail: Decodable { let reason: String? }
                let code: Int
                let errors: [Detail]?
            }
            let error: Failure
        }
        guard let value = try? JSONDecoder().decode(Envelope.self, from: data), value.error.code == status else { return nil }
        let reasons = (value.error.errors ?? []).compactMap { $0.reason.flatMap(Self.init(rawValue:)) }
        // Do not let a transient reason hide an actionable capacity/permission error.
        return reasons.first(where: { !$0.isRateLimit }) ?? reasons.first
    }
    public var isRateLimit: Bool { self == .rateLimitExceeded || self == .userRateLimitExceeded }
    public var explanation: String {
        switch self {
        case .storageQuotaExceeded:
            return "Google 云盘空间不足，剩余录音等待上传。请释放空间或扩容后点“检查同步”；已上传文件和原录音均保留。"
        case .rateLimitExceeded, .userRateLimitExceeded:
            return "Google 暂时限制了请求频率，队列已保留，将自动重试。"
        case .dailyLimitExceeded:
            return "Google API 当日配额已用尽，队列已保留；需要开发者检查配额。"
        case .insufficientFilePermissions, .appNotAuthorizedToFile, .domainPolicy:
            return "Google 拒绝写入当前目录，请检查原账户的目录权限或组织限制。原录音和队列均保留。"
        case .activeItemCreationLimitExceeded:
            return "Google 账户已达到文件数量上限，请处理账户中的文件数量后再检查同步。原录音和队列均保留。"
        }
    }
}

public enum GoogleDriveLibraryError: LocalizedError, Equatable {
    case invalidState, changedAccount, changedManifest, notAuthorized, invalidRemoteFile, metadataIncomplete, invalidRemoteFolder, notConfigured

    /// Item metadata or content failures stay on that item. Account, grant,
    /// and queue-integrity failures stop the library.
    public enum SyncFailureScope: Equatable, Sendable {
        case disableLibrary, retryLibrary, failItemOnly
    }
    public var syncFailureScope: SyncFailureScope {
        switch self {
        case .invalidState, .changedAccount, .notConfigured: return .disableLibrary
        case .invalidRemoteFolder: return .retryLibrary
        case .changedManifest, .invalidRemoteFile, .metadataIncomplete, .notAuthorized: return .failItemOnly
        }
    }
    public var errorDescription: String? {
        switch self {
        case .invalidState: return "Google Drive 本机队列无法核对，已暂停同步。原录音仍保留。"
        case .changedAccount: return "Google 账户与原绑定账户不同，已暂停同步。请连接原账户。"
        case .changedManifest: return "录音内容或清单发生变化，未继续上传。"
        case .notAuthorized: return "这段录音不在 Google Drive 的授权范围内。"
        case .invalidRemoteFolder: return "Drive 录音库目录暂未通过身份或私有权限核对，已保留全部队列，稍后重新核对。"
        case .invalidRemoteFile: return "Drive 文件的内容、位置或私有权限未通过核对，未标记为已保存。"
        case .metadataIncomplete: return "Drive 文件核对信息暂不完整，未标记为已保存，稍后只读重新核对。"
        case .notConfigured: return "此安装版本尚未配置有效的 Google iOS 登录信息，暂时无法连接。"
        }
    }
}

public enum GoogleDriveRecordingScope: String, Codable, Sendable, CaseIterable {
    case existingAndFuture, futureOnly
}

public struct GoogleDriveArtifact: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case audio, manifest, transcriptJSON, transcriptText }
    public let kind: Kind
    public let sha256: String
    public let byteCount: Int64
    public fileprivate(set) var fileID: String?
    public fileprivate(set) var uploadURL: String?
    public fileprivate(set) var verifiedAt: Date?
    /// Absent on historical receipts; never infer recovery attribution on load.
    public fileprivate(set) var verifiedUploadCorrelation: GoogleDriveUploadCorrelation?
    public var key: String { kind.rawValue + "-" + sha256 }
    public init(kind: Kind, sha256: String, byteCount: Int64) {
        self.kind = kind; self.sha256 = sha256; self.byteCount = byteCount
    }
}

public struct GoogleDriveLibraryJob: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { manifest.id }
    public let manifest: SegmentManifest
    public fileprivate(set) var artifacts: [GoogleDriveArtifact]
}

/// Drive reports these checksums for stored binary content. This is metadata
/// readback, not an independent audio download or permission for audio deletion.
public struct GoogleDrivePermission: Codable, Equatable, Sendable {
    public let id: String?
    public let type: String?
    public let role: String?
    public let deleted: Bool?
    public init(id: String?, type: String?, role: String?, deleted: Bool? = nil) {
        self.id = id; self.type = type; self.role = role; self.deleted = deleted
    }
}

public struct GoogleDriveRemoteFile: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let mimeType: String?
    public let size: String?
    public let sha256Checksum: String?
    public let parents: [String]?
    public let ownedByMe: Bool?
    public let shared: Bool?
    public let trashed: Bool?
    public let appProperties: [String: String]?
    public let permissions: [GoogleDrivePermission]?
    public init(id: String, name: String? = nil, mimeType: String? = nil, size: String? = nil,
                sha256Checksum: String? = nil, parents: [String]? = nil, ownedByMe: Bool? = nil,
                shared: Bool? = nil, trashed: Bool? = nil, appProperties: [String: String]? = nil,
                permissions: [GoogleDrivePermission]? = nil) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.size = size
        self.sha256Checksum = sha256Checksum; self.parents = parents; self.ownedByMe = ownedByMe
        self.shared = shared; self.trashed = trashed; self.appProperties = appProperties; self.permissions = permissions
    }
}

/// Its own explicit grant: iCloud selections and transport receipts never enable
/// Drive. Account and libraryID are immutable, even after pause or revocation.
public struct GoogleDriveLibraryLedger: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let libraryID: UUID
    public private(set) var accountID: String?
    public private(set) var accountLabel: String?
    public private(set) var recordingScope: GoogleDriveRecordingScope?
    public private(set) var authorizedAt: Date?
    public private(set) var baselineIDs: Set<UUID>
    public private(set) var enabled: Bool
    public private(set) var revokedLocally: Bool
    public private(set) var remoteRevocationConfirmed: Bool
    public private(set) var folderID: String?
    public private(set) var jobs: [GoogleDriveLibraryJob]
    public private(set) var retryAfter: Date?
    public private(set) var failureCount: Int
    public private(set) var apiFailureReason: GoogleDriveAPIReason?
    public private(set) var retryFailureKind: GoogleDriveRetryFailureKind?
    public private(set) var recoveryProbeAt: Date?
    public private(set) var lastFailureAt: Date?
    public private(set) var credentialRequiredAt: Date?

    public init() {
        schemaVersion = 1; libraryID = UUID(); baselineIDs = []; enabled = false
        revokedLocally = false; remoteRevocationConfirmed = false; jobs = []; failureCount = 0
    }
    public var savedAudioCount: Int {
        jobs.filter { $0.artifacts.contains { $0.kind == .audio && $0.verifiedAt != nil } }.count
    }
    public var savedTranscriptCount: Int {
        jobs.filter { $0.artifacts.contains { $0.kind == .transcriptJSON && $0.verifiedAt != nil } }.count
    }
    public var hasPendingFiles: Bool { jobs.contains { $0.artifacts.contains { $0.verifiedAt == nil } } }

    public mutating func bind(accountID: String, label: String) throws {
        guard !accountID.isEmpty, accountID.utf8.count <= 256, label.utf8.count <= 512 else { throw GoogleDriveLibraryError.invalidState }
        if let previous = self.accountID, previous != accountID { throw GoogleDriveLibraryError.changedAccount }
        self.accountID = accountID; self.accountLabel = label
    }
    /// Call only after a fresh credential has committed for the fenced account.
    /// New consent supersedes a pending local revoke; it does not establish that
    /// the old remote revoke succeeded and never resumes recording uploads.
    public mutating func recordReauthorization(accountID: String, label: String) throws {
        try bind(accountID: accountID, label: label)
        enabled = false; revokedLocally = false; remoteRevocationConfirmed = false
        retryAfter = nil; failureCount = 0; credentialRequiredAt = nil
    }
    public mutating func authorize(_ scope: GoogleDriveRecordingScope, knownIDs: Set<UUID>, at date: Date = Date()) throws {
        guard accountID != nil, recordingScope == nil, date.timeIntervalSince1970.isFinite,
              knownIDs.count <= 10_000 else { throw GoogleDriveLibraryError.invalidState }
        recordingScope = scope; authorizedAt = date; baselineIDs = knownIDs
        enabled = true; revokedLocally = false; remoteRevocationConfirmed = false; retryAfter = nil; failureCount = 0
    }
    public mutating func setEnabled(_ value: Bool) throws {
        guard !value || (accountID != nil && recordingScope != nil) else { throw GoogleDriveLibraryError.invalidState }
        enabled = value
        if value { revokedLocally = false; remoteRevocationConfirmed = false; retryAfter = nil; failureCount = 0 }
    }
    public mutating func revoke(remoteConfirmed: Bool = false) {
        enabled = false; revokedLocally = true; remoteRevocationConfirmed = remoteConfirmed; retryAfter = nil
    }
    public mutating func recordFailure(at date: Date = Date(), kind: GoogleDriveRetryFailureKind = .other, apiReason: GoogleDriveAPIReason? = nil) {
        apiFailureReason = apiReason
        retryFailureKind = kind; lastFailureAt = date
        failureCount = min(failureCount + 1, 16)
        retryAfter = date.addingTimeInterval(min(3_600, 15 * pow(2, Double(min(failureCount, 9) - 1))))
    }
    public mutating func recordCredentialRequired(at date: Date = Date()) {
        credentialRequiredAt = date; lastFailureAt = date
    }
    public mutating func clearRetry() { failureCount = 0; retryAfter = nil; retryFailureKind = nil; apiFailureReason = nil }

    /// Reserve a single opportunity without erasing the original failure or
    /// deadline. Persist before sending, including across process reconstruction.
    @discardableResult
    public mutating func reserveNetworkRecovery(at date: Date = Date()) -> Bool {
        guard enabled, !revokedLocally, accountID != nil, recordingScope != nil,
              retryFailureKind == .recoverableNetwork, let due = retryAfter, due > date else { return false }
        return reserveNetworkRecoveryOpportunity(at: date)
    }

    /// Earliest safe opportunity after a signal. A signal inside the shared
    /// cooldown must wait for this date, not disappear behind the old backoff.
    public func networkRecoveryOpportunityDate(at date: Date = Date()) -> Date? {
        guard enabled, !revokedLocally, accountID != nil, recordingScope != nil,
              date.timeIntervalSince1970.isFinite else { return nil }
        return recoveryProbeAt.map { max(date, $0.addingTimeInterval(GoogleDriveRetryFailureKind.recoveryCooldown)) } ?? date
    }

    /// Shared by library and per-item probes, so path flapping cannot walk the
    /// queue or reset the cooldown after a successful item's retry is removed.
    @discardableResult
    public mutating func reserveNetworkRecoveryOpportunity(at date: Date = Date()) -> Bool {
        guard enabled, !revokedLocally, accountID != nil, recordingScope != nil,
              GoogleDriveRetryFailureKind.cooldownElapsed(since: recoveryProbeAt, at: date) else { return false }
        recoveryProbeAt = date
        return true
    }

    /// The successful probe may clear only the retry it reserved. Another
    /// failure, grant change or HTTP response must survive a delayed success.
    public mutating func completeNetworkRecovery(reserved: Self) {
        guard enabled, !revokedLocally, libraryID == reserved.libraryID,
              accountID == reserved.accountID, authorizedAt == reserved.authorizedAt,
              recordingScope == reserved.recordingScope, folderID == reserved.folderID,
              retryFailureKind == .recoverableNetwork, failureCount == reserved.failureCount,
              retryAfter == reserved.retryAfter, recoveryProbeAt == reserved.recoveryProbeAt else { return }
        clearRetry()
    }

    public mutating func discover(manifests: [SegmentManifest], receivedIDs: Set<UUID>) throws {
        guard let mode = recordingScope, let authorizedAt else { return }
        guard manifests.count <= 10_000, Set(manifests.map(\.id)).count == manifests.count else { throw GoogleDriveLibraryError.invalidState }
        var candidate = self
        for manifest in manifests where receivedIDs.contains(manifest.id) {
            if let old = candidate.jobs.first(where: { $0.id == manifest.id }) {
                guard old.manifest == manifest else { throw GoogleDriveLibraryError.changedManifest }
                continue
            }
            guard mode == .existingAndFuture || (!baselineIDs.contains(manifest.id) && manifest.startedAt >= authorizedAt) else { continue }
            try Self.validateManifest(manifest)
            let bytes = try TransportCodec.encode(Self.exportManifest(manifest))
            candidate.jobs.append(.init(manifest: manifest, artifacts: [
                .init(kind: .audio, sha256: manifest.sha256, byteCount: manifest.byteCount),
                .init(kind: .manifest, sha256: Self.digest(bytes), byteCount: Int64(bytes.count))]))
        }
        try candidate.validate(); self = candidate
    }
    public mutating func discoverTranscript(_ transcript: SegmentTranscript, for manifest: SegmentManifest) throws {
        guard let index = jobs.firstIndex(where: { $0.manifest == manifest }) else { throw GoogleDriveLibraryError.notAuthorized }
        try transcript.validate(against: manifest)
        let json = try TransportCodec.encode(transcript), text = Self.readableTranscript(transcript, manifest: manifest)
        for (kind, bytes) in [(GoogleDriveArtifact.Kind.transcriptJSON, json), (.transcriptText, text)] {
            let value = GoogleDriveArtifact(kind: kind, sha256: Self.digest(bytes), byteCount: Int64(bytes.count))
            if !jobs[index].artifacts.contains(where: { $0.key == value.key }) { jobs[index].artifacts.append(value) }
        }
        try validate()
    }
    public mutating func allocateFolder(_ id: String) throws {
        guard Self.validFileID(id), folderID == nil || folderID == id else { throw GoogleDriveLibraryError.invalidState }
        guard !jobs.flatMap(\.artifacts).contains(where: { $0.fileID == id }) else { throw GoogleDriveLibraryError.invalidState }
        folderID = id
    }
    public mutating func allocateFile(segmentID: UUID, key: String, fileID: String) throws {
        guard Self.validFileID(fileID), fileID != folderID,
              !jobs.flatMap(\.artifacts).contains(where: { $0.fileID == fileID && $0.key != key }) else { throw GoogleDriveLibraryError.invalidState }
        try mutateArtifact(segmentID, key) {
            guard $0.fileID == nil || $0.fileID == fileID else { throw GoogleDriveLibraryError.invalidState }
            $0.fileID = fileID
        }
    }
    public mutating func recordSession(segmentID: UUID, key: String, url: String?) throws {
        guard url == nil || Self.validUploadURL(url!) else { throw GoogleDriveLibraryError.invalidState }
        try mutateArtifact(segmentID, key) {
            guard $0.fileID != nil, $0.verifiedAt == nil else { throw GoogleDriveLibraryError.invalidState }
            $0.uploadURL = url
        }
    }
    public mutating func recordVerified(segmentID: UUID, key: String, file: GoogleDriveRemoteFile,
                                        in accountID: String, at date: Date = Date()) throws {
        guard date.timeIntervalSince1970.isFinite, self.accountID == accountID, let folderID else { throw GoogleDriveLibraryError.changedAccount }
        guard let audioSHA = jobs.first(where: { $0.id == segmentID })?.manifest.sha256 else { throw GoogleDriveLibraryError.notAuthorized }
        var candidate = self
        var madeProgress = false
        try candidate.mutateArtifact(segmentID, key) { artifact in
            let properties = ["rfaLibraryID": libraryID.uuidString.lowercased(), "rfaSegmentID": segmentID.uuidString.lowercased(),
                "rfaSchema": "1", "rfaKind": artifact.kind.rawValue, "rfaContentSHA256": artifact.sha256,
                "rfaAudioSHA256": audioSHA]
            // A present conflicting field takes precedence over missing fields.
            // Incomplete metadata is recoverable only through another strict
            // readback; it is never evidence of a successful upload.
            guard artifact.fileID == file.id,
                  file.sha256Checksum.map({ $0 == artifact.sha256 }) ?? true,
                  file.size.map({ Int64($0) == artifact.byteCount }) ?? true,
                  file.parents.map({ $0 == [folderID] }) ?? true,
                  file.ownedByMe != false, file.shared != true, file.trashed != true,
                  properties.allSatisfy({ expected in file.appProperties.flatMap { $0[expected.key] }.map { $0 == expected.value } ?? true }),
                  file.permissions.map({ !$0.isEmpty && $0.allSatisfy {
                      ($0.id.map { $0 == accountID } ?? true) && ($0.type.map { $0 == "user" } ?? true)
                          && ($0.role.map { $0 == "owner" } ?? true) && $0.deleted != true
                  } }) ?? true else { throw GoogleDriveLibraryError.invalidRemoteFile }
            guard file.sha256Checksum != nil, file.size != nil, file.parents != nil,
                  Self.isOwnerOnly(file, accountID: accountID),
                  properties.allSatisfy({ file.appProperties?[$0.key] == $0.value }) else {
                throw GoogleDriveLibraryError.metadataIncomplete
            }
            madeProgress = artifact.verifiedAt == nil
            artifact.verifiedAt = date; artifact.uploadURL = nil
            artifact.verifiedUploadCorrelation = .init(segmentID: segmentID, kind: artifact.kind, manifestSHA256: audioSHA)
        }
        // Backoff measures consecutive failures without durable progress, even
        // while a large queue still has pending files. Rechecking a receipt is
        // not new progress, and all receipt/state validation must succeed first.
        if madeProgress { candidate.clearRetry() }
        self = candidate
    }
    private mutating func mutateArtifact(_ segmentID: UUID, _ key: String, _ change: (inout GoogleDriveArtifact) throws -> Void) throws {
        guard let job = jobs.firstIndex(where: { $0.id == segmentID }),
              let artifact = jobs[job].artifacts.firstIndex(where: { $0.key == key }) else { throw GoogleDriveLibraryError.notAuthorized }
        var value = self
        try change(&value.jobs[job].artifacts[artifact]); try value.validate(); self = value
    }
    public func validate() throws {
        guard schemaVersion == 1, jobs.count <= 10_000, baselineIDs.count <= 10_000,
              Set(jobs.map(\.id)).count == jobs.count, (0...16).contains(failureCount),
              !enabled || (accountID != nil && recordingScope != nil && !revokedLocally),
              (recordingScope == nil) == (authorizedAt == nil),
              authorizedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              retryAfter.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              recoveryProbeAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              lastFailureAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              credentialRequiredAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              !remoteRevocationConfirmed || revokedLocally,
              !revokedLocally || !enabled,
              accountID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
              accountLabel.map({ $0.utf8.count <= 512 }) ?? true,
              folderID.map(Self.validFileID) ?? true else { throw GoogleDriveLibraryError.invalidState }
        var ids = Set<String>()
        if let folderID { ids.insert(folderID) }
        for job in jobs {
            guard accountID != nil, let mode = recordingScope, let authorizedAt,
                  mode == .existingAndFuture || (!baselineIDs.contains(job.id) && job.manifest.startedAt >= authorizedAt)
            else { throw GoogleDriveLibraryError.notAuthorized }
            try Self.validateManifest(job.manifest)
            guard job.artifacts.count <= 128, Set(job.artifacts.map(\.key)).count == job.artifacts.count,
                  job.artifacts.filter({ $0.kind == .audio }).count == 1,
                  job.artifacts.filter({ $0.kind == .manifest }).count == 1 else { throw GoogleDriveLibraryError.invalidState }
            let manifestBytes = try TransportCodec.encode(Self.exportManifest(job.manifest))
            for artifact in job.artifacts {
                guard Self.isDigest(artifact.sha256), artifact.byteCount > 0, artifact.byteCount <= 130 * 1_024 * 1_024,
                      artifact.uploadURL.map(Self.validUploadURL) ?? true,
                      artifact.uploadURL == nil || artifact.fileID != nil,
                      artifact.verifiedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                      artifact.verifiedAt == nil || (artifact.fileID != nil && artifact.uploadURL == nil),
                      artifact.verifiedUploadCorrelation.map({ artifact.verifiedAt != nil && $0 == .init(segmentID: job.id, kind: artifact.kind, manifestSHA256: job.manifest.sha256) }) ?? true,
                      artifact.kind != .audio || (artifact.sha256 == job.manifest.sha256 && artifact.byteCount == job.manifest.byteCount),
                      artifact.kind != .manifest || (artifact.sha256 == Self.digest(manifestBytes) && artifact.byteCount == manifestBytes.count)
                else { throw GoogleDriveLibraryError.invalidState }
                if let id = artifact.fileID { guard Self.validFileID(id), ids.insert(id).inserted else { throw GoogleDriveLibraryError.invalidState } }
            }
        }
    }
    public static func isOwnerOnly(_ file: GoogleDriveRemoteFile, accountID: String) -> Bool {
        guard file.ownedByMe == true, file.shared == false, file.trashed == false,
              let permissions = file.permissions, !permissions.isEmpty else { return false }
        return permissions.allSatisfy { $0.id == accountID && $0.type == "user" && $0.role == "owner" && $0.deleted != true }
    }
    public static func validFileID(_ id: String) -> Bool {
        (8...256).contains(id.utf8.count) && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    public static func validUploadURL(_ value: String) -> Bool {
        guard value.utf8.count <= 8_192, let url = URLComponents(string: value), url.scheme == "https",
              url.host == "www.googleapis.com", url.port == nil, url.user == nil, url.password == nil,
              url.fragment == nil, url.path == "/upload/drive/v3/files",
              !(url.queryItems ?? []).contains(where: { ["access_token", "token", "key"].contains($0.name) }) else { return false }
        return true
    }
    /// Location is not part of the Drive grant. Keep source manifests intact.
    public static func exportManifest(_ value: SegmentManifest) -> SegmentManifest {
        .init(id: value.id, sessionID: value.sessionID, sequence: value.sequence, startedAt: value.startedAt,
              endedAt: value.endedAt, sampleRate: value.sampleRate, frameCount: value.frameCount,
              fileName: value.fileName, byteCount: value.byteCount, sha256: value.sha256,
              schemaVersion: value.schemaVersion, timeZoneIdentifier: value.timeZoneIdentifier, location: nil,
              recordingGroup: value.recordingGroup)
    }
    public static func readableTranscript(_ value: SegmentTranscript, manifest: SegmentManifest) -> Data {
        Data(("Record for Agent — 自动转写，可能有误\n片段ID: " + manifest.id.uuidString.lowercased()
            + "\n原音频SHA256: " + manifest.sha256 + "\n开始: " + ISO8601DateFormatter().string(from: manifest.startedAt)
            + "\n结束: " + ISO8601DateFormatter().string(from: manifest.endedAt) + "\n语言: " + value.locale + "\n\n" + value.text + "\n").utf8)
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func isDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func validateManifest(_ value: SegmentManifest) throws {
        try value.validateCaptureMetadata()
        guard value.schemaVersion == 1, value.byteCount > 0, value.byteCount <= 130 * 1_024 * 1_024,
              isDigest(value.sha256), value.frameCount > 0, value.sampleRate.isFinite, value.sampleRate > 0,
              value.startedAt.timeIntervalSince1970.isFinite, value.endedAt.timeIntervalSince1970.isFinite, value.endedAt >= value.startedAt,
              value.fileName == value.id.uuidString.lowercased() + ".caf" else { throw GoogleDriveLibraryError.changedManifest }
    }
}
