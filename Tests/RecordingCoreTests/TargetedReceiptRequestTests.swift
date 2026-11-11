import XCTest
@testable import RecordingCore

final class TargetedReceiptRequestTests: XCTestCase {
    private let id = UUID(uuidString: "7CFA71D1-58DD-4D5E-AF8E-4352A918E85D")!
    private let checksum = String(repeating: "a", count: 64)

    private func encoded(overrides: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["schemaVersion": 1, "segmentID": id.uuidString,
                                    "sha256": checksum, "byteCount": 4_096]
        value.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }

    func testRoundTripPreservesExactIdentityWithoutReceiptAuthority() throws {
        let request = try TargetedReceiptRequest(segmentID: id, sha256: checksum, byteCount: 4_096)
        XCTAssertEqual(try TransportCodec.decode(TargetedReceiptRequest.self,
                       from: TransportCodec.encode(request)), request)
        XCTAssertTrue(request.matches(SegmentReceipt(segmentID: id, sha256: checksum, byteCount: 4_096)))
        XCTAssertFalse(request.matches(SegmentReceipt(segmentID: UUID(), sha256: checksum, byteCount: 4_096)))
        XCTAssertFalse(request.matches(SegmentReceipt(segmentID: id, sha256: String(repeating: "b", count: 64), byteCount: 4_096)))
        XCTAssertFalse(request.matches(SegmentReceipt(segmentID: id, sha256: checksum, byteCount: 4_097)))
    }

    func testManifestInitializerAndMatchingUseTheSameThreeIdentityFields() throws {
        let manifest = SegmentManifest(id: id, sessionID: UUID(), sequence: 7,
            startedAt: Date(), endedAt: Date(), sampleRate: 48_000, frameCount: 1,
            fileName: id.uuidString.lowercased() + ".caf", byteCount: 4_096, sha256: checksum)
        let request = try TargetedReceiptRequest(manifest: manifest)
        XCTAssertTrue(request.matches(manifest))
        XCTAssertEqual(request.segmentID, manifest.id)
        let mismatched = try TargetedReceiptRequest(segmentID: id, sha256: checksum, byteCount: 4_095)
        XCTAssertFalse(mismatched.matches(manifest))
    }

    func testDecoderRejectsUnsupportedVersionAndMalformedUUID() throws {
        for version in [0, 2, -1] {
            XCTAssertThrowsError(try TransportCodec.decode(TargetedReceiptRequest.self,
                from: encoded(overrides: ["schemaVersion": version])))
        }
        for value in ["", "not-a-uuid", "../" + id.uuidString, id.uuidString + " "] {
            XCTAssertThrowsError(try TransportCodec.decode(TargetedReceiptRequest.self,
                from: encoded(overrides: ["segmentID": value])))
        }
    }

    func testBothInitializationAndDecodingRejectNoncanonicalChecksums() throws {
        for value in [String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                      String(repeating: "A", count: 64), String(repeating: "g", count: 64),
                      String(repeating: "ａ", count: 64)] {
            XCTAssertThrowsError(try TargetedReceiptRequest(segmentID: id, sha256: value, byteCount: 1))
            XCTAssertThrowsError(try TransportCodec.decode(TargetedReceiptRequest.self,
                from: encoded(overrides: ["sha256": value])))
        }
    }

    func testByteCountMustBeAPositiveInt64() throws {
        for count: Int64 in [0, -1] {
            XCTAssertThrowsError(try TargetedReceiptRequest(segmentID: id, sha256: checksum, byteCount: count))
            XCTAssertThrowsError(try TransportCodec.decode(TargetedReceiptRequest.self,
                from: encoded(overrides: ["byteCount": count])))
        }
        for value: Any in [1.5, "4096", true] {
            XCTAssertThrowsError(try TransportCodec.decode(TargetedReceiptRequest.self,
                from: encoded(overrides: ["byteCount": value])))
        }
        XCTAssertEqual(try TargetedReceiptRequest(segmentID: id, sha256: checksum, byteCount: .max).byteCount, .max)
    }

    func testLegacyCompatibleEnvelopeIsAPropertyListAndContainsOnlyIdentityMetadata() throws {
        let request = try TargetedReceiptRequest(segmentID: id, sha256: checksum, byteCount: 4_096)
        let envelope: [String: Any] = [TransportCodec.requestSyncKey: true,
            TransportCodec.targetedReceiptRequestKey: try TransportCodec.encode(request)]
        XCTAssertTrue(PropertyListSerialization.propertyList(envelope, isValidFor: .binary))
        XCTAssertEqual(envelope[TransportCodec.requestSyncKey] as? Bool, true)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: TransportCodec.encode(request)) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set(["schemaVersion", "segmentID", "sha256", "byteCount"]))
        XCTAssertNil(envelope[TransportCodec.receiptKey])
    }
}
