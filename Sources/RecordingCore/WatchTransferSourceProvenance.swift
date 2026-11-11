import Foundation

extension RecordingRepository {
    private struct TransferSourceProvenance: Codable {
        let segmentID: UUID
        let byteCount: Int64
        let sha256: String
        let category: WatchTransferSourceCategory
    }
    private func transferSourceProvenanceURL(_ id: UUID) -> URL {
        root.appendingPathComponent("ConnectivityDiagnostics/source-category", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased() + ".json")
    }
    /// Best effort diagnostic evidence only. Failure must not change seal, ACK,
    /// authorization or recovery semantics. Existing unlabelled files stay unknown.
    func noteTransferSourceProvenance(_ manifest: SegmentManifest, category: WatchTransferSourceCategory) {
        try? synchronized {
            let url = transferSourceProvenanceURL(manifest.id)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(watchOS) || os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                 ofItemAtPath: url.deletingLastPathComponent().path)
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            #else
            let options: Data.WritingOptions = .atomic
            #endif
            let value = TransferSourceProvenance(segmentID: manifest.id, byteCount: manifest.byteCount,
                                                 sha256: manifest.sha256, category: category)
            try JSONEncoder().encode(value).write(to: url, options: options)
        }
    }
    public func diagnosticSourceCategory(for manifest: SegmentManifest) -> WatchTransferSourceCategory {
        (try? synchronized {
            let url = transferSourceProvenanceURL(manifest.id)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.intValue > 0, size.intValue <= 1_024 else { return WatchTransferSourceCategory.unknown }
            let value = try JSONDecoder().decode(TransferSourceProvenance.self, from: Data(contentsOf: url))
            guard value.segmentID == manifest.id, value.byteCount == manifest.byteCount,
                  value.sha256 == manifest.sha256 else { return WatchTransferSourceCategory.unknown }
            return value.category
        }) ?? .unknown
    }
}
