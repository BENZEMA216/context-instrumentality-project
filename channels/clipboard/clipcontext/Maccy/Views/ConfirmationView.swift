import SwiftUI

struct ConfirmationView<Content: View>: View {
  @Bindable var item: FooterItem
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .buttonAction { item.requestConfirmation() }
      .historyConfirmation(for: item)
  }
}

extension FooterItem {
  func requestConfirmation() {
    if confirmation != nil, let suppressConfirmation, !suppressConfirmation.wrappedValue {
      showConfirmation = true
    } else {
      action()
    }
  }
}

extension View {
  @ViewBuilder
  func historyConfirmation(for item: FooterItem) -> some View {
    if let confirmation = item.confirmation, let suppressConfirmation = item.suppressConfirmation {
      @Bindable var item = item
      confirmationDialog(confirmation.message, isPresented: $item.showConfirmation) {
        Text(confirmation.comment)
        Button(confirmation.confirm, role: .destructive) { item.action() }
          .accessibilityIdentifier("confirmation-confirm")
        Button(confirmation.cancel, role: .cancel) {}
      }
      .dialogSuppressionToggle(isSuppressed: suppressConfirmation)
    } else {
      self
    }
  }
}
