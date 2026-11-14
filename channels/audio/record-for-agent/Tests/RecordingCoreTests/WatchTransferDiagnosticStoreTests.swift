import XCTest
@testable import RecordingCore

final class WatchTransferDiagnosticStoreTests: XCTestCase {
    func testCapacityRetainsRecentlyUpdatedWaitingState() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_000)
        let store = WatchTransferDiagnosticStore(root: root, clock: { now })
        for generation in 1...256 {
            store.record(refusal(.nativeOccupied, at: Int64(generation), generation: UInt64(generation)))
        }
        now.addTimeInterval(60)
        store.record(refusal(.nativeOccupied, at: 200_000, generation: 1))
        store.record(refusal(.noOwner, at: 200_001, generation: 257))
        let values = store.events(limit: 256).compactMap { WatchTransferDiagnostic.parse($0)?.refusal }
        XCTAssertEqual(values.count, 256)
        XCTAssertTrue(values.contains { $0.generation == 1 && $0.lastObservedAtMS == 200_000 })
        XCTAssertFalse(values.contains { $0.generation == 2 })
    }
    func testSmallReplayBatchIncludesLatestObservationAndCoalescedUpdate() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_000)
        let store = WatchTransferDiagnosticStore(root: root, clock: { now })
        for generation in 1...40 {
            store.record(refusal(.nativeOccupied, at: 1_000 + Int64(generation), generation: UInt64(generation)))
        }
        let completed = RecordingEvent(kind: "watch.transfer_opportunity", detail:
            WatchTransferOpportunityDiagnostic(phase: .expired, generation: 41,
                observedAtMS: 150_000, foreground: false, liveCapture: false).detail()!)
        store.record(completed)
        now.addTimeInterval(60)
        store.record(refusal(.nativeOccupied, at: 200_000, generation: 1))
        let batch = store.events(limit: 2)
        XCTAssertEqual(batch.count, 2)
        XCTAssertTrue(batch.contains { WatchTransferDiagnostic.parse($0)?.refusal?.lastObservedAtMS == 200_000 })
        XCTAssertTrue(batch.contains { $0.id == completed.id })
        let allIDs = Set(store.events(limit: 256).map(\.id))
        let remaining = store.events(excluding: Set(batch.map(\.id)), limit: 256)
        XCTAssertEqual(Set(remaining.map(\.id)).union(batch.map(\.id)), allIDs)
        let restored = WatchTransferDiagnosticStore(root: root)
        XCTAssertEqual(restored.events(limit: 2).map(\.id), batch.map(\.id))
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func refusal(_ reason: WatchTransferRefusalDiagnostic.Reason, at: Int64, generation: UInt64 = 1) -> RecordingEvent {
        let value = WatchTransferRefusalDiagnostic(reason: reason, observedAtMS: at, generation: generation,
            foreground: false, liveCapture: true, nativeCount: 12)
        return RecordingEvent(kind: "watch.transfer_refusal", detail: value.detail()!, timestamp: Date(timeIntervalSince1970: Double(at) / 1_000))
    }
    private func progress(_ id: UUID, completed: Int64 = 0, at: Int64 = 1_000) -> RecordingEvent {
        let value = WatchTransferAttemptDiagnostic(phase: .progress, segmentID: id, attemptID: id,
            sourceCategory: .normal, protection: .untilFirstAuth, observedAtMS: at,
            enqueuedAtMS: 999, generation: 1, foreground: false, liveCapture: true,
            completed: completed, total: 100, outcome: .observed)
        return RecordingEvent(kind: "watch.transfer_attempt", detail: value.detail()!)
    }
    func testLongUnchangedQueueCoalescesAlternatingRefusalsAndNativeProgress() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_000)
        let store = WatchTransferDiagnosticStore(root: root, clock: { now })
        let attempts = (0..<12).map { _ in UUID() }
        for id in attempts { store.record(progress(id)) }
        for round in 0..<3_600 {
            now = Date(timeIntervalSince1970: 1_000 + Double(round * 10))
            let ms = Int64(now.timeIntervalSince1970 * 1_000)
            store.record(refusal(.noAdmission, at: ms))
            store.record(refusal(.nativeOccupied, at: ms))
            for id in attempts { store.record(progress(id, at: ms)) }
        }
        now.addTimeInterval(60)
        // A real unchanged progress observation flushes pending counts once.
        store.record(progress(attempts[0], at: Int64(now.timeIntervalSince1970 * 1_000)))
        let refusals = store.events(limit: 256).compactMap { WatchTransferDiagnostic.parse($0)?.refusal }
        XCTAssertEqual(refusals.count, 2)
        XCTAssertTrue(refusals.allSatisfy { $0.observationCount == 3_600 })
        XCTAssertTrue(refusals.allSatisfy { $0.observedAtMS == 1_000_000 && $0.lastObservedAtMS == 36_990_000 })
        XCTAssertEqual(store.statistics.eventCount, 14)
        XCTAssertLessThanOrEqual(store.statistics.writeCount, 614)
        XCTAssertLessThan(store.statistics.persistedBytes, WatchTransferDiagnosticStore.maximumBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("ConnectivityDiagnostics").path), ["watch-transfer-v1.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("events").path))
    }

    func testPublishedRevisionsRemainImmutableAndPendingCountsAreNotForwarded() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_000)
        let store = WatchTransferDiagnosticStore(root: root, clock: { now })
        store.record(refusal(.nativeOccupied, at: 1_000_000))
        let first = try XCTUnwrap(store.events().first)
        now.addTimeInterval(10)
        store.record(refusal(.nativeOccupied, at: 1_010_000))
        XCTAssertEqual(store.events(), [first])
        XCTAssertTrue(store.events(excluding: [first.id]).isEmpty)
        now.addTimeInterval(50)
        store.record(refusal(.nativeOccupied, at: 1_060_000))
        let next = try XCTUnwrap(store.events(excluding: [first.id]).first)
        XCTAssertNotEqual(next.id, first.id)
        XCTAssertEqual(WatchTransferDiagnostic.parse(next)?.refusal?.observationCount, 3)
        XCTAssertEqual(store.statistics.writeCount, 2)
    }

    func testProgressSnapshotChangesAreBoundedAndUnchangedRestartDoesNotWrite() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_000)
        let id = UUID(), store = WatchTransferDiagnosticStore(root: root, clock: { now })
        store.record(progress(id))
        for tick in 1...100 {
            now.addTimeInterval(1)
            store.record(progress(id, completed: Int64(tick), at: 1_000 + Int64(tick)))
        }
        now.addTimeInterval(60)
        store.record(progress(id, completed: 100, at: 1_101))
        XCTAssertEqual(store.statistics.eventCount, 1)
        XCTAssertEqual(WatchTransferDiagnostic.parse(try XCTUnwrap(store.events().first))?.attempt?.completed, 100)
        XCTAssertEqual(store.statistics.writeCount, 3)
        let restored = WatchTransferDiagnosticStore(root: root, clock: { now })
        for _ in 0..<3_600 { now.addTimeInterval(10); restored.record(progress(id, completed: 100)) }
        XCTAssertEqual(restored.statistics.writeCount, 0)
        XCTAssertEqual(restored.statistics.readCount, 1)
    }

    func testBoundedChurnAndRestartReplayNeverRescansJournalOrSnapshot() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let prior = journal.appendingPathComponent("prior.json")
        try Data("preserved unrelated evidence".utf8).write(to: prior)
        let store = WatchTransferDiagnosticStore(root: root)
        for generation in 1...1_000 { store.record(refusal(.noOwner, at: Int64(generation), generation: UInt64(generation))) }
        XCTAssertEqual(store.statistics.eventCount, 256)
        XCTAssertLessThanOrEqual(store.statistics.persistedBytes, 256 * 1_024)
        let restored = WatchTransferDiagnosticStore(root: root)
        var sent = Set<UUID>(), batches = 0
        while true {
            let batch = restored.events(excluding: sent, limit: 30)
            if batch.isEmpty { break }
            batches += 1; sent.formUnion(batch.map(\.id))
        }
        XCTAssertEqual(sent.count, 256)
        XCTAssertEqual(batches, 9)
        for _ in 0..<1_000 { XCTAssertTrue(restored.events(excluding: sent).isEmpty) }
        XCTAssertEqual(restored.statistics.readCount, 1)
        XCTAssertEqual(restored.statistics.writeCount, 0)
        XCTAssertEqual(try Data(contentsOf: prior), Data("preserved unrelated evidence".utf8))
        XCTAssertTrue(restored.events(limit: -1).isEmpty)
        XCTAssertEqual(restored.events(limit: Int.max).count, 256)
    }

    func testInvalidMetadataWriteFailureAndUnsupportedSnapshotPreserveEvidence() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocked = root.appendingPathComponent("blocked")
        try Data("user evidence".utf8).write(to: blocked)
        let failed = WatchTransferDiagnosticStore(root: blocked)
        failed.record(refusal(.noOwner, at: 1))
        XCTAssertTrue(failed.events().isEmpty)
        XCTAssertEqual(failed.statistics.writeCount, 0)
        XCTAssertEqual(try Data(contentsOf: blocked), Data("user evidence".utf8))
        let store = WatchTransferDiagnosticStore(root: root)
        store.record(RecordingEvent(kind: "watch.transfer_refusal", detail: "{\"reason\":\"no_owner\",\"observedAtMS\":1,\"path\":\"private\"}"))
        store.record(RecordingEvent(kind: "recording.user", detail: "private"))
        XCTAssertEqual(store.statistics.eventCount, 0)
        XCTAssertEqual(store.statistics.writeCount, 0)
        let directory = root.appendingPathComponent("ConnectivityDiagnostics")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("watch-transfer-v1.json")
        for payload in [Data("{\"version\":2,\"events\":[]}".utf8), Data(repeating: 1, count: 256 * 1_024 + 1), Data("broken".utf8)] {
            try payload.write(to: file)
            let restored = WatchTransferDiagnosticStore(root: root)
            restored.record(refusal(.nativeOccupied, at: 1))
            XCTAssertTrue(restored.events().isEmpty)
            XCTAssertEqual(restored.statistics.writeCount, 0)
            XCTAssertEqual(try Data(contentsOf: file), payload)
        }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: blocked)
        let symlink = WatchTransferDiagnosticStore(root: root)
        symlink.record(refusal(.nativeOccupied, at: 1))
        XCTAssertTrue(symlink.events().isEmpty)
        XCTAssertEqual(try Data(contentsOf: blocked), Data("user evidence".utf8))
    }
}
