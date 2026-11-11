import XCTest
@testable import RecordingCore

final class WatchTransferHandoffPolicyTests: XCTestCase {
    private let mib: Int64 = 1_024 * 1_024
    private let charging = WatchTransferHandoffPolicy(isCharging: true)

    func testChargingAndBatteryHaveSeparateFileCountCaps() {
        XCTAssertEqual(charging.maximumOutstandingFiles, 12)
        XCTAssertEqual(WatchTransferHandoffPolicy(isCharging: false).maximumOutstandingFiles, 3)
        XCTAssertEqual(charging.maximumQueuedBytes, 192 * mib)
        XCTAssertEqual(charging.maximumPassDuration, 2)
        XCTAssertTrue(charging.permits(candidateBytes: mib, outstandingBytes: Array(repeating: mib, count: 11),
            elapsed: 0, availableCapacity: 64 * mib))
        XCTAssertFalse(charging.permits(candidateBytes: mib, outstandingBytes: Array(repeating: mib, count: 12),
            elapsed: 0, availableCapacity: 64 * mib))
        let battery = WatchTransferHandoffPolicy(isCharging: false)
        XCTAssertTrue(battery.permits(candidateBytes: mib, outstandingBytes: [mib, mib],
            elapsed: 0, availableCapacity: 64 * mib))
        XCTAssertFalse(battery.permits(candidateBytes: mib, outstandingBytes: [mib, mib, mib],
            elapsed: 0, availableCapacity: 64 * mib))
    }

    func testChargingAdmitsTwelveMinutePCMSegmentsAndBatteryRemainsBounded() {
        let segment: Int64 = 11_524_096
        for count in 0..<12 {
            XCTAssertTrue(charging.permits(candidateBytes: segment,
                outstandingBytes: Array(repeating: segment, count: count),
                elapsed: 0, availableCapacity: 512 * mib))
        }
        XCTAssertEqual(charging.decision(candidateBytes: segment,
            outstandingBytes: Array(repeating: segment, count: 12),
            elapsed: 0, availableCapacity: 512 * mib), .nativeCount)
        let battery = WatchTransferHandoffPolicy(isCharging: false)
        XCTAssertEqual(battery.maximumQueuedBytes, 64 * mib)
        XCTAssertEqual(battery.decision(candidateBytes: segment,
            outstandingBytes: Array(repeating: segment, count: 3),
            elapsed: 0, availableCapacity: 512 * mib), .nativeCount)
        XCTAssertEqual(charging.decision(candidateBytes: segment, outstandingBytes: [],
            elapsed: 0, availableCapacity: 20 * mib), .capacityReserve)
    }

    func testTimeBudgetRejectsInvalidAndExactDeadline() {
        for elapsed in [TimeInterval.nan, .infinity, -.infinity, -0.001, 2, 2.001] {
            XCTAssertFalse(charging.permits(candidateBytes: mib, outstandingBytes: [],
                elapsed: elapsed, availableCapacity: 64 * mib))
        }
        for elapsed in [0, 1.999999] {
            XCTAssertTrue(charging.permits(candidateBytes: mib, outstandingBytes: [],
                elapsed: elapsed, availableCapacity: 64 * mib))
        }
    }

    func testUnknownOrInvalidFileByteCountsFailClosed() {
        for candidate in [Int64.min, -1, 0] {
            XCTAssertFalse(charging.permits(candidateBytes: candidate, outstandingBytes: [],
                elapsed: 0, availableCapacity: 64 * mib))
        }
        for invalid in [nil, Int64.min, -1, 0] as [Int64?] {
            XCTAssertFalse(charging.permits(candidateBytes: mib, outstandingBytes: [mib, invalid],
                elapsed: 0, availableCapacity: 64 * mib))
        }
    }

    func testCapacityRequiresKnownReserveAndDoubleCandidateBytes() {
        for available in [nil, Int64.min, -1, 0, 32 * mib - 1] as [Int64?] {
            XCTAssertFalse(charging.permits(candidateBytes: mib, outstandingBytes: [],
                elapsed: 0, availableCapacity: available))
        }
        XCTAssertTrue(charging.permits(candidateBytes: mib, outstandingBytes: [],
            elapsed: 0, availableCapacity: 32 * mib))
        XCTAssertTrue(charging.permits(candidateBytes: 16 * mib, outstandingBytes: [],
            elapsed: 0, availableCapacity: 32 * mib))
        XCTAssertFalse(charging.permits(candidateBytes: 16 * mib + 1, outstandingBytes: [],
            elapsed: 0, availableCapacity: 32 * mib + 1))
        XCTAssertTrue(charging.permits(candidateBytes: 16 * mib + 1, outstandingBytes: [],
            elapsed: 0, availableCapacity: 32 * mib + 2))
    }

    func testAggregateBudgetAllowsExactBoundaryButRejectsOneByteOver() {
        XCTAssertTrue(charging.permits(candidateBytes: 16 * mib, outstandingBytes: [80 * mib, 96 * mib],
            elapsed: 0, availableCapacity: 128 * mib))
        XCTAssertFalse(charging.permits(candidateBytes: 16 * mib + 1, outstandingBytes: [80 * mib, 96 * mib],
            elapsed: 0, availableCapacity: 128 * mib))
        XCTAssertFalse(charging.permits(candidateBytes: 1, outstandingBytes: [192 * mib],
            elapsed: 0, availableCapacity: 128 * mib))
    }

    func testOneOversizedFileCanUseAnEmptyQueueOnlyWithEnoughSpace() {
        let oversized = 192 * mib + 1
        XCTAssertTrue(charging.permits(candidateBytes: oversized, outstandingBytes: [],
            elapsed: 1.9, availableCapacity: oversized * 2))
        XCTAssertFalse(charging.permits(candidateBytes: oversized, outstandingBytes: [],
            elapsed: 0, availableCapacity: oversized * 2 - 1))
        XCTAssertFalse(charging.permits(candidateBytes: oversized, outstandingBytes: [1],
            elapsed: 0, availableCapacity: oversized * 2))
        XCTAssertFalse(charging.permits(candidateBytes: 1, outstandingBytes: [oversized],
            elapsed: 0, availableCapacity: oversized * 2))
    }

    func testArithmeticOverflowFailsClosed() {
        XCTAssertFalse(charging.permits(candidateBytes: Int64.max, outstandingBytes: [],
            elapsed: 0, availableCapacity: Int64.max))
        XCTAssertFalse(charging.permits(candidateBytes: Int64.max / 2 + 1, outstandingBytes: [],
            elapsed: 0, availableCapacity: Int64.max))
        XCTAssertFalse(charging.permits(candidateBytes: 1, outstandingBytes: [Int64.max, 1],
            elapsed: 0, availableCapacity: Int64.max))
        XCTAssertFalse(charging.permits(candidateBytes: 1, outstandingBytes: [Int64.max],
            elapsed: 0, availableCapacity: Int64.max))
    }

    func testCandidateRefusalsDoNotMeanEveryCandidateMustStop() {
        let oversized = charging.decision(candidateBytes: 17 * mib, outstandingBytes: [],
            elapsed: 0, availableCapacity: 32 * mib)
        XCTAssertEqual(oversized, .candidateCapacity)
        XCTAssertFalse(oversized.stopsPass)
        XCTAssertEqual(charging.decision(candidateBytes: mib, outstandingBytes: [],
            elapsed: 0, availableCapacity: 32 * mib), .allowed)
        let aggregate = charging.decision(candidateBytes: 17 * mib, outstandingBytes: [176 * mib],
            elapsed: 0, availableCapacity: 128 * mib)
        XCTAssertEqual(aggregate, .queuedBytes)
        XCTAssertFalse(aggregate.stopsPass)
        XCTAssertEqual(charging.decision(candidateBytes: mib, outstandingBytes: [176 * mib],
            elapsed: 0, availableCapacity: 128 * mib), .allowed)
    }

    func testGlobalLimitsKeepTheirExactStoppingMeaning() {
        let checks: [(WatchTransferHandoffPolicy.Decision, WatchTransferHandoffPolicy.Decision)] = [
            (charging.decision(candidateBytes: mib, outstandingBytes: [], elapsed: 2, availableCapacity: 64 * mib), .deadline),
            (charging.decision(candidateBytes: mib, outstandingBytes: Array(repeating: mib, count: 12), elapsed: 0, availableCapacity: 64 * mib), .nativeCount),
            (charging.decision(candidateBytes: mib, outstandingBytes: [], elapsed: 0, availableCapacity: nil), .capacityUnknown),
            (charging.decision(candidateBytes: mib, outstandingBytes: [], elapsed: 0, availableCapacity: 32 * mib - 1), .capacityReserve),
            (charging.decision(candidateBytes: mib, outstandingBytes: [nil], elapsed: 0, availableCapacity: 64 * mib), .unknownQueuedBytes)
        ]
        for (actual, expected) in checks {
            XCTAssertEqual(actual, expected)
            XCTAssertTrue(actual.stopsPass)
        }
        XCTAssertFalse(WatchTransferHandoffPolicy.Decision.allowed.stopsPass)
    }
}
