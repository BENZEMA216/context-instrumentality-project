import SwiftUI
import Defaults

struct AdvancedSettingsPane: View {
  @Default(.ignoreEvents) private var paused
  private var preferencesDomain: String { Bundle.main.bundleIdentifier ?? "com.benzema.ClipContext" }

  private var pauseCommand: String {
    let resume = NSLocalizedString("TurnOffCommandResume", tableName: "AdvancedSettings", comment: "")
    return "defaults write \(preferencesDomain) ignoreOnlyNextEvent -bool false\n" +
    "defaults write \(preferencesDomain) ignoreEvents -bool true\n" +
    "# \(resume)\n" +
    "defaults write \(preferencesDomain) ignoreOnlyNextEvent -bool false\n" +
    "defaults write \(preferencesDomain) ignoreEvents -bool false"
  }

  private var ignoreNextCommand: String {
    "defaults write \(preferencesDomain) ignoreOnlyNextEvent -bool true\n" +
    "defaults write \(preferencesDomain) ignoreEvents -bool true"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      ClipSettingsGroup {
        ClipSettingsRow(Text("TurnOff", tableName: "AdvancedSettings")) {
          Toggle(isOn: Binding(get: { paused }, set: { value in
            Defaults[.ignoreOnlyNextEvent] = false
            paused = value
          })) {
            Text("TurnOff", tableName: "AdvancedSettings")
          }
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
        }

        Divider()

        VStack(alignment: .leading, spacing: 6) {
          Text("TurnOffDescription", tableName: "AdvancedSettings")
          Text(verbatim: pauseCommand)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .accessibilityIdentifier("settings-pause-commands")
          Text("TurnOffViaMenuIconDescription", tableName: "AdvancedSettings")
          Text(verbatim: ignoreNextCommand)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .accessibilityIdentifier("advanced-ignore-next-command")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 10)
      }

      ClipSettingsGroup {
        ClipSettingsRow(Text("ClearHistoryOnQuit", tableName: "AdvancedSettings")) {
          Defaults.Toggle(key: .clearOnQuit) {
            Text("ClearHistoryOnQuit", tableName: "AdvancedSettings")
          }
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
          .help(Text("ClearHistoryOnQuitTooltip", tableName: "AdvancedSettings"))
        }

        Divider()

        ClipSettingsRow(Text("ClearSystemClipboard", tableName: "AdvancedSettings")) {
          Defaults.Toggle(key: .clearSystemClipboard) {
            Text("ClearSystemClipboard", tableName: "AdvancedSettings")
          }
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
          .help(Text("ClearSystemClipboardTooltip", tableName: "AdvancedSettings"))
        }
      }
    }
  }
}

#Preview {
  AdvancedSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
