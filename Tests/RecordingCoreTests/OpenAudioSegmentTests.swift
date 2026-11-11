import Foundation
import XCTest
@testable import RecordingCore

/// Core treats candidate bytes as opaque; WatchAudio tests verify actual PCM recovery.
final class OpenAudioSegmentTests: XCTestCase {
    private struct SimulatedCrash: Error {}
    private var directory: URL!
    private let instant = Date(timeIntervalSince1970: 1_800_000_000.123)
    private let originalBytes = Data(repeating: 27, count: 8_192)
    private let candidateBytes = Data(repeating: 61, count: 4_096)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func repository(_ name: String = "watch",
                            fault: ((RepositoryFaultPoint) throws -> Void)? = nil) throws -> RecordingRepository {
        try RecordingRepository(root: directory.appendingPathComponent(name), faultInjector: fault)
    }

    private func segment(id: UUID = UUID(), sessionID: UUID = UUID(), sequence: Int = 3,
                         startedAt: Date? = nil, sampleRate: Double = 16_000,
                         channels: UInt32 = 1, timeZone: String? = "Asia/Shanghai",
                         schemaVersion: Int = 1) -> OpenAudioSegment {
        OpenAudioSegment(id: id, sessionID: sessionID, sequence: sequence,
            startedAt: startedAt ?? instant, sampleRate: sampleRate, channelCount: channels,
            pcmFormat: .float32, interleaved: false,
            timeZoneIdentifier: timeZone, schemaVersion: schemaVersion)
    }

    private func pendingURL(for segment: OpenAudioSegment, in repository: RecordingRepository) -> URL {
        repository.root.appendingPathComponent("staging")
            .appendingPathComponent(segment.id.uuidString.lowercased() + ".pending.json")
    }

    private func manifestURL(for segment: OpenAudioSegment, in repository: RecordingRepository) -> URL {
        repository.root.appendingPathComponent("manifests")
            .appendingPathComponent(segment.id.uuidString.lowercased() + ".json")
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @discardableResult
    private func prepareCandidate(for segment: OpenAudioSegment, in repository: RecordingRepository) throws -> URL {
        try repository.beginAudioSegment(segment)
        try originalBytes.write(to: repository.stagingURL(for: segment.id))
        let candidate = try repository.prepareAudioRecoveryCandidate(for: segment)
        try candidateBytes.write(to: candidate)
        return candidate
    }

    private func assertSourceAndJournalPreserved(_ segment: OpenAudioSegment,
                                                 in repository: RecordingRepository,
                                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: repository.stagingURL(for: segment.id)), originalBytes, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.openSegmentURL(for: segment.id).path), file: file, line: line)
    }

    func testBeginPersistsIdentityBeforeAnyAudioExists() throws {
        let repository = try repository()
        let segment = segment()
        try repository.beginAudioSegment(segment)

        let onDisk = try TransportCodec.decode(OpenAudioSegment.self,
            from: Data(contentsOf: repository.openSegmentURL(for: segment.id)))
        XCTAssertEqual(onDisk, segment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.stagingURL(for: segment.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.recoveryCandidateURL(for: segment.id).path))
        let reopened = try self.repository()
        XCTAssertEqual(try reopened.openAudioSegments().segments, [segment])
        XCTAssertTrue(try reopened.openAudioSegments().issues.isEmpty)
        XCTAssertNil(try reopened.committedAudioSegment(for: segment))
        try reopened.beginAudioSegment(segment) // No samples yet: the same durable identity is idempotent.
        XCTAssertEqual(try reopened.openAudioSegments().segments, [segment])
    }

    func testInvalidMetadataIsRejectedBeforeCreatingJournal() throws {
        let repository = try repository()
        let invalid = [
            segment(sequence: -1), segment(sequence: Int.max),
            segment(sampleRate: 0), segment(sampleRate: .nan), segment(sampleRate: .infinity),
            segment(sampleRate: 384_001), segment(channels: 0), segment(channels: 33),
            segment(timeZone: "Invalid/NotARealZone"), segment(schemaVersion: 2),
            // Finite but outside TransportCodec's millisecond Int64 date range.
            segment(startedAt: Date(timeIntervalSince1970: 1e16))
        ]
        for segment in invalid {
            XCTAssertThrowsError(try repository.beginAudioSegment(segment))
            XCTAssertFalse(FileManager.default.fileExists(atPath: repository.openSegmentURL(for: segment.id).path))
        }
        XCTAssertTrue(try repository.openAudioSegments().segments.isEmpty)
    }

    func testBeginCannotReuseExistingSourcePendingOrCandidateIdentity() throws {
        for kind in ["source", "pending", "candidate"] {
            let repository = try repository(kind)
            let segment = segment()
            let occupied: URL
            switch kind {
            case "source": occupied = repository.stagingURL(for: segment.id)
            case "pending": occupied = pendingURL(for: segment, in: repository)
            default: occupied = repository.recoveryCandidateURL(for: segment.id)
            }
            try write(originalBytes, to: occupied)
            XCTAssertThrowsError(try repository.beginAudioSegment(segment)) {
                XCTAssertEqual($0 as? RepositoryError, .conflictingSegment)
            }
            XCTAssertEqual(try Data(contentsOf: occupied), originalBytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: repository.openSegmentURL(for: segment.id).path))
        }
    }

    func testInventoryPreservesCorruptJournalAndHistoricalUntrackedCAF() throws {
        let repository = try repository()
        let good = segment(), corruptID = UUID(), historicalID = UUID()
        try repository.beginAudioSegment(good)
        let corruptedJournal = Data("incomplete-json".utf8)
        try write(corruptedJournal, to: repository.openSegmentURL(for: corruptID))
        try originalBytes.write(to: repository.stagingURL(for: corruptID))
        try candidateBytes.write(to: repository.stagingURL(for: historicalID))

        let inventory = try repository.openAudioSegments()
        XCTAssertEqual(inventory.segments, [good])
        XCTAssertEqual(inventory.issues.count, 1)
        XCTAssertEqual(inventory.issues.first?.fileName, "open-segments/" + corruptID.uuidString.lowercased() + ".json")
        XCTAssertEqual(inventory.untrackedAudioCount, 1)
        XCTAssertEqual(try Data(contentsOf: repository.openSegmentURL(for: corruptID)), corruptedJournal)
        XCTAssertEqual(try Data(contentsOf: repository.stagingURL(for: corruptID)), originalBytes)
        XCTAssertEqual(try Data(contentsOf: repository.stagingURL(for: historicalID)), candidateBytes)
        XCTAssertTrue(try repository.manifests().isEmpty)
    }

    func testRebuildingUncommittedCandidateLeavesOriginalAndJournalUnchanged() throws {
        let repository = try repository()
        let segment = segment()
        let candidate = try prepareCandidate(for: segment, in: repository)
        let journalBefore = try Data(contentsOf: repository.openSegmentURL(for: segment.id))
        let originalBefore = try RecordingRepository.fingerprint(of: repository.stagingURL(for: segment.id))

        XCTAssertEqual(try repository.prepareAudioRecoveryCandidate(for: segment), candidate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        try assertSourceAndJournalPreserved(segment, in: repository)
        XCTAssertEqual(try Data(contentsOf: repository.openSegmentURL(for: segment.id)), journalBefore)
        let originalAfter = try RecordingRepository.fingerprint(of: repository.stagingURL(for: segment.id))
        XCTAssertEqual(originalAfter.sha256, originalBefore.sha256)
        XCTAssertEqual(originalAfter.byteCount, originalBefore.byteCount)
    }

    func testCommitCrashAtBothBoundariesReplaysExactCandidateAndArchivesOriginalIdempotently() throws {
        let boundaries: [(String, RepositoryFaultPoint)] = [
            ("after-audio", .afterAudioCommit), ("after-manifest", .afterManifestCommit)
        ]
        for (name, boundary) in boundaries {
            let repository = try repository(name, fault: { point in
                switch (point, boundary) {
                case (.afterAudioCommit, .afterAudioCommit), (.afterManifestCommit, .afterManifestCommit):
                    throw SimulatedCrash()
                default: break
                }
            })
            let segment = segment()
            let candidate = try prepareCandidate(for: segment, in: repository)
            let expectedCandidate = try RecordingRepository.fingerprint(of: candidate)
            let originalFingerprint = try RecordingRepository.fingerprint(of: repository.stagingURL(for: segment.id))
            XCTAssertThrowsError(try repository.commitRecoveredAudioSegment(segment, candidateURL: candidate, frameCount: 8_123))
            try assertSourceAndJournalPreserved(segment, in: repository)
            XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL(for: segment, in: repository).path))
            XCTAssertThrowsError(try repository.committedAudioSegment(for: segment))
            XCTAssertThrowsError(try repository.prepareAudioRecoveryCandidate(for: segment))

            let reopened = try RecordingRepository(root: repository.root, recoveryFailureHandling: .preserveAndReport)
            let manifest = try XCTUnwrap(reopened.committedAudioSegment(for: segment))
            XCTAssertEqual(manifest.sha256, expectedCandidate.sha256)
            XCTAssertEqual(manifest.byteCount, expectedCandidate.byteCount)
            XCTAssertEqual(manifest.frameCount, 8_123)
            XCTAssertEqual(manifest.sessionID, segment.sessionID)
            XCTAssertEqual(manifest.sequence, segment.sequence)
            XCTAssertEqual(manifest.startedAt, segment.startedAt)
            XCTAssertEqual(manifest.endedAt.timeIntervalSince(manifest.startedAt), Double(8_123) / 16_000, accuracy: 0.001)
            XCTAssertEqual(manifest.timeZoneIdentifier, segment.timeZoneIdentifier)
            XCTAssertNil(manifest.location)
            XCTAssertEqual(try Data(contentsOf: reopened.audioURL(for: manifest)), candidateBytes)
            try reopened.completeAudioSegment(segment)
            let archived = try RecordingRepository.fingerprint(of: reopened.preservedOriginalURL(for: segment.id))
            XCTAssertEqual(archived.sha256, originalFingerprint.sha256)
            XCTAssertEqual(archived.byteCount, originalFingerprint.byteCount)
            XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.stagingURL(for: segment.id).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.openSegmentURL(for: segment.id).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))

            let restartedAgain = try RecordingRepository(root: repository.root)
            try restartedAgain.completeAudioSegment(segment)
            XCTAssertEqual(try restartedAgain.manifests(), [manifest])
            XCTAssertEqual(try restartedAgain.pendingSegments(), [manifest])
            XCTAssertTrue(try restartedAgain.openAudioSegments().segments.isEmpty)
            XCTAssertEqual(try Data(contentsOf: restartedAgain.preservedOriginalURL(for: segment.id)), originalBytes)
        }
    }

    func testAcknowledgedTailWithLateJournalNeverResurrectsPrunedAudio() throws {
        let repository = try repository()
        let segment = segment()
        let candidate = try prepareCandidate(for: segment, in: repository)
        let manifest = try repository.commitRecoveredAudioSegment(segment, candidateURL: candidate, frameCount: 16_000)
        try repository.acknowledge(SegmentReceipt(segmentID: manifest.id,
            sha256: manifest.sha256, byteCount: manifest.byteCount))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.audioURL(for: manifest).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.openSegmentURL(for: segment.id).path))

        let reopened = try self.repository()
        XCTAssertEqual(try reopened.committedAudioSegment(for: segment), manifest)
        try reopened.completeAudioSegment(segment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.audioURL(for: manifest).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.openSegmentURL(for: segment.id).path))
        XCTAssertEqual(try Data(contentsOf: reopened.preservedOriginalURL(for: segment.id)), originalBytes)
        XCTAssertTrue(try reopened.pendingSegments().isEmpty)
        try reopened.completeAudioSegment(segment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.audioURL(for: manifest).path))
    }

    func testIdenticalRecoveryBytesStillArchiveOriginalAfterEitherCommitCrash() throws {
        let boundaries: [(String, RepositoryFaultPoint)] = [
            ("identical-after-audio", .afterAudioCommit), ("identical-after-manifest", .afterManifestCommit)
        ]
        for (name, boundary) in boundaries {
            let repository = try repository(name, fault: { point in
                switch (point, boundary) {
                case (.afterAudioCommit, .afterAudioCommit), (.afterManifestCommit, .afterManifestCommit):
                    throw SimulatedCrash()
                default: break
                }
            })
            let segment = segment()
            let candidate = try prepareCandidate(for: segment, in: repository)
            try originalBytes.write(to: candidate)
            let originalFingerprint = try RecordingRepository.fingerprint(of: repository.stagingURL(for: segment.id))
            XCTAssertThrowsError(try repository.commitRecoveredAudioSegment(segment, candidateURL: candidate, frameCount: 16_000))

            let reopened = try RecordingRepository(root: repository.root, recoveryFailureHandling: .preserveAndReport)
            let manifest = try XCTUnwrap(reopened.committedAudioSegment(for: segment))
            try assertSourceAndJournalPreserved(segment, in: reopened)
            XCTAssertEqual(try Data(contentsOf: reopened.audioURL(for: manifest)), originalBytes)
            try reopened.completeAudioSegment(segment)
            let archived = try RecordingRepository.fingerprint(of: reopened.preservedOriginalURL(for: segment.id))
            XCTAssertEqual(archived.sha256, originalFingerprint.sha256)
            XCTAssertEqual(archived.byteCount, originalFingerprint.byteCount)
            XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.stagingURL(for: segment.id).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.openSegmentURL(for: segment.id).path))
            let restartedAgain = try RecordingRepository(root: repository.root)
            try restartedAgain.completeAudioSegment(segment)
            XCTAssertEqual(try Data(contentsOf: restartedAgain.preservedOriginalURL(for: segment.id)), originalBytes)
            XCTAssertEqual(try restartedAgain.manifests(), [manifest])
        }
    }

    func testPendingRecoveryPrefersCandidateWhenOriginalHasIdenticalBytes() throws {
        let repository = try repository()
        let segment = segment()
        let candidate = try prepareCandidate(for: segment, in: repository)
        try originalBytes.write(to: candidate)
        let fingerprint = try RecordingRepository.fingerprint(of: candidate)
        let manifest = SegmentManifest(id: segment.id, sessionID: segment.sessionID, sequence: segment.sequence,
            startedAt: segment.startedAt, endedAt: segment.startedAt.addingTimeInterval(1),
            sampleRate: segment.sampleRate, frameCount: 16_000,
            fileName: segment.id.uuidString.lowercased() + ".caf",
            byteCount: fingerprint.byteCount, sha256: fingerprint.sha256, timeZoneIdentifier: segment.timeZoneIdentifier)
        // Simulate termination after the pending manifest, before either file was moved.
        try TransportCodec.encode(manifest).write(to: pendingURL(for: segment, in: repository))

        let reopened = try RecordingRepository(root: repository.root, recoveryFailureHandling: .preserveAndReport)
        try assertSourceAndJournalPreserved(segment, in: reopened)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertEqual(try Data(contentsOf: reopened.audioURL(for: manifest)), originalBytes)
        try reopened.completeAudioSegment(segment)
        let archived = try RecordingRepository.fingerprint(of: reopened.preservedOriginalURL(for: segment.id))
        XCTAssertEqual(archived.sha256, fingerprint.sha256)
        XCTAssertEqual(archived.byteCount, fingerprint.byteCount)
    }

    func testOrdinarySealPendingStillMovesItsOnlyStagingSourceWithOpenJournal() throws {
        let repository = try repository()
        let segment = segment()
        try repository.beginAudioSegment(segment)
        try originalBytes.write(to: repository.stagingURL(for: segment.id))
        let fingerprint = try RecordingRepository.fingerprint(of: repository.stagingURL(for: segment.id))
        let manifest = SegmentManifest(id: segment.id, sessionID: segment.sessionID, sequence: segment.sequence,
            startedAt: segment.startedAt, endedAt: segment.startedAt.addingTimeInterval(1),
            sampleRate: segment.sampleRate, frameCount: 16_000,
            fileName: segment.id.uuidString.lowercased() + ".caf",
            byteCount: fingerprint.byteCount, sha256: fingerprint.sha256, timeZoneIdentifier: segment.timeZoneIdentifier)
        try TransportCodec.encode(manifest).write(to: pendingURL(for: segment, in: repository))

        let reopened = try RecordingRepository(root: repository.root, recoveryFailureHandling: .preserveAndReport)
        XCTAssertEqual(try reopened.committedAudioSegment(for: segment), manifest)
        XCTAssertEqual(try Data(contentsOf: reopened.audioURL(for: manifest)), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.stagingURL(for: segment.id).path))
        try reopened.completeAudioSegment(segment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.openSegmentURL(for: segment.id).path))
        XCTAssertEqual(try reopened.manifests(), [manifest])
    }

    func testConflictingJournalIdentityPreventsAnySourceCleanup() throws {
        let repository = try repository()
        let segment = segment()
        let candidate = try prepareCandidate(for: segment, in: repository)
        _ = try repository.commitRecoveredAudioSegment(segment, candidateURL: candidate, frameCount: 16_000)
        let conflicting = self.segment(id: segment.id, sessionID: UUID())
        let changedJournal = try TransportCodec.encode(conflicting)
        try changedJournal.write(to: repository.openSegmentURL(for: segment.id))

        XCTAssertThrowsError(try repository.completeAudioSegment(segment)) {
            XCTAssertEqual($0 as? RepositoryError, .conflictingSegment)
        }
        try assertSourceAndJournalPreserved(segment, in: repository)
        XCTAssertEqual(try Data(contentsOf: repository.openSegmentURL(for: segment.id)), changedJournal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.preservedOriginalURL(for: segment.id).path))
    }

    func testConflictingCommittedIdentityPreventsAnySourceCleanup() throws {
        let repository = try repository()
        let segment = segment()
        let candidate = try prepareCandidate(for: segment, in: repository)
        let manifest = try repository.commitRecoveredAudioSegment(segment, candidateURL: candidate, frameCount: 16_000)
        let conflicting = SegmentManifest(id: manifest.id, sessionID: UUID(), sequence: manifest.sequence,
            startedAt: manifest.startedAt, endedAt: manifest.endedAt, sampleRate: manifest.sampleRate,
            frameCount: manifest.frameCount, fileName: manifest.fileName,
            byteCount: manifest.byteCount, sha256: manifest.sha256, timeZoneIdentifier: manifest.timeZoneIdentifier)
        try TransportCodec.encode(conflicting).write(to: manifestURL(for: segment, in: repository))

        XCTAssertThrowsError(try repository.completeAudioSegment(segment)) {
            XCTAssertEqual($0 as? RepositoryError, .conflictingSegment)
        }
        try assertSourceAndJournalPreserved(segment, in: repository)
        XCTAssertEqual(try Data(contentsOf: repository.audioURL(for: manifest)), candidateBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.preservedOriginalURL(for: segment.id).path))
    }

    func testDifferentExistingArchivePreservesBothCopiesAndJournal() throws {
        let repository = try repository()
        let segment = segment()
        let candidate = try prepareCandidate(for: segment, in: repository)
        _ = try repository.commitRecoveredAudioSegment(segment, candidateURL: candidate, frameCount: 16_000)
        let otherArchive = Data(repeating: 91, count: 128)
        try write(otherArchive, to: repository.preservedOriginalURL(for: segment.id))

        XCTAssertThrowsError(try repository.completeAudioSegment(segment)) {
            XCTAssertEqual($0 as? RepositoryError, .conflictingSegment)
        }
        try assertSourceAndJournalPreserved(segment, in: repository)
        XCTAssertEqual(try Data(contentsOf: repository.preservedOriginalURL(for: segment.id)), otherArchive)
    }

    func testZeroNegativeAndOverlongRecoveredFramesCannotCommitOrRemoveSources() throws {
        let repository = try repository()
        let segment = segment()
        let candidate = try prepareCandidate(for: segment, in: repository)
        for frames: Int64 in [0, -1, 960_001] {
            XCTAssertThrowsError(try repository.commitRecoveredAudioSegment(segment, candidateURL: candidate, frameCount: frames))
            try assertSourceAndJournalPreserved(segment, in: repository)
            XCTAssertEqual(try Data(contentsOf: candidate), candidateBytes)
            XCTAssertTrue(try repository.manifests().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL(for: segment, in: repository).path))
        }
    }

    func testJustCommittedCleanupRequiresExactStoredManifestAndPreservesAudio() throws {
        let repository = try repository()
        let segment = segment()
        try repository.beginAudioSegment(segment)
        try originalBytes.write(to: repository.stagingURL(for: segment.id))
        let manifest = try repository.sealSegment(stagedURL: repository.stagingURL(for: segment.id),
            id: segment.id, sessionID: segment.sessionID, sequence: segment.sequence,
            startedAt: segment.startedAt, endedAt: segment.startedAt.addingTimeInterval(1),
            sampleRate: segment.sampleRate, frameCount: 16_000, timeZoneIdentifier: segment.timeZoneIdentifier)
        let wrong = SegmentManifest(id: manifest.id, sessionID: manifest.sessionID, sequence: manifest.sequence,
            startedAt: manifest.startedAt, endedAt: manifest.endedAt, sampleRate: manifest.sampleRate,
            frameCount: manifest.frameCount, fileName: manifest.fileName,
            byteCount: manifest.byteCount + 1, sha256: manifest.sha256, timeZoneIdentifier: manifest.timeZoneIdentifier)
        XCTAssertThrowsError(try repository.completeAudioSegment(segment, justCommitted: wrong)) {
            XCTAssertEqual($0 as? RepositoryError, .conflictingSegment)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.openSegmentURL(for: segment.id).path))
        try repository.completeAudioSegment(segment, justCommitted: manifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.openSegmentURL(for: segment.id).path))
        XCTAssertEqual(try Data(contentsOf: repository.audioURL(for: manifest)), originalBytes)
        XCTAssertEqual(try repository.pendingSegments(), [manifest])
    }
}
