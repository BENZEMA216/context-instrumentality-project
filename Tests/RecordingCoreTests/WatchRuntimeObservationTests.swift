import Foundation
import XCTest
@testable import RecordingCore

final class WatchRuntimeObservationTests: XCTestCase {
    private func observation() -> WatchRuntimeObservation {
        var value = WatchRuntimeObservation(build: "107", processRunID: UUID(), observerEpochID: UUID(),
            sequence: 1, observedAtMS: 1_800_000_000_000)
        value.nativeQueueCount = 12; value.nativeQueueObservedAtMS = value.observedAtMS - 100
        return value
    }

    func testLegacyPacketRetainsUnknownDetails() throws {
        let value = observation()
        let restored = try XCTUnwrap(WatchRuntimeObservation.decode(TransportCodec.encode(value)))
        XCTAssertNil(restored.queueSamples); XCTAssertNil(restored.lastACKFailure)
        XCTAssertNil(restored.refresh); XCTAssertNil(restored.admission)
    }

    func testProgressCannotBeComparedAcrossDifferentAttemptsOrUnknownTotals() throws {
        var value = observation()
        value.queueSamples = [.init(attemptID: UUID(), isTransferring: true, completedUnits: 40, totalUnits: nil)]
        var next = value; next.sequence += 1; next.nativeQueueObservedAtMS! += 100
        XCTAssertTrue(next.hasSameProgress(as: value))
        next.queueSamples?[0].completedUnits = 41
        XCTAssertFalse(next.hasSameProgress(as: value))
        next = value; next.queueSamples?[0].attemptID = UUID()
        XCTAssertFalse(next.hasSameProgress(as: value))
        XCTAssertEqual(WatchRuntimeObservation.decode(try TransportCodec.encode(value)), value)
    }

    func testMalformedSamplesAreRejectedWithoutHidingDuplicateNativeAttempts() throws {
        var value = observation()
        let sample = WatchRuntimeObservation.QueueSample(attemptID: UUID(), isTransferring: false, completedUnits: 0, totalUnits: 100)
        value.queueSamples = [sample, sample]
        XCTAssertTrue(value.isValid, "Duplicate native attempts must remain visible; they are not comparable progress identities")
        value.queueSamples = Array(repeating: .init(attemptID: nil, isTransferring: false, completedUnits: 0, totalUnits: 1), count: 4)
        XCTAssertFalse(value.isValid)
        value.queueSamples = [sample]; value.queueSamples?[0].completedUnits = -1
        XCTAssertFalse(value.isValid)
        value.queueSamples = []; value.nativeQueueCount = nil; value.nativeQueueObservedAtMS = nil
        XCTAssertFalse(value.isValid)
    }

    func testFailuresAreAllowlistedWithoutDescriptionsOrPaths() throws {
        var value = observation()
        value.lastACKFailure = .init(observedAtMS: value.observedAtMS - 10, stage: .commit, reason: .cocoaIO, systemCode: 260)
        value.lastACKFailure?.operation = .manifestRead
        XCTAssertEqual(WatchRuntimeObservation.decode(try TransportCodec.encode(value)), value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: TransportCodec.encode(value)) as? [String: Any])
        var failure = object["lastACKFailure"] as! [String: Any]
        failure["reason"] = "/private/untrusted-error"
        object["lastACKFailure"] = failure
        XCTAssertNil(WatchRuntimeObservation.decode(try JSONSerialization.data(withJSONObject: object)))
        value.lastACKFailure?.stage = .decode
        XCTAssertFalse(value.isValid)
        value.lastACKFailure?.reason = .decodeFailed; value.lastACKFailure?.systemCode = nil
        XCTAssertFalse(value.isValid, "A decode failure cannot claim a repository operation")
        value.lastACKFailure?.operation = nil
        XCTAssertTrue(value.isValid)
        value.lastACKFailure?.systemCode = 260
        XCTAssertFalse(value.isValid)
    }

    func testRefreshSuccessIsNotAClaimOfTaskDeliveryAndDeduplicatesAdmissionSampling() throws {
        var value = observation()
        value.refresh = .init(requestedCount: 1, acceptedCount: 1, failedCount: 0,
            requestedAtMS: value.observedAtMS - 100, preferredAtMS: value.observedAtMS + 60_000,
            completedAtMS: value.observedAtMS - 50, accepted: true, errorKind: nil, errorCode: nil)
        value.admission = .init(observedAtMS: value.observedAtMS, reason: .nativeOccupied)
        var next = value; next.sequence += 1; next.admission?.observedAtMS += 1
        XCTAssertTrue(next.hasSameProgress(as: value))
        next.admission?.reason = .retryBackoff
        XCTAssertFalse(next.hasSameProgress(as: value))
        XCTAssertEqual(value.applicationRefreshTasksStarted, 0)
        value.refresh?.errorKind = .other
        XCTAssertFalse(value.isValid)
    }

    func testMaximalDetailedPacketFitsBoundAndSurvivesPhonePersistence() throws {
        var value = observation()
        value.queueSamples = (0..<3).map { _ in .init(attemptID: UUID(), isTransferring: true, completedUnits: Int64.max, totalUnits: Int64.max) }
        value.lastACKFailure = .init(observedAtMS: value.observedAtMS, stage: .commit, reason: .storedMetadataDecodeFailed, systemCode: nil)
        value.lastACKFailure?.operation = .manifestRead
        value.refresh = .init(requestedCount: Int.max, acceptedCount: Int.max, failedCount: Int.max,
            requestedAtMS: value.observedAtMS, preferredAtMS: value.observedAtMS + 60_000,
            completedAtMS: value.observedAtMS, accepted: false, errorKind: .watchkit, errorCode: -1)
        value.admission = .init(observedAtMS: value.observedAtMS, reason: .candidateReadFailed)
        let data = try TransportCodec.encode(value)
        XCTAssertLessThanOrEqual(data.count, WatchRuntimeObservation.maximumBytes)
        let recorder = PhoneTransferPhaseDiagnostics(build: "107", writer: { _ in })
        recorder.recordWatchRuntime(data)
        XCTAssertEqual(recorder.snapshot().watchRuntime, value)
        XCTAssertTrue(recorder.snapshot().phoneReceives.isEmpty)
    }
}
