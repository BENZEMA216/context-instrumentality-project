import XCTest
@testable import RecordingCore

final class PhoneReceiptMaintenancePolicyTests: XCTestCase {
    func testHistoryDiscoveryDebounceExpiresAndExplicitRecoveryOrClockRollbackCanBypass() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(PhoneReceiptMaintenancePolicy.shouldDiscoverHistory(lastStartedAt: nil, now: start))
        XCTAssertFalse(PhoneReceiptMaintenancePolicy.shouldDiscoverHistory(lastStartedAt: start, now: start))
        XCTAssertFalse(PhoneReceiptMaintenancePolicy.shouldDiscoverHistory(lastStartedAt: start,
            now: start.addingTimeInterval(299)))
        XCTAssertTrue(PhoneReceiptMaintenancePolicy.shouldDiscoverHistory(lastStartedAt: start,
            now: start.addingTimeInterval(300)))
        XCTAssertTrue(PhoneReceiptMaintenancePolicy.shouldDiscoverHistory(lastStartedAt: start, now: start, forced: true))
        XCTAssertTrue(PhoneReceiptMaintenancePolicy.shouldDiscoverHistory(lastStartedAt: start,
            now: start.addingTimeInterval(-1)))
    }

    private func request(id: UUID = UUID(), hash: String = String(repeating: "a", count: 64),
                         bytes: Int64 = 100) throws -> TargetedReceiptRequest {
        try TargetedReceiptRequest(segmentID: id, sha256: hash, byteCount: bytes)
    }

    func testInvalidTargetedFieldNeverFallsBackToLegacyReplay() throws {
        for data in [nil, Data("invalid JSON".utf8), Data("{}".utf8)] {
            XCTAssertEqual(PhoneReceiptMaintenancePolicy.request(targetedKeyPresent: true,
                targetedData: data, legacyRequested: true), .invalidTargeted)
        }
        let valid = try request()
        let data = try TransportCodec.encode(valid)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 2
        XCTAssertEqual(PhoneReceiptMaintenancePolicy.request(targetedKeyPresent: true,
            targetedData: try JSONSerialization.data(withJSONObject: object), legacyRequested: true), .invalidTargeted)
        XCTAssertEqual(PhoneReceiptMaintenancePolicy.request(targetedKeyPresent: true,
            targetedData: data, legacyRequested: true), .targeted(valid))
        XCTAssertEqual(PhoneReceiptMaintenancePolicy.request(targetedKeyPresent: false,
            targetedData: nil, legacyRequested: true), .legacy)
        XCTAssertEqual(PhoneReceiptMaintenancePolicy.request(targetedKeyPresent: false,
            targetedData: nil, legacyRequested: false), .none)
    }

    func testOneLeaseSharesEightAttemptsAcrossCallbacksAndExactHistory() throws {
        var policy = PhoneReceiptMaintenancePolicy()
        let exact = try request()
        policy.requestHistory(limit: 8, generation: 4)
        XCTAssertTrue(policy.beginTargetedAttempt(for: exact, generation: 4))
        for _ in 0..<7 {
            // A callback/trigger repeats the existing lease, not a new grant.
            policy.requestHistory(limit: 8, generation: 4)
            XCTAssertFalse(policy.beginTargetedAttempt(for: exact, generation: 4))
            XCTAssertTrue(policy.beginHistoricalAttempt(generation: 4))
        }
        for _ in 0..<20 {
            policy.requestHistory(limit: 8, generation: 4)
            XCTAssertFalse(policy.beginHistoricalAttempt(generation: 4))
            XCTAssertFalse(policy.beginTargetedAttempt(for: try request(), generation: 4))
        }
        XCTAssertEqual(policy.verificationAttempts, 8)
        XCTAssertEqual(policy.targetedAttempts, 1)
        XCTAssertEqual(policy.historicalAttempts, 7)
        policy.beginLease(generation: 3)
        XCTAssertEqual(policy.verificationAttempts, 8)
        XCTAssertFalse(policy.beginHistoricalAttempt(generation: 3), "An old asynchronous callback cannot borrow the new lease.")
    }

    func testExactArrivingAfterHistoricalBudgetExhaustionWaitsForNextLease() throws {
        var policy = PhoneReceiptMaintenancePolicy()
        policy.requestHistory(limit: 8, generation: 0)
        for _ in 0..<8 { XCTAssertTrue(policy.beginHistoricalAttempt(generation: 0)) }
        let pending = [try request()]
        XCTAssertFalse(policy.beginTargetedAttempt(for: pending[0], generation: 0))
        // Admission failure leaves the pending request intact across a process
        // boundary; a new grant then handles it before spending history budget.
        let restored = try TransportCodec.decode([TargetedReceiptRequest].self,
            from: TransportCodec.encode(pending))
        policy.requestHistory(limit: 8, generation: 1)
        XCTAssertTrue(policy.beginTargetedAttempt(for: restored[0], generation: 1))
        XCTAssertEqual(policy.targetedAttempts, 1)
        XCTAssertEqual(policy.historicalAttempts, 0)
    }

    func testRepeatedTargetOnlyRequestsKeepOneHistoryStepAndLegacyRaisesOnlyTheRemainder() throws {
        var policy = PhoneReceiptMaintenancePolicy()
        let exact = try request()
        policy.requestHistory(limit: 1, generation: 0)
        XCTAssertTrue(policy.beginTargetedAttempt(for: exact, generation: 0))
        XCTAssertTrue(policy.beginHistoricalAttempt(generation: 0))
        for _ in 0..<20 {
            policy.requestHistory(limit: 1, generation: 0)
            XCTAssertFalse(policy.beginHistoricalAttempt(generation: 0))
            XCTAssertFalse(policy.beginTargetedAttempt(for: exact, generation: 0))
        }
        XCTAssertEqual(policy.verificationAttempts, 2)
        policy.requestHistory(limit: 8, generation: 0)
        for _ in 0..<6 { XCTAssertTrue(policy.beginHistoricalAttempt(generation: 0)) }
        XCTAssertFalse(policy.beginHistoricalAttempt(generation: 0))
        XCTAssertEqual(policy.verificationAttempts, 8)
        XCTAssertEqual(policy.historicalAttempts, 7)
        policy.requestHistory(limit: 1, generation: 0)
        XCTAssertEqual(policy.historicalLimit, 8, "A later targeted callback cannot shrink or reset a lease already serving legacy work.")
        policy.beginLease(generation: 1)
        XCTAssertEqual(policy.historicalLimit, 0, "An incoming-only grant does not inherit historical work authorization.")
    }

    func testContinuousTargetOnlyLeasesAdvanceHistoryPastBadItemsAndAcrossRestart() throws {
        let ids = (1...5).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        let exact = try request()
        var pending: [UUID] = [], cursor: UUID?, attempted: [UUID] = [], failed: [UUID] = []
        for _ in 0..<12 {
            var restarted = PhoneReceiptMaintenancePolicy()
            restarted.requestHistory(limit: 1, generation: 0)
            XCTAssertTrue(restarted.beginTargetedAttempt(for: exact, generation: 0))
            if pending.isEmpty { pending = ReceiptReplayPolicy.orderedIDs(ids, after: cursor) }
            XCTAssertTrue(restarted.beginHistoricalAttempt(generation: 0))
            let id = pending.removeFirst()
            attempted.append(id)
            // A bad historical file spends its step; it cannot block the tail.
            do {
                if id == ids[1] { throw RepositoryError.missingAudio }
            } catch { failed.append(id) }
            cursor = id
            restarted.requestHistory(limit: 1, generation: 0)
            XCTAssertFalse(restarted.beginHistoricalAttempt(generation: 0))
            XCTAssertEqual(restarted.verificationAttempts, 2)
            pending = try TransportCodec.decode([UUID].self, from: TransportCodec.encode(pending))
            cursor = try TransportCodec.decode(UUID.self, from: TransportCodec.encode(XCTUnwrap(cursor)))
        }
        XCTAssertEqual(attempted, ids + ids + Array(ids.prefix(2)))
        XCTAssertEqual(failed, [ids[1], ids[1], ids[1]])
        XCTAssertEqual(pending, Array(ids.suffix(3)))
        XCTAssertEqual(cursor, ids[1])
    }

    func testMissingOrFailedAttemptsCannotRefundBudgetAndHistoryHasAFairTurn() throws {
        var policy = PhoneReceiptMaintenancePolicy()
        policy.requestHistory(limit: 8, generation: 0)
        XCTAssertTrue(policy.beginTargetedAttempt(for: try request(), generation: 0))
        XCTAssertThrowsError(try PhoneReceiptMaintenancePolicy.verifiedReceipt(for: request()) { _ in
            throw RepositoryError.missingAudio
        })
        // A burst of new exact identities still leaves the shared remainder for history.
        for _ in 0..<40 {
            XCTAssertFalse(policy.beginTargetedAttempt(for: try request(), generation: 0))
        }
        var attempts = 0
        while policy.beginHistoricalAttempt(generation: 0) { attempts += 1 }
        XCTAssertEqual(attempts, 7)
        XCTAssertEqual(policy.verificationAttempts, 8)
        policy.requestHistory(limit: 8, generation: 1)
        XCTAssertTrue(policy.beginTargetedAttempt(for: try request(), generation: 1))
        XCTAssertEqual(policy.verificationAttempts, 1)
    }

    func testPureHistoricalSweepResumesPersistedPendingAcrossLeasesAndRestart() throws {
        let ids = (1...19).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        var pending = ReceiptReplayPolicy.orderedIDs(ids, after: nil)
        var attempted: [UUID] = []
        var cursor: UUID?
        var policy = PhoneReceiptMaintenancePolicy()
        for generation in 0..<3 {
            policy.requestHistory(limit: 8, generation: generation)
            var inLease = 0
            while !pending.isEmpty && policy.beginHistoricalAttempt(generation: generation) {
                let id = pending.removeFirst()
                attempted.append(id)
                cursor = id // Failed candidates also progress; success is not claimed.
                inLease += 1
            }
            XCTAssertEqual(inLease, generation < 2 ? 8 : 3)
            pending = try TransportCodec.decode([UUID].self, from: TransportCodec.encode(pending))
            cursor = try TransportCodec.decode(UUID.self, from: TransportCodec.encode(XCTUnwrap(cursor)))
            policy = PhoneReceiptMaintenancePolicy() // Simulated process restart; durable pending remains.
        }
        XCTAssertEqual(attempted, ids)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(cursor, ids.last)
    }

    func testTargetedVerificationUsesOnlyExactIDAndMatchesAllIdentityFields() throws {
        let exact = try request()
        let receipt = SegmentReceipt(segmentID: exact.segmentID, sha256: exact.sha256, byteCount: exact.byteCount)
        var lookedUp: [UUID] = []
        XCTAssertEqual(try PhoneReceiptMaintenancePolicy.verifiedReceipt(for: exact) {
            lookedUp.append($0); return receipt
        }, receipt)
        XCTAssertEqual(lookedUp, [exact.segmentID])
        for mismatch in [
            SegmentReceipt(segmentID: UUID(), sha256: exact.sha256, byteCount: exact.byteCount),
            SegmentReceipt(segmentID: exact.segmentID, sha256: String(repeating: "b", count: 64), byteCount: exact.byteCount),
            SegmentReceipt(segmentID: exact.segmentID, sha256: exact.sha256, byteCount: exact.byteCount + 1)
        ] {
            XCTAssertThrowsError(try PhoneReceiptMaintenancePolicy.verifiedReceipt(for: exact) { _ in mismatch }) {
                XCTAssertEqual($0 as? RepositoryError, .receiptMismatch)
            }
        }
    }

    func testExactRepositoryPathDoesNotTouchCorruptUnrelatedHistoryOrCreateMissingReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let watch = try RecordingRepository(root: root.appendingPathComponent("watch"))
        let phone = try RecordingRepository(root: root.appendingPathComponent("phone"))
        func seal() throws -> SegmentManifest {
            let id = UUID()
            let staging = watch.stagingURL(for: id)
            try Data(repeating: 42, count: 8192).write(to: staging)
            return try watch.sealSegment(stagedURL: staging, id: id, sessionID: UUID(), sequence: 0,
                startedAt: Date(timeIntervalSince1970: 1800000000), endedAt: Date(timeIntervalSince1970: 1800000060),
                sampleRate: 16000, frameCount: 960000)
        }
        let target = try seal(), unrelated = try seal()
        let receipt = try phone.acceptIncomingFile(at: watch.audioURL(for: target), manifest: target)
        _ = try phone.acceptIncomingFile(at: watch.audioURL(for: unrelated), manifest: unrelated)
        try Data(repeating: 7, count: 8192).write(to: phone.audioURL(for: unrelated))
        let exact = try TargetedReceiptRequest(manifest: target)
        XCTAssertEqual(try PhoneReceiptMaintenancePolicy.verifiedReceipt(for: exact) {
            try phone.verifiedReceipt(for: $0)
        }, receipt)
        let missing = try request()
        let missingURL = phone.root.appendingPathComponent("receipts/\(missing.segmentID.uuidString.lowercased()).json")
        XCTAssertThrowsError(try PhoneReceiptMaintenancePolicy.verifiedReceipt(for: missing) {
            try phone.verifiedReceipt(for: $0)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
        XCTAssertEqual(try watch.pendingSegments().count, 2, "Phone verification alone cannot acknowledge or prune Watch copies.")
        XCTAssertThrowsError(try phone.verifiedReceipt(for: unrelated.id))
    }
}
