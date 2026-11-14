import Defaults
import SwiftUI

struct HistoryItemView: View {
  @Bindable var item: HistoryItemDecorator
  var previous: HistoryItemDecorator?
  var next: HistoryItemDecorator?
  var index: Int

  private var selectionAppearance: SelectionAppearance {
    let previousSelected = previous?.isSelected ?? false
    let nextSelected = next?.isSelected ?? false
    switch (previousSelected, nextSelected) {
    case (true, false):
      return .topConnection
    case (false, true):
      return .bottomConnection
    case (true, true):
      return .topBottomConnection
    default:
      return .none
    }
  }

  @Default(.showHexColorSwatch) private var showHexColorSwatch
  @Environment(AppState.self) private var appState
  @State private var archive = ClipboardArchive.shared

  private var colorSwatchImage: NSImage? {
    guard showHexColorSwatch else { return nil }
    return ColorImage.from(item.title)
  }

  private func performSelect() {
    if appState.multiSelectionEnabled &&
        (NSEvent.modifierFlags.contains(.command) || appState.navigator.isMultiSelectInProgress) {
      appState.navigator.addToSelection(item: item)
    } else {
      let flags = NSEvent.ModifierFlags.currentModifierFlags
      Task {
        appState.history.select(item, flags: flags)
      }
    }
  }

  var body: some View {
    let shared = archive.isShared(item.item)
    let canShare = archive.canShare(item.item)
    ListItemView(
      id: item.id,
      selectionId: item.id,
      appIcon: item.applicationImage,
      image: item.thumbnailImage,
      accessoryImage: item.thumbnailImage != nil ? nil : colorSwatchImage,
      attributedTitle: item.attributedTitle,
      shortcuts: item.shortcuts,
      isSelected: item.isSelected,
      selectionIndex: item.multiSelectionIndex,
      selectionAppearance: selectionAppearance,
      accessibilityLabel: shared ? "\(item.accessibilityLabel)，已共享给 Agent" : item.accessibilityLabel,
      statusIcon: shared ? "tray.and.arrow.up" : nil
    ) {
      Text(verbatim: item.title)
    }
    .contextMenu {
      Button(appState.navigator.isMultiSelectInProgress ?
             (item.isSelected ? "移出多选" : "加入多选") : "选择多条…") {
        if appState.navigator.isMultiSelectInProgress {
          appState.navigator.addToSelection(item: item)
        } else {
          appState.beginMultiSelection(with: item)
        }
      }
      .accessibilityIdentifier("history-select-multiple")
      Divider()
      Button(shared ? "撤销 Agent 共享" : "分享给 Agent") {
        archive.setShared(!shared, for: item.item)
      }
      .disabled(!canShare)
      Divider()
      Button(item.isPinned ? "取消收藏" : "收藏") { appState.history.togglePin(item) }
      Button("删除", role: .destructive) { appState.history.delete(item) }
    }
    .accessibilityIdentifier("copy-history-item")
    .buttonAction(performSelect)
    .onAppear {
      item.ensureThumbnailImage()
    }
    .accessibilityAction(named: Text(item.isPinned ? "history_item_unpin_action" : "history_item_pin_action")) {
      appState.history.togglePin(item)
    }
    .accessibilityAction(named: Text("history_item_delete_action")) {
      appState.history.delete(item)
    }
    .accessibilityActions {
      if canShare {
        Button(shared ? "撤销 Agent 共享" : "分享给 Agent") {
          archive.setShared(!shared, for: item.item)
        }
      }
    }
  }
}
