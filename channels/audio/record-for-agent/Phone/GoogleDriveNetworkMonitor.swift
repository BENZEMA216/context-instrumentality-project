import Foundation
import Network
import RecordingCore

/// Observation only: this does not select a route, change network settings or
/// grant permission to sync. The library applies its existing authorization gate.
@MainActor
final class GoogleDriveNetworkMonitor {
    private let settings: GoogleDriveNetworkSettings
    private let changed: @MainActor (GoogleDriveNetworkPath, Bool) -> Void
    private var monitor: NWPathMonitor?
    private var path = GoogleDriveNetworkPath.unknown
    private var transition = GoogleDriveNetworkPathTransition()
    private var generation = UUID()

    init(settings: GoogleDriveNetworkSettings = .shared,
         changed: @escaping @MainActor (GoogleDriveNetworkPath, Bool) -> Void) {
        self.settings = settings; self.changed = changed
    }

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        generation = UUID()
        let generation = generation
        monitor.pathUpdateHandler = { [weak self] snapshot in
            let path: GoogleDriveNetworkPath = snapshot.status != .satisfied ? .unavailable
                : snapshot.usesInterfaceType(.cellular) ? .cellular : .nonCellular
            Task { @MainActor [weak self] in
                guard let self, self.monitor != nil, self.generation == generation else { return }
                self.observed(path)
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.recordforagent.google-network-path"))
    }

    func stop() {
        monitor?.cancel(); monitor = nil
        generation = UUID()
        path = .unknown; transition = GoogleDriveNetworkPathTransition()
    }

    func settingsDidChange() { observed(path) }

    private func observed(_ path: GoogleDriveNetworkPath) {
        self.path = path
        changed(path, transition.observe(path, policy: settings.policy))
    }
}
