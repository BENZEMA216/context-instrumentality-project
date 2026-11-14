import XCTest
@testable import RecordingCore

final class TransferCandidateIndexTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func seal(_ repo: RecordingRepository, sequence: Int) throws -> SegmentManifest {
        let id = UUID(), date = Date(timeIntervalSince1970: Double(1_700_000_000 + sequence * 60))
        try Data(repeating: 1, count: 64).write(to: repo.stagingURL(for: id))
        return try repo.sealSegment(stagedURL: repo.stagingURL(for: id), id: id, sessionID: UUID(),
            sequence: sequence, startedAt: date, endedAt: date.addingTimeInterval(60),
            sampleRate: 16_000, frameCount: 960_000)
    }

    func testBoundedTailAndPersistedHistoryCursorSurviveRestart() throws {
        let repo = try RecordingRepository(root: root)
        let values = try (0..<20).map { try seal(repo, sequence: $0) }
        try repo.refreshTransferCandidates()
        let first = try repo.transferCandidateBatch()
        XCTAssertEqual(first.ids, [values[19].id, values[18].id] + values.prefix(6).map(\.id))
        XCTAssertNil(first.bootstrapCount)
        let restarted = try RecordingRepository(root: root, recoverTransactionsOnInitialization: false)
        let next = try restarted.transferCandidateBatch()
        XCTAssertEqual(next.ids, [values[19].id, values[18].id] + values[6..<12].map(\.id))
        let latest = try seal(restarted, sequence: 20)
        XCTAssertEqual(try restarted.transferCandidateBatch().ids.first, latest.id)
        XCTAssertEqual(try restarted.transferCandidateBatch(limit: 100).ids.count, 21)
    }

    func testExpandedCandidatePageClampsToSixtyFourAndDefaultStaysEight() throws {
        let repo = try RecordingRepository(root: root)
        let values = try (0..<80).map { try seal(repo, sequence: $0) }
        try repo.refreshTransferCandidates()
        let defaultPage = try repo.transferCandidateBatch()
        XCTAssertEqual(defaultPage.ids.count, 8)
        XCTAssertEqual(Array(defaultPage.ids.prefix(2)), values.suffix(2).reversed().map(\.id))
        let expanded = try repo.transferCandidateBatch(limit: 1_000)
        XCTAssertEqual(expanded.ids.count, 64)
        XCTAssertEqual(Set(expanded.ids).count, 64)
        XCTAssertEqual(expanded.recordCount, 80)
        XCTAssertEqual(Array(expanded.ids.prefix(2)), values.suffix(2).reversed().map(\.id))
        // A caller-requested smaller battery page still controls each read.
        XCTAssertEqual(try repo.transferCandidateBatch(limit: 3).ids.count, 3)
    }

    func testUnreadableMarkerPreservesIndexAndHistoricalCursorUntilNextOpportunity() throws {
        let repo = try RecordingRepository(root: root)
        let values = try (0..<20).map { try seal(repo, sequence: $0) }
        try repo.refreshTransferCandidates()
        _ = try repo.transferCandidateBatch()
        let index = root.appendingPathComponent("transfer-candidates.ids")
        let cursor = root.appendingPathComponent("transfer-candidates.cursor")
        let marker = root.appendingPathComponent("transfer-candidates.ready")
        let before = try [index, cursor, marker].map { try Data(contentsOf: $0) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: marker.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path) }
        XCTAssertThrowsError(try repo.transferCandidateBatch())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        XCTAssertEqual(try [index, cursor, marker].map { try Data(contentsOf: $0) }, before)
        let resumed = try repo.transferCandidateBatch()
        XCTAssertNil(resumed.bootstrapCount)
        XCTAssertEqual(resumed.ids, [values[19].id, values[18].id] + values[6..<12].map(\.id))
    }

    func testUnreadableCursorCannotBeResetEvenWhenMarkerNeedsRebuild() throws {
        let repo = try RecordingRepository(root: root)
        _ = try (0..<12).map { try seal(repo, sequence: $0) }
        try repo.refreshTransferCandidates()
        _ = try repo.transferCandidateBatch()
        let index = root.appendingPathComponent("transfer-candidates.ids")
        let cursor = root.appendingPathComponent("transfer-candidates.cursor")
        let marker = root.appendingPathComponent("transfer-candidates.ready")
        try Data("malformed marker".utf8).write(to: marker)
        let before = try [index, cursor, marker].map { try Data(contentsOf: $0) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cursor.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cursor.path) }
        XCTAssertThrowsError(try repo.transferCandidateBatch())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cursor.path)
        XCTAssertEqual(try [index, cursor, marker].map { try Data(contentsOf: $0) }, before)
        XCTAssertEqual(try repo.transferCandidateBatch().bootstrapCount, 12)
    }

    func testUnreadableIndexCannotBeOverwrittenDuringHintRebuild() throws {
        let repo = try RecordingRepository(root: root)
        _ = try (0..<12).map { try seal(repo, sequence: $0) }
        try repo.refreshTransferCandidates()
        let index = root.appendingPathComponent("transfer-candidates.ids")
        let cursor = root.appendingPathComponent("transfer-candidates.cursor")
        let marker = root.appendingPathComponent("transfer-candidates.ready")
        try Data("malformed marker".utf8).write(to: marker)
        let before = try [index, cursor, marker].map { try Data(contentsOf: $0) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: index.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path) }
        XCTAssertThrowsError(try repo.transferCandidateBatch())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        XCTAssertEqual(try [index, cursor, marker].map { try Data(contentsOf: $0) }, before)
    }

    func testFilenameBootstrapPreservesFreshTailWithoutDecodingCorruptHistory() throws {
        let repo = try RecordingRepository(root: root)
        for _ in 0..<50 {
            try Data("broken".utf8).write(to: root.appendingPathComponent("manifests/" + UUID().uuidString.lowercased() + ".json"))
        }
        let latest = try seal(repo, sequence: 1)
        let batch = try repo.transferCandidateBatch()
        XCTAssertEqual(batch.bootstrapCount, 51)
        XCTAssertEqual(batch.ids.first, latest.id)
        XCTAssertEqual(batch.ids.count, 8)
        XCTAssertEqual(try repo.pendingSegment(id: latest.id), latest)
        XCTAssertThrowsError(try repo.manifests())
    }

    func testTornCandidateHintRebuildsFromManifestsAndIsNeverAcknowledgementProof() throws {
        let repo = try RecordingRepository(root: root)
        let value = try seal(repo, sequence: 1)
        try repo.refreshTransferCandidates()
        try Data("torn".utf8).write(to: root.appendingPathComponent("transfer-candidates.ids"))
        let batch = try repo.transferCandidateBatch()
        XCTAssertEqual(batch.bootstrapCount, 1)
        XCTAssertEqual(batch.ids, [value.id])
        XCTAssertFalse(try repo.hasDurableAcknowledgement(for: value))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.audioURL(for: value).path))
        try FileManager.default.removeItem(at: repo.audioURL(for: value))
        XCTAssertThrowsError(try repo.pendingSegment(id: value.id))
        XCTAssertFalse(try repo.hasDurableAcknowledgement(for: value))
    }

    func testHeadlessRepositoryInitializationDefersTransactionRecovery() throws {
        let repo = try RecordingRepository(root: root)
        let pending = root.appendingPathComponent("staging/" + UUID().uuidString.lowercased() + ".pending.json")
        try Data("damaged transaction".utf8).write(to: pending)
        let reopened = try RecordingRepository(root: root, recoverTransactionsOnInitialization: false)
        // macOS can spell the same temporary root as /tmp or /private/tmp.
        // Deferred recovery must retain the directory, independent of that alias.
        XCTAssertEqual(reopened.root.resolvingSymlinksInPath().path, repo.root.resolvingSymlinksInPath().path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertThrowsError(try reopened.recoverPendingTransactions())
        XCTAssertThrowsError(try RecordingRepository(root: root))
    }
    func testMissingIndexWithSurvivingMarkerRetainsOldHistoryAfterNewSeal() throws {
        let repo = try RecordingRepository(root: root)
        let old = try (0..<15).map { try seal(repo, sequence: $0) }
        try repo.refreshTransferCandidates()
        try FileManager.default.removeItem(at: root.appendingPathComponent("transfer-candidates.ids"))
        let latest = try seal(repo, sequence: 15)
        let first = try repo.transferCandidateBatch()
        XCTAssertEqual(first.bootstrapCount, 16)
        XCTAssertEqual(first.ids.first, latest.id)
        var observed = Set(first.ids)
        for _ in 0..<4 { observed.formUnion(try repo.transferCandidateBatch().ids) }
        XCTAssertTrue(Set(old.map(\.id)).isSubset(of: observed))
    }

    func testBackgroundCandidateChecksSizeWithoutHashingSource() throws {
        let repo = try RecordingRepository(root: root)
        let value = try seal(repo, sequence: 1)
        try Data(repeating: 2, count: 64).write(to: repo.audioURL(for: value))
        // Same-size bytes are not hashed by candidate selection; receipt intake
        // still validates its exact original manifest and durable receipt.
        XCTAssertEqual(try repo.pendingSegment(id: value.id), value)
        try Data(repeating: 2, count: 63).write(to: repo.audioURL(for: value))
        XCTAssertThrowsError(try repo.pendingSegment(id: value.id)) {
            XCTAssertEqual($0 as? RepositoryError, .checksumMismatch)
        }
        XCTAssertFalse(try repo.hasDurableAcknowledgement(for: value))
    }

    func testRevokedMaintenanceDoesNotReplaceCompleteIndexOrDecodeEvents() throws {
        let repo = try RecordingRepository(root: root)
        _ = try (0..<4).map { try seal(repo, sequence: $0) }
        try repo.refreshTransferCandidates()
        let before = try Data(contentsOf: root.appendingPathComponent("transfer-candidates.ids"))
        var checks = 0
        XCTAssertNil(try repo.refreshTransferCandidates(while: { checks += 1; return checks < 3 }))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("transfer-candidates.ids")), before)
        try Data("bad event".utf8).write(to: root.appendingPathComponent("events/" + UUID().uuidString + ".json"))
        XCTAssertTrue(try repo.events(while: { false }).isEmpty)
    }

    func testAlignedTruncationAfterAppendInvalidatesBaselineLength() throws {
        let repo = try RecordingRepository(root: root)
        let original = try (0..<4).map { try seal(repo, sequence: $0) }
        try repo.refreshTransferCandidates()
        let latest = try seal(repo, sequence: 4)
        let url = root.appendingPathComponent("transfer-candidates.ids")
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 37 * 4)
        try handle.close()
        let repaired = try repo.transferCandidateBatch()
        XCTAssertEqual(repaired.bootstrapCount, 5)
        XCTAssertEqual(Set(repaired.ids), Set(original.map(\.id) + [latest.id]))
        try Data().write(to: url)
        XCTAssertEqual(try repo.transferCandidateBatch().bootstrapCount, 5)
    }

    func testNewSealCannotHidePriorAlignedIndexTruncation() throws {
        let repo = try RecordingRepository(root: root)
        let original = try (0..<15).map { try seal(repo, sequence: $0) }
        try repo.refreshTransferCandidates()
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("transfer-candidates.ids"))
        try handle.truncate(atOffset: 37)
        try handle.close()
        let latest = try seal(repo, sequence: 15)
        let first = try repo.transferCandidateBatch()
        XCTAssertEqual(first.bootstrapCount, 16)
        XCTAssertEqual(first.ids.first, latest.id)
        var seen = Set(first.ids)
        for _ in 0..<4 { seen.formUnion(try repo.transferCandidateBatch().ids) }
        XCTAssertEqual(seen, Set(original.map(\.id) + [latest.id]))
    }

    func testMissingTailHintIsRemovedAndRepeatedBootstrapDoesNotTrapHistoryCursor() throws {
        let repo = try RecordingRepository(root: root)
        let manifests = try (0..<20).map { try seal(repo, sequence: $0) }
        try repo.refreshTransferCandidates()
        let hintURL = root.appendingPathComponent("transfer-candidates.ids")
        for _ in 0..<2 {
            let missingID = UUID()
            let handle = try FileHandle(forWritingTo: hintURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((missingID.uuidString.lowercased() + "\n").utf8))
            try handle.close()
            XCTAssertTrue(try repo.transferCandidateBatch().ids.contains(missingID))
            // Simulate exact-ID lookup failure invalidating the cache. Rebuild
            // must remove that tail, rather than cause an endless dirty cycle.
            try repo.invalidateTransferCandidates()
            let repaired = try repo.transferCandidateBatch()
            XCTAssertEqual(repaired.bootstrapCount, manifests.count)
            XCTAssertFalse(repaired.ids.contains(missingID))
            var seen = Set(repaired.ids)
            for _ in 0..<5 {
                let batch = try repo.transferCandidateBatch()
                XCTAssertNil(batch.bootstrapCount)
                seen.formUnion(batch.ids)
            }
            XCTAssertEqual(seen, Set(manifests.map(\.id)))
        }
    }

}
