import XCTest
@testable import RecordingCore

final class WatchTransferDiagnosticsTests: XCTestCase {
    private func attempt() -> WatchTransferAttemptDiagnostic {
        .init(phase: .enqueue, segmentID: UUID(), attemptID: UUID(), sourceCategory: .recovery,
              protection: .untilFirstAuth, observedAtMS: 100, enqueuedAtMS: 99, generation: 2,
              foreground: false, liveCapture: false, completed: 0, total: 100, outcome: .enqueued)
    }
    func testAttemptRoundTripAndUnknownFieldsAreRejectedAtOutboundBoundary() throws {
        let value = attempt(), detail = try XCTUnwrap(value.detail())
        let event = RecordingEvent(kind: "watch.transfer_attempt", detail: detail)
        XCTAssertEqual(WatchTransferDiagnostic.parse(event)?.attempt, value)
        XCTAssertTrue(WatchDiagnosticTransferPolicy.mayTransfer(event))
        var object = try JSONSerialization.jsonObject(with: Data(detail.utf8)) as! [String: Any]
        for key in ["path", "accountID", "transcript", "error", "unexpected"] {
            object[key] = "/private/real-file"
            let unsafe = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
            XCTAssertFalse(WatchDiagnosticTransferPolicy.mayTransfer(RecordingEvent(kind: event.kind, detail: unsafe)))
            object.removeValue(forKey: key)
        }
        XCTAssertNil(WatchTransferDiagnostic.parse(RecordingEvent(kind: event.kind, detail: detail, sessionID: UUID())))
    }
    func testAttemptInvalidEnumAndInconsistentPhaseFailClosed() throws {
        let detail = try XCTUnwrap(attempt().detail())
        XCTAssertNil(WatchTransferAttemptDiagnostic.decode(detail: detail.replacingOccurrences(of: "recovery", with: "private-path")))
        XCTAssertNil(WatchTransferAttemptDiagnostic.decode(detail: detail.replacingOccurrences(of: "enqueued", with: "failed")))
        XCTAssertNil(WatchTransferAttemptDiagnostic.decode(detail: detail.replacingOccurrences(of: "until_first_auth", with: "file:///private")))
    }
    func testGenerationIdentityIsScopedToProcessAndLegacyRemainsUnknown() throws {
        let firstRun = UUID(), nextRun = UUID()
        let first = WatchTransferOpportunityDiagnostic(phase: .expired, generation: 1,
            observedAtMS: 100, foreground: false, liveCapture: false, processRunID: firstRun)
        let second = WatchTransferOpportunityDiagnostic(phase: .started, generation: 1,
            observedAtMS: 200, foreground: false, liveCapture: false, processRunID: nextRun)
        XCTAssertEqual(WatchTransferOpportunityDiagnostic.decode(detail: first.detail()!)?.processRunID, firstRun)
        XCTAssertEqual(WatchTransferOpportunityDiagnostic.decode(detail: second.detail()!)?.processRunID, nextRun)
        XCTAssertNotEqual(first.processRunID, second.processRunID)
        let legacy = WatchTransferOpportunityDiagnostic(phase: .started, generation: 1,
            observedAtMS: 200, foreground: nil, liveCapture: nil)
        XCTAssertNil(WatchTransferOpportunityDiagnostic.decode(detail: legacy.detail()!)?.processRunID)
        let unsafe = first.detail()!.replacingOccurrences(of: firstRun.uuidString, with: "/private/account")
        XCTAssertNil(WatchTransferOpportunityDiagnostic.decode(detail: unsafe))
    }

    func testDiskCapacityRefusalRemainsLocal() {
        let value = WatchTransferRefusalDiagnostic(reason: .capacityLimit, observedAtMS: 120,
            generation: 1, foreground: false, liveCapture: false, nativeCount: 0)
        let event = RecordingEvent(kind: "watch.transfer_refusal", detail: value.detail()!)
        XCTAssertNotNil(WatchTransferDiagnostic.parse(event))
        XCTAssertFalse(WatchDiagnosticTransferPolicy.mayTransfer(event))
    }

    func testRefusalAndExpiryCarryOnlyClosedMetadata() throws {
        let refusal = WatchTransferRefusalDiagnostic(reason: .expiredGeneration, observedAtMS: 120,
            generation: 1, foreground: false, liveCapture: false, nativeCount: 11)
        XCTAssertEqual(WatchTransferDiagnostic.parse(RecordingEvent(kind: "watch.transfer_refusal", detail: refusal.detail()!))?.refusal, refusal)
        let expiry = WatchTransferOpportunityDiagnostic(phase: .expired, generation: 1,
            observedAtMS: 110, foreground: false, liveCapture: false)
        XCTAssertEqual(WatchTransferDiagnostic.parse(RecordingEvent(kind: "watch.transfer_opportunity", detail: expiry.detail()!))?.opportunity, expiry)
    }
    func testProvenanceUnknownOnLegacyMissingCorruptAndSymlinkSidecar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root), id = UUID()
        let input = repo.stagingURL(for: id)
        try Data(repeating: 7, count: 50).write(to: input)
        let manifest = try repo.sealSegment(stagedURL: input, id: id, sessionID: UUID(), sequence: 0,
            startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 2), sampleRate: 16_000, frameCount: 16_000)
        XCTAssertEqual(repo.diagnosticSourceCategory(for: manifest), .normal)
        repo.noteTransferSourceProvenance(manifest, category: .recovery)
        XCTAssertEqual(repo.diagnosticSourceCategory(for: manifest), .recovery)
        let path = root.appendingPathComponent("ConnectivityDiagnostics/source-category/" + id.uuidString.lowercased() + ".json")
        try FileManager.default.removeItem(at: path)
        XCTAssertEqual(repo.diagnosticSourceCategory(for: manifest), .unknown)
        try Data("broken".utf8).write(to: path)
        XCTAssertEqual(repo.diagnosticSourceCategory(for: manifest), .unknown)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: repo.audioURL(for: manifest))
        XCTAssertEqual(repo.diagnosticSourceCategory(for: manifest), .unknown)
    }
}
