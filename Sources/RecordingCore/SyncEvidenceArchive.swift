import Foundation
import CryptoKit
import Darwin

/// Why the latest retained iCloud metadata observation may (or may not) be
/// considered current. This diagnostic never grants provider confirmation.
public enum SyncEvidenceICloudProviderGate: String, Codable, CaseIterable, Sendable {
    case current, unchecked
    case replayPending = "replay_pending"
    case contextUnavailable = "context_unavailable"
    case awaitingLocalExport = "awaiting_local_export"
}

/// A projection of existing metadata. These reports never authorize ACKs,
/// audio deletion, upload, or content validation.
public struct SyncEvidenceArtifact: Codable, Equatable, Sendable {
    public let kind: String
    public let sha256: String
    public let byteCount: Int64
    public let state: String
    public let recordedAtMS: Int64?
    public let observedAtMS: Int64?
    public let origin: String
    public let uploadCorrelation: GoogleDriveUploadCorrelation?
    /// Optional for archives written before these path-free diagnostics existed.
    /// The retained last check is kept even when a gate hides current evidence.
    public let localExportedAtMS: Int64?
    public let providerCheckedAtMS: Int64?
    public let providerResult: ICloudDriveProviderObservationStatus?
    public let providerGate: SyncEvidenceICloudProviderGate?
    public init(kind: String, sha256: String, byteCount: Int64, state: String,
                recordedAtMS: Int64? = nil, observedAtMS: Int64? = nil, origin: String,
                uploadCorrelation: GoogleDriveUploadCorrelation? = nil,
                localExportedAtMS: Int64? = nil, providerCheckedAtMS: Int64? = nil,
                providerResult: ICloudDriveProviderObservationStatus? = nil,
                providerGate: SyncEvidenceICloudProviderGate? = nil) {
        self.kind = kind; self.sha256 = sha256; self.byteCount = byteCount; self.state = state
        self.recordedAtMS = recordedAtMS; self.observedAtMS = observedAtMS; self.origin = origin
        self.uploadCorrelation = uploadCorrelation
        self.localExportedAtMS = localExportedAtMS; self.providerCheckedAtMS = providerCheckedAtMS
        self.providerResult = providerResult; self.providerGate = providerGate
    }
}

public struct SyncEvidenceCommit: Codable, Equatable, Sendable {
    public let exportDigest: String
    public let providerUploaded: Bool
    public let observedAtMS: Int64?
    public init(exportDigest: String, providerUploaded: Bool, observedAtMS: Int64? = nil) {
        self.exportDigest = exportDigest; self.providerUploaded = providerUploaded; self.observedAtMS = observedAtMS
    }
}

public struct SyncEvidenceSource: Codable, Equatable, Sendable {
    public let segmentID: UUID
    public let sha256: String
    public let byteCount: Int64
    public let startedAtMS: Int64
    public let origin: String
    public let receiptAtMS: Int64?
    public let firstObservedAtMS: Int64?
    public let lastObservedAtMS: Int64?
    public let receiptWasPresent: Bool?
    public let foreground: Bool?
    public let artifacts: [SyncEvidenceArtifact]
    public let commits: [SyncEvidenceCommit]
    public init(segmentID: UUID, sha256: String, byteCount: Int64, startedAtMS: Int64, origin: String,
                receiptAtMS: Int64? = nil, firstObservedAtMS: Int64? = nil, lastObservedAtMS: Int64? = nil,
                receiptWasPresent: Bool? = nil, foreground: Bool? = nil, artifacts: [SyncEvidenceArtifact] = [], commits: [SyncEvidenceCommit] = []) {
        self.segmentID = segmentID; self.sha256 = sha256; self.byteCount = byteCount
        self.startedAtMS = startedAtMS; self.origin = origin; self.receiptAtMS = receiptAtMS
        self.firstObservedAtMS = firstObservedAtMS; self.lastObservedAtMS = lastObservedAtMS
        self.receiptWasPresent = receiptWasPresent; self.foreground = foreground; self.artifacts = artifacts; self.commits = commits
    }
}

public struct SyncEvidenceContext: Codable, Equatable, Sendable {
    public let scope: String
    public let libraryID: UUID?
    public let scopeMode: String?
    public let authorizedAtMS: Int64?
    public let baselineIDs: [UUID]
    public let enabled: Bool?
    public let discoveryComplete: Bool
    public let counts: [String: Int]
    public let failureCode: String?
    public init(scope: String, libraryID: UUID? = nil, scopeMode: String? = nil, authorizedAtMS: Int64? = nil, baselineIDs: [UUID] = [], enabled: Bool? = nil,
                discoveryComplete: Bool, counts: [String: Int] = [:], failureCode: String? = nil) {
        self.scope = scope; self.libraryID = libraryID; self.scopeMode = scopeMode; self.enabled = enabled
        self.authorizedAtMS = authorizedAtMS; self.baselineIDs = baselineIDs.sorted { $0.uuidString < $1.uuidString }
        self.discoveryComplete = discoveryComplete; self.counts = counts; self.failureCode = failureCode
    }
}

/// Immutable bounded pages followed by one atomic index publication. A collector
/// must bind every page to this generation and re-read the index after collection.
/// Older generations are historical evidence, never a current-device assertion.
/// Call on a utility serial queue; failures must not fail recording/transport.
public final class SyncEvidenceArchive: @unchecked Sendable {
    public static let schemaVersion = 2
    public enum Failure: Error, Equatable { case invalid, capacity, unavailable }
    public struct PageReference: Codable, Equatable, Sendable {
        public let name: String
        public let sha256: String
        public let byteCount: Int
        public let sourceCount: Int
    }
    public struct Index: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let stream: String
        public let generationID: UUID
        public let build: String
        public let generatedAtMS: Int64
        public let sourceCount: Int
        public let context: SyncEvidenceContext
        public let pages: [PageReference]
    }
    public struct Snapshot: Sendable { public let index: Index; public var context: SyncEvidenceContext { index.context }; public let rows: [SyncEvidenceSource] }
    private struct Page: Codable { let schemaVersion: Int; let generationID: UUID; let page: Int; let rows: [SyncEvidenceSource] }
    private struct Status: Codable, Equatable { let schemaVersion: Int; let build: String; let observedAtMS: Int64; let available: Bool; let generationID: UUID?; let failureCount: Int; let failureCode: String? }
    private struct CapturePage: Codable { let name: String; let bytesBase64: Data }
    private struct Capture: Codable {
        let schemaVersion: Int; let build: String; let stream: String; let generationID: UUID; let generatedAtMS: Int64
        let available: Bool; let audioRead: Bool; let includesAudio: Bool; let index: Index; let status: Status; let pages: [CapturePage]
    }
    private struct UnavailableCapture: Codable {
        let schemaVersion: Int; let build: String; let stream: String; let generatedAtMS: Int64
        let available: Bool; let audioRead: Bool; let includesAudio: Bool; let failureCode: String
    }
    private struct CaptureStatus: Codable {
        let schemaVersion: Int; let build: String; let stream: String; let observedAtMS: Int64; let available: Bool
        let generationID: UUID?; let captureSHA256: String?; let captureByteCount: Int?; let failureCount: Int; let failureCode: String?
    }
    public static let maximumPageBytes = 65_536
    public static let maximumIndexBytes = 65_536
    /// A self-contained metadata projection, never an audio export or an authorization to act.
    public static let maximumCaptureBytes = 8 * 1_024 * 1_024
    public static let maximumSources = 10_000
    public static let maximumPages = 256
    private let directory: URL
    private let stream: String
    private let build: String
    private let lock = NSLock()
    private var failureCount = 0
    private var captureFailureCount = 0
    private var observationPublisher: VerifiedObservationPublisher?
    private var observationProcess: UUID?
    public init(root: URL, stream: String, build: String? = nil) {
        self.stream = stream
        directory = root.appendingPathComponent("SyncEvidence", isDirectory: true).appendingPathComponent(stream, isDirectory: true)
        let proposed = build ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        self.build = proposed.utf8.count <= 20 && !proposed.isEmpty && proposed.utf8.allSatisfy({ (48...57).contains($0) }) ? proposed : "unknown"
        if VerifiedObservationPublisher.requiresSnapshot(self.build) {
            observationProcess = VerifiedObservationPublisher.processRunID
            observationPublisher = VerifiedObservationPublisher(directory: directory, reportKind: stream,
                build: self.build, processRunID: VerifiedObservationPublisher.processRunID)
        }
    }
    public func publish(rows: [SyncEvidenceSource], context: SyncEvidenceContext) throws {
        lock.lock(); defer { lock.unlock() }
        // A published capture is historical metadata. Keep it readable while a
        // newer generation is being prepared; it is not a current-device claim.
        do { try publishLocked(rows: rows, context: context) }
        catch {
            failureCount = failureCount < Int.max ? failureCount + 1 : failureCount
            _ = try? status(available: false, generation: nil, code: error as? Failure == .capacity ? "capacity_exceeded" : "evidence_unavailable")
            invalidateCapture(code: "evidence_unavailable")
            invalidateObservationLocked()
            throw error
        }
    }
    /// An unavailable status must be inspected alongside the index: an old index
    /// remains readable for forensic recovery when a new observation fails.
    public func markUnavailable() {
        lock.lock(); defer { lock.unlock() }
        failureCount = failureCount < Int.max ? failureCount + 1 : failureCount
        _ = try? status(available: false, generation: nil, code: "evidence_unavailable")
        invalidateCapture(code: "evidence_unavailable")
        invalidateObservationLocked()
    }
    public func load() throws -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return try loadLocked()
    }
    /// Revalidate existing metadata without publishing a business generation,
    /// scanning a repository, changing event times, or performing cloud work.
    @discardableResult public func observe(processRunID: UUID, sourceDidChange: Bool = false, onThrottle: ((Int) -> Void)? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if observationProcess != processRunID {
            observationProcess = processRunID
            observationPublisher = VerifiedObservationPublisher(directory: directory, reportKind: stream,
                build: build, processRunID: processRunID)
        }
        return observationPublisher!.observe(sourceDidChange: sourceDidChange, onThrottle: onThrottle) { try verifiedObservationSourceLocked() }
    }
    private func invalidateObservationLocked() {
        guard VerifiedObservationPublisher.requiresSnapshot(build) else { return }
        if observationPublisher == nil {
            observationProcess = VerifiedObservationPublisher.processRunID
            observationPublisher = VerifiedObservationPublisher(directory: directory, reportKind: stream,
                build: build, processRunID: VerifiedObservationPublisher.processRunID)
        }
        observationPublisher?.invalidate()
    }
    private func verifiedObservationSourceLocked() throws -> VerifiedObservationSource {
        try requireSafeDirectories(create: false)
        var originals: [(String, Data, Int)] = []
        func captureBytes(_ name: String, _ maximum: Int) throws -> Data {
            let bytes = try read(directory.appendingPathComponent(name), maximum: maximum)
            originals.append((name, bytes, maximum)); return bytes
        }
        let decoder = JSONDecoder()
        let indexBytes = try captureBytes("index.json", Self.maximumIndexBytes)
        let index = try decoder.decode(Index.self, from: indexBytes)
        guard let snapshot = try loadLocked(), snapshot.index == index, index.build == build,
              index.generatedAtMS > 0 else { throw Failure.invalid }
        try validateObservationSemantics(snapshot)
        // loadLocked validates every row, page, aggregate count and index identity.
        let statusBytes = try captureBytes("status.json", Self.maximumIndexBytes)
        let publication = try decoder.decode(Status.self, from: statusBytes)
        guard publication.schemaVersion == index.schemaVersion, publication.build == index.build,
              publication.available, publication.generationID == index.generationID,
              publication.failureCode == nil, publication.failureCount >= 0,
              publication.observedAtMS >= index.generatedAtMS else { throw Failure.invalid }
        let envelopeBytes = try captureBytes("metadata-capture.json", Self.maximumCaptureBytes)
        let envelope = try decoder.decode(Capture.self, from: envelopeBytes)
        guard envelope.schemaVersion == index.schemaVersion, envelope.build == index.build,
              envelope.stream == stream, envelope.generationID == index.generationID,
              envelope.generatedAtMS == index.generatedAtMS, envelope.available,
              !envelope.audioRead, !envelope.includesAudio,
              envelope.index == index, envelope.status == publication,
              envelope.pages.count == index.pages.count else { throw Failure.invalid }
        for (offset, reference) in index.pages.enumerated() {
            let page = try captureBytes(reference.name, Self.maximumPageBytes)
            guard envelope.pages[offset].name == reference.name,
                  envelope.pages[offset].bytesBase64 == page,
                  page.count == reference.byteCount, Self.digest(page) == reference.sha256
            else { throw Failure.invalid }
        }
        let captureStatusBytes = try captureBytes("capture-status.json", Self.maximumIndexBytes)
        let captured = try decoder.decode(CaptureStatus.self, from: captureStatusBytes)
        guard captured.schemaVersion == index.schemaVersion, captured.build == index.build,
              captured.stream == stream, captured.available, captured.generationID == index.generationID,
              captured.captureSHA256 == Self.digest(envelopeBytes), captured.captureByteCount == envelopeBytes.count,
              captured.failureCode == nil, captured.failureCount >= 0,
              captured.observedAtMS >= index.generatedAtMS else { throw Failure.invalid }
        for (name, bytes, maximum) in originals {
            guard try read(directory.appendingPathComponent(name), maximum: maximum) == bytes else { throw Failure.invalid }
        }
        // The capture contains exact page bytes and the complete index/status.
        // Collectors retain these two original leaves rather than hashing their
        // locally canonicalized index/status projections.
        return VerifiedObservationSource(sourceGeneratedAtMS: index.generatedAtMS,
            identity: ["generationID": index.generationID.uuidString, "stream": stream,
                       "sourceCount": String(index.sourceCount)],
            files: [.init(name: "metadata-capture.json", bytes: envelopeBytes),
                    .init(name: "capture-status.json", bytes: captureStatusBytes)],
            snapshotFiles: ["metadata-capture.json": envelopeBytes, "capture-status.json": captureStatusBytes])
    }
    private func validateObservationSemantics(_ snapshot: Snapshot) throws {
        let index = snapshot.index, rows = snapshot.rows, context = snapshot.context
        guard index.pages.allSatisfy({ $0.sourceCount <= 64 }),
              rows.map(\.segmentID.uuidString) == rows.map(\.segmentID.uuidString).sorted(),
              context.baselineIDs.map(\.uuidString) == context.baselineIDs.map(\.uuidString).sorted(),
              context.scopeMode == nil || ["existingAndFuture", "futureOnly"].contains(context.scopeMode!)
        else { throw Failure.invalid }
        for row in rows {
            guard (row.firstObservedAtMS == nil) == (row.lastObservedAtMS == nil),
                  row.firstObservedAtMS.map({ $0 <= row.lastObservedAtMS! && row.lastObservedAtMS! <= index.generatedAtMS }) ?? true,
                  row.receiptAtMS.map({ $0 <= index.generatedAtMS }) ?? true,
                  row.artifacts.allSatisfy({ artifact in
                      [artifact.recordedAtMS, artifact.observedAtMS, artifact.localExportedAtMS,
                       artifact.providerCheckedAtMS].compactMap { $0 }.allSatisfy { $0 <= index.generatedAtMS }
                          && (artifact.kind != "audio" || (artifact.sha256 == row.sha256 && artifact.byteCount == row.byteCount))
                  }), row.commits.allSatisfy({ $0.observedAtMS.map { $0 <= index.generatedAtMS } ?? true })
            else { throw Failure.invalid }
        }
        let counts = context.counts
        if stream == "phone_receipts" {
            guard context.scope == "phone_library_metadata",
                  counts["manifest_count"] == rows.count,
                  counts["receipt_count"] == rows.filter({ $0.receiptAtMS != nil }).count,
                  counts["observed_incoming_source_count"] == rows.filter({ $0.firstObservedAtMS != nil }).count,
                  [0, 1].contains(counts["history_unavailable"] ?? -1)
            else { throw Failure.invalid }
        } else {
            let artifacts = rows.flatMap(\.artifacts)
            guard context.scope == "phone_authorized_discovered", context.libraryID != nil,
                  let mode = context.scopeMode, let authorization = context.authorizedAtMS,
                  counts["authorized_source_count"] == rows.count, counts["artifact_count"] == artifacts.count
            else { throw Failure.invalid }
            let baseline = Set(context.baselineIDs)
            guard rows.allSatisfy({ $0.origin == "authorized_ledger" &&
                (mode == "existingAndFuture" || (!baseline.contains($0.segmentID) && $0.startedAtMS >= authorization)) })
            else { throw Failure.invalid }
            if stream == "google_drive" {
                let verified = artifacts.filter { $0.state == "remote_verified" }.count
                guard counts["remote_verified_artifact_count"] == verified,
                      counts["pending_artifact_count"] == artifacts.count - verified else { throw Failure.invalid }
            } else {
                guard counts["provider_uploaded_artifact_count"] == artifacts.filter({ $0.state == "provider_uploaded" }).count,
                      counts["commit_file_count"] == rows.reduce(0, { $0 + $1.commits.count }) else { throw Failure.invalid }
            }
        }
    }
    private func loadLocked() throws -> Snapshot? {
        try requireSafeDirectories(create: false)
        let file = directory.appendingPathComponent("index.json")
        var info = stat()
        if Darwin.lstat(file.path, &info) != 0 {
            if errno == ENOENT { return nil }; throw Failure.unavailable
        }
        let data = try read(file, maximum: Self.maximumIndexBytes)
        let index = try JSONDecoder().decode(Index.self, from: data)
        guard (1...Self.schemaVersion).contains(index.schemaVersion), index.stream == stream, index.sourceCount <= Self.maximumSources,
              index.sourceCount >= 0, index.pages.count <= Self.maximumPages,
              Set(index.pages.map(\.name)).count == index.pages.count else { throw Failure.invalid }
        var rows: [SyncEvidenceSource] = []
        for (offset, ref) in index.pages.enumerated() {
            guard ref.name == name(index.generationID, page: offset), ref.byteCount > 0,
                  ref.byteCount <= Self.maximumPageBytes, ref.sourceCount > 0 else { throw Failure.invalid }
            let bytes = try read(directory.appendingPathComponent(ref.name), maximum: Self.maximumPageBytes)
            guard bytes.count == ref.byteCount, Self.digest(bytes) == ref.sha256 else { throw Failure.invalid }
            let page = try JSONDecoder().decode(Page.self, from: bytes)
            guard page.schemaVersion == index.schemaVersion, page.generationID == index.generationID, page.page == offset,
                  page.rows.count == ref.sourceCount else { throw Failure.invalid }
            rows += page.rows
        }
        guard rows.count == index.sourceCount, try read(file, maximum: Self.maximumIndexBytes) == data else { throw Failure.invalid }
        try validate(rows: rows, context: index.context)
        return Snapshot(index: index, rows: rows)
    }
    private func publishLocked(rows: [SyncEvidenceSource], context: SyncEvidenceContext) throws {
        try validate(rows: rows, context: context)
        try prepare()
        if let previous = try loadLocked(), previous.context.libraryID == context.libraryID {
            let prior = Dictionary(uniqueKeysWithValues: previous.rows.map { ($0.segmentID, $0) })
            for row in rows {
                if let old = prior[row.segmentID] {
                    guard old.sha256 == row.sha256, old.byteCount == row.byteCount,
                          old.startedAtMS == row.startedAtMS else { throw Failure.invalid }
                }
            }
        }
        // Never reuse generation filenames, even after an interrupted write.
        let old = (try? read(directory.appendingPathComponent("index.json"), maximum: Self.maximumIndexBytes))
            .flatMap { try? JSONDecoder().decode(Index.self, from: $0) }
        let id = UUID(), sorted = rows.sorted { $0.segmentID.uuidString < $1.segmentID.uuidString }
        var refs: [PageReference] = [], pending: [SyncEvidenceSource] = []
        var capturePages: [CapturePage] = [], captureBase64Bytes = 0, captureCapacityExceeded = false
        func flush() throws {
            guard !pending.isEmpty else { return }
            guard refs.count < Self.maximumPages else { throw Failure.capacity }
            let bytes = try encode(Page(schemaVersion: Self.schemaVersion, generationID: id, page: refs.count, rows: pending))
            guard bytes.count <= Self.maximumPageBytes else { throw Failure.capacity }
            let leaf = name(id, page: refs.count)
            try write(bytes, to: directory.appendingPathComponent(leaf))
            refs.append(.init(name: leaf, sha256: Self.digest(bytes), byteCount: bytes.count, sourceCount: pending.count))
            if !captureCapacityExceeded {
                // Data's JSON encoding is base64. Stop retaining sidecar bytes
                // before constructing an oversized base64 envelope.
                captureBase64Bytes += ((bytes.count + 2) / 3) * 4
                if captureBase64Bytes > Self.maximumCaptureBytes {
                    captureCapacityExceeded = true; capturePages.removeAll()
                } else { capturePages.append(.init(name: leaf, bytesBase64: bytes)) }
            }
            pending.removeAll(keepingCapacity: true)
        }
        for row in sorted {
            let candidate = try encode(Page(schemaVersion: Self.schemaVersion, generationID: id, page: refs.count, rows: pending + [row]))
            if pending.count >= 64 || candidate.count > Self.maximumPageBytes { try flush() }
            pending.append(row)
        }
        try flush()
        let index = Index(schemaVersion: Self.schemaVersion, stream: stream, generationID: id, build: build,
            generatedAtMS: Int64(Date().timeIntervalSince1970 * 1_000), sourceCount: rows.count, context: context, pages: refs)
        let bytes = try encode(index)
        guard bytes.count <= Self.maximumIndexBytes else { throw Failure.capacity }
        try write(bytes, to: directory.appendingPathComponent("index.json"))
        let publishedStatus = try status(available: true, generation: id, code: nil)
        // Keep two generations. A concurrent reader always verifies its entire
        // generation and the unchanged index, or retries a later passive sample.
        let retained = Set(refs.map(\.name) + (old?.pages.map(\.name) ?? []))
        if let leaves = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for leaf in leaves where !retained.contains(leaf) && isPageName(leaf) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(leaf))
            }
        }
        publishCapture(index: index, status: publishedStatus, pages: capturePages,
                       capacityExceeded: captureCapacityExceeded)
    }
    private func validate(rows: [SyncEvidenceSource], context: SyncEvidenceContext) throws {
        guard ["phone_receipts", "google_drive", "icloud_drive"].contains(stream) else { throw Failure.invalid }
        guard rows.count <= Self.maximumSources else { throw Failure.capacity }
        guard Set(rows.map(\.segmentID)).count == rows.count, Self.safeWord(context.scope),
              context.scopeMode.map(Self.safeWord) ?? true, context.failureCode.map(Self.safeWord) ?? true,
              context.baselineIDs.count <= Self.maximumSources, Set(context.baselineIDs).count == context.baselineIDs.count,
              context.authorizedAtMS.map({ $0 >= 0 }) ?? true, context.counts.count <= 64, context.counts.allSatisfy({ Self.safeWord($0.key) && $0.value >= 0 }) else { throw Failure.invalid }
        for row in rows {
            guard Self.digestValid(row.sha256), row.byteCount > 0, row.startedAtMS >= 0, ["stored_receipt_metadata", "incoming_persisted", "authorized_ledger", "no_receipt_metadata"].contains(row.origin),
                  [row.receiptAtMS, row.firstObservedAtMS, row.lastObservedAtMS].compactMap({ $0 }).allSatisfy({ $0 >= 0 }),
                  row.artifacts.count <= 258, Set(row.artifacts.map { $0.kind + ":" + $0.sha256 }).count == row.artifacts.count else { throw Failure.invalid }
            guard row.commits.count <= 129, Set(row.commits.map(\.exportDigest)).count == row.commits.count,
                  row.commits.allSatisfy({ Self.digestValid($0.exportDigest) && ($0.observedAtMS.map({ $0 >= 0 }) ?? true)
                      && (!$0.providerUploaded || $0.observedAtMS != nil) }) else { throw Failure.invalid }
            for artifact in row.artifacts {
                guard ["audio", "manifest", "transcriptJSON", "transcriptText"].contains(artifact.kind), Self.digestValid(artifact.sha256), artifact.byteCount > 0,
                      ["pending", "local_exported", "remote_verified", "provider_uploaded", "provider_pending", "provider_unknown", "phone_persisted"].contains(artifact.state),
                      ["restored_ledger", "observed_callback", "provider_metadata", "authorized_ledger", "stored_receipt_metadata", "incoming_persisted"].contains(artifact.origin),
                      [artifact.recordedAtMS, artifact.observedAtMS].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { throw Failure.invalid }
                let hasProviderDiagnostics = artifact.localExportedAtMS != nil || artifact.providerCheckedAtMS != nil
                    || artifact.providerResult != nil || artifact.providerGate != nil
                if hasProviderDiagnostics {
                    guard stream == "icloud_drive", artifact.providerGate != nil,
                          (artifact.providerCheckedAtMS == nil) == (artifact.providerResult == nil),
                          [artifact.localExportedAtMS, artifact.providerCheckedAtMS].compactMap({ $0 })
                            .allSatisfy({ (0...253_402_300_799_999).contains($0) }),
                          artifact.state != "provider_uploaded" || (artifact.providerGate == .current
                            && artifact.providerResult == .uploaded && artifact.providerCheckedAtMS == artifact.observedAtMS)
                    else { throw Failure.invalid }
                }
                if let correlation = artifact.uploadCorrelation {
                    guard stream == "google_drive", let kind = GoogleDriveArtifact.Kind(rawValue: artifact.kind),
                          correlation == .init(segmentID: row.segmentID, kind: kind, manifestSHA256: row.sha256)
                    else { throw Failure.invalid }
                }
            }
        }
    }
    private func prepare() throws { try requireSafeDirectories(create: true) }
    private func requireSafeDirectories(create: Bool) throws {
        guard ["phone_receipts", "google_drive", "icloud_drive"].contains(stream) else { throw Failure.invalid }
        for folder in [directory.deletingLastPathComponent().deletingLastPathComponent(), directory.deletingLastPathComponent(), directory] {
            var info = stat()
            if Darwin.lstat(folder.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalid }
            } else {
                guard errno == ENOENT else { throw Failure.unavailable }
                if !create { continue }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            if create { try protect(folder, mode: 0o700) }
        }
    }
    @discardableResult private func status(available: Bool, generation: UUID?, code: String?) throws -> Status {
        try prepare()
        let value = Status(schemaVersion: Self.schemaVersion, build: build, observedAtMS: Int64(Date().timeIntervalSince1970 * 1_000),
            available: available, generationID: generation, failureCount: failureCount, failureCode: code)
        try write(try encode(value), to: directory.appendingPathComponent("status.json"))
        return value
    }
    private func invalidateCapture(code: String) {
        captureFailureCount = captureFailureCount < Int.max ? captureFailureCount + 1 : captureFailureCount
        // Try both invalidations independently. If the filesystem refuses all
        // writes, no metadata protocol can promise that old grants were revoked.
        // A collector must retain that limitation rather than claim current state.
        let unavailable = UnavailableCapture(schemaVersion: Self.schemaVersion, build: build, stream: stream,
            generatedAtMS: Int64(Date().timeIntervalSince1970 * 1_000), available: false,
            audioRead: false, includesAudio: false, failureCode: code)
        do {
            try prepare()
            try write(try encodeCapture(unavailable), to: directory.appendingPathComponent("metadata-capture.json"))
        } catch { /* The independent status write must still be attempted. */ }
        try? captureStatus(available: false, generation: nil, digest: nil, byteCount: nil, code: code)
    }
    private func publishCapture(index: Index, status: Status, pages: [CapturePage], capacityExceeded: Bool) {
        do {
            guard !capacityExceeded, pages.count == index.pages.count else { throw Failure.capacity }
            let empty = Capture(schemaVersion: Self.schemaVersion, build: build, stream: stream,
                generationID: index.generationID, generatedAtMS: index.generatedAtMS,
                available: true, audioRead: false, includesAudio: false, index: index, status: status, pages: [])
            // The envelope, index/status, page names, separators and base64 all
            // count toward the cap before constructing the full JSON buffer.
            // Unescaped base64 is ASCII and has an exact 4*ceil(n/3) length.
            var expectedBytes = try encodeCapture(empty).count + max(0, pages.count - 1)
            for page in pages {
                expectedBytes += try encodeCapture(CapturePage(name: page.name, bytesBase64: Data())).count
                expectedBytes += ((page.bytesBase64.count + 2) / 3) * 4
            }
            guard expectedBytes <= Self.maximumCaptureBytes else { throw Failure.capacity }
            let bytes = try encodeCapture(Capture(schemaVersion: empty.schemaVersion, build: empty.build,
                stream: empty.stream, generationID: empty.generationID, generatedAtMS: empty.generatedAtMS,
                available: empty.available, audioRead: empty.audioRead, includesAudio: empty.includesAudio,
                index: index, status: status, pages: pages))
            guard bytes.count == expectedBytes else { throw Failure.invalid }
            guard bytes.count <= Self.maximumCaptureBytes else { throw Failure.capacity }
            try write(bytes, to: directory.appendingPathComponent("metadata-capture.json"))
            try captureStatus(available: true, generation: index.generationID, digest: Self.digest(bytes), byteCount: bytes.count, code: nil)
        } catch {
            invalidateCapture(code: error as? Failure == .capacity ? "capacity_exceeded" : "capture_unavailable")
        }
    }
    private func encodeCapture<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func captureStatus(available: Bool, generation: UUID?, digest: String?, byteCount: Int?, code: String?) throws {
        try prepare()
        let value = CaptureStatus(schemaVersion: Self.schemaVersion, build: build, stream: stream,
            observedAtMS: Int64(Date().timeIntervalSince1970 * 1_000), available: available,
            generationID: generation, captureSHA256: digest, captureByteCount: byteCount,
            failureCount: captureFailureCount, failureCode: code)
        try write(try encode(value), to: directory.appendingPathComponent("capture-status.json"))
    }
    private func name(_ id: UUID, page: Int) -> String { "g-" + id.uuidString.lowercased() + String(format: "-p-%04d.json", page) }
    private func isPageName(_ leaf: String) -> Bool {
        guard leaf.count == 50, leaf.hasPrefix("g-"), leaf.hasSuffix(".json") else { return false }
        let parts = leaf.dropFirst(2).split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 7 && UUID(uuidString: String(leaf.dropFirst(2).prefix(36))) != nil
            && leaf.dropFirst(38).hasPrefix("-p-") && leaf.dropFirst(41).prefix(4).allSatisfy(\.isNumber)
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) }
    private static func safeWord(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 } }
    private static func digestValid(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func read(_ file: URL, maximum: Int) throws -> Data {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unavailable }; defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= maximum else { throw Failure.invalid }
        guard let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximum + 1), bytes.count <= maximum else { throw Failure.invalid }
        return bytes
    }
    private func protect(_ file: URL, mode: Int) throws {
        var values: [FileAttributeKey: Any] = [.posixPermissions: mode]
        #if os(iOS) || os(watchOS)
        values[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.setAttributes(values, ofItemAtPath: file.path)
    }
    private func write(_ bytes: Data, to file: URL) throws {
        var info = stat()
        if Darwin.lstat(file.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Failure.invalid }
        } else if errno != ENOENT { throw Failure.unavailable }
        let temporary = directory.appendingPathComponent(".evidence-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
        try protect(temporary, mode: 0o600)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: bytes); try handle.synchronize()
        guard Darwin.rename(temporary.path, file.path) == 0 else { throw Failure.unavailable }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw Failure.unavailable }; defer { Darwin.close(parent) }
        guard Darwin.fsync(parent) == 0 else { throw Failure.unavailable }
    }
}
