import SwiftUI

struct FooterItemView: View {
  @Bindable var item: FooterItem
  var presentsConfirmation = true
  @Environment(AppState.self) private var appState

  @ViewBuilder
  var body: some View {
    if presentsConfirmation {
      row.historyConfirmation(for: item)
    } else {
      row
    }
  }

  private var row: some View {
    ListItemView(
      id: item.id,
      selectionId: item.id,
      shortcuts: item.shortcuts,
      isSelected: item.isSelected,
      accessibilityLabel: NSLocalizedString(item.title, comment: "")
    ) {
      Text(LocalizedStringKey(item.title))
    }
    .buttonAction { item.requestConfirmation() }
    .onHover { hovering in
      if hovering && appState.preview.state.isOpen {
        appState.preview.togglePreview()
      }
    }
  }
}
