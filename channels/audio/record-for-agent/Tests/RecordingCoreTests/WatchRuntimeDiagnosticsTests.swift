import XCTest
import Darwin
@testable import RecordingCore

final class WatchRuntimeDiagnosticsTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-runtime-synthetic-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func target(_ root: URL) -> URL {
        root.appendingPathComponent(WatchRuntimeDiagnostics.directoryName)
            .appendingPathComponent(WatchRuntimeDiagnostics.fileName)
    }

    private func read(_ root: URL) throws -> WatchRuntimeDiagnostics.Report {
        try JSONDecoder().decode(WatchRuntimeDiagnostics.Report.self, from: Data(contentsOf: target(root)))
    }

    private func snapshotIndex(_ root: URL) throws -> [String: Any] {
        let path = root.appendingPathComponent(WatchRuntimeDiagnostics.directoryName)
            .appendingPathComponent("snapshot-index.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    }

    private func runtime(_ root: URL, queue: DispatchQueue = DispatchQueue(label: "runtime-test")) throws -> WatchRuntimeDiagnostics {
        let directory = target(root).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return WatchRuntimeDiagnostics(build: "87", observationDirectory: directory,
            writer: { try $0.write(to: self.target(root), options: .atomic) },
            observationMinimumIntervalMS: 0, observationQueue: queue)
    }

    func testLifecycleRecordDoesNotWaitForObservationQueueAndCoalescesLatestSource() throws {
        let root = try temporaryRoot(), queue = DispatchQueue(label: "blocked-runtime-observation")
        queue.suspend()
        let current = try runtime(root, queue: queue)
        // A suspended diagnostic queue must not consume a lifecycle callback's budget.
        XCTAssertTrue(current.record(.becameActive))
        XCTAssertTrue(current.record(.enteredBackground))
        XCTAssertEqual(try read(root).writeAttemptCount, 3)
        XCTAssertFalse(try snapshotIndex(root)["available"] as? Bool ?? true)
        XCTAssertEqual(current.processRunID, try read(root).processRunID)
        queue.resume()
        current.drainObservationQueue()
        let index = try snapshotIndex(root)
        XCTAssertEqual(index["available"] as? Bool, true)
        XCTAssertEqual(index["sequence"] as? Int, 1)
        let folder = target(root).deletingLastPathComponent().appendingPathComponent(
            "SnapshotGenerations/" + (try XCTUnwrap(index["generationID"] as? String)))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("watch-runtime.json")),
            try Data(contentsOf: target(root)))
    }

    func testBuild87PreparationPreservesRealRuntimeBytesAndEventTimes() throws {
        let root = try temporaryRoot(), observer = WatchRuntimeDiagnostics(root: try temporaryRoot(), build: "86")
        XCTAssertFalse(observer.prepareObservationSnapshot())
        let current = try runtime(root)
        current.drainObservationQueue()
        let bytes = try Data(contentsOf: target(root)), report = try read(root)
        let before = try snapshotIndex(root)
        XCTAssertEqual(before["available"] as? Bool, true)
        XCTAssertTrue(current.prepareObservationSnapshot())
        current.drainObservationQueue()
        let after = try snapshotIndex(root)
        XCTAssertNotEqual(before["generationID"] as? String, after["generationID"] as? String)
        XCTAssertEqual(before["fenceID"] as? String, after["fenceID"] as? String)
        XCTAssertEqual(try Data(contentsOf: target(root)), bytes)
        XCTAssertEqual(try read(root), report)
        let generation = try XCTUnwrap(after["generationID"] as? String)
        let package = target(root).deletingLastPathComponent()
            .appendingPathComponent("SnapshotGenerations/" + generation)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("watch-runtime.json")), bytes)
        let receipt = try JSONDecoder().decode(VerifiedObservationPublisher.Receipt.self,
            from: Data(contentsOf: package.appendingPathComponent(VerifiedObservationPublisher.fileName)))
        XCTAssertEqual(receipt.sourceGeneratedAtMS, report.generatedAtMS)
        XCTAssertEqual(receipt.observerProcessRunID, report.processRunID)
        XCTAssertEqual(receipt.identity["writeAttemptCount"], String(report.writeAttemptCount))
    }

    func testBuild87RuntimeCorruptionFailsClosedAndRestartChangesFence() throws {
        let root = try temporaryRoot(), observer = try runtime(root)
        observer.drainObservationQueue()
        let before = try snapshotIndex(root)
        try Data("{}".utf8).write(to: target(root))
        XCTAssertTrue(observer.prepareObservationSnapshot())
        observer.drainObservationQueue()
        let failed = try snapshotIndex(root)
        XCTAssertEqual(failed["available"] as? Bool, false)
        XCTAssertNotEqual(before["fenceID"] as? String, failed["fenceID"] as? String)
        XCTAssertTrue(observer.record(.becameActive))
        observer.drainObservationQueue()
        let recovered = try snapshotIndex(root)
        XCTAssertEqual(recovered["available"] as? Bool, true)
        XCTAssertEqual(recovered["fenceID"] as? String, failed["fenceID"] as? String)
        let restart = try runtime(root)
        restart.drainObservationQueue()
        let restarted = try snapshotIndex(root)
        XCTAssertNotEqual(restarted["fenceID"] as? String, recovered["fenceID"] as? String)
        XCTAssertNotEqual(restarted["observerProcessRunID"] as? String, recovered["observerProcessRunID"] as? String)
    }

    func testRepositoryInitializationFailureHasIndependentBoundedBreadcrumb() throws {
        let root = try temporaryRoot()
        let observer = WatchRuntimeDiagnostics(root: root, build: "61")
        XCTAssertTrue(observer.record(.modelInitializing))
        XCTAssertTrue(observer.record(.transferInitializationStarted))
        XCTAssertTrue(observer.record(.transferInitializationFailed, error: CocoaError(.fileReadNoPermission)))
        let report = try read(root)
        XCTAssertEqual(report.recentEvents.map(\.event), [.observerStarted, .modelInitializing,
            .transferInitializationStarted, .transferInitializationFailed])
        XCTAssertEqual(report.recentEvents.last?.error?.domain, .cocoa)
        XCTAssertEqual(report.build, "61")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("WristRecord").path))
        XCTAssertLessThanOrEqual(try Data(contentsOf: target(root)).count, 8_192)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: target(root).deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: target(root).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        XCTAssertEqual(fileMode?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target(root).deletingLastPathComponent().path),
            [WatchRuntimeDiagnostics.fileName])
    }

    func testWriteFailuresReachFallbackAndPersistAtNextSuccessfulBoundary() throws {
        var writes = 0
        var snapshots: [Data] = []
        var fallbackEvents: [WatchRuntimeDiagnostics.Event] = []
        let observer = WatchRuntimeDiagnostics(build: "61", writer: { bytes in
            writes += 1
            if writes <= 2 { throw POSIXError(.EACCES) }
            snapshots.append(bytes)
        }, failureSink: { event, error in
            fallbackEvents.append(event)
            XCTAssertEqual(error.domain, .posix)
            XCTAssertEqual(error.code, Int(EACCES))
        })
        XCTAssertFalse(observer.record(.transferInitializationStarted))
        XCTAssertTrue(observer.record(.transferInitializationSucceeded))
        XCTAssertEqual(fallbackEvents, [.observerStarted, .transferInitializationStarted])
        let report = try JSONDecoder().decode(WatchRuntimeDiagnostics.Report.self, from: XCTUnwrap(snapshots.last))
        XCTAssertEqual(report.writeAttemptCount, 3)
        XCTAssertEqual(report.writeFailureCount, 2)
        XCTAssertEqual(report.lastWriteFailure?.event, .transferInitializationStarted)
        XCTAssertEqual(report.lastWriteFailure?.error.code, Int(EACCES))
        XCTAssertEqual(report.counts[WatchRuntimeDiagnostics.Event.transferInitializationSucceeded.rawValue], 1)
    }

    func testFiniteEventsRemainWithinCapAndDoNotSerializePrivateErrorText() throws {
        var last: Data?
        let observer = WatchRuntimeDiagnostics(build: "account-private", writer: { bytes in
            XCTAssertLessThanOrEqual(bytes.count, WatchRuntimeDiagnostics.maximumBytes)
            last = bytes
        })
        let secret = "private-recording-token-path"
        let privateError = NSError(domain: secret, code: Int.max, userInfo: [NSLocalizedDescriptionKey: secret])
        for _ in 0..<8 {
            for event in WatchRuntimeDiagnostics.Event.allCases {
                XCTAssertTrue(observer.record(event, error: privateError))
            }
        }
        let bytes = try XCTUnwrap(last)
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        let report = try JSONDecoder().decode(WatchRuntimeDiagnostics.Report.self, from: bytes)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("account-private"))
        XCTAssertEqual(report.build, "unknown")
        XCTAssertEqual(report.recentEvents.count, WatchRuntimeDiagnostics.maximumEvents)
        XCTAssertEqual(report.counts.count, WatchRuntimeDiagnostics.Event.allCases.count)
        XCTAssertEqual(report.recentEvents.last?.error?.domain, .other)
        XCTAssertEqual(report.writeFailureCount, 0)
    }

    func testIndependentObserverEpochResetsCountersRatherThanCombiningProcesses() throws {
        let root = try temporaryRoot()
        let first = WatchRuntimeDiagnostics(root: root, build: "61")
        first.record(.connectivityTaskArrived)
        let old = try read(root)
        _ = WatchRuntimeDiagnostics(root: root, build: "61")
        let new = try read(root)
        XCTAssertNotEqual(old.processRunID, new.processRunID)
        XCTAssertNotEqual(old.observerEpochID, new.observerEpochID)
        XCTAssertEqual(new.writeAttemptCount, 1)
        XCTAssertNil(new.counts[WatchRuntimeDiagnostics.Event.connectivityTaskArrived.rawValue])
    }

    func testDiagnosticDirectorySymlinkIsRejectedWithoutTouchingDestination() throws {
        let root = try temporaryRoot()
        let outside = try temporaryRoot()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(WatchRuntimeDiagnostics.directoryName),
            withDestinationURL: outside)
        let observer = WatchRuntimeDiagnostics(root: root, build: "61")
        XCTAssertFalse(observer.record(.launchCallback))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testTargetSymlinkAndHardlinkAreRejectedAndPreviousSyntheticDataRemains() throws {
        for hardlink in [false, true] {
            let root = try temporaryRoot()
            let observer = WatchRuntimeDiagnostics(root: root, build: "61")
            let other = root.appendingPathComponent("unrelated-synthetic.json")
            let original = Data("synthetic sentinel".utf8)
            try original.write(to: other)
            try FileManager.default.removeItem(at: target(root))
            if hardlink { try FileManager.default.linkItem(at: other, to: target(root)) }
            else { try FileManager.default.createSymbolicLink(at: target(root), withDestinationURL: other) }
            XCTAssertFalse(observer.record(.launchCallback))
            XCTAssertEqual(try Data(contentsOf: other), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target(root).deletingLastPathComponent().path),
                [WatchRuntimeDiagnostics.fileName])
        }
    }

    func testConcurrentBoundariesKeepOneOrderedProcessSequence() throws {
        var last: Data?
        let observer = WatchRuntimeDiagnostics(build: "61", writer: { last = $0 })
        DispatchQueue.concurrentPerform(iterations: 100) { _ in observer.record(.becameInactive) }
        let report = try JSONDecoder().decode(WatchRuntimeDiagnostics.Report.self, from: XCTUnwrap(last))
        XCTAssertEqual(report.writeAttemptCount, 101)
        XCTAssertEqual(report.counts[WatchRuntimeDiagnostics.Event.becameInactive.rawValue], 100)
        XCTAssertEqual(report.recentEvents.map(\.sequence), Array(78...101).map(UInt64.init))
    }

    func testLifecycleAttributionUsesBoundedEnumsAndRetainsTruthfulOrderedCounters() throws {
        var last: Data?
        var policy = WatchLifecyclePolicy()
        let observer = WatchRuntimeDiagnostics(build: "75", writer: { bytes in
            XCTAssertLessThanOrEqual(bytes.count, WatchRuntimeDiagnostics.maximumBytes)
            last = bytes
        })
        for index in 0..<100 {
            let input = policy.observe(source: .scene, phase: index.isMultiple(of: 2) ? .active : .inactive,
                applicationPhase: index.isMultiple(of: 2) ? .active : .inactive)
            XCTAssertTrue(observer.record(.lifecycleObserved, lifecycle: input))
        }
        let report = try JSONDecoder().decode(WatchRuntimeDiagnostics.Report.self, from: XCTUnwrap(last))
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.writeAttemptCount, 101)
        XCTAssertEqual(report.counts["lifecycleObserved"], 100)
        XCTAssertEqual(report.writeFailureCount, 0)
        XCTAssertLessThanOrEqual(report.recentEvents.count, WatchRuntimeDiagnostics.maximumEvents)
        XCTAssertEqual(report.recentEvents.map(\.sequence),
                       Array((102 - UInt64(report.recentEvents.count))...101))
        let latest = try XCTUnwrap(report.recentEvents.last?.lifecycle)
        XCTAssertEqual(latest.source, .scene)
        XCTAssertEqual(latest.reportedPhase, .inactive)
        XCTAssertEqual(latest.applicationPhase, .inactive)
        XCTAssertEqual(latest.action, .leaveForeground)
    }

    func testLegacySchemaOneEventWithoutLifecycleStillDecodes() throws {
        let bytes = Data("""
        {"sequence":1,"event":"becameActive","observedAtMS":1,"uptimeMS":1}
        """.utf8)
        let event = try JSONDecoder().decode(WatchRuntimeDiagnostics.Observation.self, from: bytes)
        XCTAssertEqual(event.event, .becameActive)
        XCTAssertNil(event.lifecycle)
    }

    func testBeginTraceDoesNotWaitForJSONWriterOrItsLock() throws {
        let writerEntered = expectation(description: "first writer entered")
        let waitingCallEntered = expectation(description: "second trace precedes lock acquisition")
        let firstDone = expectation(description: "first record finished")
        let secondDone = expectation(description: "second record finished")
        let allowWriter = DispatchSemaphore(value: 0)
        let observer = WatchRuntimeDiagnostics(build: "76", writer: { bytes in
            let report = try JSONDecoder().decode(WatchRuntimeDiagnostics.Report.self, from: bytes)
            if report.recentEvents.last?.event == .modelInitializing {
                writerEntered.fulfill()
                _ = allowWriter.wait(timeout: .now() + 5)
            }
        }, traceSink: { trace in
            if trace.event == .becameActive, trace.phase == .began {
                XCTAssertNil(trace.sequence)
                waitingCallEntered.fulfill()
            }
        })
        DispatchQueue.global().async { observer.record(.modelInitializing); firstDone.fulfill() }
        wait(for: [writerEntered], timeout: 2)
        DispatchQueue.global().async { observer.record(.becameActive); secondDone.fulfill() }
        // This must be observable while modelInitializing still owns the JSON
        // lock. Moving begin after lock.lock() makes this expectation fail.
        wait(for: [waitingCallEntered], timeout: 2)
        allowWriter.signal()
        wait(for: [firstDone, secondDone], timeout: 3)
    }

    func testResultTraceIsOutsideLockAndIncludesBoundedFailureIdentity() throws {
        var traces: [WatchRuntimeDiagnostics.Trace] = []
        var observer: WatchRuntimeDiagnostics?
        observer = WatchRuntimeDiagnostics(build: "76", writer: { bytes in
            let report = try JSONDecoder().decode(WatchRuntimeDiagnostics.Report.self, from: bytes)
            if report.recentEvents.last?.event == .launchCallback {
                throw NSError(domain: "private-path-account", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "private-token"])
            }
        }, traceSink: { trace in
            traces.append(trace)
            if trace.phase != .began {
                // Both result paths must release the lock before the sink.
                _ = observer?.processRunID
            }
        })
        XCTAssertFalse(try XCTUnwrap(observer).record(.launchCallback))
        XCTAssertTrue(try XCTUnwrap(observer).record(.becameActive))
        XCTAssertEqual(traces.map(\.phase), [.began, .succeeded, .began, .failed, .began, .succeeded])
        XCTAssertEqual(traces.map(\.sequence), [nil, 1, nil, 2, nil, 3])
        XCTAssertEqual(traces[3].error?.domain, .other)
        XCTAssertEqual(traces[3].error?.code, 7)
        for index in stride(from: 0, to: traces.count, by: 2) {
            XCTAssertEqual(traces[index].entryUptimeMS, traces[index + 1].entryUptimeMS)
        }
        // Added system-log markers must not broaden the schema-1 JSON decoder.
        XCTAssertEqual(WatchRuntimeDiagnostics.Event.allCases.count, 22)
    }
}
