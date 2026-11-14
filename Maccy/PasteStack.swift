import Foundation
import AppKit
import Defaults
import Sauce

@Observable
class PasteStack: Identifiable, Hashable {
  private static var listener: Any?

  @MainActor
  static func initializeIfNeeded() -> Bool {
    guard Accessibility.requestPermissionIfNeeded(forPasteStack: true) else { return false }
    guard listener == nil else { return true }

    var pasteKeyDown: UInt16?
    listener = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp, .keyDown]) { event in
      switch event.type {
      case .keyDown:
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
          .subtracting([.capsLock, .numericPad, .function])
        let keyCode = KeyboardLayout.current.commandSwitchesToQWERTY && flags.contains(.command)
          ? KeyChord.pasteKey.QWERTYKeyCode : Sauce.shared.keyCode(for: KeyChord.pasteKey)
        if event.keyCode == keyCode && flags == KeyChord.pasteKeyModifiers {
          pasteKeyDown = event.keyCode
        }
      case .keyUp:
        if pasteKeyDown == event.keyCode {
          pasteKeyDown = nil
          AppState.shared.history.handlePasteStack()
        }
      default:
        break
      }
    }
    guard listener != nil else {
      let alert = NSAlert()
      alert.messageText = "无法启动顺序粘贴"
      alert.informativeText = "系统未能监听粘贴快捷键。请检查辅助功能权限后重试；已选项目仍然保留。"
      alert.addButton(withTitle: "好")
      alert.runModal()
      return false
    }
    return true
  }

  var id: UUID = UUID()
  var items: [HistoryItemDecorator]
  let modifierFlags: NSEvent.ModifierFlags
  let removeFormatting: Bool

  init(items: [HistoryItemDecorator], modifierFlags: NSEvent.ModifierFlags) {
    self.items = items
    self.modifierFlags = modifierFlags
    removeFormatting = modifierFlags.isEmpty
      ? Defaults[.removeFormattingByDefault]
      : HistoryItemAction(modifierFlags) == .pasteWithoutFormatting
  }

  /// Capture positions while the old model is still alive; a merge can delete it.
  func positions(referencing item: HistoryItem) -> [Int] {
    items.indices.filter { items[$0].item === item }
  }

  /// Keep queue order and repeated entries when history deduplication replaces a model.
  func replaceItems(at positions: [Int], with replacement: HistoryItemDecorator) {
    for position in positions where items.indices.contains(position) {
      items[position] = replacement
    }
  }

  /// Advance only after the target application has received one paste keystroke.
  @discardableResult
  func consumeCurrentItem() -> HistoryItemDecorator? {
    guard !items.isEmpty else { return nil }
    return items.removeFirst()
  }

  static func == (lhs: PasteStack, rhs: PasteStack) -> Bool {
    return lhs.id == rhs.id
      && lhs.items == rhs.items
      && lhs.modifierFlags.rawValue == rhs.modifierFlags.rawValue
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(items)
    hasher.combine(modifierFlags.rawValue)
  }
}
