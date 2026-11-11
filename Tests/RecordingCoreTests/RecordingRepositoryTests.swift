import XCTest
@testable import RecordingCore

final class RecordingRepositoryTests: XCTestCase {
    private var directory: URL!
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func repository(_ name: String = "watch",
                            fault: ((RepositoryFaultPoint) throws -> Void)? = nil) throws -> RecordingRepository {
        try RecordingRepository(root: directory.appendingPathComponent(name), faultInjector: fault)
    }

    private func seal(_ repository: RecordingRepository, id: UUID = UUID(),
                      sessionID: UUID = UUID(), payload: Data = Data(repeating: 42, count: 8_192)) throws -> SegmentManifest {
        let staging = repository.stagingURL(for: id)
        try payload.write(to: staging)
        return try repository.sealSegment(stagedURL: staging, id: id, sessionID: sessionID,
            sequence: 0, startedAt: instant, endedAt: instant.addingTimeInterval(60),
            sampleRate: 16_000, frameCount: 960_000)
    }

    func testFingerprintMatchesKnownDigestsAcrossReadBoundaries() throws {
        // Independent SHA-256 vectors for ASCII "a", including EOF on a chunk boundary.
        let vectors: [(Int, String)] = [
            (0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            (262_143, "0379854ae435b4c82999632f674694ce1f98103f645f44ba68c901a83a2b00fd"),
            (262_144, "dd3dde87623d9a6b354c68c943d189c89c63652d945e7bbdf0986cae91a49521"),
            (262_145, "c592f4a6b099700b5050ce8bc67367f0c8f44810203124e86405c3e7b6f1a2ba"),
            (1_048_593, "c26032d5154f96bd29c799447d715ab681d8d0aa308ecc6f321a35d98f0672da")
        ]
        let file = directory.appendingPathComponent("fingerprint-fixture.bin")
        for (count, digest) in vectors {
            try Data(repeating: 0x61, count: count).write(to: file)
            let result = try RecordingRepository.fingerprint(of: file)
            XCTAssertEqual(result.byteCount, Int64(count))
            XCTAssertEqual(result.sha256, digest, "payload bytes: \(count)")
        }
    }

    func testFingerprintWithdrawalBeforeFirstReadIsCancellation() throws {
        let file = directory.appendingPathComponent("fingerprint-withdrawn.bin")
        let original = Data(repeating: 0x61, count: 262_145)
        try original.write(to: file)
        var checks = 0

        XCTAssertThrowsError(try RecordingRepository.fingerprint(of: file, while: {
            checks += 1
            return false
        })) { error in
            XCTAssertTrue(error is CancellationError, "A revoked maintenance grant was reported as a storage failure")
        }
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testFingerprintWithdrawalAfterOneChunkPreservesSourceAndCanResume() throws {
        let file = directory.appendingPathComponent("fingerprint-interrupted.bin")
        let original = Data(repeating: 0x61, count: 262_145)
        try original.write(to: file)
        var checks = 0

        XCTAssertThrowsError(try RecordingRepository.fingerprint(of: file, while: {
            checks += 1
            return checks == 1
        })) { error in
            XCTAssertTrue(error is CancellationError, "An interrupted read returned a storage failure or partial digest")
        }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let result = try RecordingRepository.fingerprint(of: file)
        XCTAssertEqual(result.byteCount, 262_145)
        XCTAssertEqual(result.sha256, "c592f4a6b099700b5050ce8bc67367f0c8f44810203124e86405c3e7b6f1a2ba")
    }

    func testFingerprintRealOpenAndReadFailuresRemainIOErrors() throws {
        let missing = directory.appendingPathComponent("fingerprint-missing.bin")
        let unreadable = directory.appendingPathComponent("fingerprint-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)

        for file in [missing, unreadable] {
            XCTAssertThrowsError(try RecordingRepository.fingerprint(of: file, while: { true })) { error in
                XCTAssertFalse(error is CancellationError, "A real file I/O error was hidden as cancellation")
                XCTAssertTrue([NSCocoaErrorDomain, NSPOSIXErrorDomain].contains((error as NSError).domain),
                              "The original file I/O error was replaced")
            }
        }
    }

    func testSealedFileSurvivesRepositoryRestartAndIsPending() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let reopened = try repository()
        XCTAssertEqual(try reopened.pendingSegments(), [manifest])
        XCTAssertEqual(try Data(contentsOf: reopened.audioURL(for: manifest)).count, 8_192)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.stagingURL(for: manifest.id).path))
    }

    func testTransferCompletionWithoutReceiptCannotPruneAudio() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let phone = try repository("phone")
        _ = try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        XCTAssertEqual(try watch.pendingSegments().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))
        XCTAssertFalse(try watch.hasDurableAcknowledgement(for: manifest))
        XCTAssertFalse(try phone.hasDurableAcknowledgement(for: manifest))
    }

    func testDurableReceiptAllowsCleanupAndKeepsManifest() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let phone = try repository("phone")
        let receipt = try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        try watch.acknowledge(receipt)
        XCTAssertEqual(try watch.pendingSegments(), [])
        XCTAssertEqual(try watch.manifests(), [manifest])
        XCTAssertFalse(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))
        let reopenedWatch = try repository()
        XCTAssertTrue(try reopenedWatch.hasDurableAcknowledgement(for: manifest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopenedWatch.audioURL(for: manifest).path))
        let reopened = try repository("phone")
        XCTAssertEqual(try reopened.receipts(), [receipt])
        XCTAssertEqual(try Data(contentsOf: reopened.audioURL(for: manifest)).count, 8_192)
    }

    func testDurableAcknowledgementRequiresAckEvenWhenAudioIsMissing() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        XCTAssertFalse(try watch.hasDurableAcknowledgement(for: manifest))
        XCTAssertFalse(try repository("empty").hasDurableAcknowledgement(for: manifest))
        try FileManager.default.removeItem(at: watch.audioURL(for: manifest))
        XCTAssertFalse(try watch.hasDurableAcknowledgement(for: manifest))
        XCTAssertFalse(try repository().hasDurableAcknowledgement(for: manifest))
    }

    func testDurableAcknowledgementRejectsSameIDWithDifferentMetadata() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let receipt = try repository("phone").acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        try watch.acknowledge(receipt)
        let conflicting = SegmentManifest(id: manifest.id, sessionID: UUID(), sequence: manifest.sequence,
            startedAt: manifest.startedAt, endedAt: manifest.endedAt, sampleRate: manifest.sampleRate,
            frameCount: manifest.frameCount, fileName: manifest.fileName,
            byteCount: manifest.byteCount, sha256: manifest.sha256)
        XCTAssertThrowsError(try watch.hasDurableAcknowledgement(for: conflicting)) {
            XCTAssertEqual($0 as? RepositoryError, .conflictingSegment)
        }
        XCTAssertTrue(try watch.hasDurableAcknowledgement(for: manifest))
    }

    func testDurableAcknowledgementRejectsCorruptAcknowledgement() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let receipt = try repository("phone").acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        try watch.acknowledge(receipt)
        let acknowledgementURL = watch.root.appendingPathComponent("acknowledgements")
            .appendingPathComponent(manifest.id.uuidString.lowercased() + ".json")
        try Data("not JSON".utf8).write(to: acknowledgementURL)
        XCTAssertThrowsError(try watch.hasDurableAcknowledgement(for: manifest))
        XCTAssertThrowsError(try repository().hasDurableAcknowledgement(for: manifest))
    }

    func testDurableAcknowledgementRejectsMismatchedAcknowledgement() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let receipt = try repository("phone").acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        try watch.acknowledge(receipt)
        let acknowledgementURL = watch.root.appendingPathComponent("acknowledgements")
            .appendingPathComponent(manifest.id.uuidString.lowercased() + ".json")
        let mismatches = [
            SegmentReceipt(segmentID: manifest.id, sha256: String(repeating: "0", count: 64),
                byteCount: manifest.byteCount),
            SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount + 1),
            SegmentReceipt(segmentID: UUID(), sha256: manifest.sha256, byteCount: manifest.byteCount)
        ]
        for mismatch in mismatches {
            try TransportCodec.encode(mismatch).write(to: acknowledgementURL)
            XCTAssertThrowsError(try watch.hasDurableAcknowledgement(for: manifest)) {
                XCTAssertEqual($0 as? RepositoryError, .receiptMismatch)
            }
        }
    }

    func testDurableAcknowledgementRequiresValidLocalManifest() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let receipt = try repository("phone").acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        try watch.acknowledge(receipt)
        let manifestURL = watch.root.appendingPathComponent("manifests")
            .appendingPathComponent(manifest.id.uuidString.lowercased() + ".json")
        try FileManager.default.removeItem(at: manifestURL)
        XCTAssertThrowsError(try watch.hasDurableAcknowledgement(for: manifest))
        try Data("not JSON".utf8).write(to: manifestURL)
        XCTAssertThrowsError(try watch.hasDurableAcknowledgement(for: manifest))
        let invalid = SegmentManifest(id: manifest.id, sessionID: manifest.sessionID, sequence: manifest.sequence,
            startedAt: manifest.startedAt, endedAt: manifest.endedAt, sampleRate: manifest.sampleRate,
            frameCount: manifest.frameCount, fileName: manifest.fileName,
            byteCount: manifest.byteCount, sha256: manifest.sha256, schemaVersion: 2)
        try TransportCodec.encode(invalid).write(to: manifestURL)
        XCTAssertThrowsError(try watch.hasDurableAcknowledgement(for: manifest)) {
            XCTAssertEqual($0 as? RepositoryError, .invalidManifest("不支持的版本"))
        }
    }

    func testVisibleAcknowledgementCannotAuthorizeCancellationUntilSynchronized() throws {
        let watch = try repository(fault: { if case .beforeAcknowledgementSync = $0 { throw SimulatedCrash() } })
        let manifest = try seal(watch)
        let receipt = try repository("phone").acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        XCTAssertThrowsError(try watch.acknowledge(receipt))
        let acknowledgementURL = watch.root.appendingPathComponent("acknowledgements")
            .appendingPathComponent(manifest.id.uuidString.lowercased() + ".json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: acknowledgementURL.path))
        XCTAssertThrowsError(try watch.hasDurableAcknowledgement(for: manifest)) {
            XCTAssertTrue($0 is SimulatedCrash)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))

        let reopened = try repository()
        XCTAssertTrue(try reopened.hasDurableAcknowledgement(for: manifest))
        // The query establishes ACK durability but never prunes retained audio.
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: manifest).path))
    }

    func testLostReceiptAndDuplicateTransferReturnSameReceipt() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let first = try repository("phone").acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        let restarted = try repository("phone")
        let second = try restarted.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try restarted.manifests().count, 1)
        XCTAssertEqual(try restarted.receipts().count, 1)
    }

    func testDuplicateAcknowledgementIsIdempotent() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let receipt = try repository("phone").acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        try watch.acknowledge(receipt)
        try watch.acknowledge(receipt)
        XCTAssertEqual(try repository().pendingSegments().count, 0)
        XCTAssertEqual(try repository().manifests().count, 1)
    }

    func testWrongChecksumAcknowledgementDoesNotDeleteAudio() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let bad = SegmentReceipt(segmentID: manifest.id, sha256: String(repeating: "0", count: 64), byteCount: manifest.byteCount)
        XCTAssertThrowsError(try watch.acknowledge(bad)) { XCTAssertEqual($0 as? RepositoryError, .receiptMismatch) }
        XCTAssertEqual(try watch.pendingSegments().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.audioURL(for: manifest).path))
    }

    func testWrongLengthAcknowledgementDoesNotDeleteAudio() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let bad = SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: 1)
        XCTAssertThrowsError(try watch.acknowledge(bad))
        XCTAssertEqual(try watch.pendingSegments().count, 1)
    }

    func testCorruptedTransferGetsNoReceipt() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let corrupt = directory.appendingPathComponent("bad.caf")
        try Data(repeating: 7, count: 8_192).write(to: corrupt)
        let phone = try repository("phone")
        XCTAssertThrowsError(try phone.acceptIncomingFile(at: corrupt, manifest: manifest)) {
            XCTAssertEqual($0 as? RepositoryError, .checksumMismatch)
        }
        XCTAssertEqual(try phone.receipts().count, 0)
        XCTAssertEqual(try phone.manifests().count, 0)
    }

    func testTruncatedTransferGetsNoReceipt() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let truncated = directory.appendingPathComponent("short.caf")
        try Data(repeating: 42, count: 100).write(to: truncated)
        let phone = try repository("phone")
        XCTAssertThrowsError(try phone.acceptIncomingFile(at: truncated, manifest: manifest))
        XCTAssertEqual(try phone.receipts().count, 0)
    }

    func testSameIdentityDifferentContentCannotOverwriteCommittedSegment() throws {
        let watch = try repository()
        let original = try seal(watch)
        let phone = try repository("phone")
        _ = try phone.acceptIncomingFile(at: watch.audioURL(for: original), manifest: original)
        let otherWatch = try repository("other-watch")
        let conflicting = try seal(otherWatch, id: original.id, sessionID: original.sessionID,
                                   payload: Data(repeating: 9, count: 8_192))
        XCTAssertThrowsError(try phone.acceptIncomingFile(at: otherWatch.audioURL(for: conflicting), manifest: conflicting)) {
            XCTAssertEqual($0 as? RepositoryError, .conflictingSegment)
        }
        XCTAssertEqual(try phone.manifests(), [original])
        XCTAssertEqual(try Data(contentsOf: phone.audioURL(for: original)).first, 42)
    }

    func testPathTraversalManifestIsRejected() throws {
        let watch = try repository()
        let m = try seal(watch)
        let invalid = SegmentManifest(id: m.id, sessionID: m.sessionID, sequence: m.sequence,
            startedAt: m.startedAt, endedAt: m.endedAt, sampleRate: m.sampleRate, frameCount: m.frameCount,
            fileName: "../../escape.caf", byteCount: m.byteCount, sha256: m.sha256)
        XCTAssertThrowsError(try repository("phone").acceptIncomingFile(at: watch.audioURL(for: m), manifest: invalid))
    }

    func testCrashAfterAudioRenameRecoversSealedSegment() throws {
        let id = UUID()
        let broken = try repository(fault: { if case .afterAudioCommit = $0 { throw SimulatedCrash() } })
        XCTAssertThrowsError(try seal(broken, id: id))
        let reopened = try repository()
        XCTAssertEqual(try reopened.pendingSegments().map(\.id), [id])
        XCTAssertEqual(try Data(contentsOf: reopened.audioURL(for: reopened.manifests()[0])).count, 8_192)
    }

    func testPhoneCrashBeforeManifestCommitNeedsRetryBeforeReceipt() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let broken = try repository("phone", fault: { if case .afterAudioCommit = $0 { throw SimulatedCrash() } })
        XCTAssertThrowsError(try broken.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest))
        let reopened = try repository("phone")
        XCTAssertEqual(try reopened.manifests(), [manifest])
        XCTAssertEqual(try reopened.receipts().count, 0)
        _ = try reopened.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        XCTAssertEqual(try reopened.receipts().count, 1)
    }

    func testPhoneCrashAfterManifestCommitNeedsRetryBeforeReceipt() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let broken = try repository("phone", fault: { if case .afterManifestCommit = $0 { throw SimulatedCrash() } })
        XCTAssertThrowsError(try broken.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest))
        let reopened = try repository("phone")
        XCTAssertEqual(try reopened.manifests().count, 1)
        XCTAssertEqual(try reopened.receipts().count, 0)
        _ = try reopened.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        XCTAssertEqual(try reopened.receipts().count, 1)
    }

    func testReceiptWriteFailureKeepsWatchAudioPending() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let phone = try repository("phone", fault: { if case .beforeReceiptCommit = $0 { throw SimulatedCrash() } })
        XCTAssertThrowsError(try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest))
        XCTAssertEqual(try watch.pendingSegments().count, 1)
        XCTAssertEqual(try repository("phone").receipts().count, 0)
    }

    func testWatchCrashBeforeAcknowledgementPersistenceDoesNotDeleteAudio() throws {
        let watch = try repository(fault: { if case .beforeAcknowledgementCommit = $0 { throw SimulatedCrash() } })
        let manifest = try seal(watch)
        let receipt = try repository("phone").acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        XCTAssertThrowsError(try watch.acknowledge(receipt))
        XCTAssertEqual(try repository().pendingSegments().count, 1)
        XCTAssertFalse(try watch.hasDurableAcknowledgement(for: manifest))
        XCTAssertFalse(try repository().hasDurableAcknowledgement(for: manifest))
    }

    func testMissingDurablePhoneAudioCannotReissueAcknowledgement() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let phone = try repository("phone")
        _ = try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        try FileManager.default.removeItem(at: phone.audioURL(for: manifest))
        XCTAssertThrowsError(try phone.receipts())
        _ = try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        XCTAssertEqual(try phone.receipts().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: phone.audioURL(for: manifest).path))
    }

    func testCorrectRetransmissionRepairsCorruptedPhoneCopy() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let phone = try repository("phone")
        _ = try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        try Data(repeating: 7, count: 8_192).write(to: phone.audioURL(for: manifest))
        XCTAssertThrowsError(try phone.receipts())
        _ = try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        XCTAssertEqual(try phone.receipts().count, 1)
        XCTAssertEqual(try Data(contentsOf: phone.audioURL(for: manifest)).first, 42)
    }

    func testConflictingRetransmissionCannotOverwritePendingRecoveryManifest() throws {
        let watch = try repository()
        let original = try seal(watch)
        let phone = try repository("phone", fault: { if case .afterAudioCommit = $0 { throw SimulatedCrash() } })
        XCTAssertThrowsError(try phone.acceptIncomingFile(at: watch.audioURL(for: original), manifest: original))
        let otherWatch = try repository("other-watch")
        let conflict = try seal(otherWatch, id: original.id, sessionID: original.sessionID,
                                payload: Data(repeating: 7, count: 8_192))
        XCTAssertThrowsError(try phone.acceptIncomingFile(at: otherWatch.audioURL(for: conflict), manifest: conflict)) {
            XCTAssertEqual($0 as? RepositoryError, .conflictingSegment)
        }
        let recovered = try repository("phone")
        XCTAssertEqual(try recovered.manifests(), [original])
        XCTAssertEqual(try Data(contentsOf: recovered.audioURL(for: original)).first, 42)
    }

    func testVisibleReceiptAfterFailedSyncIsSynchronizedAgainOnRetry() throws {
        let watch = try repository()
        let manifest = try seal(watch)
        let phone = try repository("phone", fault: { if case .afterReceiptWriteBeforeSync = $0 { throw SimulatedCrash() } })
        XCTAssertThrowsError(try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest))
        // A visible receipt does not bypass the failed synchronization step.
        XCTAssertThrowsError(try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest))
        XCTAssertThrowsError(try phone.receipts())
        let restarted = try repository("phone")
        _ = try restarted.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        XCTAssertEqual(try restarted.receipts().count, 1)
    }

    func testRecoveryMarksActiveSessionInterruptedAndPreservesUserPauseAndEnd() throws {
        let store = try repository()
        var active = try store.createSession(at: instant)
        active.state = .recording
        active.lastAudioAt = instant.addingTimeInterval(50)
        active.currentSegmentStartedAt = instant.addingTimeInterval(10)
        try store.saveSession(active)
        var paused = try store.createSession(at: instant.addingTimeInterval(1))
        paused.state = .paused
        try store.saveSession(paused)
        var ended = try store.createSession(at: instant.addingTimeInterval(2))
        ended.state = .ended
        try store.saveSession(ended)
        let recovered = try repository().recoverInterruptedSessions(at: instant.addingTimeInterval(100))
        XCTAssertEqual(recovered.map(\.state), [.interrupted])
        XCTAssertEqual(try store.sessions().map(\.state), [.interrupted, .paused, .ended])
        let event = try XCTUnwrap(store.events().first)
        XCTAssertEqual(event.intervalStart, active.currentSegmentStartedAt)
        XCTAssertEqual(event.intervalEnd, instant.addingTimeInterval(100))
        XCTAssertEqual(try store.recoverInterruptedSessions().count, 0)
    }

    func testRepeatedEventDeliveryDoesNotDuplicateLog() throws {
        let store = try repository()
        let event = RecordingEvent(kind: "interruption", detail: "Siri", timestamp: instant)
        try store.appendEvent(event)
        try store.appendEvent(event)
        XCTAssertEqual(try repository().events(), [event])
    }

    func testFractionalTimestampsRemainIdenticalAcrossTransportAndDisk() throws {
        for i in 0..<100 {
            let date = instant.addingTimeInterval(Double(i) / 777.0)
            let event = RecordingEvent(kind: "sample", detail: "precision", timestamp: date,
                                       intervalStart: date, intervalEnd: date.addingTimeInterval(60))
            let restored = try TransportCodec.decode(RecordingEvent.self, from: TransportCodec.encode(event))
            XCTAssertEqual(restored, event)
            let receipt = SegmentReceipt(segmentID: UUID(), sha256: "test", byteCount: 1, receivedAt: date)
            XCTAssertEqual(try TransportCodec.decode(SegmentReceipt.self, from: TransportCodec.encode(receipt)), receipt)
        }
    }

    func testSnapshotStalenessUsesCapturedTimeNotDeliveryTime() {
        let snapshot = RecorderSnapshot(state: .recording, observedAt: instant)
        XCTAssertFalse(snapshot.isStale(at: instant.addingTimeInterval(59)))
        XCTAssertTrue(snapshot.isStale(at: instant.addingTimeInterval(61)))
        XCTAssertTrue(snapshot.isStale(at: instant.addingTimeInterval(-6)))
    }

    private struct SimulatedCrash: Error {}
}
