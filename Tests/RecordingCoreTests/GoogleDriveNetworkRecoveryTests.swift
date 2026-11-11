import Foundation
import XCTest
@testable import RecordingCore

final class GoogleDriveNetworkRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func deferred() throws -> GoogleDriveLibraryLedger {
        var ledger = GoogleDriveLibraryLedger()
        try ledger.bind(accountID: "synthetic-owner", label: "Synthetic")
        try ledger.authorize(.futureOnly, knownIDs: [], at: now.addingTimeInterval(-10))
        for _ in 0..<10 { ledger.recordFailure(at: now, kind: .recoverableNetwork) }
        return ledger
    }

    private func restore(_ ledger: GoogleDriveLibraryLedger) throws -> GoogleDriveLibraryLedger {
        try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: TransportCodec.encode(ledger))
    }

    func testHourBackoffRecoveryRetainsFailureUntilSuccessAndPreservesGrant() throws {
        var ledger = try deferred()
        let original = ledger
        XCTAssertEqual(ledger.retryAfter, now.addingTimeInterval(3_600))
        XCTAssertTrue(ledger.reserveNetworkRecovery(at: now.addingTimeInterval(1)))
        XCTAssertEqual(ledger.retryAfter, original.retryAfter)
        XCTAssertEqual(ledger.failureCount, original.failureCount)
        let reserved = ledger
        ledger.completeNetworkRecovery(reserved: reserved)
        XCTAssertNil(ledger.retryAfter)
        XCTAssertNil(ledger.retryFailureKind)
        XCTAssertEqual(ledger.failureCount, 0)
        XCTAssertEqual(ledger.libraryID, original.libraryID)
        XCTAssertEqual(ledger.authorizedAt, original.authorizedAt)
        XCTAssertEqual(ledger.recordingScope, original.recordingScope)
        XCTAssertEqual(ledger.jobs, original.jobs)
        XCTAssertEqual(ledger.recoveryProbeAt, reserved.recoveryProbeAt)
    }

    func testColdRestartAndClockRollbackCannotResetRecoveryCooldown() throws {
        var ledger = try deferred()
        XCTAssertTrue(ledger.reserveNetworkRecovery(at: now))
        ledger = try restore(ledger)
        XCTAssertFalse(ledger.reserveNetworkRecovery(at: now.addingTimeInterval(59)))
        XCTAssertFalse(ledger.reserveNetworkRecovery(at: now.addingTimeInterval(-1)))
        XCTAssertTrue(ledger.reserveNetworkRecovery(at: now.addingTimeInterval(60)))
        XCTAssertEqual(ledger.retryAfter, now.addingTimeInterval(3_600))
    }

    func testOneCooldownCoversLibraryAndDifferentItemOpportunitiesAfterSuccess() throws {
        var ledger = try deferred()
        XCTAssertTrue(ledger.reserveNetworkRecovery(at: now))
        ledger.completeNetworkRecovery(reserved: ledger)
        ledger = try restore(ledger)
        XCTAssertFalse(ledger.reserveNetworkRecoveryOpportunity(at: now.addingTimeInterval(1)))
        XCTAssertTrue(ledger.reserveNetworkRecoveryOpportunity(at: now.addingTimeInterval(60)))
        XCTAssertFalse(ledger.reserveNetworkRecoveryOpportunity(at: now.addingTimeInterval(61)))
    }

    func testHTTPAndUnclassifiedLegacyFailuresKeepDeadline() throws {
        var ledger = try deferred()
        ledger.recordFailure(at: now, kind: .other)
        let original = ledger
        XCTAssertFalse(ledger.reserveNetworkRecovery(at: now.addingTimeInterval(1)))
        XCTAssertEqual(ledger, original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: TransportCodec.encode(ledger)) as? [String: Any])
        json.removeValue(forKey: "retryFailureKind")
        ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: JSONSerialization.data(withJSONObject: json))
        try ledger.validate()
        XCTAssertFalse(ledger.reserveNetworkRecovery(at: now.addingTimeInterval(1)))
        XCTAssertEqual(ledger.retryAfter, original.retryAfter)
    }

    func testPauseRevocationAndMissingGrantNeverReserveRecovery() throws {
        var ledger = try deferred()
        try ledger.setEnabled(false)
        XCTAssertFalse(ledger.reserveNetworkRecovery(at: now))
        XCTAssertFalse(ledger.reserveNetworkRecoveryOpportunity(at: now))
        ledger.revoke()
        XCTAssertFalse(ledger.reserveNetworkRecovery(at: now))
        XCTAssertFalse(ledger.reserveNetworkRecoveryOpportunity(at: now))
        var unbound = GoogleDriveLibraryLedger()
        unbound.recordFailure(at: now, kind: .recoverableNetwork)
        XCTAssertFalse(unbound.reserveNetworkRecovery(at: now))
    }

    func testDelayedSuccessCannotClearNewHTTPFailureOrRevokedGrant() throws {
        var ledger = try deferred()
        XCTAssertTrue(ledger.reserveNetworkRecovery(at: now))
        let reserved = ledger
        ledger.recordFailure(at: now.addingTimeInterval(1), kind: .other)
        let throttled = ledger
        ledger.completeNetworkRecovery(reserved: reserved)
        XCTAssertEqual(ledger, throttled)
        ledger = reserved
        ledger.revoke()
        let revoked = ledger
        ledger.completeNetworkRecovery(reserved: reserved)
        XCTAssertEqual(ledger, revoked)
    }

    func testRecoverySignalInsideCooldownHasEarlierSafePlanThanHourBackoff() throws {
        var ledger = try deferred()
        XCTAssertTrue(ledger.reserveNetworkRecovery(at: now))
        let restored = try restore(ledger)
        XCTAssertEqual(restored.networkRecoveryOpportunityDate(at: now.addingTimeInterval(1)), now.addingTimeInterval(60))
        XCTAssertEqual(restored.retryAfter, now.addingTimeInterval(3_600))
        XCTAssertEqual(restored.networkRecoveryOpportunityDate(at: now.addingTimeInterval(-10)), now.addingTimeInterval(60))
        XCTAssertEqual(restored.networkRecoveryOpportunityDate(at: now.addingTimeInterval(61)), now.addingTimeInterval(61))
        try ledger.setEnabled(false)
        XCTAssertNil(ledger.networkRecoveryOpportunityDate(at: now))
        ledger.revoke()
        XCTAssertNil(ledger.networkRecoveryOpportunityDate(at: now))
    }

    func testFailureTimestampSurvivesRecoveryAndLegacyDecodeRemainsUnknown() throws {
        var ledger = try deferred()
        XCTAssertEqual(try restore(ledger).lastFailureAt, now)
        XCTAssertTrue(ledger.reserveNetworkRecovery(at: now))
        ledger.completeNetworkRecovery(reserved: ledger)
        XCTAssertEqual(ledger.lastFailureAt, now)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: TransportCodec.encode(ledger)) as? [String: Any])
        json.removeValue(forKey: "lastFailureAt")
        let legacy = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: JSONSerialization.data(withJSONObject: json))
        try legacy.validate()
        XCTAssertNil(legacy.lastFailureAt)
    }

    func testRetryPlanIgnoresExpiredDeadlineAndReflectsEffectiveTimer() {
        let expired = now.addingTimeInterval(-30), cooldown = now.addingTimeInterval(50)
        XCTAssertEqual(GoogleDriveRetrySchedule.timerDate(requested: expired, at: now), now.addingTimeInterval(2))
        XCTAssertEqual(GoogleDriveRetrySchedule.nextAttempt(at: now, isBusy: false, ordinary: nil,
            recovery: cooldown, library: expired, item: nil), cooldown)
        XCTAssertNil(GoogleDriveRetrySchedule.nextAttempt(at: now, isBusy: true, ordinary: cooldown,
            recovery: nil, library: expired, item: now.addingTimeInterval(20)))
        let throttle = now.addingTimeInterval(3_600)
        XCTAssertEqual(GoogleDriveRetrySchedule.nextAttempt(at: now, isBusy: false, ordinary: nil,
            recovery: nil, library: throttle, item: cooldown), throttle)
    }

    func testCredentialRequirementSurvivesRestartPauseRevokeUntilSameAccountReauthorization() throws {
        var ledger = try deferred()
        let original = ledger
        ledger.recordCredentialRequired(at: now)
        try ledger.setEnabled(false)
        ledger = try restore(ledger)
        XCTAssertEqual(ledger.credentialRequiredAt, now)
        XCTAssertEqual(ledger.lastFailureAt, now)
        XCTAssertFalse(ledger.enabled)
        try ledger.setEnabled(true)
        XCTAssertEqual(ledger.credentialRequiredAt, now, "Resume cannot imply credential repair")
        ledger.revoke()
        ledger = try restore(ledger)
        XCTAssertEqual(ledger.credentialRequiredAt, now)
        XCTAssertTrue(ledger.revokedLocally)
        XCTAssertThrowsError(try ledger.recordReauthorization(accountID: "different-owner", label: "Other"))
        XCTAssertEqual(ledger.credentialRequiredAt, now)
        try ledger.recordReauthorization(accountID: "synthetic-owner", label: "Synthetic")
        XCTAssertNil(ledger.credentialRequiredAt)
        XCTAssertFalse(ledger.enabled, "Reauthorization must not restart uploads")
        XCTAssertEqual(ledger.recordingScope, original.recordingScope)
        XCTAssertEqual(ledger.authorizedAt, original.authorizedAt)
        XCTAssertEqual(ledger.jobs, original.jobs)
        XCTAssertEqual(ledger.lastFailureAt, now, "Historical last-failure time remains available")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: TransportCodec.encode(ledger)) as? [String: Any])
        json.removeValue(forKey: "credentialRequiredAt")
        let legacy = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.credentialRequiredAt)
        try legacy.validate()
    }

    func testTransportClassificationDoesNotTreatHTTPOrCancellationAsRecovery() {
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                     NSURLErrorTimedOut, NSURLErrorSecureConnectionFailed, NSURLErrorCannotConnectToHost] {
            XCTAssertEqual(GoogleDriveRetryFailureKind.classify(errorDomain: NSURLErrorDomain, code: code), .recoverableNetwork)
        }
        for code in [NSURLErrorCancelled, NSURLErrorServerCertificateUntrusted, NSURLErrorBadURL] {
            XCTAssertEqual(GoogleDriveRetryFailureKind.classify(errorDomain: NSURLErrorDomain, code: code), .other)
        }
        for status in [401, 403, 408, 429, 500, 503] {
            XCTAssertEqual(GoogleDriveRetryFailureKind.classify(errorDomain: "HTTP", code: status), .other)
        }
    }
}
