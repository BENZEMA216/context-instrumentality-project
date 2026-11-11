import Foundation
import Darwin
import OSLog

/// Independent of the runtime JSON writer and recording library. These finite,
/// process-once markers locate startup before model construction or disk I/O.
/// They describe entry points, not successful initialization or live UI proof.
public final class WatchStartupDiagnostics: @unchecked Sendable {
    public enum Event: String, CaseIterable, Sendable {
        case appInitEntered, appBodyEntered, sceneFirstAppeared
        case delegateInitEntered, delegateLaunchEntered, delegateActiveEntered
        case modelConstructionStarted, modelInitBodyEntered, modelConstructionCompleted
        case localLibraryCheckStarted, localLibraryCheckCompleted, firstWriterStatusReceived
    }

    public static let shared = WatchStartupDiagnostics()
    private static let logger = Logger(subsystem: "WristRecord", category: "watch-startup")
    private let lock = NSLock()
    private var attempted: Set<Event> = []
    private let sink: (Event) -> Void

    init(sink: ((Event) -> Void)? = nil) {
        self.sink = sink ?? { event in
            let uptime = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
            Self.logger.notice("Startup entry event=\(event.rawValue, privacy: .public) pid=\(getpid(), privacy: .public) uptimeMS=\(uptime, privacy: .public)")
        }
    }

    /// Set the in-memory attempt before the sink, and invoke it outside this
    /// lock. Recreated views and a reentrant sink cannot restart the same marker.
    /// Actual lifecycle callbacks continue to use their normal per-edge records.
    public func recordOnce(_ event: Event) {
        lock.lock()
        let first = attempted.insert(event).inserted
        lock.unlock()
        if first { sink(event) }
    }
}
