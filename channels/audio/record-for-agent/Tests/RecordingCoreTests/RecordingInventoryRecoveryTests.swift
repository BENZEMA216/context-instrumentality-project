import Foundation
import XCTest
@testable import RecordingCore

final class RecordingInventoryRecoveryTests: XCTestCase {
    private var directory: URL!
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func file(_ name: String, in directoryName: String, root: URL) -> URL {
        root.appendingPathComponent(directoryName).appendingPathComponent(name)
    }

    private func pendingURL(_ manifest: SegmentManifest, root: URL) -> URL {
        file(manifest.id.uuidString.lowercased() + ".pending.json", in: "staging", root: root)
    }

    private func makePending(in repository: RecordingRepository, id: UUID = UUID(),
                             sessionID: UUID = UUID(), sourceDirectory: String = "staging",
                             payload: Data = Data(repeating: 42, count: 8_192)) throws -> SegmentManifest {
        let source = file(id.uuidString.lowercased() + ".caf", in: sourceDirectory, root: repository.root)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try payload.write(to: source)
        let fingerprint = try RecordingRepository.fingerprint(of: source)
        let manifest = SegmentManifest(id: id, sessionID: sessionID, sequence: 0,
            startedAt: instant, endedAt: instant.addingTimeInterval(1),
            sampleRate: 16_000, frameCount: 16_000,
            fileName: id.uuidString.lowercased() + ".caf",
            byteCount: fingerprint.byteCount, sha256: fingerprint.sha256)
        try TransportCodec.encode(manifest).write(to: pendingURL(manifest, root: repository.root))
        return manifest
    }

    private func seal(in repository: RecordingRepository, sessionID: UUID = UUID()) throws -> SegmentManifest {
        let id = UUID()
        try Data(repeating: 42, count: 8_192).write(to: repository.stagingURL(for: id))
        return try repository.sealSegment(stagedURL: repository.stagingURL(for: id),
            id: id, sessionID: sessionID, sequence: 0,
            startedAt: instant, endedAt: instant.addingTimeInterval(1),
            sampleRate: 16_000, frameCount: 16_000)
    }

    func testPreserveModeRecoversHealthyTransactionBesideCorruptPendingWithoutDeletingIt() throws {
        let root = directory.appendingPathComponent("watch")
        let repository = try RecordingRepository(root: root)
        let good = try makePending(in: repository)
        let corrupt = file(UUID().uuidString.lowercased() + ".pending.json", in: "staging", root: root)
        let damagedBytes = Data("not-json".utf8)
        try damagedBytes.write(to: corrupt)

        XCTAssertThrowsError(try RecordingRepository(root: root))
        let reopened = try RecordingRepository(root: root, recoveryFailureHandling: .preserveAndReport)
        XCTAssertEqual(try reopened.manifests(), [good])
        XCTAssertEqual(try reopened.pendingSegments(), [good])
        XCTAssertEqual(try Data(contentsOf: corrupt), damagedBytes)
        let inventory = try reopened.recordingInventory()
        XCTAssertTrue(inventory.issues.contains { $0.fileName == "staging/" + corrupt.lastPathComponent })
        let newSession = try reopened.createSession()
        _ = try seal(in: reopened, sessionID: newSession.id)
        XCTAssertEqual(try reopened.manifests().count, 2)
    }

    func testMissingAudioCanBeRetriedWithoutRestartAndClearsItsIssue() throws {
        let root = directory.appendingPathComponent("watch")
        let repository = try RecordingRepository(root: root)
        let bytes = Data(repeating: 13, count: 4_096)
        let manifest = try makePending(in: repository, payload: bytes)
        try FileManager.default.removeItem(at: repository.stagingURL(for: manifest.id))

        let reopened = try RecordingRepository(root: root, recoveryFailureHandling: .preserveAndReport)
        XCTAssertTrue(try reopened.manifests().isEmpty)
        XCTAssertFalse(try reopened.recordingInventory().issues.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL(manifest, root: root).path))
        try bytes.write(to: reopened.stagingURL(for: manifest.id))
        try reopened.recoverPendingTransactions()
        XCTAssertEqual(try reopened.manifests(), [manifest])
        XCTAssertTrue(try reopened.recordingInventory().issues.isEmpty)
        try reopened.recoverPendingTransactions()
        XCTAssertEqual(try reopened.manifests(), [manifest])
    }

    func testInventorySeparatesInvalidItemsWhileStrictReadersStillFail() throws {
        let repository = try RecordingRepository(root: directory.appendingPathComponent("watch"))
        let session = try repository.createSession(at: instant)
        let manifest = try seal(in: repository, sessionID: session.id)
        let badSession = file(UUID().uuidString.lowercased() + ".json", in: "sessions", root: repository.root)
        let badManifest = file(UUID().uuidString.lowercased() + ".json", in: "manifests", root: repository.root)
        let misplacedManifest = file(UUID().uuidString.lowercased() + ".json", in: "manifests", root: repository.root)
        try Data("broken-session".utf8).write(to: badSession)
        try Data("broken-manifest".utf8).write(to: badManifest)
        try TransportCodec.encode(manifest).write(to: misplacedManifest)

        let inventory = try repository.recordingInventory()
        XCTAssertEqual(inventory.sessions, [session])
        XCTAssertEqual(inventory.manifests, [manifest])
        XCTAssertEqual(inventory.issues.count, 3)
        XCTAssertTrue(inventory.issues.allSatisfy { !$0.reason.isEmpty && $0.reason.count <= 160 })
        XCTAssertThrowsError(try repository.sessions())
        XCTAssertThrowsError(try repository.manifests())
        XCTAssertEqual(try Data(contentsOf: badSession), Data("broken-session".utf8))
        XCTAssertEqual(try Data(contentsOf: badManifest), Data("broken-manifest".utf8))
    }

    func testUnreadableLibraryDirectoryIsNotReportedAsEmptyInventory() throws {
        let root = directory.appendingPathComponent("watch")
        let repository = try RecordingRepository(root: root)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.removeItem(at: sessions)
        try Data("directory-replaced-by-file".utf8).write(to: sessions)
        XCTAssertThrowsError(try repository.recordingInventory())
        XCTAssertThrowsError(try RecordingRepository(root: root, recoveryFailureHandling: .preserveAndReport))
    }

    func testInventoryAcceptsValidFilesEnumeratedThroughDirectoryAlias() throws {
        let physicalRoot = directory.appendingPathComponent("physical-watch")
        let aliasedRoot = directory.appendingPathComponent("watch-alias")
        try FileManager.default.createDirectory(at: physicalRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasedRoot, withDestinationURL: physicalRoot)
        let repository = try RecordingRepository(root: aliasedRoot)
        let session = try repository.createSession(at: instant)
        let manifest = try seal(in: repository, sessionID: session.id)

        let inventory = try repository.recordingInventory()
        XCTAssertEqual(inventory.sessions, [session])
        XCTAssertEqual(inventory.manifests, [manifest])
        XCTAssertTrue(inventory.issues.isEmpty)
        let reopened = try RecordingRepository(root: aliasedRoot)
        XCTAssertEqual(try reopened.recordingInventory().sessions, [session])
        XCTAssertEqual(try reopened.recordingInventory().manifests, [manifest])
        XCTAssertTrue(try reopened.recordingInventory().issues.isEmpty)
    }

    func testCandidateRecoveryPreservesDifferentOriginalBeforeAndAfterAudioMove() throws {
        for alreadyMoved in [false, true] {
            let root = directory.appendingPathComponent(alreadyMoved ? "moved" : "unmoved")
            let repository = try RecordingRepository(root: root)
            let recoveredBytes = Data(repeating: 7, count: 4_096)
            let originalBytes = Data(repeating: 9, count: 8_192)
            let manifest = try makePending(in: repository, sourceDirectory: "recovery-staging", payload: recoveredBytes)
            let candidate = file(manifest.fileName, in: "recovery-staging", root: root)
            try originalBytes.write(to: repository.stagingURL(for: manifest.id))
            if alreadyMoved { try FileManager.default.moveItem(at: candidate, to: repository.audioURL(for: manifest)) }

            let reopened = try RecordingRepository(root: root, recoveryFailureHandling: .preserveAndReport)
            XCTAssertEqual(try reopened.manifests(), [manifest])
            XCTAssertEqual(try Data(contentsOf: reopened.audioURL(for: manifest)), recoveredBytes)
            XCTAssertEqual(try Data(contentsOf: reopened.stagingURL(for: manifest.id)), originalBytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL(manifest, root: root).path))
            XCTAssertTrue(try reopened.recordingInventory().issues.contains { $0.fileName == "staging/" + manifest.fileName })
        }
    }

    func testMatchingOriginalDoesNotDeleteDifferentRecoveryCandidate() throws {
        let root = directory.appendingPathComponent("watch")
        let repository = try RecordingRepository(root: root)
        let manifest = try makePending(in: repository)
        let candidate = file(manifest.fileName, in: "recovery-staging", root: root)
        try FileManager.default.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
        let differentBytes = Data(repeating: 22, count: 1_024)
        try differentBytes.write(to: candidate)

        let reopened = try RecordingRepository(root: root, recoveryFailureHandling: .preserveAndReport)
        XCTAssertEqual(try reopened.manifests(), [manifest])
        XCTAssertEqual(try Data(contentsOf: candidate), differentBytes)
        XCTAssertTrue(try reopened.recordingInventory().issues.contains { $0.fileName == "recovery-staging/" + manifest.fileName })
    }

    func testNoMatchingSourcePreservesBothSourcesAndPendingTransaction() throws {
        let root = directory.appendingPathComponent("watch")
        let repository = try RecordingRepository(root: root)
        let manifest = try makePending(in: repository, sourceDirectory: "recovery-staging")
        let candidate = file(manifest.fileName, in: "recovery-staging", root: root)
        let brokenCandidate = Data(repeating: 4, count: 512), original = Data(repeating: 6, count: 256)
        try brokenCandidate.write(to: candidate)
        try original.write(to: repository.stagingURL(for: manifest.id))

        let reopened = try RecordingRepository(root: root, recoveryFailureHandling: .preserveAndReport)
        XCTAssertTrue(try reopened.manifests().isEmpty)
        XCTAssertEqual(try Data(contentsOf: candidate), brokenCandidate)
        XCTAssertEqual(try Data(contentsOf: reopened.stagingURL(for: manifest.id)), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL(manifest, root: root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.audioURL(for: manifest).path))
        XCTAssertEqual(try reopened.recordingInventory().issues.count, 3)
    }

    func testConflictingCommittedManifestDoesNotMoveRecoveryCandidate() throws {
        let root = directory.appendingPathComponent("watch")
        let repository = try RecordingRepository(root: root)
        let existing = try seal(in: repository)
        let candidateManifest = try makePending(in: repository, id: existing.id,
            sessionID: existing.sessionID, sourceDirectory: "recovery-staging", payload: Data(repeating: 5, count: 512))
        let candidate = file(candidateManifest.fileName, in: "recovery-staging", root: root)

        let reopened = try RecordingRepository(root: root, recoveryFailureHandling: .preserveAndReport)
        XCTAssertEqual(try reopened.manifests(), [existing])
        XCTAssertEqual(try Data(contentsOf: reopened.audioURL(for: existing)), Data(repeating: 42, count: 8_192))
        XCTAssertEqual(try Data(contentsOf: candidate), Data(repeating: 5, count: 512))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL(candidateManifest, root: root).path))
        XCTAssertFalse(try reopened.recordingInventory().issues.isEmpty)
    }

    func testReadOnlyScansDoNotWaitForAcknowledgementMutationLock() throws {
        let mutationEntered = expectation(description: "ACK holds repository mutation lock")
        let mutationFinished = expectation(description: "ACK completed")
        let readsFinished = expectation(description: "history and pending scans completed independently")
        let releaseMutation = DispatchSemaphore(value: 0)
        let repository = try RecordingRepository(root: directory.appendingPathComponent("watch"), faultInjector: {
            if case .beforeAcknowledgementCommit = $0 {
                mutationEntered.fulfill()
                _ = releaseMutation.wait(timeout: .now() + 5)
            }
        })
        let manifest = try seal(in: repository)
        let event = RecordingEvent(kind: "fixture", detail: "read-only scan")
        try repository.appendEvent(event)
        DispatchQueue.global().async {
            defer { mutationFinished.fulfill() }
            do {
                try repository.acknowledge(SegmentReceipt(segmentID: manifest.id,
                    sha256: manifest.sha256, byteCount: manifest.byteCount))
            } catch { XCTFail("ACK failed: \(error)") }
        }
        wait(for: [mutationEntered], timeout: 2)
        DispatchQueue.global().async {
            defer { readsFinished.fulfill() }
            do {
                let manifests = try repository.manifests()
                let events = try repository.events()
                let pending = try repository.pendingSegments()
                XCTAssertEqual(manifests, [manifest])
                XCTAssertEqual(events, [event])
                XCTAssertEqual(pending, [manifest])
            } catch { XCTFail("Read-only scan failed: \(error)") }
        }
        wait(for: [readsFinished], timeout: 2)
        releaseMutation.signal()
        wait(for: [mutationFinished], timeout: 2)
        XCTAssertTrue(try repository.pendingSegments().isEmpty)
    }

    func testMismatchedAcknowledgementCannotHideMissingAudio() throws {
        let repository = try RecordingRepository(root: directory.appendingPathComponent("watch"))
        let manifest = try seal(in: repository)
        try FileManager.default.removeItem(at: repository.audioURL(for: manifest))
        let acknowledgement = SegmentReceipt(segmentID: manifest.id,
            sha256: String(repeating: "0", count: 64), byteCount: manifest.byteCount)
        let acknowledgementURL = file(manifest.id.uuidString.lowercased() + ".json",
            in: "acknowledgements", root: repository.root)
        try TransportCodec.encode(acknowledgement).write(to: acknowledgementURL)
        XCTAssertThrowsError(try repository.pendingSegments()) {
            XCTAssertEqual($0 as? RepositoryError, .receiptMismatch)
        }
        XCTAssertThrowsError(try repository.hasDurableAcknowledgement(for: manifest)) {
            XCTAssertEqual($0 as? RepositoryError, .receiptMismatch)
        }
    }

    func testAcknowledgedPrunedTransactionOnlyClearsPendingAndPreservesDifferentResidue() throws {
        let root = directory.appendingPathComponent("watch")
        let repository = try RecordingRepository(root: root)
        let manifest = try seal(in: repository)
        try repository.acknowledge(SegmentReceipt(segmentID: manifest.id,
            sha256: manifest.sha256, byteCount: manifest.byteCount))
        try TransportCodec.encode(manifest).write(to: pendingURL(manifest, root: root))
        let original = repository.stagingURL(for: manifest.id)
        let candidate = file(manifest.fileName, in: "recovery-staging", root: root)
        try FileManager.default.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalBytes = Data(repeating: 99, count: 64), candidateBytes = Data(repeating: 88, count: 32)
        try originalBytes.write(to: original)
        try candidateBytes.write(to: candidate)

        let reopened = try RecordingRepository(root: root)
        XCTAssertEqual(try reopened.manifests(), [manifest])
        XCTAssertTrue(try reopened.hasDurableAcknowledgement(for: manifest))
        XCTAssertTrue(try reopened.pendingSegments().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.audioURL(for: manifest).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL(manifest, root: root).path))
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(try Data(contentsOf: candidate), candidateBytes)
        XCTAssertEqual(try reopened.recordingInventory().issues.count, 2)
    }

    func testInvalidAcknowledgementCannotFinishPrunedPendingTransaction() throws {
        let root = directory.appendingPathComponent("watch")
        let repository = try RecordingRepository(root: root)
        let manifest = try seal(in: repository)
        try TransportCodec.encode(manifest).write(to: pendingURL(manifest, root: root))
        try FileManager.default.removeItem(at: repository.audioURL(for: manifest))
        let acknowledgement = SegmentReceipt(segmentID: manifest.id,
            sha256: String(repeating: "0", count: 64), byteCount: manifest.byteCount)
        let acknowledgementURL = file(manifest.id.uuidString.lowercased() + ".json", in: "acknowledgements", root: root)
        try TransportCodec.encode(acknowledgement).write(to: acknowledgementURL)

        XCTAssertThrowsError(try RecordingRepository(root: root)) {
            XCTAssertEqual($0 as? RepositoryError, .receiptMismatch)
        }
        let reopened = try RecordingRepository(root: root, recoveryFailureHandling: .preserveAndReport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL(manifest, root: root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.audioURL(for: manifest).path))
        XCTAssertFalse(try reopened.recordingInventory().issues.isEmpty)
    }
}
