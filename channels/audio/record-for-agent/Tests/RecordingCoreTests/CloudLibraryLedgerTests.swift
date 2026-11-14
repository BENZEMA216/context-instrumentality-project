import Foundation
import XCTest
@testable import RecordingCore

final class CloudLibraryLedgerTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private let accountA = CloudLibraryScope(containerIdentifier: "iCloud.test.recordings", environment: "Development", ownerHash: String(repeating: "a", count: 64))
    private let accountB = CloudLibraryScope(containerIdentifier: "iCloud.test.recordings", environment: "Development", ownerHash: String(repeating: "b", count: 64))

    private func manifest(id: UUID = UUID(), sequence: Int = 0, digest: String = String(repeating: "1", count: 64), bytes: Int64 = 1_024) -> SegmentManifest {
        SegmentManifest(id: id, sessionID: UUID(), sequence: sequence,
                        startedAt: instant, endedAt: instant.addingTimeInterval(60),
                        sampleRate: 16_000, frameCount: 960_000,
                        fileName: id.uuidString.lowercased() + ".caf", byteCount: bytes, sha256: digest)
    }

    private func changed(_ value: SegmentManifest, digest: String? = nil, sequence: Int? = nil) -> SegmentManifest {
        SegmentManifest(id: value.id, sessionID: value.sessionID, sequence: sequence ?? value.sequence,
                        startedAt: value.startedAt, endedAt: value.endedAt, sampleRate: value.sampleRate,
                        frameCount: value.frameCount, fileName: value.fileName,
                        byteCount: value.byteCount, sha256: digest ?? value.sha256)
    }

    private func temporaryLedgerURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudLibraryLedgerTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("cloud/ledger.json")
    }

    func testInitialSnapshotDoesNotAutomaticallyAddFutureRecordings() throws {
        let original = (0..<18).map { manifest(sequence: $0) }
        let future = manifest(sequence: 18)
        var ledger = CloudLibraryLedger()
        let captured = try ledger.captureInitialSnapshot(original, at: instant)
        let afterRefresh = try ledger.captureInitialSnapshot(original + [future], at: instant.addingTimeInterval(60))
        XCTAssertEqual(afterRefresh, captured)
        XCTAssertEqual(ledger.snapshot?.segmentIDs, Set(original.map(\.id)))
        XCTAssertThrowsError(try ledger.requireAuthorized(future)) {
            XCTAssertEqual($0 as? CloudLibraryLedgerError, .notAuthorized)
        }
        let path = try temporaryLedgerURL()
        try ledger.persist(to: path)
        XCTAssertEqual(try CloudLibraryLedger.load(from: path), ledger)
        XCTAssertNil(ledger.scope, "Capturing authorization must not imply an account check or an upload.")
        XCTAssertEqual(ledger.savedAudioCount, 0)
    }

    func testAccountSwitchCannotRebindExistingSnapshotOrWriteAReceipt() throws {
        let selected = manifest()
        var ledger = CloudLibraryLedger()
        try ledger.captureInitialSnapshot([selected], at: instant)
        try ledger.bind(to: accountA)
        let beforeSwitch = ledger
        XCTAssertThrowsError(try ledger.bind(to: accountB)) {
            XCTAssertEqual($0 as? CloudLibraryLedgerError, .accountChanged)
        }
        XCTAssertThrowsError(try ledger.recordAudioSaved(selected, in: accountB,
            cloudRecordName: CloudLibraryLedger.audioRecordName(for: selected.id), at: instant)) {
            XCTAssertEqual($0 as? CloudLibraryLedgerError, .accountChanged)
        }
        XCTAssertEqual(ledger, beforeSwitch)
        try ledger.bind(to: accountA)
        XCTAssertEqual(ledger, beforeSwitch, "Returning to the original account may resume without clearing scope.")
    }

    func testPersistedAccountBindingSurvivesRecreation() throws {
        let selected = manifest()
        let path = try temporaryLedgerURL()
        var ledger = CloudLibraryLedger()
        try ledger.captureInitialSnapshot([selected], at: instant)
        try ledger.bind(to: accountA)
        try ledger.persist(to: path)
        var restored = try CloudLibraryLedger.load(from: path)
        XCTAssertThrowsError(try restored.bind(to: accountB))
        XCTAssertEqual(restored.scope, accountA)
        XCTAssertEqual(restored.snapshot, ledger.snapshot)
    }

    func testDevelopmentAndProductionCannotReuseTheSameLedger() throws {
        var ledger = CloudLibraryLedger()
        try ledger.captureInitialSnapshot([manifest()], at: instant)
        try ledger.bind(to: accountA)
        let production = CloudLibraryScope(containerIdentifier: accountA.containerIdentifier,
            environment: "Production", ownerHash: accountA.ownerHash)
        XCTAssertThrowsError(try ledger.bind(to: production)) {
            XCTAssertEqual($0 as? CloudLibraryLedgerError, .scopeChanged)
        }
        let differentContainer = CloudLibraryScope(containerIdentifier: "iCloud.test.other",
            environment: accountA.environment, ownerHash: accountA.ownerHash)
        XCTAssertThrowsError(try ledger.requireScope(differentContainer))
        XCTAssertEqual(ledger.scope, accountA)
    }

    func testChangedAudioOrMetadataIsRejectedInsteadOfBeingOverwritten() throws {
        let selected = manifest()
        var ledger = CloudLibraryLedger()
        try ledger.captureInitialSnapshot([selected], at: instant)
        try ledger.bind(to: accountA)
        for altered in [changed(selected, digest: String(repeating: "2", count: 64)), changed(selected, sequence: 9)] {
            XCTAssertThrowsError(try ledger.captureInitialSnapshot([altered])) {
                XCTAssertEqual($0 as? CloudLibraryLedgerError, .changedManifest)
            }
            XCTAssertThrowsError(try ledger.recordAudioSaved(altered, in: accountA,
                cloudRecordName: CloudLibraryLedger.audioRecordName(for: selected.id)))
        }
        XCTAssertEqual(ledger.savedAudioCount, 0)
        XCTAssertEqual(ledger.snapshot?.manifests, [selected])
    }

    func testAudioSaveRetryIsIdempotentAndDoesNotImplyTranscriptOrTransportACK() throws {
        let selected = manifest()
        var ledger = CloudLibraryLedger()
        try ledger.captureInitialSnapshot([selected], at: instant)
        try ledger.bind(to: accountA)
        let recordName = CloudLibraryLedger.audioRecordName(for: selected.id)
        try ledger.recordAudioSaved(selected, in: accountA, cloudRecordName: recordName, at: instant)
        let afterFirstSave = ledger
        try ledger.recordAudioSaved(selected, in: accountA, cloudRecordName: recordName, at: instant.addingTimeInterval(90))
        XCTAssertEqual(ledger, afterFirstSave)
        XCTAssertEqual(ledger.savedAudioCount, 1)
        XCTAssertEqual(ledger.savedTranscriptCount, 0)
        XCTAssertNil(ledger.receipt(for: selected.id)?.transcript)
        XCTAssertEqual(ledger.receipt(for: selected.id)?.metadataVerifiedAt, instant)
    }

    func testTranscriptCanArriveLaterWithoutChangingAudioReceipt() throws {
        let selected = manifest()
        var ledger = CloudLibraryLedger()
        try ledger.captureInitialSnapshot([selected], at: instant)
        try ledger.bind(to: accountA)
        let digest = String(repeating: "3", count: 64)
        let transcriptName = CloudLibraryLedger.transcriptRecordName(for: selected.id, contentSHA256: digest)
        XCTAssertThrowsError(try ledger.recordTranscriptSaved(for: selected, in: accountA,
            contentSHA256: digest, cloudRecordName: transcriptName)) {
            XCTAssertEqual($0 as? CloudLibraryLedgerError, .audioNotSaved)
        }
        try ledger.recordAudioSaved(selected, in: accountA,
            cloudRecordName: CloudLibraryLedger.audioRecordName(for: selected.id), at: instant)
        try ledger.recordTranscriptSaved(for: selected, in: accountA,
            contentSHA256: digest, cloudRecordName: transcriptName, at: instant.addingTimeInterval(60))
        let saved = ledger
        XCTAssertThrowsError(try ledger.recordTranscriptSaved(for: selected, in: accountB,
            contentSHA256: digest, cloudRecordName: transcriptName))
        XCTAssertEqual(ledger, saved)
        XCTAssertEqual(ledger.savedAudioCount, 1)
        XCTAssertEqual(ledger.savedTranscriptCount, 1)
        XCTAssertEqual(ledger.receipt(for: selected.id)?.metadataVerifiedAt, instant)
        let revisedDigest = String(repeating: "4", count: 64)
        try ledger.recordTranscriptSaved(for: selected, in: accountA, contentSHA256: revisedDigest,
            cloudRecordName: CloudLibraryLedger.transcriptRecordName(for: selected.id, contentSHA256: revisedDigest))
        XCTAssertEqual(ledger.receipt(for: selected.id)?.metadataVerifiedAt, instant)
        XCTAssertNotEqual(ledger.receipt(for: selected.id)?.transcript?.cloudRecordName, transcriptName)
    }

    func testMissingAuthorizationAndWrongCloudRecordAreRejected() throws {
        let selected = manifest()
        var ledger = CloudLibraryLedger()
        XCTAssertThrowsError(try ledger.bind(to: accountA))
        XCTAssertThrowsError(try ledger.captureInitialSnapshot([]))
        XCTAssertThrowsError(try ledger.captureInitialSnapshot([selected, selected]))
        try ledger.captureInitialSnapshot([selected], at: instant)
        XCTAssertThrowsError(try ledger.recordAudioSaved(selected, in: accountA,
            cloudRecordName: CloudLibraryLedger.audioRecordName(for: selected.id)))
        try ledger.bind(to: accountA)
        XCTAssertThrowsError(try ledger.recordAudioSaved(selected, in: accountA, cloudRecordName: "unrelated-record"))
        XCTAssertEqual(ledger.savedAudioCount, 0)
    }

    func testCorruptedLedgerFailsClosedInsteadOfResettingItsAccount() throws {
        let path = try temporaryLedgerURL()
        var ledger = CloudLibraryLedger()
        try ledger.captureInitialSnapshot([manifest()], at: instant)
        try ledger.bind(to: accountA)
        try ledger.persist(to: path)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        object["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        XCTAssertThrowsError(try CloudLibraryLedger.load(from: path)) {
            XCTAssertEqual($0 as? CloudLibraryLedgerError, .unsupportedVersion)
        }
        try Data("not a ledger".utf8).write(to: path)
        XCTAssertThrowsError(try CloudLibraryLedger.load(from: path))
    }
}
