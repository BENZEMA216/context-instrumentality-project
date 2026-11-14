import Foundation
import XCTest
@testable import RecordingCore

/// Synthetic metadata only: no recordings, credentials or network are used.
final class GoogleDriveUploadCorrelationTests: XCTestCase {
    private let segmentID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let manifestSHA = String(repeating: "a", count: 64)
    private var correlation: GoogleDriveUploadCorrelation {
        .init(segmentID: segmentID, kind: .audio, manifestSHA256: manifestSHA)
    }
    private func receipt(_ correlation: GoogleDriveUploadCorrelation?, at: Int64? = 2_000,
                         state: String = "remote_verified", kind: String = "audio") -> SyncEvidenceArtifact {
        .init(kind: kind, sha256: manifestSHA, byteCount: 320_000, state: state,
              recordedAtMS: at, origin: "observed_callback", uploadCorrelation: correlation)
    }

    func testStableBoundedKeyContainsOnlyDigestKindAndScope() throws {
        XCTAssertEqual(correlation.jobKey, "90828625b58e8515")
        XCTAssertTrue(correlation.isValid)
        XCTAssertNotEqual(correlation, .init(segmentID: UUID(), kind: .audio, manifestSHA256: manifestSHA))
        XCTAssertNotEqual(correlation, .init(segmentID: segmentID, kind: .manifest, manifestSHA256: manifestSHA))
        XCTAssertNotEqual(correlation, .init(segmentID: segmentID, kind: .audio, manifestSHA256: String(repeating: "b", count: 64)))
        let bytes = try JSONEncoder().encode(correlation)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["scope", "kind", "jobKey"])
        XCTAssertEqual(object["scope"], "upload_job")
        let text = String(decoding: bytes, as: UTF8.self)
        for secret in [segmentID.uuidString.lowercased(), manifestSHA, "/Users/", "access_token", "account", "body"] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertEqual(try JSONDecoder().decode(GoogleDriveUploadCorrelation.self, from: bytes), correlation)
    }

    func testUnattributedSharedRefreshCannotClaimJobRecovery() throws {
        let shared = GoogleDriveUploadCorrelation.shared
        XCTAssertTrue(shared.isValid)
        XCTAssertNil(shared.jobKey); XCTAssertNil(shared.kind)
        let data = try JSONEncoder().encode(shared)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: String], ["scope": "shared"])
        XCTAssertEqual(GoogleDriveUploadRecoveryEvidence.evaluate(failureCorrelation: shared,
            naturalTimeout: true, failureAtMS: 1_000, receipt: receipt(shared)), .insufficientEvidence)
    }

    func testNextOpportunityStrictReceiptProvesOnlySameJobRecovery() {
        XCTAssertEqual(GoogleDriveUploadRecoveryEvidence.evaluate(failureCorrelation: correlation,
            naturalTimeout: true, failureAtMS: 1_000, receipt: receipt(correlation)), .pass)
        let other = GoogleDriveUploadCorrelation(segmentID: UUID(), kind: .audio, manifestSHA256: manifestSHA)
        for candidate in [receipt(other), receipt(nil), receipt(correlation, at: nil), receipt(correlation, at: 1_000),
                          receipt(correlation, at: 999), receipt(correlation, state: "pending"), receipt(correlation, kind: "manifest")] {
            XCTAssertEqual(GoogleDriveUploadRecoveryEvidence.evaluate(failureCorrelation: correlation,
                naturalTimeout: true, failureAtMS: 1_000, receipt: candidate), .insufficientEvidence)
        }
        XCTAssertEqual(GoogleDriveUploadRecoveryEvidence.evaluate(failureCorrelation: nil,
            naturalTimeout: true, failureAtMS: 1_000, receipt: receipt(correlation)), .insufficientEvidence)
        XCTAssertEqual(GoogleDriveUploadRecoveryEvidence.evaluate(failureCorrelation: correlation,
            naturalTimeout: false, failureAtMS: 1_000, receipt: receipt(correlation)), .insufficientEvidence)
    }

    func testLegacyReceiptDecodesWithoutInventingCorrelation() throws {
        let bytes = try JSONEncoder().encode(receipt(nil))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("uploadCorrelation"))
        let legacy = try JSONDecoder().decode(SyncEvidenceArtifact.self, from: bytes)
        XCTAssertNil(legacy.uploadCorrelation)
        XCTAssertEqual(GoogleDriveUploadRecoveryEvidence.evaluate(failureCorrelation: correlation,
            naturalTimeout: true, failureAtMS: 1_000, receipt: legacy).rawValue, "insufficient_evidence")
    }

    func testUntrustedDecodedCorrelationRejectsSensitiveOrMalformedFields() throws {
        for value in [
            ["scope": "upload_job", "jobKey": "/Users/private/account", "kind": "audio"],
            ["scope": "upload_job", "jobKey": "ABCDEF0123456789", "kind": "audio"],
            ["scope": "upload_job", "jobKey": "abcdef0123456789", "kind": "private-token"],
            ["scope": "shared", "jobKey": "abcdef0123456789", "kind": "audio"],
            ["scope": "upload_job", "kind": "audio"]
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(GoogleDriveUploadCorrelation.self,
                from: JSONSerialization.data(withJSONObject: value)))
        }
        let extraFields = Data("{\"scope\":\"shared\",\"path\":\"/private/synthetic\",\"token\":\"synthetic-token\"}".utf8)
        let sanitized = try JSONDecoder().decode(GoogleDriveUploadCorrelation.self, from: extraFields)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(sanitized)) as? [String: String], ["scope": "shared"])
    }
}
