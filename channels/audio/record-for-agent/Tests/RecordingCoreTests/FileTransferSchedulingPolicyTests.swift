import XCTest
@testable import RecordingCore

final class FileTransferSchedulingPolicyTests: XCTestCase {
    func testThreeFreeSlotsSendNewestThenTwoOldestWithoutDuplicates() throws {
        var policy = FileTransferSchedulingPolicy()
        var eligible = (1...6).map { manifest($0) }
        // Repeated input identities must also disappear when the caller enqueues them.
        eligible.append(manifest(6))

        let selected = try (0..<3).map { _ in try enqueueNext(&policy, from: &eligible) }

        XCTAssertEqual(selected.map(\.sequence), [6, 1, 2])
        XCTAssertEqual(Set(selected.map(\.id)).count, 3)
        XCTAssertEqual(Set(eligible.map(\.sequence)), [3, 4, 5])
    }

    func testSingleSlotRefillsWithContinuousNewArrivalsStillAdvanceHistory() throws {
        var policy = FileTransferSchedulingPolicy()
        var eligible = (1...6).map { manifest($0) }
        var sent: [SegmentManifest] = []

        // Only one real slot is released per pass. A new recording appears every pass.
        for arrival in 101...109 {
            eligible.append(manifest(arrival))
            sent.append(try enqueueNext(&policy, from: &eligible))
        }

        XCTAssertEqual(sent.map(\.sequence), [101, 1, 2, 104, 3, 4, 107, 5, 6])
        XCTAssertEqual(Set(sent.map(\.id)).count, sent.count)
        XCTAssertFalse(eligible.contains { $0.sequence <= 6 })
    }

    func testRecentRecordingWaitsAtMostTwoSuccessfulHistoricalEnqueues() throws {
        var policy = FileTransferSchedulingPolicy()
        var eligible = (1...10).map { manifest($0) }
        _ = try enqueueNext(&policy, from: &eligible)
        let recent = manifest(100)
        eligible.append(recent)

        XCTAssertEqual(try enqueueNext(&policy, from: &eligible).sequence, 1)
        XCTAssertEqual(try enqueueNext(&policy, from: &eligible).sequence, 2)
        XCTAssertEqual(try enqueueNext(&policy, from: &eligible).id, recent.id)
    }

    func testSelectionAndEmptyCandidatesDoNotConsumeTurns() throws {
        var policy = FileTransferSchedulingPolicy()
        var eligible = (1...4).map { manifest($0) }

        XCTAssertNil(policy.nextCandidate(from: []))
        for _ in 0..<5 {
            XCTAssertEqual(policy.nextCandidate(from: eligible)?.sequence, 4)
        }
        _ = try enqueueNext(&policy, from: &eligible)
        XCTAssertNil(policy.nextCandidate(from: []))
        for _ in 0..<5 {
            XCTAssertEqual(policy.nextCandidate(from: eligible)?.sequence, 1)
        }
        XCTAssertEqual(try enqueueNext(&policy, from: &eligible).sequence, 1)
        XCTAssertEqual(try enqueueNext(&policy, from: &eligible).sequence, 2)
        XCTAssertEqual(policy.nextCandidate(from: eligible)?.sequence, 3)
    }

    func testFailedCandidateCanBeExcludedWithoutLosingTheRecentTurn() throws {
        var policy = FileTransferSchedulingPolicy()
        var eligible = (1...4).map { manifest($0) }
        let failed = try XCTUnwrap(policy.nextCandidate(from: eligible))
        XCTAssertEqual(failed.sequence, 4)
        // Simulate failed encoding: do not commit, exclude it for this invocation.
        eligible.removeAll { $0.id == failed.id }

        XCTAssertEqual(try enqueueNext(&policy, from: &eligible).sequence, 3)
        XCTAssertEqual(try enqueueNext(&policy, from: &eligible).sequence, 1)
        XCTAssertEqual(try enqueueNext(&policy, from: &eligible).sequence, 2)
    }

    func testEqualCaptureTimesHaveDeterministicUUIDOrder() throws {
        var firstPolicy = FileTransferSchedulingPolicy()
        var secondPolicy = FileTransferSchedulingPolicy()
        var first = (1...4).map { manifest($0, captureTime: 10) }
        var second = Array(first.reversed())

        let firstOrder = try (0..<4).map { _ in try enqueueNext(&firstPolicy, from: &first).id }
        let secondOrder = try (0..<4).map { _ in try enqueueNext(&secondPolicy, from: &second).id }

        XCTAssertEqual(firstOrder, [4, 1, 2, 3].map { manifest($0).id })
        XCTAssertEqual(firstOrder, secondOrder)
    }

    func testEveryTurnRoundTripsWithoutResettingHistoryPriority() throws {
        var policy = FileTransferSchedulingPolicy()
        var eligible = (1...6).map { manifest($0) }

        for expected in [6, 1, 2, 5, 3, 4] {
            let restored = try TransportCodec.decode(FileTransferSchedulingPolicy.self,
                from: TransportCodec.encode(policy))
            XCTAssertEqual(restored, policy)
            policy = restored
            XCTAssertEqual(try enqueueNext(&policy, from: &eligible).sequence, expected)
        }
    }

    func testSingleSlotRefillsRemainFairAcrossRestartsAndNewArrivals() throws {
        var policy = FileTransferSchedulingPolicy()
        var eligible = (1...6).map { manifest($0) }
        var sent: [Int] = []

        for arrival in 101...109 {
            eligible.append(manifest(arrival))
            sent.append(try enqueueNext(&policy, from: &eligible).sequence)
            policy = try TransportCodec.decode(FileTransferSchedulingPolicy.self,
                from: TransportCodec.encode(policy))
        }

        XCTAssertEqual(sent, [101, 1, 2, 104, 3, 4, 107, 5, 6])
    }

    func testInvalidSavedTurnsThrowInsteadOfSilentlyResettingToNewest() {
        for json in ["{\"nextTurn\":-1}", "{\"nextTurn\":3}", "{\"nextTurn\":999}",
                     "{\"nextTurn\":1.5}", "{\"nextTurn\":\"1\"}", "{\"nextTurn\":true}",
                     "{\"nextTurn\":null}", "{}"] {
            XCTAssertThrowsError(try TransportCodec.decode(FileTransferSchedulingPolicy.self,
                from: Data(json.utf8)), json)
        }
    }

    func testUnreadableStateFallbackStartsWithTwoHistoricalTransfers() throws {
        var policy = FileTransferSchedulingPolicy(startingWithOldest: true)
        var eligible = (1...6).map { manifest($0) }

        let order = try (0..<3).map { _ in try enqueueNext(&policy, from: &eligible).sequence }

        XCTAssertEqual(order, [1, 2, 6])
    }

    func testHistoryLeavesARealVacancyForNextSealedRecording() throws {
        var policy = FileTransferSchedulingPolicy()
        let now = Date(timeIntervalSince1970: 10_000)
        var eligible = (1...6).map { manifest($0) }
        var outstanding = Set<UUID>()
        for expected in [1, 2] {
            let chosen = try XCTUnwrap(policy.nextCandidate(from: eligible,
                outstandingIDs: outstanding, outstandingCount: outstanding.count, at: now))
            XCTAssertEqual(chosen.sequence, expected)
            policy.noteEnqueued(chosen, outstandingIDs: outstanding, at: now)
            outstanding.insert(chosen.id)
            eligible.removeAll { $0.id == chosen.id }
        }
        XCTAssertNil(policy.nextCandidate(from: eligible, outstandingIDs: outstanding,
            outstandingCount: 2, at: now))
        let fresh = manifest(100, captureTime: 9_999)
        eligible.append(fresh)
        XCTAssertEqual(policy.nextCandidate(from: eligible, outstandingIDs: outstanding,
            outstandingCount: 2, at: now)?.id, fresh.id)
    }

    func testRecentLaneRefillsAheadOfHistoryAndHistoricalVacanciesStillProgress() throws {
        var policy = FileTransferSchedulingPolicy()
        let now = Date(timeIntervalSince1970: 10_000)
        let fresh = manifest(100, captureTime: 9_999)
        let newer = manifest(101, captureTime: 10_000)
        var outstanding: Set<UUID> = [manifest(1).id, manifest(2).id]
        let first = try XCTUnwrap(policy.nextCandidate(from: [manifest(3), fresh],
            outstandingIDs: outstanding, outstandingCount: 2, at: now))
        XCTAssertEqual(first, fresh)
        policy.noteEnqueued(first, outstandingIDs: outstanding, at: now)
        outstanding.insert(first.id)
        policy = try TransportCodec.decode(FileTransferSchedulingPolicy.self, from: TransportCodec.encode(policy))
        outstanding.remove(manifest(1).id)
        XCTAssertEqual(policy.nextCandidate(from: [manifest(3), newer], outstandingIDs: outstanding,
            outstandingCount: 2, at: now.addingTimeInterval(1))?.sequence, 3)
        outstanding.remove(fresh.id)
        outstanding.insert(manifest(3).id)
        XCTAssertEqual(policy.nextCandidate(from: [manifest(4), newer], outstandingIDs: outstanding,
            outstandingCount: 2, at: now.addingTimeInterval(1))?.id, newer.id)
    }

    func testRecentWindowExcludesOldAndFutureRecordingsIncludingLegacyState() throws {
        let policy = try TransportCodec.decode(FileTransferSchedulingPolicy.self,
            from: Data("{\"nextTurn\":2}".utf8))
        let now = Date(timeIntervalSince1970: 10_000)
        let occupied: Set<UUID> = [manifest(1).id, manifest(2).id]
        XCTAssertNil(policy.nextCandidate(from: [manifest(3, captureTime: 9_698), manifest(4, captureTime: 10_000)],
            outstandingIDs: occupied, outstandingCount: 2, at: now))
        XCTAssertEqual(policy.nextCandidate(from: [manifest(5, captureTime: 9_699)],
            outstandingIDs: occupied, outstandingCount: 2, at: now)?.sequence, 5)
        // Even unknown/malformed system tasks consume physical queue capacity.
        XCTAssertNil(policy.nextCandidate(from: [manifest(3)], outstandingIDs: [], outstandingCount: 2, at: now))
    }

    func testExpiredRecentTaskCannotKeepTheReservedSlotOccupiedWithHistory() throws {
        var policy = FileTransferSchedulingPolicy()
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = manifest(100, captureTime: 9_999)
        policy.noteEnqueued(recent, outstandingIDs: [manifest(1).id, manifest(2).id], at: now)
        policy = try TransportCodec.decode(FileTransferSchedulingPolicy.self, from: TransportCodec.encode(policy))
        let outstanding: Set<UUID> = [recent.id, manifest(2).id]
        let later = now.addingTimeInterval(301)
        XCTAssertNil(policy.nextCandidate(from: [manifest(3)], outstandingIDs: outstanding,
            outstandingCount: 2, at: later))
        let fresh = manifest(101, captureTime: 10_300)
        XCTAssertEqual(policy.nextCandidate(from: [manifest(3), fresh], outstandingIDs: outstanding,
            outstandingCount: 2, at: later)?.id, fresh.id)
        XCTAssertNil(policy.nextCandidate(from: [fresh], outstandingIDs: outstanding,
            outstandingCount: 3, at: later))
    }

    private func enqueueNext(_ policy: inout FileTransferSchedulingPolicy,
                             from eligible: inout [SegmentManifest]) throws -> SegmentManifest {
        let selected = try XCTUnwrap(policy.nextCandidate(from: eligible))
        // Model a successful system enqueue; callers own actual queue capacity.
        policy.noteEnqueued()
        eligible.removeAll { $0.id == selected.id }
        return selected
    }

    private func manifest(_ sequence: Int, captureTime: TimeInterval? = nil) -> SegmentManifest {
        let suffix = String(format: "%012d", sequence)
        let id = UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
        let start = Date(timeIntervalSince1970: captureTime ?? TimeInterval(sequence))
        return SegmentManifest(id: id,
            sessionID: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!,
            sequence: sequence, startedAt: start, endedAt: start.addingTimeInterval(1),
            sampleRate: 48_000, frameCount: 48_000, fileName: "\(id.uuidString).caf",
            byteCount: 192_000, sha256: String(repeating: "a", count: 64))
    }
}
