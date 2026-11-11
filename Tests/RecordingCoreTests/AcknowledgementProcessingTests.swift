import XCTest
@testable import RecordingCore

final class AcknowledgementProcessingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func repository(fault: ((RepositoryFaultPoint) throws -> Void)? = nil) throws -> RecordingRepository {
        try RecordingRepository(root: root, faultInjector: fault)
    }

    private func fixture(_ repository: RecordingRepository) throws -> (SegmentManifest, SegmentReceipt) {
        let id = UUID()
        let payload = Data(repeating: 42, count: 8_192)
        try payload.write(to: repository.stagingURL(for: id))
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = try repository.sealSegment(stagedURL: repository.stagingURL(for: id),
            id: id, sessionID: UUID(), sequence: 0, startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60), sampleRate: 16_000, frameCount: 960_000)
        return (manifest, SegmentReceipt(segmentID: id, sha256: manifest.sha256,
                                         byteCount: manifest.byteCount, receivedAt: startedAt.addingTimeInterval(61)))
    }

    private func ackURL(_ id: UUID) -> URL {
        root.appendingPathComponent("acknowledgements/\(id.uuidString.lowercased()).json")
    }

    func testMissingManifestOperationPreservesOriginalFailureAndCannotCommit() throws {
        let watch = try repository()
        let unknown = SegmentReceipt(segmentID: UUID(), sha256: String(repeating: "a", count: 64), byteCount: 1)
        var operations: [AcknowledgementOperation] = []
        XCTAssertThrowsError(try watch.acknowledge(unknown, pruneAudio: false,
            observingOperation: { operations.append($0) })) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, NSFileReadNoSuchFileError)
        }
        XCTAssertEqual(operations, [.manifestRead])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ackURL(unknown.segmentID).path))
    }

    func testReceiptMismatchOperationDoesNotHideValidationOrPruneAudio() throws {
        let watch = try repository()
        let (manifest, receipt) = try fixture(watch)
        let wrong = SegmentReceipt(segmentID: receipt.segmentID, sha256: String(repeating: "0", count: 64),
            byteCount: receipt.byteCount)
        var operation: AcknowledgementOperation?
        XCTAssertThrowsError(try watch.acknowledge(wrong, observingOperation: { operation = $0 })) { error in
            XCTAssertEqual(error as? RepositoryError, .receiptMismatch)
        }
        XCTAssertEqual(operation, .receiptValidate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ackURL(manifest.id).path))
    }

    func testNewAndReplaySyncFailuresKeepTheirOperationAndRecoverDurably() throws {
        var failing = true
        let watch = try repository { point in
            if case .beforeAcknowledgementSync = point, failing { throw SyncFailure() }
        }
        let (manifest, receipt) = try fixture(watch)
        for _ in 0..<2 {
            var operation: AcknowledgementOperation?
            XCTAssertThrowsError(try watch.acknowledge(receipt, observingOperation: { operation = $0 })) { error in
                XCTAssertTrue(error is SyncFailure)
            }
            XCTAssertEqual(operation, .acknowledgementFileSync)
            XCTAssertTrue(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))
        }
        failing = false
        var operations: [AcknowledgementOperation] = []
        let recovered = try watch.acknowledge(receipt, pruneAudio: false,
            observingOperation: { operations.append($0) })
        XCTAssertFalse(recovered.didChange)
        XCTAssertEqual(operations, [.manifestRead, .manifestValidate, .receiptValidate,
            .acknowledgementFileSync, .acknowledgementDirectorySync])
        XCTAssertTrue(try watch.hasDurableAcknowledgement(for: manifest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))
    }

    func testNewConfirmationAndRepeatedReceiptReportOnlyActualChanges() throws {
        var commits = 0
        var synchronizations = 0
        let watch = try repository {
            if case .beforeAcknowledgementCommit = $0 { commits += 1 }
            if case .beforeAcknowledgementSync = $0 { synchronizations += 1 }
        }
        let (manifest, receipt) = try fixture(watch)
        let first = try watch.acknowledge(receipt)
        XCTAssertTrue(first.acknowledgementChanged)
        XCTAssertTrue(first.audioPruned)
        XCTAssertTrue(first.didChange)
        let before = try FileManager.default.attributesOfItem(atPath: ackURL(manifest.id).path)
        for _ in 0..<20 {
            let repeated = try watch.acknowledge(receipt)
            XCTAssertFalse(repeated.acknowledgementChanged)
            XCTAssertFalse(repeated.audioPruned)
            XCTAssertFalse(repeated.didChange)
        }
        let after = try FileManager.default.attributesOfItem(atPath: ackURL(manifest.id).path)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(synchronizations, 21, "Every duplicate must re-establish ACK durability.")
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(try repository().manifests(), [manifest])
        XCTAssertFalse(try repository().acknowledge(receipt).didChange)
    }

    func testDuplicateReceiptCompletesPreviouslyDeferredPruning() throws {
        let watch = try repository()
        let (manifest, receipt) = try fixture(watch)
        let first = try watch.acknowledge(receipt, pruneAudio: false)
        XCTAssertTrue(first.acknowledgementChanged)
        XCTAssertFalse(first.audioPruned)
        XCTAssertFalse(try watch.acknowledge(receipt, pruneAudio: false).didChange)
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))
        let resumed = try repository().acknowledge(receipt)
        XCTAssertFalse(resumed.acknowledgementChanged)
        XCTAssertTrue(resumed.audioPruned)
        XCTAssertTrue(resumed.didChange)
        XCTAssertFalse(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))
    }

    func testVisibleReceiptAfterFailedSyncMustSynchronizeBeforePruning() throws {
        var failSync = true
        var commits = 0
        let watch = try repository {
            if case .beforeAcknowledgementCommit = $0 { commits += 1 }
            if case .beforeAcknowledgementSync = $0, failSync { throw SyncFailure() }
        }
        let (manifest, receipt) = try fixture(watch)
        XCTAssertThrowsError(try watch.acknowledge(receipt))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ackURL(manifest.id).path))
        XCTAssertThrowsError(try watch.acknowledge(receipt))
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))
        XCTAssertEqual(commits, 1, "An identical failed-sync record must not be rewritten.")
        failSync = false
        let recovered = try watch.acknowledge(receipt)
        XCTAssertFalse(recovered.acknowledgementChanged)
        XCTAssertTrue(recovered.audioPruned)
        XCTAssertTrue(try repository().hasDurableAcknowledgement(for: manifest))
    }

    func testMissingOrCorruptACKIsNotHiddenByEarlierSuccess() throws {
        let watch = try repository()
        let (manifest, receipt) = try fixture(watch)
        try watch.acknowledge(receipt, pruneAudio: false)
        try FileManager.default.removeItem(at: ackURL(manifest.id))
        XCTAssertTrue(try watch.acknowledge(receipt, pruneAudio: false).acknowledgementChanged)
        try Data("corrupt".utf8).write(to: ackURL(manifest.id))
        XCTAssertTrue(try watch.acknowledge(receipt, pruneAudio: false).acknowledgementChanged)
        XCTAssertEqual(try TransportCodec.decode(SegmentReceipt.self, from: Data(contentsOf: ackURL(manifest.id))), receipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))
    }

    func testWrongIncomingReceiptCannotReuseExistingDurableACK() throws {
        let watch = try repository()
        let (manifest, receipt) = try fixture(watch)
        try watch.acknowledge(receipt, pruneAudio: false)
        let before = try Data(contentsOf: ackURL(manifest.id))
        let wrong = [
            SegmentReceipt(segmentID: manifest.id, sha256: String(repeating: "0", count: 64), byteCount: manifest.byteCount),
            SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount + 1)
        ]
        for value in wrong {
            XCTAssertThrowsError(try watch.acknowledge(value)) {
                XCTAssertEqual($0 as? RepositoryError, .receiptMismatch)
            }
        }
        XCTAssertEqual(try Data(contentsOf: ackURL(manifest.id)), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))
    }

    func testChangedLocalManifestIsRevalidatedOnDuplicateReceipt() throws {
        let watch = try repository()
        let (manifest, receipt) = try fixture(watch)
        try watch.acknowledge(receipt, pruneAudio: false)
        let invalid = SegmentManifest(id: manifest.id, sessionID: manifest.sessionID, sequence: manifest.sequence,
            startedAt: manifest.startedAt, endedAt: manifest.endedAt, sampleRate: manifest.sampleRate,
            frameCount: manifest.frameCount, fileName: manifest.fileName, byteCount: manifest.byteCount,
            sha256: manifest.sha256, schemaVersion: 2)
        let manifestURL = root.appendingPathComponent("manifests/\(manifest.id.uuidString.lowercased()).json")
        try TransportCodec.encode(invalid).write(to: manifestURL)
        XCTAssertThrowsError(try watch.acknowledge(receipt)) {
            XCTAssertEqual($0 as? RepositoryError, .invalidManifest("不支持的版本"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))
        try FileManager.default.removeItem(at: manifestURL)
        XCTAssertThrowsError(try watch.acknowledge(receipt))
    }

    func testDifferentReceiptTimestampIsAnActualRecordChange() throws {
        let watch = try repository()
        let (manifest, receipt) = try fixture(watch)
        try watch.acknowledge(receipt, pruneAudio: false)
        let updated = SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount,
                                     receivedAt: receipt.receivedAt.addingTimeInterval(1))
        let result = try watch.acknowledge(updated, pruneAudio: false)
        XCTAssertTrue(result.acknowledgementChanged)
        XCTAssertFalse(result.audioPruned)
        XCTAssertEqual(try TransportCodec.decode(SegmentReceipt.self, from: Data(contentsOf: ackURL(manifest.id))), updated)
    }

    func testPruningStillSynchronizesAudioDirectoryWhenFileIsAlreadyAbsent() throws {
        let watch = try repository()
        let (manifest, receipt) = try fixture(watch)
        try watch.acknowledge(receipt)
        let audioDirectory = root.appendingPathComponent("segments")
        try FileManager.default.removeItem(at: audioDirectory)
        XCTAssertThrowsError(try watch.acknowledge(receipt), "Missing directory cannot be reported as completed cleanup.")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        XCTAssertFalse(try watch.acknowledge(receipt).didChange)
        XCTAssertEqual(try watch.manifests(), [manifest])
    }

    private struct SyncFailure: Error {}
}
