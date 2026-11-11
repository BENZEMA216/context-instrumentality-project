import XCTest
@testable import RecordingCore

final class PhoneTransferPhaseDiagnosticsTests: XCTestCase {
    func testLateHistoryDoesNotEvictRecentWatchObservation() throws {
        let value = PhoneTransferPhaseDiagnostics(build: "104", writer: { _ in })
        func event(_ time: Int64, generation: UInt64) -> RecordingEvent {
            RecordingEvent(kind: "watch.transfer_opportunity", detail:
                WatchTransferOpportunityDiagnostic(phase: .expired, generation: generation,
                    observedAtMS: time, foreground: false, liveCapture: false).detail()!)
        }
        value.recordWatchEvent(event(90_000, generation: 9_000))
        for generation in 1...PhoneTransferPhaseDiagnostics.maximumWatchEvents {
            value.recordWatchEvent(event(Int64(generation), generation: UInt64(generation)))
        }
        value.drain()
        let report = value.snapshot()
        XCTAssertEqual(report.watchEvents.count, PhoneTransferPhaseDiagnostics.maximumWatchEvents)
        XCTAssertTrue(report.watchEvents.contains { $0.opportunity?.observedAtMS == 90_000 })
        XCTAssertFalse(report.watchEvents.contains { $0.opportunity?.observedAtMS == 1 })
        XCTAssertTrue(report.phoneReceives.isEmpty)
        let restored = PhoneTransferPhaseDiagnostics(build: "104", restored: try JSONEncoder().encode(report), writer: { _ in })
        XCTAssertTrue(restored.snapshot().watchEvents.contains { $0.opportunity?.observedAtMS == 90_000 })
    }
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private func manifest(id: UUID = UUID(), session: UUID = UUID(), bytes: Int64 = 64) -> SegmentManifest {
        SegmentManifest(id: id, sessionID: session, sequence: 0,
            startedAt: instant.addingTimeInterval(-60), endedAt: instant,
            sampleRate: 16_000, frameCount: 960_000, fileName: id.uuidString.lowercased() + ".caf",
            byteCount: bytes, sha256: String(repeating: "a", count: 64))
    }
    private func receipt(_ source: SegmentManifest, at: Date) -> SegmentReceipt {
        SegmentReceipt(segmentID: source.id, sha256: source.sha256, byteCount: source.byteCount, receivedAt: at)
    }

    func testSixtySourcesRecordBeforeMainHopAndRetainEachBoundary() throws {
        let value = PhoneTransferPhaseDiagnostics(build: "88", writer: { _ in })
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [self] in
            for _ in 0..<60 {
                let source = manifest()
                value.recordDelegateEntered(manifest: source, at: instant)
                value.recordStaged(manifest: source, at: instant.addingTimeInterval(1))
                let durable = receipt(source, at: instant.addingTimeInterval(2))
                value.recordDurableReceipt(manifest: source, receipt: durable, at: instant.addingTimeInterval(3))
                value.recordACKQueued(receipt: durable, at: instant.addingTimeInterval(4))
            }
            finished.signal()
        }
        // Main remains blocked: neither time capture nor writer requires it.
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        value.drain()
        let report = value.snapshot()
        XCTAssertEqual(report.phoneReceives.count, 60)
        XCTAssertEqual(report.omittedPhoneReceiveCount, 0)
        for row in report.phoneReceives {
            XCTAssertEqual(row.callbackCount, 1)
            XCTAssertEqual(row.stagedAtMS! - row.firstDelegateEnteredAtMS!, 1_000)
            XCTAssertEqual(row.durableObservedAtMS! - row.stagedAtMS!, 2_000)
            XCTAssertEqual(row.ackQueuedAtMS! - row.durableObservedAtMS!, 1_000)
        }
    }

    func testReplayPreservesOriginalReceiptAndFirstBoundaryWithoutFabricatingACK() throws {
        let value = PhoneTransferPhaseDiagnostics(build: "88", writer: { _ in })
        let source = manifest(), durable = receipt(manifest(), at: instant)
        // A mismatching receipt never supplies a durable or ACK observation.
        value.recordDelegateEntered(manifest: source, at: instant)
        value.recordDurableReceipt(manifest: source, receipt: durable)
        value.recordACKQueued(receipt: durable)
        XCTAssertNil(value.snapshot().phoneReceives.first?.durableReceiptAtMS)
        let matching = receipt(source, at: instant.addingTimeInterval(-30))
        value.recordStaged(manifest: source, at: instant.addingTimeInterval(1))
        value.recordDurableReceipt(manifest: source, receipt: matching, at: instant.addingTimeInterval(2))
        value.recordACKQueued(receipt: matching, at: instant.addingTimeInterval(3))
        value.recordDelegateEntered(manifest: source, at: instant.addingTimeInterval(20))
        value.recordStaged(manifest: source, at: instant.addingTimeInterval(21))
        value.recordDurableReceipt(manifest: source, receipt: matching, at: instant.addingTimeInterval(22))
        value.recordACKQueued(receipt: matching, at: instant.addingTimeInterval(23))
        let row = try XCTUnwrap(value.snapshot().phoneReceives.first)
        XCTAssertEqual(row.callbackCount, 2)
        XCTAssertEqual(row.lastDelegateEnteredAtMS! - row.firstDelegateEnteredAtMS!, 20_000)
        XCTAssertEqual(row.durableObservedAtMS! - row.durableReceiptAtMS!, 32_000)
        XCTAssertEqual(row.ackQueuedAtMS! - row.durableObservedAtMS!, 1_000)
    }

    func testBoundedRetentionReportsOmissionsAndNeverSerializesSourceText() throws {
        let value = PhoneTransferPhaseDiagnostics(build: "ACCOUNT-SECRET", writer: { _ in })
        for _ in 0..<300 { value.recordDelegateEntered(manifest: manifest(), at: instant) }
        value.recordDelegateEntered(manifest: nil, at: instant)
        value.drain()
        let report = value.snapshot()
        XCTAssertEqual(report.phoneReceives.count, 256)
        XCTAssertEqual(report.omittedPhoneReceiveCount, 44)
        XCTAssertEqual(report.invalidManifestCallbackCount, 1)
        let encoded = try JSONEncoder().encode(report)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertLessThanOrEqual(encoded.count, PhoneTransferPhaseDiagnostics.maximumBytes)
        XCTAssertFalse(text.contains(".caf"))
        XCTAssertFalse(text.contains("ACCOUNT-SECRET"))
        XCTAssertFalse(text.contains("sha256"))
        XCTAssertFalse(report.audioRead)
        XCTAssertFalse(report.includesAudio)
    }

    func testWriteFailureIsCountedAndNextRealObservationCanPersist() throws {
        let output = Output()
        let value = PhoneTransferPhaseDiagnostics(build: "88", writer: { bytes in try output.write(bytes) })
        value.recordDelegateEntered(manifest: manifest(), at: instant)
        value.drain()
        XCTAssertEqual(value.snapshot().writeFailureCount, 1)
        output.fail = false
        value.recordDelegateEntered(manifest: manifest(), at: instant)
        value.drain()
        let bytes = try XCTUnwrap(output.bytes)
        let restored = try JSONDecoder().decode(PhoneTransferPhaseDiagnostics.Report.self, from: bytes)
        XCTAssertEqual(restored.writeFailureCount, 1)
        XCTAssertEqual(restored.phoneReceives.count, 2)
    }

    func testRestartRetainsTimesButDoesNotInventNewACKBinding() throws {
        let value = PhoneTransferPhaseDiagnostics(build: "88", writer: { _ in })
        let source = manifest(), original = receipt(manifest(), at: instant)
        value.recordDelegateEntered(manifest: source, at: instant)
        let matching = receipt(source, at: instant)
        value.recordDurableReceipt(manifest: source, receipt: matching, at: instant)
        let data = try JSONEncoder().encode(value.snapshot())
        let restored = PhoneTransferPhaseDiagnostics(build: "88", restored: data, writer: { _ in })
        restored.recordACKQueued(receipt: matching, at: instant.addingTimeInterval(1))
        restored.recordACKQueued(receipt: original, at: instant.addingTimeInterval(2))
        XCTAssertEqual(restored.snapshot().phoneReceives.count, 1)
        XCTAssertNil(restored.snapshot().phoneReceives.first?.ackQueuedAtMS)
        restored.recordDurableReceipt(manifest: source, receipt: matching, at: instant.addingTimeInterval(3))
        restored.recordACKQueued(receipt: matching, at: instant.addingTimeInterval(4))
        XCTAssertNotNil(restored.snapshot().phoneReceives.first?.ackQueuedAtMS)
    }

    func testUnreviewedWatchEventIsNotForwardedIntoPhoneMetadata() {
        let value = PhoneTransferPhaseDiagnostics(build: "88", writer: { _ in })
        value.recordWatchEvent(RecordingEvent(kind: "file_transfer_failed", detail: "/private/account/transcript"))
        value.recordWatchEvent(RecordingEvent(kind: "watch.transfer_attempt", detail: "{\"path\":\"/private\"}"))
        XCTAssertTrue(value.snapshot().watchEvents.isEmpty)
    }

    func testRefusalSnapshotsReplaceAndRestartReplayDoesNotWriteOrRegress() throws {
        let output = Output(); output.fail = false
        let process = UUID(), first: Int64 = 1_800_000_000_000
        func event(_ count: Int) -> RecordingEvent {
            let diagnostic = WatchTransferRefusalDiagnostic(reason: .nativeOccupied, observedAtMS: first,
                generation: 1, foreground: false, liveCapture: true, nativeCount: 3,
                processRunID: process, observationCount: count, lastObservedAtMS: first + Int64(count - 1) * 10_000)
            return RecordingEvent(kind: "watch.transfer_refusal", detail: diagnostic.detail()!)
        }
        let value = PhoneTransferPhaseDiagnostics(build: "88", writer: { try output.write($0) })
        for count in 1...360 { value.recordWatchEvent(event(count)) }
        value.drain()
        XCTAssertEqual(value.snapshot().watchEvents.count, 1)
        XCTAssertEqual(value.snapshot().watchEvents.first?.refusal?.observationCount, 360)
        let data = try XCTUnwrap(output.bytes)
        let restored = PhoneTransferPhaseDiagnostics(build: "88", restored: data, writer: { try output.write($0) })
        let writes = output.writes
        for _ in 0..<360 { restored.recordWatchEvent(event(360)); restored.recordWatchEvent(event(1)) }
        restored.drain()
        XCTAssertEqual(output.writes, writes, "An identical or stale restart replay has no disk publication work")
        XCTAssertEqual(restored.snapshot().watchEvents.count, 1)
        XCTAssertEqual(restored.snapshot().watchEvents.first?.refusal?.observationCount, 360)
        restored.recordWatchEvent(event(361)); restored.drain()
        XCTAssertEqual(output.writes, writes + 1)
        XCTAssertEqual(restored.snapshot().watchEvents.first?.refusal?.observationCount, 361)
    }

    func testLegacyAndExplicitSingleObservationReplayAreSemanticallyIdentical() throws {
        let output = Output(); output.fail = false
        let value = PhoneTransferPhaseDiagnostics(build: "88", writer: { try output.write($0) })
        let first: Int64 = 1_800_000_000_000
        let legacy = WatchTransferRefusalDiagnostic(reason: .nativeOccupied, observedAtMS: first,
            generation: 1, foreground: false, liveCapture: true, nativeCount: 3)
        let explicit = WatchTransferRefusalDiagnostic(reason: .nativeOccupied, observedAtMS: first,
            generation: 1, foreground: false, liveCapture: true, nativeCount: 3,
            observationCount: 1, lastObservedAtMS: first)
        value.recordWatchEvent(RecordingEvent(kind: "watch.transfer_refusal", detail: legacy.detail()!))
        value.drain()
        let writes = output.writes
        for _ in 0..<360 {
            value.recordWatchEvent(RecordingEvent(kind: "watch.transfer_refusal", detail: explicit.detail()!))
            value.recordWatchEvent(RecordingEvent(kind: "watch.transfer_refusal", detail: legacy.detail()!))
        }
        value.drain()
        XCTAssertEqual(output.writes, writes)
        XCTAssertEqual(value.snapshot().watchEvents.count, 1)
    }

    func testDistinctWatchDiagnosticHistoryHasIndependentCountAndByteBounds() throws {
        let output = Output(); output.fail = false
        let value = PhoneTransferPhaseDiagnostics(build: "88", writer: { try output.write($0) })
        for generation in 1...800 {
            let diagnostic = WatchTransferRefusalDiagnostic(reason: .nativeOccupied,
                observedAtMS: 1_800_000_000_000 + Int64(generation), generation: UInt64(generation),
                foreground: false, liveCapture: true, nativeCount: 3)
            value.recordWatchEvent(RecordingEvent(kind: "watch.transfer_refusal", detail: diagnostic.detail()!))
        }
        value.drain()
        XCTAssertLessThanOrEqual(value.snapshot().watchEvents.count, PhoneTransferPhaseDiagnostics.maximumWatchEvents)
        XCTAssertGreaterThanOrEqual(value.snapshot().omittedWatchEventCount, 800 - PhoneTransferPhaseDiagnostics.maximumWatchEvents)
        XCTAssertLessThanOrEqual(try XCTUnwrap(output.bytes).count, PhoneTransferPhaseDiagnostics.maximumBytes)
    }

    func testUpgradePreservesEvidenceAndMarksCrossBuildHistory() throws {
        let value = PhoneTransferPhaseDiagnostics(build: "88", writer: { _ in })
        value.recordDelegateEntered(manifest: manifest(), at: instant)
        let restored = PhoneTransferPhaseDiagnostics(build: "89",
            restored: try JSONEncoder().encode(value.snapshot()), writer: { _ in })
        XCTAssertEqual(restored.snapshot().phoneReceives.count, 1)
        XCTAssertEqual(restored.snapshot().build, "89")
        XCTAssertTrue(restored.snapshot().historyIncludesEarlierBuilds)
    }

    func testRuntimeRetainsSourceIdentityAndIgnoresReplayWithoutDiskWork() throws {
        let output = Output(); output.fail = false
        let value = PhoneTransferPhaseDiagnostics(build: "106", writer: { try output.write($0) })
        var runtime = WatchRuntimeObservation(build: "105", processRunID: UUID(), observerEpochID: UUID(),
            sequence: 10, observedAtMS: 1_800_000_000_000)
        runtime.nativeQueueCount = 2; runtime.nativeQueueObservedAtMS = runtime.observedAtMS - 500
        runtime.lastACKCommittedAtMS = runtime.observedAtMS - 1000
        value.recordWatchRuntime(try TransportCodec.encode(runtime)); value.drain()
        XCTAssertEqual(value.snapshot().watchRuntime, runtime)
        XCTAssertTrue(value.snapshot().phoneReceives.isEmpty)
        XCTAssertTrue(value.snapshot().watchEvents.isEmpty)
        let restored = PhoneTransferPhaseDiagnostics(build: "106", restored: try XCTUnwrap(output.bytes),
            writer: { try output.write($0) })
        let writes = output.writes
        restored.recordWatchRuntime(try TransportCodec.encode(runtime))
        var stale = runtime; stale.sequence -= 1
        restored.recordWatchRuntime(try TransportCodec.encode(stale))
        stale.observerEpochID = UUID(); stale.observedAtMS -= 1
        restored.recordWatchRuntime(try TransportCodec.encode(stale)); restored.drain()
        XCTAssertEqual(output.writes, writes)
        XCTAssertEqual(restored.snapshot().watchRuntime, runtime)
        runtime.sequence += 1
        restored.recordWatchRuntime(try TransportCodec.encode(runtime)); restored.drain()
        XCTAssertEqual(restored.snapshot().watchRuntime?.sequence, 11)
        XCTAssertEqual(restored.snapshot().watchRuntime?.nativeQueueObservedAtMS, 1_799_999_999_500)
        XCTAssertLessThanOrEqual(try XCTUnwrap(output.bytes).count, PhoneTransferPhaseDiagnostics.maximumBytes)
    }

    func testRuntimeRejectsInvalidUnknownAndOversizedPacketsAndRestoresLegacyReport() throws {
        let value = PhoneTransferPhaseDiagnostics(build: "106", writer: { _ in })
        var runtime = WatchRuntimeObservation(build: "106", processRunID: UUID(), observerEpochID: UUID(),
            sequence: 1, observedAtMS: 1_800_000_000_000)
        XCTAssertNil(runtime.nativeQueueCount, "Missing queue observation cannot mean an empty native queue")
        runtime.nativeQueueCount = 0
        value.recordWatchRuntime(try TransportCodec.encode(runtime))
        XCTAssertNil(value.snapshot().watchRuntime)
        runtime.nativeQueueObservedAtMS = runtime.observedAtMS
        runtime.build = "/private/account"
        value.recordWatchRuntime(try TransportCodec.encode(runtime))
        runtime.build = "106"; runtime.schemaVersion = 2
        value.recordWatchRuntime(try TransportCodec.encode(runtime))
        runtime.schemaVersion = 1; runtime.tasksExpired = -1
        value.recordWatchRuntime(try TransportCodec.encode(runtime))
        value.recordWatchRuntime(Data(repeating: 32, count: WatchRuntimeObservation.maximumBytes + 1))
        XCTAssertNil(value.snapshot().watchRuntime)
        value.recordDelegateEntered(manifest: manifest(), at: instant)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value.snapshot())) as! [String: Any]
        legacy.removeValue(forKey: "watchRuntime")
        let restored = PhoneTransferPhaseDiagnostics(build: "106",
            restored: try JSONSerialization.data(withJSONObject: legacy), writer: { _ in })
        XCTAssertEqual(restored.snapshot().phoneReceives.count, 1)
        XCTAssertNil(restored.snapshot().watchRuntime)
    }

    private final class Output {
        var fail = true
        var bytes: Data?
        var writes = 0
        func write(_ data: Data) throws {
            if fail { throw POSIXError(.EIO) }
            bytes = data
            writes += 1
        }
    }
}
