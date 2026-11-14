import Defaults
import KeyboardShortcuts
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  nonisolated static let isTesting = CommandLine.arguments.contains("enable-testing")
    || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  #if DEBUG
  nonisolated static let qaDirectory: URL? = {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["CLIPCONTEXT_QA_DIRECTORY"], path.hasPrefix("/"),
          let board = environment["CLIPCONTEXT_QA_PASTEBOARD"], !board.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }()
  #endif
  static let googleDrive = ClipboardGoogleDrive()
  var panel: FloatingPanel<ContentView>!

  @objc
  private lazy var statusItem: NSStatusItem = {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.behavior = .removalAllowed
    statusItem.button?.action = #selector(performStatusItemClick)
    statusItem.button?.image = Defaults[.menuIcon].image
    statusItem.button?.imagePosition = .imageLeft
    statusItem.button?.target = self
    return statusItem
  }()

  // Base accessibility label for the status item; kept separate from the optional
  // dynamic `title` (recent copy text) so VoiceOver always announces something
  // meaningful even when that preference is off or the app is disabled.
  private func updateStatusItemAccessibilityLabel() {
    var accessibilityLabel = NSLocalizedString("status_item_accessibility_label", comment: "")
    if isStatusItemDisabled {
      accessibilityLabel += " — \(NSLocalizedString("status_item_disabled_accessibility_suffix", comment: ""))"
    }
    statusItem.button?.setAccessibilityLabel(accessibilityLabel)
  }

  private var isStatusItemDisabled: Bool {
    Defaults[.ignoreEvents] || Defaults[.enabledPasteboardTypes].isEmpty
  }

  private var statusItemVisibilityObserver: NSKeyValueObservation?
  private var waitingForArchiveBeforeQuit = false

  func applicationWillFinishLaunching(_ notification: Notification) { // swiftlint:disable:this function_body_length
    #if DEBUG
    if Self.isTesting {
      // Start from a clean slate for the isolated testing preferences.
      UserDefaults.standard.removePersistentDomain(forName: Defaults.Keys.testingSuiteName)
    }
    #endif

    // Bridge FloatingPanel via AppDelegate.
    AppState.shared.appDelegate = self

    Clipboard.shared.onNewCopy { History.shared.add($0) }
    #if DEBUG
    if !History.isRunningUnitTests { Clipboard.shared.start() }
    #else
    Clipboard.shared.start()
    #endif

    Task {
      for await _ in Defaults.updates(.clipboardCheckInterval, initial: false) {
        Clipboard.shared.restart()
      }
    }

    statusItemVisibilityObserver = observe(\.statusItem.isVisible, options: .new) { _, change in
      if let newValue = change.newValue, Defaults[.showInStatusBar] != newValue {
        Defaults[.showInStatusBar] = newValue
      }
    }

    Task {
      for await value in Defaults.updates(.showInStatusBar) {
        statusItem.isVisible = value
      }
    }

    Task {
      for await value in Defaults.updates(.menuIcon, initial: false) {
        statusItem.button?.image = value.image
      }
    }

    synchronizeMenuIconText()
    Task {
      for await value in Defaults.updates(.showRecentCopyInMenuBar) {
        if value {
          statusItem.button?.title = AppState.shared.menuIconText
        } else {
          statusItem.button?.title = ""
        }
      }
    }

    updateStatusItemAccessibilityLabel()

    Task {
      for await _ in Defaults.updates(.ignoreEvents) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
        updateStatusItemAccessibilityLabel()
      }
    }

    Task {
      for await _ in Defaults.updates(.enabledPasteboardTypes) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
        updateStatusItemAccessibilityLabel()
      }
    }
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    NSApp.appearance = Defaults[.interfaceAppearance].appearance
    Task {
      for await value in Defaults.updates(.interfaceAppearance, initial: false) {
        NSApp.appearance = value.appearance
      }
    }
    migrateUserDefaults()
    disableUnusedGlobalHotkeys()

    panel = FloatingPanel(
      contentRect: NSRect(origin: .zero, size: Defaults[.windowSize]),
      identifier: Bundle.main.bundleIdentifier ?? "com.benzema.ClipContext",
      statusBarButton: statusItem.button,
      onClose: { AppState.shared.popup.reset() }
    ) {
      ContentView()
    }

    if !Self.isTesting {
      Self.configureGoogleDrive()
      ClipboardArchive.shared.start()
    }
    if CommandLine.arguments.contains("--agent-settings") {
      AppState.shared.openPreferences(showArchive: true)
    }
  }

  static func configureGoogleDrive() {
    let archive = ClipboardArchive.shared
    if googleDrive.isConnected {
      archive.remotePublisher = { data, deviceID in
        try await googleDrive.publish(snapshot: data, deviceID: deviceID)
      }
    } else {
      archive.remotePublisher = nil
    }
    archive.invalidateRemotePublication()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    panel.toggle(height: AppState.shared.popup.height)
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard Defaults[.clearOnQuit] else { return .terminateNow }
    guard !waitingForArchiveBeforeQuit else { return .terminateLater }

    Clipboard.shared.stop()
    AppState.shared.history.clear()
    let archive = ClipboardArchive.shared
    guard archive.isPublishing else { return .terminateNow }

    waitingForArchiveBeforeQuit = true
    Task { @MainActor in
      // Give the cleared history a chance to replace the snapshot without
      // keeping the application open indefinitely when a cloud provider stalls.
      let clock = ContinuousClock()
      let deadline = clock.now + .seconds(8)
      while archive.isPublishing && clock.now < deadline {
        try? await clock.sleep(for: .milliseconds(100))
      }
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  private func ensureMigration(key: String, _ action: () -> Void) {
    if Defaults[.migrations][key] != true {
      action()
      Defaults[.migrations][key] = true
    }
  }

  @MainActor
  private func migrateUserDefaults() {
    ensureMigration(key: "2024-07-01-version-2") {
      // Start 2.x from scratch.
      Defaults.reset(.migrations)

      // Inverse hide* configuration keys.
      Defaults[.showFooter] = !UserDefaults.standard.bool(forKey: "hideFooter")
      Defaults[.showSearch] = !UserDefaults.standard.bool(forKey: "hideSearch")
      Defaults[.showTitle] = !UserDefaults.standard.bool(forKey: "hideTitle")
      UserDefaults.standard.removeObject(forKey: "hideFooter")
      UserDefaults.standard.removeObject(forKey: "hideSearch")
      UserDefaults.standard.removeObject(forKey: "hideTitle")
    }

    ensureMigration(key: "2025-07-04-add-jpeg-heic") {
      var types = Defaults[.enabledPasteboardTypes]
      if !types.isDisjoint(with: StorageType.images.types) {
        types.formUnion(StorageType.images.types)
      }
      Defaults[.enabledPasteboardTypes] = types
    }

    ensureMigration(key: "2026-08-12-cleanup-orphaned-history-item-contents") {
      _ = try? Storage.shared.cleanupOrphanedContents()
    }

    ensureMigration(key: "2026-08-31-sanitize-history-item-titles") {
      _ = try? Storage.shared.sanitizeTitles()
    }

    ensureMigration(key: "2026-09-15-remove-unpersistable-contents") {
      _ = try? Storage.shared.removeUnpersistableContents()
    }

    // The following defaults are not used in Maccy 2.x
    // and should be removed in 3.x.
    // - LaunchAtLogin__hasMigrated
    // - avoidTakingFocus
    // - saratovSeparator
    // - maxMenuItemLength
    // - maxMenuItems
  }

  @objc
  private func performStatusItemClick() {
    let modifierFlags = (NSApp.currentEvent?.modifierFlags ?? [])
      .union(NSEvent.modifierFlags)
      .intersection(.deviceIndependentFlagsMask)

    if modifierFlags.contains(.option) {
      let shouldPause = !Defaults[.ignoreEvents]
      Defaults[.ignoreOnlyNextEvent] = shouldPause && modifierFlags.contains(.shift)
      Defaults[.ignoreEvents] = shouldPause

      return
    }

    panel.toggle(height: AppState.shared.popup.height, at: .statusItem)
  }

  private func synchronizeMenuIconText() {
    _ = withObservationTracking {
      AppState.shared.menuIconText
    } onChange: {
      DispatchQueue.main.async {
        if Defaults[.showRecentCopyInMenuBar] {
          self.statusItem.button?.title = AppState.shared.menuIconText
        }
        self.synchronizeMenuIconText()
      }
    }
  }

  private func disableUnusedGlobalHotkeys() {
    let names: [KeyboardShortcuts.Name] = [.delete, .pin, .togglePreview]
    KeyboardShortcuts.disable(names)

    NotificationCenter.default.addObserver(
      forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
      object: nil,
      queue: nil
    ) { notification in
      guard let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
            names.contains(name) else { return }
      MainActor.assumeIsolated {
        KeyboardShortcuts.disable(name)
      }
    }
  }
}
