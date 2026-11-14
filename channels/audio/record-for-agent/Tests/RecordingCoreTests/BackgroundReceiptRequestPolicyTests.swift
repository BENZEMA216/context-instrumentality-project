import XCTest
@testable import RecordingCore

final class BackgroundReceiptRequestPolicyTests: XCTestCase {
    func testReceiptReplayNeedsPendingAudioAndNoOutstandingRequest() {
        var policy = BackgroundReceiptRequestPolicy()
        XCTAssertFalse(policy.beginBackgroundRequest(hasPendingSegments: false, alreadyQueued: false, uptime: 100))
        XCTAssertFalse(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: true, uptime: 100))
        XCTAssertTrue(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: false, uptime: 100))
    }

    func testRequestsAreBoundedEvenWhenSystemCompletionArrivesImmediately() {
        var policy = BackgroundReceiptRequestPolicy()
        XCTAssertTrue(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: false, uptime: 100))
        for second in 101..<400 {
            XCTAssertFalse(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: false,
                                                        uptime: TimeInterval(second)))
        }
        XCTAssertTrue(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: false, uptime: 400))
        XCTAssertFalse(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: true, uptime: 1_000))
        XCTAssertTrue(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: false, uptime: 1_000))
    }

    func testUptimeRollbackReanchorsAndStillRequiresCooldown() {
        var policy = BackgroundReceiptRequestPolicy()
        XCTAssertTrue(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: false, uptime: 1_000))
        XCTAssertFalse(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: false, uptime: 10))
        XCTAssertFalse(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: false, uptime: 309))
        XCTAssertTrue(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: false, uptime: 310))
    }

    func testQueuedBackgroundRequestDoesNotBlockActivatedImmediateOpportunity() {
        var policy = BackgroundReceiptRequestPolicy()
        XCTAssertTrue(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: false, uptime: 100))
        XCTAssertFalse(policy.beginImmediateRequest(hasPendingSegments: true, activated: false, reachable: true, uptime: 100))
        XCTAssertFalse(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: true, uptime: 101))
        XCTAssertTrue(policy.beginImmediateRequest(hasPendingSegments: true, activated: true, reachable: true, uptime: 101))
        // The system queue can remain unchanged beyond both cooldowns.
        XCTAssertFalse(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: true, uptime: 401))
        XCTAssertTrue(policy.beginImmediateRequest(hasPendingSegments: true, activated: true, reachable: true, uptime: 401))
    }

    func testInactiveAndNoPendingChecksDoNotConsumeImmediateOpportunity() {
        var policy = BackgroundReceiptRequestPolicy()
        for second in 100..<400 {
            XCTAssertFalse(policy.beginImmediateRequest(hasPendingSegments: true, activated: false,
                                                       reachable: true, uptime: TimeInterval(second)))
            XCTAssertFalse(policy.beginImmediateRequest(hasPendingSegments: false, activated: true,
                                                       reachable: true, uptime: TimeInterval(second)))
        }
        XCTAssertTrue(policy.beginImmediateRequest(hasPendingSegments: true, activated: true, reachable: true, uptime: 400))
        XCTAssertFalse(policy.beginImmediateRequest(hasPendingSegments: true, activated: false, reachable: true, uptime: 700))
        XCTAssertTrue(policy.beginImmediateRequest(hasPendingSegments: true, activated: true, reachable: true, uptime: 701))
    }

    func testUnreachableCheckDoesNotStartTheImmediateCooldown() {
        var policy = BackgroundReceiptRequestPolicy()
        for second in 100..<400 {
            XCTAssertFalse(policy.beginImmediateRequest(hasPendingSegments: true, activated: true,
                reachable: false, uptime: TimeInterval(second)))
        }
        XCTAssertTrue(policy.beginImmediateRequest(hasPendingSegments: true, activated: true,
            reachable: true, uptime: 100))
        XCTAssertFalse(policy.beginImmediateRequest(hasPendingSegments: true, activated: true,
            reachable: false, uptime: 101))
        XCTAssertFalse(policy.beginImmediateRequest(hasPendingSegments: true, activated: true,
            reachable: true, uptime: 399))
        XCTAssertTrue(policy.beginImmediateRequest(hasPendingSegments: true, activated: true,
            reachable: true, uptime: 400))
    }

    func testFrequentSyncChecksCannotCreateImmediateStormAfterARealSend() {
        var policy = BackgroundReceiptRequestPolicy()
        // A message handed to the session consumes the cooldown whether the
        // later transport reply succeeds or fails. An unreachable skip does not.
        XCTAssertTrue(policy.beginImmediateRequest(hasPendingSegments: true, activated: true, reachable: true, uptime: 100))
        for second in 101..<400 {
            XCTAssertFalse(policy.beginImmediateRequest(hasPendingSegments: true, activated: true,
                                                       reachable: true, uptime: TimeInterval(second)))
        }
        XCTAssertTrue(policy.beginImmediateRequest(hasPendingSegments: true, activated: true, reachable: true, uptime: 400))
        XCTAssertFalse(policy.beginImmediateRequest(hasPendingSegments: true, activated: true, reachable: true, uptime: 400))
    }

    func testImmediateAttemptDoesNotConsumeBackgroundRequestCooldown() {
        var policy = BackgroundReceiptRequestPolicy()
        XCTAssertTrue(policy.beginImmediateRequest(hasPendingSegments: true, activated: true, reachable: true, uptime: 100))
        XCTAssertTrue(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: false, uptime: 101))
        XCTAssertFalse(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: false, uptime: 400))
        XCTAssertTrue(policy.beginBackgroundRequest(hasPendingSegments: true, alreadyQueued: false, uptime: 401))
    }

    func testImmediateUptimeRollbackReanchorsWithoutBypassingItsCooldown() {
        var policy = BackgroundReceiptRequestPolicy()
        XCTAssertTrue(policy.beginImmediateRequest(hasPendingSegments: true, activated: true, reachable: true, uptime: 1_000))
        XCTAssertFalse(policy.beginImmediateRequest(hasPendingSegments: true, activated: true, reachable: true, uptime: 10))
        XCTAssertFalse(policy.beginImmediateRequest(hasPendingSegments: true, activated: true, reachable: true, uptime: 309))
        XCTAssertTrue(policy.beginImmediateRequest(hasPendingSegments: true, activated: true, reachable: true, uptime: 310))
    }
}
