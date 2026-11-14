import SwiftUI

struct IgnoreSettingsPane: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      ClipSettingsGroup(Text("ApplicationsTab", tableName: "IgnoreSettings")) {
        IgnoreApplicationsSettingsView()
          .frame(height: 200)
      }

      ClipSettingsGroup(Text("PasteboardTypesTab", tableName: "IgnoreSettings")) {
        IgnorePasteboardTypesSettingsView()
          .frame(height: 235)
      }

      ClipSettingsGroup(Text("RegexpTab", tableName: "IgnoreSettings")) {
        IgnoreRegexpsSettingsView()
          .frame(height: 195)
      }
    }
  }
}

#Preview {
  IgnoreSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
