import Foundation
import CryptoKit
import Darwin

public enum RecordingIntegrityMode: String, Codable, Sendable { case quick, full }

/// A fast check can reuse a historical digest, but never labels it as a new content read.
public enum RecordingIntegrityVerification: String, Codable, Sendable {
    case currentHash, checkpointHashMetadataUnchanged, historicalHashMetadataUnchanged, acknowledgedPruned, failed
}

public struct RecordingIntegrityFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let mode: UInt32
    public let linkCount: UInt64
    public let byteCount: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    public let birthSeconds: Int64
    public let birthNanoseconds: Int64

    fileprivate init(_ value: stat) {
        device = UInt64(UInt32(bitPattern: value.st_dev))
        inode = UInt64(value.st_ino)
        mode = UInt32(value.st_mode)
        linkCount = UInt64(value.st_nlink)
        byteCount = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        birthSeconds = Int64(value.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
    }

    fileprivate var isRegular: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) && linkCount == 1 }
    fileprivate var isDirectory: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
    fileprivate var generation: String { "\(device):\(inode):\(birthSeconds):\(birthNanoseconds)" }
}

public struct RecordingIntegrityIssue: Codable, Equatable, Sendable {
    public let code: String
    public let relativePath: String?
    public init(code: String, relativePath: String? = nil) { self.code = code; self.relativePath = relativePath }
}

public struct RecordingIntegrityEntry: Codable, Equatable, Sendable {
    public let relativePath: String
    /// sealed_audio, recovered_original, manifest, acknowledgement, receipt, or session.
    public let sourceKind: String
    public let segmentID: UUID?
    public let manifestSHA256: String?
    public let expectedSHA256: String?
    public let observedSHA256: String?
    public let expectedByteCount: Int64?
    public let identity: RecordingIntegrityFileIdentity?
    public let verification: RecordingIntegrityVerification
    /// Bytes physically read in this invocation, not the historical file size.
    public let bytesHashed: Int64
    public let hashObservedAt: Date?
    public let issueCode: String?
}

/// Persist outside the recording source tree. Baselines are local trusted-app observations,
/// not hardware attestations or authority to delete, restore, or acknowledge recordings.
public struct RecordingIntegrityBaseline: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let libraryGeneration: String
    public let rootIdentity: String
    public let catalogDigest: String
    public let createdAt: Date
    public let entries: [RecordingIntegrityEntry]
}

/// All entries refer to actual reads in one bounded observation window. This is a
/// trusted local checkpoint, not an externally supplied claim or a global snapshot.
public struct RecordingIntegrityCheckpoint: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let nonce: String
    public let mode: RecordingIntegrityMode
    public let libraryGeneration: String
    public let rootIdentity: String
    public let catalogDigest: String
    public let startedAt: Date
    public let entries: [RecordingIntegrityEntry]
    /// Raw small identity-bearing JSON from this observation window, never audio.
    /// Each cached value is bound to the entry's actual SHA, stat, and catalog.
    public let metadataData: [String: Data]

    public init(schemaVersion: Int, nonce: String, mode: RecordingIntegrityMode,
                libraryGeneration: String, rootIdentity: String, catalogDigest: String,
                startedAt: Date, entries: [RecordingIntegrityEntry], metadataData: [String: Data] = [:]) {
        self.schemaVersion = schemaVersion; self.nonce = nonce; self.mode = mode
        self.libraryGeneration = libraryGeneration; self.rootIdentity = rootIdentity
        self.catalogDigest = catalogDigest; self.startedAt = startedAt
        self.entries = entries; self.metadataData = metadataData
    }
}

public struct RecordingIntegrityReport: Codable, Sendable {
    public let schemaVersion: Int
    public let nonce: String
    public let mode: RecordingIntegrityMode
    public let libraryGeneration: String
    public let rootIdentity: String
    public let catalogDigest: String
    public let startedAt: Date
    public let endedAt: Date
    public let nonAtomicSnapshot: Bool
    public let isComplete: Bool
    public let passed: Bool
    /// True only for a successful full audit: every retained audio file was actually
    /// read in this nonce's bounded observation window, possibly across short calls.
    public let fullContentVerified: Bool
    public let expectedSourceCount: Int
    public let retainedAudioCount: Int
    public let recoveredOriginalCount: Int
    public let acknowledgedPrunedCount: Int
    public let currentHashCount: Int
    public let historicalHashCount: Int
    public let bytesHashed: Int64
    public let filesHashedThisCall: Int
    public let filesHashedInObservationWindow: Int
    public let bytesHashedInObservationWindow: Int64
    public let checkpoint: RecordingIntegrityCheckpoint
    public let entries: [RecordingIntegrityEntry]
    public let issues: [RecordingIntegrityIssue]
    public let nextBaseline: RecordingIntegrityBaseline?
}

public enum RecordingIntegrityAuditError: Error, Equatable {
    case invalidRequest
    case invalidRoot
    case invalidCheckpoint(String)
}

/// Read-only, bounded-memory audit of sealed recordings and their identity-bearing metadata.
/// It deliberately does not construct RecordingRepository (whose initialization can recover
/// transactions), synchronize source files, transfer audio, or mutate any recording state.
public final class RecordingIntegrityAuditor {
    private let root: URL
    private let generation: String
    private let fm = FileManager.default
    private static let metadataLimit = 1_048_576
    private static let metadataCacheLimit = 16 * 1_048_576

    public init(root: URL, libraryGeneration: String) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.generation = libraryGeneration
    }

    public static func libraryGeneration(at root: URL) throws -> String {
        let identity = try statIdentity(root.standardizedFileURL.resolvingSymlinksInPath())
        guard identity.isDirectory else { throw RecordingIntegrityAuditError.invalidRoot }
        return identity.generation
    }

    public func audit(mode: RecordingIntegrityMode, nonce: String,
                      baseline: RecordingIntegrityBaseline? = nil,
                      checkpoint: RecordingIntegrityCheckpoint? = nil,
                      checkpointInterval: TimeInterval = 0,
                      while shouldContinue: () -> Bool = { true },
                      onCheckpoint: ((RecordingIntegrityCheckpoint) -> Void)? = nil) throws -> RecordingIntegrityReport {
        guard !generation.isEmpty, generation.utf8.count <= 256,
              !nonce.isEmpty, nonce.utf8.count <= 256,
              checkpointInterval.isFinite, checkpointInterval >= 0 else { throw RecordingIntegrityAuditError.invalidRequest }
        let callStarted = Self.timestamp()
        let started = checkpoint?.startedAt ?? callStarted
        let rootStart = try Self.statIdentity(root)
        guard rootStart.isDirectory else { throw RecordingIntegrityAuditError.invalidRoot }
        var issues: [RecordingIntegrityIssue] = []
        var entries: [RecordingIntegrityEntry] = []
        let usableBaseline: RecordingIntegrityBaseline?
        if let baseline {
            if baseline.schemaVersion == 1 && baseline.libraryGeneration == generation && baseline.rootIdentity == rootStart.generation {
                usableBaseline = baseline
            } else {
                usableBaseline = nil
                issues.append(.init(code: "baseline_generation_mismatch"))
            }
        } else { usableBaseline = nil }
        var previous: [String: RecordingIntegrityEntry] = [:]
        for entry in usableBaseline?.entries ?? [] {
            if previous.updateValue(entry, forKey: entry.relativePath) != nil {
                issues.append(.init(code: "duplicate_baseline_path", relativePath: entry.relativePath))
            }
        }
        let initial = catalog()
        issues += initial.issues
        var checkpointEntries: [String: RecordingIntegrityEntry] = [:]
        var checkpointMetadata: [String: Data] = [:]
        var metadataCacheBytes = 0
        var lastCheckpointEmission = -Double.infinity
        if let checkpoint {
            guard checkpoint.schemaVersion == 1, checkpoint.nonce == nonce, checkpoint.mode == mode,
                  checkpoint.libraryGeneration == generation, checkpoint.rootIdentity == rootStart.generation,
                  checkpoint.catalogDigest == initial.digest else {
                throw RecordingIntegrityAuditError.invalidCheckpoint("checkpoint_identity_or_catalog_changed")
            }
            guard callStarted.timeIntervalSince(started) >= -5, callStarted.timeIntervalSince(started) <= 3_600 else {
                throw RecordingIntegrityAuditError.invalidCheckpoint("checkpoint_observation_window_expired")
            }
            let members = Dictionary(uniqueKeysWithValues: initial.files.map { ($0.path, $0) })
            for entry in checkpoint.entries {
                guard checkpointEntries[entry.relativePath] == nil,
                      let member = members[entry.relativePath], member.identity == entry.identity,
                      member.kind == entry.sourceKind,
                      entry.verification == .currentHash || entry.verification == .checkpointHashMetadataUnchanged,
                      let digest = entry.observedSHA256, Self.isDigest(digest),
                      let observed = entry.hashObservedAt, observed >= started.addingTimeInterval(-0.001),
                      observed <= callStarted.addingTimeInterval(5),
                      entry.expectedSHA256 == nil || entry.expectedSHA256 == digest else {
                    throw RecordingIntegrityAuditError.invalidCheckpoint("checkpoint_entry_changed_or_invalid")
                }
                checkpointEntries[entry.relativePath] = entry
            }
            for (path, data) in checkpoint.metadataData {
                guard let entry = checkpointEntries[path], let member = members[path],
                      member.kind != "sealed_audio", member.kind != "recovered_original",
                      data.count <= Self.metadataLimit, Int64(data.count) == entry.identity?.byteCount,
                      Self.digest(data) == entry.observedSHA256 else {
                    throw RecordingIntegrityAuditError.invalidCheckpoint("checkpoint_metadata_digest_mismatch")
                }
                metadataCacheBytes += data.count
                guard metadataCacheBytes <= Self.metadataCacheLimit else {
                    throw RecordingIntegrityAuditError.invalidCheckpoint("checkpoint_metadata_capacity_exceeded")
                }
                checkpointMetadata[path] = data
            }
        }
        func makeCheckpoint() -> RecordingIntegrityCheckpoint {
            .init(schemaVersion: 1, nonce: nonce, mode: mode, libraryGeneration: generation,
                  rootIdentity: rootStart.generation, catalogDigest: initial.digest, startedAt: started,
                  entries: checkpointEntries.values.sorted { $0.relativePath < $1.relativePath },
                  metadataData: checkpointMetadata)
        }
        func saveCheckpoint(_ entry: RecordingIntegrityEntry, data: Data? = nil) {
            if entry.verification == .currentHash || entry.verification == .checkpointHashMetadataUnchanged {
                if let data, checkpointMetadata[entry.relativePath] == nil {
                    guard metadataCacheBytes + data.count <= Self.metadataCacheLimit else {
                        issues.append(.init(code: "metadata_checkpoint_capacity_exceeded", relativePath: entry.relativePath))
                        return
                    }
                    checkpointMetadata[entry.relativePath] = data
                    metadataCacheBytes += data.count
                }
                checkpointEntries[entry.relativePath] = entry
                // Gate before sorting/copying the growing snapshot. The final report
                // always carries all successful reads, including ones not emitted here.
                if entry.verification == .currentHash, let onCheckpoint {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastCheckpointEmission >= checkpointInterval {
                        lastCheckpointEmission = now
                        onCheckpoint(makeCheckpoint())
                    }
                }
            }
        }
        var cancelled = !shouldContinue()
        var manifests: [UUID: SegmentManifest] = [:]
        var manifestDigests: [UUID: String] = [:]
        var acknowledgements: [UUID: SegmentReceipt] = [:]
        var receipts: [UUID: SegmentReceipt] = [:]
        // A new nonce reads metadata afresh. Same-window resumptions parse verified
        // cached bytes, so a short budget can advance beyond a large metadata catalog.
        for item in initial.files where item.kind != "sealed_audio" && item.kind != "recovered_original" {
            if cancelled { break }
            let result: (entry: RecordingIntegrityEntry, data: Data?)
            if let cached = checkpointMetadata[item.path], let entry = checkpointEntries[item.path] {
                result = (.init(relativePath: entry.relativePath, sourceKind: entry.sourceKind,
                    segmentID: entry.segmentID, manifestSHA256: entry.manifestSHA256,
                    expectedSHA256: entry.expectedSHA256, observedSHA256: entry.observedSHA256,
                    expectedByteCount: entry.expectedByteCount, identity: entry.identity,
                    verification: .checkpointHashMetadataUnchanged, bytesHashed: 0,
                    hashObservedAt: entry.hashObservedAt, issueCode: nil), cached)
            } else {
                guard shouldContinue() else { cancelled = true; break }
                result = inspect(item, previous: nil, mode: .full, shouldContinue: shouldContinue, captureData: true)
            }
            entries.append(result.entry)
            saveCheckpoint(result.entry, data: result.data)
            if let issue = result.entry.issueCode { issues.append(.init(code: issue, relativePath: item.path)) }
            guard result.entry.verification == .currentHash || result.entry.verification == .checkpointHashMetadataUnchanged,
                  let data = result.data else {
                if result.entry.issueCode == "interrupted" { cancelled = true; break }
                continue
            }
            do {
                switch item.kind {
                case "manifest":
                    let manifest = try TransportCodec.decode(SegmentManifest.self, from: data)
                    try RecordingRepository.validateManifest(manifest)
                    guard item.name == manifest.id.uuidString.lowercased() + ".json", manifests[manifest.id] == nil else { throw Invalid.invalid }
                    manifests[manifest.id] = manifest
                    manifestDigests[manifest.id] = result.entry.observedSHA256
                    if let old = previous[item.path], old.observedSHA256 != result.entry.observedSHA256 {
                        issues.append(.init(code: "source_manifest_changed", relativePath: item.path))
                    }
                case "acknowledgement", "receipt":
                    let receipt = try TransportCodec.decode(SegmentReceipt.self, from: data)
                    guard item.name == receipt.segmentID.uuidString.lowercased() + ".json",
                          Self.isDigest(receipt.sha256), receipt.byteCount > 0,
                          receipt.receivedAt.timeIntervalSince1970.isFinite else { throw Invalid.invalid }
                    if item.kind == "acknowledgement" { acknowledgements[receipt.segmentID] = receipt }
                    else { receipts[receipt.segmentID] = receipt }
                case "session":
                    let session = try TransportCodec.decode(RecordingSession.self, from: data)
                    guard item.name == session.id.uuidString.lowercased() + ".json",
                          [session.startedAt, session.updatedAt].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
                          [session.endedAt, session.lastAudioAt, session.lastSealedAt, session.currentSegmentStartedAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }) else { throw Invalid.invalid }
                    if [.recording, .starting, .interrupted].contains(session.state) || session.currentSegmentStartedAt != nil {
                        issues.append(.init(code: "open_recording_session", relativePath: item.path))
                    }
                default: break
                }
            } catch { issues.append(.init(code: "malformed_\(item.kind)", relativePath: item.path)) }
        }
        let audioNames = Set(initial.files.filter { $0.kind == "sealed_audio" }.map(\.name))
        for (id, receipt) in acknowledgements {
            guard let manifest = manifests[id], receipt.sha256 == manifest.sha256, receipt.byteCount == manifest.byteCount else {
                issues.append(.init(code: "acknowledgement_identity_mismatch", relativePath: "acknowledgements/\(id.uuidString.lowercased()).json")); continue
            }
        }
        for (id, receipt) in receipts {
            guard let manifest = manifests[id], receipt.sha256 == manifest.sha256, receipt.byteCount == manifest.byteCount else {
                issues.append(.init(code: "receipt_identity_mismatch", relativePath: "receipts/\(id.uuidString.lowercased()).json")); continue
            }
        }
        if !cancelled {
            for manifest in manifests.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where !audioNames.contains(manifest.fileName) {
                let receipt = acknowledgements[manifest.id]
                let validPrune = receipt?.sha256 == manifest.sha256 && receipt?.byteCount == manifest.byteCount
                let path = "segments/" + manifest.fileName
                entries.append(.init(relativePath: path, sourceKind: "sealed_audio", segmentID: manifest.id,
                    manifestSHA256: manifestDigests[manifest.id], expectedSHA256: manifest.sha256, observedSHA256: nil,
                    expectedByteCount: manifest.byteCount, identity: nil,
                    verification: validPrune ? .acknowledgedPruned : .failed,
                    bytesHashed: 0, hashObservedAt: nil, issueCode: validPrune ? nil : "missing_audio"))
                if !validPrune { issues.append(.init(code: "missing_audio", relativePath: path)) }
            }
            for var item in initial.files where item.kind == "sealed_audio" || item.kind == "recovered_original" {
                guard shouldContinue() else { cancelled = true; break }
                if item.kind == "sealed_audio" {
                    guard let id = UUID(uuidString: String(item.name.dropLast(4))), let manifest = manifests[id], manifest.fileName == item.name else {
                        issues.append(.init(code: "untracked_audio", relativePath: item.path)); continue
                    }
                    item.id = id; item.expectedDigest = manifest.sha256; item.expectedBytes = manifest.byteCount
                    item.manifestDigest = manifestDigests[id]
                } else if let old = previous[item.path] {
                    // A preserved recovery original has no manifest: once baselined, keep its
                    // independently observed digest as its subsequent expected content.
                    item.expectedDigest = old.observedSHA256
                    item.expectedBytes = old.identity?.byteCount
                }
                let resumed = checkpointEntries[item.path]
                let result = inspect(item, previous: resumed ?? previous[item.path], mode: mode,
                                     shouldContinue: shouldContinue, fromCheckpoint: resumed != nil)
                entries.append(result.entry)
                saveCheckpoint(result.entry)
                if let issue = result.entry.issueCode { issues.append(.init(code: issue, relativePath: item.path)) }
                if result.entry.issueCode == "interrupted" { cancelled = true; break }
            }
        }
        let currentPaths = Set(initial.files.map(\.path))
        if !cancelled {
            for old in usableBaseline?.entries ?? [] {
                // Only a complete metadata parse can distinguish a legal ACK prune
                // from a missing member. Cancellation is not evidence of data loss.
                if !currentPaths.contains(old.relativePath), !entries.contains(where: { $0.relativePath == old.relativePath && $0.verification == .acknowledgedPruned }) {
                    issues.append(.init(code: "baseline_member_missing", relativePath: old.relativePath))
                }
            }
        }
        let final = catalog()
        issues += final.issues
        if initial.digest != final.digest { issues.append(.init(code: "catalog_changed_during_audit")) }
        for entry in entries where entry.identity != nil {
            if (try? Self.statIdentity(root.appendingPathComponent(entry.relativePath))) != entry.identity {
                issues.append(.init(code: "file_changed_after_observation", relativePath: entry.relativePath))
            }
        }
        if (try? Self.statIdentity(root).generation) != rootStart.generation { issues.append(.init(code: "root_identity_changed")) }
        if cancelled { issues.append(.init(code: "interrupted")) }
        let ended = Self.timestamp()
        if ended.timeIntervalSince(started) > 3_600 { issues.append(.init(code: "observation_window_expired")) }
        if ended < callStarted { issues.append(.init(code: "observation_clock_moved_backwards")) }
        let complete = !cancelled && initial.digest == final.digest && !issues.contains(where: { $0.code == "directory_unavailable" || $0.code == "catalog_changed_during_audit" })
        let passed = complete && issues.isEmpty
        let ordered = entries.sorted { $0.relativePath < $1.relativePath }
        let next = passed ? RecordingIntegrityBaseline(schemaVersion: 1, libraryGeneration: generation,
            rootIdentity: rootStart.generation, catalogDigest: initial.digest, createdAt: ended, entries: ordered) : nil
        return RecordingIntegrityReport(schemaVersion: 1, nonce: nonce, mode: mode, libraryGeneration: generation,
            rootIdentity: rootStart.generation, catalogDigest: initial.digest, startedAt: started, endedAt: ended,
            nonAtomicSnapshot: true, isComplete: complete, passed: passed, fullContentVerified: mode == .full && passed,
            expectedSourceCount: manifests.count,
            retainedAudioCount: initial.files.filter { $0.kind == "sealed_audio" }.count,
            recoveredOriginalCount: initial.files.filter { $0.kind == "recovered_original" }.count,
            acknowledgedPrunedCount: entries.filter { $0.verification == .acknowledgedPruned }.count,
            currentHashCount: entries.filter { $0.verification == .currentHash }.count,
            historicalHashCount: entries.filter { $0.verification == .historicalHashMetadataUnchanged }.count,
            bytesHashed: entries.reduce(0) { $0 + $1.bytesHashed },
            filesHashedThisCall: entries.filter { $0.verification == .currentHash }.count,
            filesHashedInObservationWindow: entries.filter { $0.verification == .currentHash || $0.verification == .checkpointHashMetadataUnchanged }.count,
            bytesHashedInObservationWindow: entries.filter { $0.verification == .currentHash || $0.verification == .checkpointHashMetadataUnchanged }.reduce(0) { $0 + ($1.identity?.byteCount ?? 0) },
            checkpoint: makeCheckpoint(), entries: ordered, issues: issues, nextBaseline: next)
    }

    private struct Item: Codable {
        let path: String; let name: String; let kind: String
        var id: UUID? = nil; var expectedDigest: String? = nil
        var expectedBytes: Int64? = nil; var manifestDigest: String? = nil
        var identity: RecordingIntegrityFileIdentity? = nil
    }
    private struct Catalog { let files: [Item]; let digest: String; let issues: [RecordingIntegrityIssue] }
    private enum Invalid: Error { case invalid, changed, interrupted, oversize }

    private func catalog() -> Catalog {
        var files: [Item] = []
        var issues: [RecordingIntegrityIssue] = []
        let folders: [(String, String, String, Bool)] = [
            ("manifests", "manifest", "json", true), ("segments", "sealed_audio", "caf", true),
            ("acknowledgements", "acknowledgement", "json", true), ("receipts", "receipt", "json", true),
            ("sessions", "session", "json", true), ("recovered-originals", "recovered_original", "caf", false),
            ("staging", "staging", "", true), ("recovery-staging", "staging", "", false),
            ("open-segments", "open", "", false)
        ]
        for (folder, kind, suffix, required) in folders {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            let exists = (try? Self.statIdentity(directory)) != nil
            do {
                let directoryIdentity = try Self.statIdentity(directory)
                guard directoryIdentity.isDirectory else { throw Invalid.invalid }
                for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = child.lastPathComponent
                    let path = folder + "/" + name
                    if kind == "staging" || kind == "open" { issues.append(.init(code: "unsealed_recording_material", relativePath: path)); continue }
                    let identity = try Self.statIdentity(child)
                    guard identity.isRegular, child.pathExtension == suffix else {
                        issues.append(.init(code: "unexpected_library_member", relativePath: path)); continue
                    }
                    files.append(Item(path: path, name: name, kind: kind, identity: identity))
                }
            } catch {
                if required || exists { issues.append(.init(code: "directory_unavailable", relativePath: folder)) }
            }
        }
        let data = (try? TransportCodec.encode(files.sorted { $0.path < $1.path })) ?? Data()
        return Catalog(files: files, digest: Self.digest(data), issues: issues)
    }

    private func inspect(_ item: Item, previous: RecordingIntegrityEntry?, mode: RecordingIntegrityMode,
                         shouldContinue: () -> Bool, captureData: Bool = false,
                         fromCheckpoint: Bool = false) -> (entry: RecordingIntegrityEntry, data: Data?) {
        var identity: RecordingIntegrityFileIdentity?
        var observed: String?
        var observedAt: Date?
        var readBytes: Int64 = 0
        var data = Data()
        var verification = RecordingIntegrityVerification.failed
        var issue: String?
        do {
            let url = root.appendingPathComponent(item.path)
            let before = try Self.statIdentity(url)
            identity = before
            guard before.isRegular else { throw Invalid.invalid }
            if let expected = item.expectedBytes, before.byteCount != expected { issue = "byte_count_mismatch" }
            let canReuse = (mode == .quick || fromCheckpoint) && issue == nil && previous?.identity == before &&
                previous?.manifestSHA256 == item.manifestDigest && previous?.observedSHA256 != nil &&
                (previous?.expectedSHA256 == item.expectedDigest || (item.kind == "recovered_original" && previous?.observedSHA256 == item.expectedDigest)) &&
                (previous?.verification == .currentHash || previous?.verification == .historicalHashMetadataUnchanged || previous?.verification == .checkpointHashMetadataUnchanged) &&
                (item.expectedDigest == nil || previous?.observedSHA256 == item.expectedDigest)
            if canReuse, let previous {
                observed = previous.observedSHA256; observedAt = previous.hashObservedAt
                verification = fromCheckpoint ? .checkpointHashMetadataUnchanged : .historicalHashMetadataUnchanged
            } else {
                let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw Invalid.invalid }
                defer { Darwin.close(fd) }
                var openStat = stat()
                guard fstat(fd, &openStat) == 0, RecordingIntegrityFileIdentity(openStat) == before else { throw Invalid.changed }
                var hasher = SHA256()
                var buffer = [UInt8](repeating: 0, count: 256 * 1024)
                while true {
                    guard shouldContinue() else { throw Invalid.interrupted }
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count < 0 { if errno == EINTR { continue }; throw Invalid.invalid }
                    if count == 0 { break }
                    let chunk = Data(buffer.prefix(count))
                    hasher.update(data: chunk); readBytes += Int64(count)
                    guard readBytes <= before.byteCount else { throw Invalid.changed }
                    if captureData {
                        guard readBytes <= Self.metadataLimit else { throw Invalid.oversize }
                        data.append(chunk)
                    }
                }
                guard fstat(fd, &openStat) == 0, RecordingIntegrityFileIdentity(openStat) == before,
                      try Self.statIdentity(url) == before, readBytes == before.byteCount else { throw Invalid.changed }
                observed = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                observedAt = Self.timestamp()
                if let expected = item.expectedDigest, observed != expected { issue = "checksum_mismatch" }
                verification = issue == nil ? .currentHash : .failed
            }
            guard try Self.statIdentity(url) == before else { throw Invalid.changed }
        } catch Invalid.interrupted { issue = "interrupted"; verification = .failed
        } catch Invalid.changed { issue = "file_changed_during_read"; verification = .failed
        } catch Invalid.oversize { issue = "metadata_too_large"; verification = .failed
        } catch { issue = "unreadable_or_unsafe_file"; verification = .failed }
        return (.init(relativePath: item.path, sourceKind: item.kind, segmentID: item.id,
            manifestSHA256: item.manifestDigest, expectedSHA256: item.expectedDigest, observedSHA256: observed,
            expectedByteCount: item.expectedBytes, identity: identity, verification: verification,
            bytesHashed: readBytes, hashObservedAt: observedAt, issueCode: issue), captureData && verification == .currentHash ? data : nil)
    }

    private static func statIdentity(_ url: URL) throws -> RecordingIntegrityFileIdentity {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw Invalid.invalid }
        return .init(value)
    }
    private static func timestamp() -> Date { Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1_000).rounded() / 1_000) }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func isDigest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
}
