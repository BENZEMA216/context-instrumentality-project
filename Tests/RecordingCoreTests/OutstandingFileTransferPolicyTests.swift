import XCTest
@testable import RecordingCore

final class OutstandingFileTransferPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testEnqueueAgeNeverSubstitutesForTenMinutesOfObservedNoProgress() {
        for queued in [start.addingTimeInterval(-86_400), start, nil,
                       start.addingTimeInterval(86_400)] as [Date?] {
            var policy = OutstandingFileTransferPolicy()
            XCTAssertFalse(observe(&policy, at: 100, queued: queued))
            XCTAssertFalse(observe(&policy, at: 699, queued: queued))
            XCTAssertTrue(observe(&policy, at: 700, queued: queued))
            XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 700))
        }
    }

    func testIdleThresholdCanBeInjectedWithoutEnqueueAge() {
        var policy = OutstandingFileTransferPolicy(minimumIdle: 5)
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertFalse(observe(&policy, at: 104))
        XCTAssertTrue(observe(&policy, at: 105))
    }

    func testIncreasingAndResettingProgressRestartTheIdleWindow() {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertFalse(observe(&policy, at: 699, completed: 5))
        XCTAssertFalse(observe(&policy, at: 1_298, completed: 5))
        XCTAssertFalse(observe(&policy, at: 1_299, completed: 0))
        XCTAssertFalse(observe(&policy, at: 1_898))
        XCTAssertTrue(observe(&policy, at: 1_899))
    }

    func testChangedTotalAndStartingOrPausingTransferAreActivity() {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertFalse(observe(&policy, at: 700, total: 200))
        XCTAssertFalse(observe(&policy, at: 1_300, total: 200, isTransferring: true))
        XCTAssertFalse(observe(&policy, at: 1_900, total: 200))
        XCTAssertFalse(observe(&policy, at: 2_499, total: 200))
        XCTAssertTrue(observe(&policy, at: 2_500, total: 200))
    }

    func testCompletedAndInvalidProgressNeverAuthorizeRecovery() {
        for (completed, total) in [(100, 100), (101, 100), (-1, 100), (0, -1)] {
            var policy = OutstandingFileTransferPolicy()
            XCTAssertFalse(observe(&policy, at: 100, completed: Int64(completed), total: Int64(total)))
            XCTAssertFalse(observe(&policy, at: 86_400, completed: Int64(completed), total: Int64(total)))
            policy.markReceiptRequested(key: "attempt", uptime: 86_400)
            XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 86_500))
        }
    }

    func testUnknownProgressCanBecomeAReceiptCandidate() {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100, total: 0))
        XCTAssertTrue(observe(&policy, at: 700, total: 0))
    }

    func testExactReceiptRequestMustPrecedeRecoveryAndRepeatedRequestsDoNotSlideGrace() {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        policy.markReceiptRequested(key: "attempt", uptime: 100)
        XCTAssertTrue(observe(&policy, at: 700))
        XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 700))
        policy.markReceiptRequested(key: "attempt", uptime: 700)
        XCTAssertTrue(observe(&policy, at: 759))
        policy.markReceiptRequested(key: "attempt", uptime: 759)
        XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 759))
        XCTAssertTrue(observe(&policy, at: 760))
        XCTAssertTrue(policy.canRecover(key: "attempt", uptime: 760))
    }

    func testAClockValueAloneCannotReplaceObservationAfterTheReceiptGrace() {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertTrue(observe(&policy, at: 700))
        policy.markReceiptRequested(key: "attempt", uptime: 700)
        XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 10_000))
        XCTAssertTrue(observe(&policy, at: 760))
        XCTAssertTrue(policy.canRecover(key: "attempt", uptime: 760))
    }

    func testProgressAfterReceiptRequestRequiresANewIdleWindowAndExactQuery() {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertTrue(observe(&policy, at: 700))
        policy.markReceiptRequested(key: "attempt", uptime: 700)
        XCTAssertFalse(observe(&policy, at: 760, completed: 1))
        XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 760))
        XCTAssertTrue(observe(&policy, at: 1_360, completed: 1))
        XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 1_360))
        policy.markReceiptRequested(key: "attempt", uptime: 1_360)
        XCTAssertTrue(observe(&policy, at: 1_420, completed: 1))
        XCTAssertTrue(policy.canRecover(key: "attempt", uptime: 1_420))
    }

    func testSameBootRestartPreservesProgressObservationAndReceiptGrace() throws {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        policy = try roundTrip(policy)
        XCTAssertTrue(observe(&policy, at: 700))
        policy.markReceiptRequested(key: "attempt", uptime: 700)
        let restored = try roundTrip(policy)
        XCTAssertEqual(restored, policy)
        policy = restored
        XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 760))
        XCTAssertTrue(observe(&policy, at: 760))
        XCTAssertTrue(policy.canRecover(key: "attempt", uptime: 760))
    }

    func testMillisecondPersistenceDoesNotInventClockRollbackOrResetReceiptGrace() throws {
        for fraction in [0.1234, 0.1236] {
            var policy = OutstandingFileTransferPolicy()
            let observedAt = start.addingTimeInterval(700 + fraction)
            XCTAssertFalse(observe(&policy, at: 100, now: observedAt.addingTimeInterval(-600)))
            XCTAssertTrue(observe(&policy, at: 700, now: observedAt))
            policy.markReceiptRequested(key: "attempt", uptime: 700)
            policy = try TransportCodec.decode(OutstandingFileTransferPolicy.self,
                                               from: TransportCodec.encode(policy))
            // Exact same clock values after restoration retain both the prior
            // no-progress interval and the exact request already sent.
            XCTAssertTrue(observe(&policy, at: 700, now: observedAt))
            XCTAssertTrue(policy.canRecover(key: "attempt", uptime: 700, receiptGrace: 0))
            XCTAssertTrue(observe(&policy, at: 760, now: observedAt.addingTimeInterval(60)))
            XCTAssertTrue(policy.canRecover(key: "attempt", uptime: 760))
            // Only wall precision is normalized: even a fractional monotonic
            // rollback must still discard the recovery evidence.
            XCTAssertFalse(observe(&policy, at: 759.9999, now: observedAt.addingTimeInterval(60)))
            XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 760))
        }
    }

    func testDifferentBootNeverReusesEvidenceEvenWhenNewUptimeIsLarger() throws {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertTrue(observe(&policy, at: 700))
        policy.markReceiptRequested(key: "attempt", uptime: 700)
        policy = try roundTrip(policy)
        XCTAssertFalse(observe(&policy, at: 10_000, continuityID: "boot-B"))
        XCTAssertFalse(observe(&policy, at: 10_599, continuityID: "boot-B"))
        XCTAssertTrue(observe(&policy, at: 10_600, continuityID: "boot-B"))
        XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 10_600))
    }

    func testRestartWithoutBootIdentityConservativelyStartsANewObservationWindow() throws {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100, continuityID: nil))
        policy = try roundTrip(policy)
        XCTAssertFalse(observe(&policy, at: 10_000, continuityID: nil))
        XCTAssertFalse(observe(&policy, at: 10_599, continuityID: nil))
        XCTAssertTrue(observe(&policy, at: 10_600, continuityID: nil))
    }

    func testWallClockRollbackResetsProgressAndReceiptEvidence() {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertTrue(observe(&policy, at: 700))
        policy.markReceiptRequested(key: "attempt", uptime: 700)
        XCTAssertFalse(observe(&policy, at: 710, now: start.addingTimeInterval(600)))
        XCTAssertFalse(observe(&policy, at: 1_309))
        XCTAssertTrue(observe(&policy, at: 1_310))
        XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 1_310))
    }

    func testUptimeRollbackIsComparedWithTheLastObservationNotOnlyLastProgress() {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertTrue(observe(&policy, at: 700))
        policy.markReceiptRequested(key: "attempt", uptime: 700)
        XCTAssertFalse(observe(&policy, at: 690, now: start.addingTimeInterval(710)))
        XCTAssertFalse(observe(&policy, at: 1_289))
        XCTAssertTrue(observe(&policy, at: 1_290))
        XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 1_290))
    }

    func testForwardWallClockJumpDoesNotAccelerateMonotonicEvidence() {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertFalse(observe(&policy, at: 200, now: start.addingTimeInterval(86_400)))
        XCTAssertFalse(observe(&policy, at: 699, now: start.addingTimeInterval(86_401)))
        XCTAssertTrue(observe(&policy, at: 700, now: start.addingTimeInterval(86_402)))
    }

    func testCancellationTombstoneSurvivesRestartAndDoesNotAffectANewAttempt() throws {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertTrue(observe(&policy, at: 700))
        policy.markCancellationRequested(key: "attempt")
        policy.retainOutstanding(keys: [])
        policy = try roundTrip(policy)
        XCTAssertTrue(policy.cancellationRequested(key: "attempt"))
        XCTAssertTrue(observe(&policy, at: 1_300))
        XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 1_300))
        XCTAssertFalse(observe(&policy, at: 1_300, key: "new-attempt"))
        XCTAssertTrue(observe(&policy, at: 1_900, key: "new-attempt"))
        XCTAssertFalse(policy.cancellationRequested(key: "new-attempt"))
    }

    func testCrashAfterCancellationIntentCanRetryOnlyAfterANewExactReceiptQuery() throws {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertTrue(observe(&policy, at: 700))
        policy.markReceiptRequested(key: "attempt", uptime: 700)
        XCTAssertTrue(observe(&policy, at: 760))
        XCTAssertTrue(policy.canRecover(key: "attempt", uptime: 760))
        policy.markCancellationRequested(key: "attempt")
        XCTAssertFalse(observe(&policy, at: 1_360))
        policy = try roundTrip(policy)
        policy.retainOutstanding(keys: ["attempt"])
        XCTAssertTrue(observe(&policy, at: 1_360))
        XCTAssertTrue(policy.cancellationRequested(key: "attempt"))
        XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 1_360))
        policy.markReceiptRequested(key: "attempt", uptime: 1_360)
        XCTAssertTrue(observe(&policy, at: 1_420))
        XCTAssertTrue(policy.canRecover(key: "attempt", uptime: 1_420))
        policy.markCancellationRequested(key: "attempt")
        XCTAssertFalse(observe(&policy, at: 2_020))
    }

    func testRemovedCancellationTombstonesYieldToNewOutstandingAttemptsAtTheBound() {
        var policy = OutstandingFileTransferPolicy(maximumObservationCount: 2)
        XCTAssertFalse(observe(&policy, at: 100, key: "old"))
        policy.markCancellationRequested(key: "old")
        XCTAssertFalse(observe(&policy, at: 100, key: "active"))
        policy.markCancellationRequested(key: "active")
        policy.retainOutstanding(keys: ["active", "new"])
        XCTAssertFalse(observe(&policy, at: 200, key: "new"))
        XCTAssertEqual(policy.observationCount, 2)
        XCTAssertFalse(policy.cancellationRequested(key: "old"))
        XCTAssertTrue(policy.cancellationRequested(key: "active"))
    }

    func testActiveCancellationTombstonesCannotBeEvictedToAdmitMoreObservations() {
        var policy = OutstandingFileTransferPolicy(maximumObservationCount: 1)
        XCTAssertFalse(observe(&policy, at: 100))
        policy.markCancellationRequested(key: "attempt")
        policy.retainOutstanding(keys: ["attempt", "new"])
        XCTAssertFalse(observe(&policy, at: 200, key: "new"))
        XCTAssertFalse(observe(&policy, at: 10_000, key: "new"))
        XCTAssertEqual(policy.observationCount, 1)
        XCTAssertTrue(policy.cancellationRequested(key: "attempt"))
    }

    func testOneHundredAttemptsRemainBoundedAndCannotBorrowEachOthersObservation() throws {
        var policy = OutstandingFileTransferPolicy()
        for index in 0..<100 { XCTAssertFalse(observe(&policy, at: 100, key: "attempt-\(index)")) }
        XCTAssertEqual(policy.observationCount, 64)
        policy = try roundTrip(policy)
        for index in 0..<100 {
            XCTAssertEqual(observe(&policy, at: 700, key: "attempt-\(index)"), index < 64)
        }
        policy.retainOutstanding(keys: ["attempt-99"])
        XCTAssertFalse(observe(&policy, at: 701, key: "attempt-99"))
        XCTAssertTrue(observe(&policy, at: 1_301, key: "attempt-99"))
        XCTAssertEqual(policy.observationCount, 1)
    }

    func testFailedSourceVerificationDefersBothRecoveryAndAnotherReceiptQuery() throws {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertTrue(observe(&policy, at: 700))
        policy.markReceiptRequested(key: "attempt", uptime: 700)
        policy.deferRecovery(key: "attempt", uptime: 760)
        policy = try roundTrip(policy)
        XCTAssertFalse(observe(&policy, at: 1_359))
        XCTAssertTrue(observe(&policy, at: 1_360))
        XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 1_360))
    }

    func testInvalidClockObservationResetsEvidenceAcrossRestart() throws {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertTrue(observe(&policy, at: 700))
        policy.markReceiptRequested(key: "attempt", uptime: 700)
        XCTAssertFalse(observe(&policy, at: .nan))
        policy = try roundTrip(policy)
        XCTAssertFalse(observe(&policy, at: 1_000))
        XCTAssertFalse(observe(&policy, at: 1_599))
        XCTAssertTrue(observe(&policy, at: 1_600))
        XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 1_600))
    }

    func testReconfiguringRestoredThresholdCannotReuseAnOldReceiptRequest() throws {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertTrue(observe(&policy, at: 700))
        policy.markReceiptRequested(key: "attempt", uptime: 700)
        policy = try roundTrip(policy)
        policy.reconfigure(minimumIdle: 5)
        policy = try roundTrip(policy)
        XCTAssertEqual(policy.idleThreshold, 5)
        XCTAssertFalse(observe(&policy, at: 1_000))
        XCTAssertFalse(observe(&policy, at: 1_004))
        XCTAssertTrue(observe(&policy, at: 1_005))
        XCTAssertFalse(policy.canRecover(key: "attempt", uptime: 1_005))
    }

    func testUnchangedConfigurationPreservesObservationAndGrace() throws {
        var policy = OutstandingFileTransferPolicy(minimumIdle: 5)
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertTrue(observe(&policy, at: 105))
        policy.markReceiptRequested(key: "attempt", uptime: 105)
        policy = try roundTrip(policy)
        policy.reconfigure(minimumIdle: 5)
        XCTAssertTrue(observe(&policy, at: 165))
        XCTAssertTrue(policy.canRecover(key: "attempt", uptime: 165))
    }

    func testInvalidPersistedBoundsAreRejectedInsteadOfSilentlyDroppingEvidence() throws {
        let data = try JSONEncoder().encode(OutstandingFileTransferPolicy())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["observationLimit"] = 65
        XCTAssertThrowsError(try JSONDecoder().decode(OutstandingFileTransferPolicy.self,
                            from: JSONSerialization.data(withJSONObject: json)))
        json["observationLimit"] = 64
        json["idleThreshold"] = -1
        XCTAssertThrowsError(try JSONDecoder().decode(OutstandingFileTransferPolicy.self,
                            from: JSONSerialization.data(withJSONObject: json)))
    }

    func testInvalidPersistedTimelineCannotManufactureIdleOrReceiptEvidence() throws {
        var policy = OutstandingFileTransferPolicy()
        XCTAssertFalse(observe(&policy, at: 100))
        XCTAssertTrue(observe(&policy, at: 700))
        policy.markReceiptRequested(key: "attempt", uptime: 700)
        let data = try JSONEncoder().encode(policy)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var observations = try XCTUnwrap(json["observations"] as? [String: [String: Any]])
        observations["attempt"]?["lastProgressUptime"] = 800
        json["observations"] = observations
        XCTAssertThrowsError(try JSONDecoder().decode(OutstandingFileTransferPolicy.self,
                            from: JSONSerialization.data(withJSONObject: json)))
        observations["attempt"]?["lastProgressUptime"] = 100
        observations["attempt"]?["receiptRequestedUptime"] = 99
        json["observations"] = observations
        XCTAssertThrowsError(try JSONDecoder().decode(OutstandingFileTransferPolicy.self,
                            from: JSONSerialization.data(withJSONObject: json)))
    }

    private func roundTrip(_ policy: OutstandingFileTransferPolicy) throws -> OutstandingFileTransferPolicy {
        try JSONDecoder().decode(OutstandingFileTransferPolicy.self, from: JSONEncoder().encode(policy))
    }

    private func observe(_ policy: inout OutstandingFileTransferPolicy, at uptime: TimeInterval,
                         queued: Date? = nil, completed: Int64 = 0, total: Int64 = 100,
                         isTransferring: Bool = false, key: String = "attempt", now: Date? = nil,
                         continuityID: String? = "boot-A") -> Bool {
        policy.observe(key: key, enqueuedAt: queued, completed: completed, total: total,
                       isTransferring: isTransferring, now: now ?? start.addingTimeInterval(uptime),
                       uptime: uptime, continuityID: continuityID)
    }
}
