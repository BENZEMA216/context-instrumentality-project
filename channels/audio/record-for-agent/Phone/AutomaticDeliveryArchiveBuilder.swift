import CryptoKit
import Darwin
import Foundation
import RecordingCore

/// The envelope matches AgentExport v3, but its one manifest is the immutable
/// authorized job snapshot. A repository metadata rewrite cannot silently replace it.
enum AutomaticDeliveryArchiveBuilder {
    private struct Envelope: Encodable {
        struct Entry: Encodable {
            let manifest: SegmentManifest
            let audioPath: String
            let transcript: SegmentTranscript?
            let metadata: AgentRecordingMetadata
        }
        let schemaVersion: Int
        let exportID: UUID
        let exportedAt: Date
        let transcriptStatus: String
        let segments: [Entry]
    }

    static func create(repository: RecordingRepository, job: AutomaticDeliveryJob,
                       destinationDirectory: URL, transcript: SegmentTranscript?) throws -> URL {
        let manifest = job.manifest
        guard manifest.fileName == manifest.id.uuidString.lowercased() + ".caf", manifest.byteCount > 0,
              manifest.byteCount <= 128 * 1_024 * 1_024 else { throw AutomaticReceiverError.invalidArchive }
        if let transcript { try transcript.validate(against: manifest) }
        let fm = FileManager.default
        let attempt = UUID().uuidString.lowercased()
        let staging = destinationDirectory.appendingPathComponent("preparing-" + attempt, isDirectory: true)
        let payload = staging.appendingPathComponent("Record-for-Agent-" + job.id.uuidString.lowercased(), isDirectory: true)
        let audio = payload.appendingPathComponent("audio", isDirectory: true)
        let result = destinationDirectory.appendingPathComponent(job.id.uuidString.lowercased() + "-" + attempt + ".zip")
        try fm.createDirectory(at: audio, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        do {
            try verifiedCopy(from: repository.audioURL(for: manifest), to: audio.appendingPathComponent(manifest.fileName), manifest: manifest)
            try Task.checkCancellation()
            let envelope = Envelope(schemaVersion: 3, exportID: job.id, exportedAt: job.createdAt,
                transcriptStatus: transcript == nil ? "not_generated" : "ready",
                segments: [.init(manifest: manifest, audioPath: "audio/" + manifest.fileName, transcript: transcript,
                                 metadata: try AgentRecordingMetadata(manifest: manifest))])
            let bytes = try TransportCodec.encode(envelope)
            guard bytes.count <= 4 * 1_024 * 1_024 else { throw AutomaticReceiverError.invalidArchive }
            try bytes.write(to: payload.appendingPathComponent("export.json"), options: .atomic)
            try Data("Record for Agent — one explicitly authorized recording. Original audio and available transcript are bound to the frozen manifest and its SHA-256. A receiver receipt confirms storage, not Agent processing or permission to delete the source.\n".utf8)
                .write(to: payload.appendingPathComponent("README.md"), options: .atomic)
            try Task.checkCancellation()
            var coordinationError: NSError?
            var archiveError: Error?
            NSFileCoordinator().coordinate(readingItemAt: payload, options: .forUploading, error: &coordinationError) { snapshot in
                do { try fm.copyItem(at: snapshot, to: result) }
                catch { archiveError = error }
            }
            if let coordinationError { throw coordinationError }
            if let archiveError { throw archiveError }
            try Task.checkCancellation()
            let attributes = try fm.attributesOfItem(atPath: result.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let count = attributes[.size] as? NSNumber,
                  count.int64Value > 0, count.int64Value <= AutomaticDeliveryLedger.maximumArchiveBytes else {
                throw AutomaticReceiverError.invalidArchive
            }
            #if os(iOS)
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: result.path)
            #endif
            let handle = try FileHandle(forWritingTo: result)
            try handle.synchronize(); try handle.close()
            let directoryFD = Darwin.open(destinationDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directoryFD >= 0 else { throw AutomaticReceiverError.localStateUnavailable }
            defer { Darwin.close(directoryFD) }
            guard Darwin.fsync(directoryFD) == 0 else { throw AutomaticReceiverError.localStateUnavailable }
            return result
        } catch {
            try? fm.removeItem(at: result)
            throw error
        }
    }

    private static func verifiedCopy(from source: URL, to target: URL, manifest: SegmentManifest) throws {
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw AutomaticReceiverError.invalidArchive }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
              information.st_size == manifest.byteCount else { throw AutomaticReceiverError.invalidArchive }
        let outputDescriptor = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard outputDescriptor >= 0 else { throw AutomaticReceiverError.invalidArchive }
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        defer { try? output.close() }
        var digest = SHA256()
        var total: Int64 = 0
        while let data = try input.read(upToCount: 256 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            total += Int64(data.count)
            guard total <= manifest.byteCount else { throw AutomaticReceiverError.invalidArchive }
            digest.update(data: data)
            try output.write(contentsOf: data)
        }
        guard total == manifest.byteCount,
              digest.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else {
            throw AutomaticReceiverError.invalidArchive
        }
        try output.synchronize()
    }
}
