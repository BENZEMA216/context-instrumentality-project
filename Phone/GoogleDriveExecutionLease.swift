import Foundation
import UIKit

/// Drive has longer bounded foreground rounds than the receipt/inbox workers.
/// The policy is shared with the synthetic probe; UIKit only supplies lifecycle
/// transitions and a real background-task expiration signal.
final class GoogleDriveExecutionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var budget: GoogleDriveExecutionBudget
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var observer: NSObjectProtocol?
    private var ended = false
    let isSystemGranted: Bool
    private let onExpiration: @Sendable () -> Void

    private init(isForeground: Bool, systemGranted: Bool, maximumDeadline: TimeInterval?, onExpiration: @escaping @Sendable () -> Void) {
        budget = GoogleDriveExecutionBudget(isForeground: isForeground, systemGranted: systemGranted,
            now: ProcessInfo.processInfo.systemUptime, maximumDeadline: maximumDeadline)
        isSystemGranted = systemGranted; self.onExpiration = onExpiration
    }

    @MainActor
    static func begin(systemGranted: Bool, maximumDeadline: TimeInterval? = nil,
                      onExpiration: @escaping @Sendable () -> Void) -> GoogleDriveExecutionLease {
        let foreground = UIApplication.shared.applicationState == .active
        let lease = GoogleDriveExecutionLease(isForeground: foreground, systemGranted: systemGranted,
            maximumDeadline: maximumDeadline, onExpiration: onExpiration)
        // BGProcessing already owns the system assertion. An extra UIKit grant
        // could expire earlier and incorrectly cancel that still-valid parent.
        if !systemGranted {
            lease.observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: nil) { [weak lease] _ in
                    // Publish the shortened budget synchronously, even if the
                    // main actor is waiting for a Google reply.
                    lease?.enterBackground()
                    Task { @MainActor [weak lease] in lease?.acquireBackgroundGrant() }
                }
            if !foreground { lease.acquireBackgroundGrant() }
        }
        lease.scheduleExpiration()
        return lease
    }

    var deadline: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return budget.deadline
    }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { throw CancellationError() }
        try budget.check(at: ProcessInfo.processInfo.systemUptime)
    }

    func requestTimeout() throws -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { throw CancellationError() }
        return try budget.requestTimeout(at: ProcessInfo.processInfo.systemUptime)
    }

    private func enterBackground() {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        budget.enterBackground(at: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        scheduleExpiration()
    }

    @MainActor
    private func acquireBackgroundGrant() {
        guard !isSystemGranted else { return }
        lock.lock()
        let needed = !ended && identifier == .invalid
        lock.unlock()
        guard needed else { return }
        let value = UIApplication.shared.beginBackgroundTask(withName: "google-drive-sync") { [weak self] in self?.expire() }
        lock.lock()
        if ended {
            lock.unlock()
            if value != .invalid { UIApplication.shared.endBackgroundTask(value) }
            return
        }
        identifier = value
        let denied = value == .invalid
        lock.unlock()
        if denied { expire() }
    }

    private func scheduleExpiration() {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        let expected = budget.deadline
        let remaining = budget.remaining(at: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = !self.ended && self.budget.deadline == expected
            let due = self.budget.remaining(at: ProcessInfo.processInfo.systemUptime) <= 0
            self.lock.unlock()
            if current {
                if due { self.expire() }
                else { self.scheduleExpiration() }
            }
        }
    }

    private func expire() { finish(expired: true) }
    func end() { finish(expired: false) }

    private func finish(expired: Bool) {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        if expired { budget.expire() }
        let value = identifier, oldObserver = observer
        identifier = .invalid; observer = nil
        lock.unlock()
        if let oldObserver { NotificationCenter.default.removeObserver(oldObserver) }
        // The ended flag is observable to checkWork before this main-actor task
        // can run, so an awaited reply cannot start another request meanwhile.
        if expired { onExpiration() }
        if value != .invalid {
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(value) }
        }
    }

    deinit { end() }
}
