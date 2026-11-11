import Foundation

/// A synthetic native lifetime: tests choose when enumeration/invalidation
/// callbacks arrive. It never creates a native task or opens a connection.
final class ControlledDriveSession: URLSession, @unchecked Sendable {
    private let callback: URLSessionDelegate
    private let lock = NSLock()
    private var pendingEnumeration: (@Sendable ([URLSessionTask]) -> Void)?
    private let holdsEnumeration: Bool
    private var enumerations = 0, gracefulInvalidations = 0, cancellations = 0

    init(delegate: URLSessionDelegate, holdsEnumeration: Bool = false) {
        callback = delegate; self.holdsEnumeration = holdsEnumeration
        // This subclass implements every operation used by these lifetime tests;
        // the deprecated empty initializer intentionally creates no real session.
        super.init()
    }
    var enumerationCount: Int { lock.lock(); defer { lock.unlock() }; return enumerations }
    var gracefulInvalidationCount: Int { lock.lock(); defer { lock.unlock() }; return gracefulInvalidations }
    var cancellationCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    override func getAllTasks(completionHandler: @escaping @Sendable ([URLSessionTask]) -> Void) {
        lock.lock(); enumerations += 1
        if holdsEnumeration { pendingEnumeration = completionHandler; lock.unlock() }
        else { lock.unlock(); completionHandler([]) }
    }
    override func finishTasksAndInvalidate() {
        lock.lock(); gracefulInvalidations += 1; lock.unlock()
    }
    override func invalidateAndCancel() {
        lock.lock(); cancellations += 1; lock.unlock()
    }
    func releaseEnumeration() {
        lock.lock(); let pending = pendingEnumeration; pendingEnumeration = nil; lock.unlock()
        pending?([])
    }
    func releaseInvalidation() { callback.urlSession?(self, didBecomeInvalidWithError: nil) }
}

final class DriveInterleavingDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
    override func set(_ value: Any?, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value }
}

private struct DriveInterleavingTimeout: Error { let phase: String }
/// Conditions establish ordering; elapsed time is only a failure bound. No
/// sleep or scheduler turn is treated as evidence that a phase was reached.
@MainActor func waitForDriveInterleaving(_ phase: String, until predicate: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !predicate() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw DriveInterleavingTimeout(phase: phase) }
        await Task.yield()
    }
}
