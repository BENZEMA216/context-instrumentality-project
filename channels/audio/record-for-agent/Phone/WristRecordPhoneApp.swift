import SwiftUI

@main
struct WristRecordPhoneApp: App {
    @UIApplicationDelegateAdaptor(AutomaticDeliveryAppDelegate.self) private var appDelegate
    @StateObject private var store = PhoneStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneHomeView()
                .environmentObject(store)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.didBecomeActive() }
                    if phase == .background { store.didEnterBackground() }
                }
        }
    }
}
