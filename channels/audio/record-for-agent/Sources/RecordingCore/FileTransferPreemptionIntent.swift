import Foundation
import CryptoKit

/// Exact native-attempt cancellation intent. This is never an audio ACK.
public struct FileTransferPreemptionIntent: Codable, Equatable, Sendable {
    public let manifest: SegmentManifest
    public let attemptID: String
    public let epochID: UUID
    public let freshHeadID: UUID
    public let createdAt: Date

    public init(manifest: SegmentManifest, attemptID: String, epochID: UUID, freshHeadID: UUID,
                createdAt: Date = Date()) {
        self.manifest = manifest; self.attemptID = attemptID; self.epochID = epochID
        self.freshHeadID = freshHeadID; self.createdAt = createdAt
    }
}

extension RecordingRepository {
    private var preemptionDirectory: URL { root.appendingPathComponent("transfer-preemption", isDirectory: true) }
    private func preemptionURL(_ attemptID: String) throws -> URL {
        guard !attemptID.isEmpty, attemptID.utf8.count <= 512 else {
            throw RepositoryError.persistenceFailure("原生发送任务标识无效")
        }
        let digest = SHA256.hash(data: Data(attemptID.utf8)).map { String(format: "%02x", $0) }.joined()
        return preemptionDirectory.appendingPathComponent(digest + ".json")
    }

    /// Persistence must succeed before the caller requests native cancellation.
    public func persistPreemptionIntent(_ intent: FileTransferPreemptionIntent) throws {
        try synchronized {
            guard try manifest(id: intent.manifest.id) == intent.manifest else { throw RepositoryError.conflictingSegment }
            guard intent.createdAt.timeIntervalSince1970.isFinite,
                  intent.manifest.id != intent.freshHeadID else { throw RepositoryError.conflictingSegment }
            let url = try preemptionURL(intent.attemptID)
            if let existing = try preemptionIntent(attemptID: intent.attemptID) {
                guard existing.manifest == intent.manifest else { throw RepositoryError.conflictingSegment }
                return
            }
            try FileManager.default.createDirectory(at: preemptionDirectory, withIntermediateDirectories: true)
            try applyFileProtection(preemptionDirectory)
            try freshFault?(.beforePreemptionIntentCommit)
            try TransportCodec.encode(intent).write(to: url, options: .atomic)
            try applyFileProtection(url)
            try freshFault?(.afterPreemptionIntentWriteBeforeSync)
            try synchronizeFile(url)
            try synchronizeDirectory(preemptionDirectory)
            try synchronizeDirectory(root)
        }
    }

    /// O(1) lookup; never enumerate cancellation history during a callback.
    public func preemptionIntent(attemptID: String) throws -> FileTransferPreemptionIntent? {
        try synchronized {
            let url = try preemptionURL(attemptID)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let intent = try TransportCodec.decode(FileTransferPreemptionIntent.self, from: Data(contentsOf: url))
            guard intent.attemptID == attemptID else { throw RepositoryError.conflictingSegment }
            try Self.validateManifest(intent.manifest)
            try synchronizeFile(url)
            try synchronizeDirectory(preemptionDirectory)
            try synchronizeDirectory(root)
            return intent
        }
    }
}
