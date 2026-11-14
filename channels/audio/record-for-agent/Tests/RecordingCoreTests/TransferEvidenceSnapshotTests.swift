import XCTest
import Darwin
@testable import RecordingCore

final class TransferEvidenceSnapshotTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-evidence-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }
    private func fixture() throws -> (RecordingRepository, SegmentManifest, SegmentReceipt) {
        let repository = try RecordingRepository(root: root, faultInjector: { _ in
            XCTFail("A read-only metadata evidence capture crossed a mutation/fsync fault boundary")
            throw RepositoryError.persistenceFailure("synthetic forbidden mutation")
        }, recoverTransactionsOnInitialization: false)
        let id = UUID(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = SegmentManifest(id: id, sessionID: UUID(), sequence: 0,
            startedAt: date, endedAt: date.addingTimeInterval(60), sampleRate: 16_000,
            frameCount: 960_000, fileName: id.uuidString.lowercased() + ".caf", byteCount: 8192,
            sha256: String(repeating: "a", count: 64))
        let receipt = SegmentReceipt(segmentID: id, sha256: manifest.sha256, byteCount: manifest.byteCount, receivedAt: date)
        try TransportCodec.encode(manifest).write(to: path("manifests", id))
        return (repository, manifest, receipt)
    }
    private func path(_ folder: String, _ id: UUID) -> URL {
        root.appendingPathComponent(folder).appendingPathComponent(id.uuidString.lowercased() + ".json")
    }
    func testCompleteMetadataCatalogueIgnoresAudioAndEventsAndNeverRewrites() throws {
        let (repository, manifest, receipt) = try fixture()
        try TransportCodec.encode(receipt).write(to: path("receipts", manifest.id))
        try TransportCodec.encode(receipt).write(to: path("acknowledgements", manifest.id))
        // No synthetic audio exists. A corrupt event and FIFO are deliberately
        // irrelevant: the new catalogue must never enumerate/read event history.
        try Data("broken".utf8).write(to: path("events", UUID()))
        XCTAssertEqual(Darwin.mkfifo(path("events", UUID()).path, 0o600), 0)
        let paths = [path("manifests", manifest.id), path("receipts", manifest.id), path("acknowledgements", manifest.id)]
        let before = try paths.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.systemFileNumber] as? NSNumber }
        let snapshot = try repository.transferEvidenceSnapshot()
        XCTAssertEqual(snapshot.manifests, [manifest]); XCTAssertEqual(snapshot.receipts, [receipt])
        XCTAssertEqual(snapshot.acknowledgements, [receipt])
        XCTAssertEqual(try repository.transferEvidenceManifest(id: manifest.id), manifest)
        XCTAssertEqual(try paths.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.systemFileNumber] as? NSNumber }, before)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("segments").path).isEmpty)
    }
    func testOrphanAndMismatchingHistoricalACKAreRejected() throws {
        let (repository, manifest, receipt) = try fixture()
        let invalid = SegmentReceipt(segmentID: receipt.segmentID, sha256: String(repeating: "b", count: 64), byteCount: receipt.byteCount)
        try TransportCodec.encode(invalid).write(to: path("acknowledgements", manifest.id))
        XCTAssertThrowsError(try repository.transferEvidenceSnapshot()) { XCTAssertEqual($0 as? RepositoryError, .receiptMismatch) }
        try TransportCodec.encode(receipt).write(to: path("acknowledgements", manifest.id))
        try FileManager.default.removeItem(at: path("manifests", manifest.id))
        XCTAssertThrowsError(try repository.transferEvidenceSnapshot()) { XCTAssertEqual($0 as? RepositoryError, .receiptMismatch) }
    }
    func testMismatchingHistoricalReceiptIsRejected() throws {
        let (repository, manifest, receipt) = try fixture()
        let invalid = SegmentReceipt(segmentID: receipt.segmentID, sha256: receipt.sha256, byteCount: receipt.byteCount + 1)
        try TransportCodec.encode(invalid).write(to: path("receipts", manifest.id))
        XCTAssertThrowsError(try repository.transferEvidenceSnapshot()) { XCTAssertEqual($0 as? RepositoryError, .receiptMismatch) }
    }
    func testManifestIdentityAndCaptureMetadataMustBeValid() throws {
        let (repository, manifest, _) = try fixture()
        let wrong = path("manifests", UUID())
        try FileManager.default.moveItem(at: path("manifests", manifest.id), to: wrong)
        XCTAssertThrowsError(try repository.transferEvidenceSnapshot())
        try FileManager.default.moveItem(at: wrong, to: path("manifests", manifest.id))
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: path("manifests", manifest.id))) as! [String: Any]
        json["sha256"] = "bad"
        try JSONSerialization.data(withJSONObject: json).write(to: path("manifests", manifest.id))
        XCTAssertThrowsError(try repository.transferEvidenceSnapshot())
        XCTAssertThrowsError(try repository.transferEvidenceManifest(id: manifest.id))
    }
    func testSymlinkAndHardlinkCannotRedirectMetadataReads() throws {
        let (repository, manifest, _) = try fixture()
        let original = path("manifests", manifest.id), preserved = root.appendingPathComponent("synthetic-preserved-metadata.json")
        try FileManager.default.moveItem(at: original, to: preserved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: preserved)
        XCTAssertThrowsError(try repository.transferEvidenceSnapshot())
        XCTAssertThrowsError(try repository.transferEvidenceManifest(id: manifest.id))
        try FileManager.default.removeItem(at: original)
        try FileManager.default.linkItem(at: preserved, to: original)
        XCTAssertThrowsError(try repository.transferEvidenceSnapshot())
        XCTAssertThrowsError(try repository.transferEvidenceManifest(id: manifest.id))
        XCTAssertEqual(try Data(contentsOf: preserved), try TransportCodec.encode(manifest))
    }
    func testFIFOIsRejectedWithoutWaiting() throws {
        let (repository, manifest, _) = try fixture()
        try FileManager.default.removeItem(at: path("manifests", manifest.id))
        XCTAssertEqual(Darwin.mkfifo(path("manifests", manifest.id).path, 0o600), 0)
        let start = Date()
        XCTAssertThrowsError(try repository.transferEvidenceSnapshot())
        XCTAssertThrowsError(try repository.transferEvidenceManifest(id: manifest.id))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
    func testCorruptMetadataIsNotRepairedOrOmitted() throws {
        let (repository, manifest, _) = try fixture()
        let bytes = Data("{invalid".utf8)
        try bytes.write(to: path("manifests", manifest.id))
        XCTAssertThrowsError(try repository.transferEvidenceSnapshot())
        XCTAssertEqual(try Data(contentsOf: path("manifests", manifest.id)), bytes)
    }
}
