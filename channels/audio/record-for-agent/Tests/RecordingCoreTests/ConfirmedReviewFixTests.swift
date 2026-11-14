import XCTest
@testable import RecordingCore

/// Decision rules for the confirmed review fixes. Synthetic identifiers only.
/// HTTP 200 and a local write are not cloud confirmation.
final class ConfirmedReviewFixTests: XCTestCase {
    func testNaturalTimeoutRetriesTokenAndMetadataInsideTheSameBudget() {
        for path in [GoogleDriveRecoveryDecision.Path.aboutGET, .fileMetadataGET, .tokenPOST] {
            XCTAssertEqual(GoogleDriveRecoveryDecision.retryAllowance(path: path, fault: .naturalTimeout, remaining: 1), 1)
            XCTAssertEqual(GoogleDriveRecoveryDecision.retryAllowance(path: path, fault: .naturalTimeout, remaining: 7.5), 7.5)
            XCTAssertEqual(GoogleDriveRecoveryDecision.retryAllowance(path: path, fault: .naturalTimeout, remaining: 8), 8)
            XCTAssertEqual(GoogleDriveRecoveryDecision.retryAllowance(path: path, fault: .naturalTimeout, remaining: 20), 8)
            for remaining in [0.999, 0, -1, TimeInterval.infinity, -.infinity, .nan] {
                XCTAssertNil(GoogleDriveRecoveryDecision.retryAllowance(path: path, fault: .naturalTimeout, remaining: remaining))
            }
        }
        XCTAssertNil(GoogleDriveRecoveryDecision.retryAllowance(path: .tokenPOST, fault: .closedNoNotify, remaining: 8))
        XCTAssertNil(GoogleDriveRecoveryDecision.retryAllowance(path: .other, fault: .naturalTimeout, remaining: 8))
        XCTAssertEqual(GoogleDriveRecoveryDecision.retryAllowance(path: .aboutGET, fault: .closedNoNotify, remaining: 5), 5)
        XCTAssertNil(GoogleDriveRecoveryDecision.retryAllowance(path: .fileMetadataGET, fault: .other, remaining: 8))
    }

    func testFirstAttemptReservesRetryOnlyForRefreshTokenAndMetadata() {
        for path in [GoogleDriveRecoveryDecision.Path.aboutGET, .fileMetadataGET, .tokenPOST] {
            XCTAssertTrue(GoogleDriveRecoveryDecision.reservesRetry(path))
            for budget in [0.25, 1, 1.5, 1.999] {
                XCTAssertEqual(GoogleDriveRecoveryDecision.firstAttemptTimeout(budget: budget, path: path), budget)
            }
            let cases: [(budget: TimeInterval, idleTimeout: TimeInterval)] = [
                (2, 1), (2.001, 1.0005), (4, 2), (8, 4),
                (15.5, 7.75), (16, 8), (16.5, 8.5), (22, 14),
                (29, 21), (30, 22), (31, 22), (60, 22)
            ]
            for value in cases {
                XCTAssertEqual(GoogleDriveRecoveryDecision.firstAttemptTimeout(budget: value.budget, path: path),
                               value.idleTimeout, accuracy: 0.000_001)
            }
        }
        XCTAssertFalse(GoogleDriveRecoveryDecision.reservesRetry(.other))
        for budget in [0.25, 1, 1.5, 1.999, 2, 8, 16, 22, 29, 30] {
            XCTAssertEqual(GoogleDriveRecoveryDecision.firstAttemptTimeout(budget: budget, path: .other), budget)
        }
        for budget in [31.0, 60] {
            XCTAssertEqual(GoogleDriveRecoveryDecision.firstAttemptTimeout(budget: budget, path: .other), 30)
        }
        for path in [GoogleDriveRecoveryDecision.Path.aboutGET, .fileMetadataGET, .tokenPOST, .other] {
            for budget in [0, -1, TimeInterval.infinity, -.infinity, .nan] {
                XCTAssertEqual(GoogleDriveRecoveryDecision.firstAttemptTimeout(budget: budget, path: path), 0)
            }
        }
    }

    func testRetryUsesOnlyTheActualRemainderOfTheOriginalBudget() {
        let budget: TimeInterval = 30
        for elapsed in [0.0, 21, 22, 28.5, 29] {
            let remaining = budget - elapsed
            let allowance = GoogleDriveRecoveryDecision.retryAllowance(path: .tokenPOST, fault: .naturalTimeout, remaining: remaining)
            XCTAssertNotNil(allowance)
            if let allowance {
                XCTAssertLessThanOrEqual(elapsed + allowance, budget)
                XCTAssertLessThanOrEqual(allowance, 8)
            }
        }
        for elapsed in [29.001, 30, 31] {
            XCTAssertNil(GoogleDriveRecoveryDecision.retryAllowance(
                path: .tokenPOST, fault: .naturalTimeout, remaining: budget - elapsed))
        }
    }

    func testAcceptedFileMetadata404IsSameRequestRecovery() {
        XCTAssertEqual(GoogleDriveRecoveryDecision.secondAttempt(200, path: .tokenPOST, callerAcceptsMissingFile: false), .recovered)
        XCTAssertEqual(GoogleDriveRecoveryDecision.secondAttempt(404, path: .fileMetadataGET, callerAcceptsMissingFile: true), .recovered)
        XCTAssertEqual(GoogleDriveRecoveryDecision.secondAttempt(404, path: .fileMetadataGET, callerAcceptsMissingFile: false), .httpFailure)
        XCTAssertEqual(GoogleDriveRecoveryDecision.secondAttempt(404, path: .aboutGET, callerAcceptsMissingFile: true), .httpFailure)
        XCTAssertEqual(GoogleDriveRecoveryDecision.secondAttempt(204, path: .aboutGET, callerAcceptsMissingFile: false), .httpFailure)
        XCTAssertTrue(GoogleDriveRecoveryDecision.provesSameRequestRecovery(
            httpStatus: 404, methodIsGET: true, endpointIsFileMetadata: true, phaseIsRecovery: true,
            errorsEmpty: true, sameRequestAndOrigin: true))
        XCTAssertTrue(GoogleDriveRecoveryDecision.provesSameRequestRecovery(
            httpStatus: 200, methodIsGET: true, endpointIsFileMetadata: false, phaseIsRecovery: true,
            errorsEmpty: true, sameRequestAndOrigin: true))
        XCTAssertFalse(GoogleDriveRecoveryDecision.provesSameRequestRecovery(
            httpStatus: 404, methodIsGET: true, endpointIsFileMetadata: false, phaseIsRecovery: true,
            errorsEmpty: true, sameRequestAndOrigin: true))
        XCTAssertFalse(GoogleDriveRecoveryDecision.provesSameRequestRecovery(
            httpStatus: 200, methodIsGET: true, endpointIsFileMetadata: true, phaseIsRecovery: true,
            errorsEmpty: true, sameRequestAndOrigin: false),
            "Another request's success is not recovery of the failed request.")
        XCTAssertFalse(GoogleDriveRecoveryDecision.provesSameRequestRecovery(
            httpStatus: 302, methodIsGET: true, endpointIsFileMetadata: true, phaseIsRecovery: true,
            errorsEmpty: true, sameRequestAndOrigin: true))
        XCTAssertFalse(GoogleDriveRecoveryDecision.provesSameRequestRecovery(
            httpStatus: 404, methodIsGET: true, endpointIsFileMetadata: true, phaseIsRecovery: false,
            errorsEmpty: true, sameRequestAndOrigin: true))
    }

    func testItemMetadataErrorsDoNotDisableTheLibraryGrant() {
        XCTAssertEqual(GoogleDriveLibraryError.invalidRemoteFile.syncFailureScope, .failItemOnly)
        XCTAssertEqual(GoogleDriveLibraryError.changedManifest.syncFailureScope, .failItemOnly)
        XCTAssertEqual(GoogleDriveLibraryError.notAuthorized.syncFailureScope, .failItemOnly)
        XCTAssertEqual(GoogleDriveLibraryError.changedAccount.syncFailureScope, .disableLibrary)
        XCTAssertEqual(GoogleDriveLibraryError.invalidState.syncFailureScope, .disableLibrary)
        XCTAssertEqual(GoogleDriveLibraryError.notConfigured.syncFailureScope, .disableLibrary)
    }

    func testMissingIdentityCannotBecomeProviderUploaded() {
        XCTAssertFalse(ICloudDriveProviderAdmission.providerUploaded(
            identityMatches: nil, contentValidated: false, providerReportsUploaded: true, stampStable: true))
        XCTAssertTrue(ICloudDriveProviderAdmission.providerUploaded(
            identityMatches: nil, contentValidated: true, providerReportsUploaded: true, stampStable: true))
        XCTAssertFalse(ICloudDriveProviderAdmission.providerUploaded(
            identityMatches: false, contentValidated: true, providerReportsUploaded: true, stampStable: true))
        XCTAssertTrue(ICloudDriveProviderAdmission.providerUploaded(
            identityMatches: true, contentValidated: false, providerReportsUploaded: true, stampStable: true))
        XCTAssertFalse(ICloudDriveProviderAdmission.providerUploaded(
            identityMatches: true, contentValidated: true, providerReportsUploaded: true, stampStable: false))
        XCTAssertFalse(ICloudDriveProviderAdmission.providerUploaded(
            identityMatches: true, contentValidated: true, providerReportsUploaded: false, stampStable: true))
    }

    func testProviderChangeRetainsOnlyPreviouslyConfirmedUnchangedFiles() {
        XCTAssertTrue(ICloudDriveProviderAdmission.retainUploadedAfterProviderChange(
            previouslyConfirmed: true, stampMatches: true),
            "An unchanged confirmed path retains its as-of receipt without another provider metadata permit.")
        XCTAssertFalse(ICloudDriveProviderAdmission.retainUploadedAfterProviderChange(
            previouslyConfirmed: true, stampMatches: false),
            "Missing, moved, replaced or otherwise changed paths must lose their previous confirmation.")
        for stampMatches in [false, true] {
            XCTAssertFalse(ICloudDriveProviderAdmission.retainUploadedAfterProviderChange(
                previouslyConfirmed: false, stampMatches: stampMatches),
                "A local stamp alone cannot promote pending or invalid provider evidence.")
        }
    }

    func testConflictHeadLeavesTheNewExportQueueWithoutStarvingTheTail() {
        XCTAssertTrue(ICloudDriveExportAdmission.admitsNewExport(pendingExport: true, needsRepair: false, conflictBlocked: false))
        XCTAssertFalse(ICloudDriveExportAdmission.admitsNewExport(pendingExport: true, needsRepair: false, conflictBlocked: true))
        XCTAssertFalse(ICloudDriveExportAdmission.admitsNewExport(pendingExport: true, needsRepair: true, conflictBlocked: false))
        XCTAssertTrue(ICloudDriveExportAdmission.admitsRepair(pendingExport: true, needsRepair: false, conflictBlocked: true))
        XCTAssertTrue(ICloudDriveExportAdmission.admitsRepair(pendingExport: false, needsRepair: true, conflictBlocked: false))
        XCTAssertFalse(ICloudDriveExportAdmission.admitsRepair(pendingExport: false, needsRepair: false, conflictBlocked: true))
        let head = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let later = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let blocked: Set<UUID> = [head]
        let jobs = [head, later]
        let exports = jobs.filter {
            ICloudDriveExportAdmission.admitsNewExport(pendingExport: true, needsRepair: false, conflictBlocked: blocked.contains($0))
        }
        let repairs = jobs.filter {
            ICloudDriveExportAdmission.admitsRepair(pendingExport: true, needsRepair: false, conflictBlocked: blocked.contains($0))
        }
        XCTAssertEqual(exports, [later])
        XCTAssertEqual(repairs, [head])
    }

    func testHistoricalReplayAdvancesOnlyAfterASuccessfulHandoff() {
        let head = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let tail = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let pending = [head, tail]
        let held = HistoricalReceiptReplay.step(pending: pending, cursor: nil, verified: true, handoff: .unavailable)
        XCTAssertEqual(held.pending, pending)
        XCTAssertNil(held.cursor)
        XCTAssertFalse(held.committed)
        let missing = HistoricalReceiptReplay.step(pending: pending, cursor: nil, verified: true, handoff: nil)
        XCTAssertFalse(missing.committed)
        XCTAssertEqual(missing.pending, pending)
        for handoff in [HistoricalReceiptReplay.Handoff.queued, .alreadyQueued] {
            let sent = HistoricalReceiptReplay.step(pending: pending, cursor: nil, verified: true, handoff: handoff)
            XCTAssertEqual(sent.pending, [tail])
            XCTAssertEqual(sent.cursor, head)
            XCTAssertTrue(sent.committed)
        }
        let bad = HistoricalReceiptReplay.step(pending: pending, cursor: nil, verified: false, handoff: .unavailable)
        XCTAssertEqual(bad.pending, [tail])
        XCTAssertEqual(bad.cursor, head)
        XCTAssertTrue(bad.committed, "One unverifiable historical file must not block the tail.")
        let idle = HistoricalReceiptReplay.step(pending: [], cursor: head, verified: true, handoff: .queued)
        XCTAssertEqual(idle.cursor, head)
        XCTAssertFalse(idle.committed)
    }
}
