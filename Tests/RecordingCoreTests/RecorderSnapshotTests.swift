import XCTest
@testable import RecordingCore

final class RecorderSnapshotTests: XCTestCase {
    func testLegacyWireCountRemainsUnknown() throws {
        let original = RecorderSnapshot(state: .recording, sessionID: UUID(),
            observedAt: Date(timeIntervalSince1970: 1_000), pendingCount: 0, pendingCountIsKnown: true)
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: TransportCodec.encode(original)) as? [String: Any])
        wire.removeValue(forKey: "pendingCountIsKnown")
        let decoded = try TransportCodec.decode(RecorderSnapshot.self,
            from: JSONSerialization.data(withJSONObject: wire))
        var expected = original
        expected.pendingCountIsKnown = false
        XCTAssertEqual(decoded, expected)
    }

    func testDefaultZeroDoesNotClaimAnEmptyQueueWasVerified() {
        for state in [CaptureState.idle, .failed, .recording] {
            XCTAssertFalse(RecorderSnapshot(state: state).pendingCountIsKnown)
        }
    }

    func testKnownAndCachedCountsRoundTripWithoutChangingCaptureEvidence() throws {
        for known in [false, true] {
            let instant = Date(timeIntervalSince1970: 1_000)
            let original = RecorderSnapshot(state: .paused, sessionID: UUID(), observedAt: instant,
                lastAudioAt: instant.addingTimeInterval(-1), lastSealedAt: instant,
                pendingCount: 7, pendingCountIsKnown: known, detail: "Writer observation")
            XCTAssertEqual(try TransportCodec.decode(RecorderSnapshot.self,
                from: TransportCodec.encode(original)), original)
        }
    }
}
