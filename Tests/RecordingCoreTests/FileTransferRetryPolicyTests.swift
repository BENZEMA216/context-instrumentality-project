import XCTest
@testable import RecordingCore

final class FileTransferRetryPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testDeliveryWaitsFiveMinutesForDurableAcknowledgement() {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        policy.recordDelivery(of: file, at: start)

        XCTAssertFalse(policy.isEligible(file, at: start.addingTimeInterval(299)))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start), start.addingTimeInterval(300))
        XCTAssertTrue(policy.isEligible(file, at: start.addingTimeInterval(300)))
    }

    func testWaitingForAcknowledgementDoesNotBlockNewFiles() {
        var policy = FileTransferRetryPolicy()
        let delivered = manifest()
        let newFile = manifest(sequence: 2)
        policy.recordDelivery(of: delivered, at: start)

        XCTAssertFalse(policy.isEligible(delivered, at: start))
        XCTAssertTrue(policy.isEligible(newFile, at: start))
        XCTAssertEqual(policy.nextRetryDate(pending: [delivered, newFile], at: start),
                       start.addingTimeInterval(300))
    }

    func testRepeatedDeliveriesBackOffToThirtyMinutes() {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        var now = start
        for expectedDelay in [300.0, 600, 1_200, 1_800, 1_800] {
            policy.recordDelivery(of: file, at: now)
            XCTAssertEqual(policy.nextRetryDate(pending: [file], at: now),
                           now.addingTimeInterval(expectedDelay))
            now = now.addingTimeInterval(expectedDelay)
            XCTAssertTrue(policy.isEligible(file, at: now))
        }
    }

    func testFailuresUseSeparateThirtySecondBackoffCappedAtFiveMinutes() {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        var now = start
        for expectedDelay in [30.0, 60, 120, 240, 300, 300] {
            policy.recordFailure(of: file, at: now)
            XCTAssertFalse(policy.isEligible(file, at: now.addingTimeInterval(expectedDelay - 1)))
            XCTAssertEqual(policy.nextRetryDate(pending: [file], at: now),
                           now.addingTimeInterval(expectedDelay))
            now = now.addingTimeInterval(expectedDelay)
            XCTAssertTrue(policy.isEligible(file, at: now))
        }
    }

    func testSuccessfulDeliveryResetsFailureCountButPreservesDeliveryHistory() {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        policy.recordFailure(of: file, at: start)
        policy.recordFailure(of: file, at: start.addingTimeInterval(30))
        policy.recordDelivery(of: file, at: start.addingTimeInterval(90))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(90)),
                       start.addingTimeInterval(390))

        policy.recordFailure(of: file, at: start.addingTimeInterval(390))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(390)),
                       start.addingTimeInterval(420))
        policy.recordDelivery(of: file, at: start.addingTimeInterval(420))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(420)),
                       start.addingTimeInterval(1_020))
    }

    func testFailureOfAnOlderDuplicateCannotShortenWaitForAcknowledgement() {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        policy.recordDelivery(of: file, at: start)
        policy.recordFailure(of: file, at: start.addingTimeInterval(1))

        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(1)),
                       start.addingTimeInterval(300))
        XCTAssertFalse(policy.isEligible(file, at: start.addingTimeInterval(31)))
        XCTAssertTrue(policy.isEligible(file, at: start.addingTimeInterval(300)))
    }

    func testSameIDWithDifferentManifestDoesNotInheritCooldownOrAttempts() {
        var policy = FileTransferRetryPolicy()
        let original = manifest()
        let changed = manifest(id: original.id, sessionID: original.sessionID, sha256: "changed")
        policy.recordDelivery(of: original, at: start)
        policy.recordDelivery(of: original, at: start.addingTimeInterval(300))
        XCTAssertTrue(policy.isEligible(changed, at: start.addingTimeInterval(300)))
        XCTAssertNil(policy.nextRetryDate(pending: [changed], at: start.addingTimeInterval(300)))

        policy.recordDelivery(of: changed, at: start.addingTimeInterval(301))
        XCTAssertEqual(policy.nextRetryDate(pending: [changed], at: start.addingTimeInterval(301)),
                       start.addingTimeInterval(601))
        XCTAssertTrue(policy.isEligible(original, at: start.addingTimeInterval(301)))
    }

    func testIdentityChecksEveryManifestFieldEvenWhenContentHashIsUnchanged() {
        var policy = FileTransferRetryPolicy()
        let original = manifest()
        let differentSequence = manifest(id: original.id, sessionID: original.sessionID, sequence: 2)
        policy.recordDelivery(of: original, at: start)
        XCTAssertTrue(policy.isEligible(differentSequence, at: start))
        policy.retainPending(manifests: [differentSequence])
        XCTAssertEqual(policy, FileTransferRetryPolicy())
    }

    func testEncodeDecodePreservesCooldownAndAttemptCountsAcrossRestart() throws {
        var policy = FileTransferRetryPolicy()
        let delivered = manifest()
        let failed = manifest(sequence: 2)
        policy.recordDelivery(of: delivered, at: start)
        policy.recordFailure(of: failed, at: start)

        var restored = try TransportCodec.decode(FileTransferRetryPolicy.self,
                                                 from: TransportCodec.encode(policy))
        XCTAssertEqual(restored, policy)
        XCTAssertFalse(restored.isEligible(delivered, at: start.addingTimeInterval(100)))
        XCTAssertFalse(restored.isEligible(failed, at: start.addingTimeInterval(29)))
        restored.recordDelivery(of: delivered, at: start.addingTimeInterval(300))
        XCTAssertEqual(restored.nextRetryDate(pending: [delivered], at: start.addingTimeInterval(300)),
                       start.addingTimeInterval(900))
        restored.recordFailure(of: failed, at: start.addingTimeInterval(300))
        XCTAssertEqual(restored.nextRetryDate(pending: [failed], at: start.addingTimeInterval(300)),
                       start.addingTimeInterval(360))
    }

    func testAcknowledgementClearsOnlyTheAcknowledgedFile() {
        var policy = FileTransferRetryPolicy()
        let first = manifest()
        let second = manifest(sequence: 2)
        policy.recordDelivery(of: first, at: start)
        policy.recordDelivery(of: second, at: start)
        policy.acknowledge(id: first.id)
        XCTAssertTrue(policy.isEligible(first, at: start))
        XCTAssertFalse(policy.isEligible(second, at: start))
        policy.acknowledge(id: second.id)
        XCTAssertEqual(policy, FileTransferRetryPolicy())
    }

    func testRetainingPendingDoesNotResetWaitOrRewriteUnchangedState() {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        policy.recordDelivery(of: file, at: start)
        let beforeSync = policy
        for second in 1..<300 {
            policy.retainPending(manifests: [file])
            XCTAssertFalse(policy.isEligible(file, at: start.addingTimeInterval(Double(second))))
            XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(Double(second))),
                           start.addingTimeInterval(300))
        }
        XCTAssertEqual(policy, beforeSync)
        policy.retainPending(manifests: [])
        XCTAssertEqual(policy, FileTransferRetryPolicy())
    }

    func testRetryTimerSkipsOutstandingAndElapsedDeadlines() {
        var policy = FileTransferRetryPolicy()
        let earlier = manifest()
        let later = manifest(sequence: 2)
        let neverSent = manifest(sequence: 3)
        policy.recordFailure(of: earlier, at: start)
        policy.recordDelivery(of: later, at: start)

        XCTAssertEqual(policy.nextRetryDate(pending: [earlier, later, neverSent],
                                             excludingIDs: [earlier.id], at: start),
                       start.addingTimeInterval(300))
        XCTAssertEqual(policy.nextRetryDate(pending: [earlier, later, neverSent],
                                             at: start.addingTimeInterval(30)),
                       start.addingTimeInterval(300))
        XCTAssertNil(policy.nextRetryDate(pending: [earlier, later, neverSent],
                                           at: start.addingTimeInterval(300)))
        XCTAssertNil(policy.nextRetryDate(pending: [earlier, later],
                                           excludingIDs: [earlier.id, later.id], at: start))
    }

    func testEnqueueRetainsHistoryAndHasBoundedRecoveryWithoutCallback() {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        policy.recordDelivery(of: file, at: start)
        let resendTime = start.addingTimeInterval(300)
        policy.noteEnqueued(file, at: resendTime)

        XCTAssertFalse(policy.isEligible(file, at: resendTime))
        XCTAssertNil(policy.nextRetryDate(pending: [file], excludingIDs: [file.id], at: resendTime))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: resendTime),
                       resendTime.addingTimeInterval(300))
        XCTAssertTrue(policy.isEligible(file, at: resendTime.addingTimeInterval(300)))
        policy.recordDelivery(of: file, at: resendTime.addingTimeInterval(300))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: resendTime.addingTimeInterval(300)),
                       resendTime.addingTimeInterval(900))
    }

    func testClockRollbackReanchorsOnceWithoutSlidingOrLosingPersistence() throws {
        var policy = FileTransferRetryPolicy()
        let delivered = manifest()
        let failed = manifest(sequence: 2)
        policy.recordDelivery(of: delivered, at: start)
        policy.recordFailure(of: failed, at: start)
        let correctedClock = start.addingTimeInterval(-86_400)

        XCTAssertFalse(policy.isEligible(delivered, at: correctedClock))
        XCTAssertEqual(policy.nextRetryDate(pending: [delivered], at: correctedClock),
                       correctedClock.addingTimeInterval(300))
        XCTAssertEqual(policy.nextRetryDate(pending: [failed], at: correctedClock),
                       correctedClock.addingTimeInterval(30))
        let rebased = policy
        XCTAssertFalse(policy.isEligible(delivered, at: correctedClock.addingTimeInterval(299)))
        XCTAssertEqual(policy, rebased)

        var restored = try JSONDecoder().decode(FileTransferRetryPolicy.self,
                                                 from: JSONEncoder().encode(policy))
        XCTAssertTrue(restored.isEligible(delivered, at: correctedClock.addingTimeInterval(300)))
        XCTAssertNil(restored.nextRetryDate(pending: [delivered, failed],
                                             at: correctedClock.addingTimeInterval(300)))
    }

    func testLargeForwardClockJumpMakesFilesEligibleWithoutImmediateRetryTimer() {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        policy.recordDelivery(of: file, at: start)
        let jumpedClock = start.addingTimeInterval(86_400)
        XCTAssertTrue(policy.isEligible(file, at: jumpedClock))
        XCTAssertNil(policy.nextRetryDate(pending: [file], at: jumpedClock))
    }

    func testDisappearanceGraceIsFiniteAndSurvivesRestartWithoutSliding() throws {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        policy.noteEnqueued(file, attemptID: "first", at: start)
        let disappeared = start.addingTimeInterval(400)
        XCTAssertEqual(policy.recordDisappearedTransfers(outstandingIDs: [], at: disappeared), [file.id])
        let deadline = disappeared.addingTimeInterval(FileTransferRetryPolicy.disappearanceGrace)
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: disappeared), deadline)
        policy = try JSONDecoder().decode(FileTransferRetryPolicy.self, from: JSONEncoder().encode(policy))
        let saved = policy
        XCTAssertTrue(policy.recordDisappearedTransfers(outstandingIDs: [],
            at: disappeared.addingTimeInterval(59)).isEmpty)
        XCTAssertFalse(policy.isEligible(file, at: deadline.addingTimeInterval(-1)))
        XCTAssertEqual(policy, saved)
        XCTAssertTrue(policy.isEligible(file, at: deadline))
        XCTAssertTrue(policy.recordDisappearedTransfers(outstandingIDs: [file.id], at: deadline).isEmpty)
        XCTAssertTrue(policy.recordDisappearedTransfers(outstandingIDs: [],
            at: deadline.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(policy.isEligible(file, at: deadline.addingTimeInterval(1)))
    }

    func testDelayedOldCallbacksCannotReplaceANewerAttemptAfterRestart() throws {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        policy.noteEnqueued(file, attemptID: "old", at: start)
        let retryTime = start.addingTimeInterval(400)
        policy.noteEnqueued(file, attemptID: "new", at: retryTime)
        policy = try JSONDecoder().decode(FileTransferRetryPolicy.self, from: JSONEncoder().encode(policy))
        let saved = policy
        XCTAssertFalse(policy.recordDelivery(of: file, attemptID: "old", at: retryTime.addingTimeInterval(1)))
        XCTAssertFalse(policy.recordFailure(of: file, attemptID: "old", at: retryTime.addingTimeInterval(2)))
        XCTAssertFalse(policy.recordFailure(of: file, at: retryTime.addingTimeInterval(3)))
        XCTAssertEqual(policy, saved)
        XCTAssertTrue(policy.recordDelivery(of: file, attemptID: "new", at: retryTime.addingTimeInterval(4)))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: retryTime.addingTimeInterval(4)),
                       retryTime.addingTimeInterval(304))
    }

    func testLegacyStateAdoptsIdentityWithoutResettingExistingDeadline() throws {
        var original = FileTransferRetryPolicy()
        let file = manifest()
        original.recordDelivery(of: file, at: start)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var attempts = try XCTUnwrap(json["attempts"] as? [[String: Any]])
        for key in ["attemptID", "attemptEnqueuedAt", "disappearanceRetryAt"] { attempts[0].removeValue(forKey: key) }
        json["attempts"] = attempts
        var restored = try JSONDecoder().decode(FileTransferRetryPolicy.self,
            from: JSONSerialization.data(withJSONObject: json))
        restored.adoptOutstanding(file, attemptID: "newer", enqueuedAt: start.addingTimeInterval(50),
                                  at: start.addingTimeInterval(100))
        XCTAssertEqual(restored.nextRetryDate(pending: [file], at: start.addingTimeInterval(100)),
                       start.addingTimeInterval(300))
        let adopted = restored
        restored.adoptOutstanding(file, attemptID: "older", enqueuedAt: start,
                                  at: start.addingTimeInterval(101))
        XCTAssertEqual(restored, adopted)
        XCTAssertFalse(restored.recordDelivery(of: file, attemptID: "older", at: start.addingTimeInterval(102)))
        XCTAssertTrue(restored.recordDelivery(of: file, attemptID: "newer", at: start.addingTimeInterval(102)))
    }

    func testOutstandingNewerAttemptRepairsInterruptedIdentitySaveWithoutExtendingWait() {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        policy.noteEnqueued(file, attemptID: "old", at: start)
        policy.adoptOutstanding(file, attemptID: "new", enqueuedAt: start.addingTimeInterval(100),
                                at: start.addingTimeInterval(101))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(101)),
                       start.addingTimeInterval(300))
        XCTAssertFalse(policy.recordDelivery(of: file, attemptID: "old", at: start.addingTimeInterval(102)))
        XCTAssertTrue(policy.recordFailure(of: file, attemptID: "new", at: start.addingTimeInterval(102)))
    }

    func testDisappearanceGraceClockRollbackReanchorsOnlyOnce() throws {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        policy.noteEnqueued(file, attemptID: "current", at: start)
        let observed = start.addingTimeInterval(400)
        policy.recordDisappearedTransfers(outstandingIDs: [], at: observed)
        let rollback = start.addingTimeInterval(-86_400)
        XCTAssertFalse(policy.isEligible(file, at: rollback))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: rollback), rollback.addingTimeInterval(60))
        let rebased = policy
        policy.recordDisappearedTransfers(outstandingIDs: [], at: rollback.addingTimeInterval(30))
        XCTAssertEqual(policy, rebased)
        policy = try JSONDecoder().decode(FileTransferRetryPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertTrue(policy.isEligible(file, at: rollback.addingTimeInterval(60)))
    }

    func testCallbackWithoutSavedStateRetainsMetadataForLaterIdentityAdoption() {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        XCTAssertTrue(policy.recordDelivery(of: file, attemptID: "old", enqueuedAt: start,
                                            at: start.addingTimeInterval(10)))
        policy.adoptOutstanding(file, attemptID: "new", enqueuedAt: start.addingTimeInterval(20),
                                at: start.addingTimeInterval(21))
        XCTAssertFalse(policy.recordDelivery(of: file, attemptID: "old", at: start.addingTimeInterval(22)))
        XCTAssertTrue(policy.recordDelivery(of: file, attemptID: "new", at: start.addingTimeInterval(23)))
    }

    func testUnprovableIdentityAfterClockRollbackStillHasFiniteRecovery() {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        policy.noteEnqueued(file, attemptID: "known", at: start)
        let rollback = start.addingTimeInterval(-86_400)
        policy.adoptOutstanding(file, attemptID: "unproven", enqueuedAt: rollback, at: rollback)
        XCTAssertFalse(policy.recordDelivery(of: file, attemptID: "unproven", at: rollback.addingTimeInterval(1)))
        policy.recordDisappearedTransfers(outstandingIDs: [], at: rollback.addingTimeInterval(2))
        XCTAssertFalse(policy.isEligible(file, at: rollback.addingTimeInterval(299)))
        XCTAssertTrue(policy.isEligible(file, at: rollback.addingTimeInterval(300)))
        policy.noteEnqueued(file, attemptID: "replacement", at: rollback.addingTimeInterval(300))
        XCTAssertTrue(policy.recordDelivery(of: file, attemptID: "replacement", at: rollback.addingTimeInterval(301)))
    }

    func testUnclassifiedCompletionPersistsFiniteWaitWithoutInventingADelivery() throws {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "current", enqueuedAt: start,
                                                         at: start.addingTimeInterval(10)))
        policy = try TransportCodec.decode(FileTransferRetryPolicy.self, from: TransportCodec.encode(policy))
        XCTAssertFalse(policy.isEligible(file, at: start.addingTimeInterval(309)))
        XCTAssertTrue(policy.isEligible(file, at: start.addingTimeInterval(310)))
        XCTAssertFalse(policy.recordDelivery(of: file, attemptID: "obsolete", at: start.addingTimeInterval(310)))
        XCTAssertTrue(policy.recordDelivery(of: file, attemptID: "current", at: start.addingTimeInterval(310)))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(310)),
                       start.addingTimeInterval(610), "The first real delivery still gets its first five-minute ACK wait.")
    }

    func testUnclassifiedCompletionPreservesLongAckWindowAndDeliveryCount() throws {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        XCTAssertTrue(policy.recordDelivery(of: file, attemptID: "current", at: start))
        XCTAssertTrue(policy.recordDelivery(of: file, attemptID: "current", at: start.addingTimeInterval(300)))
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "current",
                                                         at: start.addingTimeInterval(400)))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(400)),
                       start.addingTimeInterval(900))
        policy = try TransportCodec.decode(FileTransferRetryPolicy.self, from: TransportCodec.encode(policy))
        // Keeping the ACK phase prevents a later ordinary failure from cutting
        // this longer wait down to its shorter transport-failure backoff.
        XCTAssertTrue(policy.recordFailure(of: file, attemptID: "current", at: start.addingTimeInterval(401)))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(401)),
                       start.addingTimeInterval(900))
        XCTAssertTrue(policy.recordDelivery(of: file, attemptID: "current", at: start.addingTimeInterval(900)))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(900)),
                       start.addingTimeInterval(2_100), "An unclassified error is not an extra delivery.")
    }

    func testUnclassifiedCompletionPreservesFailureCountWithoutCountingAnotherFailure() {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        XCTAssertTrue(policy.recordFailure(of: file, attemptID: "current", at: start))
        XCTAssertTrue(policy.recordFailure(of: file, attemptID: "current", at: start.addingTimeInterval(30)))
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "current",
                                                         at: start.addingTimeInterval(35)))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(35)),
                       start.addingTimeInterval(335))
        XCTAssertTrue(policy.recordFailure(of: file, attemptID: "current", at: start.addingTimeInterval(335)))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(335)),
                       start.addingTimeInterval(455))
    }

    func testUnclassifiedOldOrUnknownAttemptCannotReplaceCurrentIdentityOrBackoff() {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        policy.noteEnqueued(file, attemptID: "current", at: start)
        let original = policy
        XCTAssertFalse(policy.deferUnclassifiedCompletion(of: file, attemptID: "old",
                                                          at: start.addingTimeInterval(400)))
        XCTAssertFalse(policy.deferUnclassifiedCompletion(of: file, attemptID: nil,
                                                          at: start.addingTimeInterval(400)))
        XCTAssertEqual(policy, original)
        XCTAssertTrue(policy.recordFailure(of: file, attemptID: "current", at: start.addingTimeInterval(400)))
    }

    func testRepeatedUnclassifiedCompletionCannotSlideRecoveryAcrossRestart() throws {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "current", at: start))
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "current",
                                                         at: start.addingTimeInterval(299)))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(299)),
                       start.addingTimeInterval(300))
        policy = try TransportCodec.decode(FileTransferRetryPolicy.self, from: TransportCodec.encode(policy))
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "current",
                                                         at: start.addingTimeInterval(300)))
        XCTAssertTrue(policy.isEligible(file, at: start.addingTimeInterval(300)))
        XCTAssertNil(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(300)))
    }

    func testUnclassifiedCompletionKeepsExistingDisappearanceGraceBoundedAndNewEnqueueResetsIt() throws {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        policy.noteEnqueued(file, attemptID: "current", at: start)
        XCTAssertEqual(policy.recordDisappearedTransfers(outstandingIDs: [], at: start.addingTimeInterval(400)),
                       [file.id])
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "current",
                                                         at: start.addingTimeInterval(450)))
        policy = try TransportCodec.decode(FileTransferRetryPolicy.self, from: TransportCodec.encode(policy))
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "current",
                                                         at: start.addingTimeInterval(700)))
        XCTAssertTrue(policy.recordDisappearedTransfers(outstandingIDs: [], at: start.addingTimeInterval(749)).isEmpty)
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(749)),
                       start.addingTimeInterval(750))
        XCTAssertTrue(policy.isEligible(file, at: start.addingTimeInterval(750)))
        policy.noteEnqueued(file, attemptID: "replacement", at: start.addingTimeInterval(800))
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "replacement",
                                                         at: start.addingTimeInterval(810)))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(810)),
                       start.addingTimeInterval(1_110))
    }

    func testUnclassifiedCompletionClockRollbackReanchorsOnlyRemainingWaitOnce() throws {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "current",
                                                         at: start.addingTimeInterval(10)))
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "current",
                                                         at: start.addingTimeInterval(100)))
        let rollback = start.addingTimeInterval(-1_000)
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "current", at: rollback))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: rollback), rollback.addingTimeInterval(210))
        policy = try TransportCodec.decode(FileTransferRetryPolicy.self, from: TransportCodec.encode(policy))
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "current",
                                                         at: rollback.addingTimeInterval(209)))
        XCTAssertFalse(policy.isEligible(file, at: rollback.addingTimeInterval(209)))
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "current",
                                                         at: rollback.addingTimeInterval(210)))
        XCTAssertTrue(policy.isEligible(file, at: rollback.addingTimeInterval(210)))
    }

    func testAdoptingProvablyNewAttemptStartsItsOwnUnclassifiedCompletionWindow() throws {
        var policy = FileTransferRetryPolicy()
        let file = manifest()
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "old", enqueuedAt: start, at: start))
        policy.adoptOutstanding(file, attemptID: "new", enqueuedAt: start.addingTimeInterval(100),
                                at: start.addingTimeInterval(100))
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "new",
                                                         at: start.addingTimeInterval(110)))
        XCTAssertFalse(policy.deferUnclassifiedCompletion(of: file, attemptID: "old",
                                                          at: start.addingTimeInterval(120)))
        policy = try TransportCodec.decode(FileTransferRetryPolicy.self, from: TransportCodec.encode(policy))
        XCTAssertTrue(policy.deferUnclassifiedCompletion(of: file, attemptID: "new",
                                                         at: start.addingTimeInterval(409)))
        XCTAssertEqual(policy.nextRetryDate(pending: [file], at: start.addingTimeInterval(409)),
                       start.addingTimeInterval(410))
        XCTAssertTrue(policy.isEligible(file, at: start.addingTimeInterval(410)))
    }

    private func manifest(id: UUID = UUID(), sessionID: UUID = UUID(), sequence: Int = 1,
                          sha256: String = "recording-digest") -> SegmentManifest {
        SegmentManifest(id: id, sessionID: sessionID, sequence: sequence, startedAt: start,
                        endedAt: start.addingTimeInterval(60), sampleRate: 48_000,
                        frameCount: 2_880_000, fileName: "\(id.uuidString).caf", byteCount: 11_520_000,
                        sha256: sha256)
    }
}
