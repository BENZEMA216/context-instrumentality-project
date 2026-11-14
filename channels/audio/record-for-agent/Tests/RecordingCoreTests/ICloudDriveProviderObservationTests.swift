import Foundation
import XCTest
@testable import RecordingCore

final class ICloudDriveProviderObservationTests: XCTestCase {
    typealias Status = ICloudDriveProviderObservationStatus

    func testExplicitPendingMissingMetadataAndNonProviderFileRemainDistinct() {
        XCTAssertEqual(Status.metadata(regular: true, symbolicLink: false,
            ubiquitous: true, uploaded: true), .uploaded)
        XCTAssertEqual(Status.metadata(regular: true, symbolicLink: false,
            ubiquitous: true, uploaded: false), .notUploaded)
        XCTAssertEqual(Status.metadata(regular: true, symbolicLink: false,
            ubiquitous: true, uploaded: nil), .missingKey)
        XCTAssertEqual(Status.metadata(regular: true, symbolicLink: false,
            ubiquitous: nil, uploaded: true), .missingKey)
        XCTAssertEqual(Status.metadata(regular: true, symbolicLink: false,
            ubiquitous: false, uploaded: true), .notUbiquitous)
        XCTAssertEqual(Status.resourceError.applyingIdentity(fileAvailable: true,
            identityMatches: true, contentValidated: false, stampStable: true), .resourceError)
    }

    func testMissingOrUnsafeFileMetadataCannotCreatePositiveObservation() {
        for regular: Bool? in [nil, false, true] {
            for symlink: Bool? in [nil, false, true] {
                let result = Status.metadata(regular: regular, symbolicLink: symlink,
                    ubiquitous: true, uploaded: true)
                XCTAssertEqual(result == .uploaded, regular == true && symlink == false)
            }
        }
        XCTAssertEqual(Status.metadata(regular: false, symbolicLink: false,
            ubiquitous: nil, uploaded: nil), .invalidFile)
        XCTAssertEqual(Status.metadata(regular: true, symbolicLink: true,
            ubiquitous: true, uploaded: true), .invalidFile)
    }

    func testPositiveProviderFlagRequiresAvailableStableMatchingIdentityOrValidatedBody() {
        XCTAssertEqual(Status.uploaded.applyingIdentity(fileAvailable: false,
            identityMatches: true, contentValidated: true, stampStable: true), .fileUnavailable)
        XCTAssertEqual(Status.uploaded.applyingIdentity(fileAvailable: true,
            identityMatches: false, contentValidated: true, stampStable: true), .identityMismatch)
        XCTAssertEqual(Status.uploaded.applyingIdentity(fileAvailable: true,
            identityMatches: nil, contentValidated: false, stampStable: true), .identityMismatch)
        XCTAssertEqual(Status.uploaded.applyingIdentity(fileAvailable: true,
            identityMatches: true, contentValidated: false, stampStable: false), .fileChangedDuringCheck)
        XCTAssertEqual(Status.uploaded.applyingIdentity(fileAvailable: true,
            identityMatches: nil, contentValidated: true, stampStable: true), .uploaded)
        XCTAssertEqual(Status.notUploaded.applyingIdentity(fileAvailable: true,
            identityMatches: true, contentValidated: true, stampStable: true), .notUploaded)
    }

    func testLegacyBoolCacheMigrationDoesNotInventMissingFailureDetail() throws {
        struct CachedObservation: Decodable {
            let uploaded: Bool
            let failureCode: String?
            let status: Status?
            var restored: Status {
                .restored(status, legacyUploaded: uploaded, legacyFailureCode: failureCode)
            }
        }
        func decode(_ json: String) throws -> Status {
            let cached = try JSONDecoder().decode(CachedObservation.self, from: Data(json.utf8))
            return cached.restored
        }
        XCTAssertEqual(try decode(#"{"uploaded":true}"#), .uploaded)
        XCTAssertEqual(try decode(#"{"uploaded":false}"#), .legacyUnknown)
        XCTAssertEqual(try decode(#"{"uploaded":false,"failureCode":"provider_pending"}"#), .legacyUnknown)
        XCTAssertEqual(try decode(#"{"uploaded":true,"failureCode":"export_identity_changed"}"#), .identityMismatch)
        XCTAssertEqual(try decode(#"{"uploaded":false,"failureCode":"file_unavailable"}"#), .fileUnavailable)
        XCTAssertEqual(try decode(#"{"uploaded":false,"failureCode":"file_changed_during_check"}"#), .fileChangedDuringCheck)
    }

    func testLatestTypedNegativeAlwaysSupersedesRetainedLegacyPositive() throws {
        for status in Status.allCases where status != .uploaded {
            let encoded = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(Status.self, from: encoded)
            XCTAssertEqual(Status.restored(decoded, legacyUploaded: true,
                legacyFailureCode: nil), status)
        }
    }

    func testTypedDiagnosticCountsAreSeparateBoundedAndContainNoProviderErrorText() throws {
        let counts = ICloudDriveDiagnosticObservation.Counts(providerReportedPendingFiles: 3,
            providerMissingKeyFiles: 4, providerResourceErrorFiles: 5,
            providerNotUbiquitousFiles: 6, providerInvalidFileFiles: -1,
            providerLegacyUnknownFiles: .max)
        XCTAssertEqual(counts.providerReportedPendingFiles, 3)
        XCTAssertEqual(counts.providerMissingKeyFiles, 4)
        XCTAssertEqual(counts.providerResourceErrorFiles, 5)
        XCTAssertEqual(counts.providerNotUbiquitousFiles, 6)
        XCTAssertEqual(counts.providerInvalidFileFiles, 0)
        XCTAssertEqual(counts.providerLegacyUnknownFiles, 1_000_000_000)
        let bytes = try JSONEncoder().encode(counts)
        XCTAssertLessThan(bytes.count, 2_048)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["errorDescription"])
        XCTAssertNil(object["path"])
        XCTAssertEqual(object["providerResourceErrorFiles"] as? Int, 5)
    }

    func testNegativeRecheckDoesNotRewriteFirstAndLatestPositiveConfirmationTimes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = now.addingTimeInterval(-120), latest = now.addingTimeInterval(-60)
        let snapshot = ICloudDriveDiagnosticSnapshot(observation: .init(observedAt: now,
            latestProviderObservationAt: now, counts: .init(pendingProviderFiles: 1,
                providerReportedPendingFiles: 1), firstProviderConfirmationAt: first,
            latestProviderConfirmationAt: latest), at: now, connected: true, enabled: true)
        XCTAssertEqual(snapshot.status, .providerPending)
        XCTAssertEqual(snapshot.firstProviderConfirmationAt, first)
        XCTAssertEqual(snapshot.latestProviderConfirmationAt, latest)
        XCTAssertEqual(snapshot.latestProviderObservationAt, now)
    }

    func testMonitorFactsRemainIndependentFromFileConfirmationAndCannotCarryInvalidTimes() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ICloudDriveDiagnosticSnapshot(observation: nil, at: now,
            connected: true, enabled: true, providerMonitor: .init(startAttemptCount: .max,
                startSuccessCount: -1, startFailureCount: 1, notificationCount: 100,
                firstGatherAt: Date(timeIntervalSince1970: .infinity),
                latestNotificationAt: now.addingTimeInterval(6)))
        XCTAssertEqual(snapshot.status, .unknown)
        XCTAssertNil(snapshot.firstProviderConfirmationAt)
        XCTAssertNil(snapshot.latestProviderConfirmationAt)
        XCTAssertEqual(snapshot.providerMonitor?.startAttemptCount, 1_000_000_000)
        XCTAssertEqual(snapshot.providerMonitor?.startSuccessCount, 0)
        XCTAssertEqual(snapshot.providerMonitor?.startFailureCount, 1)
        XCTAssertEqual(snapshot.providerMonitor?.notificationCount, 100)
        XCTAssertNil(snapshot.providerMonitor?.firstGatherAt)
        XCTAssertNil(snapshot.providerMonitor?.latestNotificationAt)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))

        let invalid = ICloudDriveDiagnosticSnapshot(observation: .init(observedAt: now,
            firstProviderConfirmationAt: Date(timeIntervalSince1970: .nan),
            latestProviderConfirmationAt: now.addingTimeInterval(6)), at: now)
        XCTAssertNil(invalid.firstProviderConfirmationAt)
        XCTAssertNil(invalid.latestProviderConfirmationAt)
        XCTAssertNoThrow(try JSONEncoder().encode(invalid))
    }
}
