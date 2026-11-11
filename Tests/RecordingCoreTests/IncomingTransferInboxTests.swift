import XCTest
@testable import RecordingCore

final class IncomingTransferInboxTests: XCTestCase {
    private var directory: URL!
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func repository(_ name: String) throws -> RecordingRepository {
        try RecordingRepository(root: directory.appendingPathComponent(name))
    }

    private func inbox(_ name: String = "inbox",
                       fault: ((IncomingTransferInboxFaultPoint) throws -> Void)? = nil) throws -> IncomingTransferInbox {
        try IncomingTransferInbox(root: directory.appendingPathComponent(name), faultInjector: fault)
    }

    private func seal(_ repository: RecordingRepository) throws -> SegmentManifest {
        let id = UUID()
        let staging = repository.stagingURL(for: id)
        try Data(repeating: 42, count: 8_192).write(to: staging)
        return try repository.sealSegment(stagedURL: staging, id: id, sessionID: UUID(),
            sequence: 0, startedAt: instant, endedAt: instant.addingTimeInterval(60),
            sampleRate: 16_000, frameCount: 960_000)
    }

    private func transferDirectory(_ inbox: IncomingTransferInbox, id: UUID) -> URL {
        inbox.root.appendingPathComponent(id.uuidString.lowercased())
    }

    func testPrivateCopySurvivesFrameworkCleanupAndRestartThenImportsAndAcknowledges() throws {
        let watch = try repository("watch")
        let phone = try repository("phone")
        let manifest = try seal(watch)
        let temporary = directory.appendingPathComponent("framework-owned.caf")
        try FileManager.default.copyItem(at: watch.audioURL(for: manifest), to: temporary)
        let id = try inbox().stage(fileURL: temporary, manifest: manifest)
        // WatchConnectivity deletes its temporary URL after the delegate returns.
        try FileManager.default.removeItem(at: temporary)
        XCTAssertEqual(try phone.receipts(), [])
        XCTAssertEqual(try watch.pendingSegments(), [manifest])

        let reopened = try inbox()
        XCTAssertEqual(try reopened.pendingIDs(), [id])
        let entry = try reopened.load(id: id)
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.manifest, manifest)
        let receipt = try phone.acceptIncomingFile(at: entry.audioURL, manifest: entry.manifest)
        try reopened.complete(id: id, receipt: receipt)
        XCTAssertEqual(try inbox().pendingIDs(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.audioURL.path))
        XCTAssertEqual(try phone.verifiedReceipt(for: manifest.id), receipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))
        try watch.acknowledge(receipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))
        XCTAssertEqual(try RecordingRepository.fingerprint(of: phone.audioURL(for: manifest)).sha256,
                       manifest.sha256)
    }

    func testDuplicateCallbacksKeepIndependentCopiesUntilEachIsCommitted() throws {
        let watch = try repository("watch")
        let phone = try repository("phone")
        let manifest = try seal(watch)
        let store = try inbox()
        let firstID = try store.stage(fileURL: watch.audioURL(for: manifest), manifest: manifest)
        let secondID = try store.stage(fileURL: watch.audioURL(for: manifest), manifest: manifest)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(try store.pendingIDs(), [firstID, secondID].sorted { $0.uuidString < $1.uuidString })
        let first = try store.load(id: firstID)
        let second = try store.load(id: secondID)
        XCTAssertNotEqual(first.audioURL, second.audioURL)
        let receipt = try phone.acceptIncomingFile(at: first.audioURL, manifest: first.manifest)
        try store.complete(id: firstID, receipt: receipt)
        XCTAssertEqual(try store.pendingIDs(), [secondID])
        XCTAssertEqual(try RecordingRepository.fingerprint(of: second.audioURL).sha256, manifest.sha256)
        XCTAssertEqual(try phone.acceptIncomingFile(at: second.audioURL, manifest: second.manifest), receipt)
        try store.complete(id: secondID, receipt: receipt)
        try store.complete(id: secondID, receipt: receipt)
        XCTAssertEqual(try store.pendingIDs(), [])
        XCTAssertEqual(try phone.manifests(), [manifest])
    }

    func testStagingDoesNotHashOrDecodeAudioAndImportRejectsCorruptionWithoutAcknowledgement() throws {
        let watch = try repository("watch")
        let phone = try repository("phone")
        let manifest = try seal(watch)
        let corrupt = directory.appendingPathComponent("corrupt.caf")
        try Data("not audio".utf8).write(to: corrupt)
        let store = try inbox()
        let id = try store.stage(fileURL: corrupt, manifest: manifest)
        try FileManager.default.removeItem(at: corrupt)
        let entry = try inbox().load(id: id)
        XCTAssertThrowsError(try phone.acceptIncomingFile(at: entry.audioURL, manifest: entry.manifest)) {
            XCTAssertEqual($0 as? RepositoryError, .checksumMismatch)
        }
        XCTAssertEqual(try phone.receipts(), [])
        XCTAssertEqual(try store.pendingIDs(), [id])
        XCTAssertEqual(try Data(contentsOf: entry.audioURL), Data("not audio".utf8))
        XCTAssertEqual(try watch.pendingSegments(), [manifest])
    }

    func testFailedStagingBeforeMetadataPreservesCopyWithoutCreatingPendingJob() throws {
        let watch = try repository("watch")
        let manifest = try seal(watch)
        for (name, point) in [("copy-failure", IncomingTransferInboxFaultPoint.afterAudioCopyBeforeSync),
                              ("metadata-failure", .afterAudioSyncBeforeManifest)] {
            let store = try inbox(name, fault: { current in
                switch (current, point) {
                case (.afterAudioCopyBeforeSync, .afterAudioCopyBeforeSync),
                     (.afterAudioSyncBeforeManifest, .afterAudioSyncBeforeManifest):
                    throw SimulatedFailure()
                default: break
                }
            })
            XCTAssertThrowsError(try store.stage(fileURL: watch.audioURL(for: manifest), manifest: manifest))
            let reopened = try inbox(name)
            XCTAssertEqual(try reopened.pendingIDs(), [])
            let retained = try FileManager.default.contentsOfDirectory(at: reopened.root, includingPropertiesForKeys: nil)
            XCTAssertEqual(retained.count, 1)
            let audio = try XCTUnwrap(retained.first).appendingPathComponent("audio.caf")
            XCTAssertEqual(try RecordingRepository.fingerprint(of: audio).sha256, manifest.sha256)
            XCTAssertFalse(FileManager.default.fileExists(atPath:
                try XCTUnwrap(retained.first).appendingPathComponent("manifest.json").path))
        }
        XCTAssertEqual(try watch.pendingSegments(), [manifest])
    }

    func testVisibleManifestAfterFailedSyncCanRecoverThroughFullRepositoryImport() throws {
        let watch = try repository("watch")
        let phone = try repository("phone")
        let manifest = try seal(watch)
        let store = try inbox(fault: {
            if case .afterManifestWriteBeforeSync = $0 { throw SimulatedFailure() }
        })
        XCTAssertThrowsError(try store.stage(fileURL: watch.audioURL(for: manifest), manifest: manifest))
        XCTAssertEqual(try phone.receipts(), [])
        let reopened = try inbox()
        let id = try XCTUnwrap(reopened.pendingIDs().first)
        let entry = try reopened.load(id: id)
        let receipt = try phone.acceptIncomingFile(at: entry.audioURL, manifest: entry.manifest)
        try reopened.complete(id: id, receipt: receipt)
        XCTAssertEqual(try reopened.pendingIDs(), [])
        XCTAssertEqual(try phone.verifiedReceipt(for: manifest.id), receipt)
    }

    func testCorruptJobDoesNotPreventLoadingAndImportingAnotherCandidate() throws {
        let watch = try repository("watch")
        let phone = try repository("phone")
        let manifest = try seal(watch)
        let store = try inbox()
        let corruptID = try store.stage(fileURL: watch.audioURL(for: manifest), manifest: manifest)
        let goodID = try store.stage(fileURL: watch.audioURL(for: manifest), manifest: manifest)
        try Data("broken metadata".utf8).write(to:
            transferDirectory(store, id: corruptID).appendingPathComponent("manifest.json"))
        var failed: [UUID] = []
        var completed: [UUID] = []
        for id in try store.pendingIDs() {
            do {
                let entry = try store.load(id: id)
                let receipt = try phone.acceptIncomingFile(at: entry.audioURL, manifest: entry.manifest)
                try store.complete(id: id, receipt: receipt)
                completed.append(id)
            } catch { failed.append(id) }
        }
        XCTAssertEqual(failed, [corruptID])
        XCTAssertEqual(completed, [goodID])
        XCTAssertEqual(try store.pendingIDs(), [corruptID])
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            transferDirectory(store, id: corruptID).appendingPathComponent("audio.caf").path))
    }

    func testMismatchedReceiptCannotDeleteInboxCopy() throws {
        let watch = try repository("watch")
        let manifest = try seal(watch)
        let store = try inbox()
        let id = try store.stage(fileURL: watch.audioURL(for: manifest), manifest: manifest)
        let entry = try store.load(id: id)
        let mismatches = [
            SegmentReceipt(segmentID: UUID(), sha256: manifest.sha256, byteCount: manifest.byteCount),
            SegmentReceipt(segmentID: manifest.id, sha256: String(repeating: "0", count: 64),
                           byteCount: manifest.byteCount),
            SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount + 1)
        ]
        for receipt in mismatches {
            XCTAssertThrowsError(try store.complete(id: id, receipt: receipt)) {
                XCTAssertEqual($0 as? RepositoryError, .receiptMismatch)
            }
            XCTAssertEqual(try store.pendingIDs(), [id])
            XCTAssertEqual(try RecordingRepository.fingerprint(of: entry.audioURL).sha256, manifest.sha256)
        }
    }

    func testInterruptedCompletionLeavesRecoverableCopyOutsidePendingWork() throws {
        let watch = try repository("watch")
        let phone = try repository("phone")
        let manifest = try seal(watch)
        let store = try inbox(fault: {
            if case .afterCompletionRenameBeforeSync = $0 { throw SimulatedFailure() }
        })
        let id = try store.stage(fileURL: watch.audioURL(for: manifest), manifest: manifest)
        let entry = try store.load(id: id)
        let receipt = try phone.acceptIncomingFile(at: entry.audioURL, manifest: entry.manifest)
        XCTAssertThrowsError(try store.complete(id: id, receipt: receipt))
        let reopened = try inbox()
        XCTAssertEqual(try reopened.pendingIDs(), [])
        let completed = reopened.root.appendingPathComponent("completed-" + id.uuidString.lowercased())
        XCTAssertEqual(try RecordingRepository.fingerprint(of: completed.appendingPathComponent("audio.caf")).sha256,
                       manifest.sha256)
        XCTAssertEqual(try phone.verifiedReceipt(for: manifest.id), receipt)
        try reopened.complete(id: id, receipt: receipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
    }

    func testSymbolicLinkSourceCannotMasqueradeAsAPrivateCopy() throws {
        let watch = try repository("watch")
        let manifest = try seal(watch)
        let link = directory.appendingPathComponent("framework-symlink.caf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: watch.audioURL(for: manifest))
        let store = try inbox()
        XCTAssertThrowsError(try store.stage(fileURL: link, manifest: manifest))
        XCTAssertEqual(try store.pendingIDs(), [])
    }

    func testMissingInboxDirectoryIsNotReportedAsEmpty() throws {
        let store = try inbox()
        try FileManager.default.removeItem(at: store.root)
        XCTAssertThrowsError(try store.pendingIDs())
    }

    private struct SimulatedFailure: Error {}
}
