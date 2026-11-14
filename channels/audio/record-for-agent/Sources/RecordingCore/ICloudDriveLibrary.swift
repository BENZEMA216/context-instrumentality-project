import CryptoKit
import Darwin
import Foundation

public enum ICloudDriveLibraryError: LocalizedError, Equatable {
    case invalidState, notAuthorized, changedManifest, invalidSource, conflict, invalidMarker, unsafePath, cancelled, ioFailure
    case requiresRevalidation
    public var errorDescription: String? {
        switch self {
        case .invalidState: return "iCloud Drive 本机同步状态无法核对。"
        case .notAuthorized: return "录音不在 iCloud Drive 的授权范围内。"
        case .changedManifest: return "已登记录音的清单发生变化，未继续导出。"
        case .invalidSource: return "源录音的内容或文件身份未通过核对。"
        case .conflict: return "iCloud Drive 目标存在冲突，未覆盖已有文件。"
        case .invalidMarker: return "目标文件夹不属于这份 iCloud Drive 资料库。"
        case .unsafePath: return "文件路径包含符号链接或不安全成员。"
        case .cancelled: return "iCloud Drive 导出已暂停，未提交未完成的文件。"
        case .ioFailure: return "iCloud Drive 文件读写未完成，原录音仍保留。"
        case .requiresRevalidation: return "已导出录音的文件身份发生变化，需要单独复核；未重新读取或导出录音。"
        }
    }
}

public enum ICloudDriveRecordingScope: String, Codable, Sendable, CaseIterable {
    case existingAndFuture, futureOnly
}

public struct ICloudDriveArtifact: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case audio, manifest, transcriptJSON, transcriptText }
    public let kind: Kind
    public let sha256: String
    public let byteCount: Int64
    public let relativePath: String
    public var key: String { kind.rawValue + "-" + sha256 }
}

/// Identity is evidence for reusing a previously observed hash, not a new hash.
/// ctime is deliberately retained: restoring mtime does not hide an ordinary edit.
public struct ICloudDriveFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let byteCount: Int64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let changeSeconds: Int64
    public let changeNanoseconds: Int64
    fileprivate init(_ value: stat) {
        device = UInt64(UInt32(bitPattern: value.st_dev)); inode = UInt64(value.st_ino)
        byteCount = Int64(value.st_size)
        modificationSeconds = Int64(value.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changeSeconds = Int64(value.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

public struct ICloudDriveLibraryJob: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { manifest.id }
    public let libraryID: UUID
    public let manifest: SegmentManifest
    public fileprivate(set) var artifacts: [ICloudDriveArtifact]
    public fileprivate(set) var exportedKeys: Set<String>
    /// Only local evidence. Cloud upload status is owned by the Phone adapter.
    public fileprivate(set) var exportedFiles: [String: ICloudDriveFileIdentity]
}

/// Written last, after all referenced files have been verified and atomically
/// installed. This certifies a local export, never iCloud server availability.
public struct ICloudDriveExportReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let libraryID: UUID
    public let segmentID: UUID
    public let audioSHA256: String
    public let manifestSHA256: String
    public let exportDigest: String
    public let artifacts: [ICloudDriveArtifact]
    public let transcriptVersionSHA256: String?
    public let committedAt: Date
    public let localFileIdentities: [String: ICloudDriveFileIdentity]
    public var relativePath: String { "commits/" + segmentID.uuidString.lowercased() + "/" + exportDigest + ".json" }
}

public struct ICloudDriveLibraryMarker: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let libraryID: UUID
    public let format: String
    public init(libraryID: UUID) {
        schemaVersion = 1; self.libraryID = libraryID; format = "record-for-agent-icloud-drive"
    }
}

/// Exact, read-only marker failures. These are not evidence that the user chose
/// another folder: an unavailable provider entry must remain distinguishable
/// from a decoded marker that actually names a different library.
public enum ICloudDriveMarkerInspectionError: Error, Equatable, Sendable {
    case missingLibrary, missingMarker, invalidEncoding, libraryMismatch
    case unsafeEntry, changedDuringRead, systemCall(Int32)
}

/// This grant is independent of Google Drive, CloudKit and transport receipts.
/// Discovery never treats a Watch inventory or an in-flight transfer as received.
public struct ICloudDriveLibraryLedger: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let libraryID: UUID
    public private(set) var recordingScope: ICloudDriveRecordingScope?
    public private(set) var authorizedAt: Date?
    public private(set) var baselineIDs: Set<UUID>
    public private(set) var enabled: Bool
    public private(set) var jobs: [ICloudDriveLibraryJob]

    public init(libraryID: UUID = UUID()) {
        schemaVersion = 1; self.libraryID = libraryID; baselineIDs = []; enabled = false; jobs = []
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, libraryID, recordingScope, authorizedAt, baselineIDs, enabled, jobs
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(libraryID, forKey: .libraryID)
        try container.encodeIfPresent(recordingScope, forKey: .recordingScope)
        try container.encodeIfPresent(authorizedAt, forKey: .authorizedAt)
        // Set iteration is randomized across processes. Keep the schema-1
        // array representation so synthesized decoding accepts old orderings.
        try container.encode(baselineIDs.sorted { $0.uuidString < $1.uuidString }, forKey: .baselineIDs)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(jobs, forKey: .jobs)
    }
    public var exportedAudioCount: Int { jobs.filter { job in job.artifacts.contains { $0.kind == .audio && job.exportedKeys.contains($0.key) } }.count }
    public var exportedTranscriptCount: Int { jobs.filter { job in job.artifacts.contains { $0.kind == .transcriptJSON && job.exportedKeys.contains($0.key) } }.count }
    public var hasPendingFiles: Bool { jobs.contains { job in job.artifacts.contains { !job.exportedKeys.contains($0.key) } } }

    public mutating func authorize(_ scope: ICloudDriveRecordingScope, knownIDs: Set<UUID>, at date: Date = Date()) throws {
        guard recordingScope == nil, knownIDs.count <= 10_000, Self.validDate(date) else { throw ICloudDriveLibraryError.invalidState }
        recordingScope = scope; authorizedAt = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 * 1_000) / 1_000)
        baselineIDs = knownIDs; enabled = true
    }
    public mutating func setEnabled(_ value: Bool) throws {
        guard !value || recordingScope != nil else { throw ICloudDriveLibraryError.notAuthorized }
        enabled = value
    }
    public mutating func discover(manifests: [SegmentManifest], receivedIDs: Set<UUID>) throws {
        guard enabled, let scope = recordingScope, let authorizedAt else { return }
        guard manifests.count <= 10_000, Set(manifests.map(\.id)).count == manifests.count else { throw ICloudDriveLibraryError.invalidState }
        var candidate = self
        for manifest in manifests {
            if let old = candidate.jobs.first(where: { $0.id == manifest.id }) {
                guard old.manifest == manifest else { throw ICloudDriveLibraryError.changedManifest }
                continue
            }
            guard receivedIDs.contains(manifest.id), scope == .existingAndFuture ||
                    (!baselineIDs.contains(manifest.id) && manifest.startedAt >= authorizedAt) else { continue }
            try Self.validateManifest(manifest)
            let bytes = try TransportCodec.encode(Self.exportManifest(manifest))
            candidate.jobs.append(.init(libraryID: libraryID, manifest: manifest, artifacts: [
                Self.artifact(.audio, manifest: manifest, sha: manifest.sha256, count: manifest.byteCount),
                Self.artifact(.manifest, manifest: manifest, data: bytes)], exportedKeys: [], exportedFiles: [:]))
        }
        try candidate.validate(); self = candidate
    }
    public mutating func discoverTranscript(_ transcript: SegmentTranscript, for manifest: SegmentManifest) throws {
        try discoverTranscripts([(transcript: transcript, manifest: manifest)])
    }
    /// Register one discovery pass atomically. Each transcript keeps its exact
    /// authorized manifest binding; the entire resulting ledger is validated
    /// once, including unchanged and empty batches decoded from local storage.
    public mutating func discoverTranscripts(_ items: [(transcript: SegmentTranscript, manifest: SegmentManifest)]) throws {
        guard enabled else { throw ICloudDriveLibraryError.notAuthorized }
        guard items.count <= 10_000 else { throw ICloudDriveLibraryError.invalidState }
        var indices: [UUID: Int] = [:]
        for (index, job) in jobs.enumerated() {
            guard indices.updateValue(index, forKey: job.id) == nil else { throw ICloudDriveLibraryError.invalidState }
        }
        var candidate = self
        for (transcript, manifest) in items {
            guard let index = indices[manifest.id], candidate.jobs[index].manifest == manifest else {
                throw ICloudDriveLibraryError.notAuthorized
            }
            try transcript.validate(against: manifest)
            // The phone retains the current transcript body. Coalesce versions
            // never committed, while keeping every immutable exported version.
            let job = candidate.jobs[index]
            var artifacts = job.artifacts.filter {
                ($0.kind != .transcriptJSON && $0.kind != .transcriptText) || job.exportedKeys.contains($0.key)
            }
            for (kind, bytes) in [(ICloudDriveArtifact.Kind.transcriptJSON, try TransportCodec.encode(transcript)),
                                  (.transcriptText, Self.readableTranscript(transcript))] {
                let artifact = Self.artifact(kind, manifest: manifest, data: bytes)
                if !artifacts.contains(artifact) { artifacts.append(artifact) }
            }
            if artifacts != job.artifacts { candidate.jobs[index].artifacts = artifacts }
        }
        try candidate.validate(); self = candidate
    }
    public mutating func recordExported(_ receipt: ICloudDriveExportReceipt) throws {
        guard enabled, receipt.libraryID == libraryID,
              let index = jobs.firstIndex(where: { $0.id == receipt.segmentID }) else { throw ICloudDriveLibraryError.notAuthorized }
        try Self.validateReceipt(receipt, job: jobs[index])
        var candidate = self
        for artifact in receipt.artifacts {
            candidate.jobs[index].exportedKeys.insert(artifact.key)
            candidate.jobs[index].exportedFiles[artifact.key] = receipt.localFileIdentities[artifact.key]
        }
        try candidate.validate(); self = candidate
    }
    public func validate() throws {
        guard schemaVersion == 1, jobs.count <= 10_000, baselineIDs.count <= 10_000,
              (recordingScope == nil) == (authorizedAt == nil), !enabled || recordingScope != nil,
              authorizedAt.map(Self.validDate) ?? true, Set(jobs.map(\.id)).count == jobs.count,
              recordingScope != nil || (jobs.isEmpty && baselineIDs.isEmpty) else { throw ICloudDriveLibraryError.invalidState }
        for job in jobs {
            guard job.libraryID == libraryID else { throw ICloudDriveLibraryError.invalidState }
            try Self.validateManifest(job.manifest)
            if recordingScope == .futureOnly {
                guard !baselineIDs.contains(job.id), let authorizedAt, job.manifest.startedAt >= authorizedAt else { throw ICloudDriveLibraryError.invalidState }
            }
            let base = [Self.artifact(.audio, manifest: job.manifest, sha: job.manifest.sha256, count: job.manifest.byteCount),
                        Self.artifact(.manifest, manifest: job.manifest, data: try TransportCodec.encode(Self.exportManifest(job.manifest)))]
            guard job.artifacts.count >= 2, job.artifacts.count <= 258,
                  Set(job.artifacts.map(\.key)).count == job.artifacts.count,
                  base.allSatisfy(job.artifacts.contains),
                  job.artifacts.filter({ $0.kind == .audio || $0.kind == .manifest }).count == 2,
                  job.exportedKeys.isSubset(of: Set(job.artifacts.map(\.key))),
                  Set(job.exportedFiles.keys) == job.exportedKeys else { throw ICloudDriveLibraryError.invalidState }
            for artifact in job.artifacts {
                guard Self.validSHA(artifact.sha256), artifact.byteCount > 0, artifact.byteCount <= 130 * 1_024 * 1_024,
                      artifact == Self.artifact(artifact.kind, manifest: job.manifest, sha: artifact.sha256, count: artifact.byteCount),
                      job.exportedFiles[artifact.key].map({ $0.byteCount == artifact.byteCount }) ?? true else { throw ICloudDriveLibraryError.invalidState }
            }
        }
    }
    public static func exportManifest(_ manifest: SegmentManifest) -> SegmentManifest {
        .init(id: manifest.id, sessionID: manifest.sessionID, sequence: manifest.sequence,
              startedAt: manifest.startedAt, endedAt: manifest.endedAt, sampleRate: manifest.sampleRate,
              frameCount: manifest.frameCount, fileName: manifest.fileName, byteCount: manifest.byteCount,
              sha256: manifest.sha256, schemaVersion: manifest.schemaVersion,
              timeZoneIdentifier: manifest.timeZoneIdentifier, location: nil, recordingGroup: manifest.recordingGroup)
    }
    public static func readableTranscript(_ transcript: SegmentTranscript) -> Data { Data((transcript.text + "\n").utf8) }
    public static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    public static func exportDigest(_ artifacts: [ICloudDriveArtifact]) -> String {
        digest(Data(artifacts.sorted { $0.key < $1.key }.map { "\($0.kind.rawValue)\t\($0.sha256)\t\($0.byteCount)\t\($0.relativePath)\n" }.joined().utf8))
    }
    fileprivate static func validSHA(_ value: String) -> Bool { value.utf8.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    fileprivate static func validDate(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite && (0...253_402_300_799).contains(date.timeIntervalSince1970) }
    fileprivate static func validateManifest(_ manifest: SegmentManifest) throws {
        try RecordingRepository.validateManifest(manifest)
        guard validDate(manifest.startedAt), validDate(manifest.endedAt), manifest.byteCount <= 130 * 1_024 * 1_024 else { throw ICloudDriveLibraryError.invalidState }
    }
    fileprivate static func artifact(_ kind: ICloudDriveArtifact.Kind, manifest: SegmentManifest, data: Data) -> ICloudDriveArtifact {
        artifact(kind, manifest: manifest, sha: digest(data), count: Int64(data.count))
    }
    fileprivate static func artifact(_ kind: ICloudDriveArtifact.Kind, manifest: SegmentManifest, sha: String, count: Int64) -> ICloudDriveArtifact {
        if kind == .audio, let group = manifest.recordingGroup, let name = manifest.groupedAudioFileName {
            return .init(kind: kind, sha256: sha, byteCount: count,
                         relativePath: "audio/\(group.cloudName)/\(name)")
        }
        let directory: String, suffix: String
        switch kind {
        case .audio: directory = "audio"; suffix = "caf"
        case .manifest: directory = "manifests"; suffix = "json"
        case .transcriptJSON: directory = "transcripts"; suffix = "json"
        case .transcriptText: directory = "transcripts"; suffix = "txt"
        }
        return .init(kind: kind, sha256: sha, byteCount: count,
                     relativePath: directory + "/" + manifest.id.uuidString.lowercased() + "/" + sha + "." + suffix)
    }
    /// Marker bytes must decode as this library's marker. The file name is not proof.
    public static func provesMarker(_ data: Data, libraryID: UUID) -> Bool {
        (try? TransportCodec.decode(ICloudDriveLibraryMarker.self, from: data)) == ICloudDriveLibraryMarker(libraryID: libraryID)
    }
    /// Commit bytes must validate for this job and path. A digest in the file
    /// name, without those bytes, is not proof.
    public static func provesCommit(_ data: Data, relativePath: String, job: ICloudDriveLibraryJob) -> Bool {
        guard let receipt = try? TransportCodec.decode(ICloudDriveExportReceipt.self, from: data),
              receipt.relativePath == relativePath else { return false }
        return (try? validateReceipt(receipt, job: job)) != nil
    }
    fileprivate static func validateReceipt(_ receipt: ICloudDriveExportReceipt, job: ICloudDriveLibraryJob) throws {
        let artifacts = receipt.artifacts
        guard receipt.schemaVersion == 1, receipt.libraryID == job.libraryID,
              receipt.segmentID == job.id, receipt.audioSHA256 == job.manifest.sha256,
              receipt.artifacts == artifacts.sorted(by: { $0.key < $1.key }),
              artifacts.count == (receipt.transcriptVersionSHA256 == nil ? 2 : 4),
              Set(artifacts.map(\.key)).count == artifacts.count, artifacts.allSatisfy(job.artifacts.contains),
              artifacts.contains(where: { $0.kind == .audio }),
              artifacts.first(where: { $0.kind == .manifest })?.sha256 == receipt.manifestSHA256,
              receipt.exportDigest == exportDigest(artifacts), validDate(receipt.committedAt),
              Set(receipt.localFileIdentities.keys) == Set(artifacts.map(\.key)),
              artifacts.allSatisfy({ receipt.localFileIdentities[$0.key]?.byteCount == $0.byteCount }) else { throw ICloudDriveLibraryError.invalidState }
        if let version = receipt.transcriptVersionSHA256 {
            guard artifacts.first(where: { $0.kind == .transcriptJSON })?.sha256 == version,
                  artifacts.filter({ $0.kind == .transcriptText }).count == 1 else { throw ICloudDriveLibraryError.invalidState }
        }
    }
}

/// The caller resolves and holds the security-scoped destination bookmark and
/// coordinates this entire operation with NSFileCoordinator. No source is ever
/// deleted or written; no transfer ACK or iCloud-upload receipt is generated.
public struct ICloudDriveExportWriter: Sendable {
    public let root: URL
    public let libraryID: UUID
    public var libraryURL: URL { root.appendingPathComponent("RecordForAgent-" + libraryID.uuidString.lowercased(), isDirectory: true) }
    public init(root: URL, libraryID: UUID) { self.root = root; self.libraryID = libraryID }

    @discardableResult public func validateMarker(createIfMissing: Bool = false) throws -> URL {
        let directory = try openLibrary(create: createIfMissing, while: { true })
        close(directory); return libraryURL
    }

    /// Reads only this library's existing <=4 KiB marker. Never creates a
    /// directory or marker, adopts a copy, scans children, or reads recordings.
    public func inspectExistingMarker() throws {
        guard root.isFileURL else { throw ICloudDriveMarkerInspectionError.unsafeEntry }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw ICloudDriveMarkerInspectionError.systemCall(errno) }
        defer { close(rootFD) }
        let name = "RecordForAgent-" + libraryID.uuidString.lowercased()
        let libraryFD = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard libraryFD >= 0 else {
            let code = errno
            if code == ENOENT { throw ICloudDriveMarkerInspectionError.missingLibrary }
            if code == ELOOP || code == ENOTDIR { throw ICloudDriveMarkerInspectionError.unsafeEntry }
            throw ICloudDriveMarkerInspectionError.systemCall(code)
        }
        defer { close(libraryFD) }
        var libraryBefore = stat()
        guard fstat(libraryFD, &libraryBefore) == 0 else { throw ICloudDriveMarkerInspectionError.systemCall(errno) }
        let markerFD = openat(libraryFD, "library.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard markerFD >= 0 else {
            let code = errno
            if code == ENOENT { throw ICloudDriveMarkerInspectionError.missingMarker }
            if code == ELOOP { throw ICloudDriveMarkerInspectionError.unsafeEntry }
            throw ICloudDriveMarkerInspectionError.systemCall(code)
        }
        defer { close(markerFD) }
        var before = stat()
        guard fstat(markerFD, &before) == 0 else { throw ICloudDriveMarkerInspectionError.systemCall(errno) }
        guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else {
            throw ICloudDriveMarkerInspectionError.unsafeEntry
        }
        guard before.st_size >= 0, before.st_size <= 4_096 else {
            throw ICloudDriveMarkerInspectionError.invalidEncoding
        }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let amount = Darwin.read(markerFD, &buffer, buffer.count)
            if amount < 0 {
                if errno == EINTR { continue }
                throw ICloudDriveMarkerInspectionError.systemCall(errno)
            }
            if amount == 0 { break }
            guard bytes.count + amount <= 4_096 else { throw ICloudDriveMarkerInspectionError.invalidEncoding }
            bytes.append(contentsOf: buffer[0..<amount])
        }
        var after = stat(), current = stat()
        guard fstat(markerFD, &after) == 0 else { throw ICloudDriveMarkerInspectionError.systemCall(errno) }
        guard fstatat(libraryFD, "library.json", &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ICloudDriveMarkerInspectionError.systemCall(errno)
        }
        guard ICloudDriveFileIdentity(before) == ICloudDriveFileIdentity(after),
              ICloudDriveFileIdentity(after) == ICloudDriveFileIdentity(current),
              Int64(bytes.count) == before.st_size else {
            throw ICloudDriveMarkerInspectionError.changedDuringRead
        }
        var libraryCurrent = stat()
        guard fstatat(rootFD, name, &libraryCurrent, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ICloudDriveMarkerInspectionError.systemCall(errno)
        }
        guard libraryCurrent.st_mode & S_IFMT == S_IFDIR,
              libraryBefore.st_dev == libraryCurrent.st_dev, libraryBefore.st_ino == libraryCurrent.st_ino else {
            throw ICloudDriveMarkerInspectionError.changedDuringRead
        }
        let marker: ICloudDriveLibraryMarker
        do { marker = try TransportCodec.decode(ICloudDriveLibraryMarker.self, from: bytes) }
        catch { throw ICloudDriveMarkerInspectionError.invalidEncoding }
        guard marker == ICloudDriveLibraryMarker(libraryID: libraryID) else {
            throw ICloudDriveMarkerInspectionError.libraryMismatch
        }
    }

    public func export(job: ICloudDriveLibraryJob, audioURL: URL, transcript: SegmentTranscript? = nil,
                       revalidateLocalAudio: Bool = false,
                       while shouldContinue: @Sendable () -> Bool = { true }) throws -> ICloudDriveExportReceipt {
        try check(shouldContinue)
        guard job.libraryID == libraryID else { throw ICloudDriveLibraryError.notAuthorized }
        // A decoded/forged job must still satisfy the same structural checks.
        var validator = ICloudDriveLibraryLedger(libraryID: libraryID)
        try validator.authorize(.existingAndFuture, knownIDs: [])
        try validator.discover(manifests: [job.manifest], receivedIDs: [job.id])
        if let transcript { try validator.discoverTranscript(transcript, for: job.manifest) }
        var selected = validator.jobs[0].artifacts
        guard selected.allSatisfy(job.artifacts.contains) else { throw ICloudDriveLibraryError.notAuthorized }
        selected.sort { $0.key < $1.key }
        let directory = try openLibrary(create: true, while: shouldContinue)
        defer { close(directory) }
        let manifestBytes = try TransportCodec.encode(ICloudDriveLibraryLedger.exportManifest(job.manifest))
        var identities: [String: ICloudDriveFileIdentity] = [:]
        for artifact in selected {
            try check(shouldContinue)
            let bytes: Data?
            switch artifact.kind {
            case .audio: bytes = nil
            case .manifest: bytes = manifestBytes
            case .transcriptJSON: bytes = try transcript.map(TransportCodec.encode)
            case .transcriptText: bytes = transcript.map(ICloudDriveLibraryLedger.readableTranscript)
            }
            identities[artifact.key] = try install(artifact: artifact, data: bytes, source: audioURL,
                in: directory, cached: job.exportedFiles[artifact.key], revalidateLocalAudio: revalidateLocalAudio, while: shouldContinue)
        }
        try check(shouldContinue)
        // Check all retained paths again before committing. Hash observations are
        // bounded by this coordinated operation, not an atomic filesystem snapshot.
        for artifact in selected {
            try check(shouldContinue)
            let parent = try openParent(artifact.relativePath, in: directory, create: false)
            defer { close(parent.fd) }
            guard try pathIdentity(parent.leaf, in: parent.fd) == identities[artifact.key] else { throw ICloudDriveLibraryError.conflict }
        }
        let receipt = ICloudDriveExportReceipt(schemaVersion: 1, libraryID: libraryID, segmentID: job.id,
            audioSHA256: job.manifest.sha256, manifestSHA256: selected.first { $0.kind == .manifest }!.sha256,
            exportDigest: ICloudDriveLibraryLedger.exportDigest(selected), artifacts: selected,
            transcriptVersionSHA256: selected.first { $0.kind == .transcriptJSON }?.sha256,
            committedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 * 1_000) / 1_000),
            localFileIdentities: identities)
        try ICloudDriveLibraryLedger.validateReceipt(receipt, job: job)
        let parent = try openParent(receipt.relativePath, in: directory, create: true)
        defer { close(parent.fd) }
        if let data = try readIfPresent(parent.leaf, in: parent.fd, maximum: 128 * 1_024) {
            let old = try TransportCodec.decode(ICloudDriveExportReceipt.self, from: data)
            try ICloudDriveLibraryLedger.validateReceipt(old, job: job)
            guard old.libraryID == libraryID, old.artifacts == selected, old.exportDigest == receipt.exportDigest else { throw ICloudDriveLibraryError.conflict }
            // Preserve immutable commit bytes, while returning refreshed local evidence.
            try check(shouldContinue)
            return receipt
        }
        try check(shouldContinue)
        try atomicWrite(try TransportCodec.encode(receipt), leaf: parent.leaf, in: parent.fd, while: shouldContinue)
        return receipt
    }

    private func openLibrary(create: Bool, while shouldContinue: () -> Bool) throws -> Int32 {
        try check(shouldContinue)
        guard root.isFileURL else { throw ICloudDriveLibraryError.unsafePath }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw ICloudDriveLibraryError.unsafePath }
        defer { close(rootFD) }
        let name = "RecordForAgent-" + libraryID.uuidString.lowercased()
        var made = false
        if create {
            try check(shouldContinue)
            if mkdirat(rootFD, name, 0o700) == 0 { made = true }
            else if errno != EEXIST { throw ICloudDriveLibraryError.ioFailure }
        }
        let fd = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ICloudDriveLibraryError.invalidMarker }
        do {
            if let bytes = try readIfPresent("library.json", in: fd, maximum: 4_096) {
                let marker = try TransportCodec.decode(ICloudDriveLibraryMarker.self, from: bytes)
                guard marker == ICloudDriveLibraryMarker(libraryID: libraryID) else { throw ICloudDriveLibraryError.invalidMarker }
            } else {
                // Never adopt a pre-existing unmarked folder, even if it looks empty.
                guard made else { throw ICloudDriveLibraryError.invalidMarker }
                try atomicWrite(try TransportCodec.encode(ICloudDriveLibraryMarker(libraryID: libraryID)),
                                leaf: "library.json", in: fd, while: shouldContinue)
            }
            return fd
        } catch {
            close(fd)
            if made { _ = unlinkat(rootFD, name, AT_REMOVEDIR) }
            throw error
        }
    }

    private func install(artifact: ICloudDriveArtifact, data: Data?, source: URL, in directory: Int32,
                         cached: ICloudDriveFileIdentity?, revalidateLocalAudio: Bool, while shouldContinue: () -> Bool) throws -> ICloudDriveFileIdentity {
        let parent = try openParent(artifact.relativePath, in: directory, create: true)
        defer { close(parent.fd) }
        if let observed = try pathIdentity(parent.leaf, in: parent.fd) {
            // Metadata-only reuse avoids opening an evicted ubiquitous CAF,
            // which could otherwise ask the provider to download its content.
            if observed == cached { return observed }
            // A later text export must not silently reopen/hash an already
            // exported recording merely because a provider changed its stat
            // identity. Metadata cannot distinguish an attribute update from
            // edited bytes with a restored mtime. Keep this proof gap explicit.
            if artifact.kind == .audio, let cached {
                // Device-number and/or ctime drift may enter explicit full
                // revalidation of a locally present target. Neither is proof
                // of content identity: the digest and stable before/after stat
                // below must still match. Do not fetch evicted audio, replace
                // a changed destination, or use source audio as a fallback.
                guard revalidateLocalAudio,
                      observed.inode == cached.inode, observed.byteCount == cached.byteCount,
                      observed.modificationSeconds == cached.modificationSeconds,
                      observed.modificationNanoseconds == cached.modificationNanoseconds else {
                    throw ICloudDriveLibraryError.requiresRevalidation
                }
                let target = libraryURL.appendingPathComponent(artifact.relativePath)
                let resources = try target.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                if resources.isUbiquitousItem == true,
                   resources.ubiquitousItemDownloadingStatus != .current,
                   resources.ubiquitousItemDownloadingStatus != .downloaded {
                    throw ICloudDriveLibraryError.requiresRevalidation
                }
                var mode = stat()
                guard fstatat(parent.fd, parent.leaf, &mode, AT_SYMLINK_NOFOLLOW) == 0,
                      mode.st_mode & S_IRUSR != 0 else { throw ICloudDriveLibraryError.requiresRevalidation }
            }
            guard observed.byteCount == artifact.byteCount else { throw ICloudDriveLibraryError.conflict }
            let existing = openat(parent.fd, parent.leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard existing >= 0 else { throw ICloudDriveLibraryError.unsafePath }
            defer { close(existing) }
            let before = try identity(existing)
            guard before == observed else { throw ICloudDriveLibraryError.conflict }
            let actual = try hash(existing, into: nil, while: shouldContinue)
            guard actual.count == artifact.byteCount, actual.sha == artifact.sha256,
                  try identity(existing) == before else { throw ICloudDriveLibraryError.conflict }
            return before
        }
        // A missing already-exported destination is also an identity proof
        // gap, never implicit permission to reread and reexport its audio.
        if artifact.kind == .audio, cached != nil {
            throw ICloudDriveLibraryError.requiresRevalidation
        }
        let temp = ".partial-" + UUID().uuidString.lowercased()
        let fd = openat(parent.fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ICloudDriveLibraryError.ioFailure }
        defer { close(fd); unlinkat(parent.fd, temp, 0) }
        if let data {
            guard Int64(data.count) == artifact.byteCount, ICloudDriveLibraryLedger.digest(data) == artifact.sha256 else { throw ICloudDriveLibraryError.invalidState }
            try write(data, to: fd, while: shouldContinue)
        } else {
            guard source.isFileURL else { throw ICloudDriveLibraryError.invalidSource }
            let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard input >= 0 else { throw ICloudDriveLibraryError.invalidSource }
            defer { close(input) }
            let before = try identity(input)
            guard before.byteCount == artifact.byteCount else { throw ICloudDriveLibraryError.invalidSource }
            let actual = try hash(input, into: fd, while: shouldContinue)
            guard actual.count == artifact.byteCount, actual.sha == artifact.sha256,
                  try identity(input) == before else { throw ICloudDriveLibraryError.invalidSource }
            var atPath = stat()
            guard lstat(source.path, &atPath) == 0, ICloudDriveFileIdentity(atPath) == before,
                  atPath.st_mode & S_IFMT == S_IFREG else { throw ICloudDriveLibraryError.invalidSource }
        }
        guard fsync(fd) == 0 else { throw ICloudDriveLibraryError.ioFailure }
        try check(shouldContinue)
        guard renameatx_np(parent.fd, temp, parent.fd, parent.leaf, UInt32(RENAME_EXCL)) == 0 else {
            throw errno == EEXIST ? ICloudDriveLibraryError.conflict : ICloudDriveLibraryError.ioFailure
        }
        guard fsync(parent.fd) == 0 else { throw ICloudDriveLibraryError.ioFailure }
        let final = openat(parent.fd, parent.leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard final >= 0 else { throw ICloudDriveLibraryError.unsafePath }
        defer { close(final) }
        let written = try identity(fd), retained = try identity(final)
        guard written == retained, retained.byteCount == artifact.byteCount else { throw ICloudDriveLibraryError.conflict }
        return retained
    }

    private func openParent(_ relative: String, in rootFD: Int32, create: Bool) throws -> (fd: Int32, leaf: String) {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else { throw ICloudDriveLibraryError.unsafePath }
        var current = dup(rootFD)
        guard current >= 0 else { throw ICloudDriveLibraryError.ioFailure }
        do {
            for part in components.dropLast() {
                if create && mkdirat(current, part, 0o700) != 0 && errno != EEXIST { throw ICloudDriveLibraryError.ioFailure }
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ICloudDriveLibraryError.unsafePath }
                close(current); current = next
            }
            return (current, components.last!)
        } catch { close(current); throw error }
    }
    private func identity(_ fd: Int32) throws -> ICloudDriveFileIdentity {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw ICloudDriveLibraryError.ioFailure }
        return try identity(value)
    }
    private func pathIdentity(_ leaf: String, in directory: Int32) throws -> ICloudDriveFileIdentity? {
        var value = stat()
        if fstatat(directory, leaf, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw ICloudDriveLibraryError.unsafePath
        }
        return try identity(value)
    }
    private func identity(_ value: stat) throws -> ICloudDriveFileIdentity {
        guard value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else { throw ICloudDriveLibraryError.unsafePath }
        return ICloudDriveFileIdentity(value)
    }
    private func hash(_ input: Int32, into output: Int32?, while shouldContinue: () -> Bool) throws -> (sha: String, count: Int64) {
        var digest = SHA256(), count: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try check(shouldContinue)
            let amount = Darwin.read(input, &buffer, buffer.count)
            if amount < 0 { if errno == EINTR { continue }; throw ICloudDriveLibraryError.ioFailure }
            if amount == 0 { break }
            let bytes = Data(buffer[0..<amount]); digest.update(data: bytes); count += Int64(amount)
            if let output { try write(bytes, to: output, while: shouldContinue) }
        }
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
    private func write(_ data: Data, to fd: Int32, while shouldContinue: () -> Bool) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try check(shouldContinue)
                let amount = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), min(64 * 1_024, buffer.count - offset))
                if amount < 0 { if errno == EINTR { continue }; throw ICloudDriveLibraryError.ioFailure }
                guard amount > 0 else { throw ICloudDriveLibraryError.ioFailure }; offset += amount
            }
        }
    }
    private func readIfPresent(_ leaf: String, in directory: Int32, maximum: Int) throws -> Data? {
        let fd = openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw ICloudDriveLibraryError.unsafePath }
        defer { close(fd) }
        let before = try identity(fd)
        guard before.byteCount <= maximum else { throw ICloudDriveLibraryError.conflict }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let amount = Darwin.read(fd, &buffer, buffer.count)
            if amount < 0 { if errno == EINTR { continue }; throw ICloudDriveLibraryError.ioFailure }
            if amount == 0 { break }
            guard result.count + amount <= maximum else { throw ICloudDriveLibraryError.conflict }
            result.append(contentsOf: buffer[0..<amount])
        }
        guard try identity(fd) == before, Int64(result.count) == before.byteCount else { throw ICloudDriveLibraryError.conflict }
        return result
    }
    private func atomicWrite(_ data: Data, leaf: String, in directory: Int32, while shouldContinue: () -> Bool) throws {
        try check(shouldContinue)
        let temp = ".partial-" + UUID().uuidString.lowercased()
        let fd = openat(directory, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ICloudDriveLibraryError.ioFailure }
        defer { close(fd); unlinkat(directory, temp, 0) }
        try write(data, to: fd, while: shouldContinue)
        guard fsync(fd) == 0 else { throw ICloudDriveLibraryError.ioFailure }
        try check(shouldContinue)
        guard renameatx_np(directory, temp, directory, leaf, UInt32(RENAME_EXCL)) == 0 else { throw ICloudDriveLibraryError.conflict }
        guard fsync(directory) == 0 else { throw ICloudDriveLibraryError.ioFailure }
    }
    private func check(_ shouldContinue: () -> Bool) throws { if !shouldContinue() { throw ICloudDriveLibraryError.cancelled } }
}
