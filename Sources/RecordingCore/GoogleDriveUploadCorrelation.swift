import CryptoKit
import Foundation

/// A bounded, metadata-only join key. The source identity is hashed in memory;
/// paths, account identifiers, credentials and request bodies are never retained.
public struct GoogleDriveUploadCorrelation: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable { case uploadJob = "upload_job", shared }
    public let scope: Scope
    public let jobKey: String?
    public let kind: GoogleDriveArtifact.Kind?

    public init(segmentID: UUID, kind: GoogleDriveArtifact.Kind, manifestSHA256: String) {
        let identity = segmentID.uuidString.lowercased() + "|" + kind.rawValue + "|" + manifestSHA256
        scope = .uploadJob
        jobKey = SHA256.hash(data: Data(identity.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        self.kind = kind
    }

    private init(shared: Void) { scope = .shared; jobKey = nil; kind = nil }
    public static let shared = Self(shared: ())

    public var isValid: Bool {
        switch scope {
        case .uploadJob:
            return kind != nil && jobKey.map { value in
                value.utf8.count == 16 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            } == true
        case .shared:
            return jobKey == nil && kind == nil
        }
    }

    private enum CodingKeys: String, CodingKey { case scope, jobKey, kind }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try container.decode(Scope.self, forKey: .scope)
        jobKey = try container.decodeIfPresent(String.self, forKey: .jobKey)
        kind = try container.decodeIfPresent(GoogleDriveArtifact.Kind.self, forKey: .kind)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid upload correlation"))
        }
    }
}

/// A later HTTP success is not upload recovery. Only a strict cloud receipt for
/// the failed job, recorded after its natural timeout, supplies that proof.
public enum GoogleDriveUploadRecoveryEvidence {
    public enum Verdict: String, Codable, Equatable, Sendable {
        case pass, insufficientEvidence = "insufficient_evidence"
    }

    public static func evaluate(failureCorrelation: GoogleDriveUploadCorrelation?, naturalTimeout: Bool,
                                failureAtMS: Int64, receipt: SyncEvidenceArtifact) -> Verdict {
        guard naturalTimeout, failureAtMS >= 0, let failureCorrelation,
              failureCorrelation.isValid, failureCorrelation.scope == .uploadJob,
              receipt.uploadCorrelation == failureCorrelation,
              receipt.kind == failureCorrelation.kind?.rawValue,
              receipt.state == "remote_verified", let recordedAtMS = receipt.recordedAtMS,
              recordedAtMS > failureAtMS else { return .insufficientEvidence }
        return .pass
    }
}
