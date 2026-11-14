import Foundation

/// Written durably before the first sample. A CAF filename alone cannot establish
/// its recording session or capture time after a crash.
public struct OpenAudioSegment: Codable, Equatable, Sendable, Identifiable {
    public enum PCMFormat: String, Codable, Sendable {
        case float32, float64, int16, int32
    }

    public let schemaVersion: Int
    public let id: UUID
    public let sessionID: UUID
    public let sequence: Int
    public let startedAt: Date
    public let sampleRate: Double
    public let channelCount: UInt32
    public let pcmFormat: PCMFormat
    /// Input layout; the CAF's on-disk channel layout is validated independently.
    public let interleaved: Bool
    public let timeZoneIdentifier: String?
    public let recordingGroup: RecordingGroup?

    public init(id: UUID, sessionID: UUID, sequence: Int, startedAt: Date,
                sampleRate: Double, channelCount: UInt32, pcmFormat: PCMFormat,
                interleaved: Bool, timeZoneIdentifier: String?, schemaVersion: Int = 1,
                recordingGroup: RecordingGroup? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.startedAt = Date(timeIntervalSince1970: (startedAt.timeIntervalSince1970 * 1_000).rounded() / 1_000)
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.pcmFormat = pcmFormat
        self.interleaved = interleaved
        self.timeZoneIdentifier = timeZoneIdentifier
        self.recordingGroup = recordingGroup
    }
}

public struct OpenAudioSegmentInventory: Sendable {
    public let segments: [OpenAudioSegment]
    public let issues: [RecordingInventoryIssue]
    /// Historical CAF files without enough identity/time metadata are preserved.
    public let untrackedAudioCount: Int
}

extension RecordingRepository {
    private var openSegmentsDirectory: URL { root.appendingPathComponent("open-segments", isDirectory: true) }
    private var recoveryStagingDirectory: URL { root.appendingPathComponent("recovery-staging", isDirectory: true) }
    private var recoveredOriginalsDirectory: URL { root.appendingPathComponent("recovered-originals", isDirectory: true) }

    public func openSegmentURL(for id: UUID) -> URL {
        openSegmentsDirectory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    public func recoveryCandidateURL(for id: UUID) -> URL {
        recoveryStagingDirectory.appendingPathComponent(id.uuidString.lowercased() + ".caf")
    }

    public func preservedOriginalURL(for id: UUID) -> URL {
        recoveredOriginalsDirectory.appendingPathComponent(id.uuidString.lowercased() + ".caf")
    }

    /// Failure here is a capture-storage failure: do not start a new file whose
    /// identity cannot be recovered. It is not a network/sync status failure.
    public func beginAudioSegment(_ segment: OpenAudioSegment) throws {
        try synchronized {
            try validateOpenSegment(segment)
            try createTailDirectory(openSegmentsDirectory)
            let url = openSegmentURL(for: segment.id)
            if FileManager.default.fileExists(atPath: url.path) {
                guard try readOpenSegment(at: url) == segment else { throw RepositoryError.conflictingSegment }
            }
            guard !FileManager.default.fileExists(atPath: stagingURL(for: segment.id).path),
                  !FileManager.default.fileExists(atPath: manifestURL(for: segment.id).path),
                  !FileManager.default.fileExists(atPath: pendingManifestURL(for: segment.id).path),
                  !FileManager.default.fileExists(atPath: recoveryCandidateURL(for: segment.id).path) else {
                throw RepositoryError.conflictingSegment
            }
            try persist(segment, at: url)
            notePriorityOpenSegment(segment)
        }
    }

    /// Per-file failures are observations, not permission to delete or guess at
    /// the identity of an old recording. The directory itself must be readable.
    public func openAudioSegments() throws -> OpenAudioSegmentInventory {
        let fm = FileManager.default
        var segments: [OpenAudioSegment] = []
        var issues: [RecordingInventoryIssue] = []
        var journalIDs = Set<UUID>()
        if fm.fileExists(atPath: openSegmentsDirectory.path) {
            for url in try fm.contentsOfDirectory(at: openSegmentsDirectory, includingPropertiesForKeys: nil)
                where url.pathExtension == "json" {
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) { journalIDs.insert(id) }
                do {
                    let segment = try readOpenSegment(at: url)
                    try validateOpenSegment(segment)
                    guard url.lastPathComponent == segment.id.uuidString.lowercased() + ".json" else {
                        throw RepositoryError.invalidManifest("尾段记录的文件名与标识不一致")
                    }
                    segments.append(segment)
                } catch {
                    issues.append(RecordingInventoryIssue(fileName: "open-segments/" + url.lastPathComponent,
                                                          reason: error.localizedDescription))
                }
            }
        }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let untracked = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).filter { url in
            guard url.pathExtension == "caf", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !journalIDs.contains(id) else { return false }
            return !fm.fileExists(atPath: manifestURL(for: id).path)
                && !fm.fileExists(atPath: pendingManifestURL(for: id).path)
        }.count
        return OpenAudioSegmentInventory(segments: segments.sorted {
            if $0.startedAt == $1.startedAt { return $0.sequence < $1.sequence }
            return $0.startedAt < $1.startedAt
        }, issues: issues, untrackedAudioCount: untracked)
    }

    /// Call before rebuilding a candidate. An existing pending commit must first
    /// finish using its exact stored hash, never be replaced by a new encoding.
    public func committedAudioSegment(for segment: OpenAudioSegment) throws -> SegmentManifest? {
        try synchronized {
            try validateOpenSegment(segment)
            if FileManager.default.fileExists(atPath: pendingManifestURL(for: segment.id).path) {
                throw RepositoryError.persistenceFailure("此尾段的提交尚未完成，原文件已保留")
            }
            let url = manifestURL(for: segment.id)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let manifest = try TransportCodec.decode(SegmentManifest.self, from: Data(contentsOf: url))
            try validate(manifest)
            try validateIdentity(manifest, for: segment)
            // A late sidecar after a successful receipt must not resurrect audio
            // already pruned from Watch storage.
            if try hasDurableAcknowledgement(for: manifest) { return manifest }
            let fingerprint = try Self.fingerprint(of: audioURL(for: manifest))
            guard fingerprint.sha256 == manifest.sha256, fingerprint.byteCount == manifest.byteCount else {
                throw RepositoryError.checksumMismatch
            }
            try synchronizeFile(audioURL(for: manifest))
            try synchronizeDirectory(audioURL(for: manifest).deletingLastPathComponent())
            try persist(manifest, at: url)
            return manifest
        }
    }

    public func prepareAudioRecoveryCandidate(for segment: OpenAudioSegment) throws -> URL {
        try synchronized {
            try validateOpenSegment(segment)
            guard try readOpenSegment(at: openSegmentURL(for: segment.id)) == segment,
                  !FileManager.default.fileExists(atPath: pendingManifestURL(for: segment.id).path),
                  !FileManager.default.fileExists(atPath: manifestURL(for: segment.id).path) else {
                throw RepositoryError.conflictingSegment
            }
            try createTailDirectory(recoveryStagingDirectory)
            let url = recoveryCandidateURL(for: segment.id)
            // Only an uncommitted candidate is disposable. The original CAF and
            // its durable identity record are unchanged if rebuilding fails.
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                try synchronizeDirectory(recoveryStagingDirectory)
            }
            return url
        }
    }

    public func commitRecoveredAudioSegment(_ segment: OpenAudioSegment, candidateURL: URL,
                                            frameCount: Int64) throws -> SegmentManifest {
        try synchronized {
            try validateOpenSegment(segment)
            guard candidateURL.standardizedFileURL == recoveryCandidateURL(for: segment.id).standardizedFileURL,
                  try readOpenSegment(at: openSegmentURL(for: segment.id)) == segment,
                  frameCount > 0, frameCount <= Int64((segment.sampleRate * 60).rounded()) else {
                throw RepositoryError.invalidManifest("恢复尾段的来源、身份或帧数无效")
            }
            // The caller has closed and decoded the complete candidate. Persist
            // the exact bytes before the standard write-ahead transaction begins.
            try synchronizeFile(candidateURL)
            let fingerprint = try Self.fingerprint(of: candidateURL)
            let manifest = SegmentManifest(id: segment.id, sessionID: segment.sessionID,
                sequence: segment.sequence, startedAt: segment.startedAt,
                endedAt: segment.startedAt.addingTimeInterval(Double(frameCount) / segment.sampleRate),
                sampleRate: segment.sampleRate, frameCount: frameCount,
                fileName: segment.id.uuidString.lowercased() + ".caf",
                byteCount: fingerprint.byteCount, sha256: fingerprint.sha256,
                timeZoneIdentifier: segment.timeZoneIdentifier, recordingGroup: segment.recordingGroup)
            try validate(manifest)
            try commitAudio(at: candidateURL, manifest: manifest)
            noteTransferSourceProvenance(manifest, category: .recovery)
            return manifest
        }
    }

    /// Complete only after verifying durable committed audio (or its durable
    /// phone ACK). Recovery originals are archived, never silently overwritten.
    public func completeAudioSegment(_ segment: OpenAudioSegment,
                                     justCommitted manifestFromCommit: SegmentManifest? = nil) throws {
        try synchronized {
            let manifest: SegmentManifest
            if let manifestFromCommit {
                // sealSegment/commitRecoveredAudioSegment already synchronized and
                // hashed these exact bytes. Do not hash a whole minute again on the
                // live audio queue just to remove its obsolete identity sidecar.
                try validate(manifestFromCommit)
                try validateIdentity(manifestFromCommit, for: segment)
                let stored = try TransportCodec.decode(SegmentManifest.self,
                    from: Data(contentsOf: manifestURL(for: segment.id)))
                guard stored == manifestFromCommit,
                      !FileManager.default.fileExists(atPath: pendingManifestURL(for: segment.id).path) else {
                    throw RepositoryError.conflictingSegment
                }
                if !FileManager.default.fileExists(atPath: audioURL(for: stored).path),
                   try !hasDurableAcknowledgement(for: stored) { throw RepositoryError.missingAudio }
                manifest = stored
            } else {
                guard let committed = try committedAudioSegment(for: segment) else { throw RepositoryError.missingAudio }
                manifest = committed
            }
            do { try notePrioritySegmentCommitted(manifest) }
            catch { blockPriorityCapture(error); return }
            let journalURL = openSegmentURL(for: segment.id)
            if FileManager.default.fileExists(atPath: journalURL.path) {
                guard try readOpenSegment(at: journalURL) == segment else { throw RepositoryError.conflictingSegment }
            }
            let source = stagingURL(for: segment.id)
            if FileManager.default.fileExists(atPath: source.path) {
                try createTailDirectory(recoveredOriginalsDirectory)
                let preserved = preservedOriginalURL(for: segment.id)
                if FileManager.default.fileExists(atPath: preserved.path) {
                    let originalHash = try Self.fingerprint(of: source)
                    let preservedHash = try Self.fingerprint(of: preserved)
                    guard originalHash.sha256 == preservedHash.sha256,
                          originalHash.byteCount == preservedHash.byteCount else {
                        throw RepositoryError.conflictingSegment
                    }
                    try synchronizeFile(preserved)
                    try synchronizeDirectory(recoveredOriginalsDirectory)
                    try FileManager.default.removeItem(at: source)
                } else {
                    try synchronizeFile(source)
                    try FileManager.default.moveItem(at: source, to: preserved)
                    try synchronizeFile(preserved)
                    try synchronizeDirectory(recoveredOriginalsDirectory)
                }
                try synchronizeDirectory(source.deletingLastPathComponent())
            }
            let candidate = recoveryCandidateURL(for: segment.id)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let fingerprint = try Self.fingerprint(of: candidate)
                guard fingerprint.sha256 == manifest.sha256, fingerprint.byteCount == manifest.byteCount else {
                    throw RepositoryError.conflictingSegment
                }
                try FileManager.default.removeItem(at: candidate)
                try synchronizeDirectory(recoveryStagingDirectory)
            }
            if FileManager.default.fileExists(atPath: journalURL.path) {
                try FileManager.default.removeItem(at: journalURL)
                try synchronizeDirectory(openSegmentsDirectory)
            }
        }
    }

    private func createTailDirectory(_ url: URL) throws {
        let existed = FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try applyFileProtection(url)
        if !existed { try synchronizeDirectory(root) }
    }

    private func manifestURL(for id: UUID) -> URL {
        root.appendingPathComponent("manifests", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func pendingManifestURL(for id: UUID) -> URL {
        root.appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased() + ".pending.json")
    }

    private func readOpenSegment(at url: URL) throws -> OpenAudioSegment {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= 65_536 else {
            throw RepositoryError.invalidManifest("尾段恢复记录不是有效的小型元数据文件")
        }
        return try TransportCodec.decode(OpenAudioSegment.self, from: Data(contentsOf: url))
    }

    private func validateOpenSegment(_ segment: OpenAudioSegment) throws {
        let startMilliseconds = (segment.startedAt.timeIntervalSince1970 * 1_000).rounded()
        let endMilliseconds = ((segment.startedAt.timeIntervalSince1970 + 60) * 1_000).rounded()
        guard segment.schemaVersion == 1, segment.sequence >= 0, segment.sequence < Int.max,
              segment.startedAt.timeIntervalSince1970.isFinite,
              startMilliseconds.isFinite, endMilliseconds.isFinite,
              startMilliseconds >= Double(Int64.min), endMilliseconds < Double(Int64.max),
              segment.sampleRate.isFinite, segment.sampleRate > 0, segment.sampleRate <= 384_000,
              segment.channelCount > 0, segment.channelCount <= 32,
              segment.timeZoneIdentifier.map({ TimeZone(identifier: $0) != nil }) ?? true else {
            throw RepositoryError.invalidManifest("尾段恢复记录的时间、音频格式或版本无效")
        }
        try segment.recordingGroup?.validate(segmentSequence: segment.sequence)
    }

    private func validateIdentity(_ manifest: SegmentManifest, for segment: OpenAudioSegment) throws {
        guard manifest.id == segment.id, manifest.sessionID == segment.sessionID,
              manifest.sequence == segment.sequence, manifest.startedAt == segment.startedAt,
              manifest.sampleRate == segment.sampleRate, manifest.timeZoneIdentifier == segment.timeZoneIdentifier,
              manifest.recordingGroup == segment.recordingGroup,
              manifest.frameCount <= Int64((segment.sampleRate * 60).rounded()) else {
            throw RepositoryError.conflictingSegment
        }
    }
}
