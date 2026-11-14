import AppKit
import Defaults
import Foundation
import SwiftUI

@Observable
class AppState: Sendable {
  static let shared = AppState(history: History.shared, footer: Footer())

  let multiSelectionEnabled = true

  var appDelegate: AppDelegate?
  var popup: Popup
  var history: History
  var footer: Footer
  var navigator: NavigationManager
  var preview: SlideoutController

  var isEditingItem: Bool = false
  var suppressPopupAutoClose: Bool {
    return navigator.isDragAndDropInProgress || isEditingItem
  }

  var searchVisible: Bool {
    if !Defaults[.showSearch] { return false }
    switch Defaults[.searchVisibility] {
    case .always: return true
    case .duringSearch: return !history.searchQuery.isEmpty
    }
  }

  var menuIconText: String {
    var title = history.latestUnpinnedItem?.text.shortened(to: 100)
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    title.unicodeScalars.removeAll(where: CharacterSet.newlines.contains)
    return title.shortened(to: 20)
  }

  private let about = About()
  private var settingsWindowController: ClipContextSettingsWindowController?

  init(history: History, footer: Footer) {
    self.history = history
    self.footer = footer
    popup = Popup()
    navigator = NavigationManager(history: history, footer: footer)
    preview = SlideoutController(
      onContentResize: { contentWidth in
        Defaults[.windowSize].width = contentWidth
      },
      onSlideoutResize: { previewWidth in
        Defaults[.previewWidth] = previewWidth
      })
    preview.contentWidth = Defaults[.windowSize].width
    preview.slideoutWidth = Defaults[.previewWidth]
  }

  @MainActor
  func select(flags modifierFlags: NSEvent.ModifierFlags) {
    guard !navigator.isManualMultiSelect || !navigator.selection.isEmpty else { return }
    if !navigator.selection.isEmpty {
      if navigator.isMultiSelectInProgress {
        startSelectedPasteStack(flags: modifierFlags)
      } else {
        history.select(navigator.selection.first, flags: modifierFlags)
      }
    } else if let item = footer.selectedItem {
      // TODO: Use item.suppressConfirmation, but it's not updated!
      if item.confirmation != nil, Defaults[.suppressClearAlert] == false {
        item.showConfirmation = true
      } else {
        item.action()
      }
    } else {
      Clipboard.shared.copyInMaccy(history.searchQuery)
      history.searchQuery = ""
    }
  }

  @MainActor
  func beginMultiSelection(with item: HistoryItemDecorator? = nil) {
    if let item { navigator.select(item: item) }
    if navigator.selection.isEmpty { navigator.highlightFirst() }
    navigator.isManualMultiSelect = true
  }

  @MainActor
  func cancelMultiSelection() {
    let item = navigator.leadHistoryItem
    navigator.isManualMultiSelect = false
    navigator.select(item: item ?? history.firstVisibleItem)
  }

  @MainActor
  func startSelectedPasteStack(flags: NSEvent.ModifierFlags = []) {
    if history.startPasteStack(selection: &navigator.selection, flags: flags) {
      navigator.isManualMultiSelect = false
    }
  }

  @MainActor
  func togglePin() {
    withTransaction(Transaction()) {
      navigator.selection.forEach { _, item in
        history.togglePin(item)
      }
    }
  }

  @MainActor
  func removePasteStack() {
    history.interruptPasteStack()
    navigator.highlightFirst()
  }

  @MainActor
  func deleteSelection() {
    guard let leadItem = navigator.leadHistoryItem else { return }
    let nextUnselectedItem = history.nearestVisible(to: leadItem) { !$0.isSelected }

    withTransaction(Transaction()) {
      navigator.selection.forEach { _, item in
        history.delete(item)
      }
      navigator.select(item: nextUnselectedItem)
    }
  }

  func openAbout() {
    about.openAbout(nil)
  }

  @MainActor
  func openPreferences(showArchive: Bool = false) {
    if settingsWindowController == nil {
      settingsWindowController = ClipContextSettingsWindowController()
    }
    settingsWindowController?.show(page: showArchive ? .archive : nil)
  }

  func quit() {
    NSApp.terminate(self)
  }
}
