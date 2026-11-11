import Combine
import CoreLocation
import Foundation
import RecordingCore

enum RecordingLocationAuthorization {
    case notDetermined, authorized, denied
}

@MainActor
protocol RecordingLocationDriver: AnyObject {
    var authorization: RecordingLocationAuthorization { get }
    var servicesEnabled: Bool { get }
    var onAuthorizationChanged: (() -> Void)? { get set }
    var onResult: ((UUID, [SegmentLocation]?) -> Void)? { get set }
    func requestWhenInUseAuthorization()
    func requestLocation(id: UUID)
    func cancelRequests()
}

/// Optional metadata only. Audio capture never waits for this controller.
@MainActor
final class RecordingLocationManager: ObservableObject {
    enum Status {
        case disabled, waitingForAuthorization, noPermission, unavailable, enabled

        var text: String {
            switch self {
            case .disabled: return "已关闭"
            case .waitingForAuthorization: return "等待授权"
            case .noPermission: return "未获位置权限"
            case .unavailable: return "位置暂不可用"
            case .enabled: return "已开启"
            }
        }
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var status: Status = .disabled
    @Published private(set) var isIntroductionPresented = false
    @Published private(set) var introductionPresentationID: UUID?
    var onLocation: ((SegmentLocation) -> Void)?
    var onClearLocation: (() -> Void)?
    var isActuallyRecording: () -> Bool = { false }

    private var driver: (any RecordingLocationDriver)?
    private let makeDriver: @MainActor () -> any RecordingLocationDriver
    private let savePreference: (Bool) -> Void
    private let saveIntroductionHandled: (Bool) -> Void
    private let now: () -> Date
    private let schedulesTimers: Bool
    private var foreground = false
    private var interfaceReady = false
    private var introductionPresentationAllowed = false
    private var introductionHandled: Bool
    private var introductionSheetAppeared = false
    private var introductionAuthorizationPending = false
    private var captureStartedAt: Date?
    private var nextRequestAt: Date?
    private var pending: (id: UUID, startedAt: Date, deadline: Date)?
    private var timer: Task<Void, Never>?
    private var lastAuthorization: RecordingLocationAuthorization = .notDetermined
    private var lastServicesEnabled = false

    init(driver: (any RecordingLocationDriver)? = nil,
         driverFactory: @escaping @MainActor () -> any RecordingLocationDriver = { SystemRecordingLocationDriver() },
         loadPreference: () -> Bool? = { UserDefaults.standard.object(forKey: "RecordForAgent.recordLocations") as? Bool },
         savePreference: @escaping (Bool) -> Void = { UserDefaults.standard.set($0, forKey: "RecordForAgent.recordLocations") },
         loadIntroductionHandled: () -> Bool = { UserDefaults.standard.bool(forKey: "RecordForAgent.locationIntroductionHandled") },
         saveIntroductionHandled: @escaping (Bool) -> Void = { UserDefaults.standard.set($0, forKey: "RecordForAgent.locationIntroductionHandled") },
         now: @escaping () -> Date = Date.init,
         schedulesTimers: Bool = true) {
        // A headless transfer launch must not construct CLLocationManager or query
        // location services. Keep only local UI/preference state until both gates open.
        self.makeDriver = { driver ?? driverFactory() }
        self.savePreference = savePreference
        self.saveIntroductionHandled = saveIntroductionHandled
        self.now = now
        self.schedulesTimers = schedulesTimers
        let preference = loadPreference()
        isEnabled = preference ?? false
        let handled = loadIntroductionHandled()
        introductionHandled = handled || preference != nil
        // Build 8 wrote the preference only after an explicit toggle. Keep either choice,
        // including false, and remember existing system choices across Allow Once expiry.
        if introductionHandled && !handled { saveIntroductionHandled(true) }
        updateStatus()
    }

    /// Called only by the user's toggle. Restore, foreground entry and recording do not prompt.
    func setEnabled(_ enabled: Bool) {
        markIntroductionHandled()
        introductionAuthorizationPending = false
        cancelIntroductionPresentation()
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        savePreference(enabled)
        if !enabled {
            cancelPendingRequests()
            onClearLocation?()
        } else if foreground, interfaceReady {
            refreshAuthorization()
            if let driver, lastServicesEnabled, lastAuthorization == .notDetermined {
                driver.requestWhenInUseAuthorization()
            }
        }
        refreshAuthorization()
    }

    func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        if !active {
            cancelPendingRequests()
            cancelIntroductionPresentation()
            // A later foreground transition is not a new authorization gesture.
            introductionAuthorizationPending = false
        }
        else { nextRequestAt = nil }
        refreshAuthorization()
    }

    func setInterfaceReady() {
        interfaceReady = true
        refreshAuthorization()
    }

    func setIntroductionPresentationAllowed(_ allowed: Bool) {
        introductionPresentationAllowed = allowed
        if !allowed {
            cancelIntroductionPresentation()
            introductionAuthorizationPending = false
        }
        presentIntroductionIfNeeded()
    }

    /// The sheet closes first; only its onDismiss callback can request system permission.
    func introductionDidAppear(id: UUID) {
        guard introductionPresentationID == id else { return }
        introductionSheetAppeared = true
    }

    func acceptIntroduction(id: UUID) {
        guard introductionPresentationID == id, isIntroductionPresented else { return }
        introductionSheetAppeared = true
        introductionAuthorizationPending = true
        isIntroductionPresented = false
    }

    func declineIntroduction(id: UUID) {
        guard introductionPresentationID == id, isIntroductionPresented else { return }
        introductionSheetAppeared = true
        markIntroductionHandled()
        introductionAuthorizationPending = false
        isIntroductionPresented = false
    }

    func introductionDidDismiss(id: UUID) {
        guard introductionPresentationID == id else { return }
        introductionPresentationID = nil
        introductionSheetAppeared = false
        let shouldEnable = introductionAuthorizationPending && foreground && introductionPresentationAllowed
        introductionAuthorizationPending = false
        if shouldEnable { setEnabled(true) }
        presentIntroductionIfNeeded()
    }

    private func markIntroductionHandled() {
        guard !introductionHandled else { return }
        introductionHandled = true
        saveIntroductionHandled(true)
    }

    private func cancelIntroductionPresentation() {
        isIntroductionPresented = false
        // SwiftUI may never call onDismiss if the requested sheet had not appeared.
        if !introductionSheetAppeared { introductionPresentationID = nil }
    }

    private func presentIntroductionIfNeeded() {
        guard foreground, interfaceReady, introductionPresentationAllowed, !introductionHandled,
              introductionPresentationID == nil, !isEnabled,
              driver != nil, lastAuthorization == .notDetermined else { return }
        introductionPresentationID = UUID()
        isIntroductionPresented = true
    }

    /// Normal pause/end preserves the last fix until the writer seals its final segment.
    func setRecordingActive(_ active: Bool) {
        if active {
            guard captureStartedAt == nil else { return }
            captureStartedAt = now()
            nextRequestAt = nil
            tick()
        } else {
            captureStartedAt = nil
            nextRequestAt = nil
            cancelPendingRequests()
            updateStatus()
        }
    }

    func refreshAuthorization() {
        if driver == nil {
            guard foreground, interfaceReady else {
                updateStatus()
                return
            }
            let driver = makeDriver()
            self.driver = driver
            driver.onAuthorizationChanged = { [weak self] in self?.refreshAuthorization() }
            driver.onResult = { [weak self] id, locations in self?.receive(id: id, locations: locations) }
        }
        guard let driver else { return }
        // Once activated, permission callbacks must still clear retained metadata
        // after a background revocation. This never creates a headless driver.
        let authorization = driver.authorization
        let servicesEnabled = driver.servicesEnabled
        if isEnabled, (lastAuthorization == .authorized && authorization != .authorized
                       || lastServicesEnabled && !servicesEnabled) {
            cancelPendingRequests()
            onClearLocation?()
        }
        lastAuthorization = authorization
        lastServicesEnabled = servicesEnabled
        if authorization != .notDetermined {
            markIntroductionHandled()
            cancelIntroductionPresentation()
        }
        updateStatus()
        tick()
        presentIntroductionIfNeeded()
    }

    /// Exposed internally so deterministic checks can advance a fake clock without GPS or timers.
    func tick() {
        guard canRequest, let driver else {
            cancelPendingRequests()
            return
        }
        guard isActuallyRecording() else {
            setRecordingActive(false)
            return
        }
        let date = now()
        if let pending, date >= pending.deadline {
            driver.cancelRequests()
            self.pending = nil
            status = .unavailable
        }
        if pending == nil, nextRequestAt == nil || date >= nextRequestAt! {
            let id = UUID()
            pending = (id, date, date.addingTimeInterval(20))
            nextRequestAt = date.addingTimeInterval(60)
            driver.requestLocation(id: id)
        }
        scheduleNextTick()
    }

    private var canRequest: Bool {
        guard isEnabled, foreground, interfaceReady, captureStartedAt != nil, let driver else { return false }
        // A revocation delegate can still be queued behind a location result.
        // Check current permission only after all foreground acquisition gates pass.
        return driver.servicesEnabled && driver.authorization == .authorized
    }

    private func receive(id: UUID, locations: [SegmentLocation]?) {
        guard let request = pending, request.id == id else { return }
        pending = nil
        guard canRequest, let captureStartedAt, isActuallyRecording() else {
            refreshAuthorization()
            return
        }
        let date = now()
        guard date < request.deadline,
              let location = locations?.filter({ location in
                  (try? location.validate()) != nil
                      && location.capturedAt >= captureStartedAt
                      && location.capturedAt >= request.startedAt
                      && location.capturedAt <= date
              }).max(by: { $0.capturedAt < $1.capturedAt }) else {
            status = .unavailable
            scheduleNextTick()
            return
        }
        status = .enabled
        onLocation?(location)
        scheduleNextTick()
    }

    private func updateStatus() {
        if !isEnabled { status = .disabled }
        else if !lastServicesEnabled { status = .unavailable }
        else {
            switch lastAuthorization {
            case .notDetermined: status = .waitingForAuthorization
            case .denied: status = .noPermission
            case .authorized: status = .enabled
            }
        }
    }

    private func cancelPendingRequests() {
        timer?.cancel()
        timer = nil
        if pending != nil { driver?.cancelRequests() }
        pending = nil
    }

    private func scheduleNextTick() {
        timer?.cancel()
        timer = nil
        guard schedulesTimers, canRequest,
              let due = pending?.deadline ?? nextRequestAt else { return }
        let seconds = max(0.1, due.timeIntervalSince(now()))
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }
}

/// Each acquisition gets a distinct manager because Core Location callbacks have no request ID.
/// Cancelled and queued callbacks therefore cannot satisfy a newer request.
@MainActor
private final class SystemRecordingLocationDriver: NSObject, RecordingLocationDriver, CLLocationManagerDelegate {
    var onAuthorizationChanged: (() -> Void)?
    var onResult: ((UUID, [SegmentLocation]?) -> Void)?
    private let permissionManager = CLLocationManager()
    private var acquisition: (id: UUID, manager: CLLocationManager, delegate: RecordingLocationRequestDelegate)?

    var authorization: RecordingLocationAuthorization {
        switch permissionManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }
    var servicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }

    override init() {
        super.init()
        permissionManager.delegate = self
    }

    func requestWhenInUseAuthorization() {
        permissionManager.requestWhenInUseAuthorization()
    }

    func requestLocation(id: UUID) {
        cancelRequests()
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let delegate = RecordingLocationRequestDelegate(id: id) { [weak self] id, locations in
            Task { @MainActor [weak self] in self?.complete(id: id, locations: locations) }
        }
        acquisition = (id, manager, delegate)
        manager.delegate = delegate
        manager.requestLocation()
    }

    func cancelRequests() {
        acquisition?.manager.delegate = nil
        acquisition?.manager.stopUpdatingLocation()
        acquisition = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let identity = ObjectIdentifier(manager)
        Task { @MainActor [weak self] in
            guard let self,
                  identity == ObjectIdentifier(self.permissionManager) else { return }
            self.onAuthorizationChanged?()
        }
    }

    private func complete(id: UUID, locations: [SegmentLocation]?) {
        guard acquisition?.id == id else { return }
        cancelRequests()
        onResult?(id, locations)
    }
}

/// The immutable ID also survives delivery queued before cancellation, even if a manager's
/// object address is reused. This delegate never reads controller state off the main actor.
private final class RecordingLocationRequestDelegate: NSObject, CLLocationManagerDelegate {
    private let id: UUID
    private let onResult: @Sendable (UUID, [SegmentLocation]?) -> Void

    init(id: UUID, onResult: @escaping @Sendable (UUID, [SegmentLocation]?) -> Void) {
        self.id = id
        self.onResult = onResult
        super.init()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let values = locations.map {
            SegmentLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
                            horizontalAccuracy: $0.horizontalAccuracy, capturedAt: $0.timestamp)
        }
        onResult(id, values)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onResult(id, nil)
    }
}
