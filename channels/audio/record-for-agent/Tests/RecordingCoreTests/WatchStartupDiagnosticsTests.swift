import XCTest
@testable import RecordingCore

final class WatchStartupDiagnosticsTests: XCTestCase {
    func testRepeatedViewAndConstructionEntriesAreProcessOnce() {
        let lock = NSLock()
        var events: [WatchStartupDiagnostics.Event] = []
        let observer = WatchStartupDiagnostics { event in
            lock.lock(); defer { lock.unlock() }
            events.append(event)
        }
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            observer.recordOnce(.appBodyEntered)
            observer.recordOnce(.sceneFirstAppeared)
        }
        XCTAssertEqual(events.filter { $0 == .appBodyEntered }.count, 1)
        XCTAssertEqual(events.filter { $0 == .sceneFirstAppeared }.count, 1)
        // A new process observer has a new attempt set; a view recreation uses
        // the existing shared instance instead of resetting it.
        var newProcessAttempts = 0
        let next = WatchStartupDiagnostics { _ in newProcessAttempts += 1 }
        next.recordOnce(.appBodyEntered)
        XCTAssertEqual(newProcessAttempts, 1)
    }

    func testAttemptIsMarkedAndLockReleasedBeforeReentrantSink() {
        var events: [WatchStartupDiagnostics.Event] = []
        var observer: WatchStartupDiagnostics!
        observer = WatchStartupDiagnostics { event in
            events.append(event)
            observer.recordOnce(event)
            if event == .modelConstructionStarted { observer.recordOnce(.modelInitBodyEntered) }
        }
        observer.recordOnce(.modelConstructionStarted)
        observer.recordOnce(.modelConstructionStarted)
        XCTAssertEqual(events, [.modelConstructionStarted, .modelInitBodyEntered])
    }

    func testStartupOnceDoesNotSuppressRealLifecycleEdges() {
        let startup = WatchStartupDiagnostics { _ in }
        var last: Data?
        let runtime = WatchRuntimeDiagnostics(build: "76", writer: { last = $0 }, traceSink: { _ in })
        for _ in 0..<3 {
            startup.recordOnce(.delegateActiveEntered)
            runtime.record(.becameActive)
            runtime.record(.enteredBackground)
        }
        let report = try? JSONDecoder().decode(WatchRuntimeDiagnostics.Report.self, from: last ?? Data())
        XCTAssertEqual(report?.counts["becameActive"], 3)
        XCTAssertEqual(report?.counts["enteredBackground"], 3)
    }
}
