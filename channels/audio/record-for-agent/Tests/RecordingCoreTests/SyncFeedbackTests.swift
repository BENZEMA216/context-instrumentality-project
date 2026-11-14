import XCTest
@testable import RecordingCore

final class SyncFeedbackTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testDeliveryReachabilityAndAnEmptyUnverifiedListCannotClaimCompletion() {
        var feedback = SyncFeedback()
        feedback.observe(pendingCount: 1, queuedCount: 0, transferringCount: 0,
                         awaitingConfirmationCount: 1, connectionReady: true, reachable: true,
                         hasSealedSegments: true, at: start)
        XCTAssertEqual(feedback.phase, .waitingForConfirmation)
        feedback.observe(pendingCount: 0, queuedCount: 0, transferringCount: 0,
                         connectionReady: true, reachable: true, hasSealedSegments: true, at: start)
        XCTAssertEqual(feedback.phase, .waitingForConfirmation)
        feedback.observe(pendingCount: 0, queuedCount: 0, transferringCount: 0,
                         connectionReady: false, reachable: false, hasSealedSegments: true,
                         allReceiptsVerified: true, at: start)
        XCTAssertEqual(feedback.phase, .completed)
    }

    func testNewAudioAndDuplicateReceiptsDoNotInventConfirmedProgress() {
        var feedback = SyncFeedback()
        feedback.observe(pendingCount: 10, queuedCount: 3, transferringCount: 1,
                         connectionReady: true, reachable: true, hasSealedSegments: true, at: start)
        let receiptID = UUID()
        feedback.recordVerifiedReceipt(id: receiptID, at: start)
        // A new segment replaced the acknowledged segment in the pending count.
        feedback.observe(pendingCount: 10, queuedCount: 3, transferringCount: 1,
                         connectionReady: true, reachable: true, hasSealedSegments: true, at: start)
        XCTAssertEqual(feedback.confirmedCount, 1)
        feedback.recordVerifiedReceipt(id: receiptID, at: start.addingTimeInterval(5))
        XCTAssertEqual(feedback.confirmedCount, 1)
        XCTAssertEqual(feedback.lastConfirmedAt, start)
        feedback.observe(pendingCount: 4, queuedCount: 3, transferringCount: 1,
                         connectionReady: true, reachable: true, hasSealedSegments: true, at: start)
        XCTAssertEqual(feedback.confirmedCount, 1)
        XCTAssertEqual(feedback.phase, .transferring)
    }

    func testFailureWinsOverZeroPendingAndClearsOnlyWithANewSuccessfulObservation() {
        var feedback = SyncFeedback()
        feedback.observe(pendingCount: 0, queuedCount: 0, transferringCount: 0,
                         connectionReady: true, reachable: true, hasSealedSegments: true,
                         allReceiptsVerified: true, failure: "receipt rejected", at: start)
        XCTAssertEqual(feedback.phase, .failed)
        XCTAssertEqual(feedback.message, "receipt rejected")
        feedback.observe(pendingCount: 2, queuedCount: 1, transferringCount: 0,
                         connectionReady: true, reachable: false, hasSealedSegments: true, at: start)
        XCTAssertEqual(feedback.phase, .queued)
        XCTAssertNil(feedback.message)
    }

    func testRepeatedTapIsBoundedAndDoesNotChangeRetryEvidence() {
        var feedback = SyncFeedback()
        let retry = start.addingTimeInterval(300)
        feedback.observe(pendingCount: 2, queuedCount: 0, transferringCount: 0,
                         connectionReady: true, reachable: true, hasSealedSegments: true,
                         retryAt: retry, at: start)
        XCTAssertEqual(feedback.phase, .retryScheduled)
        XCTAssertTrue(feedback.beginRequest(at: start))
        XCTAssertFalse(feedback.beginRequest(at: start.addingTimeInterval(1)))
        XCTAssertTrue(feedback.beginRequest(at: start.addingTimeInterval(1.5)))
        XCTAssertEqual(feedback.retryAt, retry)
        XCTAssertTrue(feedback.beginRequest(at: start.addingTimeInterval(-50)))
    }

    func testEmptyNewRepositoryIsIdleAndReadFailuresCannotReUseOldSuccess() {
        var feedback = SyncFeedback()
        feedback.observe(pendingCount: 0, queuedCount: 0, transferringCount: 0,
                         connectionReady: true, reachable: true, hasSealedSegments: false, at: start)
        XCTAssertEqual(feedback.phase, .idle)
        feedback.recordFailure("repository unavailable", at: start)
        XCTAssertEqual(feedback.phase, .failed)
        XCTAssertEqual(feedback.message, "repository unavailable")
    }
}
