import XCTest
@testable import RecordingCore

final class SegmentLocationPolicyTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func time(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }
    private func fix(_ offset: TimeInterval, accuracy: Double = 10, latitude: Double = 31) -> SegmentLocation {
        SegmentLocation(latitude: latitude, longitude: 121, horizontalAccuracy: accuracy, capturedAt: time(offset))
    }
    private func policy() -> SegmentLocationPolicy {
        var policy = SegmentLocationPolicy()
        policy.beginRecording(at: origin)
        return policy
    }

    func testLatestEligibleFixSurvivesNewerFixBeyondFinalAudioBoundary() {
        var policy = policy()
        policy.update(fix(59), receivedAt: time(59))
        policy.update(fix(61), receivedAt: time(62))
        policy.update(fix(55), receivedAt: time(62)) // Out-of-order arrival cannot replace the latest eligible fix.
        XCTAssertEqual(policy.sealSegment(startedAt: origin, endedAt: time(60)), fix(59))
        XCTAssertEqual(policy.sealSegment(startedAt: time(60), endedAt: time(90)), fix(61))
        XCTAssertEqual(policy.retainedFixCount, 0)
    }

    func testShortSegmentUsesOnlyItsActualAudioInterval() {
        var policy = policy()
        policy.update(fix(25), receivedAt: time(25))
        policy.update(fix(40), receivedAt: time(40))
        XCTAssertEqual(policy.sealSegment(startedAt: origin, endedAt: time(30)), fix(25))
    }

    func testPersistedMillisecondBoundariesAndAdjacentSegmentDoNotReusePoint() {
        for offset in [10.0, 20.0] {
            var policy = policy()
            policy.update(fix(offset), receivedAt: time(25))
            XCTAssertEqual(policy.sealSegment(startedAt: time(10), endedAt: time(20)), fix(offset))
            policy.update(fix(offset), receivedAt: time(25)) // Repeated late callback for a sealed boundary is ignored.
            XCTAssertNil(policy.sealSegment(startedAt: time(20), endedAt: time(30)))
        }
        for offset in [9.999, 20.001] {
            var policy = policy()
            policy.update(fix(offset), receivedAt: time(25))
            XCTAssertNil(policy.sealSegment(startedAt: time(10), endedAt: time(20)))
        }
    }

    func testNilClearsUnsealedPointsAndBlocksCallbacksCapturedBeforeClear() {
        var policy = policy()
        policy.update(fix(5), receivedAt: time(6))
        policy.update(nil, receivedAt: time(10))
        policy.update(fix(9), receivedAt: time(11))
        XCTAssertNil(policy.sealSegment(startedAt: origin, endedAt: time(15)))
        // A provider that has been explicitly re-enabled can supply a new fix.
        policy.update(fix(16), receivedAt: time(17))
        XCTAssertEqual(policy.sealSegment(startedAt: time(15), endedAt: time(20)), fix(16))
    }

    func testPrepareAndEndClearAllPreviousRunLocations() {
        var policy = policy()
        policy.update(fix(5), receivedAt: time(6))
        policy.beginRecording(at: time(10))
        policy.update(fix(9), receivedAt: time(11))
        XCTAssertNil(policy.sealSegment(startedAt: time(10), endedAt: time(12)))
        policy.update(fix(13), receivedAt: time(14))
        policy.endRecording()
        policy.update(fix(15), receivedAt: time(15))
        XCTAssertNil(policy.sealSegment(startedAt: time(12), endedAt: time(20)))
        policy.beginRecording(at: time(25))
        XCTAssertNil(policy.sealSegment(startedAt: time(25), endedAt: time(30)))
    }

    func testFutureFixAtCallbackTimeStaysRejectedWhenQueueExecutesLater() {
        var policy = policy()
        // Queue execution may be after t=30; the callback's original t=10 remains authoritative.
        policy.update(fix(20), receivedAt: time(10))
        XCTAssertNil(policy.sealSegment(startedAt: origin, endedAt: time(30)))
    }

    func testInvalidCoordinatesAccuracyAndOldTimestampAreIgnored() {
        let invalid = [fix(5, latitude: 91), fix(5, latitude: .nan), fix(5, accuracy: -1),
                       fix(5, accuracy: .infinity), fix(5, accuracy: 100001), fix(-1),
                       SegmentLocation(latitude: 0, longitude: 181, horizontalAccuracy: 1, capturedAt: time(5))]
        for location in invalid {
            var policy = policy()
            policy.update(location, receivedAt: time(10))
            XCTAssertNil(policy.sealSegment(startedAt: origin, endedAt: time(20)))
        }
    }

    func testCandidatesAreBoundedAndEqualTimestampPrefersBetterAccuracy() {
        var policy = policy()
        for index in 0..<1000 { policy.update(fix(Double(index)), receivedAt: time(1000)) }
        XCTAssertEqual(policy.retainedFixCount, SegmentLocationPolicy.maximumRetainedFixes)
        policy.update(fix(999, accuracy: 2), receivedAt: time(1000))
        policy.update(fix(999, accuracy: 50), receivedAt: time(1000))
        XCTAssertEqual(policy.retainedFixCount, SegmentLocationPolicy.maximumRetainedFixes)
        XCTAssertEqual(policy.sealSegment(startedAt: time(900), endedAt: time(1000)), fix(999, accuracy: 2))
    }
}
