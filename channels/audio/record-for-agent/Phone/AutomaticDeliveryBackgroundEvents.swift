import Foundation
import UIKit

/// UIKit's completion handler is fulfilled only after the background URLSession
/// has delivered its events. Unknown old grants are cancelled, never restored as
/// the current pairing or granted access to current credentials.
@MainActor
final class AutomaticDeliveryBackgroundEvents: NSObject, URLSessionDelegate {
    static let shared = AutomaticDeliveryBackgroundEvents()
    private weak var store: PhoneAutomaticDeliveryStore?
    private weak var drive: GoogleDriveLibrary?
    private nonisolated let eventTracker = BackgroundSessionEventTracker.shared
    let gate = BackgroundSessionRestorationGate(isForeground: { UIApplication.shared.applicationState == .active })
    private var foregroundObserver: NSObjectProtocol?
    private var discardedSessions: [String: URLSession] = [:]

    override init() {
        super.init()
        gate.restoreUnknown = { [weak self] in self?.discard($0) }
        gate.invalidateUnrestorable = { [weak self] in self?.discardNative($0) }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.gate.restorePermitted() }
            }
    }

    func registerStore(_ store: PhoneAutomaticDeliveryStore) { self.store = store }
    func registerDrive(_ drive: GoogleDriveLibrary) { self.drive = drive }
    func canRestore(_ identifier: String) -> Bool { gate.canRestore(identifier) }
    func registerRestore(_ identifier: String, restore: @escaping () -> Void) { gate.registerRestore(identifier, restore: restore) }
    func unregisterRestore(_ identifier: String) { gate.unregisterRestore(identifier) }
    func finishRegistration() { gate.finishRegistration() }
    func setDiagnosticHandler(_ handler: @escaping (String, String) -> Void) { gate.setDiagnosticHandler(handler) }
    func beginProcessing(isCancelled: @escaping @Sendable () -> Bool) -> UUID { gate.beginProcessing(isCancelled: isCancelled) }
    func endProcessing(_ token: UUID) { gate.endProcessing(token) }
    func cancelUnrestorable(_ identifier: String) { gate.cancelUnrestorable(identifier) }
    func requiresInvalidation(_ identifier: String) -> Bool { gate.requiresInvalidation(identifier) }
    func hasPendingCompletion(_ identifier: String) -> Bool { gate.hasPendingCompletion(identifier) }
    func beginHandoff(_ identifier: String) -> UUID { gate.beginHandoff(identifier) }
    func completeHandoff(_ identifier: String, token: UUID) { gate.completeHandoff(identifier, token: token) }
    func receive(_ identifier: String, completion: @escaping () -> Void) { gate.receive(identifier, completion: completion) }
    func finish(_ identifier: String, token: UUID?) { gate.finish(identifier, token: token) }

    private func discard(_ identifier: String) {
        // The full registry has finished loading before this callback. Never
        // recreate an old grant with another receiver's credentials.
        if drive?.restoreBackgroundSession(identifier) == true { return }
        if store?.restoreBackgroundSession(identifier) == true { return }
        discardNative(identifier)
    }

    private func discardNative(_ identifier: String) {
        guard discardedSessions[identifier] == nil else { return }
        _ = gate.beginHandoff(identifier)
        let session = URLSession(configuration: .background(withIdentifier: identifier), delegate: self, delegateQueue: nil)
        discardedSessions[identifier] = session
        session.invalidateAndCancel()
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        let event = eventTracker.capture(identifier)
        Task { @MainActor in self.finish(identifier, token: event.token) }
    }

    nonisolated func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in
            self.discardedSessions.removeValue(forKey: identifier)
            let token = self.gate.beginHandoff(identifier)
            self.gate.completeHandoff(identifier, token: token)
        }
    }
}

final class AutomaticDeliveryAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PhoneBackgroundSync.shared.register()
        // WC must be activated even when iOS starts us solely for background work.
        _ = PhoneStore.shared
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            AutomaticDeliveryBackgroundEvents.shared.receive(identifier, completion: completionHandler)
        }
    }
}
