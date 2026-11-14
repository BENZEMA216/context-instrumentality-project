import AppKit
import Testing
import Defaults
import SwiftData
@testable import Maccy

extension SharedStateTests {
  @MainActor
  final class HistoryTests { // swiftlint:disable:this type_body_length
    let savedSize = Defaults[.size]
    let savedSortBy = Defaults[.sortBy]
    let savedPinOrder = Defaults[.pinOrder]
    let savedPinTo = Defaults[.pinTo]
    let history = History.shared

    init() {
      History.shared.clearAll()
      Defaults[.size] = 10
      Defaults[.sortBy] = .firstCopiedAt
      Defaults[.pinOrder] = PinOrder()
      Defaults[.pinTo] = .bottom
    }

    deinit {
      Defaults[.size] = savedSize
      Defaults[.sortBy] = savedSortBy
      Defaults[.pinOrder] = savedPinOrder
      Defaults[.pinTo] = savedPinTo
    }

    @Test("Default is empty")
    func defaultIsEmpty() {
      #expect(history.items.toArray() == [])
    }

    @Test("Adding")
    func adding() {
      let first = history.add(historyItem("foo"))
      let second = history.add(historyItem("bar"))
      #expect(history.items.toArray() == [second, first])
    }

    @Test("Adding persisted duplicate")
    func addingPersistedDuplicate() throws {
      let first = historyItem("foo")
      first.title = "xyz"
      first.application = "iTerm.app"
      history.add(first)
      first.pin = "f"

      let third = historyItem("foo")
      third.application = "Xcode.app"
      let transferredContents = first.contents
      let merged = history.add(third)

      #expect(history.items.toArray() == [merged])
      #expect(Set(merged.item.contents) == Set(transferredContents))
      #expect(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
      #expect(merged.item.numberOfCopies == 2)
      #expect(merged.item.pin == "f")
      #expect(merged.item.title == "xyz")
      #expect(merged.item.application == "iTerm.app")
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Adding unsaved duplicate")
    @available(macOS 15.0, *)
    func addingUnsavedDuplicate() throws {
      let first = historyItem("foo")
      first.title = "xyz"
      first.application = "iTerm.app"
      history.add(first)
      first.pin = "f"

      let second = historyItem("foo", persisted: false)
      second.application = "Xcode.app"
      let transferredContents = first.contents
      let merged = history.add(second)

      #expect(history.items.toArray() == [merged])
      #expect(Set(merged.item.contents) == Set(transferredContents))
      #expect(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
      #expect(merged.item.numberOfCopies == 2)
      #expect(merged.item.pin == "f")
      #expect(merged.item.title == "xyz")
      #expect(merged.item.application == "iTerm.app")
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Adding item that is superseded by existing")
    func addingItemThatIsSupersededByExisting() throws {
      let firstContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.rtf.rawValue,
          value: "two".data(using: .utf8)!
        )
      ]
      let firstItem = HistoryItem()
      Storage.shared.context.insert(firstItem)
      firstItem.application = "Maccy.app"
      firstItem.contents = firstContents
      firstItem.title = firstItem.generateTitle()
      history.add(firstItem)

      let secondContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        )
      ]
      let secondItem = HistoryItem()
      Storage.shared.context.insert(secondItem)
      secondItem.application = "Maccy.app"
      secondItem.contents = secondContents
      secondItem.title = secondItem.generateTitle()
      let second = history.add(secondItem)

      #expect(history.items.toArray() == [second])
      #expect(Set(history.items[0].item.contents) == Set(firstContents))
      try assertStorageCounts(items: 1, contents: firstContents.count)
    }

    @Test("Adding item with different modified type")
    func addingItemWithDifferentModifiedType() {
      let firstContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.modified.rawValue,
          value: "1".data(using: .utf8)!
        )
      ]
      let firstItem = HistoryItem()
      Storage.shared.context.insert(firstItem)
      firstItem.contents = firstContents
      history.add(firstItem)

      let secondContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.modified.rawValue,
          value: "2".data(using: .utf8)!
        )
      ]
      let secondItem = HistoryItem()
      Storage.shared.context.insert(secondItem)
      secondItem.contents = secondContents
      let second = history.add(secondItem)

      #expect(history.items.toArray() == [second])
      #expect(Set(history.items[0].item.contents) == Set(firstContents))
    }

    @Test("Adding item from Maccy")
    func addingItemFromMaccy() {
      let firstContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)
        )
      ]
      let first = HistoryItem()
      Storage.shared.context.insert(first)
      first.application = "Xcode.app"
      first.contents = firstContents
      history.add(first)

      let secondContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.fromMaccy.rawValue,
          value: "".data(using: .utf8)
        )
      ]
      let second = HistoryItem()
      Storage.shared.context.insert(second)
      second.application = "Maccy.app"
      second.contents = secondContents
      let secondDecorator = history.add(second)

      #expect(history.items.toArray() == [secondDecorator])
      #expect(history.items[0].item.application == "Xcode.app")
      #expect(Set(history.items[0].item.contents) == Set(firstContents))
    }

    @Test("Modified after copying")
    func modifiedAfterCopying() {
      history.add(historyItem("foo"))

      let modifiedItem = historyItem("bar")
      modifiedItem.contents.append(HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: String(Clipboard.shared.changeCount).data(using: .utf8)
      ))
      let modifiedItemDecorator = history.add(modifiedItem)

      #expect(history.items.toArray() == [modifiedItemDecorator])
      #expect(history.items[0].text == "bar")
    }

    @Test("Clearing unpinned")
    func clearingUnpinned() throws {
      let pinned = history.add(historyItem("foo"))
      history.togglePin(pinned)
      history.add(historyItem("bar"))
      let orphan = HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "orphan".data(using: .utf8)
      )
      Storage.shared.context.insert(orphan)
      try Storage.shared.context.save()

      history.clear()

      #expect(history.items.toArray() == [pinned])
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Clearing all")
    func clearingAll() throws {
      history.add(historyItem("foo"))
      let pinned = history.add(historyItem("bar"))
      history.togglePin(pinned)
      Storage.shared.context.insert(HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "orphan".data(using: .utf8)
      ))
      try Storage.shared.context.save()

      history.clearAll()

      #expect(history.items.toArray() == [])
      try assertStorageCounts(items: 0, contents: 0)
    }

    @Test("Custom board membership survives duplicate copies and reloads")
    func customBoardMembershipSurvivesRecopyAndReload() async throws {
      let boards = ShelfBoards.shared
      let board = boards.create(name: "Research")
      defer { boards.delete(board.id) }

      for legacy in [false, true] {
        let text = legacy ? "legacy board note" : "board note"
        let source = historyItem(text)
        if legacy { source.archiveID = nil }
        let original = history.add(source)
        let originalArchiveID = original.item.archiveID
        let originalDate = original.item.firstCopiedAt
        boards.toggleMember(original.item, in: board.id)

        let copied = history.add(historyItem(text))
        #expect(copied.item.archiveID == originalArchiveID)
        #expect(copied.item.firstCopiedAt == originalDate)
        #expect(boards.contains(copied.item, in: board.id))

        try await history.load()
        let loaded = try #require(history.items.first { $0.text == text })
        let persistedBoards = ShelfBoards()
        #expect(persistedBoards.contains(loaded.item, in: board.id))
      }
      try assertStorageCounts(items: 2, contents: 2)
    }

    @Test("Custom board contents survive history trimming and clearing")
    func customBoardContentsSurviveTrimmingAndClearing() async throws {
      let boards = ShelfBoards.shared
      let board = boards.create(name: "Keep")
      defer { boards.delete(board.id) }
      Defaults[.size] = 2
      let saved = history.add(historyItem("saved board item"))
      boards.toggleMember(saved.item, in: board.id)
      for index in 1...3 {
        history.add(historyItem("recent \(index)"))
      }

      #expect(history.items.count == 3)
      #expect(history.items.contains(saved))
      #expect(!history.items.contains { $0.text == "recent 1" })

      history.clear()
      #expect(history.items.toArray() == [saved])
      try assertStorageCounts(items: 1, contents: 1)
      try await history.load()
      let loaded = try #require(history.items.first)
      #expect(loaded.text == "saved board item")
      #expect(boards.contains(loaded.item, in: board.id))
    }

    @Test("Clearing all removes custom board contents and membership")
    func clearingAllRemovesCustomBoardContents() throws {
      let boards = ShelfBoards.shared
      let board = boards.create(name: "Saved")
      defer { boards.delete(board.id) }
      let first = history.add(historyItem("saved first"))
      let second = history.add(historyItem("saved second"))
      boards.toggleMember(first.item, in: board.id)
      boards.toggleMember(second.item, in: board.id)
      history.togglePin(second)

      history.clearAll()

      #expect(history.items.isEmpty)
      let emptied = try #require(boards.boards.first { $0.id == board.id })
      #expect(emptied.itemIDs.isEmpty)
      let persisted = try #require(ShelfBoards().boards.first { $0.id == board.id })
      #expect(persisted.itemIDs.isEmpty)
      try assertStorageCounts(items: 0, contents: 0)
    }

    @Test("Max size")
    func maxSize() throws {
      var items: [HistoryItemDecorator] = []
      for index in 0...10 {
        items.append(history.add(historyItem(String(index))))
      }

      #expect(history.items.count == 10)
      #expect(history.items.contains(items[10]))
      #expect(!history.items.contains(items[0]))
      try assertStorageCounts(items: 10, contents: 10)
    }

    @Test("Max size ignores pinned")
    func maxSizeIgnoresPinned() {
      var items: [HistoryItemDecorator] = []

      let item = history.add(historyItem("0"))
      items.append(item)
      history.togglePin(item)

      for index in 1...11 {
        items.append(history.add(historyItem(String(index))))
      }

      #expect(history.items.count == 11)
      #expect(history.items.contains(items[10]))
      #expect(history.items.contains(items[0]))
      #expect(!history.items.contains(items[1]))
    }

    @Test("Pinning updates pin order")
    func pinningUpdatesPinOrder() {
      let item = history.add(historyItem("foo"))
      history.togglePin(item)

      #expect(history.pinnedItems == [item])
      #expect(Defaults[.pinOrder].pins == [item.item.pin].compactMap { $0 })
    }

    @Test("Pins without a free key get no shortcuts")
    func noShortcutsForPinWithoutKey() {
      #expect(KeyShortcut.create(character: "").isEmpty)
      #expect(KeyShortcut.create(character: "b").count == 3)
    }

    @Test("Pinning after all shortcuts are assigned")
    func pinningAfterAllShortcutsAreAssigned() async throws {
      let supportedPins = HistoryItem.supportedPins
      for index in 0..<supportedPins.count {
        let item = history.add(historyItem("keyed \(index)"))
        history.togglePin(item)
      }

      #expect(history.availablePins.isEmpty)
      #expect(Set(history.pinnedItems.compactMap(\.item.pin)) == supportedPins)

      let first = history.add(historyItem("first without shortcut"))
      history.togglePin(first)
      let second = history.add(historyItem("second without shortcut"))
      history.togglePin(second)

      #expect(first.item.pin == "")
      #expect(second.item.pin == "")
      #expect(history.pinnedItems.suffix(2) == [first, second])
      #expect(history.unpinnedItems.isEmpty)

      for index in 0...Defaults[.size] {
        history.add(historyItem("unpinned \(index)"))
      }

      let expectedCount = supportedPins.count + 2
      #expect(history.pinnedItems.count == expectedCount)
      try assertStorageCounts(
        items: expectedCount + Defaults[.size],
        contents: expectedCount + Defaults[.size]
      )

      try await history.load()
      #expect(history.pinnedItems.count == expectedCount)
      #expect(
        Set(history.pinnedItems.filter { $0.item.pin == "" }.map(\.title)) ==
        ["first without shortcut", "second without shortcut"]
      )
    }

    @Test("Unpinning updates pin order")
    func unpinningUpdatesPinOrder() {
      let item = history.add(historyItem("foo"))
      history.togglePin(item)
      history.togglePin(item)

      #expect(history.pinnedItems == [])
      #expect(Defaults[.pinOrder].pins == [])
    }

    @Test("Moving pins updates pin order")
    func movingPinsUpdatesPinOrder() {
      let first = history.add(historyItem("foo"))
      let second = history.add(historyItem("bar"))
      history.togglePin(first)
      history.togglePin(second)

      history.movePin(from: IndexSet(integer: 0), to: 2)

      #expect(history.pinnedItems == [second, first])
      #expect(Defaults[.pinOrder].pins == [second.item.pin, first.item.pin].compactMap { $0 })
    }

    @Test("Max size is changed")
    func maxSizeIsChanged() {
      var items: [HistoryItemDecorator] = []
      for index in 0...10 {
        items.append(history.add(historyItem(String(index))))
      }
      Defaults[.size] = 5
      history.add(historyItem("11"))

      #expect(history.items.count == 5)
      #expect(history.items.contains(items[10]))
      #expect(!history.items.contains(items[5]))
    }

    @Test("Re-adding bottom-most pinned item at full capacity")
    func readdingBottomMostPinnedItemAtFullCapacity() {
      // Regression test for a crash when re-copying (invoking) the bottom-most
      // pinned item while history is at full capacity and pins are sorted to the
      // bottom. The stale insert index used to trap with an out-of-bounds insert.
      // Issue link: https://github.com/p0deje/Maccy/issues/1466
      // `pinTo` is restored to its default value(.top) in `deinit`.
      Defaults[.pinTo] = .bottom

      // Pin an item; `history.togglePin` re-sorts `all`, so with `.bottom` the
      // pinned item ends up as the last element.
      let pinned = history.add(historyItem("pinned"))
      history.togglePin(pinned)

      // Fill unpinned history to full capacity.
      for index in 0..<Defaults[.size] {
        history.add(historyItem(String(index)))
      }

      #expect(history.items.last == pinned)

      // Re-copy the pinned item. It is detected as a duplicate, removed and
      // re-inserted while `limitHistorySize` trims an exceeding unpinned item.
      // Before the fix this inserted at a stale, out-of-bounds index and crashed.
      let readded = history.add(historyItem("pinned"))

      #expect(history.items.contains(readded))
      #expect(history.items.filter(\.isPinned).count == 1)
    }

    @Test("Removing")
    func removing() throws {
      let foo = history.add(historyItem("foo"))
      let bar = history.add(historyItem("bar"))
      history.delete(foo)
      #expect(history.items.toArray() == [bar])
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Cleaning up orphaned contents")
    func cleaningUpOrphanedContents() throws {
      let live = history.add(historyItem("live"))
      let liveContent = live.item.contents[0]
      for value in ["orphan-1", "orphan-2"] {
        Storage.shared.context.insert(HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.data(using: .utf8)
        ))
      }
      try Storage.shared.context.save()

      #expect(try Storage.shared.cleanupOrphanedContents() == 2)
      #expect(try Storage.shared.cleanupOrphanedContents() == 0)
      #expect(live.item.contents == [liveContent])
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Removing unpersistable contents")
    func removingUnpersistableContents() throws {
      let live = history.add(historyItem("live"))
      live.item.contents.append(HistoryItemContent(
        type: NSPasteboard.PasteboardType.safariWebArchve.rawValue,
        value: Data(repeating: 0x61, count: 1024)
      ))
      try Storage.shared.context.save()

      #expect(try Storage.shared.removeUnpersistableContents() == 1)
      #expect(try Storage.shared.removeUnpersistableContents() == 0)
      #expect(live.item.contents.map(\.type) == [NSPasteboard.PasteboardType.string.rawValue])
      try assertStorageCounts(items: 1, contents: 1)
    }

    private func assertStorageCounts(
      items: Int,
      contents: Int,
      orphaned: Int = 0,
      fileID: String = #fileID,
      filePath: String = #filePath,
      line: Int = #line,
      column: Int = #column
    ) throws {
      let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
      let context = Storage.shared.context
      context.processPendingChanges()
      try context.save()
      #expect(
        try context.fetchCount(FetchDescriptor<HistoryItem>()) == items,
        sourceLocation: sourceLocation
      )
      #expect(
        try context.fetchCount(FetchDescriptor<HistoryItemContent>()) == contents,
        sourceLocation: sourceLocation
      )
      #expect(
        try context.fetchCount(FetchDescriptor<HistoryItemContent>(
          predicate: #Predicate { $0.item == nil }
        )) == orphaned,
        sourceLocation: sourceLocation
      )
    }

    private func historyItem(_ value: String, persisted: Bool = true) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      if persisted {
        Storage.shared.context.insert(item)
      }
      item.contents = contents
      item.numberOfCopies = 1
      item.title = item.generateTitle()

      return item
    }
  }
}

extension SharedStateTests {
  @MainActor
  struct ClipboardArchiveTests {
    @Test("Selected history is archived and revocation updates both copies")
    func selectedHistoryAndRevocation() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanUp() }
      let archive = fixture.archive
      let cloudFolder = fixture.root.appending(path: "provider")
      try FileManager.default.createDirectory(at: cloudFolder, withIntermediateDirectories: true)
      let shared = try fixture.insertText("fixture")
      _ = try fixture.insertText("private fixture")
      let sharedID = try #require(shared.archiveID).uuidString.lowercased()
      let cloudURL = cloudFolder.appending(path: "ClipContext/\(archive.deviceID)/clipboard.json")

      archive.start()
      #expect(!archive.canSync)
      #expect(!FileManager.default.fileExists(atPath: archive.localURL.path))
      try archive.setFolder(cloudFolder, for: .iCloudDrive)
      archive.setShared(true, for: shared)
      try await waitForPublication(archive)
      let first = try fixture.readSnapshot()
      #expect(archive.canSync)
      #expect(first.items.map(\.id) == [sharedID])
      #expect(first.items.first?.contents.first?.text == "fixture")
      #expect(try Data(contentsOf: cloudURL) == Data(contentsOf: archive.localURL))

      archive.setShared(false, for: shared)
      try await waitForPublication(archive)
      let second = try fixture.readSnapshot()
      #expect(second.items.isEmpty)
      #expect(second.revision > first.revision)
      #expect(try Data(contentsOf: cloudURL) == Data(contentsOf: archive.localURL))
      try archive.disconnect(.iCloudDrive)
      #expect(!FileManager.default.fileExists(atPath: cloudURL.path))
    }

    @Test("Archive policies honor exclusions and encode supported content")
    func policiesAndFilters() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanUp() }
      let archive = fixture.archive
      let savedApps = Defaults[.ignoredApps]
      let savedMode = Defaults[.ignoreAllAppsExceptListed]
      let savedPatterns = Defaults[.ignoreRegexp]
      defer {
        Defaults[.ignoredApps] = savedApps
        Defaults[.ignoreAllAppsExceptListed] = savedMode
        Defaults[.ignoreRegexp] = savedPatterns
      }
      Defaults[.ignoredApps] = ["org.clipcontext.fixture.blocked"]
      Defaults[.ignoreAllAppsExceptListed] = false
      Defaults[.ignoreRegexp] = ["fixture-secret-[0-9]+"]
      let image = Data([0x89, 0x50, 0x4e, 0x47])
      let link = "https://example.com/fixture"
      let pinned = try fixture.insert([
        .init(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("pinned fixture".utf8)),
        .init(type: NSPasteboard.PasteboardType.png.rawValue, value: image),
        .init(type: NSPasteboard.PasteboardType.URL.rawValue, value: Data(link.utf8)),
        .init(type: NSPasteboard.PasteboardType.source.rawValue, value: Data("fixture metadata".utf8))
      ], pin: "b")
      let unpinned = try fixture.insertText("unpinned fixture")
      let appFiltered = try fixture.insertText("application fixture", application: "org.clipcontext.fixture.blocked")
      let regexFiltered = try fixture.insertText("fixture-secret-123")
      let transient = try fixture.insert([
        .init(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("transient fixture".utf8)),
        .init(type: NSPasteboard.PasteboardType.transient.rawValue, value: Data([0x00]))
      ])
      let pinnedID = try #require(pinned.archiveID).uuidString.lowercased()
      let unpinnedID = try #require(unpinned.archiveID).uuidString.lowercased()

      archive.policy = .pinned
      archive.start()
      try await waitForPublication(archive)
      let pinnedOnly = try fixture.readSnapshot()
      #expect(pinnedOnly.items.map(\.id) == [pinnedID])
      let parts = try #require(pinnedOnly.items.first?.contents)
      #expect(parts.count == 3)
      #expect(parts.first { $0.type == NSPasteboard.PasteboardType.png.rawValue }?.base64 == image)
      #expect(parts.first { $0.type == NSPasteboard.PasteboardType.URL.rawValue }?.text == link)
      #expect(parts.first { $0.type == NSPasteboard.PasteboardType.string.rawValue }?.text == "pinned fixture")

      archive.policy = .all
      try await waitForPublication(archive)
      #expect(try Set(fixture.readSnapshot().items.map(\.id)) == [pinnedID, unpinnedID])
      #expect(!archive.canShare(appFiltered))
      #expect(!archive.canShare(regexFiltered))
      #expect(!archive.canShare(transient))

      archive.setShared(false, for: pinned)
      try await waitForPublication(archive)
      #expect(try fixture.readSnapshot().items.map(\.id) == [unpinnedID])

      archive.policy = .off
      try await waitForPublication(archive)
      #expect(try fixture.readSnapshot().items.isEmpty)
    }

    @Test("Remote failures retry and unchanged snapshots keep their revision")
    func retriesRemotePublicationWithoutRevisionChurn() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanUp() }
      let archive = fixture.archive
      _ = try fixture.insertText("remote fixture")
      var attempts: [Data] = []
      archive.remotePublisher = { bytes, deviceID in
        #expect(!deviceID.isEmpty)
        attempts.append(bytes)
        if attempts.count == 1 { throw URLError(.notConnectedToInternet) }
      }

      archive.policy = .all
      archive.start()
      try await waitForPublication(archive)
      #expect(archive.remoteError != nil)
      #expect(archive.remoteLastSync == nil)
      let first = try Data(contentsOf: archive.localURL)

      archive.syncNow()
      try await waitForPublication(archive)
      #expect(attempts == [first, first])
      #expect(archive.remoteError == nil)
      #expect(archive.remoteLastSync != nil)

      archive.syncNow()
      try await waitForPublication(archive)
      #expect(attempts.count == 2)
      #expect(try Data(contentsOf: archive.localURL) == first)

      archive.invalidateRemotePublication()
      try await waitForPublication(archive)
      #expect(attempts == [first, first, first])
    }

    private func waitForPublication(_ archive: ClipboardArchive) async throws {
      let deadline = ContinuousClock.now + .seconds(10)
      while archive.isPublishing && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      try #require(!archive.isPublishing)
      #expect(archive.localError == nil)
    }

    @MainActor
    private final class Fixture {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      let suite = "com.benzema.ClipContext.archive-test.\(UUID().uuidString)"
      let preferences: UserDefaults
      let container: ModelContainer
      let archive: ClipboardArchive

      init() throws {
        preferences = try #require(UserDefaults(suiteName: suite))
        container = try ModelContainer(
          for: HistoryItem.self,
          configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        archive = ClipboardArchive(preferences: preferences, localURL: root.appending(path: "local/clipboard.json")) {
          context
        }
      }

      func cleanUp() {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
      }

      func insertText(_ text: String, application: String? = nil) throws -> HistoryItem {
        let content = HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8))
        return try insert([content], application: application)
      }

      func insert(_ contents: [HistoryItemContent], pin: String? = nil, application: String? = nil) throws -> HistoryItem {
        let item = HistoryItem(contents: contents)
        item.pin = pin
        item.application = application
        container.mainContext.insert(item)
        try container.mainContext.save()
        return item
      }

      func readSnapshot() throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: archive.localURL))
      }
    }

    private struct Snapshot: Decodable {
      struct Item: Decodable {
        struct Part: Decodable {
          let type: String
          let text: String?
          let base64: Data?
        }

        let id: String
        let contents: [Part]
      }

      let revision: Int
      let items: [Item]
    }
  }
}
