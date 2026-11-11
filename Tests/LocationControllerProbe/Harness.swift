import Foundation
import RecordingCore

@MainActor
final class FakeDriver: RecordingLocationDriver {
    private var authorizationValue: RecordingLocationAuthorization
    private var servicesEnabledValue = true
    var authorizationReads = 0
    var servicesEnabledReads = 0
    var authorization: RecordingLocationAuthorization {
        get { authorizationReads += 1; return authorizationValue }
        set { authorizationValue = newValue }
    }
    var servicesEnabled: Bool {
        get { servicesEnabledReads += 1; return servicesEnabledValue }
        set { servicesEnabledValue = newValue }
    }
    var onAuthorizationChanged: (() -> Void)?
    var onResult: ((UUID, [SegmentLocation]?) -> Void)?
    var permissionRequests = 0
    var locationRequests: [UUID] = []
    var cancellationCount = 0
    var currentID: UUID?
    init(_ authorization: RecordingLocationAuthorization) { self.authorizationValue = authorization }
    func requestWhenInUseAuthorization() { permissionRequests += 1 }
    func requestLocation(id: UUID) { locationRequests.append(id); currentID = id }
    func cancelRequests() { cancellationCount += 1; currentID = nil }
    func deliver(_ id: UUID, _ locations: [SegmentLocation]?) {
        if currentID == id { currentID = nil }
        onResult?(id, locations)
    }
    func changeAuthorization(_ value: RecordingLocationAuthorization) {
        authorization = value
        onAuthorizationChanged?()
    }
}

@MainActor
final class Fixture {
    final class Values {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        var actualAudio = false
        var savedPreferences: [Bool] = []
        var preference: Bool?
        var introductionHandled = false
        var savedIntroductionHandled: [Bool] = []
        var locations: [SegmentLocation] = []
        var clearCount = 0
    }
    let values = Values()
    let driver: FakeDriver
    let model: RecordingLocationManager
    private var callbackIntroductionID = UUID()
    init(enabled: Bool? = false, authorization: RecordingLocationAuthorization = .authorized,
         introductionHandled: Bool = false) {
        let driver = FakeDriver(authorization)
        self.driver = driver
        let values = self.values
        values.preference = enabled
        values.introductionHandled = introductionHandled
        model = RecordingLocationManager(driver: driver, loadPreference: { values.preference },
            savePreference: { values.preference = $0; values.savedPreferences.append($0) },
            loadIntroductionHandled: { values.introductionHandled },
            saveIntroductionHandled: { values.introductionHandled = $0; values.savedIntroductionHandled.append($0) },
            now: { values.date }, schedulesTimers: false)
        model.isActuallyRecording = { values.actualAudio }
        model.onLocation = { values.locations.append($0) }
        model.onClearLocation = { values.clearCount += 1 }
        // Existing sampling scenarios model a restored, ready UI. New-install
        // introduction scenarios explicitly exercise the interface-ready gate.
        if enabled != nil { model.setInterfaceReady() }
    }
    func at(_ seconds: Double) { values.date = Date(timeIntervalSince1970: 1_700_000_000 + seconds) }
    func fix(_ seconds: Double, accuracy: Double = 100, latitude: Double = 31.2, longitude: Double = 121.5) -> SegmentLocation {
        SegmentLocation(latitude: latitude, longitude: longitude, horizontalAccuracy: accuracy,
                        capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds))
    }
    func start() {
        model.setForeground(true)
        model.setEnabled(true)
        values.actualAudio = true
        model.setRecordingActive(true)
    }
    func presentIntroduction() {
        model.setForeground(true)
        model.setInterfaceReady()
        model.setIntroductionPresentationAllowed(true)
        appearIntroduction()
    }
    func appearIntroduction() {
        guard let id = model.introductionPresentationID else { return }
        callbackIntroductionID = id
        model.introductionDidAppear(id: id)
    }
    func acceptIntroduction() {
        if let id = model.introductionPresentationID { callbackIntroductionID = id }
        model.acceptIntroduction(id: callbackIntroductionID)
    }
    func declineIntroduction() {
        if let id = model.introductionPresentationID { callbackIntroductionID = id }
        model.declineIntroduction(id: callbackIntroductionID)
    }
    func dismissIntroduction() {
        // Match the presenter closure's fixed identity, even if a new sheet was requested.
        model.introductionDidDismiss(id: callbackIntroductionID)
    }
    func restart() -> Fixture {
        Fixture(enabled: values.preference, authorization: driver.authorization,
                introductionHandled: values.introductionHandled)
    }
}

@main
struct Probe {
    @MainActor static func main() throws {
        var caseNames: [String] = []
        var assertions = 0
        var failures: [String] = []
        var currentCase = ""
        func begin(_ name: String) { currentCase = name; caseNames.append(name) }
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            assertions += 1
            if !condition() { failures.append(currentCase + ": " + description) }
        }

        begin("headless_location_controller_never_constructs_or_queries_driver")
        do {
            var creations = 0
            let driver = FakeDriver(.authorized)
            let model = RecordingLocationManager(driverFactory: { creations += 1; return driver },
                loadPreference: { true }, savePreference: { _ in }, loadIntroductionHandled: { true },
                saveIntroductionHandled: { _ in }, schedulesTimers: false)
            model.isActuallyRecording = { true }
            model.refreshAuthorization()
            model.setRecordingActive(true)
            model.tick()
            model.setForeground(false)
            model.setInterfaceReady()
            model.setIntroductionPresentationAllowed(true)
            model.refreshAuthorization()
            check(creations == 0, "headless init and transfer-adjacent callbacks do not construct a driver")
            check(driver.authorizationReads == 0 && driver.servicesEnabledReads == 0, "headless callbacks never read system authorization or services")
            check(driver.permissionRequests == 0 && driver.locationRequests.isEmpty, "headless controller requests neither permission nor fixes")
            check(model.isEnabled && !model.isIntroductionPresented, "saved UI state remains usable without the driver")
        }

        begin("foreground_before_interface_ready_constructs_driver_once_without_prompt")
        do {
            var creations = 0
            let driver = FakeDriver(.notDetermined)
            let model = RecordingLocationManager(driverFactory: { creations += 1; return driver },
                loadPreference: { true }, savePreference: { _ in }, loadIntroductionHandled: { true },
                saveIntroductionHandled: { _ in }, schedulesTimers: false)
            model.setForeground(true)
            model.refreshAuthorization()
            model.tick()
            check(creations == 0 && driver.authorizationReads == 0 && driver.servicesEnabledReads == 0,
                  "foreground alone cannot instantiate or query the driver")
            model.setInterfaceReady()
            check(creations == 1 && driver.authorizationReads > 0 && driver.servicesEnabledReads > 0,
                  "the second gate creates and queries the driver on its main actor")
            model.setInterfaceReady()
            model.setForeground(true)
            model.refreshAuthorization()
            check(creations == 1, "repeated readiness and foreground events reuse one driver")
            check(driver.permissionRequests == 0 && driver.locationRequests.isEmpty, "restored opt-in cannot prompt or sample without audio")
            check(model.status.text == "等待授权", "ready UI reflects actual authorization")
        }

        begin("interface_ready_before_foreground_defers_driver_and_background_revocation_clears")
        do {
            var creations = 0
            var clears = 0
            let driver = FakeDriver(.authorized)
            let model = RecordingLocationManager(driverFactory: { creations += 1; return driver },
                loadPreference: { true }, savePreference: { _ in }, loadIntroductionHandled: { true },
                saveIntroductionHandled: { _ in }, schedulesTimers: false)
            model.onClearLocation = { clears += 1 }
            model.setInterfaceReady()
            model.refreshAuthorization()
            check(creations == 0, "interface readiness without real foreground remains driver-free")
            model.setForeground(true)
            check(creations == 1, "real foreground opens the final gate once")
            model.setForeground(false)
            let reads = driver.authorizationReads + driver.servicesEnabledReads
            driver.changeAuthorization(.denied)
            model.refreshAuthorization()
            model.tick()
            check(driver.authorizationReads + driver.servicesEnabledReads > reads && clears == 1,
                  "an existing driver's background revocation clears the writer's retained metadata")
            check(model.status.text == "未获位置权限", "background revocation remains visible without enabling acquisition")
            model.setForeground(true)
            check(creations == 1 && driver.authorizationReads + driver.servicesEnabledReads > reads,
                  "returning foreground refreshes the existing driver rather than constructing another")
            check(driver.permissionRequests == 0 && driver.locationRequests.isEmpty, "all passive lifecycle edges remain permission-free")
        }

        begin("pre_ready_toggle_does_not_defer_a_system_permission_request")
        do {
            var creations = 0
            let driver = FakeDriver(.notDetermined)
            let model = RecordingLocationManager(driverFactory: { creations += 1; return driver },
                loadPreference: { false }, savePreference: { _ in }, loadIntroductionHandled: { true },
                saveIntroductionHandled: { _ in }, schedulesTimers: false)
            model.setForeground(true)
            model.setEnabled(true)
            check(creations == 0 && model.isEnabled, "pre-ready explicit preference is local only")
            model.setInterfaceReady()
            check(creations == 1 && driver.permissionRequests == 0,
                  "UI readiness must not replay a prior toggle as a new consent gesture")
            model.setEnabled(false)
            model.setEnabled(true)
            check(driver.permissionRequests == 1, "a new explicit ready foreground toggle can request permission")
        }

        begin("default_disabled_never_prompts_or_requests")
        do {
            let f = Fixture(authorization: .notDetermined)
            check(!f.model.isEnabled, "defaults off")
            check(f.model.status.text == "已关闭", "disabled status")
            f.model.setForeground(true)
            f.values.actualAudio = true
            f.model.setRecordingActive(true)
            f.model.tick()
            f.driver.changeAuthorization(.authorized)
            check(f.driver.permissionRequests == 0, "default off never prompts")
            check(f.driver.locationRequests.isEmpty, "default off never samples")
            check(f.values.savedPreferences.isEmpty, "restore does not write preference")
            check(f.values.clearCount == 0, "no spurious clear")
        }

        begin("restored_true_does_not_automatically_prompt")
        do {
            let f = Fixture(enabled: true, authorization: .notDetermined)
            f.model.setForeground(true)
            f.values.actualAudio = true
            f.model.setRecordingActive(true)
            f.model.tick()
            f.model.setEnabled(true)
            f.model.setForeground(false)
            f.model.setForeground(true)
            check(f.model.isEnabled, "restores opt-in")
            check(f.driver.permissionRequests == 0, "restore/foreground/recording/tick/repeated true never prompt")
            check(f.driver.locationRequests.isEmpty, "no sample without authorization")
            check(f.model.status.text == "等待授权", "explicit pending authorization status")
            check(f.values.savedPreferences.isEmpty, "restore does not persist")
        }

        begin("only_explicit_foreground_transition_requests_authorization")
        do {
            let f = Fixture(authorization: .notDetermined)
            f.model.setEnabled(true)
            check(f.driver.permissionRequests == 0, "background toggle cannot prompt")
            f.model.setForeground(true)
            f.model.tick()
            check(f.driver.permissionRequests == 0, "foreground does not defer a background prompt")
            f.model.setEnabled(false)
            f.model.setEnabled(true)
            check(f.driver.permissionRequests == 1, "explicit foreground false-to-true prompts once")
            f.model.setEnabled(true)
            f.model.tick()
            f.driver.onAuthorizationChanged?()
            check(f.driver.permissionRequests == 1, "repeated true/tick/notification cannot reprompt")
            check(f.values.savedPreferences == [true, false, true], "only actual toggle changes persist")
        }

        begin("allow_once_expiry_permits_a_new_explicit_prompt")
        do {
            let f = Fixture(authorization: .notDetermined)
            f.model.setForeground(true)
            f.model.setEnabled(true)
            f.driver.changeAuthorization(.authorized)
            f.driver.changeAuthorization(.notDetermined)
            f.model.setForeground(false)
            f.model.setForeground(true)
            check(f.driver.permissionRequests == 1, "expiry and foreground do not prompt")
            f.model.setEnabled(false)
            f.model.setEnabled(true)
            check(f.driver.permissionRequests == 2, "another explicit opt-in can prompt after allow-once expiry")
            f.model.setEnabled(true)
            check(f.driver.permissionRequests == 2, "duplicate true remains idempotent")
            check(f.driver.locationRequests.isEmpty, "authorization workflow has no audio acquisition")
        }

        begin("authorization_without_actual_audio_cannot_sample")
        do {
            let f = Fixture(enabled: true)
            f.model.setForeground(true)
            f.model.tick()
            check(f.driver.locationRequests.isEmpty, "authorized idle does not sample")
            f.model.setRecordingActive(true)
            check(f.driver.locationRequests.isEmpty, "actual-audio guard defeats false recording signal")
            f.values.actualAudio = true
            f.model.tick()
            check(f.driver.locationRequests.isEmpty, "failed audio activation must be explicitly reactivated")
            f.model.setRecordingActive(true)
            check(f.driver.locationRequests.count == 1, "actual audio starts one acquisition")
            check(f.driver.permissionRequests == 0, "authorized sampling never prompts")
        }

        begin("sixty_second_cadence_and_twenty_second_timeout")
        do {
            let f = Fixture(); f.start()
            check(f.driver.locationRequests.count == 1, "initial acquisition")
            for _ in 0..<20 { f.model.tick(); f.model.setRecordingActive(true) }
            f.at(19.999); f.model.tick()
            check(f.driver.locationRequests.count == 1, "repeated status/ticks never overlap")
            check(f.driver.cancellationCount == 0, "no cancellation before deadline")
            f.at(20); f.model.tick()
            check(f.driver.cancellationCount == 1, "deadline cancels in-flight request")
            check(f.driver.currentID == nil, "timeout releases driver")
            check(f.model.status.text == "位置暂不可用", "timeout is metadata unavailable")
            f.at(59.999); f.model.tick()
            check(f.driver.locationRequests.count == 1, "timeout does not bypass cadence")
            f.at(60); f.model.tick()
            check(f.driver.locationRequests.count == 2, "next interval retries")
            let id = f.driver.locationRequests.last!
            f.at(60.5); f.driver.deliver(id, [f.fix(60.5)])
            check(f.values.locations.count == 1, "retry accepts current fix")
            f.at(119.999); f.model.tick()
            check(f.driver.locationRequests.count == 2, "successful reply does not shorten next interval")
            f.at(120); f.model.tick()
            check(f.driver.locationRequests.count == 3, "third interval starts once")
            check(f.values.clearCount == 0 && f.values.actualAudio, "timeout preserves audio and retained metadata")
        }

        begin("failure_releases_request_without_stopping_audio")
        do {
            let f = Fixture(); f.start()
            let id = f.driver.locationRequests[0]
            f.at(1); f.driver.deliver(id, nil)
            check(f.driver.currentID == nil, "failure releases request")
            check(f.model.status.text == "位置暂不可用", "failure is only location unavailable")
            check(f.values.locations.isEmpty && f.values.clearCount == 0 && f.values.actualAudio, "failure never writes, clears, or stops audio")
            f.at(20); f.model.tick()
            check(f.driver.cancellationCount == 0, "completed failure has no pending timeout")
            f.at(60); f.model.tick()
            check(f.driver.locationRequests.count == 2, "failure retries at next interval")
        }

        begin("normal_stop_keeps_last_fix_for_final_seal")
        do {
            let f = Fixture(); f.start()
            f.at(1); f.driver.deliver(f.driver.locationRequests[0], [f.fix(1)])
            f.values.actualAudio = false
            f.model.setRecordingActive(false)
            check(f.values.locations.count == 1 && f.values.clearCount == 0, "stop preserves final-segment metadata")
            f.at(90); f.model.tick()
            check(f.driver.locationRequests.count == 1, "stopped capture cannot request")
            f.values.actualAudio = true
            f.model.setRecordingActive(true)
            check(f.driver.locationRequests.count == 2, "resumed actual capture requests a new fix")
            f.model.setRecordingActive(false)
            check(f.driver.cancellationCount == 1, "stopping pending request cancels it")
            check(f.values.clearCount == 0, "pending cancellation still preserves final fix")
        }

        begin("pause_resume_rejects_old_success_and_failure_ids")
        do {
            let f = Fixture(); f.start()
            let old = f.driver.locationRequests[0]
            f.model.setRecordingActive(false)
            f.at(1); f.model.setRecordingActive(true)
            let current = f.driver.locationRequests.last!
            check(old != current, "resume has a distinct request ID")
            f.at(2); f.driver.deliver(old, [f.fix(2)])
            check(f.values.locations.isEmpty && f.driver.currentID == current, "old success cannot satisfy or stop current request")
            f.driver.deliver(old, nil)
            check(f.driver.currentID == current, "old failure cannot stop current request")
            f.driver.deliver(current, [f.fix(2)])
            check(f.values.locations == [f.fix(2)], "current result still succeeds")
            f.driver.deliver(old, [f.fix(2)])
            check(f.values.locations.count == 1 && f.values.clearCount == 0, "late old callback cannot rewrite metadata")
        }

        begin("background_cancels_without_clearing_and_foreground_restarts")
        do {
            let f = Fixture(); f.start()
            f.at(1); f.driver.deliver(f.driver.locationRequests[0], [f.fix(1)])
            f.at(60); f.model.tick()
            let old = f.driver.locationRequests.last!
            f.model.setForeground(false)
            check(f.driver.cancellationCount == 1, "background cancels acquisition")
            check(f.values.clearCount == 0, "background does not clear last fix")
            f.at(70); f.model.tick()
            check(f.driver.locationRequests.count == 2, "background does not retry")
            f.model.setForeground(true)
            let current = f.driver.locationRequests.last!
            check(f.driver.locationRequests.count == 3 && current != old, "foreground starts a fresh request")
            f.driver.deliver(old, [f.fix(70)])
            check(f.values.locations.count == 1 && f.driver.currentID == current, "old background request ignored")
            f.at(71); f.driver.deliver(current, [f.fix(71)])
            check(f.values.locations.count == 2, "foreground reply accepted")
            check(f.driver.permissionRequests == 0, "foreground never requests authorization")
        }

        begin("disable_clears_and_late_authorization_cannot_restart")
        do {
            let f = Fixture(); f.start()
            let id = f.driver.locationRequests[0]
            f.model.setEnabled(false)
            check(f.driver.cancellationCount == 1 && f.values.clearCount == 1, "off cancels and clears unsealed metadata")
            f.at(1); f.driver.deliver(id, [f.fix(1)])
            check(f.values.locations.isEmpty, "late off-result ignored")
            f.driver.changeAuthorization(.authorized)
            f.at(60); f.model.tick()
            check(f.driver.locationRequests.count == 1 && f.model.status.text == "已关闭", "late authorization cannot restart disabled controller")
            let waiting = Fixture(authorization: .notDetermined)
            waiting.start(); waiting.model.setEnabled(false)
            waiting.driver.changeAuthorization(.authorized)
            check(waiting.driver.permissionRequests == 1 && waiting.driver.locationRequests.isEmpty, "real pending authorization workflow remains off after late grant")
            check(waiting.values.clearCount == 1, "disable emits one clear")
        }

        begin("revocation_and_service_disable_cancel_and_clear")
        do {
            let f = Fixture(); f.start()
            let id = f.driver.locationRequests[0]
            f.driver.changeAuthorization(.denied)
            check(f.driver.cancellationCount == 1 && f.values.clearCount == 1, "revocation cancels and clears")
            check(f.model.status.text == "未获位置权限", "revocation status")
            f.driver.onAuthorizationChanged?()
            check(f.values.clearCount == 1, "duplicate revocation is idempotent")
            f.at(1); f.driver.deliver(id, [f.fix(1)])
            f.at(60); f.model.tick()
            check(f.values.locations.isEmpty && f.driver.locationRequests.count == 1, "revoked controller rejects late data and new samples")
            check(f.values.actualAudio && f.model.isEnabled, "revocation does not alter audio or user preference")
            let service = Fixture(); service.start()
            service.driver.servicesEnabled = false
            service.driver.onAuthorizationChanged?()
            check(service.values.clearCount == 1 && service.driver.cancellationCount == 1, "service disable cancels and clears")
            check(service.model.status.text == "位置暂不可用", "service disable distinct from denied permission")
        }

        begin("revocation_without_a_delivered_delegate_rejects_queued_fixes")
        do {
            for revokePermission in [true, false] {
                let f = Fixture(); f.start()
                let id = f.driver.locationRequests[0]
                // Core Location's authorization delegate can be queued after a result.
                if revokePermission { f.driver.authorization = .denied }
                else { f.driver.servicesEnabled = false }
                f.at(1)
                f.driver.deliver(id, [f.fix(1)])
                check(f.values.locations.isEmpty, "a queued fix cannot use stale permission/service caches")
                check(f.values.clearCount == 1, "the retained optional fix is cleared on observing revocation")
                f.at(60); f.model.tick()
                check(f.driver.locationRequests.count == 1, "revocation without an earlier delegate cannot start another acquisition")
            }
        }

        begin("stale_future_invalid_and_empty_fixes_are_rejected")
        do {
            let builders: [(String, (Fixture) -> [SegmentLocation]?)] = [
                ("stale", { [$0.fix(-1)] }), ("future", { [$0.fix(1)] }),
                ("latitude", { [$0.fix(0, latitude: 91)] }), ("longitude", { [$0.fix(0, longitude: 181)] }),
                ("negativeAccuracy", { [$0.fix(0, accuracy: -1)] }), ("infiniteAccuracy", { [$0.fix(0, accuracy: .infinity)] }),
                ("nanCoordinate", { [$0.fix(0, latitude: .nan)] }), ("empty", { _ in [] }),
            ]
            for (name, build) in builders {
                let f = Fixture(); f.start()
                f.driver.deliver(f.driver.locationRequests[0], build(f))
                check(f.values.locations.isEmpty && f.model.status.text == "位置暂不可用", name + " rejected")
                check(f.values.actualAudio && f.values.clearCount == 0, name + " does not affect audio or retained metadata")
                f.at(60); f.model.tick()
                check(f.driver.locationRequests.count == 2, name + " releases request for next interval")
            }
            let f = Fixture(); f.start()
            f.at(1); f.driver.deliver(f.driver.locationRequests[0], nil)
            f.at(60); f.model.tick()
            f.at(61); f.driver.deliver(f.driver.locationRequests.last!, [f.fix(59)])
            check(f.values.locations.isEmpty, "fix from same capture but before current request is rejected")
        }

        begin("deadline_callback_is_rejected_without_a_prior_timer_tick")
        do {
            let f = Fixture(); f.start()
            f.at(20); f.driver.deliver(f.driver.locationRequests[0], [f.fix(20)])
            check(f.values.locations.isEmpty && f.model.status.text == "位置暂不可用", "deadline is enforced in callback")
            f.at(60); f.model.tick()
            check(f.driver.locationRequests.count == 2, "deadline result releases request")
            check(f.values.clearCount == 0 && f.values.actualAudio, "deadline does not clear or stop audio")
        }

        begin("approximate_location_is_accepted_without_precision_upgrade")
        do {
            let f = Fixture(); f.start()
            f.at(5)
            let newest = f.fix(4, accuracy: 5_000)
            f.driver.deliver(f.driver.locationRequests[0], [f.fix(-1), f.fix(1, accuracy: 100_000), newest, f.fix(6)])
            check(f.values.locations == [newest], "newest valid coarse fix accepted, stale/future excluded")
            check(f.values.locations[0].horizontalAccuracy == 5_000, "accuracy is preserved without fabrication")
            check(f.driver.permissionRequests == 0, "coarse fix does not ask for more permission")
            check(f.model.status.text == "已开启", "coarse success is available metadata")
        }

        begin("lost_actual_audio_stops_acquisition_and_rejects_pending_result")
        do {
            let tick = Fixture(); tick.start()
            tick.values.actualAudio = false
            tick.at(1); tick.model.tick()
            check(tick.driver.cancellationCount == 1 && tick.values.clearCount == 0, "lost audio cancels without clearing final fix")
            tick.at(60); tick.model.tick()
            check(tick.driver.locationRequests.count == 1, "lost audio never keeps sampling")
            let reply = Fixture(); reply.start()
            reply.values.actualAudio = false
            reply.at(1); reply.driver.deliver(reply.driver.locationRequests[0], [reply.fix(1)])
            check(reply.values.locations.isEmpty && reply.values.clearCount == 0, "result is rejected if actual audio ended")
            reply.values.actualAudio = true
            reply.model.tick()
            check(reply.driver.locationRequests.count == 1, "actual audio requires fresh lifecycle activation after loss")
            reply.model.setRecordingActive(true)
            check(reply.driver.locationRequests.count == 2, "fresh audio activation resumes sampling")
        }

        begin("first_launch_requires_foreground_interface_ready_and_modal_permission")
        do {
            let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
            for order in orders {
                let f = Fixture(enabled: nil, authorization: .notDetermined)
                check(!f.model.isIntroductionPresented && !f.model.isEnabled, "new installation starts off with no sheet")
                for (index, gate) in order.enumerated() {
                    switch gate {
                    case 0: f.model.setForeground(true)
                    case 1: f.model.setInterfaceReady()
                    default: f.model.setIntroductionPresentationAllowed(true)
                    }
                    check(f.model.isIntroductionPresented == (index == 2), "all gates required in order \(order), step \(index)")
                }
                f.model.setForeground(true)
                f.model.setInterfaceReady()
                f.model.setIntroductionPresentationAllowed(true)
                f.model.tick()
                check(f.driver.permissionRequests == 0 && f.driver.locationRequests.isEmpty, "app introduction cannot request system permission or GPS")
                check(f.values.savedPreferences.isEmpty && f.values.savedIntroductionHandled.isEmpty, "presentation itself does not persist a choice")
            }
        }

        begin("acceptance_waits_for_dismissal_before_permission_and_persistence")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined)
            f.presentIntroduction()
            f.acceptIntroduction()
            check(!f.model.isIntroductionPresented && !f.model.isEnabled, "accept closes app sheet before enabling")
            check(f.driver.permissionRequests == 0, "accept does not overlap system prompt with app sheet")
            check(f.values.preference == nil && !f.values.introductionHandled, "accept is not yet a completed persisted choice")
            f.acceptIntroduction()
            f.declineIntroduction()
            check(f.values.savedIntroductionHandled.isEmpty, "actions on closing sheet cannot overwrite pending acceptance")
            f.dismissIntroduction()
            check(f.model.isEnabled && f.driver.permissionRequests == 1, "dismissal enables and requests WhenInUse once")
            check(f.values.savedPreferences == [true] && f.values.savedIntroductionHandled == [true], "completed acceptance persists both decisions once")
            check(f.driver.locationRequests.isEmpty, "permission request alone does not sample")
            f.dismissIntroduction()
            f.model.setInterfaceReady()
            check(f.driver.permissionRequests == 1 && !f.model.isIntroductionPresented, "repeat callbacks never prompt or reintroduce")
            check(f.values.savedIntroductionHandled == [true], "completion remains idempotent")
        }

        begin("decline_persists_without_system_prompt_and_survives_restart")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined)
            f.presentIntroduction()
            f.declineIntroduction()
            check(!f.model.isIntroductionPresented && !f.model.isEnabled, "decline closes sheet and leaves location off")
            check(f.values.savedIntroductionHandled == [true], "decline completion is durable")
            check(f.driver.permissionRequests == 0 && f.driver.locationRequests.isEmpty, "decline uses no system service")
            f.dismissIntroduction()
            f.model.setForeground(false)
            f.model.setForeground(true)
            check(!f.model.isIntroductionPresented, "decline stays handled after foreground")
            let restarted = f.restart()
            restarted.presentIntroduction()
            check(!restarted.model.isIntroductionPresented && !restarted.model.isEnabled, "restart preserves decline")
            check(restarted.driver.permissionRequests == 0, "restart after decline never prompts")
            restarted.model.setEnabled(true)
            check(restarted.driver.permissionRequests == 1 && restarted.model.isEnabled, "later explicit manual opt-in still works")
        }

        begin("system_denial_after_acceptance_never_reintroduces_or_reprompts")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined)
            f.presentIntroduction()
            f.acceptIntroduction()
            f.dismissIntroduction()
            f.driver.changeAuthorization(.denied)
            f.model.setForeground(false)
            f.model.setForeground(true)
            f.model.setInterfaceReady()
            check(f.driver.permissionRequests == 1 && !f.model.isIntroductionPresented, "denial does not reopen introduction or repeat system prompt")
            check(f.model.status.text == "未获位置权限", "denial is visible")
            f.model.setEnabled(false)
            f.model.setEnabled(true)
            check(f.driver.permissionRequests == 1, "denied permission cannot be requested by repeated toggling")
            let restarted = f.restart()
            restarted.presentIntroduction()
            check(!restarted.model.isIntroductionPresented && restarted.driver.permissionRequests == 0, "denied installation remains handled on restart")
            check(restarted.model.status.text == "未获位置权限", "restored denied state remains truthful")
        }

        begin("build_eight_boolean_choices_migrate_for_all_authorization_states")
        do {
            for preference in [false, true] {
                for authorization: RecordingLocationAuthorization in [.notDetermined, .authorized, .denied] {
                    let f = Fixture(enabled: preference, authorization: authorization)
                    check(f.model.isEnabled == preference, "migration preserves explicit \(preference)")
                    check(f.values.savedIntroductionHandled == [true], "legacy explicit choice migrates introduction completion")
                    check(f.values.savedPreferences.isEmpty, "migration never rewrites the recording-location preference")
                    f.presentIntroduction()
                    check(!f.model.isIntroductionPresented && f.driver.permissionRequests == 0, "legacy preference suppresses app and system prompts")
                    check(f.driver.locationRequests.isEmpty, "legacy preference alone cannot start GPS")
                    let restarted = f.restart()
                    restarted.presentIntroduction()
                    check(!restarted.model.isIntroductionPresented && restarted.values.savedIntroductionHandled.isEmpty, "migration is idempotent across restart")
                }
            }
        }

        begin("existing_system_decisions_migrate_even_without_a_boolean_preference")
        do {
            for authorization: RecordingLocationAuthorization in [.authorized, .denied] {
                let f = Fixture(enabled: nil, authorization: authorization)
                f.presentIntroduction()
                check(!f.model.isEnabled && !f.model.isIntroductionPresented, "existing system decision does not opt user into recording metadata")
                check(f.values.savedIntroductionHandled == [true] && f.values.preference == nil, "only introduction completion migrates")
                check(f.driver.permissionRequests == 0 && f.driver.locationRequests.isEmpty, "migration is passive")
                f.driver.changeAuthorization(.notDetermined)
                f.model.setForeground(false)
                f.model.setForeground(true)
                check(!f.model.isIntroductionPresented && f.driver.permissionRequests == 0, "later authorization expiry cannot recreate first-run onboarding")
                let restarted = f.restart()
                restarted.presentIntroduction()
                check(!restarted.model.isIntroductionPresented, "expired migrated system choice remains handled after restart")
            }
        }

        begin("already_handled_introduction_remains_passive_without_any_preference")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined, introductionHandled: true)
            f.presentIntroduction()
            check(!f.model.isIntroductionPresented && !f.model.isEnabled, "handled introduction with nil preference stays off")
            check(f.values.savedIntroductionHandled.isEmpty && f.values.savedPreferences.isEmpty, "passive restoration does not write preferences")
            check(f.driver.permissionRequests == 0, "handled restoration never prompts")
            f.model.setEnabled(true)
            check(f.driver.permissionRequests == 1, "explicit manual retry remains available")
        }

        begin("allow_once_expiry_after_introduction_requires_manual_retry")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined)
            f.presentIntroduction()
            f.acceptIntroduction()
            f.dismissIntroduction()
            f.driver.changeAuthorization(.authorized)
            f.driver.changeAuthorization(.notDetermined)
            f.model.setForeground(false)
            f.model.setForeground(true)
            check(!f.model.isIntroductionPresented && f.driver.permissionRequests == 1, "Allow Once expiry causes neither introduction nor system prompt")
            f.model.setEnabled(true)
            check(f.driver.permissionRequests == 1, "duplicate true is not a retry gesture")
            f.model.setEnabled(false)
            f.model.setEnabled(true)
            check(f.driver.permissionRequests == 2, "explicit off/on can request after Allow Once expires")
            check(f.values.savedIntroductionHandled == [true], "manual retry does not duplicate intro persistence")
        }

        begin("background_during_acceptance_cancels_pending_permission_until_new_accept")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined)
            f.presentIntroduction()
            f.acceptIntroduction()
            f.model.setForeground(false)
            f.dismissIntroduction()
            check(!f.model.isEnabled && f.driver.permissionRequests == 0, "background dismissal cannot authorize")
            check(f.values.preference == nil && !f.values.introductionHandled, "abandoned acceptance is not persisted")
            f.model.setForeground(true)
            check(f.model.isIntroductionPresented && f.driver.permissionRequests == 0, "foreground returns only to app introduction")
            f.acceptIntroduction()
            check(f.driver.permissionRequests == 0, "fresh acceptance still waits for new dismissal")
            f.dismissIntroduction()
            check(f.driver.permissionRequests == 1 && f.model.isEnabled, "fresh explicit acceptance completes normally")
            check(f.values.savedIntroductionHandled == [true] && f.values.savedPreferences == [true], "only completed acceptance persists")
        }

        begin("foreground_before_old_dismissal_does_not_race_a_new_sheet")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined)
            f.presentIntroduction()
            f.acceptIntroduction()
            f.model.setForeground(false)
            f.model.setForeground(true)
            f.model.setInterfaceReady()
            f.model.setIntroductionPresentationAllowed(true)
            check(!f.model.isIntroductionPresented, "old in-flight dismissal blocks a new sheet")
            check(f.driver.permissionRequests == 0 && f.values.savedIntroductionHandled.isEmpty, "foreground cannot complete abandoned acceptance")
            f.dismissIntroduction()
            check(f.model.isIntroductionPresented && f.driver.permissionRequests == 0, "old dismissal presents only a fresh app sheet")
            check(!f.model.isEnabled && f.values.preference == nil, "fresh sheet does not inherit old acceptance")
            f.acceptIntroduction()
            f.dismissIntroduction()
            check(f.driver.permissionRequests == 1 && f.model.isEnabled, "new sheet requires a new explicit acceptance")
        }

        begin("modal_block_defaults_off_and_waits_until_other_modal_releases")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined)
            f.model.setForeground(true)
            f.model.setInterfaceReady()
            check(!f.model.isIntroductionPresented, "modal presentation defaults disallowed")
            f.model.setIntroductionPresentationAllowed(false)
            check(!f.model.isIntroductionPresented && f.driver.permissionRequests == 0, "active competing modal keeps introduction hidden")
            f.model.setIntroductionPresentationAllowed(true)
            check(f.model.isIntroductionPresented, "releasing competing modal permits app introduction")
            f.appearIntroduction()
            f.model.setIntroductionPresentationAllowed(false)
            check(!f.model.isIntroductionPresented, "new competing modal dismisses introduction")
            f.model.setIntroductionPresentationAllowed(true)
            check(!f.model.isIntroductionPresented, "old sheet must dismiss before a new presentation")
            f.dismissIntroduction()
            check(f.model.isIntroductionPresented && f.driver.permissionRequests == 0, "old sheet dismissal safely reopens app-only introduction")
        }

        begin("modal_block_during_acceptance_discards_pending_permission")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined)
            f.presentIntroduction()
            f.acceptIntroduction()
            f.model.setIntroductionPresentationAllowed(false)
            f.dismissIntroduction()
            check(!f.model.isEnabled && f.driver.permissionRequests == 0, "competing modal prevents queued system prompt")
            check(f.values.preference == nil && !f.values.introductionHandled, "blocked acceptance does not persist completion")
            f.model.setIntroductionPresentationAllowed(true)
            check(f.model.isIntroductionPresented && f.driver.permissionRequests == 0, "unblocking offers app introduction without automatic permission")
            f.acceptIntroduction()
            f.dismissIntroduction()
            check(f.driver.permissionRequests == 1, "new acceptance after unblock can prompt")
        }

        begin("system_authorization_changed_while_introduction_is_open")
        do {
            for authorization: RecordingLocationAuthorization in [.authorized, .denied] {
                let f = Fixture(enabled: nil, authorization: .notDetermined)
                f.presentIntroduction()
                f.driver.changeAuthorization(authorization)
                check(!f.model.isIntroductionPresented && !f.model.isEnabled, "external system choice closes introduction without opt-in")
                check(f.values.savedIntroductionHandled == [true] && f.values.preference == nil, "external system choice is remembered without creating an opt-in")
                f.dismissIntroduction()
                check(f.driver.permissionRequests == 0 && f.driver.locationRequests.isEmpty, "dismissal after external choice remains passive")
                f.driver.changeAuthorization(.notDetermined)
                check(!f.model.isIntroductionPresented, "external choice expiry does not reopen introduction")
            }
        }

        begin("process_restart_after_unfinished_acceptance_reintroduces_app_only")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined)
            f.presentIntroduction()
            f.acceptIntroduction()
            let restarted = f.restart()
            restarted.presentIntroduction()
            check(restarted.model.isIntroductionPresented && !restarted.model.isEnabled, "unfinished acceptance survives only as unhandled introduction")
            check(restarted.driver.permissionRequests == 0 && restarted.values.savedIntroductionHandled.isEmpty, "restart cannot complete an old authorization gesture")
            restarted.declineIntroduction()
            restarted.dismissIntroduction()
            check(restarted.values.savedIntroductionHandled == [true] && restarted.driver.permissionRequests == 0, "new launch permits an independent decline")
        }

        begin("manual_toggle_while_introduction_is_open_does_not_double_prompt")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined)
            f.presentIntroduction()
            f.model.setEnabled(true)
            check(!f.model.isIntroductionPresented && f.driver.permissionRequests == 1, "explicit manual opt-in closes introduction and requests once")
            check(f.values.savedIntroductionHandled == [true] && f.values.savedPreferences == [true], "manual choice completes introduction")
            f.dismissIntroduction()
            f.acceptIntroduction()
            check(f.driver.permissionRequests == 1 && !f.model.isIntroductionPresented, "stale sheet callbacks cannot double-prompt")
            let off = Fixture(enabled: nil, authorization: .notDetermined)
            off.presentIntroduction()
            off.model.setEnabled(false)
            off.dismissIntroduction()
            check(!off.model.isIntroductionPresented && !off.model.isEnabled && off.driver.permissionRequests == 0, "explicit false choice suppresses introduction even when already off")
            check(off.values.savedIntroductionHandled == [true], "explicit false choice is durable via intro completion")
        }

        begin("requested_but_unappeared_sheet_recovers_without_any_dismiss_callback")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined)
            f.model.setForeground(true)
            f.model.setInterfaceReady()
            f.model.setIntroductionPresentationAllowed(true)
            let old = f.model.introductionPresentationID!
            check(f.model.isIntroductionPresented, "first presentation is requested without simulating appearance")
            f.model.setForeground(false)
            check(f.model.introductionPresentationID == nil && !f.model.isIntroductionPresented, "unappeared request releases identity immediately on background")
            f.model.setForeground(true)
            let current = f.model.introductionPresentationID!
            check(current != old && f.model.isIntroductionPresented, "foreground requests a new sheet without waiting for absent onDismiss")
            check(f.driver.permissionRequests == 0 && !f.model.isEnabled, "reintroduction remains app-only")
            check(f.values.savedIntroductionHandled.isEmpty && f.values.savedPreferences.isEmpty, "aborted presentation persists no decision")
            f.model.introductionDidAppear(id: current)
            f.model.acceptIntroduction(id: current)
            check(f.driver.permissionRequests == 0, "new accepted sheet waits for its own dismissal")
            f.model.introductionDidDismiss(id: current)
            check(f.driver.permissionRequests == 1 && f.model.isEnabled, "new presentation completes after explicit new acceptance")
        }

        begin("unappeared_modal_block_releases_identity_without_dismissal")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined)
            f.model.setForeground(true)
            f.model.setInterfaceReady()
            f.model.setIntroductionPresentationAllowed(true)
            let old = f.model.introductionPresentationID!
            f.model.setIntroductionPresentationAllowed(false)
            check(f.model.introductionPresentationID == nil && !f.model.isIntroductionPresented, "modal block releases an unappeared request")
            f.model.setIntroductionPresentationAllowed(true)
            let current = f.model.introductionPresentationID!
            check(current != old && f.model.isIntroductionPresented, "unblocking can request another sheet without onDismiss")
            f.model.introductionDidDismiss(id: old)
            check(f.model.introductionPresentationID == current && f.model.isIntroductionPresented, "late old dismissal cannot dismiss or replace new request")
            check(f.driver.permissionRequests == 0 && f.values.savedIntroductionHandled.isEmpty, "modal cancellation cannot prompt or complete onboarding")
        }

        begin("all_old_presentation_callbacks_are_isolated_from_a_new_uuid")
        do {
            for event in ["appear", "dismiss", "accept", "decline"] {
                let f = Fixture(enabled: nil, authorization: .notDetermined)
                f.model.setForeground(true)
                f.model.setInterfaceReady()
                f.model.setIntroductionPresentationAllowed(true)
                let old = f.model.introductionPresentationID!
                f.model.setForeground(false)
                f.model.setForeground(true)
                let current = f.model.introductionPresentationID!
                switch event {
                case "appear": f.model.introductionDidAppear(id: old)
                case "dismiss": f.model.introductionDidDismiss(id: old)
                case "accept": f.model.acceptIntroduction(id: old)
                default: f.model.declineIntroduction(id: old)
                }
                check(f.model.introductionPresentationID == current && f.model.isIntroductionPresented, "old \(event) cannot replace, hide, or dismiss new UUID")
                check(f.values.savedPreferences.isEmpty && f.values.savedIntroductionHandled.isEmpty, "old \(event) cannot persist any new choice")
                check(f.driver.permissionRequests == 0 && !f.model.isEnabled, "old \(event) cannot request permission or opt in")
                f.model.introductionDidAppear(id: current)
                f.model.acceptIntroduction(id: current)
                f.model.introductionDidDismiss(id: old)
                check(f.driver.permissionRequests == 0 && f.model.introductionPresentationID == current, "old dismissal cannot complete new acceptance after \(event)")
                f.model.introductionDidDismiss(id: current)
                check(f.driver.permissionRequests == 1 && f.model.isEnabled, "current UUID completes normally after old \(event)")
                check(f.values.savedPreferences == [true] && f.values.savedIntroductionHandled == [true], "only current UUID persists after old \(event)")
            }
        }

        begin("late_old_appearance_cannot_mark_the_new_request_as_appeared")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined)
            f.model.setForeground(true)
            f.model.setInterfaceReady()
            f.model.setIntroductionPresentationAllowed(true)
            let old = f.model.introductionPresentationID!
            f.model.setForeground(false)
            f.model.setForeground(true)
            let second = f.model.introductionPresentationID!
            f.model.introductionDidAppear(id: old)
            f.model.setForeground(false)
            check(f.model.introductionPresentationID == nil, "old appearance cannot make new unappeared request wait for dismissal")
            f.model.setForeground(true)
            let third = f.model.introductionPresentationID!
            check(third != old && third != second && f.model.isIntroductionPresented, "another foreground transition remains recoverable without dismissal")
            f.model.introductionDidDismiss(id: old)
            f.model.introductionDidDismiss(id: second)
            check(f.model.introductionPresentationID == third && f.model.isIntroductionPresented, "both stale dismissals preserve third UUID")
            check(f.driver.permissionRequests == 0 && f.values.savedIntroductionHandled.isEmpty, "all abandoned requests remain passive")
        }

        begin("appeared_sheet_keeps_identity_until_matching_dismissal")
        do {
            let f = Fixture(enabled: nil, authorization: .notDetermined)
            f.presentIntroduction()
            let old = f.model.introductionPresentationID!
            f.model.setForeground(false)
            check(f.model.introductionPresentationID == old && !f.model.isIntroductionPresented, "appeared sheet retains UUID while dismissing")
            f.model.setForeground(true)
            check(f.model.introductionPresentationID == old && !f.model.isIntroductionPresented, "foreground cannot overlap an appeared closing sheet")
            f.model.introductionDidDismiss(id: UUID())
            check(f.model.introductionPresentationID == old, "unrelated dismissal cannot release appeared sheet")
            f.model.introductionDidDismiss(id: old)
            let current = f.model.introductionPresentationID!
            check(current != old && f.model.isIntroductionPresented, "matching dismissal releases closing sheet before new presentation")
            f.model.acceptIntroduction(id: old)
            f.model.declineIntroduction(id: old)
            check(f.model.introductionPresentationID == current && f.model.isIntroductionPresented, "old button events cannot act on fresh presentation")
            check(f.driver.permissionRequests == 0 && f.values.savedIntroductionHandled.isEmpty, "appeared cancellation cannot authorize")
        }

        let report: [String: Any] = [
            "status": failures.isEmpty ? "passed" : "failed",
            "caseCount": caseNames.count, "assertionCount": assertions,
            "cases": caseNames, "failures": failures,
            "scope": "Actual RecordingLocationManager.swift + RecordingCore; injected fake driver and clock; timers disabled; no system driver, permission, GPS, or recording devices instantiated."
        ]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let reportPath = CommandLine.arguments[1]
        try bytes.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        print(String(data: bytes, encoding: .utf8)!)
        if !failures.isEmpty { exit(1) }
    }
}
