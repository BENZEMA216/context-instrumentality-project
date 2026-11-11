import XCTest
import Darwin
@testable import RecordingCore

final class RecordingDiagnosticEventSnapshotTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func repository() throws -> RecordingRepository {
        try RecordingRepository(root: root, recoverTransactionsOnInitialization: false)
    }

    @discardableResult
    private func writeEvent(kind: String = "synthetic", timestamp: Date? = nil, modifiedAt: Date? = nil,
                            detail: String = "synthetic metadata") throws -> RecordingEvent {
        let event = RecordingEvent(kind: kind, detail: detail, timestamp: timestamp ?? now)
        let url = root.appendingPathComponent("events/\(event.id.uuidString.lowercased()).json")
        try TransportCodec.encode(event).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt ?? now], ofItemAtPath: url.path)
        return event
    }

    func testColdSelectionNeverDecodesUnselectedOldCorruptBodyAndReportsPartialCoverage() throws {
        let repository = try repository()
        let corrupt = root.appendingPathComponent("events/\(UUID().uuidString.lowercased()).json")
        try Data("{old corrupt body".utf8).write(to: corrupt)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10000)], ofItemAtPath: corrupt.path)
        var fault: RecordingEvent!
        for index in 0..<1000 {
            let value = try writeEvent(kind: index == 0 ? "phone.drive_background_request_failed" : "synthetic",
                timestamp: now.addingTimeInterval(Double(index) - 1000),
                modifiedAt: now.addingTimeInterval(Double(index) - 1000))
            if index == 0 { fault = value }
        }
        let snapshot = try repository.diagnosticMetadataSnapshot(at: now)
        XCTAssertEqual(snapshot.events.count, 500)
        XCTAssertTrue(snapshot.events.contains(fault), "Recent noise displaced a recognized fault in the same bounded candidates")
        let selection = snapshot.eventSelection
        XCTAssertEqual(selection.decodedFileCount, 1000)
        XCTAssertEqual(selection.totalEventFileCount, 1001)
        XCTAssertEqual(selection.omittedEventFileCount, 501)
        XCTAssertEqual(selection.indexSource, .coldDirectoryMetadata)
        XCTAssertEqual(selection.selectionBasis, .fileModificationTime)
        XCTAssertTrue(selection.truncated)
        XCTAssertFalse(selection.historyCoverageKnown)
        XCTAssertTrue(selection.candidateLimitReached)
        XCTAssertTrue(selection.eventLimitReached)
        XCTAssertEqual(selection.recognizedFaultCandidateCount, 1)
        XCTAssertEqual(selection.recognizedFaultsIncludedCount, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(selection.eventBytesRead), 2_097_152)
        XCTAssertThrowsError(try repository.metadataSnapshot(), "Full history must still validate the old corrupt file")
        XCTAssertEqual(try Data(contentsOf: corrupt), Data("{old corrupt body".utf8))
    }

    func testWarmIndexUsesOnlyBoundedCachedMetadataAndAppendUpdatesItWithoutNewFiles() throws {
        let repository = try repository()
        let original = try writeEvent()
        XCTAssertEqual(try repository.recentEventsSnapshot(at: now).eventSelection.indexSource, .coldDirectoryMetadata)
        let warm = try repository.recentEventsSnapshot(at: now)
        XCTAssertEqual(warm.eventSelection.indexSource, .warmInMemory)
        XCTAssertEqual(warm.eventSelection.inspectedDirectoryEntryCount, 0)
        XCTAssertEqual(warm.events, [original])
        let event = RecordingEvent(kind: "synthetic", detail: "incremental append", timestamp: now)
        try repository.appendEvent(event)
        let appended = try repository.recentEventsSnapshot(at: now)
        XCTAssertEqual(appended.eventSelection.indexSource, .warmInMemory)
        XCTAssertEqual(appended.eventSelection.totalEventFileCount, 2)
        XCTAssertEqual(Set(appended.events.map(\.id)), Set([original.id, event.id]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("events").path).count, 2)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("index") })
        // The metadata hint must not bypass appendEvent's immutable-ID check.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: TransportCodec.encode(original)) as? [String: Any])
        object["detail"] = "different content for the same event id"
        let conflicting = try TransportCodec.decode(RecordingEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try repository.appendEvent(conflicting))
    }

    func testExternalAtomicAppendInvalidatesWarmHint() throws {
        let repository = try repository()
        _ = try writeEvent()
        _ = try repository.recentEventsSnapshot(at: now)
        _ = try writeEvent(modifiedAt: now.addingTimeInterval(1))
        let snapshot = try repository.recentEventsSnapshot(at: now)
        XCTAssertEqual(snapshot.eventSelection.indexSource, .coldDirectoryMetadata)
        XCTAssertEqual(snapshot.eventSelection.totalEventFileCount, 2)
    }

    func testDecodedEventTimeIsFilteredSeparatelyFromFilesystemTime() throws {
        let repository = try repository()
        _ = try writeEvent(timestamp: now.addingTimeInterval(-172800), modifiedAt: now)
        let recent = try writeEvent(timestamp: now.addingTimeInterval(-10), modifiedAt: now.addingTimeInterval(-172800))
        _ = try writeEvent(timestamp: now.addingTimeInterval(60), modifiedAt: now)
        let snapshot = try repository.recentEventsSnapshot(at: now)
        XCTAssertEqual(snapshot.events, [recent])
        XCTAssertEqual(snapshot.eventSelection.decodedFileCount, 3)
        XCTAssertEqual(snapshot.eventSelection.omittedEventFileCount, 2)
        XCTAssertEqual(snapshot.eventSelection.requestedStartAt, now.addingTimeInterval(-86400))
        XCTAssertFalse(snapshot.eventSelection.historyCoverageKnown)
    }

    func testAggregateByteBudgetStopsBeforeOpeningFurtherBodies() throws {
        let repository = try repository()
        var expectedBytes = 0
        for index in 0..<5 {
            let event = try writeEvent(modifiedAt: now.addingTimeInterval(Double(index)),
                                      detail: String(repeating: "x", count: 600000))
            if index >= 2 { expectedBytes += try TransportCodec.encode(event).count }
        }
        let snapshot = try repository.recentEventsSnapshot(at: now)
        XCTAssertEqual(snapshot.events.count, 3)
        XCTAssertEqual(snapshot.eventSelection.decodedFileCount, 3)
        XCTAssertEqual(snapshot.eventSelection.eventBytesRead, expectedBytes)
        XCTAssertTrue(snapshot.eventSelection.byteLimitReached)
        XCTAssertEqual(snapshot.eventSelection.omittedEventFileCount, 2)
    }

    func testSelectedOversizedMetadataFailsInsteadOfSilentlyClaimingValidSubset() throws {
        let repository = try repository()
        for size in [1_048_577, 2_097_153] {
            let event = try writeEvent(detail: String(repeating: "x", count: size))
            XCTAssertThrowsError(try repository.recentEventsSnapshot(at: now)) {
                XCTAssertEqual($0 as? RepositoryError, .invalidManifest("诊断元数据文件超过大小限制或为空"))
            }
            try FileManager.default.removeItem(at: root.appendingPathComponent("events/\(event.id.uuidString.lowercased()).json"))
        }
    }

    func testCancellationIsExplicitAndDoesNotHoldRecordingMutationLockDuringColdScan() throws {
        let repository = try repository()
        _ = try writeEvent()
        XCTAssertThrowsError(try repository.recentEventsSnapshot(at: now, while: { false })) {
            XCTAssertTrue($0 is CancellationError)
        }
        var checks = 0
        let appended = DispatchSemaphore(value: 0)
        XCTAssertThrowsError(try repository.recentEventsSnapshot(at: now, while: {
            checks += 1
            guard checks == 3 else { return true }
            DispatchQueue.global().async {
                defer { appended.signal() }
                try? repository.appendEvent(RecordingEvent(kind: "synthetic", detail: "concurrent append", timestamp: self.now))
            }
            XCTAssertEqual(appended.wait(timeout: .now() + 2), .success,
                           "Event enumeration monopolized the recording mutation lock")
            return false
        })) { XCTAssertTrue($0 is CancellationError) }
    }

    func testSelectedSymlinkAndFIFOAreRejectedWithoutReadingTargetOrBlocking() throws {
        let repository = try repository()
        let target = root.appendingPathComponent("synthetic-nonmetadata")
        try Data("not an event".utf8).write(to: target)
        let alias = root.appendingPathComponent("events/\(UUID().uuidString.lowercased()).json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        XCTAssertThrowsError(try repository.recentEventsSnapshot(at: now))
        try FileManager.default.removeItem(at: alias)
        XCTAssertEqual(Darwin.mkfifo(alias.path, 0o600), 0)
        let start = Date()
        XCTAssertThrowsError(try repository.recentEventsSnapshot(at: now))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(try Data(contentsOf: target), Data("not an event".utf8))
    }

    func testFaultKindsAreExactAndTimeContextDoesNotClaimCausalRecovery() throws {
        let fault = RecordingEvent(kind: "phone.drive_background_request_failed", detail: "fixed kind", timestamp: now.addingTimeInterval(-500))
        let context = RecordingEvent(kind: "synthetic", detail: "error in free text is not a fault", timestamp: now.addingTimeInterval(-499))
        let before = RecordingEvent(kind: "synthetic", detail: "preceding observation", timestamp: now.addingTimeInterval(-501))
        let fake = RecordingEvent(kind: "unrecognized_error", detail: "error", timestamp: now)
        let noise = (0..<100).map { RecordingEvent(kind: "synthetic", detail: "noise", timestamp: now.addingTimeInterval(-Double($0))) }
        let denseAfter = (0..<100).map { RecordingEvent(kind: "synthetic", detail: "dense later noise",
            timestamp: now.addingTimeInterval(-450 - Double($0) / 100)) }
        let result = RecordingDiagnosticEventPolicy.select([fault, context, before, fake] + noise + denseAfter, limit: 20)
        XCTAssertTrue(result.events.contains(fault))
        XCTAssertTrue(result.events.contains(context))
        XCTAssertTrue(result.events.contains(before), "Dense later context displaced the closest preceding observation")
        XCTAssertEqual(result.faultCount, 1)
        XCTAssertEqual(result.includedFaultCount, 1)
        XCTAssertEqual(result.contextCount, 4)
    }

    func testBoundedMetadataHeapKeepsTheSameNewestCandidatesAsAnUnboundedReferenceSort() {
        let candidates = (0..<150).map { index in
            RecordingDiagnosticEventCandidate(name: String(format: "%03d", index),
                modifiedSeconds: Int64((index * 73) % 29), modifiedNanoseconds: Int64(index % 3),
                byteCount: 100, inode: UInt64(index))
        }
        var heap = RecordingDiagnosticEventCandidateHeap(limit: 17)
        for candidate in candidates { heap.insert(candidate) }
        XCTAssertEqual(heap.values.count, 17)
        XCTAssertEqual(heap.values.sorted { $0.newer(than: $1) },
                       Array(candidates.sorted { $0.newer(than: $1) }.prefix(17)))
    }

    func testDefaultMetadataKeepsManifestReceiptValidationWithoutAudioOrSourceWrites() throws {
        let repository = try repository()
        let id = UUID()
        let manifest = SegmentManifest(id: id, sessionID: UUID(), sequence: 0, startedAt: now,
            endedAt: now.addingTimeInterval(1), sampleRate: 16000, frameCount: 16000,
            fileName: id.uuidString.lowercased() + ".caf", byteCount: 32000, sha256: String(repeating: "a", count: 64))
        let receipt = SegmentReceipt(segmentID: id, sha256: manifest.sha256, byteCount: manifest.byteCount)
        let manifestURL = root.appendingPathComponent("manifests/\(id.uuidString.lowercased()).json")
        let receiptURL = root.appendingPathComponent("receipts/\(id.uuidString.lowercased()).json")
        let manifestBytes = try TransportCodec.encode(manifest), receiptBytes = try TransportCodec.encode(receipt)
        try manifestBytes.write(to: manifestURL); try receiptBytes.write(to: receiptURL)
        _ = try writeEvent()
        let snapshot = try repository.diagnosticMetadataSnapshot(at: now)
        XCTAssertEqual(snapshot.manifests, [manifest]); XCTAssertEqual(snapshot.receipts, [receipt])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.audioURL(for: manifest).path))
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBytes)
        XCTAssertEqual(try Data(contentsOf: receiptURL), receiptBytes)
        let mismatch = SegmentReceipt(segmentID: id, sha256: String(repeating: "b", count: 64), byteCount: manifest.byteCount)
        try TransportCodec.encode(mismatch).write(to: receiptURL)
        XCTAssertThrowsError(try repository.diagnosticMetadataSnapshot(at: now)) {
            XCTAssertEqual($0 as? RepositoryError, .receiptMismatch)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("segments").path), [])
    }
}
