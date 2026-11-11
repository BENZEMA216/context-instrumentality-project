import XCTest
@testable import RecordingCore

final class TransferDiagnosticsPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testConnectivityBeforeWriterLoadCannotPublishAnIdleSnapshot() {
        let state = TransferSnapshotState()
        // Pending files may already exist during activation or receipt handling.
        XCTAssertNil(state.applicationSnapshot(pendingCount: 163))
        XCTAssertNil(state.applicationSnapshot(pendingCount: 158))
    }

    func testPendingCountRefreshPreservesWriterEvidenceAndObservationTime() throws {
        var state = TransferSnapshotState()
        let writer = RecorderSnapshot(state: .recording, sessionID: UUID(), observedAt: start,
                                      lastAudioAt: start, lastSealedAt: start.addingTimeInterval(-10),
                                      pendingCount: 163, pendingCountIsKnown: false)
        state.receive(writer)
        let transferred = try XCTUnwrap(state.applicationSnapshot(pendingCount: 158))
        XCTAssertEqual(transferred.state, .recording)
        XCTAssertEqual(transferred.sessionID, writer.sessionID)
        XCTAssertEqual(transferred.observedAt, start)
        XCTAssertEqual(transferred.lastAudioAt, start)
        XCTAssertEqual(transferred.lastSealedAt, writer.lastSealedAt)
        XCTAssertEqual(transferred.pendingCount, 158)
        XCTAssertTrue(transferred.pendingCountIsKnown)
        XCTAssertFalse(state.latest!.pendingCountIsKnown)
        XCTAssertTrue(transferred.isStale(at: start.addingTimeInterval(61)))
        XCTAssertEqual(state.latest, writer)

        // A real idle observation from the writer is valid and must not be hidden.
        let idle = RecorderSnapshot(state: .idle, observedAt: start.addingTimeInterval(120))
        state.receive(idle)
        var verifiedIdle = idle
        verifiedIdle.pendingCountIsKnown = true
        XCTAssertEqual(state.applicationSnapshot(pendingCount: 0), verifiedIdle)
        XCTAssertEqual(state.latest, idle)
    }

    func testUnchangedQueueLogsAtMostOncePerMinuteAndManualSyncCanInspectImmediately() {
        var policy = TransferDiagnosticsPolicy()
        XCTAssertTrue(policy.shouldLogQueue(fingerprint: "queue-a", trigger: .automatic, at: start))
        for second in 1..<60 {
            XCTAssertFalse(policy.shouldLogQueue(fingerprint: "queue-a", trigger: .automatic,
                                                at: start.addingTimeInterval(Double(second))))
        }
        XCTAssertTrue(policy.shouldLogQueue(fingerprint: "queue-a", trigger: .automatic,
                                           at: start.addingTimeInterval(60)))
        XCTAssertTrue(policy.shouldLogQueue(fingerprint: "queue-a", trigger: .manual,
                                           at: start.addingTimeInterval(61)))
        XCTAssertFalse(policy.shouldLogQueue(fingerprint: "queue-a", trigger: .automatic,
                                            at: start.addingTimeInterval(62)))
        XCTAssertTrue(policy.shouldLogQueue(fingerprint: "queue-b", trigger: .automatic,
                                           at: start.addingTimeInterval(62)))
    }

    func testEventDeliveryCompletionCannotCreateARecurringDiagnosticTransfer() {
        var policy = TransferDiagnosticsPolicy()
        XCTAssertFalse(policy.shouldLogQueue(fingerprint: "queue-a", trigger: .eventDeliveryCompletion,
                                            at: start))
        XCTAssertTrue(policy.shouldLogQueue(fingerprint: "queue-a", trigger: .automatic, at: start))
        // Completions can arrive late or observe a different queue. Neither may
        // produce another event or consume the next legitimate observation.
        for minute in 1...120 {
            XCTAssertFalse(policy.shouldLogQueue(fingerprint: "queue-b", trigger: .eventDeliveryCompletion,
                                                at: start.addingTimeInterval(Double(minute * 60))))
        }
        XCTAssertTrue(policy.shouldLogQueue(fingerprint: "queue-b", trigger: .automatic,
                                           at: start.addingTimeInterval(7_201)))
        XCTAssertFalse(policy.shouldLogQueue(fingerprint: "queue-b", trigger: .automatic,
                                            at: start.addingTimeInterval(7_202)))
    }
}
