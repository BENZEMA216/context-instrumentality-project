import XCTest
@testable import RecordingCore

/// Synthetic decisions for P-42, P-43, and P-44. No device, audio, or credential.
final class ConfirmedReviewFollowUpTests: XCTestCase {
    func testChargingInspectsEveryDurableAckDuplicateWhileBatteryRotatesThree() {
        let charging = WatchBackgroundTransferPolicy(isCharging: true)
        XCTAssertEqual(charging.acknowledgedDuplicateInspectionCount(outstanding: 12, maintenanceAllowed: false), 12)
        XCTAssertEqual(charging.acknowledgedDuplicateInspectionCount(outstanding: 1, maintenanceAllowed: false), 1)
        let battery = WatchBackgroundTransferPolicy()
        XCTAssertEqual(battery.acknowledgedDuplicateInspectionCount(outstanding: 12, maintenanceAllowed: false), 3)
        XCTAssertEqual(battery.acknowledgedDuplicateInspectionCount(outstanding: 2, maintenanceAllowed: false), 2)
        XCTAssertEqual(battery.acknowledgedDuplicateInspectionCount(outstanding: 12, maintenanceAllowed: true), 12)
        XCTAssertEqual(battery.acknowledgedDuplicateInspectionCount(outstanding: 0, maintenanceAllowed: false), 0)
    }

    func testEventsAndReceiptRequestsLeaveEachOtherAUserInfoSlot() {
        XCTAssertTrue(WatchUserInfoScheduling.admitsEvent(events: 0, receiptRequests: 2, others: 0))
        XCTAssertFalse(WatchUserInfoScheduling.admitsReceiptRequest(events: 0, receiptRequests: 2, others: 0))
        XCTAssertTrue(WatchUserInfoScheduling.admitsReceiptRequest(events: 2, receiptRequests: 0, others: 0))
        XCTAssertFalse(WatchUserInfoScheduling.admitsEvent(events: 2, receiptRequests: 0, others: 0))
        XCTAssertTrue(WatchUserInfoScheduling.admitsEvent(events: 0, receiptRequests: 0, others: 0))
        XCTAssertTrue(WatchUserInfoScheduling.admitsReceiptRequest(events: 0, receiptRequests: 0, others: 0))
        XCTAssertFalse(WatchUserInfoScheduling.admitsEvent(events: 1, receiptRequests: 2, others: 0))
        XCTAssertFalse(WatchUserInfoScheduling.admitsReceiptRequest(events: 2, receiptRequests: 1, others: 0))
        XCTAssertFalse(WatchUserInfoScheduling.admitsEvent(events: 0, receiptRequests: 0, others: 3))
        XCTAssertFalse(WatchUserInfoScheduling.admitsReceiptRequest(events: 0, receiptRequests: 0, others: 3))
        XCTAssertFalse(WatchUserInfoScheduling.admitsReceiptRequest(events: -1, receiptRequests: 0, others: 0))
    }

    func testExpiredResumableStatusClearsTheAudioTurnWithoutBecomingAReceipt() {
        XCTAssertEqual(GoogleDriveResumableReadBack.classify(status: 200), .needsMetadata)
        XCTAssertEqual(GoogleDriveResumableReadBack.classify(status: 201), .needsMetadata)
        XCTAssertEqual(GoogleDriveResumableReadBack.classify(status: 308), .pending)
        XCTAssertEqual(GoogleDriveResumableReadBack.classify(status: 404), .sessionExpired)
        XCTAssertEqual(GoogleDriveResumableReadBack.classify(status: 410), .sessionExpired)
        XCTAssertEqual(GoogleDriveAudioTurn.preparedSessionIndex([true, false]), 0)
        XCTAssertEqual(GoogleDriveAudioTurn.preparedSessionIndex([false, true]), 1)
        XCTAssertNil(GoogleDriveAudioTurn.preparedSessionIndex([false, false]))
        XCTAssertNil(GoogleDriveAudioTurn.preparedSessionIndex([]))
    }

    func testPreemptionScanIncludesTasksBehindTheFirstThree() {
        let outstanding = Array(0..<8)
        let scanned = WatchPreemptionScan.candidates(outstanding)
        XCTAssertEqual(scanned, outstanding)
        XCTAssertEqual(scanned.last, 7)
    }
}
