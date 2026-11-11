import Foundation
import Darwin
import XCTest
@testable import RecordingCore

final class AutomaticDeliveryLedgerTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000.123)
    private let digest = String(repeating: "a", count: 64)
    private let otherDigest = String(repeating: "b", count: 64)

    private func scope(receiverID: UUID = UUID(), pairingID: UUID = UUID(), grantEpoch: UUID = UUID(),
                       installationID: UUID = UUID(), endpoint: String = "https://mac.local:9443",
                       certificate: String = String(repeating: "c", count: 64)) -> AutomaticDeliveryScope {
        AutomaticDeliveryScope(receiverID: receiverID, pairingID: pairingID, grantEpoch: grantEpoch,
            sourceInstallationID: installationID, endpoint: endpoint, certificateSHA256: certificate)
    }

    private func manifest(id: UUID = UUID()) -> SegmentManifest {
        SegmentManifest(id: id, sessionID: UUID(), sequence: 0, startedAt: instant, endedAt: instant.addingTimeInterval(60),
            sampleRate: 16_000, frameCount: 960_000, fileName: id.uuidString.lowercased() + ".caf", byteCount: 4_096, sha256: digest)
    }

    private func newLedger(_ recording: SegmentManifest, scope binding: AutomaticDeliveryScope? = nil) throws -> AutomaticDeliveryLedger {
        try AutomaticDeliveryLedger(scope: binding ?? scope(), baselineIDs: [recording.id],
            selectedExistingIDs: [recording.id], includeFuture: false, createdAt: instant)
    }

    private func queuedLedger() throws -> (AutomaticDeliveryLedger, SegmentManifest, UUID) {
        let recording = manifest()
        var ledger = try newLedger(recording)
        let id = try XCTUnwrap(ledger.reconcile(manifests: [recording], receivedSegmentIDs: [recording.id], now: instant).first)
        return (ledger, recording, id)
    }

    private func prepare(_ id: UUID, in ledger: inout AutomaticDeliveryLedger, at date: Date? = nil) throws {
        let date = date ?? instant
        try ledger.beginPreparation(deliveryID: id, now: date)
        try ledger.recordPreparedArchive(deliveryID: id, relativePath: id.uuidString.lowercased() + ".zip",
            sha256: digest, byteCount: 8_192, now: date)
    }

    private func receipt(for job: AutomaticDeliveryJob) throws -> AutomaticDeliveryReceipt {
        AutomaticDeliveryReceipt(receiverID: job.scope.receiverID, deliveryID: job.id,
            archiveSHA256: try XCTUnwrap(job.archive).sha256, recordingIDs: [job.manifest.id], storedAt: instant)
    }

    private func path() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutomaticDeliveryLedgerTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("grant/ledger.json")
    }

    private func altered(_ ledger: AutomaticDeliveryLedger,
                         _ alteration: (inout [String: Any]) -> Void) throws -> AutomaticDeliveryLedger {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: TransportCodec.encode(ledger)) as? [String: Any])
        alteration(&json)
        return try TransportCodec.decode(AutomaticDeliveryLedger.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testSelectionIsAnExplicitSubsetAndInsecureScopesAreRejected() throws {
        let original = manifest()
        XCTAssertThrowsError(try AutomaticDeliveryLedger(scope: scope(), baselineIDs: [], selectedExistingIDs: [original.id],
            includeFuture: false, createdAt: instant))
        for endpoint in ["http://mac.local", "https://user:secret@mac.local", "https://mac.local?token=secret", "https://mac.local#token", "https://"] {
            XCTAssertThrowsError(try newLedger(original, scope: scope(endpoint: endpoint)))
        }
        XCTAssertThrowsError(try newLedger(original, scope: scope(certificate: "invalid")))
        XCTAssertNoThrow(try newLedger(original, scope: scope(endpoint: "https://127.0.0.1:9443")))
    }

    func testFutureAuthorizationNeverIncludesUnselectedBaselineRecordings() throws {
        let selected = manifest(), unselected = manifest(), future = manifest(), futureWithoutReceipt = manifest()
        var ledger = try AutomaticDeliveryLedger(scope: scope(), baselineIDs: [selected.id, unselected.id],
            selectedExistingIDs: [selected.id], includeFuture: true, createdAt: instant)
        try ledger.reconcile(manifests: [selected, unselected, future, futureWithoutReceipt],
            receivedSegmentIDs: [selected.id, unselected.id, future.id], now: instant)
        XCTAssertEqual(Set(ledger.jobs.map(\.manifest.id)), [selected.id, future.id])
        XCTAssertEqual(ledger.baselineIDs, [selected.id, unselected.id])
        XCTAssertEqual(ledger.eligibleFutureIDs, [future.id])
        XCTAssertEqual(ledger.authorizedIDs, [selected.id, future.id])
        let checkpoint = ledger
        XCTAssertEqual(try ledger.reconcile(manifests: [selected, unselected, future],
            receivedSegmentIDs: [selected.id, unselected.id, future.id], now: instant), [])
        XCTAssertEqual(ledger, checkpoint)
        try ledger.reconcile(manifests: [], receivedSegmentIDs: [], now: instant)
        XCTAssertEqual(ledger, checkpoint, "Refresh cannot erase the persistent baseline or future eligibility.")
    }

    func testSelectedOnlyCannotExpandAndRequiresDurableReceipt() throws {
        let selected = manifest(), later = manifest()
        var ledger = try newLedger(selected)
        XCTAssertEqual(try ledger.reconcile(manifests: [selected, later], receivedSegmentIDs: [later.id], now: instant), [])
        XCTAssertTrue(ledger.jobs.isEmpty)
        try ledger.reconcile(manifests: [selected, later], receivedSegmentIDs: [selected.id, later.id], now: instant)
        XCTAssertEqual(ledger.jobs.map(\.manifest.id), [selected.id])
        XCTAssertEqual(ledger.authorizedIDs, [selected.id])
        XCTAssertTrue(ledger.eligibleFutureIDs.isEmpty)
    }

    func testFutureEligibilitySurvivesMetadataDelayAndRestart() throws {
        let future = manifest()
        var ledger = try AutomaticDeliveryLedger(scope: scope(), baselineIDs: [], selectedExistingIDs: [], includeFuture: true, createdAt: instant)
        try ledger.reconcile(manifests: [], receivedSegmentIDs: [future.id], now: instant)
        XCTAssertEqual(ledger.eligibleFutureIDs, [future.id])
        XCTAssertTrue(ledger.jobs.isEmpty)
        let url = try path()
        try ledger.save(to: url)
        var restored = try AutomaticDeliveryLedger.load(from: url, expectedScope: ledger.scope)
        try restored.reconcile(manifests: [future], receivedSegmentIDs: [future.id], now: instant)
        XCTAssertEqual(restored.jobs.map(\.manifest), [future])
    }

    func testEveryScopeComponentSeparatesGrantsAndDoesNotMutateOldJobs() throws {
        let (ledger, _, _) = try queuedLedger()
        let original = ledger.scope
        let replacements = [
            scope(receiverID: UUID(), pairingID: original.pairingID, grantEpoch: original.grantEpoch, installationID: original.sourceInstallationID),
            scope(receiverID: original.receiverID, pairingID: UUID(), grantEpoch: original.grantEpoch, installationID: original.sourceInstallationID),
            scope(receiverID: original.receiverID, pairingID: original.pairingID, grantEpoch: UUID(), installationID: original.sourceInstallationID),
            scope(receiverID: original.receiverID, pairingID: original.pairingID, grantEpoch: original.grantEpoch, installationID: UUID()),
            scope(receiverID: original.receiverID, pairingID: original.pairingID, grantEpoch: original.grantEpoch, installationID: original.sourceInstallationID, endpoint: "https://other.local:9443"),
            scope(receiverID: original.receiverID, pairingID: original.pairingID, grantEpoch: original.grantEpoch, installationID: original.sourceInstallationID, certificate: digest)
        ]
        let url = try path()
        try ledger.persist(to: url)
        for replacement in replacements {
            XCTAssertThrowsError(try ledger.requireScope(replacement)) { XCTAssertEqual($0 as? AutomaticDeliveryLedgerError, .scopeChanged) }
            XCTAssertThrowsError(try AutomaticDeliveryLedger.load(from: url, expectedScope: replacement))
            let next = try AutomaticDeliveryLedger(scope: replacement, baselineIDs: ledger.baselineIDs,
                selectedExistingIDs: [], includeFuture: true, createdAt: instant)
            XCTAssertTrue(next.jobs.isEmpty)
            XCTAssertTrue(next.authorizedIDs.isEmpty)
        }
        XCTAssertEqual(try AutomaticDeliveryLedger.load(from: url, expectedScope: original), ledger)
    }

    func testCapturedManifestCannotChangeAndFailedReconcileIsAtomic() throws {
        var (ledger, original, _) = try queuedLedger()
        let checkpoint = ledger
        let changed = SegmentManifest(id: original.id, sessionID: original.sessionID, sequence: original.sequence,
            startedAt: original.startedAt, endedAt: original.endedAt, sampleRate: original.sampleRate,
            frameCount: original.frameCount, fileName: original.fileName, byteCount: original.byteCount, sha256: otherDigest)
        XCTAssertThrowsError(try ledger.reconcile(manifests: [changed], receivedSegmentIDs: [], now: instant)) {
            XCTAssertEqual($0 as? AutomaticDeliveryLedgerError, .changedManifest)
        }
        XCTAssertThrowsError(try ledger.reconcile(manifests: [original, original], receivedSegmentIDs: [original.id], now: instant))
        XCTAssertEqual(ledger, checkpoint)
    }

    func testTranscriptFollowupGetsDistinctIDAndCannotReplaceAudioDelivery() throws {
        var (ledger, recording, audioID) = try queuedLedger()
        try prepare(audioID, in: &ledger)
        try ledger.beginUpload(deliveryID: audioID, now: instant)
        let audioReceipt = try receipt(for: XCTUnwrap(ledger.job(for: audioID)))
        try ledger.acceptReceipt(audioReceipt, forScope: ledger.scope, now: instant)
        let audioJob = ledger.job(for: audioID)
        let textID = try XCTUnwrap(ledger.reconcile(manifests: [recording], receivedSegmentIDs: [recording.id],
            transcriptHashes: [recording.id: digest], now: instant).first)
        XCTAssertNotEqual(audioID, textID)
        XCTAssertEqual(ledger.job(for: textID)?.transcriptSHA256, digest)
        XCTAssertEqual(ledger.job(for: audioID), audioJob)
        XCTAssertEqual(try ledger.reconcile(manifests: [recording], receivedSegmentIDs: [recording.id],
            transcriptHashes: [recording.id: digest], now: instant), [])
        try ledger.reconcile(manifests: [recording], receivedSegmentIDs: [recording.id],
            transcriptHashes: [recording.id: otherDigest], now: instant)
        XCTAssertEqual(ledger.jobs.count, 3)
        XCTAssertEqual(Set(ledger.jobs.map(\.id)).count, 3)
        XCTAssertEqual(ledger.job(for: audioID), audioJob)
    }

    func testMissingTranscriptCacheDoesNotQueueAnExtraAudioOnlyVersion() throws {
        let recording = manifest()
        var ledger = try newLedger(recording)
        try ledger.reconcile(manifests: [recording], receivedSegmentIDs: [recording.id], transcriptHashes: [recording.id: digest], now: instant)
        let checkpoint = ledger
        XCTAssertEqual(try ledger.reconcile(manifests: [recording], receivedSegmentIDs: [recording.id], now: instant), [])
        XCTAssertEqual(ledger, checkpoint)
        XCTAssertThrowsError(try ledger.reconcile(manifests: [recording], receivedSegmentIDs: [recording.id], transcriptHashes: [recording.id: "bad"], now: instant))
        XCTAssertEqual(ledger, checkpoint)
    }

    func testRetryReusesExactArchiveAndDeliveryIDWithBackoff() throws {
        var (ledger, _, id) = try queuedLedger()
        try prepare(id, in: &ledger)
        let archive = ledger.job(for: id)?.archive
        try ledger.beginUpload(deliveryID: id, now: instant)
        try ledger.recordFailure(deliveryID: id, statusCode: 503, message: "暂时不可用", now: instant)
        XCTAssertEqual(ledger.job(for: id)?.state, .retryWaiting)
        XCTAssertEqual(ledger.job(for: id)?.attemptCount, 1)
        XCTAssertEqual(ledger.job(for: id)?.nextAttemptAt, instant.addingTimeInterval(15))
        XCTAssertThrowsError(try ledger.beginUpload(deliveryID: id, now: instant.addingTimeInterval(14))) {
            XCTAssertEqual($0 as? AutomaticDeliveryLedgerError, .retryNotDue)
        }
        XCTAssertThrowsError(try ledger.recordPreparedArchive(deliveryID: id, relativePath: "replacement.zip", sha256: otherDigest, byteCount: 8_192, now: instant))
        try ledger.beginUpload(deliveryID: id, now: instant.addingTimeInterval(15))
        try ledger.recordFailure(deliveryID: id, message: "超时", now: instant.addingTimeInterval(15))
        XCTAssertEqual(ledger.job(for: id)?.attemptCount, 2)
        XCTAssertEqual(ledger.job(for: id)?.nextAttemptAt, instant.addingTimeInterval(45))
        XCTAssertEqual(ledger.job(for: id)?.archive, archive)
        XCTAssertEqual(ledger.jobs.map(\.id), [id])
        XCTAssertEqual(AutomaticDeliveryLedger.retryDelay(afterAttempt: 10), 3_600)
        XCTAssertEqual(AutomaticDeliveryLedger.retryDelay(afterAttempt: 100_000), 3_600)
        XCTAssertEqual(AutomaticDeliveryLedger.retryDelay(afterAttempt: Int.min), 15)
    }

    func testAuthenticationFailureBlocksAutomaticRetry() throws {
        for status in [401, 403] {
            var (ledger, recording, id) = try queuedLedger()
            try prepare(id, in: &ledger)
            try ledger.beginUpload(deliveryID: id, now: instant)
            try ledger.recordFailure(deliveryID: id, statusCode: status, message: "需要重新配对", now: instant)
            XCTAssertEqual(ledger.job(for: id)?.state, .blocked)
            XCTAssertNil(ledger.job(for: id)?.nextAttemptAt)
            let checkpoint = ledger
            XCTAssertThrowsError(try ledger.beginUpload(deliveryID: id, now: instant.addingTimeInterval(10_000)))
            try ledger.reconcile(manifests: [recording], receivedSegmentIDs: [recording.id], now: instant)
            try ledger.recoverInterruptedJobs(now: instant)
            XCTAssertEqual(ledger, checkpoint)
        }
    }

    func testAttemptCapStopsRetriesWithoutDiscardingArchive() throws {
        var (ledger, _, id) = try queuedLedger()
        try prepare(id, in: &ledger)
        var date = instant
        for attempt in 1...AutomaticDeliveryLedger.maximumAttempts {
            try ledger.beginUpload(deliveryID: id, now: date)
            try ledger.recordFailure(deliveryID: id, statusCode: 503, message: "稍后重试", now: date)
            XCTAssertEqual(ledger.job(for: id)?.attemptCount, attempt)
            date = ledger.job(for: id)?.nextAttemptAt ?? date
        }
        XCTAssertEqual(ledger.job(for: id)?.state, .blocked)
        XCTAssertNotNil(ledger.job(for: id)?.archive)
        XCTAssertThrowsError(try ledger.beginUpload(deliveryID: id, now: date.addingTimeInterval(7_200)))
    }

    func testMatchingLateReceiptAfterAttemptCapConfirmsStorageWithoutResumingUpload() throws {
        var (ledger, recording, id) = try queuedLedger()
        try prepare(id, in: &ledger)
        var date = instant
        for _ in 1...AutomaticDeliveryLedger.maximumAttempts {
            try ledger.beginUpload(deliveryID: id, now: date)
            try ledger.recordFailure(deliveryID: id, message: "timeout", now: date)
            date = ledger.job(for: id)?.nextAttemptAt ?? date
        }
        let blocked = ledger
        let valid = try receipt(for: XCTUnwrap(ledger.job(for: id)))
        XCTAssertEqual(ledger.job(for: id)?.state, .blocked)
        XCTAssertThrowsError(try ledger.acceptReceipt(valid, forScope: scope(), now: date))
        let wrongHash = AutomaticDeliveryReceipt(receiverID: ledger.scope.receiverID, deliveryID: id,
            archiveSHA256: otherDigest, recordingIDs: [recording.id], storedAt: instant)
        XCTAssertThrowsError(try ledger.acceptReceipt(wrongHash, forScope: ledger.scope, now: date))
        let wrongDelivery = AutomaticDeliveryReceipt(receiverID: ledger.scope.receiverID, deliveryID: UUID(),
            archiveSHA256: digest, recordingIDs: [recording.id], storedAt: instant)
        XCTAssertThrowsError(try ledger.acceptReceipt(wrongDelivery, forScope: ledger.scope, now: date))
        let wrongRecording = AutomaticDeliveryReceipt(receiverID: ledger.scope.receiverID, deliveryID: id,
            archiveSHA256: digest, recordingIDs: [UUID()], storedAt: instant)
        XCTAssertThrowsError(try ledger.acceptReceipt(wrongRecording, forScope: ledger.scope, now: date))
        XCTAssertEqual(ledger, blocked)
        try ledger.acceptReceipt(valid, forScope: ledger.scope, now: date)
        XCTAssertEqual(ledger.job(for: id)?.state, .delivered)
        XCTAssertEqual(ledger.job(for: id)?.receipt, valid)
        XCTAssertEqual(ledger.job(for: id)?.attemptCount, AutomaticDeliveryLedger.maximumAttempts)
        XCTAssertEqual(ledger.job(for: id)?.archive, blocked.job(for: id)?.archive)
        XCTAssertNil(ledger.job(for: id)?.nextAttemptAt)
        XCTAssertNil(ledger.job(for: id)?.lastError)
        XCTAssertThrowsError(try ledger.beginUpload(deliveryID: id, now: date.addingTimeInterval(7_200)))
    }

    func testRecoveryPreservesActiveBackgroundTaskAndRetriesInterruptedWork() throws {
        let records = [manifest(), manifest(), manifest()]
        var ledger = try AutomaticDeliveryLedger(scope: scope(), baselineIDs: Set(records.map(\.id)),
            selectedExistingIDs: Set(records.map(\.id)), includeFuture: false, createdAt: instant)
        let ids = try ledger.reconcile(manifests: records, receivedSegmentIDs: Set(records.map(\.id)), now: instant)
        try prepare(ids[0], in: &ledger)
        try ledger.beginUpload(deliveryID: ids[0], now: instant)
        try prepare(ids[1], in: &ledger)
        try ledger.beginUpload(deliveryID: ids[1], now: instant)
        try ledger.beginPreparation(deliveryID: ids[2], now: instant)
        let active = ledger.job(for: ids[0]), interruptedArchive = ledger.job(for: ids[1])?.archive
        let url = try path()
        try ledger.persist(to: url)
        ledger = try AutomaticDeliveryLedger.load(from: url, expectedScope: ledger.scope)
        try ledger.recoverInterruptedJobs(activeDeliveryIDs: [ids[0]], now: instant.addingTimeInterval(1))
        XCTAssertEqual(ledger.job(for: ids[0]), active)
        XCTAssertEqual(ledger.job(for: ids[1])?.state, .retryWaiting)
        XCTAssertEqual(ledger.job(for: ids[1])?.archive, interruptedArchive)
        XCTAssertEqual(ledger.job(for: ids[1])?.attemptCount, 1)
        XCTAssertEqual(ledger.job(for: ids[2])?.state, .retryWaiting)
        XCTAssertNil(ledger.job(for: ids[2])?.archive)
        XCTAssertEqual(ledger.job(for: ids[2])?.attemptCount, 1)
        let checkpoint = ledger
        try ledger.recoverInterruptedJobs(activeDeliveryIDs: [ids[0]], now: instant.addingTimeInterval(5))
        XCTAssertEqual(ledger, checkpoint)
    }

    func testMismatchedReceiptsAndChangedScopeCannotAcknowledge() throws {
        var (ledger, recording, id) = try queuedLedger()
        try prepare(id, in: &ledger)
        try ledger.beginUpload(deliveryID: id, now: instant)
        let valid = try receipt(for: XCTUnwrap(ledger.job(for: id)))
        let wrong = [
            AutomaticDeliveryReceipt(schemaVersion: 2, receiverID: ledger.scope.receiverID, deliveryID: id, archiveSHA256: digest, recordingIDs: [recording.id], storedAt: instant),
            AutomaticDeliveryReceipt(receiverID: UUID(), deliveryID: id, archiveSHA256: digest, recordingIDs: [recording.id], storedAt: instant),
            AutomaticDeliveryReceipt(receiverID: ledger.scope.receiverID, deliveryID: UUID(), archiveSHA256: digest, recordingIDs: [recording.id], storedAt: instant),
            AutomaticDeliveryReceipt(receiverID: ledger.scope.receiverID, deliveryID: id, archiveSHA256: otherDigest, recordingIDs: [recording.id], storedAt: instant),
            AutomaticDeliveryReceipt(receiverID: ledger.scope.receiverID, deliveryID: id, archiveSHA256: digest, recordingIDs: [], storedAt: instant),
            AutomaticDeliveryReceipt(receiverID: ledger.scope.receiverID, deliveryID: id, archiveSHA256: digest, recordingIDs: [UUID()], storedAt: instant),
            AutomaticDeliveryReceipt(receiverID: ledger.scope.receiverID, deliveryID: id, archiveSHA256: digest, recordingIDs: [recording.id, recording.id], storedAt: instant)
        ]
        let checkpoint = ledger
        for receipt in wrong { XCTAssertThrowsError(try ledger.acceptReceipt(receipt, forScope: ledger.scope, now: instant)) }
        XCTAssertThrowsError(try ledger.acceptReceipt(valid, forScope: scope(), now: instant))
        XCTAssertEqual(ledger, checkpoint)
        try ledger.acceptReceipt(valid, forScope: ledger.scope, now: instant)
        XCTAssertEqual(ledger.job(for: id)?.state, .delivered)
        XCTAssertEqual(ledger.job(for: id)?.receipt, valid)
        let delivered = ledger
        try ledger.acceptReceipt(valid, forScope: ledger.scope, now: instant.addingTimeInterval(5))
        XCTAssertEqual(ledger, delivered, "An identical receipt is fully idempotent.")
        XCTAssertThrowsError(try ledger.recordFailure(deliveryID: id, message: "late error", now: instant))
    }

    func testReceiptRequiresPersistedUploadAttemptButAcceptsLateMatchingResponse() throws {
        var (ledger, _, id) = try queuedLedger()
        try prepare(id, in: &ledger)
        let valid = try receipt(for: XCTUnwrap(ledger.job(for: id)))
        XCTAssertThrowsError(try ledger.acceptReceipt(valid, forScope: ledger.scope, now: instant))
        try ledger.beginUpload(deliveryID: id, now: instant)
        try ledger.recordFailure(deliveryID: id, message: "timeout", now: instant)
        try ledger.acceptReceipt(valid, forScope: ledger.scope, now: instant)
        XCTAssertEqual(ledger.job(for: id)?.state, .delivered)
    }

    func testArchiveRejectsTraversalAndOversizeAndDoesNotAlterPreparingJob() throws {
        var (ledger, _, id) = try queuedLedger()
        try ledger.beginPreparation(deliveryID: id, now: instant)
        let checkpoint = ledger
        for name in ["../export.zip", "/tmp/export.zip", "nested/export.zip", "nested\\export.zip", ".hidden.zip", "export%2f.zip", "export.caf", ""] {
            XCTAssertThrowsError(try ledger.recordPreparedArchive(deliveryID: id, relativePath: name, sha256: digest, byteCount: 1, now: instant))
        }
        for bytes in [Int64(0), -1, AutomaticDeliveryLedger.maximumArchiveBytes + 1] {
            XCTAssertThrowsError(try ledger.recordPreparedArchive(deliveryID: id, relativePath: "export.zip", sha256: digest, byteCount: bytes, now: instant))
        }
        XCTAssertEqual(ledger, checkpoint)
        try ledger.recordPreparedArchive(deliveryID: id, relativePath: "export.zip", sha256: digest,
            byteCount: AutomaticDeliveryLedger.maximumArchiveBytes, now: instant)
        XCTAssertEqual(ledger.job(for: id)?.state, .queued)
    }

    func testDuplicateArchivePathCannotMakeTwoJobsOverwriteEachOther() throws {
        var (ledger, recording, id) = try queuedLedger()
        try prepare(id, in: &ledger)
        let textID = try XCTUnwrap(ledger.reconcile(manifests: [recording], receivedSegmentIDs: [recording.id],
            transcriptHashes: [recording.id: digest], now: instant).first)
        try ledger.beginPreparation(deliveryID: textID, now: instant)
        let checkpoint = ledger
        XCTAssertThrowsError(try ledger.recordPreparedArchive(deliveryID: textID,
            relativePath: try XCTUnwrap(ledger.job(for: id)?.archive?.relativePath), sha256: otherDigest, byteCount: 9_000, now: instant))
        XCTAssertThrowsError(try ledger.recordPreparedArchive(deliveryID: textID,
            relativePath: id.uuidString.uppercased() + ".zip", sha256: otherDigest, byteCount: 9_000, now: instant))
        XCTAssertEqual(ledger, checkpoint)
    }

    func testPersistenceRoundTripUsesIntegerMillisecondsAndRejectsTamperedStates() throws {
        var (ledger, _, id) = try queuedLedger()
        try prepare(id, in: &ledger)
        try ledger.beginUpload(deliveryID: id, now: instant)
        try ledger.recordFailure(deliveryID: id, message: "network", now: instant)
        let url = try path()
        try ledger.save(to: url)
        XCTAssertEqual(try AutomaticDeliveryLedger.load(from: url, expectedScope: ledger.scope), ledger)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((json["createdAt"] as? NSNumber)?.int64Value, 1_800_000_000_123)
        XCTAssertEqual((json["createdAt"] as? NSNumber)?.doubleValue, 1_800_000_000_123)
        let broken = try altered(ledger) { json in
            var jobs = json["jobs"] as! [[String: Any]]
            jobs[0]["state"] = "delivered"
            json["jobs"] = jobs
        }
        XCTAssertThrowsError(try broken.validate())
        try TransportCodec.encode(broken).write(to: url)
        XCTAssertThrowsError(try AutomaticDeliveryLedger.load(from: url, expectedScope: ledger.scope))
        XCTAssertThrowsError(try broken.persist(to: url))
    }

    func testLoadValidationRejectsExpandedAuthorizationAndChangedJobScope() throws {
        let (ledger, _, _) = try queuedLedger()
        let expanded = try altered(ledger) { $0["selectedExistingIDs"] = [UUID().uuidString] }
        XCTAssertThrowsError(try expanded.validate())
        let future = try altered(ledger) { $0["eligibleFutureIDs"] = [UUID().uuidString] }
        XCTAssertThrowsError(try future.validate())
        let rebound = try altered(ledger) { json in
            var jobs = json["jobs"] as! [[String: Any]]
            var scope = jobs[0]["scope"] as! [String: Any]
            scope["grantEpoch"] = UUID().uuidString
            jobs[0]["scope"] = scope
            json["jobs"] = jobs
        }
        XCTAssertThrowsError(try rebound.validate())
        let duplicate = try altered(ledger) { $0["jobs"] = ($0["jobs"] as! [[String: Any]]) + ($0["jobs"] as! [[String: Any]]) }
        XCTAssertThrowsError(try duplicate.validate())
    }

    func testValidationRejectsUnsupportedVersionFractionalMillisecondsAndInvalidSource() throws {
        let (ledger, _, _) = try queuedLedger()
        let unsupported = try altered(ledger) { $0["schemaVersion"] = 3 }
        XCTAssertThrowsError(try unsupported.validate()) { XCTAssertEqual($0 as? AutomaticDeliveryLedgerError, .unsupportedVersion) }
        let fractional = try altered(ledger) { $0["createdAt"] = 1_800_000_000_123.5 }
        XCTAssertThrowsError(try fractional.validate())
        let invalidSource = try altered(ledger) { json in
            var jobs = json["jobs"] as! [[String: Any]]
            var manifest = jobs[0]["manifest"] as! [String: Any]
            manifest["fileName"] = "../outside.caf"
            jobs[0]["manifest"] = manifest
            json["jobs"] = jobs
        }
        XCTAssertThrowsError(try invalidSource.validate())
    }

    func testLedgerCapacityIsBounded() throws {
        let ids = Set((0...AutomaticDeliveryLedger.maximumAuthorizedRecordings).map { _ in UUID() })
        XCTAssertThrowsError(try AutomaticDeliveryLedger(scope: scope(), baselineIDs: ids, selectedExistingIDs: [], includeFuture: false, createdAt: instant))
        let (ledger, _, _) = try queuedLedger()
        let oversized = try altered(ledger) { json in
            let item = (json["jobs"] as! [[String: Any]])[0]
            json["jobs"] = Array(repeating: item, count: AutomaticDeliveryLedger.maximumJobs + 1)
        }
        XCTAssertThrowsError(try oversized.validate()) { XCTAssertEqual($0 as? AutomaticDeliveryLedgerError, .capacityExceeded) }
    }

    func testPersistenceRejectsSymlinksDirectoriesAndNonregularFiles() throws {
        let (ledger, _, _) = try queuedLedger()
        let url = try path()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.json")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try ledger.save(to: url))
        XCTAssertThrowsError(try AutomaticDeliveryLedger.load(from: url, expectedScope: ledger.scope))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ledger.save(to: url))
        XCTAssertThrowsError(try AutomaticDeliveryLedger.load(from: url, expectedScope: ledger.scope))
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(Darwin.mkfifo(url.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertThrowsError(try ledger.save(to: url))
        XCTAssertThrowsError(try AutomaticDeliveryLedger.load(from: url, expectedScope: ledger.scope))
        try FileManager.default.removeItem(at: url)
        let linkDirectory = directory.deletingLastPathComponent().appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkDirectory, withDestinationURL: directory)
        XCTAssertThrowsError(try ledger.save(to: linkDirectory.appendingPathComponent("ledger.json")))
    }

    func testOversizedOrMissingLedgerDoesNotBecomeAnEmptyAuthorizedLedger() throws {
        let (ledger, _, _) = try queuedLedger()
        let url = try path()
        XCTAssertThrowsError(try AutomaticDeliveryLedger.load(from: url, expectedScope: ledger.scope))
        try ledger.save(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(AutomaticDeliveryLedger.maximumLedgerBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try AutomaticDeliveryLedger.load(from: url, expectedScope: ledger.scope))
    }

    func testNewAllRecordingsGrantIncludesEveryKnownAndLaterReceivedRecordingWithoutDateFilter() throws {
        let known = [manifest(), manifest()]
        let laterReceived = manifest()
        let enabledAt = instant.addingTimeInterval(120)
        var ledger = try AutomaticDeliveryLedger(scope: scope(), knownRecordingIDs: Set(known.map(\.id)), createdAt: enabledAt)
        XCTAssertEqual(ledger.schemaVersion, 2)
        XCTAssertEqual(ledger.selectedExistingIDs, Set(known.map(\.id)))
        XCTAssertTrue(ledger.includeFuture)
        let all = known + [laterReceived]
        try ledger.reconcile(manifests: all, receivedSegmentIDs: Set(all.map(\.id)), now: enabledAt)
        XCTAssertEqual(Set(ledger.jobs.map(\.manifest.id)), Set(all.map(\.id)))
        XCTAssertEqual(ledger.eligibleFutureIDs, [laterReceived.id])
        XCTAssertLessThan(laterReceived.endedAt, enabledAt, "Old recording dates do not restrict a newly received recording.")
        XCTAssertFalse(try ledger.migrateToAllRecordings())
        let checkpoint = ledger
        XCTAssertEqual(try ledger.reconcile(manifests: all, receivedSegmentIDs: Set(all.map(\.id)), now: enabledAt), [])
        XCTAssertEqual(ledger, checkpoint)
    }

    func testEmptyAllRecordingsGrantWaitsForMetadataAndReceiptThenIncludesEverything() throws {
        let first = manifest(), second = manifest()
        var ledger = try AutomaticDeliveryLedger(scope: scope(), knownRecordingIDs: [], createdAt: instant)
        XCTAssertTrue(ledger.authorizedIDs.isEmpty)
        XCTAssertTrue(ledger.includeFuture)
        try ledger.reconcile(manifests: [second], receivedSegmentIDs: [first.id], now: instant)
        XCTAssertTrue(ledger.jobs.isEmpty)
        XCTAssertEqual(ledger.eligibleFutureIDs, [first.id])
        let url = try path()
        try ledger.persist(to: url)
        ledger = try AutomaticDeliveryLedger.load(from: url, expectedScope: ledger.scope)
        try ledger.reconcile(manifests: [first, second], receivedSegmentIDs: [first.id], now: instant)
        XCTAssertEqual(ledger.jobs.map(\.manifest.id), [first.id])
        try ledger.reconcile(manifests: [first, second], receivedSegmentIDs: [first.id, second.id], now: instant)
        XCTAssertEqual(Set(ledger.jobs.map(\.manifest.id)), [first.id, second.id])
        XCTAssertEqual(ledger.authorizedIDs, [first.id, second.id])
    }

    func testAllRecordingsKnownIDsRemainEligibleWhenMetadataOrReceiptArrivesLater() throws {
        let metadataDelayed = manifest(), receiptDelayed = manifest()
        var ledger = try AutomaticDeliveryLedger(scope: scope(), knownRecordingIDs: [metadataDelayed.id, receiptDelayed.id], createdAt: instant)
        try ledger.reconcile(manifests: [receiptDelayed], receivedSegmentIDs: [metadataDelayed.id], now: instant)
        XCTAssertTrue(ledger.jobs.isEmpty)
        try ledger.reconcile(manifests: [metadataDelayed, receiptDelayed], receivedSegmentIDs: [metadataDelayed.id], now: instant)
        XCTAssertEqual(ledger.jobs.map(\.manifest.id), [metadataDelayed.id])
        try ledger.reconcile(manifests: [metadataDelayed, receiptDelayed], receivedSegmentIDs: [metadataDelayed.id, receiptDelayed.id], now: instant)
        XCTAssertEqual(Set(ledger.jobs.map(\.manifest.id)), [metadataDelayed.id, receiptDelayed.id])
        XCTAssertTrue(ledger.eligibleFutureIDs.isEmpty, "Known IDs remain part of the immutable baseline.")
    }

    func testLegacySelectionMigratesToAllExistingAndNewRecordingsIdempotently() throws {
        let selected = manifest(), formerlyUnselected = manifest(), laterReceived = manifest()
        var ledger = try AutomaticDeliveryLedger(scope: scope(), baselineIDs: [selected.id, formerlyUnselected.id],
            selectedExistingIDs: [selected.id], includeFuture: false, createdAt: instant)
        try ledger.reconcile(manifests: [selected, formerlyUnselected, laterReceived],
            receivedSegmentIDs: [selected.id, formerlyUnselected.id, laterReceived.id], now: instant)
        let originalJobs = ledger.jobs
        XCTAssertEqual(originalJobs.map(\.manifest.id), [selected.id])
        let url = try path()
        try ledger.persist(to: url)
        ledger = try AutomaticDeliveryLedger.load(from: url, expectedScope: ledger.scope)
        XCTAssertEqual(ledger.schemaVersion, 1, "Loading legacy state does not silently migrate or enable it.")
        XCTAssertTrue(try ledger.migrateToAllRecordings())
        XCTAssertEqual(ledger.schemaVersion, 2)
        XCTAssertEqual(ledger.jobs, originalJobs)
        XCTAssertEqual(ledger.selectedExistingIDs, ledger.baselineIDs)
        XCTAssertTrue(ledger.includeFuture)
        let migrated = ledger
        XCTAssertFalse(try ledger.migrateToAllRecordings())
        XCTAssertEqual(ledger, migrated)
        try ledger.persist(to: url)
        ledger = try AutomaticDeliveryLedger.load(from: url, expectedScope: migrated.scope)
        XCTAssertEqual(ledger, migrated)
        let added = try ledger.reconcile(manifests: [selected, formerlyUnselected, laterReceived],
            receivedSegmentIDs: [selected.id, formerlyUnselected.id, laterReceived.id], now: instant)
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(Set(ledger.jobs.map(\.manifest.id)), [selected.id, formerlyUnselected.id, laterReceived.id])
        XCTAssertEqual(ledger.job(for: originalJobs[0].id), originalJobs[0])
    }

    func testMigrationPreservesEveryJobStateArchiveReceiptAndScopeExactly() throws {
        let records = (0..<6).map { _ in manifest() }
        let unselected = manifest(), previousFuture = manifest()
        let originalScope = scope()
        let baseline = Set(records.map(\.id)).union([unselected.id])
        var ledger = try AutomaticDeliveryLedger(scope: originalScope, baselineIDs: baseline,
            selectedExistingIDs: Set(records.map(\.id)), includeFuture: true, createdAt: instant)
        let initial = records + [previousFuture]
        try ledger.reconcile(manifests: initial, receivedSegmentIDs: Set(initial.map(\.id)), now: instant)
        let ids = try records.map { record in try XCTUnwrap(ledger.jobs.first { $0.manifest.id == record.id }?.id) }
        try ledger.beginPreparation(deliveryID: ids[1], now: instant)
        for id in ids[2...5] {
            try prepare(id, in: &ledger)
            try ledger.beginUpload(deliveryID: id, now: instant)
        }
        try ledger.recordFailure(deliveryID: ids[3], statusCode: 503, message: "retry", now: instant)
        let accepted = try receipt(for: XCTUnwrap(ledger.job(for: ids[4])))
        try ledger.acceptReceipt(accepted, forScope: originalScope, now: instant)
        try ledger.recordFailure(deliveryID: ids[5], statusCode: 403, message: "repair required", now: instant)
        XCTAssertEqual(Set(ledger.jobs.map { $0.state.rawValue }), ["queued", "preparing", "uploading", "retryWaiting", "delivered", "blocked"])
        let before = ledger
        let serializedJobs = try TransportCodec.encode(ledger.jobs)
        XCTAssertTrue(try ledger.migrateToAllRecordings())
        XCTAssertEqual(ledger.scope, before.scope)
        XCTAssertEqual(ledger.createdAt, before.createdAt)
        XCTAssertEqual(ledger.baselineIDs, before.baselineIDs)
        XCTAssertEqual(ledger.eligibleFutureIDs, before.eligibleFutureIDs)
        XCTAssertEqual(ledger.jobs, before.jobs)
        XCTAssertEqual(try TransportCodec.encode(ledger.jobs), serializedJobs)
        XCTAssertEqual(ledger.job(for: ids[4])?.receipt, accepted)
        XCTAssertEqual(ledger.job(for: ids[5])?.state, .blocked)
        let url = try path()
        try ledger.persist(to: url)
        XCTAssertEqual(try AutomaticDeliveryLedger.load(from: url, expectedScope: originalScope), ledger)
    }

    func testSchemaTwoRejectsAnyPartialSelectionOrFutureOptOutInsteadOfRepairingIt() throws {
        let original = manifest()
        let ledger = try AutomaticDeliveryLedger(scope: scope(), knownRecordingIDs: [original.id], createdAt: instant)
        let partial = try altered(ledger) { $0["selectedExistingIDs"] = [] as [String] }
        let futureDisabled = try altered(ledger) { $0["includeFuture"] = false }
        for broken in [partial, futureDisabled] {
            XCTAssertThrowsError(try broken.validate()) { XCTAssertEqual($0 as? AutomaticDeliveryLedgerError, .invalidAuthorization) }
            var candidate = broken
            XCTAssertThrowsError(try candidate.migrateToAllRecordings())
            XCTAssertEqual(candidate, broken)
            let url = try path()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TransportCodec.encode(broken).write(to: url)
            XCTAssertThrowsError(try AutomaticDeliveryLedger.load(from: url, expectedScope: ledger.scope))
        }
    }

    func testAllRecordingsIncrementalRefreshAndTranscriptVersionsStayIdempotent() throws {
        let existing = manifest(), later = manifest()
        var ledger = try AutomaticDeliveryLedger(scope: scope(), knownRecordingIDs: [existing.id], createdAt: instant)
        let audioID = try XCTUnwrap(ledger.reconcile(manifests: [existing], receivedSegmentIDs: [existing.id], now: instant).first)
        try prepare(audioID, in: &ledger)
        try ledger.beginUpload(deliveryID: audioID, now: instant)
        try ledger.acceptReceipt(receipt(for: XCTUnwrap(ledger.job(for: audioID))), forScope: ledger.scope, now: instant)
        let deliveredAudio = ledger.job(for: audioID)
        try ledger.reconcile(manifests: [existing, later], receivedSegmentIDs: [existing.id, later.id],
            transcriptHashes: [existing.id: digest], now: instant)
        XCTAssertEqual(ledger.jobs.count, 3)
        let checkpoint = ledger
        XCTAssertEqual(try ledger.reconcile(manifests: [existing, later], receivedSegmentIDs: [existing.id, later.id],
            transcriptHashes: [existing.id: digest], now: instant), [])
        XCTAssertEqual(ledger, checkpoint)
        try ledger.reconcile(manifests: [existing, later], receivedSegmentIDs: [existing.id, later.id], now: instant)
        XCTAssertEqual(ledger, checkpoint, "Missing transcript cache does not invent another audio version.")
        let revision = try ledger.reconcile(manifests: [existing, later], receivedSegmentIDs: [existing.id, later.id],
            transcriptHashes: [existing.id: otherDigest], now: instant)
        XCTAssertEqual(revision.count, 1)
        XCTAssertEqual(ledger.jobs.count, 4)
        XCTAssertEqual(ledger.job(for: audioID), deliveredAudio)
        let url = try path()
        try ledger.persist(to: url)
        ledger = try AutomaticDeliveryLedger.load(from: url, expectedScope: ledger.scope)
        XCTAssertEqual(try ledger.reconcile(manifests: [existing, later], receivedSegmentIDs: [existing.id, later.id],
            transcriptHashes: [existing.id: otherDigest], now: instant), [])
    }

    func testAllRecordingsMigrationCannotRebindScopeOrReuseAnotherGrantsReceipt() throws {
        var (legacy, recording, legacyID) = try queuedLedger()
        try prepare(legacyID, in: &legacy)
        try legacy.beginUpload(deliveryID: legacyID, now: instant)
        let originalReceipt = try receipt(for: XCTUnwrap(legacy.job(for: legacyID)))
        let originalScope = legacy.scope
        try legacy.migrateToAllRecordings()
        let migrated = legacy
        let replacementScope = scope(receiverID: originalScope.receiverID)
        XCTAssertThrowsError(try legacy.acceptReceipt(originalReceipt, forScope: replacementScope, now: instant))
        XCTAssertEqual(legacy, migrated)
        var replacement = try AutomaticDeliveryLedger(scope: replacementScope, knownRecordingIDs: [recording.id], createdAt: instant)
        let replacementID = try XCTUnwrap(replacement.reconcile(manifests: [recording], receivedSegmentIDs: [recording.id], now: instant).first)
        try prepare(replacementID, in: &replacement)
        try replacement.beginUpload(deliveryID: replacementID, now: instant)
        let beforeWrongReceipt = replacement
        XCTAssertThrowsError(try replacement.acceptReceipt(originalReceipt, forScope: replacementScope, now: instant))
        XCTAssertEqual(replacement, beforeWrongReceipt)
        try legacy.acceptReceipt(originalReceipt, forScope: originalScope, now: instant)
        XCTAssertEqual(legacy.job(for: legacyID)?.state, .delivered)
        XCTAssertEqual(replacement.job(for: replacementID)?.state, .uploading)
    }

    func testOverCapacityMigrationFailsAtomicallyInsteadOfCreatingPartialAllScope() throws {
        let baseline = Set((0..<AutomaticDeliveryLedger.maximumAuthorizedRecordings).map { _ in UUID() })
        let future = manifest()
        var ledger = try AutomaticDeliveryLedger(scope: scope(), baselineIDs: baseline, selectedExistingIDs: [], includeFuture: true, createdAt: instant)
        try ledger.reconcile(manifests: [future], receivedSegmentIDs: [future.id], now: instant)
        let before = ledger
        XCTAssertThrowsError(try ledger.migrateToAllRecordings()) { XCTAssertEqual($0 as? AutomaticDeliveryLedgerError, .capacityExceeded) }
        XCTAssertEqual(ledger, before)
    }
}
