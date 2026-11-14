import AppKit
import Defaults
import SwiftData
import Testing
@testable import Maccy

@Suite(.serialized)
enum SharedStateTests {}


extension SharedStateTests {
  @MainActor
  struct PasteStackSelectionTests {
    @Test("Multiple selection retains order and survives pointer navigation")
    func selectionOrderAndHover() throws {
      let history = History.shared
      let savedPresentation = Defaults[.historyPresentation]
      Defaults[.historyPresentation] = .list
      history.clearAll()
      defer {
        history.clearAll()
        Defaults[.historyPresentation] = savedPresentation
      }
      _ = history.add(makeItem("queue A"))
      _ = history.add(makeItem("queue B"))
      _ = history.add(makeItem("queue C"))
      let items = Array(history.items)
      #expect(items.count == 3)
      let navigator = NavigationManager(history: history, footer: Footer())
      navigator.select(item: items[0])
      navigator.extendHighlightToNext()
      #expect(navigator.selection.items == [items[0], items[1]])
      #expect(items[0].selectionIndex == 0)
      #expect(items[1].selectionIndex == 1)
      navigator.hoverSelectionWhileKeyboardNavigating = items[2].id
      navigator.isKeyboardNavigating = false
      #expect(navigator.selection.items == [items[0], items[1]])
      navigator.addToSelection(item: items[1])
      navigator.addToSelection(item: items[0])
      #expect(navigator.selection.isEmpty)
      #expect(navigator.isManualMultiSelect)
      navigator.addToSelection(item: items[2])
      #expect(navigator.selection.items == [items[2]])
      #expect(items[2].selectionIndex == 0)
    }

    @Test("Paste queue consumes selected items in order and safely becomes empty")
    func consumesInSelectionOrder() {
      let first = HistoryItemDecorator(makeItem("queue first"))
      let second = HistoryItemDecorator(makeItem("queue second"))
      let stack = PasteStack(items: [second, first], modifierFlags: [])
      #expect(stack.items.first == second)
      #expect(stack.consumeCurrentItem() == second)
      #expect(stack.items.first == first)
      #expect(stack.consumeCurrentItem() == first)
      #expect(stack.items.isEmpty)
      #expect(stack.consumeCurrentItem() == nil)
    }

    @Test("Paste queue freezes its format choice for all subsequent items")
    func preservesFormattingChoice() {
      let savedFormatting = Defaults[.removeFormattingByDefault]
      defer { Defaults[.removeFormattingByDefault] = savedFormatting }
      Defaults[.removeFormattingByDefault] = true
      let plain = PasteStack(items: [], modifierFlags: [])
      Defaults[.removeFormattingByDefault] = false
      #expect(plain.removeFormatting)
      let formatted = PasteStack(items: [], modifierFlags: HistoryItemAction.copy.modifierFlags)
      #expect(!formatted.removeFormatting)
      let explicitPlain = PasteStack(items: [], modifierFlags: HistoryItemAction.pasteWithoutFormatting.modifierFlags)
      #expect(explicitPlain.removeFormatting)
    }

    @Test("Permission failure preserves selected items and does not create a paste queue")
    func deniedMonitoringKeepsSelection() {
      let history = History.shared
      history.interruptPasteStack()
      let first = HistoryItemDecorator(makeItem("denied first"))
      let second = HistoryItemDecorator(makeItem("denied second"))
      var selection = Selection(items: [first, second])
      var requestedMonitoring = false
      let started = history.startPasteStack(selection: &selection, flags: [], prepareMonitoring: {
        requestedMonitoring = true
        return false
      })
      #expect(requestedMonitoring)
      #expect(!started)
      #expect(history.pasteStack == nil)
      #expect(selection.items == [first, second])
    }

    @Test("Deleting or clearing history stops a pending paste queue")
    func deletingQueueItemsStopsQueue() {
      let history = History.shared
      history.clearAll()
      defer { history.clearAll() }
      let first = history.add(makeItem("remove first"))
      let second = history.add(makeItem("keep second"))
      history.pasteStack = PasteStack(items: [first, second], modifierFlags: [])
      history.delete(first)
      #expect(history.pasteStack == nil)
      history.pasteStack = PasteStack(items: [second], modifierFlags: [])
      history.clear()
      #expect(history.pasteStack == nil)
      let third = history.add(makeItem("clear all"))
      history.pasteStack = PasteStack(items: [third], modifierFlags: [])
      history.clearAll()
      #expect(history.pasteStack == nil)
    }

    @Test("Recaptured copy rebinds the queue and deleting its new history item stops it")
    func recapturedCopyRebindsQueue() async throws {
      let fixture = QueueCopyFixture()
      defer { fixture.cleanUp() }
      let first = fixture.history.add(makeItem("queue recaptured"))
      let second = fixture.history.add(makeItem("queue second"))
      let stack = PasteStack(items: [first, second, first], modifierFlags: [])
      fixture.history.pasteStack = stack

      let recaptured = try await fixture.copyAndCapture(first.item)
      #expect(recaptured !== first)
      #expect(stack.items == [recaptured, second, recaptured])
      #expect(recaptured.item.text == "queue recaptured")
      fixture.history.delete(recaptured)
      #expect(fixture.history.pasteStack == nil)
    }

    @Test("Recapturing legacy duplicate RTF replaces a later queue model without losing data or order")
    func duplicateRTFQueueRetainsLaterPayload() async throws {
      let fixture = QueueCopyFixture()
      defer { fixture.cleanUp() }
      let value = "legacy queue rich text"
      let rich = try #require(NSAttributedString(
        string: value,
        attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]
      ).rtf(from: NSRange(location: 0, length: value.utf16.count), documentAttributes: [:]))
      let older = makeItem(value)
      older.contents.append(HistoryItemContent(type: NSPasteboard.PasteboardType.rtf.rawValue, value: rich))
      older.contents.append(HistoryItemContent(type: "public.utf16-external-plain-text", value: nil))
      older.lastCopiedAt = Date(timeIntervalSinceNow: -20)
      let newer = makeItem(value)
      newer.contents.append(HistoryItemContent(type: NSPasteboard.PasteboardType.rtf.rawValue, value: rich))
      newer.contents.append(HistoryItemContent(type: "public.utf16-external-plain-text", value: value.data(using: .utf16)))
      newer.lastCopiedAt = Date(timeIntervalSinceNow: -10)
      // Old app versions could persist both representations. Bypass add only to build
      // that legacy fixture, then use the real copy -> capture -> History.add path.
      Storage.shared.context.insert(older)
      Storage.shared.context.insert(newer)
      try Storage.shared.context.save()
      try await fixture.history.load()
      let first = try #require(fixture.history.items.first { $0.item === older })
      let later = try #require(fixture.history.items.first { $0.item === newer })
      let stack = PasteStack(items: [first, later, later], modifierFlags: [])
      fixture.history.pasteStack = stack

      let recaptured = try await fixture.copyAndCapture(first.item)
      #expect(stack.items == [first, recaptured, recaptured])
      #expect(stack.consumeCurrentItem() == first)
      let next = try #require(stack.items.first)
      #expect(next.item.rtfData == rich)
      let recapturedAgain = try await fixture.copyAndCapture(next.item)
      #expect(fixture.pasteboard.string(forType: .string) == value)
      #expect(fixture.pasteboard.data(forType: .rtf) == rich)
      #expect(stack.items == [recapturedAgain, recapturedAgain])
      #expect(stack.consumeCurrentItem() == recapturedAgain)
      #expect(stack.items.first?.item.rtfData == rich)
    }

    @Test("An external copy before the timer fires stops the queue without overwriting it", arguments: [false, true])
    func externalCopyBeforeTimerStopsQueue(capturePaused: Bool) async throws {
      let fixture = QueueCopyFixture()
      defer { fixture.cleanUp() }
      let first = fixture.history.add(makeItem("queued first"))
      let second = fixture.history.add(makeItem("queued second"))
      let stack = PasteStack(items: [first, second], modifierFlags: [])
      fixture.history.pasteStack = stack
      _ = try await fixture.copyAndCapture(first.item)

      Defaults[.ignoreEvents] = capturePaused
      fixture.pasteboard.clearContents()
      fixture.pasteboard.setString("new external copy", forType: .string)
      let externalChangeCount = fixture.pasteboard.changeCount

      // No polling timer or explicit capture runs between the external write
      // and the paste-key event that would otherwise advance the queue.
      fixture.history.handlePasteStack(clipboard: fixture.clipboard)

      #expect(fixture.history.pasteStack == nil)
      #expect(stack.items.count == 2)
      #expect(fixture.pasteboard.changeCount == externalChangeCount)
      #expect(fixture.pasteboard.string(forType: .string) == "new external copy")
    }

    @Test("A pending own copy is captured before advancing the queue")
    func ownCopyBeforeTimerAdvancesQueue() async throws {
      let fixture = QueueCopyFixture()
      defer { fixture.cleanUp() }
      let first = fixture.history.add(makeItem("queued first"))
      let second = fixture.history.add(makeItem("queued second"))
      let stack = PasteStack(items: [first, second], modifierFlags: [])
      fixture.history.pasteStack = stack
      fixture.clipboard.copy(first.item)

      fixture.history.handlePasteStack(clipboard: fixture.clipboard)

      #expect(fixture.history.pasteStack === stack)
      #expect(stack.items.count == 1)
      #expect(stack.items.first?.item.text == "queued second")
      #expect(fixture.pasteboard.string(forType: .string) == "queued second")
      for _ in 0..<100 where fixture.captured.count < 2 {
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect(fixture.captured.count == 2)
      #expect(stack.items.first === fixture.captured.last)
    }

    @MainActor
    private final class QueueCopyFixture {
      let history = History.shared
      let pasteboard = NSPasteboard.withUniqueName()
      let clipboard: Clipboard
      var captured: [HistoryItemDecorator] = []
      let savedIgnoreEvents = Defaults[.ignoreEvents]
      let savedIgnoreAllApps = Defaults[.ignoreAllAppsExceptListed]
      let savedIgnoredApps = Defaults[.ignoredApps]
      let savedSortBy = Defaults[.sortBy]

      init() {
        clipboard = Clipboard(pasteboard: pasteboard)
        Defaults[.ignoreEvents] = false
        Defaults[.ignoreAllAppsExceptListed] = false
        Defaults[.ignoredApps] = []
        Defaults[.sortBy] = .lastCopiedAt
        history.clearAll()
        clipboard.onNewCopy { [weak self] item in
          guard let self else { return }
          captured.append(history.add(item))
        }
      }

      func copyAndCapture(_ item: HistoryItem) async throws -> HistoryItemDecorator {
        let previousCount = captured.count
        clipboard.copy(item)
        for _ in 0..<100 where captured.count == previousCount {
          try await Task.sleep(for: .milliseconds(5))
        }
        #expect(captured.count == previousCount + 1)
        return try #require(captured.last)
      }

      func cleanUp() {
        clipboard.clearHooks()
        history.clearAll()
        pasteboard.releaseGlobally()
        Defaults[.ignoreEvents] = savedIgnoreEvents
        Defaults[.ignoreAllAppsExceptListed] = savedIgnoreAllApps
        Defaults[.ignoredApps] = savedIgnoredApps
        Defaults[.sortBy] = savedSortBy
      }
    }

    private func makeItem(_ text: String) -> HistoryItem {
      let item = HistoryItem()
      item.contents = [HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue,
                                          value: text.data(using: .utf8))]
      item.title = text
      return item
    }
  }
}
