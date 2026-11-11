import Foundation
import XCTest
@testable import RecordingCore

/// Synthetic metadata only. These tests neither authorize an account nor upload
/// files, and a metadata receipt never represents an independent audio backup.
final class GoogleDriveLibraryTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private let owner = "synthetic-owner-permission-id"
    private let folder = "syntheticFolderID"
    private let session = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=synthetic-session"

    private func manifest(id: UUID = UUID(), startedAt: Date? = nil,
                          sha256: String = String(repeating: "a", count: 64),
                          location: SegmentLocation? = nil) -> SegmentManifest {
        let start = startedAt ?? instant
        return .init(id: id, sessionID: UUID(), sequence: 0, startedAt: start,
            endedAt: start.addingTimeInterval(10), sampleRate: 16_000, frameCount: 160_000,
            fileName: id.uuidString.lowercased() + ".caf", byteCount: 320_000, sha256: sha256,
            timeZoneIdentifier: "Asia/Shanghai", location: location)
    }

    private func transcript(_ source: SegmentManifest, text: String = "合成测试：明天下午三点核对三份文件。",
                            hash: String? = nil) -> SegmentTranscript {
        .init(segmentID: source.id, audioSHA256: hash ?? source.sha256, locale: "zh-CN",
              engine: "synthetic-fixture", createdAt: instant.addingTimeInterval(60), text: text, spans: [])
    }

    private func authorized(_ sources: [SegmentManifest]) throws -> GoogleDriveLibraryLedger {
        var ledger = GoogleDriveLibraryLedger()
        try ledger.bind(accountID: owner, label: "Synthetic account")
        try ledger.authorize(.existingAndFuture, knownIDs: Set(sources.map(\.id)), at: instant)
        try ledger.discover(manifests: sources, receivedIDs: Set(sources.map(\.id)))
        return ledger
    }

    private func artifact(_ ledger: GoogleDriveLibraryLedger, _ source: SegmentManifest,
                          kind: GoogleDriveArtifact.Kind = .audio) throws -> GoogleDriveArtifact {
        try XCTUnwrap(ledger.jobs.first(where: { $0.id == source.id })?.artifacts.first(where: { $0.kind == kind }))
    }

    private func remote(_ ledger: GoogleDriveLibraryLedger, _ source: SegmentManifest,
                        _ artifact: GoogleDriveArtifact) throws -> GoogleDriveRemoteFile {
        .init(id: try XCTUnwrap(artifact.fileID), size: String(artifact.byteCount),
              sha256Checksum: artifact.sha256, parents: [try XCTUnwrap(ledger.folderID)],
              ownedByMe: true, shared: false, trashed: false,
              appProperties: ["rfaSchema": "1", "rfaLibraryID": ledger.libraryID.uuidString.lowercased(),
                  "rfaSegmentID": source.id.uuidString.lowercased(), "rfaKind": artifact.kind.rawValue,
                  "rfaContentSHA256": artifact.sha256, "rfaAudioSHA256": source.sha256],
              permissions: [.init(id: owner, type: "user", role: "owner")])
    }

    private func roundTrip<T: Codable>(_ value: T, as type: T.Type = T.self) throws -> T {
        try TransportCodec.decode(type, from: TransportCodec.encode(value))
    }

    private func changedJSON<T: Codable>(_ value: T, _ mutation: (inout [String: Any]) -> Void) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: TransportCodec.encode(value)) as? [String: Any])
        mutation(&object)
        return try TransportCodec.decode(T.self, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    func testReceiptsAndDiscoveryDoNotEnableDriveWithoutItsOwnGrant() throws {
        let source = manifest()
        var ledger = GoogleDriveLibraryLedger()
        try ledger.discover(manifests: [source], receivedIDs: [source.id])
        XCTAssertTrue(ledger.jobs.isEmpty)
        XCTAssertFalse(ledger.enabled)
        XCTAssertThrowsError(try ledger.setEnabled(true))
        XCTAssertThrowsError(try ledger.authorize(.existingAndFuture, knownIDs: [source.id], at: instant))
        try ledger.bind(accountID: owner, label: "Synthetic account")
        try ledger.discover(manifests: [source], receivedIDs: [source.id])
        XCTAssertTrue(ledger.jobs.isEmpty, "An account connection alone is not a recording grant.")
        XCTAssertFalse(ledger.enabled)
    }

    func testExistingAndFutureScopeRequiresDurableReceiptAndKeepsScopeFixed() throws {
        let old = manifest(startedAt: instant.addingTimeInterval(-60))
        let future = manifest(startedAt: instant.addingTimeInterval(60))
        var ledger = try authorized([old])
        try ledger.discover(manifests: [old, future], receivedIDs: [old.id])
        XCTAssertEqual(ledger.jobs.map(\.id), [old.id])
        try ledger.discover(manifests: [old, future], receivedIDs: [old.id, future.id])
        XCTAssertEqual(Set(ledger.jobs.map(\.id)), [old.id, future.id])
        let before = ledger
        XCTAssertThrowsError(try ledger.authorize(.futureOnly, knownIDs: [], at: instant.addingTimeInterval(120)))
        XCTAssertEqual(ledger, before)
    }

    func testFutureOnlyExcludesBaselineAndBackdatedLateArrivalsAtExactBoundary() throws {
        let baseline = manifest(startedAt: instant.addingTimeInterval(1))
        let backdated = manifest(startedAt: instant.addingTimeInterval(-0.001))
        let boundary = manifest(startedAt: instant)
        let future = manifest(startedAt: instant.addingTimeInterval(1))
        var ledger = GoogleDriveLibraryLedger()
        try ledger.bind(accountID: owner, label: "Synthetic account")
        try ledger.authorize(.futureOnly, knownIDs: [baseline.id], at: instant)
        try ledger.discover(manifests: [baseline, backdated, boundary, future],
                            receivedIDs: [baseline.id, backdated.id, boundary.id, future.id])
        XCTAssertEqual(Set(ledger.jobs.map(\.id)), [boundary.id, future.id])
        let restored = try roundTrip(ledger)
        try restored.validate()
        XCTAssertEqual(restored.baselineIDs, [baseline.id])
        XCTAssertEqual(restored.authorizedAt, instant)
        XCTAssertEqual(restored.recordingScope, .futureOnly)
    }

    func testAccountFenceSurvivesPauseRevocationAndSerialization() throws {
        let source = manifest()
        var ledger = try authorized([source])
        let libraryID = ledger.libraryID
        try ledger.setEnabled(false)
        ledger.revoke(remoteConfirmed: true)
        var restored = try roundTrip(ledger)
        try restored.validate()
        let before = restored
        XCTAssertThrowsError(try restored.bind(accountID: "other-owner", label: "Other")) {
            XCTAssertEqual($0 as? GoogleDriveLibraryError, .changedAccount)
        }
        XCTAssertEqual(restored, before)
        try restored.bind(accountID: owner, label: "Synthetic account")
        try restored.setEnabled(true)
        XCTAssertEqual(restored.libraryID, libraryID)
        XCTAssertEqual(restored.jobs, ledger.jobs)
        XCTAssertFalse(restored.revokedLocally)
        XCTAssertFalse(restored.remoteRevocationConfirmed)
    }

    func testFreshReauthorizationSupersedesPendingRevokeWithoutResumingOrChangingGrant() throws {
        let source = manifest()
        for remoteConfirmed in [false, true] {
            var ledger = try authorized([source])
            try ledger.allocateFolder(folder)
            ledger.revoke(remoteConfirmed: remoteConfirmed)
            let previous = ledger
            try ledger.recordReauthorization(accountID: owner, label: "Fresh same account")
            try ledger.validate()
            XCTAssertFalse(ledger.enabled)
            XCTAssertFalse(ledger.revokedLocally)
            XCTAssertFalse(ledger.remoteRevocationConfirmed, "Fresh consent is not proof of an old revoke request.")
            XCTAssertEqual(ledger.libraryID, previous.libraryID)
            XCTAssertEqual(ledger.accountID, previous.accountID)
            XCTAssertEqual(ledger.folderID, previous.folderID)
            XCTAssertEqual(ledger.recordingScope, previous.recordingScope)
            XCTAssertEqual(ledger.authorizedAt, previous.authorizedAt)
            XCTAssertEqual(ledger.baselineIDs, previous.baselineIDs)
            XCTAssertEqual(ledger.jobs, previous.jobs)
            XCTAssertEqual(try roundTrip(ledger), ledger)
        }
    }

    func testFreshReauthorizationRejectsDifferentAccountAtomicallyAndAllowsUnscopedReconnect() throws {
        var ledger = try authorized([manifest()])
        ledger.revoke()
        let before = ledger
        XCTAssertThrowsError(try ledger.recordReauthorization(accountID: "other-account", label: "Other"))
        XCTAssertEqual(ledger, before)
        var unscoped = GoogleDriveLibraryLedger()
        try unscoped.bind(accountID: owner, label: "Original")
        unscoped.revoke()
        try unscoped.recordReauthorization(accountID: owner, label: "Fresh original")
        XCTAssertNil(unscoped.recordingScope)
        XCTAssertFalse(unscoped.enabled)
        XCTAssertFalse(unscoped.revokedLocally)
        try unscoped.validate()
    }

    func testFirstScopeCanBeAuthorizedAfterRevokingAnUnscopedConnection() throws {
        var ledger = GoogleDriveLibraryLedger()
        try ledger.bind(accountID: owner, label: "Synthetic account")
        let identity = ledger.libraryID
        ledger.revoke(remoteConfirmed: true)
        XCTAssertNil(ledger.recordingScope)
        XCTAssertTrue(ledger.remoteRevocationConfirmed)
        try ledger.bind(accountID: owner, label: "Same synthetic account")
        try ledger.authorize(.futureOnly, knownIDs: [], at: instant)
        try ledger.validate()
        XCTAssertTrue(ledger.enabled)
        XCTAssertFalse(ledger.revokedLocally)
        XCTAssertFalse(ledger.remoteRevocationConfirmed)
        XCTAssertEqual(ledger.libraryID, identity)
        XCTAssertEqual(ledger.accountID, owner)
        XCTAssertThrowsError(try ledger.bind(accountID: "another-owner", label: "Other account"))
    }

    func testDuplicateOrChangedManifestFailsAtomically() throws {
        let original = manifest()
        var ledger = try authorized([original])
        let before = ledger
        XCTAssertThrowsError(try ledger.discover(manifests: [original, original], receivedIDs: [original.id]))
        let altered = SegmentManifest(id: original.id, sessionID: original.sessionID, sequence: original.sequence,
            startedAt: original.startedAt, endedAt: original.endedAt, sampleRate: original.sampleRate,
            frameCount: original.frameCount, fileName: original.fileName, byteCount: original.byteCount,
            sha256: String(repeating: "b", count: 64), timeZoneIdentifier: original.timeZoneIdentifier)
        let newSource = manifest()
        XCTAssertThrowsError(try ledger.discover(manifests: [newSource, altered], receivedIDs: [original.id, newSource.id])) {
            XCTAssertEqual($0 as? GoogleDriveLibraryError, .changedManifest)
        }
        XCTAssertEqual(ledger, before, "A later invalid item must not leave an earlier new job committed.")
    }

    func testFolderAndFileIDsAreImmutableAndCannotAliasOtherObjects() throws {
        let source = manifest()
        var ledger = try authorized([source])
        try ledger.allocateFolder(folder)
        let audio = try artifact(ledger, source)
        let metadata = try artifact(ledger, source, kind: .manifest)
        try ledger.allocateFile(segmentID: source.id, key: audio.key, fileID: "syntheticAudioID")
        try ledger.allocateFolder(folder)
        try ledger.allocateFile(segmentID: source.id, key: audio.key, fileID: "syntheticAudioID")
        let before = ledger
        XCTAssertThrowsError(try ledger.allocateFolder("replacementFolderID"))
        XCTAssertThrowsError(try ledger.allocateFile(segmentID: source.id, key: audio.key, fileID: "replacementAudioID"))
        XCTAssertThrowsError(try ledger.allocateFile(segmentID: source.id, key: metadata.key, fileID: "syntheticAudioID"))
        XCTAssertThrowsError(try ledger.allocateFile(segmentID: source.id, key: metadata.key, fileID: folder))
        XCTAssertThrowsError(try ledger.allocateFile(segmentID: UUID(), key: audio.key, fileID: "unknownSegmentID"))
        XCTAssertEqual(ledger, before)
        var restored = try roundTrip(ledger)
        try restored.validate()
        XCTAssertThrowsError(try restored.allocateFile(segmentID: source.id, key: audio.key, fileID: "replacementAudioID"))
        XCTAssertEqual(restored, before)
    }

    func testSameDigestInTwoSegmentsStillCannotShareRemoteFileIdentity() throws {
        let first = manifest(), second = manifest()
        var ledger = try authorized([first, second])
        let audio = try artifact(ledger, first)
        try ledger.allocateFile(segmentID: first.id, key: audio.key, fileID: "syntheticAudioID")
        let before = ledger
        XCTAssertThrowsError(try ledger.allocateFile(segmentID: second.id, key: audio.key, fileID: "syntheticAudioID"))
        XCTAssertEqual(ledger, before)
    }

    func testSessionPauseFailureAndRestartNeverInventSavedReceipt() throws {
        let source = manifest()
        var ledger = try authorized([source])
        let audio = try artifact(ledger, source)
        XCTAssertThrowsError(try ledger.recordSession(segmentID: source.id, key: audio.key, url: session))
        try ledger.allocateFolder(folder)
        try ledger.allocateFile(segmentID: source.id, key: audio.key, fileID: "syntheticAudioID")
        try ledger.recordSession(segmentID: source.id, key: audio.key, url: session)
        ledger.recordFailure(at: instant)
        try ledger.setEnabled(false)
        var restored = try roundTrip(ledger)
        try restored.validate()
        XCTAssertEqual(try artifact(restored, source).uploadURL, session)
        XCTAssertEqual(try artifact(restored, source).fileID, "syntheticAudioID")
        XCTAssertEqual(restored.savedAudioCount, 0)
        XCTAssertEqual(restored.savedTranscriptCount, 0)
        XCTAssertTrue(restored.hasPendingFiles)
        XCTAssertEqual(restored.retryAfter, instant.addingTimeInterval(15))
        try restored.setEnabled(true)
        XCTAssertNil(restored.retryAfter)
        XCTAssertEqual(restored.failureCount, 0)
        XCTAssertEqual(try artifact(restored, source).uploadURL, session)
        try restored.recordSession(segmentID: source.id, key: audio.key, url: nil)
        XCTAssertEqual(try artifact(restored, source).fileID, "syntheticAudioID", "An expired upload keeps its durable file ID.")
        XCTAssertEqual(restored.savedAudioCount, 0)
    }

    func testOnlyCompleteOwnerBoundMetadataReceiptMarksAudioSaved() throws {
        let source = manifest()
        var ledger = try authorized([source])
        try ledger.allocateFolder(folder)
        let key = try artifact(ledger, source).key
        try ledger.allocateFile(segmentID: source.id, key: key, fileID: "syntheticAudioID")
        try ledger.recordSession(segmentID: source.id, key: key, url: session)
        let audio = try artifact(ledger, source)
        let receipt = try remote(ledger, source, audio)
        let before = ledger
        XCTAssertThrowsError(try ledger.recordVerified(segmentID: source.id, key: key, file: receipt, in: "other-owner", at: instant))
        XCTAssertEqual(ledger, before)
        try ledger.recordVerified(segmentID: source.id, key: key, file: receipt, in: owner, at: instant)
        XCTAssertEqual(ledger.savedAudioCount, 1)
        XCTAssertEqual(ledger.savedTranscriptCount, 0)
        XCTAssertEqual(try artifact(ledger, source).verifiedAt, instant)
        XCTAssertEqual(try artifact(ledger, source).verifiedUploadCorrelation,
                       .init(segmentID: source.id, kind: .audio, manifestSHA256: source.sha256))
        XCTAssertNil(try artifact(ledger, source).uploadURL)
        XCTAssertTrue(ledger.hasPendingFiles, "The manifest is independently pending.")
        XCTAssertThrowsError(try ledger.recordSession(segmentID: source.id, key: key, url: session))
        let restored = try roundTrip(ledger)
        try restored.validate()
        XCTAssertEqual(restored, ledger)
    }

    func testLegacyStrictReceiptKeepsHistoricalTimeButDoesNotInventJobCorrelation() throws {
        let source = manifest()
        var ledger = try authorized([source])
        try ledger.allocateFolder(folder)
        let key = try artifact(ledger, source).key
        try ledger.allocateFile(segmentID: source.id, key: key, fileID: "syntheticAudioID")
        let receipt = try remote(ledger, source, artifact(ledger, source))
        try ledger.recordVerified(segmentID: source.id, key: key, file: receipt, in: owner, at: instant)
        let legacy = try changedJSON(ledger) { object in
            var jobs = object["jobs"] as! [[String: Any]]
            var artifacts = jobs[0]["artifacts"] as! [[String: Any]]
            for index in artifacts.indices { artifacts[index].removeValue(forKey: "verifiedUploadCorrelation") }
            jobs[0]["artifacts"] = artifacts; object["jobs"] = jobs
        }
        try legacy.validate()
        XCTAssertEqual(try artifact(legacy, source).verifiedAt, instant)
        XCTAssertNil(try artifact(legacy, source).verifiedUploadCorrelation)
        XCTAssertEqual(legacy.savedAudioCount, 1, "Historical receipts remain stored; they cannot prove a correlated recovery")
    }

    func testMissingReceiptFieldsFailClosedWithoutMutatingQueue() throws {
        let source = manifest()
        var ledger = try authorized([source])
        try ledger.allocateFolder(folder)
        let key = try artifact(ledger, source).key
        try ledger.allocateFile(segmentID: source.id, key: key, fileID: "syntheticAudioID")
        let receipt = try remote(ledger, source, artifact(ledger, source))
        for field in ["size", "sha256Checksum", "parents", "ownedByMe", "shared", "trashed", "appProperties", "permissions"] {
            let altered = try changedJSON(receipt) { $0.removeValue(forKey: field) }
            let before = ledger
            XCTAssertThrowsError(try ledger.recordVerified(segmentID: source.id, key: key, file: altered, in: owner, at: instant), field) {
                XCTAssertEqual($0 as? GoogleDriveLibraryError, .metadataIncomplete, field)
            }
            XCTAssertEqual(ledger, before, field)
        }
        for field in ["rfaSchema", "rfaLibraryID", "rfaSegmentID", "rfaKind", "rfaContentSHA256", "rfaAudioSHA256"] {
            let altered = try changedJSON(receipt) { object in
                var properties = object["appProperties"] as! [String: Any]
                properties.removeValue(forKey: field); object["appProperties"] = properties
            }
            XCTAssertThrowsError(try ledger.recordVerified(segmentID: source.id, key: key, file: altered, in: owner, at: instant), field) {
                XCTAssertEqual($0 as? GoogleDriveLibraryError, .metadataIncomplete, field)
            }
            XCTAssertEqual(ledger.savedAudioCount, 0)
        }
    }

    func testIncompleteMetadataRecoversOnlyWithExactReceiptAfterRestart() throws {
        let source = manifest(), peer = manifest()
        var ledger = try authorized([source, peer])
        try ledger.allocateFolder(folder)
        let key = try artifact(ledger, source).key
        try ledger.allocateFile(segmentID: source.id, key: key, fileID: "syntheticAudioID")
        try ledger.recordSession(segmentID: source.id, key: key, url: session)
        let receipt = try remote(ledger, source, artifact(ledger, source))
        for field in ["size", "sha256Checksum", "permissionID", "permissionRole", "permissionType"] {
            let incomplete = try changedJSON(receipt) { object in
                if field.hasPrefix("permission") {
                    var permissions = object["permissions"] as! [[String: Any]]
                    let key = field == "permissionID" ? "id" : field == "permissionRole" ? "role" : "type"
                    permissions[0].removeValue(forKey: key); object["permissions"] = permissions
                } else { object.removeValue(forKey: field) }
            }
            XCTAssertThrowsError(try ledger.recordVerified(segmentID: source.id, key: key, file: incomplete, in: owner, at: instant)) {
                XCTAssertEqual($0 as? GoogleDriveLibraryError, .metadataIncomplete)
            }
            ledger = try roundTrip(ledger)
            XCTAssertEqual(try artifact(ledger, source).uploadURL, session)
            XCTAssertNil(try artifact(ledger, source).verifiedAt)
        }
        try ledger.recordVerified(segmentID: source.id, key: key, file: receipt, in: owner, at: instant)
        XCTAssertEqual(ledger.savedAudioCount, 1)
        XCTAssertNil(try artifact(ledger, peer).verifiedAt, "Recovery of one source cannot verify its peer")
        XCTAssertEqual(try artifact(ledger, source).fileID, receipt.id)
        XCTAssertNil(try artifact(ledger, source).uploadURL)
    }

    func testKnownConflictTakesPrecedenceOverIncompleteMetadata() throws {
        let source = manifest()
        var ledger = try authorized([source])
        try ledger.allocateFolder(folder)
        let key = try artifact(ledger, source).key
        try ledger.allocateFile(segmentID: source.id, key: key, fileID: "syntheticAudioID")
        let receipt = try remote(ledger, source, artifact(ledger, source))
        for (field, value) in [("sha256Checksum", String(repeating: "b", count: 64) as Any),
                               ("parents", ["foreignFolderID"] as Any), ("shared", true as Any),
                               ("permissions", [["id": "foreign-owner"]] as Any)] {
            let conflicting = try changedJSON(receipt) { object in
                object.removeValue(forKey: "size"); object[field] = value
            }
            let before = ledger
            XCTAssertThrowsError(try ledger.recordVerified(segmentID: source.id, key: key, file: conflicting, in: owner, at: instant)) {
                XCTAssertEqual($0 as? GoogleDriveLibraryError, .invalidRemoteFile)
            }
            XCTAssertEqual(ledger, before)
        }
    }

    func testWrongDigestSizeParentIdentityOrSharingNeverMarksSaved() throws {
        let source = manifest()
        var ledger = try authorized([source])
        try ledger.allocateFolder(folder)
        let key = try artifact(ledger, source).key
        try ledger.allocateFile(segmentID: source.id, key: key, fileID: "syntheticAudioID")
        let receipt = try remote(ledger, source, artifact(ledger, source))
        let mutations: [(String, Any)] = [
            ("id", "otherRemoteFileID"), ("size", "319999"), ("size", "not-a-number"),
            ("sha256Checksum", String(repeating: "b", count: 64)), ("parents", ["otherFolderID"]),
            ("parents", [folder, "otherFolderID"]), ("ownedByMe", false), ("shared", true), ("trashed", true),
            ("permissions", []),
            ("permissions", [["id": "other-owner", "type": "user", "role": "owner"]]),
            ("permissions", [["id": owner, "type": "user", "role": "reader"]]),
            ("permissions", [["id": owner, "type": "domain", "role": "owner"]]),
            ("permissions", [["id": owner, "type": "user", "role": "owner", "deleted": true]]),
            ("permissions", [["id": owner, "type": "user", "role": "owner"], ["type": "anyone", "role": "reader"]])
        ]
        for (field, value) in mutations {
            let altered = try changedJSON(receipt) { $0[field] = value }
            let before = ledger
            XCTAssertThrowsError(try ledger.recordVerified(segmentID: source.id, key: key, file: altered, in: owner, at: instant), field) {
                XCTAssertEqual($0 as? GoogleDriveLibraryError, .invalidRemoteFile, field)
            }
            XCTAssertEqual(ledger, before, field)
        }
    }

    func testLateAndRevisedTranscriptsAddVersionsWithoutChangingAudioReceipt() throws {
        let source = manifest()
        var ledger = try authorized([source])
        try ledger.allocateFolder(folder)
        let key = try artifact(ledger, source).key
        try ledger.allocateFile(segmentID: source.id, key: key, fileID: "syntheticAudioID")
        let receipt = try remote(ledger, source, artifact(ledger, source))
        try ledger.recordVerified(segmentID: source.id, key: key, file: receipt, in: owner, at: instant)
        let savedAudio = try artifact(ledger, source)
        let first = transcript(source)
        try ledger.discoverTranscript(first, for: source)
        let firstVersion = ledger
        try ledger.discoverTranscript(first, for: source)
        XCTAssertEqual(ledger, firstVersion, "Repeated discovery is idempotent.")
        try ledger.discoverTranscript(transcript(source, text: "修订后的合成资料：共有四份文件。"), for: source)
        XCTAssertEqual(ledger.jobs[0].artifacts.filter { $0.kind == .transcriptJSON }.count, 2)
        XCTAssertEqual(ledger.jobs[0].artifacts.filter { $0.kind == .transcriptText }.count, 2)
        XCTAssertEqual(try artifact(ledger, source), savedAudio)
        XCTAssertEqual(ledger.savedAudioCount, 1)
        XCTAssertEqual(ledger.savedTranscriptCount, 0, "Discovering text is not a cloud receipt.")
        let restored = try roundTrip(ledger)
        try restored.validate()
        XCTAssertEqual(restored, ledger)
    }

    func testTranscriptMustMatchBothAuthorizedSegmentAndAudio() throws {
        let source = manifest(), unselected = manifest()
        var ledger = try authorized([source])
        let before = ledger
        XCTAssertThrowsError(try ledger.discoverTranscript(transcript(unselected), for: unselected))
        XCTAssertThrowsError(try ledger.discoverTranscript(transcript(source, hash: String(repeating: "b", count: 64)), for: source))
        XCTAssertEqual(ledger, before)
    }

    func testExportOmitsLocationWhilePreservingOriginalAndManifestArtifactDigest() throws {
        let location = SegmentLocation(latitude: 1.25, longitude: 2.5, horizontalAccuracy: 3, capturedAt: instant)
        let source = manifest(location: location)
        let ledger = try authorized([source])
        let exported = GoogleDriveLibraryLedger.exportManifest(source)
        XCTAssertNil(exported.location)
        XCTAssertEqual(exported.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(source.location, location)
        XCTAssertEqual(ledger.jobs[0].manifest.location, location, "The immutable local manifest remains intact.")
        let bytes = try TransportCodec.encode(exported)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["location"])
        let metadata = try artifact(ledger, source, kind: .manifest)
        XCTAssertEqual(metadata.sha256, GoogleDriveLibraryLedger.digest(bytes))
        XCTAssertEqual(metadata.byteCount, Int64(bytes.count))
    }

    func testRestoredCorruptionCannotExpandFutureGrantOrForgeArtifactIdentity() throws {
        let source = manifest(startedAt: instant.addingTimeInterval(1))
        var ledger = GoogleDriveLibraryLedger()
        try ledger.bind(accountID: owner, label: "Synthetic account")
        try ledger.authorize(.futureOnly, knownIDs: [], at: instant)
        try ledger.discover(manifests: [source], receivedIDs: [source.id])
        let invalidBaseline = try changedJSON(ledger) { $0["baselineIDs"] = [source.id.uuidString] }
        XCTAssertThrowsError(try invalidBaseline.validate())
        let invalidSchema = try changedJSON(ledger) { $0["schemaVersion"] = 99 }
        XCTAssertThrowsError(try invalidSchema.validate())
        for kind in ["audio", "manifest"] {
            let changed = try changedJSON(ledger) { object in
                var jobs = object["jobs"] as! [[String: Any]]
                var artifacts = jobs[0]["artifacts"] as! [[String: Any]]
                let index = artifacts.firstIndex(where: { $0["kind"] as? String == kind })!
                artifacts[index]["sha256"] = String(repeating: "b", count: 64)
                jobs[0]["artifacts"] = artifacts; object["jobs"] = jobs
            }
            XCTAssertThrowsError(try changed.validate(), kind)
        }
        let noFileID = try changedJSON(ledger) { object in
            var jobs = object["jobs"] as! [[String: Any]]
            var artifacts = jobs[0]["artifacts"] as! [[String: Any]]
            artifacts[0]["uploadURL"] = session
            jobs[0]["artifacts"] = artifacts; object["jobs"] = jobs
        }
        XCTAssertThrowsError(try noFileID.validate())
        XCTAssertEqual(ledger.savedAudioCount, 0)
    }

    func testRetryIsBoundedAndDoesNotAlterBindingsOrFileReceipts() throws {
        let source = manifest()
        var ledger = try authorized([source])
        let jobs = ledger.jobs, identity = ledger.libraryID
        for _ in 0..<30 { ledger.recordFailure(at: instant) }
        XCTAssertEqual(ledger.failureCount, 16)
        XCTAssertEqual(ledger.retryAfter, instant.addingTimeInterval(3_600))
        XCTAssertEqual(ledger.jobs, jobs)
        XCTAssertEqual(ledger.libraryID, identity)
        XCTAssertEqual(ledger.accountID, owner)
        XCTAssertEqual(ledger.savedAudioCount, 0)
        ledger.clearRetry()
        XCTAssertNil(ledger.retryAfter)
        XCTAssertEqual(ledger.failureCount, 0)
    }

    func testNewVerifiedReceiptResetsConsecutiveFailureBackoffWithPendingQueue() throws {
        let source = manifest()
        var ledger = try authorized([source])
        try ledger.allocateFolder(folder)
        let key = try artifact(ledger, source).key
        try ledger.allocateFile(segmentID: source.id, key: key, fileID: "syntheticAudioID")
        try ledger.recordSession(segmentID: source.id, key: key, url: session)
        for _ in 0..<3 { ledger.recordFailure(at: instant) }
        XCTAssertEqual(ledger.failureCount, 3)
        XCTAssertEqual(ledger.retryAfter, instant.addingTimeInterval(60))
        // Resume from the same encoded state the next app round would restore.
        ledger = try roundTrip(ledger)
        let receipt = try remote(ledger, source, artifact(ledger, source))
        try ledger.recordVerified(segmentID: source.id, key: key, file: receipt, in: owner, at: instant)
        XCTAssertEqual(ledger.failureCount, 0)
        XCTAssertNil(ledger.retryAfter)
        XCTAssertEqual(ledger.savedAudioCount, 1)
        XCTAssertNil(try artifact(ledger, source).uploadURL)
        XCTAssertEqual(try artifact(ledger, source).fileID, receipt.id)
        XCTAssertTrue(ledger.hasPendingFiles, "The manifest is still pending; draining the queue is not needed to reset backoff.")
        ledger = try roundTrip(ledger)
        ledger.recordFailure(at: instant.addingTimeInterval(10))
        XCTAssertEqual(ledger.failureCount, 1)
        XCTAssertEqual(ledger.retryAfter, instant.addingTimeInterval(25))
    }

    func testNewManifestAndTranscriptReceiptsAlsoResetBackoffButDiscoveryDoesNot() throws {
        let source = manifest()
        var ledger = try authorized([source])
        try ledger.allocateFolder(folder)
        ledger.recordFailure(at: instant)
        let beforeDiscovery = ledger.retryAfter
        try ledger.discoverTranscript(transcript(source), for: source)
        XCTAssertEqual(ledger.failureCount, 1)
        XCTAssertEqual(ledger.retryAfter, beforeDiscovery)
        for kind in [GoogleDriveArtifact.Kind.manifest, .transcriptJSON, .transcriptText] {
            ledger.recordFailure(at: instant)
            let key = try artifact(ledger, source, kind: kind).key
            try ledger.allocateFile(segmentID: source.id, key: key, fileID: "synthetic-" + kind.rawValue + "ID")
            XCTAssertGreaterThan(ledger.failureCount, 0, "An allocation is not durable progress.")
            let receipt = try remote(ledger, source, artifact(ledger, source, kind: kind))
            try ledger.recordVerified(segmentID: source.id, key: key, file: receipt, in: owner, at: instant)
            XCTAssertEqual(ledger.failureCount, 0, kind.rawValue)
            XCTAssertNil(ledger.retryAfter, kind.rawValue)
            XCTAssertTrue(ledger.hasPendingFiles, "The original audio remains pending.")
        }
        XCTAssertEqual(ledger.savedAudioCount, 0)
        XCTAssertEqual(ledger.savedTranscriptCount, 1)
    }

    func testDuplicateVerifiedReceiptDoesNotResetBackoffAfterRestart() throws {
        let source = manifest()
        var ledger = try authorized([source])
        try ledger.allocateFolder(folder)
        let key = try artifact(ledger, source).key
        try ledger.allocateFile(segmentID: source.id, key: key, fileID: "syntheticAudioID")
        let receipt = try remote(ledger, source, artifact(ledger, source))
        try ledger.recordVerified(segmentID: source.id, key: key, file: receipt, in: owner, at: instant)
        ledger.recordFailure(at: instant)
        ledger.recordFailure(at: instant)
        ledger = try roundTrip(ledger)
        let retryAfter = ledger.retryAfter
        try ledger.recordVerified(segmentID: source.id, key: key, file: receipt, in: owner, at: instant.addingTimeInterval(1))
        XCTAssertEqual(ledger.failureCount, 2)
        XCTAssertEqual(ledger.retryAfter, retryAfter)
        XCTAssertEqual(ledger.savedAudioCount, 1)
        XCTAssertEqual(try artifact(ledger, source).fileID, receipt.id)
        XCTAssertNil(try artifact(ledger, source).uploadURL)
        ledger.recordFailure(at: instant.addingTimeInterval(2))
        XCTAssertEqual(ledger.failureCount, 3)
        XCTAssertEqual(ledger.retryAfter, instant.addingTimeInterval(62))
    }

    func testRejectedReceiptCannotClearBackoffOrPartiallyCommitProgress() throws {
        let source = manifest()
        var ledger = try authorized([source])
        try ledger.allocateFolder(folder)
        let key = try artifact(ledger, source).key
        try ledger.allocateFile(segmentID: source.id, key: key, fileID: "syntheticAudioID")
        try ledger.recordSession(segmentID: source.id, key: key, url: session)
        for _ in 0..<4 { ledger.recordFailure(at: instant) }
        let receipt = try remote(ledger, source, artifact(ledger, source))
        let before = ledger
        XCTAssertThrowsError(try ledger.recordVerified(segmentID: source.id, key: key, file: receipt, in: "other-owner", at: instant))
        XCTAssertEqual(ledger, before)
        XCTAssertThrowsError(try ledger.recordVerified(segmentID: source.id, key: key, file: receipt, in: owner, at: Date(timeIntervalSince1970: .infinity)))
        XCTAssertEqual(ledger, before)
        for (field, value) in [("size", "319999"), ("sha256Checksum", String(repeating: "b", count: 64))] {
            let invalid = try changedJSON(receipt) { $0[field] = value }
            XCTAssertThrowsError(try ledger.recordVerified(segmentID: source.id, key: key, file: invalid, in: owner, at: instant), field)
            XCTAssertEqual(ledger, before, field)
        }
        let shared = try changedJSON(receipt) { $0["shared"] = true }
        XCTAssertThrowsError(try ledger.recordVerified(segmentID: source.id, key: key, file: shared, in: owner, at: instant))
        XCTAssertEqual(ledger, before)
        let wrongSource = try changedJSON(receipt) { object in
            var properties = object["appProperties"] as! [String: Any]
            properties["rfaSegmentID"] = UUID().uuidString.lowercased(); object["appProperties"] = properties
        }
        XCTAssertThrowsError(try ledger.recordVerified(segmentID: source.id, key: key, file: wrongSource, in: owner, at: instant))
        XCTAssertEqual(ledger, before)
        // A valid receipt still cannot commit when the surrounding restored state fails validation.
        var invalidState = try changedJSON(ledger) { $0["schemaVersion"] = 99 }
        let invalidBefore = invalidState
        XCTAssertThrowsError(try invalidState.recordVerified(segmentID: source.id, key: key, file: receipt, in: owner, at: instant))
        XCTAssertEqual(invalidState, invalidBefore)
    }

    func testIntermittentFailuresDuringLargeQueueStayAtFirstRetryAfterEachNewReceipt() throws {
        let sources = (0..<281).map { _ in manifest() }
        var ledger = try authorized(sources)
        try ledger.allocateFolder(folder)
        let identity = ledger.libraryID
        for (index, source) in sources.prefix(12).enumerated() {
            let now = instant.addingTimeInterval(Double(index * 60))
            ledger.recordFailure(at: now)
            XCTAssertEqual(ledger.failureCount, 1, "An earlier successful round must break the failure streak.")
            XCTAssertEqual(ledger.retryAfter, now.addingTimeInterval(15))
            let key = try artifact(ledger, source).key
            try ledger.allocateFile(segmentID: source.id, key: key, fileID: "syntheticAudioID" + String(index))
            let receipt = try remote(ledger, source, artifact(ledger, source))
            try ledger.recordVerified(segmentID: source.id, key: key, file: receipt, in: owner, at: now.addingTimeInterval(15))
            ledger = try roundTrip(ledger)
            XCTAssertEqual(ledger.failureCount, 0)
            XCTAssertNil(ledger.retryAfter)
            XCTAssertEqual(ledger.savedAudioCount, index + 1)
            XCTAssertTrue(ledger.hasPendingFiles)
        }
        XCTAssertEqual(ledger.jobs.count, 281)
        XCTAssertEqual(ledger.libraryID, identity)
        for count in 1...10 {
            ledger.recordFailure(at: instant)
            XCTAssertEqual(ledger.failureCount, count)
            XCTAssertEqual(ledger.retryAfter, instant.addingTimeInterval(min(3_600, 15 * pow(2, Double(min(count, 9) - 1)))))
        }
        XCTAssertEqual(ledger.savedAudioCount, 12, "A pure failure streak does not invent further progress.")
    }

    func testUploadURLAndFileIDAllowlistRejectsCredentialAndDestinationConfusion() {
        XCTAssertTrue(GoogleDriveLibraryLedger.validUploadURL(session))
        for url in [
            "http://www.googleapis.com/upload/drive/v3/files?upload_id=test",
            "https://www.googleapis.com.evil.invalid/upload/drive/v3/files",
            "https://evil.invalid/upload/drive/v3/files",
            "https://www.googleapis.com:443/upload/drive/v3/files",
            "https://name:secret@www.googleapis.com/upload/drive/v3/files",
            "https://www.googleapis.com/upload/drive/v3/files#fragment",
            "https://www.googleapis.com/drive/v3/files",
            "https://www.googleapis.com/upload/drive/v3/files/other",
            "https://www.googleapis.com/upload/drive/v3/files?access_token=secret",
            "https://www.googleapis.com/upload/drive/v3/files?token=secret",
            "https://www.googleapis.com/upload/drive/v3/files?key=secret"
        ] { XCTAssertFalse(GoogleDriveLibraryLedger.validUploadURL(url), url) }
        for id in ["", "short", "../synthetic", "https://drive.google.com/file/d/id", "synthetic ID", String(repeating: "a", count: 257)] {
            XCTAssertFalse(GoogleDriveLibraryLedger.validFileID(id), id)
        }
        XCTAssertTrue(GoogleDriveLibraryLedger.validFileID("synthetic_file-ID123"))
    }
}

final class GoogleDriveOAuthRequestTests: XCTestCase {
    private let client = "1234567890-synthetic.apps.googleusercontent.com"
    private let reversed = "com.googleusercontent.apps.1234567890-synthetic"
    private let bundle = "test.record-for-agent"
    private let state = String(repeating: "s", count: 64)
    private let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    private func configuration(client: String? = nil, reversed: String? = nil,
                               registeredBundle: String? = nil, schemes: [String]? = nil) throws -> GoogleDriveOAuthConfiguration {
        try .init(clientID: client ?? self.client, reversedClientID: reversed ?? self.reversed,
                  registeredBundleID: registeredBundle ?? bundle, actualBundleID: bundle,
                  registeredSchemes: schemes ?? [self.reversed])
    }

    func testOAuthRequestUsesRegisteredRedirectAndPKCES256WithoutClientSecret() throws {
        let configuration = try configuration()
        let url = try configuration.authorizationURL(state: state, challenge: challenge)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(parts.queryItems)
        XCTAssertEqual(Set(items.map(\.name)).count, items.count)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(parts.scheme, "https")
        XCTAssertEqual(parts.host, "accounts.google.com")
        XCTAssertEqual(parts.path, "/o/oauth2/v2/auth")
        XCTAssertEqual(query["client_id"], client)
        XCTAssertEqual(query["redirect_uri"], reversed + ":/oauthredirect")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["scope"], "https://www.googleapis.com/auth/drive.file")
        XCTAssertEqual(query["state"], state)
        XCTAssertEqual(query["code_challenge"], challenge)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["access_type"], "offline")
        XCTAssertEqual(query["prompt"], "consent select_account")
        XCTAssertEqual(query["include_granted_scopes"], "false")
        XCTAssertNil(query["client_secret"])
        XCTAssertNil(query["code_verifier"], "The authorization endpoint receives the challenge, not the verifier.")
    }

    func testUnregisteredPlaceholderAndMismatchedClientConfigurationsAreRejected() {
        XCTAssertThrowsError(try configuration(client: "$(WR_GOOGLE_CLIENT_ID)"))
        XCTAssertThrowsError(try configuration(client: "REPLACE.apps.googleusercontent.com"))
        XCTAssertThrowsError(try configuration(client: ".apps.googleusercontent.com"))
        XCTAssertThrowsError(try configuration(client: "synthetic.apps.googleusercontent.com.evil.invalid"))
        XCTAssertThrowsError(try configuration(reversed: "com.googleusercontent.apps.another-client"))
        XCTAssertThrowsError(try configuration(registeredBundle: "other.bundle"))
        XCTAssertThrowsError(try configuration(registeredBundle: ""))
        XCTAssertThrowsError(try configuration(schemes: []))
        XCTAssertThrowsError(try configuration(schemes: ["another-callback"]))
    }

    func testMalformedNonceAndChallengeCannotCreateAuthorizationURL() throws {
        let configuration = try configuration()
        for invalid in ["", String(repeating: "s", count: 42), String(repeating: "s", count: 129),
                        String(repeating: "s", count: 42) + "+", String(repeating: "s", count: 42) + " "] {
            XCTAssertThrowsError(try configuration.authorizationURL(state: invalid, challenge: challenge))
        }
        for invalid in ["", String(repeating: "a", count: 42), String(repeating: "a", count: 44),
                        String(repeating: "a", count: 42) + "=", String(repeating: "a", count: 42) + "/"] {
            XCTAssertThrowsError(try configuration.authorizationURL(state: state, challenge: invalid))
        }
    }

    func testCallbackReturnsOnlyCodeFromExactRedirectAndMatchingState() throws {
        let configuration = try configuration()
        let callback = try XCTUnwrap(URL(string: configuration.redirectURI + "?state=" + state + "&code=synthetic%2Bcode"))
        XCTAssertEqual(try configuration.authorizationCode(from: callback, expectedState: state), "synthetic+code")
        XCTAssertThrowsError(try configuration.authorizationCode(from: callback, expectedState: String(repeating: "x", count: 64)))
        XCTAssertThrowsError(try configuration.authorizationCode(from: callback, expectedState: "short"))
    }

    func testDuplicateMissingErrorAndConfusedRedirectCallbacksAreRejected() throws {
        let configuration = try configuration()
        let validQuery = "?state=" + state + "&code=synthetic-code"
        let callbacks = [
            "other.scheme:/oauthredirect" + validQuery,
            reversed + "://evil.invalid/oauthredirect" + validQuery,
            reversed + "://name:secret@evil.invalid:443/oauthredirect" + validQuery,
            reversed + ":/otherpath" + validQuery,
            reversed + ":/oauthredirect/" + validQuery,
            reversed + ":/oauthredirect" + validQuery + "#fragment",
            reversed + ":/oauthredirect?code=synthetic-code",
            reversed + ":/oauthredirect?state=" + state,
            reversed + ":/oauthredirect?state=" + state + "&code=",
            reversed + ":/oauthredirect" + validQuery + "&state=" + state,
            reversed + ":/oauthredirect" + validQuery + "&code=second-code",
            reversed + ":/oauthredirect" + validQuery + "&error=access_denied",
            reversed + ":/oauthredirect?state=" + state + "&code=" + String(repeating: "c", count: 4_097)
        ]
        for raw in callbacks {
            let callback = try XCTUnwrap(URL(string: raw))
            XCTAssertThrowsError(try configuration.authorizationCode(from: callback, expectedState: state), raw)
        }
    }

    func testFolderFailureRetriesLibraryWithoutQuarantiningArtifacts() {
        XCTAssertEqual(GoogleDriveLibraryError.invalidRemoteFolder.syncFailureScope, .retryLibrary)
        XCTAssertNotEqual(GoogleDriveLibraryError.invalidRemoteFolder.syncFailureScope,
                          GoogleDriveLibraryError.invalidRemoteFile.syncFailureScope)
    }

    func testSingleItemMetadataErrorsStayOffTheLibraryGrant() {
        for error in [GoogleDriveLibraryError.invalidRemoteFile, .metadataIncomplete, .changedManifest, .notAuthorized] {
            XCTAssertEqual(error.syncFailureScope, .failItemOnly)
        }
        for error in [GoogleDriveLibraryError.invalidState, .changedAccount, .notConfigured] {
            XCTAssertEqual(error.syncFailureScope, .disableLibrary)
        }
    }
}
