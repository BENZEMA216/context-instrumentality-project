import SwiftUI
import Defaults

struct StorageSettingsPane: View {
  @Observable
  class ViewModel {
    var saveFiles = false {
      didSet {
        Defaults.withoutPropagation {
          if saveFiles {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.files.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.files.types)
          }
        }
      }
    }

    var saveImages = false {
      didSet {
        Defaults.withoutPropagation {
          if saveImages {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.images.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.images.types)
          }
        }
      }
    }

    var saveText = false {
      didSet {
        Defaults.withoutPropagation {
          if saveText {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.text.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.text.types)
          }
        }
      }
    }

    private var observer: Defaults.Observation?

    init() {
      observer = Defaults.observe(.enabledPasteboardTypes) { change in
        self.saveFiles = change.newValue.isSuperset(of: StorageType.files.types)
        self.saveImages = change.newValue.isSuperset(of: StorageType.images.types)
        self.saveText = change.newValue.isSuperset(of: StorageType.text.types)
      }
    }

    isolated deinit {
      observer?.invalidate()
    }
  }

  @Default(.size) private var size
  @Default(.sortBy) private var sortBy

  @State private var viewModel = ViewModel()
  @State private var storageSize = Storage.shared.size
  @State private var confirmingClear = false

  private let sizeFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 999
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      ClipSettingsGroup(Text("ClipSettingsKeepHistory")) {
        ClipSettingsRow(Text("Size", tableName: "StorageSettings")) {
          HStack {
            TextField("", value: $size, formatter: sizeFormatter)
              .frame(width: 66)
              .help(Text("SizeTooltip", tableName: "StorageSettings"))
              .accessibilityLabel(Text("Size", tableName: "StorageSettings"))
            Stepper("", value: $size, in: 1...999)
              .labelsHidden()
              .accessibilityLabel(Text("Size", tableName: "StorageSettings"))
            Text(storageSize)
              .font(.caption)
              .foregroundStyle(.secondary)
              .help(Text("CurrentSizeTooltip", tableName: "StorageSettings"))
              .onAppear {
                storageSize = Storage.shared.size
              }
          }
        }

        Divider()

        ClipSettingsRow(Text("SortBy", tableName: "StorageSettings")) {
          Picker("", selection: $sortBy) {
            ForEach(Sorter.By.allCases) { mode in
              Text(mode.description)
            }
          }
          .labelsHidden()
          .frame(width: 155)
          .help(Text("SortByTooltip", tableName: "StorageSettings"))
          .accessibilityLabel(Text("SortBy", tableName: "StorageSettings"))
        }

        Divider()

        Button("ClipSettingsEraseHistory") { confirmingClear = true }
          .frame(maxWidth: .infinity, minHeight: 36, alignment: .trailing)
          .confirmationDialog("clear_alert_message", isPresented: $confirmingClear) {
            Button("clear_alert_confirm", role: .destructive) { AppState.shared.history.clear() }
            Button("clear_alert_cancel", role: .cancel) {}
          } message: {
            Text("ClipSettingsEraseHistoryDetail")
          }
      }

      ClipSettingsGroup {
        ClipSettingsRow(Text("ClipSettingsSaveTypes")) {
          HStack(spacing: 9) {
            typeToggle("Files", isOn: $viewModel.saveFiles)
            typeToggle("Images", isOn: $viewModel.saveImages)
            typeToggle("Text", isOn: $viewModel.saveText)
          }
        }
        .help(Text("SaveDescription", tableName: "StorageSettings"))
      }
    }
  }

  private func typeToggle(_ label: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
      Text(label, tableName: "StorageSettings")
    }
    .toggleStyle(.checkbox)
    .controlSize(.small)
    .fixedSize()
  }
}

#Preview {
  StorageSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
