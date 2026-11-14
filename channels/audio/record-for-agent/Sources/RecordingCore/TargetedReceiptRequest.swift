import Foundation

/// A request for one existing durable receipt, never acknowledgement authority.
/// The legacy requestSync flag can accompany this payload for older counterparts.
public struct TargetedReceiptRequest: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case unsupportedSchemaVersion, invalidChecksum, invalidByteCount
    }

    public let schemaVersion: Int
    public let segmentID: UUID
    public let sha256: String
    public let byteCount: Int64

    public init(schemaVersion: Int = 1, segmentID: UUID, sha256: String, byteCount: Int64) throws {
        self.schemaVersion = schemaVersion
        self.segmentID = segmentID
        self.sha256 = sha256
        self.byteCount = byteCount
        try validate()
    }

    public init(manifest: SegmentManifest) throws {
        try self.init(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
                      segmentID: values.decode(UUID.self, forKey: .segmentID),
                      sha256: values.decode(String.self, forKey: .sha256),
                      byteCount: values.decode(Int64.self, forKey: .byteCount))
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw ValidationError.unsupportedSchemaVersion }
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw ValidationError.invalidChecksum }
        guard byteCount > 0 else { throw ValidationError.invalidByteCount }
    }

    public func matches(_ receipt: SegmentReceipt) -> Bool {
        segmentID == receipt.segmentID && sha256 == receipt.sha256 && byteCount == receipt.byteCount
    }

    public func matches(_ manifest: SegmentManifest) -> Bool {
        segmentID == manifest.id && sha256 == manifest.sha256 && byteCount == manifest.byteCount
    }
}
