import AppKit
import SwiftUI
import Defaults

struct AppearanceSettingsPane: View {
  @Default(.interfaceAppearance) private var interfaceAppearance
  @Default(.historyPresentation) private var historyPresentation
  @Default(.popupPosition) private var popupAt
  @Default(.popupScreen) private var popupScreen
  @Default(.pinTo) private var pinTo
  @Default(.imageMaxHeight) private var imageHeight
  @Default(.openPreviewAutomatically) private var openPreviewAutomatically
  @Default(.previewDelay) private var previewDelay
  @Default(.highlightMatch) private var highlightMatch
  @Default(.menuIcon) private var menuIcon
  @Default(.showInStatusBar) private var showInStatusBar
  @Default(.showSearch) private var showSearch
  @Default(.searchVisibility) private var searchVisibility
  @Default(.showFooter) private var showFooter
  @Default(.windowPosition) private var windowPosition

  @State private var screens = NSScreen.screens

  private let imageHeightFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 200
    return formatter
  }()

  private let previewDelayFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 200
    formatter.maximum = 100_000
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      ClipSettingsGroup {
        ClipSettingsRow(Text("配色")) {
          Picker("配色", selection: $interfaceAppearance) {
            Text("浅色").tag(InterfaceAppearance.light)
            Text("深色").tag(InterfaceAppearance.dark)
            Text("跟随系统").tag(InterfaceAppearance.system)
          }
          .labelsHidden()
          .frame(width: 155)
        }
        Divider()
        ClipSettingsRow(Text("ClipSettingsHistoryLayout")) {
          Picker("ClipSettingsHistoryLayout", selection: $historyPresentation) {
            Text("ClipSettingsHistoryLayoutCards").tag(HistoryPresentation.shelf)
            Text("ClipSettingsHistoryLayoutList").tag(HistoryPresentation.list)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .accessibilityLabel(Text("ClipSettingsHistoryLayout"))
          .accessibilityIdentifier("settings-history-layout")
          .frame(width: 155)
        }

        Divider()

        if historyPresentation == .shelf {
          ClipSettingsRow(Text("ClipSettingsDisplay")) {
            Picker("ClipSettingsDisplay", selection: displaySelection) {
              screenChoices
            }
            .labelsHidden()
            .frame(width: 155)
            .accessibilityLabel(Text("ClipSettingsDisplay"))
          }

          Divider()

          Text("ClipSettingsShelfPosition")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10)
        } else {
          listPlacementSettings
        }
      }

      ClipSettingsGroup(Text("ClipSettingsPreview")) {
        if historyPresentation == .list {
          listPreviewSettings
          Divider()
        }

        ClipSettingsRow(Text("HighlightMatches", tableName: "AppearanceSettings")) {
          Picker("", selection: $highlightMatch) {
            ForEach(HighlightMatch.allCases) { match in
              Text(match.description)
            }
          }
          .labelsHidden()
          .frame(width: 155)
          .help(Text("HighlightMatchesTooltip", tableName: "AppearanceSettings"))
          .accessibilityLabel(Text("HighlightMatches", tableName: "AppearanceSettings"))
        }

        Divider()

        toggleRow("ShowSpecialSymbols", key: .showSpecialSymbols)
          .help(Text("ShowSpecialSymbolsTooltip", tableName: "AppearanceSettings"))
        Divider()
        toggleRow("ShowApplicationIcons", key: .showApplicationIcons)
        Divider()
        toggleRow("ShowHexColorSwatch", key: .showHexColorSwatch)
          .help(Text("ShowHexColorSwatchTooltip", tableName: "AppearanceSettings"))
      }

      ClipSettingsGroup(Text("ClipSettingsWindowAndMenuBar")) {
        ClipSettingsRow(Text("ShowMenuIcon", tableName: "AppearanceSettings")) {
          HStack {
            Picker("", selection: $menuIcon) {
              ForEach(MenuIcon.allCases) { icon in
                Image(nsImage: icon.image)
              }
            }
            .labelsHidden()
            .frame(width: 68)
            .disabled(!showInStatusBar)
            .controlSize(.small)
            .accessibilityLabel(Text("ShowMenuIcon", tableName: "AppearanceSettings"))

            toggle("ShowMenuIcon", key: .showInStatusBar)
          }
        }

        Divider()
        toggleRow("ShowRecentCopyInMenuBar", key: .showRecentCopyInMenuBar)
        Divider()

        if historyPresentation == .list {
          ClipSettingsRow(Text("ShowSearchField", tableName: "AppearanceSettings")) {
            HStack {
              Picker("", selection: $searchVisibility) {
                ForEach(SearchVisibility.allCases) { type in
                  Text(type.description)
                }
              }
              .labelsHidden()
              .frame(width: 112)
              .disabled(!showSearch)
              .controlSize(.small)
              .accessibilityLabel(Text("ShowSearchField", tableName: "AppearanceSettings"))

              toggle("ShowSearchField", key: .showSearch)
            }
          }
          .accessibilityIdentifier("settings-list-search-options")

          Divider()
          toggleRow("ShowTitleBeforeSearchField", key: .showTitle)
          Divider()
          toggleRow("ShowFooter", key: .showFooter)

          if !showFooter {
            Divider()

            Text("OpenPreferencesWarning", tableName: "AppearanceSettings")
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.vertical, 10)
          }
        } else {
          Text("ClipSettingsShelfSearchBehavior")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10)
            .accessibilityIdentifier("settings-shelf-search-description")
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
      screens = NSScreen.screens
    }
  }

  @ViewBuilder
  private var listPlacementSettings: some View {
    ClipSettingsRow(Text("PopupAt", tableName: "AppearanceSettings")) {
      HStack {
        Picker("", selection: $popupAt) {
          ForEach(PopupPosition.allCases) { position in
            if position == .center || position == .lastPosition, screens.count > 1 {
              screenPicker(for: position)
            } else {
              Text(position.description)
            }
          }
        }
        .labelsHidden()
        .frame(width: 155)
        .help(Text("PopupAtTooltip", tableName: "AppearanceSettings"))
        .accessibilityLabel(Text("PopupAt", tableName: "AppearanceSettings"))

        if popupAt == .lastPosition {
          Button {
            _windowPosition.reset()
          } label: {
            Image(systemName: "arrow.uturn.backward.circle.fill")
              .imageScale(.large)
          }
          .buttonStyle(.borderless)
          .help(Text("PopupAtLastLocationReset", tableName: "AppearanceSettings"))
          .disabled(windowPosition == _windowPosition.defaultValue)
        }
      }
    }

    Divider()

    ClipSettingsRow(Text("PinTo", tableName: "AppearanceSettings")) {
      Picker("", selection: $pinTo) {
        ForEach(PinsPosition.allCases) { position in
          Text(position.description)
        }
      }
      .labelsHidden()
      .frame(width: 155)
      .help(Text("PinToTooltip", tableName: "AppearanceSettings"))
      .accessibilityLabel(Text("PinTo", tableName: "AppearanceSettings"))
    }
  }

  @ViewBuilder
  private var listPreviewSettings: some View {
    ClipSettingsRow(Text("ImageHeight", tableName: "AppearanceSettings")) {
      HStack {
        TextField("", value: $imageHeight, formatter: imageHeightFormatter)
          .frame(width: 95)
          .help(Text("ImageHeightTooltip", tableName: "AppearanceSettings"))
          .accessibilityLabel(Text("ImageHeight", tableName: "AppearanceSettings"))
        Stepper("", value: $imageHeight, in: 1...200)
          .labelsHidden()
          .accessibilityLabel(Text("ImageHeight", tableName: "AppearanceSettings"))
      }
    }

    Divider()
    toggleRow("OpenPreviewAutomatically", key: .openPreviewAutomatically)
    Divider()

    ClipSettingsRow(Text("PreviewDelay", tableName: "AppearanceSettings")) {
      HStack {
        TextField("", value: $previewDelay, formatter: previewDelayFormatter)
          .frame(width: 95)
          .help(Text("PreviewDelayTooltip", tableName: "AppearanceSettings"))
          .accessibilityLabel(Text("PreviewDelay", tableName: "AppearanceSettings"))
        Stepper("", value: $previewDelay, in: 200...100_000)
          .labelsHidden()
          .accessibilityLabel(Text("PreviewDelay", tableName: "AppearanceSettings"))
      }
      .disabled(!openPreviewAutomatically)
    }
  }

  private func toggleRow(_ label: LocalizedStringKey, key: Defaults.Key<Bool>) -> some View {
    ClipSettingsRow(Text(label, tableName: "AppearanceSettings")) {
      toggle(label, key: key)
    }
  }

  private func toggle(_ label: LocalizedStringKey, key: Defaults.Key<Bool>) -> some View {
    Defaults.Toggle(key: key) {
      Text(label, tableName: "AppearanceSettings")
    }
    .labelsHidden()
    .toggleStyle(.switch)
    .controlSize(.small)
  }

  private var displaySelection: Binding<Int> {
    Binding {
      popupScreen > 0 && screens.indices.contains(popupScreen - 1) ? popupScreen : 0
    } set: {
      popupScreen = $0
    }
  }

  @ViewBuilder
  private var screenChoices: some View {
    Text(labelForScreen(index: 0))
      .tag(0)

    ForEach(screens.indices, id: \.self) { index in
      Text(labelForScreen(index: index + 1))
        .tag(index + 1)
    }
  }

  private func screenPicker(for position: PopupPosition) -> some View {
    let screenBinding = Binding {
      displaySelection.wrappedValue
    } set: {
      popupScreen = $0
      popupAt = position
    }

    return Picker(selection: screenBinding) {
      screenChoices
    } label: {
      if popupAt == position {
        Text("\(position.description) (\(labelForScreen(index: popupScreen)))")
      } else {
        Text(position.description)
      }
    }
  }

  private func labelForScreen(index screenIndex: Int) -> String {
    if screenIndex > 0, screens.indices.contains(screenIndex - 1) {
      return screens[screenIndex - 1].localizedName
    }
    return String(localized: "ActiveScreen", table: "AppearanceSettings")
  }
}

#Preview {
  AppearanceSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
