import Foundation
import XCTest
@testable import RecordingCore

final class ICloudDriveDiagnosticTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnknownAndInvalidOrStaleObservationsNeverBecomeUploadConfirmation() throws {
        let cold = ICloudDriveDiagnosticSnapshot(observation: nil, at: now)
        XCTAssertEqual(cold.availability, .notObserved)
        XCTAssertEqual(cold.status, .unknown)
        XCTAssertNil(cold.counts)
        let counters = ICloudDriveDiagnosticObservation.Counts(providerConfirmedFiles: 5)
        let stale = ICloudDriveDiagnosticSnapshot(observation: .init(
            observedAt: now.addingTimeInterval(-3_601), counts: counters), at: now, connected: true, enabled: true)
        XCTAssertEqual(stale.availability, .stale)
        XCTAssertEqual(stale.status, .unknown)
        XCTAssertEqual(stale.counts?.providerConfirmedFiles, 5) // explicitly historical facts
        let future = ICloudDriveDiagnosticSnapshot(observation: .init(
            observedAt: now.addingTimeInterval(6), counts: counters), at: now, connected: true, enabled: true)
        XCTAssertEqual(future.availability, .invalidTimestamp)
        XCTAssertEqual(future.status, .unknown)
        XCTAssertNil(future.observedAt)
        XCTAssertNil(future.ageSeconds)
        let invalid = ICloudDriveDiagnosticSnapshot(observation: .init(
            observedAt: Date(timeIntervalSince1970: .infinity)), at: now)
        XCTAssertEqual(invalid.availability, .invalidTimestamp)
        XCTAssertNoThrow(try TransportCodec.encode(invalid))
    }

    func testIdentityProofGapIsDifferentFromProviderPendingAndDoesNotInventConfirmation() {
        let observation = ICloudDriveDiagnosticObservation(observedAt: now,
            latestProviderObservationAt: now.addingTimeInterval(-10),
            counts: .init(providerConfirmedFiles: 4, pendingProviderFiles: 3,
                          needsIdentityRevalidationSources: 1))
        let gap = ICloudDriveDiagnosticSnapshot(observation: observation, at: now, connected: true, enabled: true)
        XCTAssertEqual(gap.availability, .cached)
        XCTAssertEqual(gap.status, .needsIdentityRevalidation)
        XCTAssertEqual(gap.latestProviderObservationAt, now.addingTimeInterval(-10))
        XCTAssertFalse(gap.currentRemoteReadabilityProven)
        XCTAssertFalse(gap.allCountersShareOneObservationTime)
        let pending = ICloudDriveDiagnosticSnapshot(observation: .init(observedAt: now,
            counts: .init(pendingProviderFiles: 3)), at: now, connected: true, enabled: true)
        XCTAssertEqual(pending.status, .providerPending)
        XCTAssertEqual(pending.counts?.providerConfirmedFiles, 0)
        let empty = ICloudDriveDiagnosticSnapshot(observation: .init(observedAt: now), at: now,
            connected: true, enabled: true)
        XCTAssertEqual(empty.status, .unknown)
    }

    func testCurrentFailureRevocationAndPauseDoNotPromoteRetainedHistory() {
        let retained = ICloudDriveDiagnosticObservation(observedAt: now,
            counts: .init(providerConfirmedFiles: 7, retainedHistoricalPositiveFiles: 7))
        let failed = ICloudDriveDiagnosticSnapshot(observation: retained, at: now, connected: true,
            enabled: true, operationFailed: true)
        XCTAssertEqual(failed.availability, .unavailable)
        XCTAssertEqual(failed.status, .unavailable)
        XCTAssertEqual(failed.failure, .operationFailed)
        XCTAssertEqual(failed.observedAt, retained.observedAt)
        let revoked = ICloudDriveDiagnosticSnapshot(observation: .init(observedAt: now,
            failure: .providerUnavailable, cacheResetReason: .authorizationUnavailable), at: now,
            connected: true, enabled: false)
        XCTAssertEqual(revoked.status, .unavailable)
        XCTAssertEqual(revoked.cacheResetReason, .authorizationUnavailable)
        let paused = ICloudDriveDiagnosticSnapshot(observation: retained, at: now, connected: true, enabled: false)
        XCTAssertEqual(paused.status, .paused)
        let disconnected = ICloudDriveDiagnosticSnapshot(observation: retained, at: now)
        XCTAssertEqual(disconnected.status, .disconnected)
    }

    func testFixedTypedEnvelopeIsBoundedAndCannotCarryPrivateStrings() throws {
        let snapshot = ICloudDriveDiagnosticSnapshot(observation: .init(observedAt: now,
            failure: .evidenceUnavailable, cacheResetReason: .invalid, expiredPhase: .provider,
            counts: .init(authorizedSources: .max, locallyWrittenAudio: -1,
                          pendingProviderFiles: .max, needsIdentityRevalidationSources: .max)), at: now,
            connected: true, enabled: true)
        let bytes = try TransportCodec.encode(snapshot)
        XCTAssertLessThan(bytes.count, 4_096)
        XCTAssertEqual(snapshot.counts?.authorizedSources, 1_000_000_000)
        XCTAssertEqual(snapshot.counts?.locallyWrittenAudio, 0)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(value["providerAccessedForExport"] as? Bool, false)
        XCTAssertEqual(value["workerStartedForExport"] as? Bool, false)
        XCTAssertEqual(value["audioContentVerified"] as? Bool, false)
        XCTAssertEqual(value["includesRecordingIdentities"] as? Bool, false)
        for forbidden in ["path", "bookmark", "segmentID", "libraryID", "account", "token", "errorDescription"] {
            XCTAssertNil(value[forbidden])
        }
    }
}
