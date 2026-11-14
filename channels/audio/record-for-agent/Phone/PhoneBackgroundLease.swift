import Foundation
import UIKit

/// System expiry can arrive on any queue, including while the worker is inside
/// an atomic file commit. Cancellation must become visible without queuing work.
final class PhoneBackgroundCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Finite execution time for already-arrived audio. Expiration never waits for
/// decoding or filesystem work; the worker stops before taking its next item.
final class PhoneBackgroundLease: AutomaticDeliveryExecutionLease, @unchecked Sendable {
    private let lock = NSLock()
    private let deadline = ProcessInfo.processInfo.systemUptime + 20
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var ended = false
    private var permitted = false

    static func begin(name: String, systemGranted: Bool = false, incomingCallback: Bool = false,
                      diagnostic: (@Sendable (String) -> Void)? = nil,
                      completion: @escaping @Sendable (PhoneBackgroundLease) -> Void) {
        let acquire = {
            let lease = PhoneBackgroundLease()
            let application = UIApplication.shared
            let identifier = application.beginBackgroundTask(withName: name) { [weak lease] in
                lease?.expire()
            }
            lease.lock.lock()
            if lease.ended {
                lease.lock.unlock()
                if identifier != .invalid { application.endBackgroundTask(identifier) }
            } else {
                lease.identifier = identifier
                // An incoming callback never needs a MainActor observation to
                // use an actual UIKit assertion. A denied grant still denies work.
                lease.permitted = identifier != .invalid || systemGranted
                    || (!incomingCallback && application.applicationState == .active)
                lease.lock.unlock()
            }
            if incomingCallback {
                diagnostic?("application_state=not_observed background_refresh_status=not_observed"
                    + " grant_valid=\(identifier != .invalid) system_granted=\(systemGranted)")
            } else {
                let applicationState: String
                switch application.applicationState {
                case .active: applicationState = "active"
                case .inactive: applicationState = "inactive"
                case .background: applicationState = "background"
                @unknown default: applicationState = "unknown(rawValue:\(application.applicationState.rawValue))"
                }
                let refreshStatus: String
                switch application.backgroundRefreshStatus {
                case .available: refreshStatus = "available"
                case .denied: refreshStatus = "denied"
                case .restricted: refreshStatus = "restricted"
                @unknown default: refreshStatus = "unknown(rawValue:\(application.backgroundRefreshStatus.rawValue))"
                }
                // Observations only. Protected data can be unavailable on a locked
                // phone while our first-unlock files remain accessible; never gate
                // recording or synchronization on this diagnostic value.
                diagnostic?("application_state=\(applicationState) background_refresh_status=\(refreshStatus)"
                    + " low_power_mode=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
                    + " grant_valid=\(identifier != .invalid) system_granted=\(systemGranted)"
                    + " protected_data_available=\(application.isProtectedDataAvailable)")
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { [weak lease] in lease?.expire() }
            completion(lease)
        }
        // UIApplication's begin/endBackgroundTask APIs are nonisolated. Taking
        // a new assertion for a native file callback must not wait for optional
        // cloud/store construction on main during a cold background launch.
        if incomingCallback { acquire() }
        else { DispatchQueue.main.async(execute: acquire) }
    }

    var hasTimeRemaining: Bool {
        lock.lock()
        defer { lock.unlock() }
        return permitted && !ended && ProcessInfo.processInfo.systemUptime < deadline
    }

    func expire() { end() }

    func end() {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        let value = identifier
        identifier = .invalid
        lock.unlock()
        if value != .invalid {
            UIApplication.shared.endBackgroundTask(value)
        }
    }

    deinit { end() }
}

/// Covers the gap between WC's temporary-file callback and acquisition of the
/// serial import lease. Acquire before copying, not after returning to WC. This
/// assertion does not authorize an ACK or turn a denied grant into execution.
final class PhoneIncomingCallbackLease: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var ended = false

    static func begin() -> PhoneIncomingCallbackLease {
        let lease = PhoneIncomingCallbackLease()
        let acquire = {
            let identifier = UIApplication.shared.beginBackgroundTask(withName: "recording-incoming-handoff") {
                lease.end()
            }
            lease.lock.lock()
            if lease.ended {
                lease.lock.unlock()
                if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
            } else {
                lease.identifier = identifier
                lease.lock.unlock()
            }
        }
        // UIKit explicitly allows these assertion APIs on non-main threads.
        // Acquire synchronously on WC's callback queue, before the temporary
        // file is copied, without waiting for PhoneStore's MainActor bootstrap.
        acquire()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { [weak lease] in lease?.end() }
        return lease
    }

    func end() {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        let value = identifier
        identifier = .invalid
        lock.unlock()
        if value != .invalid {
            UIApplication.shared.endBackgroundTask(value)
        }
    }

    deinit { end() }
}
