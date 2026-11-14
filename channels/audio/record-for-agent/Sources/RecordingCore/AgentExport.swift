import Foundation

public enum AgentExportError: LocalizedError {
    case emptySelection, selectionChanged, tooLarge, damagedAudio, archiveUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptySelection: return "请先选择要交给 Agent 的录音。"
        case .selectionChanged: return "部分所选录音已不可用，请重新选择。"
        case .tooLarge: return "每次最多导出 500 段、500 MB 录音，请减少选择后重试。"
        case .damagedAudio: return "所选录音未通过完整性检查，未生成导出包。原始录音仍保留。"
        case .archiveUnavailable: return "系统未能生成导出包，请稍后重试。"
        }
    }
}

public struct AgentExportManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let exportID: UUID
    public let exportedAt: Date
    public let transcriptStatus: String
    public let segments: [Entry]

    public struct Entry: Codable, Sendable {
        public let manifest: SegmentManifest
        public let audioPath: String
        public let transcript: SegmentTranscript?
        public let metadata: AgentRecordingMetadata?
    }
}

/// An explicit selection boundary. It never reads audio outside selectedIDs and
/// never changes repository audio, receipts, or transfer state.
public enum AgentExportBuilder {
    public static let maximumBytes: Int64 = 500 * 1_024 * 1_024
    public static let maximumSegments = 500

    public static func createArchive(repository: RecordingRepository, selectedIDs: Set<UUID>,
                                     destinationDirectory: URL, now: Date = Date(),
                                     transcripts: [UUID: SegmentTranscript] = [:]) throws -> URL {
        try createArchive(repository: repository, selectedIDs: selectedIDs,
                          destinationDirectory: destinationDirectory, now: now,
                          transcripts: transcripts, archiveWriter: writeSystemArchive)
    }

    // Internal seam for synthetic tests of the real payload and cleanup paths
    // when Foundation's upload-archive service is unavailable. The public API
    // always uses the system writer; there is no production fallback.
    static func createArchive(repository: RecordingRepository, selectedIDs: Set<UUID>,
                              destinationDirectory: URL, now: Date = Date(),
                              transcripts: [UUID: SegmentTranscript] = [:],
                              archiveWriter: (URL, URL) throws -> Void) throws -> URL {
        guard !selectedIDs.isEmpty else { throw AgentExportError.emptySelection }
        guard selectedIDs.count <= maximumSegments else { throw AgentExportError.tooLarge }
        let selected = try repository.manifests().filter { selectedIDs.contains($0.id) }
            .sorted { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt }
        guard selected.count == selectedIDs.count else { throw AgentExportError.selectionChanged }
        var totalBytes: Int64 = 0
        for manifest in selected {
            if let transcript = transcripts[manifest.id] { try transcript.validate(against: manifest) }
            guard manifest.byteCount > 0, manifest.byteCount <= maximumBytes - totalBytes else {
                throw AgentExportError.tooLarge
            }
            guard manifest.fileName == manifest.id.uuidString.lowercased() + ".caf" else {
                throw AgentExportError.damagedAudio
            }
            totalBytes += manifest.byteCount
        }

        let fm = FileManager.default
        let exportID = UUID()
        let name = "Record-for-Agent-" + exportID.uuidString.lowercased()
        let staging = destinationDirectory.appendingPathComponent("staging-" + exportID.uuidString, isDirectory: true)
        let payload = staging.appendingPathComponent(name, isDirectory: true)
        let audio = payload.appendingPathComponent("audio", isDirectory: true)
        let result = destinationDirectory.appendingPathComponent(name + ".zip")
        try fm.createDirectory(at: audio, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            var entries: [AgentExportManifest.Entry] = []
            for manifest in selected {
                let fileName = manifest.id.uuidString.lowercased() + ".caf"
                let copy = audio.appendingPathComponent(fileName)
                let source = repository.audioURL(for: manifest)
                try requireRegularFile(source, fileManager: fm)
                try fm.copyItem(at: source, to: copy)
                try requireRegularFile(copy, fileManager: fm)
                // Verify the exported bytes, so changes during copying cannot
                // produce an archive whose declared digest differs from its audio.
                let fingerprint = try RecordingRepository.fingerprint(of: copy)
                guard fingerprint.byteCount == manifest.byteCount,
                      fingerprint.sha256 == manifest.sha256 else { throw AgentExportError.damagedAudio }
                entries.append(.init(manifest: manifest, audioPath: "audio/" + fileName,
                                     transcript: transcripts[manifest.id], metadata: try AgentRecordingMetadata(manifest: manifest)))
            }
            let transcriptCount = entries.filter { $0.transcript != nil }.count
            let status = transcriptCount == 0 ? "not_generated" : (transcriptCount == entries.count ? "ready" : "partial")
            let manifest = AgentExportManifest(schemaVersion: 3,
                                               exportID: exportID, exportedAt: now,
                                               transcriptStatus: status, segments: entries)
            let metadata = try TransportCodec.encode(manifest)
            guard metadata.count <= 4 * 1_024 * 1_024 else { throw AgentExportError.tooLarge }
            try metadata.write(to: payload.appendingPathComponent("export.json"), options: .atomic)
            let readme = """
            Record for Agent — selected recordings

            This archive contains only the recordings selected on the iPhone.
            export.json preserves the original segment timestamps, sequence,
            byte counts and SHA-256 digests. audio/ contains the original CAF files.
            Transcript status: \(status). Available transcripts are included inline
            in export.json and bound to the SHA-256 of their source recording.
            Import with the Record for Agent local bridge before using an Agent.
            The receiving application can access all recordings in this archive.
            """
            try Data(readme.utf8).write(to: payload.appendingPathComponent("README.md"), options: .atomic)
            try archiveWriter(payload, result)
            guard fm.fileExists(atPath: result.path) else { throw AgentExportError.archiveUnavailable }
            return result
        } catch {
            try? fm.removeItem(at: result)
            throw error
        }
    }

    private static func writeSystemArchive(payload: URL, result: URL) throws {
        var coordinationError: NSError?
        var archiveError: Error?
        // Foundation creates a ZIP snapshot. Copy it while the accessor owns
        // its temporary URL; that URL is invalid after the accessor returns.
        NSFileCoordinator().coordinate(readingItemAt: payload, options: .forUploading,
                                        error: &coordinationError) { snapshot in
            do { try FileManager.default.copyItem(at: snapshot, to: result) }
            catch { archiveError = error }
        }
        if let coordinationError { throw coordinationError }
        if let archiveError { throw archiveError }
    }

    private static func requireRegularFile(_ url: URL, fileManager: FileManager) throws {
        // attributesOfItem reports the link itself. Never follow a substituted
        // symlink while checking a selected recording or archiving its copy.
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw AgentExportError.damagedAudio
        }
    }
}
