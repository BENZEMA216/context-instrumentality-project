import XCTest
import CryptoKit
import Darwin
@testable import RecordingCore

final class RecordingIntegrityAuditTests: XCTestCase {
    private var temporary: URL!
    private var root: URL!
    private var repository: RecordingRepository!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = temporary.appendingPathComponent("library")
        repository = try RecordingRepository(root: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func seal(_ bytes: Data = Data(repeating: 0x61, count: 600_000)) throws -> SegmentManifest {
        let id = UUID()
        let session = RecordingSession(startedAt: Date(timeIntervalSince1970: 1_800_000_000), state: .paused)
        try repository.saveSession(session)
        let path = repository.stagingURL(for: id)
        try bytes.write(to: path)
        return try repository.sealSegment(stagedURL: path, id: id, sessionID: session.id, sequence: 0,
            startedAt: session.startedAt, endedAt: session.startedAt.addingTimeInterval(60),
            sampleRate: 16_000, frameCount: 960_000)
    }
    private func auditor(_ generation: String = "test-generation") -> RecordingIntegrityAuditor {
        RecordingIntegrityAuditor(root: root, libraryGeneration: generation)
    }
    private func auditReport(_ mode: RecordingIntegrityMode = .full, baseline: RecordingIntegrityBaseline? = nil) throws -> RecordingIntegrityReport {
        try auditor().audit(mode: mode, nonce: UUID().uuidString, baseline: baseline)
    }
    private func audioEntry(_ report: RecordingIntegrityReport) throws -> RecordingIntegrityEntry {
        try XCTUnwrap(report.entries.first { $0.sourceKind == "sealed_audio" })
    }
    private func codes(_ report: RecordingIntegrityReport) -> Set<String> { Set(report.issues.map(\.code)) }

    func testFullReadsKnownContentAndQuickReusesOnlyHistoricalDigest() throws {
        let source = try seal(Data("abc".utf8))
        let full = try auditReport()
        XCTAssertTrue(full.passed)
        XCTAssertTrue(full.fullContentVerified)
        let entry = try audioEntry(full)
        XCTAssertEqual(entry.observedSHA256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(entry.expectedSHA256, source.sha256)
        XCTAssertEqual(entry.bytesHashed, 3)
        let quick = try auditReport(.quick, baseline: XCTUnwrap(full.nextBaseline))
        XCTAssertTrue(quick.passed)
        XCTAssertFalse(quick.fullContentVerified)
        XCTAssertEqual(try audioEntry(quick).verification, .historicalHashMetadataUnchanged)
        XCTAssertEqual(try audioEntry(quick).bytesHashed, 0)
        XCTAssertEqual(try audioEntry(quick).hashObservedAt, entry.hashObservedAt)
        XCTAssertEqual(quick.historicalHashCount, 1)
        XCTAssertGreaterThan(quick.bytesHashed, 0, "Metadata is freshly hashed, even in quick mode")
    }

    func testNewNonceFullNeverUsesOldFullBaselineForAudio() throws {
        _ = try seal()
        let first = try auditReport()
        let second = try auditReport(.full, baseline: XCTUnwrap(first.nextBaseline))
        XCTAssertTrue(second.fullContentVerified)
        XCTAssertEqual(try audioEntry(second).verification, .currentHash)
        XCTAssertEqual(try audioEntry(second).bytesHashed, 600_000)
    }

    func testSameSizeCorruptionForcesFreshHashAndFails() throws {
        let manifest = try seal(Data("good".utf8))
        let full = try auditReport()
        try Data("evil".utf8).write(to: repository.audioURL(for: manifest))
        let quick = try auditReport(.quick, baseline: XCTUnwrap(full.nextBaseline))
        XCTAssertFalse(quick.passed)
        XCTAssertNil(quick.nextBaseline)
        XCTAssertTrue(codes(quick).contains("checksum_mismatch"))
        XCTAssertEqual(try audioEntry(quick).bytesHashed, 4)
        XCTAssertNotEqual(try audioEntry(quick).expectedSHA256, try audioEntry(quick).observedSHA256)
    }

    func testNewSegmentIsActuallyHashedWhileUnchangedSegmentIsSkipped() throws {
        _ = try seal()
        let initial = try auditReport()
        _ = try seal(Data("new recording".utf8))
        let quick = try auditReport(.quick, baseline: XCTUnwrap(initial.nextBaseline))
        XCTAssertTrue(quick.passed)
        let audio = quick.entries.filter { $0.sourceKind == "sealed_audio" }
        XCTAssertEqual(audio.filter { $0.verification == .historicalHashMetadataUnchanged }.count, 1)
        XCTAssertEqual(audio.filter { $0.verification == .currentHash }.count, 1)
    }

    func testExactAcknowledgementAllowsLegalPruneButMissingAudioDoesNot() throws {
        let manifest = try seal()
        let baseline = try XCTUnwrap(auditReport().nextBaseline)
        try repository.acknowledge(.init(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount))
        let pruned = try auditReport(.quick, baseline: baseline)
        XCTAssertTrue(pruned.passed)
        XCTAssertEqual(pruned.acknowledgedPrunedCount, 1)
        XCTAssertNil(try audioEntry(pruned).observedSHA256)
        try FileManager.default.removeItem(at: root.appendingPathComponent("acknowledgements/\(manifest.id.uuidString.lowercased()).json"))
        let missing = try auditReport(.quick, baseline: baseline)
        XCTAssertFalse(missing.passed)
        XCTAssertTrue(codes(missing).contains("missing_audio"))
    }

    func testWrongAcknowledgementCannotInventPruneEvidence() throws {
        let manifest = try seal()
        try FileManager.default.removeItem(at: repository.audioURL(for: manifest))
        let wrong = SegmentReceipt(segmentID: manifest.id, sha256: String(repeating: "0", count: 64), byteCount: manifest.byteCount)
        try TransportCodec.encode(wrong).write(to: root.appendingPathComponent("acknowledgements/\(manifest.id.uuidString.lowercased()).json"))
        let report = try auditReport()
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.acknowledgedPrunedCount, 0)
        XCTAssertTrue(codes(report).contains("acknowledgement_identity_mismatch"))
        XCTAssertTrue(codes(report).contains("missing_audio"))
    }

    func testRecoveryOriginalIsReadThenProtectedByBaselineDigest() throws {
        _ = try seal()
        let directory = root.appendingPathComponent("recovered-originals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("preserved.caf")
        try Data("recovered".utf8).write(to: file)
        let first = try auditReport()
        XCTAssertTrue(first.passed)
        XCTAssertEqual(first.recoveredOriginalCount, 1)
        let recovered = try XCTUnwrap(first.entries.first { $0.sourceKind == "recovered_original" })
        XCTAssertNil(recovered.expectedSHA256)
        XCTAssertEqual(recovered.bytesHashed, 9)
        let quick = try auditReport(.quick, baseline: XCTUnwrap(first.nextBaseline))
        XCTAssertTrue(quick.passed)
        XCTAssertEqual(quick.entries.first { $0.sourceKind == "recovered_original" }?.verification, .historicalHashMetadataUnchanged)
        try Data("CORRUPTED".utf8).write(to: file)
        XCTAssertTrue(codes(try auditReport(.quick, baseline: first.nextBaseline)).contains("checksum_mismatch"))
    }

    func testBaselineMissingManifestCannotBecomeSmallerSuccessfulLibrary() throws {
        let manifest = try seal()
        let first = try auditReport()
        try FileManager.default.removeItem(at: root.appendingPathComponent("manifests/\(manifest.id.uuidString.lowercased()).json"))
        try FileManager.default.removeItem(at: repository.audioURL(for: manifest))
        let quick = try auditReport(.quick, baseline: XCTUnwrap(first.nextBaseline))
        XCTAssertFalse(quick.passed)
        XCTAssertTrue(codes(quick).contains("baseline_member_missing"))
    }

    func testMalformedManifestAndExtraAudioCannotPass() throws {
        _ = try seal()
        try Data("broken".utf8).write(to: root.appendingPathComponent("manifests/extra.json"))
        try Data("orphan".utf8).write(to: root.appendingPathComponent("segments/\(UUID().uuidString.lowercased()).caf"))
        let report = try auditReport()
        XCTAssertFalse(report.passed)
        XCTAssertTrue(codes(report).contains("malformed_manifest"))
        XCTAssertTrue(codes(report).contains("untracked_audio"))
    }

    func testStagingAndActiveSessionFailClosed() throws {
        _ = try seal()
        try Data("open".utf8).write(to: repository.stagingURL(for: UUID()))
        try repository.saveSession(RecordingSession(state: .recording))
        let report = try auditReport()
        XCTAssertFalse(report.passed)
        XCTAssertFalse(report.fullContentVerified)
        XCTAssertTrue(codes(report).contains("unsealed_recording_material"))
        XCTAssertTrue(codes(report).contains("open_recording_session"))
    }

    func testSymlinksAndHardLinksAreRejectedWithoutReadingTarget() throws {
        let manifest = try seal()
        let audio = repository.audioURL(for: manifest)
        let outside = temporary.appendingPathComponent("outside.caf")
        try FileManager.default.moveItem(at: audio, to: outside)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: outside)
        let linked = try auditReport()
        XCTAssertFalse(linked.passed)
        XCTAssertTrue(codes(linked).contains("unexpected_library_member"))
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.linkItem(at: outside, to: audio)
        XCTAssertTrue(codes(try auditReport()).contains("unexpected_library_member"))
    }

    func testMutationWhileStreamingAndCatalogAdditionInvalidateFullResult() throws {
        let manifest = try seal(Data(repeating: 1, count: 1_000_000))
        let audio = repository.audioURL(for: manifest)
        var changed = false
        let report = try auditor().audit(mode: .full, nonce: "mutating", while: {
            if !changed, let handle = try? FileHandle(forWritingTo: audio) {
                changed = true
                try? handle.seek(toOffset: 999_999)
                try? handle.write(contentsOf: Data([2]))
                try? handle.close()
                try? Data("new".utf8).write(to: self.root.appendingPathComponent("segments/new.caf"))
            }
            return true
        })
        XCTAssertFalse(report.passed)
        XCTAssertTrue(codes(report).contains("catalog_changed_during_audit"))
    }

    func testMutationAfterFirstAudioChunkCannotProduceSuccessfulCurrentHash() throws {
        let manifest = try seal(Data(repeating: 1, count: 1_000_000))
        let audio = repository.audioURL(for: manifest)
        var checks = 0
        let report = try auditor().audit(mode: .full, nonce: "during-stream", while: {
            checks += 1
            // One manifest + one paused session each use outer/read/EOF checks;
            // With the initial cancellation check, check 10 is after the first audio chunk.
            if checks == 10, let handle = try? FileHandle(forWritingTo: audio) {
                try? handle.seek(toOffset: 999_999)
                try? handle.write(contentsOf: Data([2]))
                try? handle.close()
            }
            return true
        })
        XCTAssertGreaterThanOrEqual(checks, 10)
        XCTAssertFalse(report.fullContentVerified)
        XCTAssertTrue(codes(report).contains("file_changed_during_read"))
        XCTAssertNil(try audioEntry(report).observedSHA256)
    }

    func testRecoveryStagingCannotBeSilentlyExcluded() throws {
        _ = try seal()
        let directory = root.appendingPathComponent("recovery-staging")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("unfinished recovery".utf8).write(to: directory.appendingPathComponent("tail.caf"))
        let report = try auditReport()
        XCTAssertFalse(report.passed)
        XCTAssertTrue(codes(report).contains("unsealed_recording_material"))
    }

    func testCancelledFullCheckpointsResumeSameNonceButNeverPretendSameCallRead() throws {
        _ = try seal()
        _ = try seal()
        var audioFinished = false
        var saved: RecordingIntegrityCheckpoint?
        let partial = try auditor().audit(mode: .full, nonce: "bounded-run", while: { !audioFinished }, onCheckpoint: { checkpoint in
            saved = checkpoint
            audioFinished = checkpoint.entries.contains { $0.sourceKind == "sealed_audio" }
        })
        XCTAssertFalse(partial.isComplete)
        XCTAssertFalse(partial.fullContentVerified)
        XCTAssertNil(partial.nextBaseline)
        let restored = try TransportCodec.decode(RecordingIntegrityCheckpoint.self, from: TransportCodec.encode(XCTUnwrap(saved)))
        let finished = try auditor().audit(mode: .full, nonce: "bounded-run", checkpoint: restored)
        XCTAssertTrue(finished.passed)
        XCTAssertTrue(finished.fullContentVerified)
        XCTAssertEqual(finished.entries.filter { $0.sourceKind == "sealed_audio" && $0.verification == .checkpointHashMetadataUnchanged }.count, 1)
        XCTAssertGreaterThan(finished.filesHashedInObservationWindow, finished.filesHashedThisCall)
        XCTAssertEqual(finished.entries.filter { $0.sourceKind == "sealed_audio" }.reduce(0) { $0 + $1.bytesHashed }, 600_000)
        XCTAssertEqual(finished.startedAt, restored.startedAt)
    }

    func testDefaultCheckpointCallbackStillEmitsEveryPhysicallyReadFile() throws {
        _ = try seal(Data("first".utf8))
        _ = try seal(Data("second".utf8))
        var emittedCounts: [Int] = []
        let report = try auditor().audit(mode: .full, nonce: "default-checkpoints", onCheckpoint: {
            emittedCounts.append($0.entries.count)
        })
        XCTAssertTrue(report.fullContentVerified)
        XCTAssertEqual(emittedCounts, Array(1...report.filesHashedThisCall))
        XCTAssertEqual(report.checkpoint.entries.count, report.filesHashedThisCall)
    }

    func testThrottledCheckpointCallbackReturnsCompleteFinalCoverage() throws {
        _ = try seal(Data("first".utf8))
        _ = try seal(Data("second".utf8))
        _ = try seal(Data("third".utf8))
        var emitted: [RecordingIntegrityCheckpoint] = []
        let report = try auditor().audit(mode: .full, nonce: "throttled-checkpoints",
            checkpointInterval: 3_600, onCheckpoint: { emitted.append($0) })
        XCTAssertTrue(report.fullContentVerified)
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.entries.count, 1)
        XCTAssertEqual(report.checkpoint.entries.count, 9)
        XCTAssertEqual(report.checkpoint.metadataData.count, 6)
        XCTAssertEqual(report.filesHashedInObservationWindow, 9)
        XCTAssertEqual(Set(report.checkpoint.entries.map(\.relativePath)), Set(report.entries.map(\.relativePath)))
        let restored = try TransportCodec.decode(RecordingIntegrityCheckpoint.self,
            from: TransportCodec.encode(report.checkpoint))
        let resumed = try auditor().audit(mode: .full, nonce: "throttled-checkpoints", checkpoint: restored)
        XCTAssertTrue(resumed.fullContentVerified)
        XCTAssertEqual(resumed.filesHashedThisCall, 0)
        XCTAssertEqual(resumed.filesHashedInObservationWindow, 9)
    }

    func testThrottledInterruptionKeepsUnemittedReadsForResume() throws {
        _ = try seal(Data("first".utf8))
        _ = try seal(Data("second".utf8))
        _ = try seal(Data("third".utf8))
        var checks = 0
        var emitted: [RecordingIntegrityCheckpoint] = []
        let partial = try auditor().audit(mode: .full, nonce: "throttled-interruption",
            checkpointInterval: 3_600, while: {
                checks += 1
                return checks < 12
            }, onCheckpoint: { emitted.append($0) })
        XCTAssertFalse(partial.isComplete)
        XCTAssertFalse(partial.fullContentVerified)
        XCTAssertNil(partial.nextBaseline)
        XCTAssertEqual(codes(partial), ["interrupted"])
        XCTAssertEqual(emitted.count, 1)
        XCTAssertGreaterThan(partial.checkpoint.entries.count, try XCTUnwrap(emitted.first).entries.count)
        XCTAssertEqual(partial.checkpoint.entries.count, partial.filesHashedThisCall)
        let restored = try TransportCodec.decode(RecordingIntegrityCheckpoint.self,
            from: TransportCodec.encode(partial.checkpoint))
        let finished = try auditor().audit(mode: .full, nonce: "throttled-interruption", checkpoint: restored)
        XCTAssertTrue(finished.fullContentVerified)
        XCTAssertEqual(finished.filesHashedInObservationWindow, 9)
        XCTAssertEqual(finished.filesHashedThisCall + partial.filesHashedThisCall, 9)
    }

    func testCheckpointRejectsWrongNonceGenerationCatalogAndExpiry() throws {
        let source = try seal()
        let full = try auditor().audit(mode: .full, nonce: "fixed")
        let checkpoint = full.checkpoint
        XCTAssertThrowsError(try auditor().audit(mode: .full, nonce: "other", checkpoint: checkpoint))
        XCTAssertThrowsError(try auditor("other-generation").audit(mode: .full, nonce: "fixed", checkpoint: checkpoint))
        let expired = RecordingIntegrityCheckpoint(schemaVersion: 1, nonce: checkpoint.nonce, mode: checkpoint.mode,
            libraryGeneration: checkpoint.libraryGeneration, rootIdentity: checkpoint.rootIdentity,
            catalogDigest: checkpoint.catalogDigest, startedAt: Date().addingTimeInterval(-3_601), entries: checkpoint.entries)
        XCTAssertThrowsError(try auditor().audit(mode: .full, nonce: "fixed", checkpoint: expired))
        try Data(repeating: 9, count: 600_000).write(to: repository.audioURL(for: source))
        XCTAssertThrowsError(try auditor().audit(mode: .full, nonce: "fixed", checkpoint: checkpoint))
    }

    func testAuditDoesNotModifySourceBytesOrCreateRepositoryDirectories() throws {
        _ = try seal()
        func tree() throws -> [String: Data] {
            let urls = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            var values: [String: Data] = [:]
            for case let url as URL in urls where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                values[url.path] = try Data(contentsOf: url)
            }
            return values
        }
        let before = try tree()
        XCTAssertTrue(try auditReport().passed)
        XCTAssertEqual(try tree(), before)
        let nonexistent = temporary.appendingPathComponent("missing")
        XCTAssertThrowsError(try RecordingIntegrityAuditor(root: nonexistent, libraryGeneration: "missing").audit(mode: .full, nonce: "x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nonexistent.path))
    }

    func testDanglingOptionalDirectorySymlinkCannotDisappearFromScope() throws {
        _ = try seal()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("recovered-originals"),
            withDestinationURL: temporary.appendingPathComponent("absent"))
        let report = try auditReport()
        XCTAssertFalse(report.passed)
        XCTAssertTrue(codes(report).contains("directory_unavailable"))
    }

    func testSourceManifestMutationCannotBeAdoptedByQuickCheck() throws {
        let manifest = try seal()
        let original = try auditReport()
        let changed = SegmentManifest(id: manifest.id, sessionID: manifest.sessionID, sequence: manifest.sequence + 1,
            startedAt: manifest.startedAt, endedAt: manifest.endedAt, sampleRate: manifest.sampleRate,
            frameCount: manifest.frameCount, fileName: manifest.fileName, byteCount: manifest.byteCount, sha256: manifest.sha256)
        try TransportCodec.encode(changed).write(to: root.appendingPathComponent("manifests/\(manifest.id.uuidString.lowercased()).json"))
        let report = try auditReport(.quick, baseline: original.nextBaseline)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(codes(report).contains("source_manifest_changed"))
        XCTAssertNil(report.nextBaseline)
    }

    func testTinyBatchesAdvanceThroughMetadataAndAudioWithoutRereadingOldFiles() throws {
        _ = try seal()
        _ = try seal()
        _ = try seal()
        var checkpoint: RecordingIntegrityCheckpoint?
        var completed: RecordingIntegrityReport?
        var previousCount = 0
        var totalReadCount = 0
        for _ in 0..<12 {
            var batchSpent = false
            let report = try auditor().audit(mode: .full, nonce: "tiny-budget", checkpoint: checkpoint,
                while: { !batchSpent }, onCheckpoint: { _ in batchSpent = true })
            totalReadCount += report.filesHashedThisCall
            XCTAssertEqual(report.filesHashedThisCall, 1, "Only one new file is allowed in each batch")
            XCTAssertGreaterThan(report.checkpoint.entries.count, previousCount)
            previousCount = report.checkpoint.entries.count
            checkpoint = try TransportCodec.decode(RecordingIntegrityCheckpoint.self,
                from: TransportCodec.encode(report.checkpoint))
            if report.isComplete { completed = report; break }
            XCTAssertEqual(codes(report), ["interrupted"])
        }
        let final = try XCTUnwrap(completed)
        XCTAssertTrue(final.fullContentVerified)
        XCTAssertEqual(final.retainedAudioCount, 3)
        XCTAssertEqual(final.filesHashedInObservationWindow, 9)
        XCTAssertEqual(totalReadCount, 9, "Every metadata/audio file is physically read exactly once in the window")
        XCTAssertEqual(final.checkpoint.metadataData.count, 6)
        XCTAssertEqual(final.entries.filter { $0.verification == .checkpointHashMetadataUnchanged }.count, 8)
        let quick = try auditReport(.quick, baseline: XCTUnwrap(final.nextBaseline))
        XCTAssertTrue(quick.passed)
        XCTAssertEqual(quick.historicalHashCount, 3,
            "A completed window's checkpoint reads become historical baseline evidence for later quick checks")
        XCTAssertEqual(quick.entries.filter { $0.sourceKind == "sealed_audio" }.reduce(0) { $0 + $1.bytesHashed }, 0)
    }

    func testCheckpointMetadataBytesCannotBeForgedOrDetachedFromObservedDigest() throws {
        _ = try seal()
        let report = try auditor().audit(mode: .full, nonce: "cached-metadata")
        var cached = report.checkpoint.metadataData
        let path = try XCTUnwrap(cached.keys.first)
        cached[path] = Data("forged".utf8)
        let corrupt = RecordingIntegrityCheckpoint(schemaVersion: 1, nonce: report.checkpoint.nonce,
            mode: .full, libraryGeneration: report.libraryGeneration, rootIdentity: report.rootIdentity,
            catalogDigest: report.catalogDigest, startedAt: report.startedAt,
            entries: report.checkpoint.entries, metadataData: cached)
        XCTAssertThrowsError(try auditor().audit(mode: .full, nonce: "cached-metadata", checkpoint: corrupt)) { error in
            XCTAssertEqual(error as? RecordingIntegrityAuditError,
                .invalidCheckpoint("checkpoint_metadata_digest_mismatch"))
        }
    }

    func testReceiptMustMatchSourceAndCannotAuthorizePruning() throws {
        let manifest = try seal()
        let path = root.appendingPathComponent("receipts/\(manifest.id.uuidString.lowercased()).json")
        let wrong = SegmentReceipt(segmentID: manifest.id, sha256: String(repeating: "0", count: 64), byteCount: manifest.byteCount)
        try TransportCodec.encode(wrong).write(to: path)
        let invalid = try auditReport()
        XCTAssertFalse(invalid.passed)
        XCTAssertTrue(codes(invalid).contains("receipt_identity_mismatch"))
        let exact = SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount)
        try TransportCodec.encode(exact).write(to: path)
        XCTAssertTrue(try auditReport().passed)
        try FileManager.default.removeItem(at: repository.audioURL(for: manifest))
        let prunedWithoutAck = try auditReport()
        XCTAssertFalse(prunedWithoutAck.passed)
        XCTAssertEqual(prunedWithoutAck.acknowledgedPrunedCount, 0)
        XCTAssertTrue(codes(prunedWithoutAck).contains("missing_audio"))
    }

    func testCancelledQuickDoesNotMisreportUnparsedLegalPruneAsMissing() throws {
        let manifest = try seal()
        let baseline = try XCTUnwrap(auditReport().nextBaseline)
        try repository.acknowledge(.init(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount))
        let interrupted = try auditor().audit(mode: .quick, nonce: "cancelled", baseline: baseline, while: { false })
        XCTAssertFalse(interrupted.isComplete)
        XCTAssertEqual(codes(interrupted), ["interrupted"])
        let completed = try auditor().audit(mode: .quick, nonce: "cancelled", baseline: baseline,
            checkpoint: interrupted.checkpoint)
        XCTAssertTrue(completed.passed)
        XCTAssertEqual(completed.acknowledgedPrunedCount, 1)
    }

    func testCancelledCachedMetadataWindowDoesNotCompleteWithoutActivityPermission() throws {
        _ = try seal()
        let full = try auditor().audit(mode: .full, nonce: "cached-cancel")
        let cancelled = try auditor().audit(mode: .full, nonce: "cached-cancel",
            checkpoint: full.checkpoint, while: { false })
        XCTAssertFalse(cancelled.isComplete)
        XCTAssertFalse(cancelled.fullContentVerified)
        XCTAssertEqual(codes(cancelled), ["interrupted"])
        XCTAssertEqual(cancelled.bytesHashed, 0)
    }

    func testReportRoundTripsWithHistoricalAndCurrentHashesDistinct() throws {
        _ = try seal()
        let report = try auditReport()
        let decoded = try TransportCodec.decode(RecordingIntegrityReport.self, from: TransportCodec.encode(report))
        XCTAssertEqual(decoded.entries, report.entries)
        XCTAssertEqual(decoded.nextBaseline, report.nextBaseline)
        XCTAssertEqual(decoded.nonce, report.nonce)
        XCTAssertEqual(decoded.catalogDigest, report.catalogDigest)
    }
}
