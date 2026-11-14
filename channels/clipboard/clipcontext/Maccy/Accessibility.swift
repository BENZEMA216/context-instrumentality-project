import AppKit
@preconcurrency import ApplicationServices

struct Accessibility {
  static var isTrusted: Bool { AXIsProcessTrusted() }

  /// Permission is checked at the time of the action because it can be revoked
  /// while the app is running. Never report a paste as successful without it.
  @MainActor
  static func requestPermissionIfNeeded(forPasteStack: Bool = false) -> Bool {
    guard !isTrusted else { return true }

    let alert = NSAlert()
    alert.messageText = NSLocalizedString("AccessibilityPermissionTitle", comment: "")
    alert.informativeText = NSLocalizedString(
      forPasteStack ? "AccessibilityPermissionStackMessage" : "AccessibilityPermissionPasteMessage",
      comment: ""
    )
    alert.alertStyle = .informational
    alert.addButton(withTitle: NSLocalizedString("AccessibilityOpenSettings", comment: ""))
    alert.addButton(withTitle: NSLocalizedString("AccessibilityLater", comment: ""))
    alert.buttons[0].setAccessibilityIdentifier("accessibility-open-settings")
    alert.buttons[1].setAccessibilityIdentifier("accessibility-later")
    NSApp.activate(ignoringOtherApps: true)

    if alert.runModal() == .alertFirstButtonReturn {
      // The system prompt registers this app in Privacy settings. macOS still
      // requires the user to authorize it; applications cannot enable themselves.
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
      }
    }
    return false
  }
}
