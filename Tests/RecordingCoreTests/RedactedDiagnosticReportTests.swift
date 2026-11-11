import XCTest
import Darwin
@testable import RecordingCore

final class RedactedDiagnosticReportTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func eventsDirectory() throws -> URL {
        let url = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    @discardableResult private func writeEvent(_ value: RecordingEvent, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(value.id.uuidString.lowercased() + ".json")
        try TransportCodec.encode(value).write(to: file)
        return file
    }
    func testDefaultProjectionCannotExportPrivateFieldsOrUnknownKinds() throws {
        let secret = "PRIVATE-account-token-location-path-audioSHA-transcript"
        let event = RecordingEvent(kind: secret, detail: secret, sessionID: UUID(), timestamp: now)
        let watch = RecorderSnapshot(state: .paused, sessionID: UUID(), observedAt: now, detail: secret)
        let safe = RedactedDiagnosticEvent(event)
        let data = try TransportCodec.encode(safe)
        XCTAssertEqual(safe.category, .other); XCTAssertEqual(safe.kind, .other)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(secret)); XCTAssertFalse(text.contains(event.id.uuidString))
        XCTAssertFalse(text.contains(event.sessionID!.uuidString)); XCTAssertFalse(text.contains("detail"))
        let watchText = String(decoding: try TransportCodec.encode(RedactedDiagnosticWatch(snapshot: watch, reachable: false, at: now)), as: UTF8.self)
        XCTAssertFalse(watchText.contains(secret)); XCTAssertFalse(watchText.contains(watch.sessionID!.uuidString))
        XCTAssertEqual(RedactedDiagnosticReport.safeBuild("58.1"), "58.1")
        XCTAssertEqual(RedactedDiagnosticReport.safeBuild(secret), "unknown")
    }
    func testCaptureRecoveryStagesAndGapEdgesRemainDistinctWithoutClaimingCorrelation() throws {
        let kinds = ["automatic_resume_attempt", "automatic_resume_scheduled", "automatic_resume_exhausted",
            "capture_attempt_started", "capture_engine_started", "capture_attempt_audio_confirmed",
            "capture_attempts_cancelled", "user_paused", "user_ended", "audio_gap", "gap_closed"]
        let values = kinds.map { RedactedDiagnosticEvent(RecordingEvent(kind: $0, detail: "secret", timestamp: now)) }
        XCTAssertEqual(Set(values.map { $0.kind.rawValue }).count, kinds.count)
        XCTAssertTrue(values.allSatisfy { $0.kind != .other && $0.correlation == "not_available" })
    }
    func testHistoricalReaderUsesOnlyEventFilesAndExportsOnlyProjection() throws {
        let directory = try eventsDirectory()
        // Other library components are deliberately unusable. Merely exporting
        // events must not enumerate/decode these directories or follow aliases.
        for name in ["audio", "manifests", "receipts", "transcripts"] {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: root.appendingPathComponent("missing-private-target"))
        }
        let value = RecordingEvent(kind: "audio_gap", detail: "SENSITIVE_FREE_TEXT", sessionID: UUID(), timestamp: now)
        let file = try writeEvent(value, in: directory), before = try Data(contentsOf: directory.appendingPathComponent(value.id.uuidString.lowercased() + ".json"))
        let batch = try DiagnosticHistoryReader.read(root: root, at: now)
        XCTAssertEqual(batch.events.count, 1); XCTAssertTrue(batch.completeHistoryObserved)
        XCTAssertEqual(batch.events.first?.kind, .audioGap)
        let text = String(decoding: try TransportCodec.encode(batch), as: UTF8.self)
        XCTAssertFalse(text.contains("SENSITIVE_FREE_TEXT")); XCTAssertFalse(text.contains(value.id.uuidString))
        XCTAssertFalse(text.contains(value.sessionID!.uuidString)); XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testHistoricalReaderRejectsSymlinksHardLinksAndOversizedMetadata() throws {
        let directory = try eventsDirectory(), target = root.appendingPathComponent("outside.json")
        try Data("PRIVATE".utf8).write(to: target)
        let file = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try DiagnosticHistoryReader.read(root: root, at: now))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(Darwin.link(target.path, file.path), 0)
        XCTAssertThrowsError(try DiagnosticHistoryReader.read(root: root, at: now))
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 65, count: DiagnosticHistoryReader.maximumFileBytes + 1).write(to: file)
        XCTAssertThrowsError(try DiagnosticHistoryReader.read(root: root, at: now))
        XCTAssertEqual(try Data(contentsOf: target), Data("PRIVATE".utf8))
    }
    func testHistoricalCandidateCapIsExplicitAndCancellationReturnsNoPartialSuccess() throws {
        let directory = try eventsDirectory()
        for index in 0...DiagnosticHistoryReader.maximumEvents {
            try writeEvent(.init(kind: "user_paused", detail: "", timestamp: now.addingTimeInterval(Double(index))), in: directory)
        }
        let value = try DiagnosticHistoryReader.read(root: root, at: now)
        XCTAssertEqual(value.events.count, DiagnosticHistoryReader.maximumEvents)
        XCTAssertTrue(value.truncated); XCTAssertTrue(value.candidateLimitReached)
        XCTAssertFalse(value.completeHistoryObserved); XCTAssertEqual(value.totalEventFileCount, 2_001)
        XCTAssertThrowsError(try DiagnosticHistoryReader.read(root: root, while: { false })) { XCTAssertTrue($0 is CancellationError) }
    }
    func testWatchMissingAndOldOrInvalidObservationAreHonest() {
        XCTAssertEqual(RedactedDiagnosticWatch(snapshot: nil, reachable: true, at: now).availability, .missing)
        let old = RecorderSnapshot(state: .recording, observedAt: now.addingTimeInterval(-61))
        XCTAssertEqual(RedactedDiagnosticWatch(snapshot: old, reachable: true, at: now).availability, .stale)
        let future = RecorderSnapshot(state: .paused, observedAt: now.addingTimeInterval(30))
        XCTAssertEqual(RedactedDiagnosticWatch(snapshot: future, reachable: true, at: now).availability, .invalidTimestamp)
    }
    func testMissingRepositoryCanProduceExplicitUnavailableReportWithoutInventingZeroHistory() throws {
        let history = RedactedDiagnosticEventBatch.unavailable(includeFullHistory: false, at: now)
        let memory = RedactedDiagnosticMemory(capturedAt: now, librarySnapshotObservedAt: nil,
            librarySnapshotAvailable: false, segmentCount: 0, receiptCount: 0, visibleEventCount: 0, storageFailureObserved: true)
        let report = RedactedDiagnosticReport(issueID: UUID(), processRunID: UUID(), build: "58",
            operatingSystem: .init(majorVersion: 18, minorVersion: 0, patchVersion: 1),
            collectionStartedAt: now, collectionFinishedAt: now, collectionElapsedMS: 1,
            memory: memory, watch: .init(snapshot: nil, reachable: false, at: now), eventHistory: history)
        let data = try TransportCodec.encode(report)
        let url = try DiagnosticReportStorage.writeReport(data, issueID: report.issueID, root: root)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let events = try XCTUnwrap(object["eventHistory"] as? [String: Any])
        XCTAssertEqual(events["availability"] as? String, "unavailable")
        XCTAssertEqual(events["unavailableReason"] as? String, "library_unavailable")
        XCTAssertEqual(events["completeHistoryObserved"] as? Bool, false)
        XCTAssertNil(events["totalEventFileCount"])
        XCTAssertEqual(object["macASRObservation"] as? String, "not_observed")
        XCTAssertEqual(object["agentObservation"] as? String, "not_observed")
        XCTAssertEqual(object["build"] as? String, "58"); XCTAssertNotNil(object["processRunID"])
    }
    func testAtomicPrivateReportCannotBeReplacedOrExceedWholeEnvelopeCap() throws {
        let id = UUID(), data = Data("{\"safe\":true}".utf8)
        let url = try DiagnosticReportStorage.writeReport(data, issueID: id, root: root)
        XCTAssertEqual(try Data(contentsOf: url), data)
        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let directoryMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600); XCTAssertEqual(directoryMode, 0o700)
        XCTAssertThrowsError(try DiagnosticReportStorage.writeReport(Data("replacement".utf8), issueID: id, root: root))
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertThrowsError(try DiagnosticReportStorage.writeReport(Data(repeating: 0, count: DiagnosticReportStorage.maximumReportBytes + 1), issueID: UUID(), root: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count, 1)
    }
    func testRetentionLifecycleAndCrashTemporaryCleanupStayInsideDedicatedDirectory() throws {
        let outside = root.appendingPathComponent("keep.json"), data = Data("{}".utf8)
        try data.write(to: outside)
        var lastID = UUID(), lastURL: URL!
        for _ in 0...DiagnosticReportStorage.maximumReportCount {
            lastID = UUID(); lastURL = try DiagnosticReportStorage.writeReport(data, issueID: lastID, root: root)
        }
        let directory = lastURL.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 10)
        var lifecycle = DiagnosticShareLifecycle(issueID: lastID, requestedAt: now, fileReadyAt: now, fileReadyElapsedMS: 10)
        try DiagnosticReportStorage.writeLifecycle(lifecycle, root: root)
        lifecycle.panelPresentedAt = now; lifecycle.activityFinishedAt = now; lifecycle.systemActivityCompleted = false
        try DiagnosticReportStorage.writeLifecycle(lifecycle, root: root)
        let receipt = directory.appendingPathComponent("lifecycle-\(lastID.uuidString.lowercased()).json")
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        XCTAssertEqual(decoded["systemActivityCompleted"] as? Bool, false)
        XCTAssertEqual(decoded["recipientDeliveryObserved"] as? Bool, false)
        let pending = directory.appendingPathComponent(".pending-" + UUID().uuidString.lowercased())
        try data.write(to: pending)
        _ = try DiagnosticReportStorage.writeReport(data, issueID: UUID(), root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path)); XCTAssertEqual(try Data(contentsOf: outside), data)
    }
    func testRejectedDuplicateAtCapacityPreservesAllRetainedReportsAndReceipts() throws {
        let now = Date()
        let data = Data("{}".utf8)
        var ids: [UUID] = [], urls: [URL] = []
        for index in 0..<DiagnosticReportStorage.maximumReportCount {
            let id = UUID()
            let url = try DiagnosticReportStorage.writeReport(data, issueID: id, root: root, at: now)
            try DiagnosticReportStorage.writeLifecycle(.init(issueID: id, requestedAt: now,
                fileReadyAt: now, fileReadyElapsedMS: 1), root: root, at: now)
            // Retention order must not depend on filesystem timestamp resolution.
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(index) - 60)],
                                                 ofItemAtPath: url.path)
            ids.append(id); urls.append(url)
        }
        let directory = try XCTUnwrap(urls.last).deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let original = try Dictionary(uniqueKeysWithValues: names.map {
            ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
        })

        XCTAssertThrowsError(try DiagnosticReportStorage.writeReport(Data("replacement".utf8),
            issueID: try XCTUnwrap(ids.last), root: root, at: now))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), names)
        for (name, bytes) in original {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), bytes)
        }
    }
    func testExpiredReportCannotBeReplacedUsingTheSameIssueID() throws {
        let id = UUID(), data = Data("{\"original\":true}".utf8)
        let url = try DiagnosticReportStorage.writeReport(data, issueID: id, root: root)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86_400)],
                                             ofItemAtPath: url.path)

        XCTAssertThrowsError(try DiagnosticReportStorage.writeReport(Data("replacement".utf8),
            issueID: id, root: root, at: now))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
    func testExpiredReportAndReceiptAreRemovedTogether() throws {
        let id = UUID(), url = try DiagnosticReportStorage.writeReport(Data("{}".utf8), issueID: id, root: root)
        let lifecycle = DiagnosticShareLifecycle(issueID: id, requestedAt: now, fileReadyAt: now, fileReadyElapsedMS: 1)
        try DiagnosticReportStorage.writeLifecycle(lifecycle, root: root)
        let receipt = url.deletingLastPathComponent().appendingPathComponent("lifecycle-\(id.uuidString.lowercased()).json")
        for file in [url, receipt] {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: file.path)
        }
        _ = try DiagnosticReportStorage.writeReport(Data("{}".utf8), issueID: UUID(), root: root, at: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }
    func testExportDirectoryAliasIsRefusedWithoutTouchingTarget() throws {
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("RedactedDiagnosticExports"), withDestinationURL: other)
        XCTAssertThrowsError(try DiagnosticReportStorage.writeReport(Data("{}".utf8), issueID: UUID(), root: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), [])
    }
}
