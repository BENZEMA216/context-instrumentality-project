import Darwin
import Foundation
import XCTest
@testable import RecordingCore

/// Synthetic metadata only. Never opens a device, a recording or a cloud account.
final class ImmutableObservationPacingTests: XCTestCase {
    private final class Clock {
        var wall: Int64 = 2_000_000
        var continuous: Int64 = 1_000_000
        func advance(_ amount: Int64) { wall += amount; continuous += amount }
    }
    private var root: URL!
    private var clock: Clock!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("immutable-pacing-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        clock = Clock()
    }
    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func publisher(build: String = "88", kind: String = "google_drive", process: UUID = UUID(),
                           directory: URL? = nil,
                           retention: ImmutableObservationSnapshotPublisher.Retention? = nil,
                           freeBytes: @escaping (Int32) -> Int64? = { _ in Int64.max },
                           inspectSnapshot: ((ImmutableObservationSnapshotPublisher) -> Void)? = nil,
                           writer: ((Data, String) throws -> Void)? = nil) -> VerifiedObservationPublisher {
        let directory = directory ?? root!, clock = clock!
        let snapshot = ImmutableObservationSnapshotPublisher(directory: directory, reportKind: kind,
            build: build, processRunID: process, retention: retention, availableBytes: freeBytes)
        inspectSnapshot?(snapshot)
        return VerifiedObservationPublisher(reportKind: kind, build: build, processRunID: process,
            clock: { (clock.wall, clock.continuous) }, writer: writer ?? { bytes, name in
                try bytes.write(to: directory.appendingPathComponent(name), options: .atomic)
            }, failureSink: { _ in }, snapshotPublisher: snapshot)
    }
    private func source(_ value: Int = 1, captureBytes: Int = 128) -> VerifiedObservationSource {
        let prefix = "{\"synthetic\":true,\"value\":\(value),\"padding\":\""
        let capture = Data((prefix + String(repeating: "x", count: captureBytes - prefix.utf8.count - 2) + "\"}").utf8)
        let files = ["metadata-capture.json": capture, "capture-status.json": Data("{\"available\":true}".utf8)]
        return .init(sourceGeneratedAtMS: 1_000, identity: ["generationID": "synthetic-\(value)"],
            files: files.keys.sorted().map { .init(name: $0, bytes: files[$0]!) }, snapshotFiles: files)
    }
    private func indexBytes(_ directory: URL? = nil) throws -> Data {
        try Data(contentsOf: (directory ?? root!).appendingPathComponent("snapshot-index.json"))
    }
    private func index(_ directory: URL? = nil) throws -> ImmutableObservationSnapshotPublisher.Index {
        try JSONDecoder().decode(ImmutableObservationSnapshotPublisher.Index.self, from: indexBytes(directory))
    }
    private func generation(_ value: ImmutableObservationSnapshotPublisher.Index, directory: URL? = nil) throws -> URL {
        (directory ?? root!).appendingPathComponent("SnapshotGenerations").appendingPathComponent(try XCTUnwrap(value.generationID))
    }
    private func liveReceipt() throws -> VerifiedObservationPublisher.Receipt {
        try JSONDecoder().decode(VerifiedObservationPublisher.Receipt.self,
            from: Data(contentsOf: root.appendingPathComponent(VerifiedObservationPublisher.fileName)))
    }

    func testBuild87HealthyThreeSecondBurstExhaustsQuotaButBuild88StaysBounded() throws {
        let legacyRoot = root.appendingPathComponent("legacy87")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let legacy = publisher(build: "87", directory: legacyRoot)
        // Same capture length as the incident, but every byte is generated here.
        for value in 1...55 {
            XCTAssertTrue(legacy.observe(sourceDidChange: true) { source(value, captureBytes: 1_204_971) })
            clock.advance(2_961)
        }
        let beforeFailure = try index(legacyRoot)
        XCTAssertFalse(legacy.observe(sourceDidChange: true) { source(56, captureBytes: 1_204_971) })
        XCTAssertEqual(try index(legacyRoot).failureCode, "validation_or_write_failed")
        XCTAssertNotEqual(try index(legacyRoot).fenceID, beforeFailure.fenceID)
        XCTAssertEqual(clock.continuous - 1_000_000, 162_855)

        clock = Clock()
        let paced = publisher()
        var fence: UUID?, maximumRetained = 0, published = Set<String>(), validations = 0
        var first: ImmutableObservationSnapshotPublisher.Index?
        for value in 0...200 {
            XCTAssertTrue(paced.observe(sourceDidChange: true) {
                validations += 1
                return source(value, captureBytes: 1_204_971)
            })
            let pointer = try index()
            if fence == nil { fence = pointer.fenceID; first = pointer }
            XCTAssertTrue(pointer.available); XCTAssertEqual(pointer.fenceID, fence)
            published.insert(try XCTUnwrap(pointer.generationID))
            maximumRetained = max(maximumRetained, try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent("SnapshotGenerations").path).count)
            if value == 150 {
                // A real collection deadline is 420 s; this old pin survives 450 s.
                XCTAssertTrue(FileManager.default.fileExists(atPath: try generation(XCTUnwrap(first)).path))
            }
            if value < 200 { clock.advance(3_000) }
        }
        XCTAssertEqual(validations, 201)
        XCTAssertEqual(published.count, 21)
        XCTAssertLessThanOrEqual(maximumRetained, 17)
        XCTAssertEqual(try liveReceipt().observedAtMS, clock.wall)
        XCTAssertEqual(try index().observedAtMS, clock.wall)
    }

    func testLargeCloudContinuationCapturesStayWithinQuotaWithoutRefreshingPinnedTimes() throws {
        for kind in ["icloud_drive", "google_drive"] {
            let directory = root.appendingPathComponent(kind)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let publisher = publisher(kind: kind, directory: directory)
            var generations = Set<String>(), fence: UUID?, validations = 0
            for value in 0...20 {
                XCTAssertTrue(publisher.observe(sourceDidChange: true) {
                    validations += 1
                    return source(value, captureBytes: 8 * 1_024 * 1_024 - 65_536)
                }, "A valid large \(kind) continuation capture must not exhaust its own retention quota at round \(value)")
                let current = try index(directory)
                guard current.available else { return }
                if fence == nil { fence = current.fenceID }
                XCTAssertEqual(current.fenceID, fence)
                generations.insert(try XCTUnwrap(current.generationID))
                XCTAssertLessThan(clock.wall - current.observedAtMS, 240_000)
                let receipt = try JSONDecoder().decode(VerifiedObservationPublisher.Receipt.self,
                    from: Data(contentsOf: directory.appendingPathComponent(VerifiedObservationPublisher.fileName)))
                XCTAssertEqual(receipt.observedAtMS, clock.wall)
                XCTAssertEqual(receipt.identity["generationID"], "synthetic-\(value)")
                if value < 20 { clock.advance(30_000) }
            }
            XCTAssertEqual(validations, 21)
            XCTAssertGreaterThan(generations.count, 1)
            XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(
                atPath: directory.appendingPathComponent("SnapshotGenerations").path).count, 8)
        }
    }

    func testCurrentPayloadGrowthPacesBeforeCopyAndRealFailureStillRecoversImmediately() throws {
        let publisher = publisher(kind: "icloud_drive")
        XCTAssertTrue(publisher.observe { source() })
        let initial = try index(), initialBytes = try indexBytes()
        clock.advance(30_000)
        XCTAssertTrue(publisher.observe(sourceDidChange: true) {
            let pending = try index()
            XCTAssertEqual(pending.sequence, initial.sequence)
            XCTAssertEqual(pending.observedAtMS, initial.observedAtMS)
            XCTAssertFalse(pending.available)
            return source(2, captureBytes: 8 * 1_024 * 1_024 - 65_536)
        })
        XCTAssertEqual(try indexBytes(), initialBytes, "The current larger payload changes pacing before allocating another generation")
        XCTAssertEqual(try liveReceipt().observedAtMS, clock.wall)
        clock.advance(60_000)
        XCTAssertTrue(publisher.observe { source(3, captureBytes: 8 * 1_024 * 1_024 - 65_536) })
        let large = try index()
        XCTAssertNotEqual(large.generationID, initial.generationID)
        clock.advance(1_000)
        XCTAssertFalse(publisher.observe(sourceDidChange: true) { throw VerifiedObservationPublisher.Failure.invalidSource })
        let failed = try index()
        XCTAssertNotEqual(failed.fenceID, large.fenceID)
        XCTAssertTrue(publisher.observe { source(4, captureBytes: 8 * 1_024 * 1_024 - 65_536) })
        XCTAssertEqual(try index().fenceID, failed.fenceID)
        XCTAssertNotEqual(try index().generationID, large.generationID)
        XCTAssertEqual(try index().observedAtMS, clock.wall)
    }

    func testBuild87PinsSurviveUpgradeAndCapacityWaitKeepsOriginalFreshnessUntilReclaim() throws {
        var oldGenerations: [ImmutableObservationSnapshotPublisher.Index] = []
        do {
            let legacy = publisher(build: "87", kind: "icloud_drive")
            for value in 0..<20 {
                XCTAssertTrue(legacy.observe(sourceDidChange: true) { source(value, captureBytes: 1_000_000) })
                oldGenerations.append(try index())
                clock.advance(3_000)
            }
        }
        let upgraded = publisher(kind: "icloud_drive")
        XCTAssertFalse(try index().available, "Upgrade cannot reuse a build87 pin as a current build88 observation")
        XCTAssertEqual(try index().failureCode, "observer_startup")
        XCTAssertTrue(upgraded.observe { source(20, captureBytes: 8 * 1_024 * 1_024 - 65_536) })
        let initial = try index()
        var prior = initial, sawCapacityWait = false
        for value in 1...18 {
            clock.advance(30_000)
            XCTAssertTrue(upgraded.observe(sourceDidChange: true) { source(20 + value, captureBytes: 8 * 1_024 * 1_024 - 65_536) })
            let current = try index()
            XCTAssertTrue(current.available); XCTAssertEqual(current.fenceID, initial.fenceID)
            XCTAssertLessThan(clock.wall - current.observedAtMS, 240_000)
            if value == 15 {
                sawCapacityWait = current.generationID == prior.generationID
                XCTAssertEqual(current.observedAtMS, prior.observedAtMS)
                XCTAssertEqual(current.sequence, prior.sequence)
                for old in oldGenerations {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: try generation(old).path),
                        "Protected build87 packages survive an upgrade and capacity wait unchanged")
                }
            }
            if value == 16 {
                XCTAssertNotEqual(current.generationID, prior.generationID,
                    "A real new generation publishes when the original protected pins expire")
            }
            prior = current
        }
        XCTAssertTrue(sawCapacityWait)
        XCTAssertEqual(try liveReceipt().observedAtMS, clock.wall)
    }

    func testCoalescingKeepsExactImmutableBytesButPublishesHonestCurrentLivePair() throws {
        let publisher = publisher()
        XCTAssertTrue(publisher.observe { source() })
        let initial = try index(), pointerBytes = try indexBytes(), folder = try generation(initial)
        let leaves = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let originals = try Dictionary(uniqueKeysWithValues: leaves.map { ($0, try Data(contentsOf: folder.appendingPathComponent($0))) })
        clock.advance(29_000)
        var validations = 0
        XCTAssertTrue(publisher.observe(sourceDidChange: true) {
            validations += 1
            let pending = try index()
            XCTAssertFalse(pending.available, "A new reader must not pin a source whose validation is pending")
            XCTAssertEqual(pending.failureCode, "validation_pending")
            XCTAssertNil(pending.generationID); XCTAssertNil(pending.manifestSHA256); XCTAssertNil(pending.manifestByteCount)
            XCTAssertEqual(pending.sequence, initial.sequence)
            XCTAssertEqual(pending.observedAtMS, initial.observedAtMS)
            XCTAssertEqual(pending.continuousTimeMS, initial.continuousTimeMS)
            XCTAssertEqual(pending.fenceID, initial.fenceID)
            return source(2)
        })
        XCTAssertEqual(validations, 1); XCTAssertEqual(try indexBytes(), pointerBytes)
        let receipt = try liveReceipt()
        XCTAssertEqual(receipt.observedAtMS, clock.wall); XCTAssertGreaterThan(receipt.sequence, initial.sequence)
        XCTAssertEqual(receipt.files, source(2).files)
        let receiptBytes = try Data(contentsOf: root.appendingPathComponent(VerifiedObservationPublisher.fileName))
        let status = try JSONDecoder().decode(VerifiedObservationPublisher.Status.self,
            from: Data(contentsOf: root.appendingPathComponent(VerifiedObservationPublisher.statusName)))
        XCTAssertTrue(status.available); XCTAssertEqual(status.observationSHA256, VerifiedObservationPublisher.digest(receiptBytes))
        XCTAssertEqual(status.sequence, receipt.sequence)
        for (name, bytes) in originals { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), bytes) }

        clock.advance(1_000)
        XCTAssertTrue(publisher.observe { source(3) }, "A coalesced event at 29 s must not postpone the due publication at 30 s")
        XCTAssertNotEqual(try index().generationID, initial.generationID)
        XCTAssertEqual(try index().fenceID, initial.fenceID)
        XCTAssertEqual(try index().observedAtMS, clock.wall)
    }

    func testMalformedSourceInsideIntervalRotatesFenceAndCanRecoverImmediately() throws {
        let publisher = publisher()
        XCTAssertTrue(publisher.observe { source() })
        let old = try index()
        clock.advance(1_000)
        XCTAssertFalse(publisher.observe(sourceDidChange: true) { throw VerifiedObservationPublisher.Failure.invalidSource })
        let failed = try index()
        XCTAssertFalse(failed.available); XCTAssertNotEqual(failed.fenceID, old.fenceID)
        XCTAssertTrue(publisher.observe { source(2) }, "A real failure cannot leave a 30-second recovery throttle")
        XCTAssertEqual(try index().fenceID, failed.fenceID)
        XCTAssertNotEqual(try index().generationID, old.generationID)
    }

    func testCoalescingStillRejectsMismatchedBytesAndNonAllowlistedPayload() throws {
        for mismatch in [true, false] {
            let publisher = publisher()
            XCTAssertTrue(publisher.observe { source() })
            let old = try index(); clock.advance(1_000)
            let original = source()
            let invalid = mismatch
                ? VerifiedObservationSource(sourceGeneratedAtMS: 1_000, identity: original.identity,
                    files: original.files, snapshotFiles: source(2).snapshotFiles)
                : VerifiedObservationSource(sourceGeneratedAtMS: 1_000, identity: original.identity,
                    files: [.init(name: "not-allowlisted.json", bytes: Data("{}".utf8))],
                    snapshotFiles: ["not-allowlisted.json": Data("{}".utf8)])
            XCTAssertFalse(publisher.observe(sourceDidChange: true) { invalid })
            XCTAssertEqual(try index().failureCode, "snapshot_source_invalid")
            XCTAssertNotEqual(try index().fenceID, old.fenceID)
        }
    }

    func testLiveWriteFailureDuringCoalescingStillRotatesFence() throws {
        var rejectReceipt = false
        let root = root!
        let publisher = publisher(writer: { bytes, name in
            if rejectReceipt && name == VerifiedObservationPublisher.fileName { throw POSIXError(.EACCES) }
            try bytes.write(to: root.appendingPathComponent(name), options: .atomic)
        })
        XCTAssertTrue(publisher.observe { source() }); let old = try index()
        clock.advance(1_000); rejectReceipt = true
        XCTAssertFalse(publisher.observe(sourceDidChange: true) { source(2) })
        let failed = try index()
        XCTAssertEqual(failed.failureCode, "validation_or_write_failed")
        XCTAssertNotEqual(failed.fenceID, old.fenceID)
        rejectReceipt = false
        XCTAssertTrue(publisher.observe { source(3) })
        XCTAssertEqual(try index().fenceID, failed.fenceID)
    }

    func testCoalescedRestoreAndInvalidationWriteFailuresLeaveDurablePendingUntilRecovery() throws {
        let root = root!
        var denyRestore = false
        let publisher = publisher(writer: { bytes, name in
            try bytes.write(to: root.appendingPathComponent(name), options: .atomic)
            if denyRestore, name == VerifiedObservationPublisher.statusName,
               try JSONDecoder().decode(VerifiedObservationPublisher.Status.self, from: bytes).available {
                // The live pair succeeded, but restore, error-index replacement
                // and fallback unlink are all denied after durable pending.
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
            }
        })
        XCTAssertTrue(publisher.observe { source() }); let old = try index()
        clock.advance(1_000); denyRestore = true
        XCTAssertFalse(publisher.observe(sourceDidChange: true) { source(2) })
        let stranded = try index()
        XCTAssertFalse(stranded.available); XCTAssertEqual(stranded.failureCode, "validation_pending")
        XCTAssertEqual(stranded.sequence, old.sequence)
        XCTAssertEqual(stranded.observedAtMS, old.observedAtMS)
        denyRestore = false
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        XCTAssertTrue(publisher.observe { source(3) })
        let recovered = try index()
        XCTAssertTrue(recovered.available); XCTAssertNotEqual(recovered.fenceID, old.fenceID)
        XCTAssertNotEqual(recovered.generationID, old.generationID)
    }

    func testInterruptedCoalescedAttemptLeavesUnavailablePointerWithoutClockRollback() throws {
        var snapshot: ImmutableObservationSnapshotPublisher?
        var publisher: VerifiedObservationPublisher? = self.publisher(inspectSnapshot: { snapshot = $0 })
        XCTAssertTrue(publisher!.observe { source() }); let old = try index()
        clock.advance(1_000)
        try snapshot!.begin(sequence: old.sequence + 1, time: (clock.wall, clock.continuous),
            minimumPublicationIntervalMS: 30_000)
        publisher = nil; snapshot = nil // Process ended before validation/commit.
        let pending = try index()
        XCTAssertFalse(pending.available); XCTAssertEqual(pending.failureCode, "validation_pending")
        XCTAssertEqual(pending.sequence, old.sequence)
        XCTAssertEqual(pending.observedAtMS, old.observedAtMS)
        XCTAssertEqual(pending.continuousTimeMS, old.continuousTimeMS)
        XCTAssertEqual(pending.fenceID, old.fenceID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try generation(old).path))
    }

    func testCoalescingComparesExactIndexBytesAndRejectsConcurrentMutation() throws {
        let publisher = publisher()
        XCTAssertTrue(publisher.observe { source() }); let old = try index()
        clock.advance(1_000)
        XCTAssertFalse(publisher.observe(sourceDidChange: true) {
            // Same decoded fields are insufficient: the checked pointer changed.
            try (indexBytes() + Data(" ".utf8)).write(to: root.appendingPathComponent("snapshot-index.json"))
            return source(2)
        })
        XCTAssertEqual(try index().failureCode, "snapshot_concurrent_writer")
        XCTAssertNotEqual(try index().fenceID, old.fenceID)
    }

    func testActualCapacityExhaustionStillFailsClosedWithSpecificCodeAndProtectedPins() throws {
        var retention = ImmutableObservationSnapshotPublisher.Retention.forReportKind("google_drive")
        retention.maximumCount = 2; retention.recentCount = 1
        let publisher = publisher(retention: retention)
        XCTAssertTrue(publisher.observe { source() }); let first = try index()
        clock.advance(240_000)
        XCTAssertTrue(publisher.observe { source(2) }); let second = try index()
        clock.advance(240_000)
        XCTAssertFalse(publisher.observe { source(3) })
        let failed = try index()
        XCTAssertEqual(failed.failureCode, "snapshot_capacity_exceeded")
        XCTAssertNotEqual(failed.fenceID, second.fenceID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try generation(first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try generation(second).path))
        clock.advance(480_000)
        XCTAssertTrue(publisher.observe { source(4) })
        XCTAssertEqual(try index().fenceID, failed.fenceID)
    }

    func testLowSpaceAndClockJumpCannotHideInsideCoalescingInterval() throws {
        var free = Int64.max
        let publisher = publisher(freeBytes: { _ in free })
        XCTAssertTrue(publisher.observe { source() }); let old = try index()
        clock.advance(1_000); free = 0
        XCTAssertFalse(publisher.observe(sourceDidChange: true) { source(2) })
        XCTAssertEqual(try index().failureCode, "snapshot_low_space")
        XCTAssertNotEqual(try index().fenceID, old.fenceID)
        free = Int64.max
        XCTAssertTrue(publisher.observe { source(3) }); let recovered = try index()
        clock.wall += 300_000; clock.continuous += 1_000
        XCTAssertFalse(publisher.observe(sourceDidChange: true) { source(4) })
        XCTAssertEqual(try index().failureCode, "clock_discontinuity")
        XCTAssertNotEqual(try index().fenceID, recovered.fenceID)
    }

    func testExplicitInvalidationAndProcessRestartCannotReuseCoalescedSuccess() throws {
        let publisher = publisher()
        XCTAssertTrue(publisher.observe { source() }); let first = try index()
        clock.advance(1_000); publisher.invalidate()
        let invalidated = try index()
        XCTAssertEqual(invalidated.failureCode, "source_publication_failed")
        XCTAssertNotEqual(invalidated.fenceID, first.fenceID)
        XCTAssertTrue(publisher.observe { source(2) })
        let recovered = try index()
        XCTAssertEqual(recovered.fenceID, invalidated.fenceID)
        XCTAssertNotEqual(recovered.generationID, first.generationID)
        let process = UUID(), restarted = self.publisher(process: process)
        let startup = try index()
        XCTAssertEqual(startup.failureCode, "observer_startup")
        XCTAssertEqual(startup.observerProcessRunID, process)
        XCTAssertNotEqual(startup.fenceID, recovered.fenceID)
        XCTAssertTrue(restarted.observe { source(3) })
        XCTAssertEqual(try index().fenceID, startup.fenceID)
    }
}
