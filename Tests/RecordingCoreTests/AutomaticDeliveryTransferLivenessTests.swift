import XCTest
@testable import RecordingCore

final class AutomaticDeliveryTransferLivenessTests: XCTestCase {
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    func testRetainedTaskWithNoBytesIsReclaimedAfterStartWindow() {
        let id = UUID(), task = AutomaticDeliveryTransferProgress(deliveryID: UUID(), bytesSent: 0, bytesReceived: 0)
        var policy = AutomaticDeliveryTransferLiveness()
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: [task], registeredAt: [task.deliveryID: epoch],
            now: epoch.addingTimeInterval(599)), [])
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: [task], registeredAt: [task.deliveryID: epoch],
            now: epoch.addingTimeInterval(600)), [task.deliveryID])
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: [task], registeredAt: [task.deliveryID: epoch],
            now: epoch.addingTimeInterval(900)), [], "Do not repeatedly cancel the same task")
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: [.init(deliveryID: id, bytesSent: 0, bytesReceived: 0)],
            registeredAt: [:], now: epoch.addingTimeInterval(900)), [], "Unknown tasks do not inherit another job's age")
    }

    func testProgressingUploadAndResponseRenewLiveness() {
        let id = UUID()
        var policy = AutomaticDeliveryTransferLiveness()
        func progress(_ sent: Int64, _ received: Int64 = 0) -> [AutomaticDeliveryTransferProgress] {
            [.init(deliveryID: id, bytesSent: sent, bytesReceived: received)]
        }
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: progress(1), registeredAt: [id: epoch], now: epoch), [])
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: progress(500), registeredAt: [id: epoch],
            now: epoch.addingTimeInterval(119)), [])
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: progress(500, 10), registeredAt: [id: epoch],
            now: epoch.addingTimeInterval(238)), [])
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: progress(500, 10), registeredAt: [id: epoch],
            now: epoch.addingTimeInterval(357)), [])
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: progress(500, 10), registeredAt: [id: epoch],
            now: epoch.addingTimeInterval(358)), [id])
    }

    func testRestoredTaskWithExistingBytesGetsFreshProgressWindow() {
        let id = UUID(), old = epoch.addingTimeInterval(-20 * 60)
        let task = AutomaticDeliveryTransferProgress(deliveryID: id, bytesSent: 100, bytesReceived: 0)
        var policy = AutomaticDeliveryTransferLiveness()
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: [task], registeredAt: [id: old], now: epoch), [])
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: [task], registeredAt: [id: old],
            now: epoch.addingTimeInterval(120)), [id])
    }

    func testRetryWithSameIDStartsFreshAndClockRollbackDoesNotCancel() {
        let id = UUID(), task = AutomaticDeliveryTransferProgress(deliveryID: id, bytesSent: 0, bytesReceived: 0)
        var policy = AutomaticDeliveryTransferLiveness()
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: [task], registeredAt: [id: epoch],
            now: epoch.addingTimeInterval(600)), [id])
        policy.forget(id)
        let retry = epoch.addingTimeInterval(615)
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: [task], registeredAt: [id: retry], now: retry), [])
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: [task], registeredAt: [id: retry], now: epoch), [])
    }

    func testOneStalledTransferDoesNotCancelAnotherOrForgetAbsentTask() {
        let a = UUID(), b = UUID()
        var policy = AutomaticDeliveryTransferLiveness()
        let tasks = [AutomaticDeliveryTransferProgress(deliveryID: a, bytesSent: 0, bytesReceived: 0),
                     AutomaticDeliveryTransferProgress(deliveryID: b, bytesSent: 10, bytesReceived: 0)]
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: tasks, registeredAt: [a: epoch, b: epoch],
            now: epoch.addingTimeInterval(600)), [a])
        _ = policy.stalledDeliveryIDs(transfers: [], registeredAt: [:], now: epoch.addingTimeInterval(601))
        XCTAssertEqual(policy.stalledDeliveryIDs(transfers: [tasks[0]], registeredAt: [a: epoch.addingTimeInterval(602)],
            now: epoch.addingTimeInterval(602)), [])
    }
}
