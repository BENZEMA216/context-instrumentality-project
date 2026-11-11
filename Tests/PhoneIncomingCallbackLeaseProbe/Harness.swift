import Foundation

protocol AutomaticDeliveryExecutionLease: Sendable {
    var hasTimeRemaining: Bool { get }
    func end()
}
struct UIBackgroundTaskIdentifier: Equatable, Hashable {
    let rawValue: Int
    static let invalid = Self(rawValue: -1)
}
/// UIKit's assertion APIs are nonisolated; its lifecycle observations are not.
final class UIApplication: @unchecked Sendable {
    static let shared = UIApplication()
    enum Mode { case granted, denied, expiredDuringBegin }
    enum State: Int { case active, inactive, background }
    enum Refresh: Int { case available, denied, restricted }
    private let lock = NSRecursiveLock()
    var mode = Mode.granted
    private var handlers: [UIBackgroundTaskIdentifier: () -> Void] = [:]
    private var next = 0
    private var ended: [UIBackgroundTaskIdentifier] = []
    var applicationState: State { precondition(Thread.isMainThread); return .background }
    var backgroundRefreshStatus: Refresh { precondition(Thread.isMainThread); return .available }
    var isProtectedDataAvailable: Bool { precondition(Thread.isMainThread); return true }
    var snapshot: (active: Int, ended: [UIBackgroundTaskIdentifier]) {
        lock.lock(); defer { lock.unlock() }; return (handlers.count, ended)
    }
    var expiration: () -> Void {
        lock.lock(); defer { lock.unlock() }; return handlers.values.first!
    }
    func beginBackgroundTask(withName name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        lock.lock(); defer { lock.unlock() }
        if mode == .denied { return .invalid }
        next += 1
        let id = UIBackgroundTaskIdentifier(rawValue: next)
        handlers[id] = expirationHandler
        if mode == .expiredDuringBegin { expirationHandler() }
        return id
    }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        lock.lock(); defer { lock.unlock() }
        ended.append(id); handlers.removeValue(forKey: id)
    }
}
final class ResultBox<Value>: @unchecked Sendable {
    let lock = NSLock()
    var value: Value?
    func store(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
    func snapshot() -> Value? { lock.lock(); defer { lock.unlock() }; return value }
}
@main struct Probe {
    static func main() {
        let app = UIApplication.shared
        let first = PhoneIncomingCallbackLease.begin()
        precondition(app.snapshot.active == 1, "Assertion must exist before returning to caller")
        first.end(); first.end()
        precondition(app.snapshot.ended.count == 1 && app.snapshot.active == 0,
            "Release must remove the native expiration handler exactly once")
        app.mode = .denied
        let denied = PhoneIncomingCallbackLease.begin(); denied.end()
        precondition(app.snapshot.ended.count == 1, "Never end an invalid system grant")
        app.mode = .expiredDuringBegin
        let expired = PhoneIncomingCallbackLease.begin(); expired.end()
        precondition(app.snapshot.ended.count == 2 && app.snapshot.active == 0,
            "Expiry before identifier assignment must release the returned identifier exactly once")
        app.mode = .granted
        let box = ResultBox<PhoneIncomingCallbackLease>()
        let callbackReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.store(PhoneIncomingCallbackLease.begin()); callbackReturned.signal()
        }
        // Deliberately do not pump main: cold startup may be constructing cloud
        // stores here. The old main.sync path cannot pass this regression.
        precondition(callbackReturned.wait(timeout: .now() + 2) == .success,
            "Cold background callback assertion must not wait for MainActor bootstrap")
        precondition(app.snapshot.active == 1, "The assertion exists before staging can begin")
        let handler = app.expiration
        handler(); handler(); box.snapshot()?.end()
        precondition(app.snapshot.ended.count == 3 && app.snapshot.active == 0,
            "Expiry and explicit handoff release each grant only once")

        let importBox = ResultBox<PhoneBackgroundLease>()
        let importStarted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            PhoneBackgroundLease.begin(name: "cold-background-import", incomingCallback: true) {
                importBox.store($0); importStarted.signal()
            }
        }
        precondition(importStarted.wait(timeout: .now() + 2) == .success,
            "Cold incoming import cannot wait for an ordinary main-queue lease")
        precondition(importBox.snapshot()?.hasTimeRemaining == true,
            "A real granted assertion permits background import with no foreground observation")
        importBox.snapshot()?.end()
        precondition(app.snapshot.ended.count == 4 && app.snapshot.active == 0)

        app.mode = .denied
        PhoneBackgroundLease.begin(name: "denied-incoming", incomingCallback: true) {
            precondition(!$0.hasTimeRemaining, "Denied assertions cannot authorize background import")
            $0.end()
        }
        precondition(app.snapshot.ended.count == 4)
        app.mode = .expiredDuringBegin
        PhoneBackgroundLease.begin(name: "expired-incoming", incomingCallback: true) {
            precondition(!$0.hasTimeRemaining, "Expiry during begin cannot become a permitted lease")
            $0.end()
        }
        precondition(app.snapshot.ended.count == 5 && app.snapshot.active == 0,
            "The late identifier is returned exactly once even after import expiry")
        precondition(Set(app.snapshot.ended).count == 5)
        print("Production callback/import assertion: 7 scenarios passed; no device, audio or network access")
    }
}
