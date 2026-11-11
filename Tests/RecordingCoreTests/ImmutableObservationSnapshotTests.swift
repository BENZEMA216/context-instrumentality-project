import Foundation
import Darwin
import XCTest
@testable import RecordingCore

/// All payloads are synthetic JSON metadata. No recording or device is opened.
final class ImmutableObservationSnapshotTests: XCTestCase {
    private final class Clock { var wall: Int64 = 2_000_000; var continuous: Int64 = 1_000_000 }
    private var root: URL!
    private var clock: Clock!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("immutable-observation-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        clock = Clock()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func publisher(process: UUID = UUID(), retention: ImmutableObservationSnapshotPublisher.Retention = .init(),
                           bootSessionID: String? = ImmutableObservationSnapshotPublisher.currentBootSessionID(),
                           freeBytes: @escaping (Int32) -> Int64? = { _ in Int64.max },
                           reserveBytes: @escaping () -> Int64 = { 64 * 1_024 * 1_024 },
                           inspectSnapshot: ((ImmutableObservationSnapshotPublisher) -> Void)? = nil,
                           writer: ((Data, String) throws -> Void)? = nil) -> VerifiedObservationPublisher {
        let clock = clock!, root = root!
        let snapshot = ImmutableObservationSnapshotPublisher(directory: root,
            reportKind: "phone_receipts", build: "87", processRunID: process, retention: retention,
            bootSessionID: bootSessionID, availableBytes: freeBytes, recordingReserveBytes: reserveBytes)
        inspectSnapshot?(snapshot)
        return VerifiedObservationPublisher(reportKind: "phone_receipts", build: "87", processRunID: process,
            minimumIntervalMS: 0, clock: { (clock.wall, clock.continuous) }, writer: writer ?? { bytes, name in
                try bytes.write(to: root.appendingPathComponent(name), options: .atomic)
            }, failureSink: { _ in }, snapshotPublisher: snapshot)
    }
    private func source(_ value: Int = 1) -> VerifiedObservationSource {
        let bytes = ["metadata-capture.json": Data("{\"sourceEventAtMS\":1000,\"value\":\(value)}".utf8),
                     "capture-status.json": Data("{\"available\":true}".utf8)]
        return .init(sourceGeneratedAtMS: 1_000, identity: ["generationID": "original-\(value)"],
                     files: bytes.keys.sorted().map { .init(name: $0, bytes: bytes[$0]!) }, snapshotFiles: bytes)
    }
    private func index() throws -> ImmutableObservationSnapshotPublisher.Index {
        try JSONDecoder().decode(ImmutableObservationSnapshotPublisher.Index.self,
            from: Data(contentsOf: root.appendingPathComponent("snapshot-index.json")))
    }
    private func generation(_ value: ImmutableObservationSnapshotPublisher.Index) throws -> URL {
        root.appendingPathComponent("SnapshotGenerations").appendingPathComponent(try XCTUnwrap(value.generationID))
    }
    private func manifest(_ value: ImmutableObservationSnapshotPublisher.Index) throws -> ImmutableObservationSnapshotPublisher.Manifest {
        let bytes = try Data(contentsOf: generation(value).appendingPathComponent("manifest.json"))
        XCTAssertEqual(bytes.count, value.manifestByteCount)
        XCTAssertEqual(VerifiedObservationPublisher.digest(bytes), value.manifestSHA256)
        return try JSONDecoder().decode(ImmutableObservationSnapshotPublisher.Manifest.self, from: bytes)
    }
    private func verifyPinned(_ value: ImmutableObservationSnapshotPublisher.Index) throws -> [String: Data] {
        let manifest = try manifest(value), folder = try generation(value)
        XCTAssertEqual(manifest.fenceID, value.fenceID)
        XCTAssertEqual(manifest.observerProcessRunID, value.observerProcessRunID)
        XCTAssertEqual(manifest.sequence, value.sequence)
        XCTAssertEqual(manifest.observedAtMS, value.observedAtMS)
        XCTAssertFalse(manifest.audioRead); XCTAssertFalse(manifest.includesAudio)
        var payloads: [String: Data] = [:]
        for file in manifest.files {
            let bytes = try Data(contentsOf: folder.appendingPathComponent(file.name))
            XCTAssertEqual(file.byteCount, bytes.count)
            XCTAssertEqual(file.sha256, VerifiedObservationPublisher.digest(bytes))
            payloads[file.name] = bytes
        }
        return payloads
    }
    private func advance(_ milliseconds: Int64 = 1000) { clock.wall += milliseconds; clock.continuous += milliseconds }

    func testPinnedGenerationSurvivesSuccessfulPublicationWithoutInventingSourceProgress() throws {
        let publisher = publisher()
        XCTAssertFalse(try index().available)
        XCTAssertEqual(try index().sequence, 0)
        XCTAssertTrue(publisher.observe { source() })
        let first = try index(), original = try verifyPinned(first)
        advance()
        XCTAssertTrue(publisher.observe(sourceDidChange: true) { source(2) })
        let second = try index()
        XCTAssertEqual(first.fenceID, second.fenceID)
        XCTAssertEqual(second.sequence, first.sequence + 1)
        XCTAssertNotEqual(first.generationID, second.generationID)
        XCTAssertEqual(try verifyPinned(first), original)
        XCTAssertEqual(try manifest(second).sourceGeneratedAtMS, 1000)
        XCTAssertEqual(try verifyPinned(second)["metadata-capture.json"], source(2).snapshotFiles?["metadata-capture.json"])
    }

    func testPendingAndFailureFenceCannotBeHiddenByLaterSuccessfulRecovery() throws {
        let publisher = publisher()
        XCTAssertTrue(publisher.observe { source() })
        let before = try index(), preserved = try verifyPinned(before)
        advance()
        XCTAssertFalse(publisher.observe(sourceDidChange: true) {
            let pending = try index()
            XCTAssertFalse(pending.available); XCTAssertNil(pending.generationID)
            XCTAssertEqual(pending.failureCode, "validation_pending")
            XCTAssertEqual(pending.fenceID, before.fenceID)
            throw VerifiedObservationPublisher.Failure.invalidSource
        })
        let failed = try index()
        XCTAssertFalse(failed.available); XCTAssertNotEqual(failed.fenceID, before.fenceID)
        advance()
        XCTAssertTrue(publisher.observe(sourceDidChange: true) { source() })
        XCTAssertEqual(try index().fenceID, failed.fenceID)
        XCTAssertEqual(try verifyPinned(before), preserved)
    }

    func testRestartImmediatelyInvalidatesOldProcessEvenWithoutObservation() throws {
        let first = publisher()
        XCTAssertTrue(first.observe { source() })
        let old = try index()
        let restartedProcess = UUID()
        let second = publisher(process: restartedProcess)
        let startup = try index()
        XCTAssertFalse(startup.available); XCTAssertEqual(startup.sequence, 0)
        XCTAssertEqual(startup.failureCode, "observer_startup")
        XCTAssertEqual(startup.observerProcessRunID, restartedProcess)
        XCTAssertNotEqual(old.fenceID, startup.fenceID)
        XCTAssertNoThrow(try verifyPinned(old))
        withExtendedLifetime(second) { }
    }

    func testInterruptedPendingAttemptNeverLeavesOldAvailableIndex() throws {
        let publisher = publisher()
        XCTAssertTrue(publisher.observe { source() })
        let old = try index()
        var interrupted: ImmutableObservationSnapshotPublisher? = .init(directory: root,
            reportKind: "phone_receipts", build: "87", processRunID: old.observerProcessRunID)
        try interrupted?.begin(sequence: old.sequence + 1, time: (clock.wall, clock.continuous))
        interrupted = nil // Models process termination after durable pending publication.
        XCTAssertFalse(try index().available)
        XCTAssertEqual(try index().failureCode, "validation_pending")
        XCTAssertNoThrow(try verifyPinned(old))
    }

    func testSourceWriteFailureInvalidatesSnapshotAndPreservesItsOriginalBytes() throws {
        let publisher = publisher()
        XCTAssertTrue(publisher.observe { source() })
        let old = try index(), bytes = try verifyPinned(old)
        advance(); publisher.invalidate()
        XCTAssertFalse(try index().available)
        XCTAssertEqual(try index().failureCode, "source_publication_failed")
        XCTAssertNotEqual(try index().fenceID, old.fenceID)
        XCTAssertEqual(try verifyPinned(old), bytes)
    }

    func testYoungGenerationsAreProtectedAtCapacityAndOldestIsReclaimedOnlyAfterBothClocks() throws {
        var policy = ImmutableObservationSnapshotPublisher.Retention()
        policy.recentCount = 1; policy.maximumCount = 2
        let publisher = publisher(retention: policy)
        XCTAssertTrue(publisher.observe { source() }); let first = try index()
        advance()
        XCTAssertTrue(publisher.observe { source(2) }); let second = try index()
        advance()
        XCTAssertFalse(publisher.observe { source(3) })
        XCTAssertFalse(try index().available)
        XCTAssertNoThrow(try verifyPinned(first)); XCTAssertNoThrow(try verifyPinned(second))
        advance(900_000)
        XCTAssertTrue(publisher.observe { source(3) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: try generation(first).path))
        XCTAssertNoThrow(try verifyPinned(second))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("SnapshotGenerations").path).count, 2)
    }

    func testRestartWithForwardWallJumpCannotGarbageCollectYoungContinuousTime() throws {
        var policy = ImmutableObservationSnapshotPublisher.Retention()
        policy.recentCount = 0; policy.maximumCount = 1
        let first = publisher(retention: policy)
        XCTAssertTrue(first.observe { source() }); let pinned = try index()
        clock.wall += 2_000_000; clock.continuous += 10
        let restarted = publisher(retention: policy)
        XCTAssertFalse(restarted.observe { source(2) })
        XCTAssertNoThrow(try verifyPinned(pinned))
        XCTAssertFalse(try index().available)
    }

    func testConcurrentWriterCannotInterleaveItsPendingFenceOrGeneration() throws {
        let first = publisher(), second = publisher()
        XCTAssertTrue(first.observe {
            let pending = try index()
            XCTAssertFalse(second.observe { source(99) })
            XCTAssertEqual(try index(), pending)
            return source()
        })
        let committed = try index()
        XCTAssertTrue(committed.available)
        XCTAssertEqual(try verifyPinned(committed)["metadata-capture.json"], source().snapshotFiles?["metadata-capture.json"])
    }

    func testUnsafePathsAndSymlinkGenerationCannotEscapeMetadataRoot() throws {
        let publisher = publisher()
        let bytes = Data("{}".utf8)
        XCTAssertFalse(publisher.observe {
            .init(sourceGeneratedAtMS: 1000, identity: ["id": "bad"],
                  files: [.init(name: "../outside.json", bytes: bytes)], snapshotFiles: ["../outside.json": bytes])
        })
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("private.json")
        try bytes.write(to: sentinel)
        let link = root.appendingPathComponent("SnapshotGenerations").appendingPathComponent(UUID().uuidString.lowercased())
        XCTAssertEqual(Darwin.symlink(outside.path, link.path), 0)
        advance()
        XCTAssertFalse(publisher.observe { source() })
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertFalse(try index().available)
    }

    func testMissingOrMismatchedExactSourceBytesAndClockJumpFailClosed() throws {
        let publisher = publisher()
        XCTAssertTrue(publisher.observe { source() }); let old = try index()
        advance()
        XCTAssertFalse(publisher.observe {
            .init(sourceGeneratedAtMS: 1000, identity: ["id": "missing"], files: source().files)
        })
        advance()
        XCTAssertFalse(publisher.observe {
            .init(sourceGeneratedAtMS: 1000, identity: ["id": "changed"], files: source().files,
                  snapshotFiles: source(2).snapshotFiles)
        })
        advance(); XCTAssertTrue(publisher.observe { source() })
        clock.wall += 100_000; clock.continuous += 1000
        XCTAssertFalse(publisher.observe { source() })
        XCTAssertEqual(try index().failureCode, "clock_discontinuity")
        XCTAssertNoThrow(try verifyPinned(old))
    }

    func testFailedGenerationsAreReclaimedBeforeCountLimitAndDoNotStrandCapacity() throws {
        var policy = ImmutableObservationSnapshotPublisher.Retention()
        policy.maximumCount = 2
        let publisher = publisher(retention: policy)
        let generations = root.appendingPathComponent("SnapshotGenerations")
        // More crash leftovers than the old maximumCount+1 pre-GC guard allowed.
        for i in 0..<1025 {
            let incomplete = generations.appendingPathComponent(UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try Data("{}".utf8).write(to: incomplete.appendingPathComponent(i % 2 == 0 ? "partial.json" : "manifest.json"))
        }
        XCTAssertTrue(publisher.observe { source() })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: generations.path).count, 1)
        XCTAssertNoThrow(try verifyPinned(index()))
    }

    func testRebootReclaimsEvenNewestGenerationDespiteResetMonotonicClock() throws {
        var policy = ImmutableObservationSnapshotPublisher.Retention()
        policy.maximumCount = 1
        let old = publisher(retention: policy, bootSessionID: "100.0")
        XCTAssertTrue(old.observe { source() }); let first = try index()
        clock.wall += 100; clock.continuous = 10
        let restarted = publisher(retention: policy, bootSessionID: "200.0")
        XCTAssertTrue(restarted.observe { source(2) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: try generation(first).path))
        XCTAssertEqual(try manifest(index()).bootSessionID, "200.0")
    }

    func testLegacyGenerationWithResetMonotonicClockDoesNotStrandCapacity() throws {
        var policy = ImmutableObservationSnapshotPublisher.Retention()
        policy.maximumCount = 1
        let old = publisher(retention: policy, bootSessionID: nil)
        XCTAssertTrue(old.observe { source() }); let first = try index()
        clock.wall += 100; clock.continuous = 10
        let restarted = publisher(retention: policy, bootSessionID: "200.0")
        XCTAssertTrue(restarted.observe { source(2) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: try generation(first).path))
    }

    func testOldCurrentGenerationGetsFullCollectionGraceWhenSuperseded() throws {
        var policy = ImmutableObservationSnapshotPublisher.Retention()
        policy.recentCount = 1
        let publisher = publisher(retention: policy)
        XCTAssertTrue(publisher.observe { source() }); let pinned = try index()
        advance(900_000) // A collector can pin this still-current old generation.
        XCTAssertTrue(publisher.observe { source(2) })
        advance(1_000)
        XCTAssertTrue(publisher.observe { source(3) })
        XCTAssertNoThrow(try verifyPinned(pinned))
        advance(478_999)
        XCTAssertTrue(publisher.observe { source(4) })
        XCTAssertNoThrow(try verifyPinned(pinned))
        advance(1)
        XCTAssertTrue(publisher.observe { source(5) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: try generation(pinned).path))
    }

    func testSuccessfulPublicationsDoNotRescanKnownGenerationFilesAndManifests() throws {
        var snapshot: ImmutableObservationSnapshotPublisher!
        let publisher = publisher(inspectSnapshot: { snapshot = $0 })
        for value in 0..<8 {
            XCTAssertTrue(publisher.observe { source(value) })
            advance()
        }
        XCTAssertEqual(snapshot.generationScanCount, 0)
        var recovered: ImmutableObservationSnapshotPublisher!
        let restarted = self.publisher(inspectSnapshot: { recovered = $0 })
        XCTAssertTrue(restarted.observe { source(9) })
        XCTAssertEqual(recovered.generationScanCount, 8)
        advance()
        XCTAssertTrue(restarted.observe { source(10) })
        XCTAssertEqual(recovered.generationScanCount, 8)
    }

    func testLowSpacePreservesRecordingReserveAndReportsFixedFailureThenRecovers() throws {
        var free: Int64 = 100 * 1_024 * 1_024
        let reserve: Int64 = 96 * 1_024 * 1_024 // Larger than the diagnostic floor.
        let publisher = publisher(freeBytes: { _ in free }, reserveBytes: { reserve })
        XCTAssertTrue(publisher.observe { source() }); let pinned = try index()
        free = reserve + 64 * 1_024 // Failure metadata fits, a new payload does not.
        advance()
        XCTAssertFalse(publisher.observe { source(2) })
        XCTAssertEqual(try index().failureCode, "snapshot_low_space")
        XCTAssertNotEqual(try index().fenceID, pinned.fenceID)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:
            root.appendingPathComponent("SnapshotGenerations").path).count, 1)
        XCTAssertNoThrow(try verifyPinned(pinned))
        free = 100 * 1_024 * 1_024; advance()
        XCTAssertTrue(publisher.observe { source(3) })
    }

    func testGroupPoliciesBoundLargeWatchBacklogSeparatelyFromSmallRuntimeReports() {
        let backlog = ImmutableObservationSnapshotPublisher.Retention.forReportKind("watch_backlog")
        let runtime = ImmutableObservationSnapshotPublisher.Retention.forReportKind("watch_runtime")
        XCTAssertEqual(backlog.recentCount, 4)
        XCTAssertEqual(backlog.minimumAgeMS, 480_000)
        XCTAssertEqual(backlog.maximumBytes, 128 * 1_024 * 1_024)
        XCTAssertLessThan(runtime.maximumBytes, backlog.maximumBytes)
        XCTAssertEqual(RecordingStorageBudget.minimumFreeBytes(sampleRate: 48_000, bytesPerFrame: 4, bufferCount: 2), 46_080_000)
        XCTAssertEqual(RecordingStorageBudget.minimumFreeBytes(sampleRate: 16_000, bytesPerFrame: 2, bufferCount: 1), 8 * 1_024 * 1_024)
    }

    func testLowSpaceCanRecoverByReclaimingStrandedGenerationBeforeRejectingPublication() throws {
        let generations = root.appendingPathComponent("SnapshotGenerations")
        let stranded = generations.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: stranded, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data("{}".utf8).write(to: stranded.appendingPathComponent("partial.json"))
        let reserve: Int64 = 64 * 1_024 * 1_024
        let publisher = publisher(freeBytes: { _ in
            FileManager.default.fileExists(atPath: stranded.path) ? reserve - 1 : reserve + 1_024 * 1_024
        })
        XCTAssertTrue(publisher.observe { source() })
        XCTAssertFalse(FileManager.default.fileExists(atPath: stranded.path))
        XCTAssertTrue(try index().available)
    }
}
