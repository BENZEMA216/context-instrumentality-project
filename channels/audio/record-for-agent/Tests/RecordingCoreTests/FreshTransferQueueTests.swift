import XCTest
@testable import RecordingCore

/// These fixtures contain synthetic bytes only. Assertions observe the public
/// queue contract, source preservation, and restart behavior rather than copy
/// the implementation's selection logic.
final class FreshTransferQueueTests: XCTestCase {
    private var root: URL!
    private let sessionID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private enum SimulatedCrash: Error { case interrupted }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-transfer-tests-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func repository(fault: ((RepositoryFaultPoint) throws -> Void)? = nil,
                            recover: Bool = true) throws -> RecordingRepository {
        try RecordingRepository(root: root, faultInjector: fault,
                                recoverTransactionsOnInitialization: recover)
    }

    private func fixtureID(_ ordinal: Int) -> UUID {
        // Intentionally neither seal order nor date order when sorted as UUIDs.
        let permutation = [90, 4, 78, 12, 66, 25, 54, 37, 42, 1, 99, 7, 88, 14, 76, 21]
        return UUID(uuidString: String(format: "%08x-0000-0000-0000-%012x",
                                      permutation[ordinal % permutation.count], ordinal + 1))!
    }

    @discardableResult
    private func seal(_ repo: RecordingRepository, ordinal: Int,
                      session: UUID? = nil, sequence: Int? = nil) throws -> SegmentManifest {
        let id = fixtureID(ordinal)
        // Capture times also disagree with seal order. FIFO is defined by commit
        // order, including restored recordings after clock changes.
        let date = start.addingTimeInterval(Double((15 - ordinal) * 60))
        try Data(repeating: UInt8(ordinal + 1), count: 257 + ordinal)
            .write(to: repo.stagingURL(for: id))
        return try repo.sealSegment(stagedURL: repo.stagingURL(for: id), id: id,
            sessionID: session ?? sessionID, sequence: sequence ?? ordinal,
            startedAt: date, endedAt: date.addingTimeInterval(60),
            sampleRate: 16_000, frameCount: 960_000)
    }

    private func receipt(_ value: SegmentManifest) -> SegmentReceipt {
        SegmentReceipt(segmentID: value.id, sha256: value.sha256, byteCount: value.byteCount)
    }

    private var stateURL: URL { root.appendingPathComponent("fresh-transfer/state.json") }
    private var logURL: URL { root.appendingPathComponent("fresh-transfer/order.ids") }

    private func rewriteState(_ mutation: (inout [String: Any]) -> Void) throws {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        mutation(&value)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: stateURL)
    }

    func testInaccessibleFreshParentIsNotAnEmptyQueueAndResumesWithoutReset() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let value = try seal(repo, ordinal: 0)
        try repo.closePriorityCapture()
        let beforeState = try Data(contentsOf: stateURL)
        let beforeLog = try Data(contentsOf: logURL)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try repo.freshTransferSnapshot())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        XCTAssertEqual(try Data(contentsOf: stateURL), beforeState)
        XCTAssertEqual(try Data(contentsOf: logURL), beforeLog)
        let resumed = try repo.freshTransferSnapshot()
        XCTAssertEqual(resumed.head, value)
        XCTAssertEqual(resumed.remainingCount, 1)
        XCTAssertFalse(try repo.hasDurableAcknowledgement(for: value))
    }

    func testAllElevenSegmentsAdvanceInSealOrderAcrossEveryRestart() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let values = try (0..<11).map { try seal(repo, ordinal: $0) }
        try repo.closePriorityCapture()

        XCTAssertNotEqual(values.map(\.id), values.map(\.id).sorted { $0.uuidString < $1.uuidString })
        for (offset, expected) in values.enumerated() {
            let reopened = try repository()
            let observed = try reopened.freshTransferSnapshot()
            XCTAssertEqual(observed.head, expected, "Every middle segment must be reachable, offset \(offset)")
            XCTAssertEqual(observed.remainingCount, values.count - offset)
            XCTAssertFalse(observed.captureOpen)
            XCTAssertTrue(observed.blocksHistory)
            XCTAssertTrue(try reopened.isProtectedFreshSegment(expected))
            XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: expected).path))
            try reopened.acknowledge(receipt(expected))
        }
        let complete = try repository().freshTransferSnapshot()
        XCTAssertNil(complete.head)
        XCTAssertEqual(complete.remainingCount, 0)
        XCTAssertFalse(complete.needsAnotherPass)
        XCTAssertFalse(complete.blocksHistory)
    }

    func testOutOfOrderReceiptsAndTransportCompletionCannotSkipUnacknowledgedHead() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let values = try (0..<3).map { try seal(repo, ordinal: $0) }
        try repo.closePriorityCapture()
        try repo.acknowledge(receipt(values[2]))
        try repo.acknowledge(receipt(values[1]))

        var transport = FileTransferRetryPolicy()
        transport.noteEnqueued(values[0], attemptID: "transport-only")
        XCTAssertTrue(transport.recordDelivery(of: values[0], attemptID: "transport-only"))
        for _ in 0..<3 {
            let reopened = try repository()
            let observed = try reopened.freshTransferSnapshot()
            XCTAssertEqual(observed.head, values[0])
            XCTAssertEqual(observed.remainingCount, 3)
            XCTAssertFalse(try reopened.hasDurableAcknowledgement(for: values[0]))
            XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: values[0]).path))
        }
        try repo.acknowledge(receipt(values[0]))
        XCTAssertFalse(try repo.freshTransferSnapshot().blocksHistory)
    }

    func testOpenCaptureWithTemporarilyEmptyFIFOStillBlocksHistory() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let first = try seal(repo, ordinal: 0)
        try repo.acknowledge(receipt(first))
        let betweenSegments = try repo.freshTransferSnapshot()
        XCTAssertTrue(betweenSegments.captureOpen)
        XCTAssertTrue(betweenSegments.blocksHistory)
        XCTAssertNil(betweenSegments.head)
        XCTAssertEqual(betweenSegments.remainingCount, 0)

        let second = try seal(repo, ordinal: 1)
        XCTAssertEqual(try repo.freshTransferSnapshot().head, second)
        try repo.closePriorityCapture()
        XCTAssertTrue(try repo.freshTransferSnapshot().blocksHistory)
        try repo.acknowledge(receipt(second))
        XCTAssertFalse(try repo.freshTransferSnapshot().blocksHistory)
    }

    func testManualResumePrioritizesItsEpochAndAutomaticSessionRecoveryKeepsThatEpoch() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let first = try seal(repo, ordinal: 0)
        try repo.closePriorityCapture()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 1, newEpoch: true)
        let second = try seal(repo, ordinal: 1)
        let recoveredSession = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        try repo.beginPriorityCapture(sessionID: recoveredSession, nextSequence: 0, newEpoch: false)
        let third = try seal(repo, ordinal: 2, session: recoveredSession, sequence: 0)
        try repo.closePriorityCapture()

        for expected in [second, third, first] {
            let reopened = try repository()
            XCTAssertEqual(try reopened.freshTransferSnapshot().head, expected)
            try reopened.acknowledge(receipt(expected))
        }
        XCTAssertFalse(try repository().freshTransferSnapshot().blocksHistory)
    }

    func testLatestExplicitEpochDrainsAcrossPauseAndRestartBeforeOldGlobalHead() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let old = try seal(repo, ordinal: 0)
        let oldIdentity = try XCTUnwrap(repo.freshTransferSnapshot().priorityIdentity)
        try repo.closePriorityCapture()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 1, newEpoch: true)
        let between = try repo.freshTransferSnapshot()
        XCTAssertNil(between.head, "An old head cannot fill the gap before the new first seal")
        XCTAssertTrue(between.blocksHistory)
        XCTAssertFalse(try repo.isCurrentPriority(oldIdentity))
        let first = try seal(repo, ordinal: 1)
        let second = try seal(repo, ordinal: 2)
        let order = try Data(contentsOf: logURL)
        try repo.closePriorityCapture()
        let reopened = try repository()
        let selected = try reopened.freshTransferSnapshot()
        let identity = try XCTUnwrap(selected.priorityIdentity)
        XCTAssertEqual(selected.head, first)
        XCTAssertTrue(try reopened.isCurrentPriority(identity))
        XCTAssertTrue(try reopened.canYieldToPriority(old, priority: identity))
        XCTAssertTrue(try reopened.isProtectedFreshSegment(old), "Yield eligibility must not remove audio protection")
        try reopened.acknowledge(receipt(second))
        XCTAssertEqual(try repository().freshTransferSnapshot().head, first)
        try reopened.acknowledge(receipt(first))
        let fallback = try repository().freshTransferSnapshot()
        XCTAssertEqual(fallback.head, old)
        XCTAssertNil(fallback.priorityIdentity)
        var admissions = 0
        XCTAssertTrue(try reopened.withCurrentFreshHead(old, priority: nil) { admissions += 1 })
        try reopened.beginPriorityCapture(sessionID: sessionID, nextSequence: 3, newEpoch: true)
        XCTAssertFalse(try reopened.withCurrentFreshHead(old, priority: nil) { admissions += 1 },
                       "A new explicit begin must revoke an earlier fallback selection before enqueue")
        XCTAssertEqual(admissions, 1)
        try reopened.closePriorityCapture()
        XCTAssertFalse(try reopened.hasDurableAcknowledgement(for: old))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: old).path))
        XCTAssertEqual(try Data(contentsOf: logURL), order, "Priority must never rewrite the global append log")
        try reopened.acknowledge(receipt(old))
        XCTAssertFalse(try repository().freshTransferSnapshot().blocksHistory)
    }

    func testLateRecoveredOldTailIsSkippedOnlyByPriorityCursorAndNeverPreempted() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let old = try seal(repo, ordinal: 0)
        let draft = OpenAudioSegment(id: fixtureID(1), sessionID: sessionID, sequence: 1,
            startedAt: start, sampleRate: 16_000, channelCount: 1, pcmFormat: .int16,
            interleaved: true, timeZoneIdentifier: nil)
        try repo.beginAudioSegment(draft)
        let original = Data(repeating: 23, count: 258)
        try original.write(to: repo.stagingURL(for: draft.id))
        let newSession = UUID()
        try repo.beginPriorityCapture(sessionID: newSession, nextSequence: 0, newEpoch: true)
        let first = try seal(repo, ordinal: 2, session: newSession, sequence: 0)
        let late = try repo.sealSegment(stagedURL: repo.stagingURL(for: draft.id), id: draft.id,
            sessionID: sessionID, sequence: 1, startedAt: start, endedAt: start.addingTimeInterval(60),
            sampleRate: 16_000, frameCount: 960_000)
        let second = try seal(repo, ordinal: 3, session: newSession, sequence: 1)
        try repo.closePriorityCapture()
        let identity = try XCTUnwrap(repo.freshTransferSnapshot().priorityIdentity)
        XCTAssertTrue(try repo.canYieldToPriority(old, priority: identity))
        XCTAssertFalse(try repo.canYieldToPriority(late, priority: identity))
        XCTAssertTrue(try repo.isProtectedFreshSegment(late))
        try repo.acknowledge(receipt(first))
        let next = try repository().freshTransferSnapshot()
        XCTAssertEqual(next.head, second)
        XCTAssertEqual(next.checkedCount, 3, "ACK, old-epoch skip and new head each spend one shared candidate")
        try repo.acknowledge(receipt(second))
        XCTAssertEqual(try repository().freshTransferSnapshot().head, old)
        try repo.acknowledge(receipt(old))
        XCTAssertEqual(try repository().freshTransferSnapshot().head, late)
        XCTAssertEqual(try Data(contentsOf: repo.audioURL(for: late)), original)
        try repo.acknowledge(receipt(late))
        XCTAssertFalse(try repository().freshTransferSnapshot().blocksHistory)
    }

    func testBothCursorsShareEightCandidateBudgetWithoutSkippingOldUnacknowledgedHead() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let old = try seal(repo, ordinal: 0)
        try repo.closePriorityCapture()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 1, newEpoch: true)
        let current = try (1...8).map { try seal(repo, ordinal: $0) }
        for value in current { try repo.acknowledge(receipt(value)) }
        try repo.closePriorityCapture()
        let first = try repo.freshTransferSnapshot()
        XCTAssertEqual(first.checkedCount, 8)
        XCTAssertNil(first.head)
        XCTAssertTrue(first.needsAnotherPass)
        XCTAssertEqual(first.remainingCount, 9, "Global remainder conservatively includes ACK holes")
        let second = try repository().freshTransferSnapshot(acknowledgementLimit: 1)
        XCTAssertEqual(second.checkedCount, 1)
        XCTAssertEqual(second.head, old)
        XCTAssertNil(second.priorityIdentity)
        try repo.acknowledge(receipt(old))
        let third = try repository().freshTransferSnapshot()
        XCTAssertEqual(third.checkedCount, 8)
        XCTAssertTrue(third.needsAnotherPass)
        XCTAssertEqual(try repository().freshTransferSnapshot().remainingCount, 0)
    }

    func testPriorityAndFallbackShareRemainderOfCallerBudget() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let old = try seal(repo, ordinal: 0)
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 1, newEpoch: true)
        let newest = try seal(repo, ordinal: 1)
        try repo.acknowledge(receipt(newest))
        try repo.closePriorityCapture()
        var charged = 0
        let observed = try repo.freshTransferSnapshot(acknowledgementLimit: 1, onCandidateCheck: { charged += 1 })
        XCTAssertEqual(observed.checkedCount, 1)
        XCTAssertNil(observed.head)
        XCTAssertTrue(observed.needsAnotherPass)
        XCTAssertEqual(try repo.freshTransferSnapshot(acknowledgementLimit: 1,
            onCandidateCheck: { charged += 1 }).head, old)
        XCTAssertEqual(charged, 2, "Both priority and fallback reads notify the same caller budget")
    }

    func testFailedEighthCandidateReadStillChargesEightAttemptsWithoutWrappingItsError() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let old = try seal(repo, ordinal: 0)
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 1, newEpoch: true)
        let newer = try (1...8).map { try seal(repo, ordinal: $0) }
        for value in newer.prefix(7) { try repo.acknowledge(receipt(value)) }
        let missing = root.appendingPathComponent("fresh-transfer/" + newer[7].id.uuidString.lowercased() + ".json")
        try FileManager.default.removeItem(at: missing)
        var charged = 0
        XCTAssertThrowsError(try repo.freshTransferSnapshot(onCandidateCheck: { charged += 1 })) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, NSFileReadNoSuchFileError)
        }
        XCTAssertEqual(charged, 8)
        var additional = 0
        let exhausted = try repo.freshTransferSnapshot(acknowledgementLimit: max(0, 8 - charged),
            onCandidateCheck: { additional += 1 })
        XCTAssertEqual(additional, 0)
        XCTAssertEqual(exhausted.checkedCount, 0)
        XCTAssertNil(exhausted.head)
        XCTAssertTrue(exhausted.needsAnotherPass)
        XCTAssertFalse(try repo.hasDurableAcknowledgement(for: old))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.audioURL(for: newer[7]).path))
    }

    func testRevokedCandidateReadIsNotChargedAndOriginalCommitFailureIsPreserved() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let value = try seal(repo, ordinal: 0)
        try repo.acknowledge(receipt(value))
        var charged = 0
        let revoked = try repo.freshTransferSnapshot(while: { false }, onCandidateCheck: { charged += 1 })
        XCTAssertEqual(charged, 0)
        XCTAssertEqual(revoked.checkedCount, 0)
        XCTAssertTrue(revoked.needsAnotherPass)
        let broken = try repository(fault: { if case .beforeFreshHeadCommit = $0 { throw SimulatedCrash.interrupted } },
                                    recover: false)
        XCTAssertThrowsError(try broken.freshTransferSnapshot(onCandidateCheck: { charged += 1 })) { error in
            XCTAssertTrue(error is SimulatedCrash)
        }
        XCTAssertEqual(charged, 1)
    }

    func testPriorityCursorCommitFailureCannotSkipNewHeadOrReleaseOldAudioAfterRestart() throws {
        for boundary in [RepositoryFaultPoint.beforeFreshHeadCommit, .afterFreshHeadCommit] {
            let caseRoot = root.appendingPathComponent(UUID().uuidString)
            let repo = try RecordingRepository(root: caseRoot)
            try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
            let old = try seal(repo, ordinal: 0)
            try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 1, newEpoch: true)
            let acknowledged = try seal(repo, ordinal: 1)
            let pending = try seal(repo, ordinal: 2)
            try repo.closePriorityCapture()
            try repo.acknowledge(receipt(acknowledged))
            let broken = try RecordingRepository(root: caseRoot, faultInjector: { point in
                switch (point, boundary) {
                case (.beforeFreshHeadCommit, .beforeFreshHeadCommit), (.afterFreshHeadCommit, .afterFreshHeadCommit):
                    throw SimulatedCrash.interrupted
                default: break
                }
            }, recoverTransactionsOnInitialization: false)
            XCTAssertThrowsError(try broken.freshTransferSnapshot())
            let reopened = try RecordingRepository(root: caseRoot)
            XCTAssertEqual(try reopened.freshTransferSnapshot().head, pending)
            XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: old).path))
            XCTAssertFalse(try reopened.hasDurableAcknowledgement(for: old))
            try reopened.acknowledge(receipt(pending))
            XCTAssertEqual(try reopened.freshTransferSnapshot().head, old)
        }
    }

    func testLegacyStateKeepsGlobalOrderUntilNextExplicitBegin() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let first = try seal(repo, ordinal: 0)
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 1, newEpoch: true)
        _ = try seal(repo, ordinal: 1)
        try rewriteState { value in
            for key in ["priorityEpochID", "prioritySessionID", "priorityStartPosition", "priorityCursor"] {
                value.removeValue(forKey: key)
            }
        }
        let legacy = try repository()
        XCTAssertEqual(try legacy.freshTransferSnapshot().head, first)
        XCTAssertNil(try legacy.freshTransferSnapshot().priorityIdentity)
        let recoveredSession = UUID()
        try legacy.beginPriorityCapture(sessionID: recoveredSession, nextSequence: 0, newEpoch: false)
        _ = try seal(legacy, ordinal: 2, session: recoveredSession, sequence: 0)
        XCTAssertEqual(try legacy.freshTransferSnapshot().head, first)
        try legacy.closePriorityCapture()
        try legacy.beginPriorityCapture(sessionID: recoveredSession, nextSequence: 1, newEpoch: true)
        let newest = try seal(legacy, ordinal: 3, session: recoveredSession, sequence: 1)
        XCTAssertEqual(try repository().freshTransferSnapshot().head, newest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.audioURL(for: first).path))
    }

    func testMalformedPriorityProvenanceNeverSilentlyDowngradesToLegacy() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let value = try seal(repo, ordinal: 0)
        try repo.closePriorityCapture()
        let valid = try Data(contentsOf: stateURL)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0.removeValue(forKey: "priorityEpochID") },
            { $0.removeValue(forKey: "prioritySessionID") },
            { $0.removeValue(forKey: "priorityStartPosition") },
            { $0.removeValue(forKey: "priorityCursor") },
            { $0["priorityEpochID"] = NSNull() },
            { $0["priorityEpochID"] = UUID().uuidString },
            { $0["prioritySessionID"] = UUID().uuidString },
            { $0["priorityCursor"] = -1 },
            { $0["priorityCursor"] = 2 },
            { $0["priorityStartPosition"] = 1 },
            { $0["priorityStartPosition"] = -1 }
        ]
        for mutate in mutations {
            try valid.write(to: stateURL)
            try rewriteState(mutate)
            let reopened = try repository(recover: false)
            XCTAssertThrowsError(try reopened.freshTransferSnapshot())
            XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: value).path))
            XCTAssertFalse(try reopened.hasDurableAcknowledgement(for: value))
        }
    }

    func testPriorityIdentityAndAdmissionRejectNewerBeginAndFutureOrUnknownEntries() throws {
        let repo = try repository()
        let history = try seal(repo, ordinal: 0)
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 1, newEpoch: true)
        let current = try seal(repo, ordinal: 1)
        let currentState = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let identity = try XCTUnwrap(repo.freshTransferSnapshot().priorityIdentity)
        XCTAssertTrue(try repo.canYieldToPriority(history, priority: identity))
        XCTAssertFalse(try repo.canYieldToPriority(current, priority: identity))
        var executions = 0
        XCTAssertTrue(try repo.withCurrentFreshHead(current, priority: identity) { executions += 1 })
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 2, newEpoch: true)
        let future = try seal(repo, ordinal: 2)
        XCTAssertFalse(try repo.withCurrentPriority(identity) { executions += 1 })
        XCTAssertFalse(try repo.withCurrentFreshHead(current, priority: identity) { executions += 1 })
        XCTAssertFalse(try repo.withCurrentFreshHead(current, priority: nil) { executions += 1 })
        XCTAssertEqual(executions, 1)
        // Even if a later boundary/entry is visible beside an older selection,
        // an entry at/after explicit begin cannot be called a pre-existing task.
        try rewriteState { value in
            for key in ["capture", "priorityEpochID", "prioritySessionID", "priorityStartPosition", "priorityCursor"] {
                value[key] = currentState[key]
            }
        }
        XCTAssertTrue(try repo.isCurrentPriority(identity))
        XCTAssertFalse(try repo.canYieldToPriority(future, priority: identity))
        let entryURL = root.appendingPathComponent("fresh-transfer/" + future.id.uuidString.lowercased() + ".json")
        try FileManager.default.removeItem(at: entryURL)
        XCTAssertThrowsError(try repo.canYieldToPriority(future, priority: identity))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.audioURL(for: future).path))
    }

    func testSameSessionSegmentsBeforeTheCaptureBoundaryStayHistorical() throws {
        let repo = try repository()
        let history = try seal(repo, ordinal: 0, sequence: 0)
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 1, newEpoch: true)
        let fresh = try seal(repo, ordinal: 1, sequence: 1)
        XCTAssertFalse(try repo.isProtectedFreshSegment(history))
        XCTAssertTrue(try repo.isProtectedFreshSegment(fresh))
        XCTAssertEqual(try repo.freshTransferSnapshot().head, fresh)
        try repo.acknowledge(receipt(fresh))
        try repo.closePriorityCapture()
        XCTAssertFalse(try repo.freshTransferSnapshot().blocksHistory)
        XCTAssertEqual(try repo.pendingSegments(), [history])
    }

    func testAudioAndManifestCommitCrashesRecoverMembershipExactlyOnce() throws {
        for boundary in [RepositoryFaultPoint.afterAudioCommit, .afterManifestCommit] {
            let caseRoot = root.appendingPathComponent(UUID().uuidString)
            let broken = try RecordingRepository(root: caseRoot, faultInjector: { point in
                switch (point, boundary) {
                case (.afterAudioCommit, .afterAudioCommit), (.afterManifestCommit, .afterManifestCommit):
                    throw SimulatedCrash.interrupted
                default: break
                }
            })
            try broken.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
            XCTAssertThrowsError(try seal(broken, ordinal: 0))
            let reopened = try RecordingRepository(root: caseRoot)
            let first = try reopened.manifest(id: fixtureID(0))
            XCTAssertEqual(try reopened.freshTransferSnapshot().head, first)
            try reopened.recoverPendingTransactions()
            let second = try seal(reopened, ordinal: 1)
            XCTAssertEqual(try reopened.freshTransferSnapshot().remainingCount, 2)
            try reopened.acknowledge(receipt(first))
            XCTAssertEqual(try reopened.freshTransferSnapshot().head, second)
            try reopened.acknowledge(receipt(second))
            try reopened.closePriorityCapture()
            XCTAssertFalse(try reopened.freshTransferSnapshot().blocksHistory)
        }
    }

    func testFreshAppendFailureKeepsAudioAndWALUntilRestartRepairsTheSamePosition() throws {
        let broken = try repository(fault: { if case .afterFreshAppend = $0 { throw SimulatedCrash.interrupted } })
        try broken.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let first = try seal(broken, ordinal: 0)
        XCTAssertNotNil(broken.priorityCaptureWarning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.audioURL(for: first).path))
        XCTAssertThrowsError(try broken.freshTransferSnapshot())
        XCTAssertThrowsError(try broken.closePriorityCapture())
        let pending = root.appendingPathComponent("staging/" + first.id.uuidString.lowercased() + ".pending.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        let headless = try repository(recover: false)
        XCTAssertThrowsError(try headless.freshTransferSnapshot(),
                             "An extra durable log record without its committed count is not an empty FIFO")

        let reopened = try repository()
        XCTAssertNil(reopened.priorityCaptureWarning)
        XCTAssertEqual(try reopened.freshTransferSnapshot().head, first)
        XCTAssertEqual(try reopened.freshTransferSnapshot().remainingCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        let second = try seal(reopened, ordinal: 1)
        try reopened.acknowledge(receipt(first))
        XCTAssertEqual(try reopened.freshTransferSnapshot().head, second)
        XCTAssertEqual(try reopened.freshTransferSnapshot().remainingCount, 1)
    }

    func testAcknowledgedPrunedPendingTransactionDoesNotResurrectAudioOrDuplicateFIFO() throws {
        let broken = try repository(fault: { if case .afterManifestCommit = $0 { throw SimulatedCrash.interrupted } })
        try broken.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        XCTAssertThrowsError(try seal(broken, ordinal: 0))
        let first = try broken.manifest(id: fixtureID(0))
        try broken.acknowledge(receipt(first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.audioURL(for: first).path))

        let reopened = try repository()
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.audioURL(for: first).path))
        XCTAssertEqual(try reopened.freshTransferSnapshot().remainingCount, 0)
        let second = try seal(reopened, ordinal: 1)
        XCTAssertEqual(try reopened.freshTransferSnapshot().head, second)
        XCTAssertEqual(try reopened.freshTransferSnapshot().remainingCount, 1)
    }

    func testFailedHeadCommitAndRestartNeverSkipTheNextUnacknowledgedSegment() throws {
        for boundary in [RepositoryFaultPoint.beforeFreshHeadCommit, .afterFreshHeadCommit] {
            let caseRoot = root.appendingPathComponent(UUID().uuidString)
            let setup = try RecordingRepository(root: caseRoot)
            try setup.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
            let first = try seal(setup, ordinal: 0)
            let second = try seal(setup, ordinal: 1)
            try setup.closePriorityCapture()
            try setup.acknowledge(receipt(first))
            let broken = try RecordingRepository(root: caseRoot, faultInjector: { point in
                switch (point, boundary) {
                case (.beforeFreshHeadCommit, .beforeFreshHeadCommit), (.afterFreshHeadCommit, .afterFreshHeadCommit):
                    throw SimulatedCrash.interrupted
                default: break
                }
            }, recoverTransactionsOnInitialization: false)
            XCTAssertThrowsError(try broken.freshTransferSnapshot())
            let reopened = try RecordingRepository(root: caseRoot)
            XCTAssertEqual(try reopened.freshTransferSnapshot().head, second)
            XCTAssertFalse(try reopened.hasDurableAcknowledgement(for: second))
            XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: second).path))
        }
    }

    func testBoundedAcknowledgementScanDoesNotDeclareNineCompletedHeadsEmpty() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let values = try (0..<11).map { try seal(repo, ordinal: $0) }
        try repo.closePriorityCapture()
        for value in values { try repo.acknowledge(receipt(value)) }
        let firstPass = try repo.freshTransferSnapshot(acknowledgementLimit: 8)
        XCTAssertNil(firstPass.head)
        XCTAssertEqual(firstPass.remainingCount, 3)
        XCTAssertTrue(firstPass.needsAnotherPass)
        XCTAssertTrue(firstPass.blocksHistory)
        XCTAssertEqual(firstPass.checkedCount, 8)
        let secondPass = try repository().freshTransferSnapshot(acknowledgementLimit: 8)
        XCTAssertEqual(secondPass.remainingCount, 0)
        XCTAssertFalse(secondPass.needsAnotherPass)
        XCTAssertFalse(secondPass.blocksHistory)
        XCTAssertEqual(secondPass.checkedCount, 3)
    }

    func testZeroBudgetDoesNoHeadWorkAndLargeBudgetIsClampedToSixtyFour() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let values = try (0..<70).map { try seal(repo, ordinal: $0) }
        try repo.closePriorityCapture()
        for value in values { try repo.acknowledge(receipt(value)) }
        let zero = try repo.freshTransferSnapshot(acknowledgementLimit: 0)
        XCTAssertNil(zero.head)
        XCTAssertEqual(zero.remainingCount, 70)
        XCTAssertTrue(zero.needsAnotherPass)
        XCTAssertTrue(zero.blocksHistory)
        XCTAssertEqual(zero.checkedCount, 0)
        let large = try repo.freshTransferSnapshot(acknowledgementLimit: 100)
        XCTAssertEqual(large.remainingCount, 6)
        XCTAssertTrue(large.needsAnotherPass)
        XCTAssertEqual(large.checkedCount, 64)
    }

    func testMissingEntireQueueAfterInitializationIsNotAnEmptyLibrary() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let first = try seal(repo, ordinal: 0)
        try FileManager.default.removeItem(at: root.appendingPathComponent("fresh-transfer"))
        XCTAssertThrowsError(try repo.freshTransferSnapshot())
        let reopened = try repository(recover: false)
        XCTAssertThrowsError(try reopened.freshTransferSnapshot())
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: first).path))
        XCTAssertFalse(try reopened.hasDurableAcknowledgement(for: first))
    }

    func testCorruptSchedulingStateDoesNotMakeAudioRecoveryFatalOrPermitHistory() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let first = try seal(repo, ordinal: 0)
        try Data("not-json".utf8).write(to: stateURL)
        let reopened = try repository(recover: false)
        XCTAssertNoThrow(try reopened.recoverPendingTransactions())
        XCTAssertNotNil(reopened.priorityCaptureWarning)
        XCTAssertThrowsError(try reopened.freshTransferSnapshot())
        XCTAssertNoThrow(try repository())
        XCTAssertEqual(try reopened.manifest(id: first.id), first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: first).path))
    }

    func testTruncatedOrMalformedOrderLogRemainsUnknownAndPreservesSources() throws {
        for contents in [Data("torn".utf8), Data((String(repeating: "x", count: 36) + "\n").utf8)] {
            let caseRoot = root.appendingPathComponent(UUID().uuidString)
            let repo = try RecordingRepository(root: caseRoot)
            try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
            let first = try seal(repo, ordinal: 0)
            try contents.write(to: caseRoot.appendingPathComponent("fresh-transfer/order.ids"))
            XCTAssertThrowsError(try repo.freshTransferSnapshot())
            let reopened = try RecordingRepository(root: caseRoot, recoverTransactionsOnInitialization: false)
            XCTAssertThrowsError(try reopened.freshTransferSnapshot())
            XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: first).path))
            XCTAssertFalse(try reopened.hasDurableAcknowledgement(for: first))
        }
    }

    func testExtremeStoredCountIsRejectedWithoutArithmeticOverflow() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let first = try seal(repo, ordinal: 0)
        try rewriteState { $0["count"] = Int.max }
        XCTAssertThrowsError(try repo.freshTransferSnapshot())
        XCTAssertThrowsError(try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 1, newEpoch: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.audioURL(for: first).path))
    }

    func testLegacyFlatPendingManifestRecoversWithoutInventingFreshMembership() throws {
        let broken = try repository(fault: { if case .afterManifestCommit = $0 { throw SimulatedCrash.interrupted } })
        XCTAssertThrowsError(try seal(broken, ordinal: 0))
        let original = try broken.manifest(id: fixtureID(0))
        let pending = root.appendingPathComponent("staging/" + original.id.uuidString.lowercased() + ".pending.json")
        // This is the exact older disk representation, with no local priority fields.
        try TransportCodec.encode(original).write(to: pending)
        let reopened = try repository()
        XCTAssertEqual(try reopened.pendingSegments(), [original])
        XCTAssertFalse(try reopened.freshTransferSnapshot().blocksHistory)
        XCTAssertFalse(try reopened.isProtectedFreshSegment(original))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: original).path))
    }

    func testCloseFailuresRemainExplicitlyBlockedAcrossRestartWithoutAudioTransactionRepairProof() throws {
        for boundary in [RepositoryFaultPoint.beforeFreshCloseCommit, .afterFreshCloseCommit] {
            let caseRoot = root.appendingPathComponent(UUID().uuidString)
            let setup = try RecordingRepository(root: caseRoot)
            try setup.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
            let first = try seal(setup, ordinal: 0)
            try setup.acknowledge(receipt(first), pruneAudio: false)
            XCTAssertEqual(try setup.freshTransferSnapshot().remainingCount, 0)
            let broken = try RecordingRepository(root: caseRoot, faultInjector: { point in
                switch (point, boundary) {
                case (.beforeFreshCloseCommit, .beforeFreshCloseCommit), (.afterFreshCloseCommit, .afterFreshCloseCommit):
                    throw SimulatedCrash.interrupted
                default: break
                }
            }, recoverTransactionsOnInitialization: false)
            XCTAssertThrowsError(try broken.closePriorityCapture())
            XCTAssertNotNil(broken.priorityCaptureWarning)
            XCTAssertThrowsError(try broken.freshTransferSnapshot(), "A failed close must not immediately permit history")

            let headless = try RecordingRepository(root: caseRoot, recoverTransactionsOnInitialization: false)
            XCTAssertThrowsError(try headless.freshTransferSnapshot())
            let reopened = try RecordingRepository(root: caseRoot)
            XCTAssertThrowsError(try reopened.freshTransferSnapshot())
            XCTAssertNotNil(reopened.priorityCaptureWarning)
            XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: first).path))
            XCTAssertTrue(try reopened.hasDurableAcknowledgement(for: first))
            // Without an exact repairing transaction, an unknown close remains
            // explicit and conservative instead of treating no pending as empty.
            try reopened.recoverPendingTransactions()
            XCTAssertThrowsError(try reopened.freshTransferSnapshot())
        }
    }

    func testFailedCaptureBoundaryCommitPreservesAudioAndNeverSilentlyFallsBackToHistory() throws {
        let setup = try repository()
        try setup.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        try setup.closePriorityCapture()
        let broken = try repository(fault: { if case .beforeFreshCaptureCommit = $0 { throw SimulatedCrash.interrupted } })
        XCTAssertThrowsError(try broken.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true))
        XCTAssertNotNil(broken.priorityCaptureWarning)
        let value = try seal(broken, ordinal: 0)
        XCTAssertEqual(try broken.manifest(id: value.id), value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.audioURL(for: value).path))
        XCTAssertThrowsError(try broken.freshTransferSnapshot())
        XCTAssertThrowsError(try broken.closePriorityCapture())

        let reopened = try repository()
        XCTAssertNotNil(reopened.priorityCaptureWarning)
        XCTAssertThrowsError(try reopened.freshTransferSnapshot())
        XCTAssertFalse(try reopened.hasDurableAcknowledgement(for: value))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: value).path))
    }

    func testTailFromEarlierSessionKeepsItsFreshMembershipWhenSealedAfterSessionRecovery() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let first = try seal(repo, ordinal: 0)
        let earlierEpoch = try XCTUnwrap(repo.freshTransferSnapshot().headEpochID)
        let recoveredSession = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        try repo.beginPriorityCapture(sessionID: recoveredSession, nextSequence: 0, newEpoch: false)
        let current = try seal(repo, ordinal: 2, session: recoveredSession, sequence: 0)
        // This old-session tail had not yet entered commitAudio when recovery
        // moved capture to another session. Its durable boundary must survive.
        let delayedTail = try seal(repo, ordinal: 1, sequence: 1)
        try repo.closePriorityCapture()
        XCTAssertTrue(try repo.isProtectedFreshSegment(delayedTail))
        for expected in [first, current, delayedTail] {
            let reopened = try repository()
            let snapshot = try reopened.freshTransferSnapshot()
            XCTAssertEqual(snapshot.head, expected, "A late tail joins by seal order without becoming history")
            XCTAssertEqual(snapshot.headEpochID, earlierEpoch)
            try reopened.acknowledge(receipt(expected))
        }
        XCTAssertFalse(try repository().freshTransferSnapshot().blocksHistory)
    }

    func testFailureBeforeFreshAppendIsRecoveredWithoutLosingOrDuplicatingTheSegment() throws {
        let broken = try repository(fault: { if case .beforeFreshAppend = $0 { throw SimulatedCrash.interrupted } })
        try broken.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let value = try seal(broken, ordinal: 0)
        XCTAssertNotNil(broken.priorityCaptureWarning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.audioURL(for: value).path))
        XCTAssertThrowsError(try broken.freshTransferSnapshot())
        let reopened = try repository()
        XCTAssertEqual(try reopened.freshTransferSnapshot().head, value)
        XCTAssertEqual(try reopened.freshTransferSnapshot().remainingCount, 1)
        try reopened.recoverPendingTransactions()
        XCTAssertEqual(try reopened.freshTransferSnapshot().remainingCount, 1)
        try reopened.acknowledge(receipt(value))
        try reopened.closePriorityCapture()
        XCTAssertFalse(try reopened.freshTransferSnapshot().blocksHistory)
    }

    func testMissingArchivedSessionBoundaryCannotSilentlyReclassifyItsLateTailAsHistory() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        _ = try seal(repo, ordinal: 0)
        let newSession = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        try repo.beginPriorityCapture(sessionID: newSession, nextSequence: 0, newEpoch: false)
        _ = try seal(repo, ordinal: 2, session: newSession, sequence: 0)
        let missingBoundary = root.appendingPathComponent("fresh-transfer/session-" + sessionID.uuidString.lowercased() + ".json")
        try FileManager.default.removeItem(at: missingBoundary)
        let tail = try seal(repo, ordinal: 1, sequence: 1)
        XCTAssertEqual(try repo.manifest(id: tail.id), tail, "A scheduling fault must not discard captured audio")
        XCTAssertNotNil(repo.priorityCaptureWarning)
        XCTAssertThrowsError(try repo.freshTransferSnapshot())
        XCTAssertThrowsError(try repo.closePriorityCapture())
        let reopened = try repository()
        XCTAssertThrowsError(try reopened.freshTransferSnapshot())
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: tail).path))
        XCTAssertFalse(try reopened.hasDurableAcknowledgement(for: tail))
    }

    func testUnsealedFreshTailStillBlocksHistoryAfterNewSessionIsAcknowledgedAndClosedAcrossRestart() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let oldDraft = OpenAudioSegment(id: fixtureID(1), sessionID: sessionID, sequence: 0,
            startedAt: start, sampleRate: 16_000, channelCount: 1, pcmFormat: .int16,
            interleaved: true, timeZoneIdentifier: nil)
        try repo.beginAudioSegment(oldDraft)
        let original = Data(repeating: 31, count: 258)
        try original.write(to: repo.stagingURL(for: oldDraft.id))

        let newSession = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        try repo.beginPriorityCapture(sessionID: newSession, nextSequence: 0, newEpoch: true)
        let newer = try seal(repo, ordinal: 2, session: newSession, sequence: 0)
        try repo.acknowledge(receipt(newer))
        try repo.closePriorityCapture()
        for observed in [try repo.freshTransferSnapshot(), try repository().freshTransferSnapshot()] {
            XCTAssertNil(observed.head)
            XCTAssertEqual(observed.remainingCount, 0)
            XCTAssertFalse(observed.captureOpen)
            XCTAssertEqual(observed.unresolvedOpenCount, 1)
            XCTAssertTrue(observed.blocksHistory, "A preserved fresh raw tail must survive a later capture close")
        }

        let reopened = try repository()
        XCTAssertEqual(try Data(contentsOf: reopened.stagingURL(for: oldDraft.id)), original)
        let oldTail = try reopened.sealSegment(stagedURL: reopened.stagingURL(for: oldDraft.id),
            id: oldDraft.id, sessionID: sessionID, sequence: 0, startedAt: start,
            endedAt: start.addingTimeInterval(60), sampleRate: 16_000, frameCount: 960_000)
        let committed = try reopened.freshTransferSnapshot()
        XCTAssertEqual(committed.head, oldTail, "A recovered tail joins after segments already sealed")
        XCTAssertEqual(committed.remainingCount, 1)
        XCTAssertEqual(committed.unresolvedOpenCount, 0)
        XCTAssertTrue(committed.blocksHistory)
        try reopened.completeAudioSegment(oldDraft, justCommitted: oldTail)
        try reopened.acknowledge(receipt(oldTail))
        XCTAssertFalse(try repository().freshTransferSnapshot().blocksHistory)
    }

    func testFailedCaptureBoundaryCannotReleaseUnsealedFreshAudioAfterRestart() throws {
        let setup = try repository()
        try setup.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        try setup.closePriorityCapture()
        let newSession = UUID(uuidString: "60000000-0000-0000-0000-000000000006")!
        let broken = try repository(fault: { if case .beforeFreshCaptureCommit = $0 { throw SimulatedCrash.interrupted } })
        XCTAssertThrowsError(try broken.beginPriorityCapture(sessionID: newSession, nextSequence: 0, newEpoch: true))
        let draft = OpenAudioSegment(id: fixtureID(3), sessionID: newSession, sequence: 0,
            startedAt: start, sampleRate: 16_000, channelCount: 1, pcmFormat: .int16,
            interleaved: true, timeZoneIdentifier: nil)
        try broken.beginAudioSegment(draft)
        let original = Data(repeating: 41, count: 260)
        try original.write(to: broken.stagingURL(for: draft.id))
        XCTAssertThrowsError(try broken.freshTransferSnapshot())

        let headless = try repository(recover: false)
        XCTAssertThrowsError(try headless.freshTransferSnapshot(), "A WC-only launch has no writer to repair this state")

        let reopened = try repository()
        XCTAssertEqual(try Data(contentsOf: reopened.stagingURL(for: draft.id)), original)
        do {
            let observed = try reopened.freshTransferSnapshot()
            XCTAssertTrue(observed.blocksHistory, "Restart cannot clear a failed capture boundary while its raw audio remains")
        } catch {
            // An explicitly unknown state is a valid fail-closed result.
            XCTAssertNotNil(reopened.priorityCaptureWarning)
        }
        let value = try reopened.sealSegment(stagedURL: reopened.stagingURL(for: draft.id),
            id: draft.id, sessionID: newSession, sequence: 0, startedAt: start,
            endedAt: start.addingTimeInterval(60), sampleRate: 16_000, frameCount: 960_000)
        XCTAssertEqual(try reopened.manifest(id: value.id), value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: value).path))
        do {
            let observed = try reopened.freshTransferSnapshot()
            XCTAssertEqual(observed.head, value, "If recovered, this manifest must retain fresh membership")
            XCTAssertTrue(observed.blocksHistory)
        } catch {
            XCTAssertNotNil(reopened.priorityCaptureWarning)
        }
    }

    func testMaintenanceRevocationStopsBeforeAnotherFreshHeadReadAndAccountsCompletedChecks() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let values = try (0..<5).map { try seal(repo, ordinal: $0) }
        for value in values { try repo.acknowledge(receipt(value)) }
        try repo.closePriorityCapture()
        var grants = 0
        let revoked = try repo.freshTransferSnapshot(while: {
            grants += 1
            return grants <= 2
        })
        XCTAssertEqual(revoked.checkedCount, 2)
        XCTAssertEqual(revoked.remainingCount, 3)
        XCTAssertNil(revoked.head)
        XCTAssertTrue(revoked.needsAnotherPass)
        XCTAssertTrue(revoked.blocksHistory)
        XCTAssertFalse(try repository().freshTransferSnapshot().blocksHistory)
    }

    func testJournalDurableBeforeOpenGateCrashCannotLoseFreshRawTailDuringLaterSession() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let draft = OpenAudioSegment(id: fixtureID(4), sessionID: sessionID, sequence: 0,
            startedAt: start, sampleRate: 16_000, channelCount: 1, pcmFormat: .int16,
            interleaved: true, timeZoneIdentifier: nil)
        try repo.beginAudioSegment(draft)
        let original = Data(repeating: 51, count: 261)
        try original.write(to: repo.stagingURL(for: draft.id))
        // Emulate termination after the identity journal became durable but
        // before the separate fresh scheduling gate committed.
        try rewriteState { $0["openSegmentIDs"] = [] }

        let reopened = try repository()
        reopened.registerPriorityOpenSegmentForRecovery(draft)
        let newSession = UUID(uuidString: "70000000-0000-0000-0000-000000000007")!
        try reopened.beginPriorityCapture(sessionID: newSession, nextSequence: 0, newEpoch: false)
        let newer = try seal(reopened, ordinal: 5, session: newSession, sequence: 0)
        try reopened.acknowledge(receipt(newer))
        try reopened.closePriorityCapture()
        let observed = try reopened.freshTransferSnapshot()
        XCTAssertNil(observed.head)
        XCTAssertEqual(observed.remainingCount, 0)
        XCTAssertEqual(observed.unresolvedOpenCount, 1)
        XCTAssertTrue(observed.blocksHistory)
        XCTAssertEqual(try Data(contentsOf: reopened.stagingURL(for: draft.id)), original)
        XCTAssertTrue(try repository().freshTransferSnapshot().blocksHistory)
    }

    func testCommittedJournalRecoveryAndRepeatedCompletionCannotLeavePermanentOpenGate() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let draft = OpenAudioSegment(id: fixtureID(6), sessionID: sessionID, sequence: 0,
            startedAt: start, sampleRate: 16_000, channelCount: 1, pcmFormat: .int16,
            interleaved: true, timeZoneIdentifier: nil)
        try repo.beginAudioSegment(draft)
        try Data(repeating: 61, count: 263).write(to: repo.stagingURL(for: draft.id))
        let value = try repo.sealSegment(stagedURL: repo.stagingURL(for: draft.id),
            id: draft.id, sessionID: sessionID, sequence: 0, startedAt: start,
            endedAt: start.addingTimeInterval(60), sampleRate: 16_000, frameCount: 960_000)
        // The exact manifest committed but the audio writer was interrupted
        // before completing/removing its open identity journal.
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.openSegmentURL(for: draft.id).path))
        try repo.acknowledge(receipt(value), pruneAudio: true)
        try repo.closePriorityCapture()
        XCTAssertFalse(try repo.freshTransferSnapshot().blocksHistory)

        let reopened = try repository()
        reopened.registerPriorityOpenSegmentForRecovery(draft)
        XCTAssertEqual(try reopened.freshTransferSnapshot().unresolvedOpenCount, 1)
        XCTAssertEqual(try reopened.committedAudioSegment(for: draft), value)
        try reopened.completeAudioSegment(draft)
        try reopened.completeAudioSegment(draft)
        let complete = try reopened.freshTransferSnapshot()
        XCTAssertEqual(complete.unresolvedOpenCount, 0)
        XCTAssertFalse(complete.blocksHistory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.openSegmentURL(for: draft.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.audioURL(for: value).path))
        let restartedAgain = try repository()
        try restartedAgain.completeAudioSegment(draft)
        XCTAssertFalse(try restartedAgain.freshTransferSnapshot().blocksHistory)
    }

    func testEmptyArchivedBoundaryForUnsealedTailIsUnknownRatherThanHistorical() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let draft = OpenAudioSegment(id: fixtureID(7), sessionID: sessionID, sequence: 0,
            startedAt: start, sampleRate: 16_000, channelCount: 1, pcmFormat: .int16,
            interleaved: true, timeZoneIdentifier: nil)
        try repo.beginAudioSegment(draft)
        let original = Data(repeating: 71, count: 264)
        try original.write(to: repo.stagingURL(for: draft.id))
        let newSession = UUID(uuidString: "80000000-0000-0000-0000-000000000008")!
        try repo.beginPriorityCapture(sessionID: newSession, nextSequence: 0, newEpoch: false)
        try repo.closePriorityCapture()
        // A recovery must rebuild the missing scheduling hint from the raw
        // journal. An empty but valid JSON archive supplies no usable boundary.
        try rewriteState { $0["openSegmentIDs"] = [] }
        let boundaryURL = root.appendingPathComponent("fresh-transfer/session-" + sessionID.uuidString.lowercased() + ".json")
        try Data("[]".utf8).write(to: boundaryURL)

        let reopened = try repository()
        reopened.registerPriorityOpenSegmentForRecovery(draft)
        XCTAssertNotNil(reopened.priorityCaptureWarning)
        XCTAssertThrowsError(try reopened.freshTransferSnapshot())
        XCTAssertThrowsError(try reopened.closePriorityCapture())
        XCTAssertEqual(try Data(contentsOf: reopened.stagingURL(for: draft.id)), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.openSegmentURL(for: draft.id).path))
        XCTAssertThrowsError(try repository(recover: false).freshTransferSnapshot())
    }
    func testThreeMemberPipelinePreservesSealOrderAndAcknowledgementHolesAcrossRestart() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let values = try (0..<7).map { try seal(repo, ordinal: $0) }
        try repo.closePriorityCapture()
        let first = try repo.freshTransferSnapshot(maximumAdmissions: 3)
        XCTAssertEqual(first.admissions.map(\.manifest), Array(values.prefix(3)))
        XCTAssertEqual(first.admissions.map(\.position), [0, 1, 2])
        try repo.acknowledge(receipt(values[2]), pruneAudio: true)
        let reopened = try repository()
        let second = try reopened.freshTransferSnapshot(maximumAdmissions: 3)
        XCTAssertEqual(second.head, values[0])
        XCTAssertEqual(second.remainingCount, 7)
        XCTAssertEqual(second.admissions.map(\.manifest), [values[0], values[1], values[3]])
        XCTAssertEqual(second.admissions.map(\.position), [0, 1, 3])
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: values[0]).path))
        try reopened.acknowledge(receipt(values[0]), pruneAudio: true)
        let next = try repository().freshTransferSnapshot(maximumAdmissions: 3)
        XCTAssertEqual(next.head, values[1])
        XCTAssertEqual(next.admissions.map(\.manifest), [values[1], values[3], values[4]])
    }

    func testPipelineSharesEightChecksWithAckPrefixAndClampsExpandedWindowToTwelve() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let values = try (0..<22).map { try seal(repo, ordinal: $0) }
        for value in values.prefix(7) { try repo.acknowledge(receipt(value), pruneAudio: true) }
        var checked = 0
        let limited = try repo.freshTransferSnapshot(acknowledgementLimit: 8, maximumAdmissions: 100,
                                                    onCandidateCheck: { checked += 1 })
        XCTAssertEqual(checked, 8)
        XCTAssertEqual(limited.checkedCount, 8)
        XCTAssertEqual(limited.admissions.map(\.manifest), [values[7]])
        let defaultBudget = try repo.freshTransferSnapshot(maximumAdmissions: 100)
        XCTAssertEqual(defaultBudget.admissions.count, 8)
        let full = try repo.freshTransferSnapshot(acknowledgementLimit: 100, maximumAdmissions: 100)
        XCTAssertEqual(full.admissions.map(\.manifest), Array(values[7..<19]))
        XCTAssertEqual(full.checkedCount, 12)
    }

    func testPipelineDoesNotMixEarlierEpochAndAdmissionIsRevokedByExplicitResume() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let old = try seal(repo, ordinal: 0)
        try repo.closePriorityCapture()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 1, newEpoch: true)
        let current = try (1..<5).map { try seal(repo, ordinal: $0) }
        let window = try repo.freshTransferSnapshot(maximumAdmissions: 3)
        XCTAssertEqual(window.admissions.map(\.manifest), Array(current.prefix(3)))
        var calls = 0
        XCTAssertTrue(try repo.withCurrentFreshAdmission(window.admissions[1], head: current[0],
                                                        priority: window.priorityIdentity) { calls += 1 })
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 5, newEpoch: true)
        XCTAssertFalse(try repo.withCurrentFreshAdmission(window.admissions[2], head: current[0],
                                                         priority: window.priorityIdentity) { calls += 1 })
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.audioURL(for: old).path))
        XCTAssertFalse(try repo.hasDurableAcknowledgement(for: old))
    }

    func testPipelineAdmissionRejectsReceiptArrivingAfterSelection() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let values = try (0..<3).map { try seal(repo, ordinal: $0) }
        let window = try repo.freshTransferSnapshot(maximumAdmissions: 3)
        try repo.acknowledge(receipt(values[1]), pruneAudio: true)
        var called = false
        XCTAssertFalse(try repo.withCurrentFreshAdmission(window.admissions[1], head: values[0],
                                                         priority: window.priorityIdentity) { called = true })
        XCTAssertFalse(called)
        XCTAssertEqual(try repo.freshTransferSnapshot().head, values[0])
    }

    func testDamagedLookaheadCannotBlockVerifiedHeadOrSkipDamagedEntry() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let values = try (0..<3).map { try seal(repo, ordinal: $0) }
        let entry = root.appendingPathComponent("fresh-transfer/" + values[1].id.uuidString.lowercased() + ".json")
        try Data("broken lookahead".utf8).write(to: entry)
        let observed = try repo.freshTransferSnapshot(maximumAdmissions: 3)
        XCTAssertEqual(observed.head, values[0])
        XCTAssertEqual(observed.admissions.map(\.manifest), [values[0]])
        XCTAssertEqual(observed.checkedCount, 2)
        try repo.acknowledge(receipt(values[0]), pruneAudio: true)
        XCTAssertThrowsError(try repo.freshTransferSnapshot(maximumAdmissions: 3))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.audioURL(for: values[1]).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.audioURL(for: values[2]).path))
    }

    func testLongHeadAcknowledgementHoleRemainsExplicitlyBoundedWithoutSkippingAudio() throws {
        let repo = try repository()
        try repo.beginPriorityCapture(sessionID: sessionID, nextSequence: 0, newEpoch: true)
        let values = try (0..<12).map { try seal(repo, ordinal: $0) }
        try repo.closePriorityCapture()
        // Later members can finish before the first receipt. The local scan
        // budget must remain finite even if that leaves a long-lived head hole.
        for value in values[1...7] { try repo.acknowledge(receipt(value), pruneAudio: true) }
        for _ in 0..<3 {
            let observed = try repository().freshTransferSnapshot(maximumAdmissions: 3)
            XCTAssertEqual(observed.head, values[0])
            XCTAssertEqual(observed.admissions.map(\.manifest), [values[0]])
            XCTAssertEqual(observed.checkedCount, 8)
            XCTAssertEqual(observed.remainingCount, 12)
            XCTAssertTrue(observed.needsAnotherPass)
            XCTAssertTrue(observed.blocksHistory)
            XCTAssertTrue(FileManager.default.fileExists(atPath: repo.audioURL(for: values[0]).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: repo.audioURL(for: values[8]).path))
        }
        try repo.acknowledge(receipt(values[0]), pruneAudio: true)
        let prefix = try repo.freshTransferSnapshot(maximumAdmissions: 3)
        XCTAssertNil(prefix.head, "The eight confirmed prefix members consume this pass before candidate nine.")
        XCTAssertTrue(prefix.admissions.isEmpty)
        XCTAssertEqual(prefix.checkedCount, 8)
        XCTAssertEqual(prefix.remainingCount, 4)
        XCTAssertTrue(prefix.needsAnotherPass)
        XCTAssertTrue(prefix.blocksHistory, "An exhausted budget is never proof of an empty queue.")
        let expanded = try repository().freshTransferSnapshot(maximumAdmissions: 3)
        XCTAssertEqual(expanded.admissions.map(\.manifest), [values[8], values[9], values[10]])
        XCTAssertEqual(expanded.checkedCount, 3)
        XCTAssertFalse(expanded.needsAnotherPass)
    }

}
