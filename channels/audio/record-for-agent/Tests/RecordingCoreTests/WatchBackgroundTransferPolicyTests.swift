import XCTest
@testable import RecordingCore

final class WatchBackgroundTransferPolicyTests: XCTestCase {
    func testChargingHistoryBringsForwardFutureRefreshAndKeepsAcceptedDueRequest() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(WatchBackgroundTransferPolicy.preferredRefreshDate(existing: nil,
            isCharging: true, now: now), now.addingTimeInterval(60))
        XCTAssertEqual(WatchBackgroundTransferPolicy.preferredRefreshDate(existing: now.addingTimeInterval(900),
            confirmedDuringThisProcess: true, isCharging: true, now: now), now.addingTimeInterval(60))
        let due = now.addingTimeInterval(-30)
        XCTAssertEqual(WatchBackgroundTransferPolicy.preferredRefreshDate(existing: due,
            confirmedDuringThisProcess: true, isCharging: true, now: now), due)
        let accepted = now.addingTimeInterval(20)
        XCTAssertEqual(WatchBackgroundTransferPolicy.preferredRefreshDate(existing: accepted,
            isCharging: true, now: now), accepted)
        XCTAssertEqual(WatchBackgroundTransferPolicy.preferredRefreshDate(existing: accepted,
            isCharging: false, now: now), accepted)
    }

    func testSealedBacklogBringsForwardLongRefreshWithoutPostponingAcceptedDueWork() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let urgent = now.addingTimeInterval(60)
        XCTAssertEqual(WatchBackgroundTransferPolicy.preferredRefreshDate(
            existing: now.addingTimeInterval(900), confirmedDuringThisProcess: true,
            sealedBacklog: true, now: now), urgent)
        XCTAssertEqual(WatchBackgroundTransferPolicy.preferredRefreshDate(
            existing: urgent, confirmedDuringThisProcess: true,
            sealedBacklog: true, now: now.addingTimeInterval(30)), urgent)
        XCTAssertEqual(WatchBackgroundTransferPolicy.preferredRefreshDate(
            existing: urgent, confirmedDuringThisProcess: true,
            sealedBacklog: true, now: now.addingTimeInterval(90)), urgent)
        XCTAssertEqual(WatchBackgroundTransferPolicy.preferredRefreshDate(
            existing: nil, sealedBacklog: true, now: now), urgent)
    }

    func testClosedBacklogKeepsTwelveNativeSlotsOnBatteryWithoutReplenishingConsumedWork() {
        let policy = WatchBackgroundTransferPolicy(sealedBacklog: true)
        XCTAssertEqual(policy.maximumOutstandingFiles, 12)
        XCTAssertEqual(policy.maximumCandidateChecks, 64)
        XCTAssertEqual(policy.remainingEnqueues(consumed: 11), 1)
        XCTAssertEqual(policy.remainingEnqueues(consumed: 12), 0)
        let handoff = WatchTransferHandoffPolicy(isCharging: false, sealedBacklog: true)
        XCTAssertEqual(handoff.maximumQueuedBytes, 192 * 1_024 * 1_024)
        XCTAssertEqual(handoff.maximumPassDuration, 2)
        XCTAssertFalse(handoff.permits(candidateBytes: 11 * 1_024 * 1_024,
            outstandingBytes: Array(repeating: 11 * 1_024 * 1_024, count: 12), elapsed: 0.1, availableCapacity: 1_000_000_000))
    }

    func testBatteryOpportunityHasOneSharedThreeFileBudget() {
        let policy = WatchBackgroundTransferPolicy()
        XCTAssertEqual(policy.maximumCandidateChecks, 8)
        XCTAssertEqual(policy.maximumOutstandingFiles, 3)
        XCTAssertEqual(policy.remainingEnqueues(consumed: 0), 3)
        XCTAssertEqual(policy.remainingEnqueues(consumed: 1), 2)
        XCTAssertEqual(policy.remainingEnqueues(consumed: 3), 0)
        XCTAssertEqual(policy.remainingEnqueues(consumed: 12), 0)
    }

    func testChargingPrequeuesTwelveWithoutRequiringTransportCallbacks() {
        let policy = WatchBackgroundTransferPolicy(isCharging: true)
        XCTAssertEqual(policy.maximumOutstandingFiles, 12)
        XCTAssertEqual(policy.remainingEnqueues(consumed: 3), 9)
        XCTAssertEqual(policy.remainingEnqueues(consumed: 12), 0)
        XCTAssertEqual(policy.remainingCandidateChecks(consumed: 64), 0)
    }

    func testUnpluggingClampsConsumedBudgetAndRepeatedSamplesDoNotResetIt() {
        let battery = WatchBackgroundTransferPolicy()
        for _ in 0..<30 {
            XCTAssertEqual(battery.remainingEnqueues(consumed: 3), 0)
            XCTAssertEqual(battery.remainingCandidateChecks(consumed: 12), 0)
            XCTAssertEqual(battery.maximumOutstandingFiles, 3)
        }
        XCTAssertEqual(WatchBackgroundTransferPolicy(isCharging: true).remainingEnqueues(consumed: 3), 9)
    }

    func testRestartPreservesFutureIntentAndRenewsOverdueIntentOnce() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let original = now.addingTimeInterval(400)
        XCTAssertEqual(WatchBackgroundTransferPolicy.preferredRefreshDate(existing: original, now: now), original)
        let renewed = WatchBackgroundTransferPolicy.preferredRefreshDate(existing: now.addingTimeInterval(-1), now: now)
        XCTAssertEqual(renewed, now.addingTimeInterval(900))
        XCTAssertEqual(WatchBackgroundTransferPolicy.preferredRefreshDate(existing: renewed, now: now.addingTimeInterval(20)), renewed)
        let alreadyDue = now.addingTimeInterval(-30)
        XCTAssertEqual(WatchBackgroundTransferPolicy.preferredRefreshDate(existing: alreadyDue,
            confirmedDuringThisProcess: true, now: now), alreadyDue)
    }

    func testForegroundExitDoesNotCreateAnIntentWhenNoneExists() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(WatchBackgroundTransferPolicy.shouldRenewRefreshAfterForegroundExit(
            preferredDate: nil, now: now))
    }

    func testForegroundExitPreservesFutureIntent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(WatchBackgroundTransferPolicy.shouldRenewRefreshAfterForegroundExit(
            preferredDate: now.addingTimeInterval(1), now: now))
    }

    func testForegroundExitRenewsIntentExactlyAtItsPreferredDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(WatchBackgroundTransferPolicy.shouldRenewRefreshAfterForegroundExit(
            preferredDate: now, now: now))
    }

    func testForegroundExitRenewsOverdueIntent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(WatchBackgroundTransferPolicy.shouldRenewRefreshAfterForegroundExit(
            preferredDate: now.addingTimeInterval(-1), now: now))
    }

    func testForegroundExitRejectsNonfiniteIntentDates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for interval in [TimeInterval.nan, .infinity, -.infinity] {
            XCTAssertFalse(WatchBackgroundTransferPolicy.shouldRenewRefreshAfterForegroundExit(
                preferredDate: Date(timeIntervalSince1970: interval), now: now))
        }
    }
}
