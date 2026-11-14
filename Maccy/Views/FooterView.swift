import Defaults
import SwiftUI

struct FooterView: View {
  @Bindable var footer: Footer

  @Environment(AppState.self) private var appState
  @Environment(ModifierFlags.self) private var modifierFlags
  @Default(.showFooter) private var showFooter

  var clearAllModifiersPressed: Bool {
    let clearModifiers = footer.items[0].shortcuts.first?.modifierFlags ?? []
    let clearAllModifiers = footer.items[1].shortcuts.first?.modifierFlags ?? []
    return !modifierFlags.flags.isEmpty
      && !modifierFlags.flags.isSubset(of: clearModifiers)
      && modifierFlags.flags.isSubset(of: clearAllModifiers)
  }

  private var activeClearItem: FooterItem {
    footer.items[clearAllModifiersPressed ? 1 : 0]
  }

  var body: some View {
    VStack(spacing: 0) {
      if showFooter {
        Divider()
          .padding(.horizontal, Popup.horizontalSeparatorPadding)
          .padding(.bottom, Popup.verticalSeparatorPadding)

        // Only one actionable row exists, including in the accessibility tree.
        // Opacity-based stacking left the hidden Clear all row hit-testable by AX.
        FooterItemView(item: activeClearItem, presentsConfirmation: false)

        ForEach(footer.items.suffix(from: 2)) { item in
          FooterItemView(item: item)
        }
      }
    }
    .onChange(of: clearAllModifiersPressed, initial: true) {
      footer.items[0].isVisible = !clearAllModifiersPressed
      footer.items[1].isVisible = clearAllModifiersPressed
      if let selected = appState.footer.selectedItem,
         selected == footer.items[0] || selected == footer.items[1],
         selected != activeClearItem {
        appState.navigator.select(footerItem: activeClearItem)
      }
    }
    .frame(maxHeight: showFooter ? nil : 0)
    .padding(.bottom, showFooter ? Popup.verticalPadding : 0)
    .readHeight(appState, into: \.popup.footerHeight)
    // These hosts are stable and never hidden with the row. Releasing Shift while
    // Clear all is confirming must not remove its dialog or switch its action.
    .historyConfirmation(for: footer.items[0])
    .background {
      Color.clear.historyConfirmation(for: footer.items[1])
    }
  }
}
