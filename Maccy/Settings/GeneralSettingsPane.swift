import AppKit
import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

enum ClipSettingsPage: String, CaseIterable, Identifiable {
  case general, archive, privacy, shortcuts, appearance, advanced

  var id: Self { self }

  var title: String {
    switch self {
    case .general: String(localized: "Title", table: "GeneralSettings")
    case .archive: String(localized: "ClipSettingsAgent")
    case .privacy: String(localized: "ClipSettingsPrivacy")
    case .shortcuts: String(localized: "ClipSettingsShortcuts")
    case .appearance: String(localized: "Title", table: "AppearanceSettings")
    case .advanced: String(localized: "Title", table: "AdvancedSettings")
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .archive: "sparkles"
    case .privacy: "hand.raised"
    case .shortcuts: "keyboard"
    case .appearance: "paintpalette"
    case .advanced: "slider.horizontal.3"
    }
  }
}

@MainActor
@Observable
private final class ClipSettingsNavigation {
  private(set) var visited: Set<ClipSettingsPage> = [.general]

  var selection: ClipSettingsPage = .general {
    didSet {
      visited.insert(selection)
    }
  }
}

@MainActor
final class ClipContextSettingsWindowController: NSWindowController {
  private let navigation = ClipSettingsNavigation()

  init() {
    let contentSize = NSSize(width: 648, height: 600)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    super.init(window: window)

    window.contentViewController = NSHostingController(rootView: ClipSettingsWindow(navigation: navigation))
    window.title = String(localized: "ClipSettingsWindowTitle")
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.backgroundColor = .textBackgroundColor
    window.contentMinSize = NSSize(width: 620, height: 480)
    window.setContentSize(contentSize)
    window.isReleasedWhenClosed = false
    window.center()
    window.setFrameUsingName("ClipContextSettings")
    window.setFrameAutosaveName("ClipContextSettings")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  func show(page: ClipSettingsPage?) {
    if let page {
      navigation.selection = page
    }
    NSApp.activate()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}

private struct ClipSettingsWindow: View {
  let navigation: ClipSettingsNavigation

  var body: some View {
    HStack(alignment: .top, spacing: 20) {
      sidebar
        .frame(width: 200)
        .padding([.leading, .vertical], 8)

      ZStack(alignment: .topLeading) {
        ForEach(ClipSettingsPage.allCases.filter(navigation.visited.contains)) { page in
          let isSelected = navigation.selection == page

          ScrollView {
            VStack(alignment: .leading, spacing: 20) {
              Text(page.title)
                .font(.system(size: 17, weight: .semibold))
                .padding(.leading, 10)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("settings-heading-\(page.rawValue)")
              content(for: page)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 20)
            .padding(.top, 17)
            .padding(.bottom, 12)
          }
          .ignoresSafeArea(.container, edges: .top)
          .opacity(isSelected ? 1 : 0)
          .disabled(!isSelected)
          .allowsHitTesting(isSelected)
          .accessibilityHidden(!isSelected)
        }
      }
    }
    .background(Color(nsColor: .textBackgroundColor))
    .ignoresSafeArea(.container, edges: .top)
    .frame(minWidth: 620, minHeight: 480)
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(ClipSettingsPage.allCases) { page in
        Button {
          navigation.selection = page
        } label: {
          Label {
            Text(page.title)
              .lineLimit(1)
          } icon: {
            Image(systemName: page.symbol)
              .font(.system(size: 16))
              .foregroundStyle(.primary)
              .frame(width: 19)
          }
          .font(.system(size: 15))
          .foregroundStyle(navigation.selection == page ? Color.primary : Color.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
          .frame(minHeight: 32)
          .background {
            if navigation.selection == page {
              RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.12))
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-page-\(page.rawValue)")
        .accessibilityAddTraits(navigation.selection == page ? .isSelected : [])
      }

      Spacer()

      if let guide = Bundle.main.url(forResource: "ClipContext-Guide", withExtension: "html") {
        Button {
          NSWorkspace.shared.open(guide)
        } label: {
          Label("ClipSettingsHelp", systemImage: "questionmark.circle")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 10)
    .padding(.top, 42)
    .padding(.bottom, 8)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 19))
  }

  @ViewBuilder
  private func content(for page: ClipSettingsPage) -> some View {
    switch page {
    case .general:
      GeneralSettingsPane()
      StorageSettingsPane()
    case .archive:
      ArchiveSettingsPane()
    case .privacy:
      IgnoreSettingsPane()
    case .shortcuts:
      ShortcutSettingsPane()
    case .appearance:
      AppearanceSettingsPane()
    case .advanced:
      AdvancedSettingsPane()
    }
  }
}

struct ClipSettingsGroup<Content: View>: View {
  private let title: Text?
  private let content: Content

  init(_ title: Text? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      if let title {
        title
          .font(.system(size: 15, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
          .padding(.horizontal, 10)
      }

      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
  }
}

struct ClipSettingsRow<Control: View>: View {
  private let title: Text
  private let control: Control

  init(_ title: Text, @ViewBuilder control: () -> Control) {
    self.title = title
    self.control = control()
  }

  var body: some View {
    HStack(spacing: 16) {
      title
        .font(.system(size: 14))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      control
    }
    .frame(minHeight: 36)
  }
}

struct GeneralSettingsPane: View {
  private let notificationsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(Bundle.main.bundleIdentifier ?? "")"
  )

  @Default(.searchMode) private var searchMode
  @Default(.pasteByDefault) private var pasteByDefault
  @Default(.removeFormattingByDefault) private var removeFormatting

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      ClipSettingsGroup {
        ClipSettingsRow(Text("LaunchAtLogin", tableName: "GeneralSettings")) {
          LaunchAtLogin.Toggle { Text("LaunchAtLogin", tableName: "GeneralSettings") }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }

        Divider()

        ClipSettingsRow(Text("Search", tableName: "GeneralSettings")) {
          Picker("Search", selection: $searchMode) {
            ForEach(Search.Mode.allCases) { mode in
              Text(mode.description)
            }
          }
          .labelsHidden()
          .accessibilityLabel(Text("Search", tableName: "GeneralSettings"))
          .frame(width: 155)
        }

        if let notificationsURL {
          Divider()
          ClipSettingsRow(Text("ClipSettingsNotificationsAndSounds")) {
            Link(destination: notificationsURL) {
              Image(systemName: "arrow.up.right")
                .font(.callout.weight(.semibold))
            }
            .accessibilityLabel(Text("ClipSettingsNotificationsAndSounds"))
          }
        }
      }

      ClipSettingsGroup(Text("ClipSettingsPasteItems")) {
        VStack(alignment: .leading, spacing: 12) {
          pasteOption(
            "ClipSettingsPasteActiveApp",
            detail: "ClipSettingsPasteActiveAppDetail",
            value: true
          )
          pasteOption(
            "ClipSettingsPasteClipboard",
            detail: "ClipSettingsPasteClipboardDetail",
            value: false
          )
        }
        .padding(.vertical, 11)

        Divider()

        Toggle("ClipSettingsPastePlainText", isOn: $removeFormatting)
          .toggleStyle(.checkbox)
          .font(.system(size: 14))
          .frame(minHeight: 36)
      }
    }
  }

  private func pasteOption(_ title: LocalizedStringKey, detail: LocalizedStringKey, value: Bool) -> some View {
    let selected = pasteByDefault == value

    return Button {
      pasteByDefault = value
    } label: {
      HStack(alignment: .top, spacing: 8) {
        ZStack {
          Circle().fill(Color.primary.opacity(selected ? 0.15 : 0.10))
          if selected {
            Circle()
              .fill(Color.primary)
              .frame(width: 5, height: 5)
          }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 14))
          Text(detail)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(title))
    .accessibilityHint(Text(detail))
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct ShortcutSettingsPane: View {
  @Default(.pasteByDefault) private var pasteByDefault
  @Default(.removeFormattingByDefault) private var removeFormatting

  var body: some View {
    ClipSettingsGroup {
      shortcutRow("Open", help: "OpenTooltip", name: .popup) { shortcut in
        if shortcut == nil {
          AppState.shared.popup.deinitEventsMonitor()
        } else {
          AppState.shared.popup.initEventsMonitor()
        }
      }

      Divider()
      shortcutRow("Pin", help: "PinTooltip", name: .pin)

      Divider()
      shortcutRow("Delete", help: "DeleteTooltip", name: .delete)

      Divider()
      shortcutRow("ShowPreview", help: "ShowPreviewTooltip", name: .togglePreview)
    }

    ClipSettingsGroup(Text("ClipSettingsPasteItems")) {
      Text(modifierDescription)
        .id([pasteByDefault, removeFormatting])
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 10)
    }
  }

  private func shortcutRow(
    _ label: LocalizedStringKey,
    help: LocalizedStringKey,
    name: KeyboardShortcuts.Name,
    onChange: @escaping (KeyboardShortcuts.Shortcut?) -> Void = { _ in }
  ) -> some View {
    ClipSettingsRow(Text(label, tableName: "GeneralSettings")) {
      KeyboardShortcuts.Recorder(for: name, onChange: onChange)
        .help(Text(help, tableName: "GeneralSettings"))
        .accessibilityLabel(Text(label, tableName: "GeneralSettings"))
    }
  }

  private var modifierDescription: String {
    String(
      format: String(localized: "Modifiers", table: "GeneralSettings"),
      HistoryItemAction.copy.modifierFlags.description,
      HistoryItemAction.paste.modifierFlags.description,
      HistoryItemAction.pasteWithoutFormatting.modifierFlags.description
    )
  }
}

#Preview {
  ClipSettingsWindow(navigation: ClipSettingsNavigation())
    .environment(\.locale, .init(identifier: "en"))
}
