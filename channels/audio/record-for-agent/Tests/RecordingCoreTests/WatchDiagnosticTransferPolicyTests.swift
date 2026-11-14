import XCTest
@testable import RecordingCore

final class WatchDiagnosticTransferPolicyTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testCaptureAndTransferEvidenceRoundTripsWithoutChangingIdentity() throws {
        let events = [
            event("segment_opened", "id=abc rate=16000 channels=1 format=1"),
            event("segment_sealed", "id=abc frames=960000 bytes=1920000"),
            event("phone_durable_ack", "id=abc"),
            event("file_transfer_queue", "pending=4 progress=32/64 fraction=0.5"),
            event("capture_telemetry", "battery=0.75 effectiveSeconds=120"),
            event("audio_interruption", "type=1 options=0 appState=active wantsRecording=true"),
            event("file_transfer_obsolete_callback", "id=abc outcome=failure ignored=true")
        ]
        XCTAssertTrue(events.allSatisfy(WatchDiagnosticTransferPolicy.mayTransfer))
        let packet = try TransportCodec.encode(events)
        XCTAssertEqual(WatchDiagnosticTransferPolicy.transferableBatch(from: packet), events)
        XCTAssertFalse(WatchDiagnosticTransferPolicy.shouldCancelQueuedUserInfo([TransportCodec.eventsKey: packet]))
    }

    func testLegacyCapacityNumbersAndDerivedInformationRemainLocal() {
        let records = [
            event("segment_opened", "id=abc freeBytes=123456789"),
            event("capture_telemetry", "battery=0.75 free_bytes=0 effectiveSeconds=120"),
            event("capture_telemetry", "availableBytes=123 remainingBytes=456"),
            event("capture_telemetry", "storageCapacity=1024 usedPercent=95"),
            event("capture_telemetry", "low_space=true"),
            event("capture_telemetry", "disk_low"),
            event("capture_telemetry", "insufficient_space"),
            event("capture_telemetry", "可用空间不足；未确认的录音不会被自动删除"),
            event("capture_telemetry", "容量剩余 20%"),
            event("disk_low", "true"),
            event("insufficient_space", "true"),
            event("capture_storage_telemetry", "battery=0.75 effectiveSeconds=120 freeBytes=0")
        ]
        for record in records {
            XCTAssertFalse(WatchDiagnosticTransferPolicy.mayTransfer(record), "\(record.kind): \(record.detail)")
        }
    }

    func testFreeFormErrorsAndUnknownKindsFailClosed() {
        let records = [
            event("capture_attempt_error", "stage=writer_prepare domain=NSCocoaErrorDomain code=640"),
            event("file_sync_failed", "domain=NSPOSIXErrorDomain code=28"),
            event("capture_interrupted", "保存录音失败：The operation could not be completed. (ENOSPC)"),
            event("capture_interrupted", "封存片段失败，临时音频已保留。"),
            event("capture_attempts_cancelled", "reason=capture_failed appState=active"),
            event("file_transfer_queue", "code=28"),
            event("segment_opened", "message=insufficient resources"),
            event("future_diagnostic", "123456")
        ]
        for record in records { XCTAssertFalse(WatchDiagnosticTransferPolicy.mayTransfer(record)) }
        XCTAssertTrue(WatchDiagnosticTransferPolicy.mayTransfer(
            event("capture_attempts_cancelled", "reason=system_interruption_began appState=active")))
    }

    func testSnapshotFailureStateAndTimesSurviveWhileItsLocalExplanationDoesNotLeaveWatch() throws {
        let unsafeDetails = [
            "保存录音失败：可用空间不足；未确认的录音不会被自动删除",
            "freeBytes=0", "disk_low", "insufficient_space", "NSCocoaErrorDomain Code=640",
            "An unreviewed future failure message"
        ]
        for detail in unsafeDetails {
            let original = RecorderSnapshot(state: .failed, sessionID: UUID(), observedAt: instant,
                lastAudioAt: instant.addingTimeInterval(-3), lastSealedAt: instant.addingTimeInterval(-60),
                pendingCount: 7, pendingCountIsKnown: true, detail: detail)
            var expected = original
            expected.detail = nil
            let outbound = WatchDiagnosticTransferPolicy.snapshotForTransfer(original)
            XCTAssertEqual(outbound, expected)
            XCTAssertEqual(original.detail, detail)
            XCTAssertEqual(try TransportCodec.decode(RecorderSnapshot.self, from: TransportCodec.encode(outbound)), expected)
        }
    }

    func testKnownUserAndAudioMessagesRemainVisibleInSnapshotsAndEvents() {
        for (kind, state, detail) in [
            ("user_paused", CaptureState.paused, "你已暂停，点击继续才会重新录音。"),
            ("user_ended", .ended, "本次录音已结束。已保存片段会继续等待手机确认。"),
            ("capture_interrupted", .interrupted, "麦克风被系统或其他应用占用；未录到的时间会保留为缺口。")
        ] {
            let snapshot = RecorderSnapshot(state: state, observedAt: instant, detail: detail)
            XCTAssertEqual(WatchDiagnosticTransferPolicy.snapshotForTransfer(snapshot), snapshot)
            XCTAssertTrue(WatchDiagnosticTransferPolicy.mayTransfer(event(kind, detail)))
        }
    }

    func testMixedQueuedPacketIsCancelledAndSafeRecordsCanBeRequeuedUnchanged() throws {
        let local = [
            event("segment_sealed", "id=abc frames=960000 bytes=1920000"),
            event("capture_telemetry", "freeBytes=123456789 battery=0.75"),
            event("phone_durable_ack", "id=abc"),
            event("disk_low", "true")
        ]
        let mixed = try TransportCodec.encode(local)
        XCTAssertTrue(WatchDiagnosticTransferPolicy.shouldCancelQueuedUserInfo([TransportCodec.eventsKey: mixed]))
        XCTAssertNil(WatchDiagnosticTransferPolicy.transferableBatch(from: mixed))

        // Cancellation is not an application ACK. Reselecting from the journal
        // retains the complete safe records, including ID, timestamps and body.
        let requeued = local.filter(WatchDiagnosticTransferPolicy.mayTransfer)
        XCTAssertEqual(requeued, [local[0], local[2]])
        XCTAssertEqual(WatchDiagnosticTransferPolicy.transferableBatch(from: try TransportCodec.encode(requeued)), requeued)
        XCTAssertEqual(try TransportCodec.decode([RecordingEvent].self, from: mixed), local)
    }

    func testMalformedEventPacketsAreCancelledWithoutTouchingUnrelatedUserInfo() throws {
        for payload: [String: Any] in [
            [TransportCodec.eventsKey: Data("broken".utf8)],
            [TransportCodec.eventsKey: "wrong type"],
            [TransportCodec.eventsKey: try TransportCodec.encode([RecordingEvent]())]
        ] { XCTAssertTrue(WatchDiagnosticTransferPolicy.shouldCancelQueuedUserInfo(payload)) }
        for payload: [String: Any] in [
            [TransportCodec.requestSyncKey: true],
            [TransportCodec.receiptKey: Data("receipt".utf8)],
            [TransportCodec.targetedReceiptRequestKey: Data("targeted".utf8)],
            ["unrelated": "payload"], [:]
        ] { XCTAssertFalse(WatchDiagnosticTransferPolicy.shouldCancelQueuedUserInfo(payload)) }
    }

    func testSelectingOutboundDiagnosticsDoesNotMutateJournalAudioOrPendingAcknowledgements() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try RecordingRepository(root: directory)
        let id = UUID(), sessionID = UUID()
        let audio = Data(repeating: 42, count: 1024)
        try audio.write(to: repository.stagingURL(for: id))
        let manifest = try repository.sealSegment(stagedURL: repository.stagingURL(for: id), id: id,
            sessionID: sessionID, sequence: 0, startedAt: instant, endedAt: instant.addingTimeInterval(60),
            sampleRate: 16_000, frameCount: 960_000)
        let local = [event("segment_sealed", "id=\(id) bytes=1024"), event("disk_low", "true")]
        for record in local { try repository.appendEvent(record) }
        let before = try repository.events()
        let outbound = before.filter(WatchDiagnosticTransferPolicy.mayTransfer)
        XCTAssertEqual(outbound, [local[0]])
        XCTAssertEqual(try repository.events(), before)
        XCTAssertEqual(try repository.manifests(), [manifest])
        XCTAssertEqual(try repository.pendingSegments(), [manifest])
        XCTAssertFalse(try repository.hasDurableAcknowledgement(for: manifest))
        XCTAssertEqual(try Data(contentsOf: repository.audioURL(for: manifest)), audio)
    }

    private func event(_ kind: String, _ detail: String) -> RecordingEvent {
        RecordingEvent(kind: kind, detail: detail, sessionID: UUID(), timestamp: instant,
                       intervalStart: instant.addingTimeInterval(-1), intervalEnd: instant)
    }
}
