import XCTest
@testable import RecordingCore

final class ReceiptReplayRepositoryTests: XCTestCase {
    private var directory: URL!
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func repository(_ name: String,
                            fault: ((RepositoryFaultPoint) throws -> Void)? = nil) throws -> RecordingRepository {
        try RecordingRepository(root: directory.appendingPathComponent(name), faultInjector: fault)
    }

    private func seal(_ repository: RecordingRepository, id: UUID = UUID()) throws -> SegmentManifest {
        let staging = repository.stagingURL(for: id)
        try Data(repeating: 42, count: 8_192).write(to: staging)
        return try repository.sealSegment(stagedURL: staging, id: id, sessionID: UUID(),
            sequence: 0, startedAt: instant, endedAt: instant.addingTimeInterval(60),
            sampleRate: 16_000, frameCount: 960_000)
    }

    private func receiptURL(_ repository: RecordingRepository, id: UUID) -> URL {
        repository.root.appendingPathComponent("receipts")
            .appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    func testCandidatesAreStableAndDoNotReadOrVerifyReceiptContentsOrAudio() throws {
        let watch = try repository("watch")
        let phone = try repository("phone")
        let ids = [
            UUID(uuidString: "c0000000-0000-0000-0000-000000000003")!,
            UUID(uuidString: "a0000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "b0000000-0000-0000-0000-000000000002")!
        ]
        var manifests: [SegmentManifest] = []
        for id in ids {
            let manifest = try seal(watch, id: id)
            _ = try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
            manifests.append(manifest)
        }
        try Data("damaged JSON".utf8).write(to: receiptURL(phone, id: ids[0]))
        try FileManager.default.removeItem(at: phone.audioURL(for: manifests[1]))
        try Data(repeating: 7, count: 8_192).write(to: phone.audioURL(for: manifests[2]))
        // Noncanonical names are never committed receipt identities.
        let receiptsDirectory = phone.root.appendingPathComponent("receipts")
        try Data().write(to: receiptsDirectory.appendingPathComponent("invalid.json"))
        try Data().write(to: receiptsDirectory.appendingPathComponent(ids[0].uuidString + ".json"))
        try Data().write(to: receiptsDirectory.appendingPathComponent(UUID().uuidString.lowercased() + ".tmp"))
        let reopened = try repository("phone", fault: {
            if case .afterReceiptWriteBeforeSync = $0 { throw SimulatedSyncFailure() }
        })

        let expected = ids.sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(try reopened.receiptIDsForReplay(), expected)
        XCTAssertEqual(try reopened.receiptIDsForReplay(), expected)
        XCTAssertThrowsError(try reopened.receipts(), "The existing all-receipts API must retain its strict semantics.")
    }

    func testVerifiedReplayReturnsOriginalReceiptAndSurvivesRestart() throws {
        let watch = try repository("watch")
        let phone = try repository("phone")
        let manifest = try seal(watch)
        let original = try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)

        XCTAssertEqual(try phone.verifiedReceipt(for: manifest.id), original)
        let reopened = try repository("phone")
        XCTAssertEqual(try reopened.verifiedReceipt(for: manifest.id), original)
        XCTAssertEqual(try reopened.receipts(), [original])
        XCTAssertEqual(try RecordingRepository.fingerprint(of: phone.audioURL(for: manifest)).sha256,
                       manifest.sha256)
        XCTAssertEqual(try watch.pendingSegments(), [manifest], "Replay alone must not acknowledge or prune the sender.")
    }

    func testCorruptAndMissingCandidatesDoNotPreventIndependentValidReplays() throws {
        let watch = try repository("watch")
        let phone = try repository("phone")
        var manifests: [SegmentManifest] = []
        var receipts: [SegmentReceipt] = []
        for _ in 0..<5 {
            let manifest = try seal(watch)
            manifests.append(manifest)
            receipts.append(try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest))
        }
        try FileManager.default.removeItem(at: phone.audioURL(for: manifests[1]))
        try Data(repeating: 9, count: 8_192).write(to: phone.audioURL(for: manifests[2]))
        try Data("bad receipt".utf8).write(to: receiptURL(phone, id: manifests[3].id))

        var verified: [SegmentReceipt] = []
        var failures: Set<UUID> = []
        for id in try phone.receiptIDsForReplay() {
            do { verified.append(try phone.verifiedReceipt(for: id)) }
            catch { failures.insert(id) }
        }
        XCTAssertEqual(Set(verified.map(\.segmentID)), [manifests[0].id, manifests[4].id])
        XCTAssertEqual(verified.first { $0.segmentID == manifests[0].id }, receipts[0])
        XCTAssertEqual(verified.first { $0.segmentID == manifests[4].id }, receipts[4])
        XCTAssertEqual(failures, Set(manifests[1...3].map(\.id)))
        XCTAssertEqual(try watch.pendingSegments().count, 5)
        XCTAssertThrowsError(try phone.verifiedReceipt(for: manifests[1].id)) {
            XCTAssertEqual($0 as? RepositoryError, .missingAudio)
        }
        XCTAssertThrowsError(try phone.verifiedReceipt(for: manifests[2].id)) {
            XCTAssertEqual($0 as? RepositoryError, .checksumMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: phone.audioURL(for: manifests[2])).first, 9,
                       "Rejected audio must remain available for diagnosis and repair.")
    }

    func testReplayRejectsReceiptMovedUnderAnotherCandidatesFilename() throws {
        let watch = try repository("watch")
        let phone = try repository("phone")
        let first = try seal(watch)
        let second = try seal(watch)
        _ = try phone.acceptIncomingFile(at: watch.audioURL(for: first), manifest: first)
        let secondReceipt = try phone.acceptIncomingFile(at: watch.audioURL(for: second), manifest: second)
        try TransportCodec.encode(secondReceipt).write(to: receiptURL(phone, id: first.id))

        XCTAssertThrowsError(try phone.verifiedReceipt(for: first.id)) {
            XCTAssertEqual($0 as? RepositoryError, .receiptMismatch)
        }
        XCTAssertEqual(try phone.verifiedReceipt(for: second.id), secondReceipt)
    }

    func testReplayRejectsInvalidManifestEvenWhenReceiptAndAudioMatch() throws {
        let watch = try repository("watch")
        let phone = try repository("phone")
        let manifest = try seal(watch)
        _ = try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        let invalid = SegmentManifest(id: manifest.id, sessionID: manifest.sessionID, sequence: manifest.sequence,
            startedAt: manifest.startedAt, endedAt: manifest.endedAt, sampleRate: manifest.sampleRate,
            frameCount: manifest.frameCount, fileName: manifest.fileName,
            byteCount: manifest.byteCount, sha256: manifest.sha256, schemaVersion: 2)
        let manifestURL = phone.root.appendingPathComponent("manifests")
            .appendingPathComponent(manifest.id.uuidString.lowercased() + ".json")
        try TransportCodec.encode(invalid).write(to: manifestURL)

        XCTAssertThrowsError(try phone.verifiedReceipt(for: manifest.id)) {
            XCTAssertEqual($0 as? RepositoryError, .invalidManifest("不支持的版本"))
        }
        XCTAssertEqual(try Data(contentsOf: manifestURL), try TransportCodec.encode(invalid))
    }

    func testReplayCannotReturnVisibleReceiptUntilItsSynchronizationSucceeds() throws {
        let watch = try repository("watch")
        let setupPhone = try repository("phone")
        let first = try seal(watch)
        let second = try seal(watch)
        let firstReceipt = try setupPhone.acceptIncomingFile(at: watch.audioURL(for: first), manifest: first)
        let secondReceipt = try setupPhone.acceptIncomingFile(at: watch.audioURL(for: second), manifest: second)
        var failNextSync = true
        let phone = try repository("phone", fault: {
            if case .afterReceiptWriteBeforeSync = $0, failNextSync {
                failNextSync = false
                throw SimulatedSyncFailure()
            }
        })

        XCTAssertThrowsError(try phone.verifiedReceipt(for: first.id)) {
            XCTAssertTrue($0 is SimulatedSyncFailure)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL(phone, id: first.id).path))
        XCTAssertEqual(try phone.verifiedReceipt(for: second.id), secondReceipt)
        XCTAssertEqual(try phone.verifiedReceipt(for: first.id), firstReceipt)
        XCTAssertEqual(try watch.pendingSegments().count, 2)
    }

    func testCandidateDisappearingAfterEnumerationDoesNotCreateNewReceipt() throws {
        let watch = try repository("watch")
        let phone = try repository("phone")
        let manifest = try seal(watch)
        _ = try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        XCTAssertEqual(try phone.receiptIDsForReplay(), [manifest.id])
        let url = receiptURL(phone, id: manifest.id)
        try FileManager.default.removeItem(at: url)

        XCTAssertThrowsError(try phone.verifiedReceipt(for: manifest.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try phone.receiptIDsForReplay(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: phone.audioURL(for: manifest).path))
    }

    func testMissingReceiptDirectoryIsNotReportedAsAnEmptyBacklog() throws {
        let phone = try repository("phone")
        try FileManager.default.removeItem(at: phone.root.appendingPathComponent("receipts"))
        XCTAssertThrowsError(try phone.receiptIDsForReplay())
    }

    private struct SimulatedSyncFailure: Error {}
}
