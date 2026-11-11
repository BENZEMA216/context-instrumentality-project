import XCTest
@testable import RecordingCore

final class ReceiptReplayPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testBoundedReplayCursorContinuesPastAttemptedOrCorruptItemAndWraps() {
        let ids = (1...5).map {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
        }
        XCTAssertEqual(ReceiptReplayPolicy.orderedIDs(ids.reversed(), after: nil), ids)
        XCTAssertEqual(ReceiptReplayPolicy.orderedIDs(ids + [ids[0]], after: ids[1]),
                       [ids[2], ids[3], ids[4], ids[0], ids[1]])
        XCTAssertEqual(ReceiptReplayPolicy.orderedIDs(ids, after: ids[4]), ids)
        // A removed receipt cannot reset the progress of the rest of the sweep.
        XCTAssertEqual(ReceiptReplayPolicy.orderedIDs([ids[0], ids[2], ids[4]], after: ids[1]),
                       [ids[2], ids[4], ids[0]])
        XCTAssertEqual(ReceiptReplayPolicy.orderedIDs([], after: ids[1]), [])
    }

    private func receipts(_ count: Int) -> [SegmentReceipt] {
        (0..<count).map { index in
            SegmentReceipt(segmentID: UUID(), sha256: String(repeating: "a", count: 64),
                           byteCount: Int64(index + 1),
                           receivedAt: start.addingTimeInterval(Double(index)))
        }
    }

    func testRecentUnattemptedReceiptsLeadAndAllHistoryGetsATurn() {
        var policy = ReceiptReplayPolicy()
        let history = receipts(25)
        let first = policy.nextBatch(from: history, at: start)
        XCTAssertEqual(first, Array(history.reversed().prefix(12)))
        // Even after cooldown expires, previously unseen older receipts win.
        let second = policy.nextBatch(from: history, at: start.addingTimeInterval(16))
        XCTAssertEqual(second, Array(history.reversed().dropFirst(12).prefix(12)))
        let third = policy.nextBatch(from: history, at: start.addingTimeInterval(32))
        XCTAssertEqual(third.first, history.first)
        XCTAssertEqual(Set((first + second + third).map(\.segmentID)).count, 25)
        XCTAssertEqual(third.count, 12)
    }

    func testRapidBatchesAreBoundedAndRejectedTriggersDoNotExtendDebounce() {
        var policy = ReceiptReplayPolicy()
        let history = receipts(25)
        let first = policy.nextBatch(from: history, at: start)
        for offset in [0.0, 0.1, 1.0, 1.999] {
            XCTAssertTrue(policy.nextBatch(from: history, at: start.addingTimeInterval(offset)).isEmpty)
        }
        let second = policy.nextBatch(from: history, at: start.addingTimeInterval(2))
        let third = policy.nextBatch(from: history, at: start.addingTimeInterval(4))
        XCTAssertEqual([first.count, second.count, third.count], [12, 12, 1])
        XCTAssertEqual(Set((first + second + third).map(\.segmentID)).count, 25)
    }

    func testFailedAttemptsRemainCoolingAndDoNotStarveRemainingReceipts() {
        var policy = ReceiptReplayPolicy(batchLimit: 1)
        let history = receipts(2)
        XCTAssertEqual(policy.nextBatch(from: history, at: start), [history[1]])
        // There is deliberately no success callback or failure reset in the policy.
        XCTAssertEqual(policy.nextBatch(from: history, at: start.addingTimeInterval(2)), [history[0]])
        XCTAssertTrue(policy.nextBatch(from: history, at: start.addingTimeInterval(14.999)).isEmpty)
        XCTAssertEqual(policy.nextBatch(from: history, at: start.addingTimeInterval(15)), [history[1]])
        XCTAssertEqual(policy.nextBatch(from: history, at: start.addingTimeInterval(17)), [history[0]])
    }

    func testFreshArrivalBypassesBatchDebounceButDuplicateArrivalDoesNot() {
        var policy = ReceiptReplayPolicy()
        let history = receipts(2)
        XCTAssertEqual(policy.nextBatch(from: [history[0]], at: start), [history[0]])
        XCTAssertTrue(policy.beginImmediateAttempt(history[1], at: start.addingTimeInterval(0.1)))
        XCTAssertFalse(policy.beginImmediateAttempt(history[1], at: start.addingTimeInterval(1)))
        XCTAssertTrue(policy.nextBatch(from: history, at: start.addingTimeInterval(2)).isEmpty)
        XCTAssertFalse(policy.beginImmediateAttempt(history[1], at: start.addingTimeInterval(15.099)))
        XCTAssertTrue(policy.beginImmediateAttempt(history[1], at: start.addingTimeInterval(15.1)))
    }

    func testSameSegmentWithDifferentCompleteReceiptDoesNotInheritCooldown() {
        var policy = ReceiptReplayPolicy()
        let original = receipts(1)[0]
        XCTAssertTrue(policy.beginImmediateAttempt(original, at: start))
        let replacement = SegmentReceipt(segmentID: original.segmentID, sha256: original.sha256,
                                         byteCount: original.byteCount,
                                         receivedAt: original.receivedAt.addingTimeInterval(1))
        XCTAssertTrue(policy.canAttempt(replacement, at: start))
        XCTAssertTrue(policy.beginImmediateAttempt(replacement, at: start))
        XCTAssertFalse(policy.canAttempt(replacement, at: start))
    }

    func testEmptyOrCoolingBatchDoesNotConsumeFutureOpportunity() {
        var policy = ReceiptReplayPolicy()
        let receipt = receipts(1)[0]
        XCTAssertTrue(policy.nextBatch(from: [], at: start).isEmpty)
        XCTAssertEqual(policy.nextBatch(from: [receipt], at: start), [receipt])
        XCTAssertTrue(policy.nextBatch(from: [receipt], at: start.addingTimeInterval(14.9)).isEmpty)
        XCTAssertEqual(policy.nextBatch(from: [receipt], at: start.addingTimeInterval(15)), [receipt])
    }

    func testReconnectDuringCooldownHasABoundedDeferredOpportunity() {
        var policy = ReceiptReplayPolicy()
        let receipt = receipts(1)[0]
        XCTAssertTrue(policy.beginImmediateAttempt(receipt, at: start))
        let reconnect = start.addingTimeInterval(3)
        XCTAssertTrue(policy.nextBatch(from: [receipt], at: reconnect).isEmpty)
        let delay = policy.delayUntilAttempt(receipt, at: reconnect)
        XCTAssertEqual(delay, 12)
        XCTAssertEqual(policy.nextBatch(from: [receipt], at: reconnect.addingTimeInterval(delay)), [receipt])
    }

    func testEqualDatesUseStableOrderAndDuplicateInputsDoNotSpendBatchCapacity() {
        var policy = ReceiptReplayPolicy(batchLimit: 2)
        let a = SegmentReceipt(segmentID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                               sha256: "a", byteCount: 1, receivedAt: start)
        let b = SegmentReceipt(segmentID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                               sha256: "b", byteCount: 1, receivedAt: start)
        XCTAssertEqual(policy.nextBatch(from: [b, b, a], at: start), [a, b])
    }

    func testClockRollbackAndProcessRestartAllowDurableReceiptReplay() {
        var policy = ReceiptReplayPolicy()
        let receipt = receipts(1)[0]
        XCTAssertEqual(policy.nextBatch(from: [receipt], at: start), [receipt])
        let earlier = start.addingTimeInterval(-60)
        XCTAssertEqual(policy.nextBatch(from: [receipt], at: earlier), [receipt])
        XCTAssertTrue(policy.nextBatch(from: [receipt], at: earlier).isEmpty)
        var restarted = ReceiptReplayPolicy()
        XCTAssertEqual(restarted.nextBatch(from: [receipt], at: start), [receipt])
    }
}

final class TargetedReceiptHandoffTests: XCTestCase {
    private func request(_ suffix: Int) throws -> TargetedReceiptRequest {
        try TargetedReceiptRequest(segmentID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!,
                                   sha256: String(repeating: "ab", count: 32), byteCount: 64)
    }

    func testUnavailableTargetedHandoffKeepsTheHead() throws {
        let head = try request(1)
        let tail = try request(2)
        let pending = [head, tail]
        let held = TargetedReceiptHandoff.step(pending: pending, verified: true, handoff: .unavailable)
        XCTAssertEqual(held.pending, pending)
        XCTAssertFalse(held.committed)
        let missing = TargetedReceiptHandoff.step(pending: pending, verified: true, handoff: nil)
        XCTAssertEqual(missing.pending, pending)
        XCTAssertFalse(missing.committed)
        for handoff in [HistoricalReceiptReplay.Handoff.queued, .alreadyQueued] {
            let sent = TargetedReceiptHandoff.step(pending: pending, verified: true, handoff: handoff)
            XCTAssertEqual(sent.pending, [tail])
            XCTAssertTrue(sent.committed)
        }
        let bad = TargetedReceiptHandoff.step(pending: pending, verified: false, handoff: .unavailable)
        XCTAssertEqual(bad.pending, [tail])
        XCTAssertTrue(bad.committed, "One unverifiable targeted request must not block the tail.")
    }
}

final class ReceiptVerificationFailureTests: XCTestCase {
    private let privateDetail = "synthetic-private-path-and-credential-detail"

    func testKnownInvalidRepositoryDataDoesNotFailMaintenance() {
        let cases: [(RepositoryError, ReceiptVerificationFailure, String)] = [
            (.invalidManifest(privateDetail), .invalidMetadata, "invalid_metadata"),
            (.receiptMismatch, .identityMismatch, "identity_mismatch"),
            (.conflictingSegment, .identityMismatch, "identity_mismatch"),
            (.checksumMismatch, .contentMismatch, "content_mismatch"),
            (.missingAudio, .missingData, "missing_data")
        ]
        for (error, expected, code) in cases {
            let failure = ReceiptVerificationFailure.classify(error)
            XCTAssertEqual(failure, expected)
            XCTAssertEqual(failure.rawValue, code)
            XCTAssertFalse(failure.failsMaintenance)
            XCTAssertFalse(failure.rawValue.contains(privateDetail))
        }
    }

    func testDecodingAndTargetedValidationFailuresHaveOnlyFiniteNonfatalCode() {
        enum Key: String, CodingKey { case receipt }
        let context = DecodingError.Context(codingPath: [Key.receipt],
                                            debugDescription: privateDetail)
        let errors: [Error] = [
            DecodingError.dataCorrupted(context),
            DecodingError.keyNotFound(Key.receipt, context),
            DecodingError.typeMismatch(String.self, context),
            DecodingError.valueNotFound(String.self, context),
            TargetedReceiptRequest.ValidationError.unsupportedSchemaVersion,
            TargetedReceiptRequest.ValidationError.invalidChecksum,
            TargetedReceiptRequest.ValidationError.invalidByteCount
        ]
        for error in errors {
            let failure = ReceiptVerificationFailure.classify(error)
            XCTAssertEqual(failure, .invalidMetadata)
            XCTAssertEqual(failure.rawValue, "invalid_metadata")
            XCTAssertFalse(failure.failsMaintenance)
            XCTAssertFalse(failure.rawValue.contains(privateDetail))
        }
    }

    func testMissingFileIsNonfatalOnlyForTheKnownCocoaReadError() {
        let missing = ReceiptVerificationFailure.classify(NSError(
            domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue,
            userInfo: [NSLocalizedDescriptionKey: privateDetail]))
        XCTAssertEqual(missing, .missingData)
        XCTAssertEqual(missing.rawValue, "missing_data")
        XCTAssertFalse(missing.failsMaintenance)

        let unrelated = ReceiptVerificationFailure.classify(NSError(
            domain: "SyntheticUnknownErrorDomain", code: CocoaError.fileReadNoSuchFile.rawValue,
            userInfo: [NSLocalizedDescriptionKey: privateDetail]))
        XCTAssertEqual(unrelated, .storageFailure)
        XCTAssertEqual(unrelated.rawValue, "storage_failure")
        XCTAssertTrue(unrelated.failsMaintenance)
    }

    func testStorageAndUnknownFailuresRemainFatalWithoutDisclosingDetails() {
        struct UnknownFailure: LocalizedError {
            let detail: String
            var errorDescription: String? { detail }
        }
        let errors: [Error] = [
            RepositoryError.invalidStagingPath,
            RepositoryError.persistenceFailure("fsync failed: \(privateDetail)"),
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: privateDetail]),
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: privateDetail]),
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: privateDetail]),
            NSError(domain: NSPOSIXErrorDomain, code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "fsync I/O error: \(privateDetail)"]),
            UnknownFailure(detail: privateDetail)
        ]
        for error in errors {
            let failure = ReceiptVerificationFailure.classify(error)
            XCTAssertEqual(failure, .storageFailure)
            XCTAssertEqual(failure.rawValue, "storage_failure")
            XCTAssertTrue(failure.failsMaintenance)
            XCTAssertFalse(failure.rawValue.contains(privateDetail))
        }
    }
}
