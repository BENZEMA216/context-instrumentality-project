@preconcurrency import ApplicationServices
import Carbon
import XCTest

// swiftlint:disable file_length
// swiftlint:disable type_body_length
@MainActor
private struct HistoryItemQuery {
  let query: XCUIElementQuery

  var allElementsBoundByIndex: [XCUIElement] {
    query.allElementsBoundByIndex
  }

  subscript(title: String) -> XCUIElement {
    query.matching(
      NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, "\(title), ")
    ).firstMatch
  }
}

@MainActor
class MaccyUITests: XCTestCase {
  let app = XCUIApplication()
  let pasteboard = NSPasteboard.withUniqueName()
  let fixtureDirectory = FileManager.default.temporaryDirectory.appending(path: "ClipContext-UITests-\(UUID().uuidString)")

  let copy1 = UUID().uuidString
  let copy2 = UUID().uuidString
  let copy3 = UUID().uuidString

  // https://hetima.github.io/fucking_nsimage_syntax
  let image1 = NSImage(named: "NSAddTemplate")!
  let image2 = NSImage(named: "NSBluetoothTemplate")!

  var file1: URL { fixtureDirectory.appending(path: "file1.txt") }
  var file2: URL { fixtureDirectory.appending(path: "file2.txt") }

  let rtf1 = NSAttributedString(string: "foo").rtf(
    from: NSRange(0...2),
    documentAttributes: [:]
  )
  let rtf2 = NSAttributedString(string: "bar").rtf(
    from: NSRange(0...2),
    documentAttributes: [:]
  )

  let html1 = "<a href='#'>foo</a>".data(using: .utf8)
  let html2 = "<a href='#'>bar</a>".data(using: .utf8)

  private var items: HistoryItemQuery {
    HistoryItemQuery(
      query: app.descendants(matching: .any).matching(identifier: "copy-history-item")
    )
  }

  var itemTitles: [String] {
    items.allElementsBoundByIndex
      .sorted(by: { $0.frame.origin.y < $1.frame.origin.y })
      .compactMap { $0.label.components(separatedBy: ", ").first }
  }

  override func setUp() async throws {
    try await super.setUp()
    continueAfterFailure = false

    try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    try "Hello world".write(to: file1, atomically: true, encoding: .utf8)
    try "Hello world".write(to: file2, atomically: true, encoding: .utf8)

    app.launchArguments.append(contentsOf: ["enable-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
    app.launchEnvironment["CLIPCONTEXT_QA_PASTEBOARD"] = pasteboard.name.rawValue
    app.launchEnvironment["CLIPCONTEXT_QA_DIRECTORY"] = fixtureDirectory.path
    if name.contains("testShelf") {
      app.launchEnvironment["CLIPCONTEXT_QA_HISTORY_PRESENTATION"] = "shelf"
    }
    setKeyboardShortcut("popup", keyCode: kVK_ANSI_C, modifiers: cmdKey | shiftKey)
    setKeyboardShortcut("pin", keyCode: kVK_ANSI_P, modifiers: optionKey)
    setKeyboardShortcut("delete", keyCode: kVK_Delete, modifiers: optionKey)
    setKeyboardShortcut("togglePreview", keyCode: kVK_Space, modifiers: controlKey)
    app.launch()
    // Use the real menu-bar or hotkey entry point. Explicitly activating this
    // accessory app can later restore the previous app and dismiss its panel.

    copyToClipboard(copy2)
    copyToClipboard(copy1)
  }

  override func tearDown() async throws {
    releaseRawKeyboardState()
    app.terminate()
    pasteboard.releaseGlobally()
    try? FileManager.default.removeItem(at: fixtureDirectory)
    try await super.tearDown()
  }

  func testPopupWithHotkey() throws {
    popUpWithHotkey()
    assertExists(items[copy1])
    assertExists(items[copy2])
  }

  func testCloseWithHotkey() throws {
    popUpWithMouse()
    assertExists(items[copy1])
    simulatePopupHotkey()
    assertNotExists(items[copy1])
  }

  func testPopupWithMenubar() {
    popUpWithMouse()
    assertExists(items[copy1])
    assertExists(items[copy2])
  }

  func testNewCopyIsAdded() {
    popUpWithMouse()
    let copy3 = UUID().uuidString
    copyToClipboard(copy3)
    assertExists(items[copy3])
    typeInPopup(.escape)
    popUpWithMouse()
    assertExists(items[copy2])
  }

  func testSearch() {
    popUpWithMouse()
    search(copy2)
    assertSearchFieldValue(copy2)
    assertExists(app.staticTexts[copy2])
    assertNotExists(items[copy1])
  }

  func testSearchFiles() {
    copyToClipboard(file2)
    copyToClipboard(file1)
    popUpWithMouse()
    search(file2.lastPathComponent)
    assertExists(items[file2.absoluteString.removingPercentEncoding!])
    assertNotExists(items[file1.absoluteString.removingPercentEncoding!])
  }

  func testCopyWithClick() {
    popUpWithMouse()
    scrollIntoViewIfNeeded(items[copy2].firstMatch)
    items[copy2].firstMatch.click()
    assertPasteboardStringEquals(copy2)
  }

  func testCopyWithEnter() {
    popUpWithMouse()
    scrollIntoViewIfNeeded(items[copy2].firstMatch)
    hover(items[copy2].firstMatch)
    typeInPopup(.enter)
    assertPasteboardStringEquals(copy2)
  }

  func testCopyWithCommandShortcut() {
    popUpWithMouse()
    typeInPopup("2", modifiers: [.command])
    assertPasteboardStringEquals(copy2)
  }

  func testSearchAndCopyWithCommandShortcut() {
    popUpWithMouse()
    search(copy2)
    typeInPopup("1", modifiers: [.command])
    assertPasteboardStringEquals(copy2)
  }

  func testCopyImage() {
    copyToClipboard(image2)
    copyToClipboard(image1)
    popUpWithMouse()
    let allItems = items.allElementsBoundByIndex
    guard allItems.count > 1 else {
      XCTFail("Expected at least 2 history items, found \(allItems.count)")
      return
    }
    scrollIntoViewIfNeeded(allItems[1])
    hoverAndClick(allItems[1])
    assertPasteboardDataCountEquals(image2.tiffRepresentation!.count, forType: .tiff)
  }

  func testOCRRecognizesTextInImage() {
    copyToClipboard(textImage("Lighthouse"))
    popUpWithMouse()
    assertImageFound(bySearching: "lighthouse")
  }

  func testOCRCopiesRecognizedTextFromSidePanel() {
    copyToClipboard(textImage("Lighthouse"))
    popUpWithMouse()

    let imageItem = items.query.matching(NSPredicate(format: "label BEGINSWITH %@", "Image, ")).firstMatch
    assertExists(imageItem)
    hover(imageItem)

    let copyTextButton = app.buttons["Copy extracted text."].firstMatch
    XCTAssertTrue(copyTextButton.waitForExistence(timeout: 3), "Side panel has no copy extracted text button")
    expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: copyTextButton)
    waitForExpectations(timeout: 15)
    copyTextButton.click()

    assertExists(items["Lighthouse"])
    XCTAssertEqual(itemTitles.first, "Lighthouse")
    assertPasteboardStringEquals("Lighthouse")
  }

  func testCopyFile() {
    copyToClipboard(file2)
    copyToClipboard(file1)
    popUpWithMouse()

    XCTAssertEqual(Array(itemTitles.prefix(2)), [
      file1.absoluteString.removingPercentEncoding!,
      file2.absoluteString.removingPercentEncoding!
    ])
    scrollIntoViewIfNeeded(items[file2.absoluteString.removingPercentEncoding!].firstMatch)
    hoverAndClick(items[file2.absoluteString.removingPercentEncoding!].firstMatch)
    assertPasteboardStringEquals(file2.absoluteString, forType: .fileURL)
  }

  func testCopyRTF() {
    copyToClipboard(rtf2, .rtf)
    popUpWithMouse()
    closePopupByClickingOutside()
    copyToClipboard(rtf1, .rtf)
    popUpWithMouse()
    XCTAssertEqual(Array(itemTitles.prefix(2)), ["foo", "bar"])
    scrollIntoViewIfNeeded(items["bar"].firstMatch)
    hoverAndClick(items["bar"].firstMatch)
    assertPasteboardDataEquals(rtf2, forType: .rtf)
    waitTillClipboardCheck()
    popUpWithMouse()
    XCTAssertEqual(itemTitles.filter { $0 == "bar" }.count, 1, "Re-copying RTF must not duplicate its history item")
  }

  func testCopyHTML() {
    copyToClipboard(html2, .html)
    copyToClipboard(html1, .html)
    popUpWithMouse()
    XCTAssertEqual(Array(itemTitles.prefix(2)), ["foo", "bar"])
    scrollIntoViewIfNeeded(items["bar"].firstMatch)
    hoverAndClick(items["bar"].firstMatch)
    assertPasteboardDataEquals(html2, forType: .html)
  }

  func testDownArrow() {
    popUpWithMouse()
    typeInPopup(.downArrow)
    typeInPopup(.enter)
    assertPasteboardStringEquals(copy2)
  }

  func testUpArrow() {
    popUpWithMouse()
    typeInPopup(.downArrow)
    typeInPopup(.upArrow)
    typeInPopup(.enter)
    assertPasteboardStringEquals(copy1)
  }

  func testControlJ() {
    popUpWithMouse()
    typeInPopup("j", modifiers: [.control])
    typeInPopup(.enter)
    assertPasteboardStringEquals(copy2)
  }

  func testControlK() {
    popUpWithMouse()
    typeInPopup("j", modifiers: [.control])
    typeInPopup("k", modifiers: [.control])
    typeInPopup(.enter)
    assertPasteboardStringEquals(copy1)
  }

  func testDeleteEntry() {
    popUpWithMouse()
    typeInPopup(.delete, modifiers: [.option])
    assertNotExists(items[copy1])

    typeInPopup(.escape)
    popUpWithMouse()
    assertNotExists(items[copy1])
  }

  func testDeleteEntryDuringSearch() {
    popUpWithMouse()
    search(copy2)
    typeInPopup(.delete, modifiers: [.option])
    assertNotExists(items[copy2])

    typeInPopup(.escape)
    popUpWithMouse()
    assertNotExists(items[copy2])
  }

  func testClear() {
    popUpWithMouse()
    scrollIntoViewIfNeeded(items[copy2].firstMatch)
    pin(copy2)
    hoverAndClick(app.buttons["Clear"].firstMatch)
    confirmClear()
    popUpWithMouse()
    assertNotExists(items[copy1])
    assertExists(items[copy2])
  }

  func testClearDuringSearch() {
    popUpWithMouse()
    search(copy2)
    hoverAndClick(app.buttons["Clear"].firstMatch)
    confirmClear()
    popUpWithMouse()
    assertNotExists(items[copy1])
    assertNotExists(items[copy2])
  }

  func testClearAll() {
    popUpWithMouse()
    scrollIntoViewIfNeeded(items[copy2].firstMatch)
    pin(copy2)
    clickClearAllWhileHoldingShift()
    confirmClear()
    popUpWithMouse()
    assertNotExists(items[copy1])
    assertNotExists(items[copy2])
  }

  func testPin() {
    popUpWithMouse()
    scrollIntoViewIfNeeded(items[copy2].firstMatch)
    pin(copy2)
    XCTAssertEqual(Array(itemTitles.prefix(2)), [copy2, copy1])

    typeInPopup(.escape)
    popUpWithMouse()
    XCTAssertEqual(Array(itemTitles.prefix(2)), [copy2, copy1])
  }

  func testPinDuringSearch() {
    popUpWithMouse()
    search(copy2)
    scrollIntoViewIfNeeded(items[copy2].firstMatch)
    pin(copy2)
    assertSearchFieldValue("")
    XCTAssertEqual(Array(itemTitles.prefix(2)), [copy2, copy1])
  }

  func testUnpin() {
    popUpWithMouse()
    scrollIntoViewIfNeeded(items[copy2].firstMatch)
    pin(copy2)
    pin(copy2)
    XCTAssertEqual(Array(itemTitles.prefix(2)), [copy1, copy2])
  }

  func testReorderPinsByDragging() {
    popUpWithMouse()
    pin(copy1)
    pin(copy2)
    XCTAssertEqual(Array(itemTitles.prefix(2)), [copy1, copy2])

    drag(items[copy2].firstMatch, before: items[copy1].firstMatch)
    XCTAssertEqual(Array(itemTitles.prefix(2)), [copy2, copy1])

    typeInPopup(.escape)
    popUpWithMouse()
    XCTAssertEqual(Array(itemTitles.prefix(2)), [copy2, copy1])
  }

  func testRemoveLastWordFromSearchWithControlW() {
    popUpWithMouse()
    search("foo bar")
    typeInPopup("w", modifiers: [.control])
    assertSearchFieldValue("foo ")
  }

  func testPasteToSearch() throws {
    try requireTestPrecondition(
      ProcessInfo.processInfo.environment["CLIPCONTEXT_TEST_SYSTEM_PASTE"] == "1",
      "The native Command-V test requires explicit permission to use the system pasteboard."
    )
    try requireRawKeyboardAccess()
    popUpWithMouse()
    let field = app.textFields.firstMatch
    assertExists(field)
    field.click()
    try withTemporarySystemPasteboardString(copy1) {
      typeInPopup("v", modifiers: [.command])
      // CGEvent posting is asynchronous. Keep the fixture on the real pasteboard
      // until AppKit has consumed native Cmd-V, then restore the user's contents.
      expectation(for: NSPredicate { _, _ in
        field.exists && field.value as? String == self.copy1
      }, evaluatedWith: nil)
      waitForExpectations(timeout: 3)
    }
    XCTAssertTrue(field.value as? String == copy1, "Search did not paste the test fixture.")
    assertExists(items[copy1])
    assertNotExists(items[copy2])
  }

  private func withTemporarySystemPasteboardString(_ text: String, action: () -> Void) throws {
    let systemPasteboard = NSPasteboard.general
    let originalChangeCount = systemPasteboard.changeCount
    let backup = try snapshotPasteboard(in: systemPasteboard)
    let fixture = NSPasteboardItem()
    fixture.setString(text, forType: .string)
    fixture.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    try requireTestPrecondition(systemPasteboard.changeCount == originalChangeCount, "The system pasteboard changed during setup.")

    var fixtureChangeCount = systemPasteboard.clearContents()
    defer {
      // The user may have copied something new while the test was running.
      if systemPasteboard.changeCount == fixtureChangeCount {
        systemPasteboard.clearContents()
        if !backup.isEmpty {
          XCTAssertTrue(systemPasteboard.writeObjects(backup), "Could not restore the previous system pasteboard.")
          let restored = systemPasteboard.pasteboardItems ?? []
          XCTAssertEqual(restored.count, backup.count, "The restored pasteboard item count differs.")
          for (original, result) in zip(backup, restored) {
            for type in original.types {
              XCTAssertTrue(
                original.data(forType: type) == result.data(forType: type),
                "A clipboard representation was not restored byte-for-byte."
              )
            }
          }
        }
      }
    }
    let wroteFixture = systemPasteboard.writeObjects([fixture])
    fixtureChangeCount = systemPasteboard.changeCount
    XCTAssertTrue(wroteFixture, "Could not write the test fixture.")
    if wroteFixture { action() }
  }

  private func snapshotPasteboard(in pasteboard: NSPasteboard) throws -> [NSPasteboardItem] {
    // Copy every available representation, including images, file references, legacy
    // types and privacy markers. Nothing from the user's clipboard is logged.
    guard let items = pasteboard.pasteboardItems else {
      if pasteboard.types?.isEmpty ?? true { return [] }
      try requireTestPrecondition(false, "Could not snapshot the current system pasteboard for restoration.")
      return []
    }
    return try items.map { item in
      let backup = NSPasteboardItem()
      for type in item.types {
        guard let bytes = item.data(forType: type), backup.setData(bytes, forType: type) else {
          try requireTestPrecondition(false, "A system pasteboard representation could not be copied for restoration.")
          return backup
        }
      }
      return backup
    }
  }

  func testDisablesOnOptionClickingMenubarIcon() {
    clickStatusItem(modifiers: [.option])

    let copy3 = UUID().uuidString
    let copy4 = UUID().uuidString
    copyToClipboard(copy3)
    copyToClipboard(copy4)

    popUpWithMouse()
    assertNotExists(items[copy3])
    assertNotExists(items[copy4])

    typeInPopup(.escape)
    clickStatusItem(modifiers: [.option])
  }

  func testDisablesOnlyForNextCopyOnOptionShiftClickingMenubarIcon() {
    clickStatusItem(modifiers: [.option, .shift])

    let copy3 = UUID().uuidString
    let copy4 = UUID().uuidString
    copyToClipboard(copy3)
    copyToClipboard(copy4)

    popUpWithMouse()
    assertNotExists(items[copy3])
    assertExists(items[copy4])
  }

  func testCreatesNewCopyOnEnterWhenSearchResultsAreEmpty() {
    popUpWithMouse()
    search("foo bar")
    typeInPopup(.return)
    assertPasteboardStringEquals("foo bar")
    assertExists(items["foo bar"])
  }

  func testOpenAndClose() async throws {
    try await requestRawKeyboardAccessIfConfigured()
    try requireRawKeyboardAccess()
    defer { releaseRawKeyboardState() }

    // Simulate the popup hotkey press (Cmd + Shift + C).
    let cDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)!
    cDown.flags = [.maskCommand, .maskShift]
    cDown.post(tap: .cghidEventTap)

    waitUntilPoppedUp()

    // Release the 'C' key but keep the popup open.
    let cUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)!
    cUp.flags = [.maskCommand, .maskShift]
    cUp.post(tap: .cghidEventTap)

    waitUntilPoppedUp()

    // Release the 'Shift' key and assert that the popup remains open - "normal" mode.
    let shiftUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: false)!
    shiftUp.flags = [.maskCommand] // Command remains active, Shift released
    shiftUp.post(tap: .cghidEventTap)

    waitUntilPoppedUp()

    // Release the 'CMD' key and assert that the popup remains open - "normal" mode.
    let commandUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: false)!
    commandUp.flags = []
    commandUp.post(tap: .cghidEventTap)

    waitUntilPoppedUp()

    // Press shortcut again and assert the window closes
    cDown.flags = [.maskCommand, .maskShift]
    cDown.post(tap: .cghidEventTap)

    assertPopupDismissed()
  }

  func testOpenAndSelectSecondItem() async throws {
    try await requestRawKeyboardAccessIfConfigured()
    try requireRawKeyboardAccess()
    defer { releaseRawKeyboardState() }

    postKeyEvent(kVK_Command, down: true, flags: [.maskCommand])
    postKeyEvent(kVK_Shift, down: true, flags: [.maskCommand, .maskShift])
    // Two separate C presses, each released while the modifiers stay held.
    for _ in 0..<2 {
      postKeyEvent(kVK_ANSI_C, down: true, flags: [.maskCommand, .maskShift])
      postKeyEvent(kVK_ANSI_C, down: false, flags: [.maskCommand, .maskShift])
      waitUntilPoppedUp()
    }
    postKeyEvent(kVK_Shift, down: false, flags: [.maskCommand])
    postKeyEvent(kVK_Command, down: false, flags: [])
    assertPopupDismissed()
    assertPasteboardStringEquals(copy2)
  }

  func testOpenAndSelectThirdItem() async throws {
    try await requestRawKeyboardAccessIfConfigured()
    try requireRawKeyboardAccess()
    defer { releaseRawKeyboardState() }
    copyToClipboard(copy3)

    postKeyEvent(kVK_Command, down: true, flags: [.maskCommand])
    postKeyEvent(kVK_Shift, down: true, flags: [.maskCommand, .maskShift])
    // Three separate presses retain the ordinary key-up behavior under test.
    for _ in 0..<3 {
      postKeyEvent(kVK_ANSI_C, down: true, flags: [.maskCommand, .maskShift])
      postKeyEvent(kVK_ANSI_C, down: false, flags: [.maskCommand, .maskShift])
      waitUntilPoppedUp()
    }
    postKeyEvent(kVK_Shift, down: false, flags: [.maskCommand])
    postKeyEvent(kVK_Command, down: false, flags: [])
    assertPopupDismissed()
    assertPasteboardStringEquals(copy2)
  }

  func testOpenAndSelectThirdItemRepeatedPress() async throws {
    try await requestRawKeyboardAccessIfConfigured()
    try requireRawKeyboardAccess()
    defer { releaseRawKeyboardState() }
    copyToClipboard(copy3)

    // Simulate the popup hotkey press (Cmd + Shift + C).
    let cDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)!
    cDown.flags = [.maskCommand, .maskShift]
    cDown.post(tap: .cghidEventTap)

    waitUntilPoppedUp()

    // Press C 2 more times while keeping the modifier keys pressed
    cDown.post(tap: .cghidEventTap)
    cDown.post(tap: .cghidEventTap)

    // Release all modifiers keys and assert that the popup closes.
    let cUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)!
    cUp.flags = [.maskCommand, .maskShift]
    cUp.post(tap: .cghidEventTap)
    let modifiersUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: false)!
    modifiersUp.flags = []
    modifiersUp.post(tap: .cghidEventTap)

    assertPopupDismissed()
    assertPasteboardStringEquals(copy2)
  }

  func testTogglePopupAndCloseOnClickOutside() {
    popUpWithHotkey()

    closePopupByClickingOutside()
    assertNotExists(items[copy1])

    // Assert that the hotkeys still work
    popUpWithHotkey()

    simulatePopupHotkey()
    assertPopupDismissed()
  }

  func testShelfSearchShowsEmptyStateAndCopiesMatchingCard() {
    popUpWithMouse()
    let openSearch = shelfElement("shelf-open-search")
    assertExists(openSearch)
    clickInNonactivatingPopup(openSearch)
    let field = shelfElement("shelf-search")
    assertExists(field)
    clickInNonactivatingPopup(field)

    let missingQuery = "zzzz"
    typeSearchText(missingQuery)
    expectation(for: NSPredicate(format: "value == %@", missingQuery), evaluatedWith: field)
    waitForExpectations(timeout: 3)
    let emptyState = shelfElement("shelf-empty")
    assertExists(emptyState)
    assertNotExists(items[copy1])

    clickInNonactivatingPopup(shelfElement("shelf-clear-search"))
    expectation(for: NSPredicate(format: "value == %@", ""), evaluatedWith: field)
    waitForExpectations(timeout: 3)
    clickInNonactivatingPopup(field)
    let matchQuery = String(copy2.prefix(6))
    typeSearchText(matchQuery)
    expectation(for: NSPredicate(format: "value == %@", matchQuery), evaluatedWith: field)
    waitForExpectations(timeout: 3)
    assertExists(items[copy2])
    assertNotExists(items[copy1])
    assertNotExists(emptyState)

    clickInNonactivatingPopup(items[copy2])
    assertPasteboardStringEquals(copy2)
  }

  func testShelfRightArrowMovesToNextCardAndReturnCopiesIt() {
    popUpWithMouse()
    assertExists(shelfElement("shelf-open-search"))
    assertNotExists(shelfElement("shelf-search"))
    assertExists(shelfElement("history-scroll-view"))
    let firstCard = items[copy1]
    let secondCard = items[copy2]
    assertExists(firstCard)
    assertExists(secondCard)
    XCTAssertEqual(firstCard.frame.width, 232, accuracy: 2)
    XCTAssertEqual(firstCard.frame.height, 232, accuracy: 2)
    XCTAssertGreaterThan(secondCard.frame.minX, firstCard.frame.maxX)
    XCTAssertEqual(firstCard.frame.minY, secondCard.frame.minY, accuracy: 2)

    typeInPopup(.rightArrow)
    assertExists(app.dialogs.firstMatch)
    expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: secondCard)
    waitForExpectations(timeout: 3)
    typeInPopup(.return)
    assertPasteboardStringEquals(copy2)
  }

  func testShelfFavoritesShowOnlyPinnedCards() {
    popUpWithMouse()
    let history = shelfElement("shelf-history-tab")
    let favorites = shelfElement("shelf-favorites-tab")
    assertExists(history)
    assertExists(favorites)
    favorites.click()
    assertExists(shelfElement("shelf-empty"))
    typeInPopup(.return)
    assertPasteboardStringEquals(copy1)
    assertNotExists(items[copy1])
    assertNotExists(items[copy2])

    history.click()
    assertExists(items[copy2])
    items[copy2].rightClick()
    let pin = app.menuItems["收藏"].firstMatch
    assertExists(pin)
    pin.click()
    favorites.click()
    assertExists(items[copy2])
    assertNotExists(items[copy1])
    assertNotExists(shelfElement("shelf-empty"))

    history.click()
    assertExists(items[copy1])
  }

  func testShelfCustomBoardShowsOnlyItsMembers() {
    popUpWithMouse()
    let addBoard = shelfElement("shelf-add-board")
    assertExists(addBoard)
    addBoard.click()

    let boardName = "Release Notes"
    let nameField = shelfElement("shelf-board-name")
    assertExists(nameField)
    nameField.click()
    nameField.typeText(boardName)
    shelfElement("shelf-board-save").click()

    let boardTab = app.buttons.matching(NSPredicate(format: "label == %@", boardName)).firstMatch
    assertExists(boardTab)
    assertExists(shelfElement("shelf-empty"))
    assertNotExists(items[copy1])
    assertNotExists(items[copy2])

    shelfElement("shelf-history-tab").click()
    assertExists(items[copy1])
    assertExists(items[copy2])
    items[copy1].rightClick()
    let boardMenu = app.menuItems["加入收藏板"].firstMatch
    assertExists(boardMenu)
    boardMenu.click()
    let addToBoard = app.menuItems[boardName].firstMatch
    assertExists(addToBoard)
    addToBoard.click()

    boardTab.click()
    assertExists(items[copy1])
    assertNotExists(items[copy2])
    assertNotExists(shelfElement("shelf-empty"))
  }

  func testShelfTypeFilterShowsFilesAndRestoresAllCards() {
    copyToClipboard(file1)
    popUpWithMouse()
    let fileCard = items[file1.absoluteString.removingPercentEncoding!]
    assertExists(fileCard)
    assertExists(items[copy1])

    shelfElement("shelf-open-search").click()
    let filter = shelfElement("shelf-filter")
    assertExists(filter)
    filter.click()
    let fileFilter = shelfElement("shelf-filter-file")
    assertExists(fileFilter)
    fileFilter.click()
    assertExists(fileCard)
    assertNotExists(items[copy1])
    assertNotExists(items[copy2])

    filter.click()
    let allTypes = shelfElement("shelf-filter-all")
    assertExists(allTypes)
    allTypes.click()
    assertExists(items[copy1])
    assertExists(fileCard)
  }

  func testShelfSettingsNavigation() {
    popUpWithMouse()
    let more = shelfElement("shelf-more")
    assertExists(more)
    more.click()

    let openSettings = shelfElement("shelf-open-settings")
    let nativeMenuItem = app.menuItems.matching(
      NSPredicate(format: "label IN %@", ["设置…", "Settings…"])
    ).firstMatch
    let settingsCommand = openSettings.exists ? openSettings : nativeMenuItem
    assertExists(settingsCommand)
    settingsCommand.click()

    let settings = app.windows.containing(.any, identifier: "settings-page-general").firstMatch
    assertExists(settings)
    let general = settings.buttons["settings-page-general"]
    let privacy = settings.buttons["settings-page-privacy"]
    let appearance = settings.buttons["settings-page-appearance"]
    let generalHeading = settings.staticTexts["settings-heading-general"]
    let privacyHeading = settings.staticTexts["settings-heading-privacy"]
    let appearanceHeading = settings.staticTexts["settings-heading-appearance"]
    assertExists(generalHeading)

    privacy.click()
    assertExists(privacyHeading)
    assertNotExists(generalHeading)

    general.click()
    assertExists(generalHeading)
    assertNotExists(privacyHeading)

    appearance.click()
    assertExists(appearanceHeading)
    let layout = settings.descendants(matching: .any).matching(identifier: "settings-history-layout").firstMatch
    assertExists(layout)
  }

  func testMultipleSelectionControlsInList() {
    popUpWithMouse()
    let begin = shelfElement("begin-multiple-selection")
    assertExists(begin)
    begin.click()
    verifyMultipleSelectionControls()
  }

  func testShelfMultipleSelectionControls() {
    popUpWithMouse()
    shelfElement("shelf-more").click()
    let begin = shelfElement("begin-multiple-selection")
    assertExists(begin)
    begin.click()
    verifyMultipleSelectionControls()
  }

  private func verifyMultipleSelectionControls() {
    let count = shelfElement("paste-selection-count")
    let start = shelfElement("start-paste-stack")
    let cancel = shelfElement("cancel-multiple-selection")
    assertExists(count)
    assertExists(start)
    assertExists(cancel)
    expectation(for: NSPredicate(format: "value == %@", "已选 1 条"), evaluatedWith: count)
    waitForExpectations(timeout: 3)
    XCTAssertNotEqual(items[copy1].isSelected, items[copy2].isSelected)
    let additionalItem = items[copy1].isSelected ? items[copy2] : items[copy1]
    additionalItem.click()
    expectation(for: NSPredicate(format: "value == %@", "已选 2 条"), evaluatedWith: count)
    waitForExpectations(timeout: 3)
    XCTAssertTrue(start.isEnabled, "A two-item selection should offer the paste queue action")
    XCTAssertTrue(items[copy1].isSelected)
    XCTAssertTrue(items[copy2].isSelected)
    cancel.click()
    assertNotExists(count)
    assertExists(items[copy1])
    assertExists(items[copy2])
  }

  func testShelfAppearanceHidesListOnlySearchControls() {
    let settings = openSettingsFromShelf()
    settings.buttons["settings-page-appearance"].click()
    let listOnly = settings.descendants(matching: .any)
      .matching(identifier: "settings-list-search-options").firstMatch
    let shelfDescription = settings.descendants(matching: .any)
      .matching(identifier: "settings-shelf-search-description").firstMatch
    assertNotExists(listOnly)
    assertExists(shelfDescription)

    let layout = settings.descendants(matching: .any)
      .matching(identifier: "settings-history-layout").firstMatch
    let listButton = layout.radioButtons.matching(NSPredicate(format: "label IN %@", ["List", "列表"])).firstMatch
    assertExists(listButton)
    listButton.click()
    assertExists(listOnly)
    assertNotExists(shelfDescription)
  }

  func testShelfAdvancedPauseCommandsUseCurrentBundle() throws {
    let settings = openSettingsFromShelf()
    settings.buttons["settings-page-advanced"].click()
    let pause = settings.descendants(matching: .any).matching(identifier: "settings-pause-commands").firstMatch
    let ignoreNext = settings.descendants(matching: .any)
      .matching(identifier: "advanced-ignore-next-command").firstMatch
    assertExists(pause)
    assertExists(ignoreNext)
    let targetURL = Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "ClipContext.app")
    let targetID = Bundle(url: targetURL)?.bundleIdentifier ?? "com.benzema.ClipContext"
    let pauseCommands = try XCTUnwrap(pause.value as? String)
    let ignoreNextCommands = try XCTUnwrap(ignoreNext.value as? String)
    XCTAssertTrue(pauseCommands.contains("defaults write \(targetID) ignoreEvents -bool true"))
    XCTAssertTrue(pauseCommands.contains("defaults write \(targetID) ignoreEvents -bool false"))
    XCTAssertTrue(ignoreNextCommands.contains("defaults write \(targetID) ignoreOnlyNextEvent -bool true"))
    XCTAssertTrue(ignoreNextCommands.contains("defaults write \(targetID) ignoreEvents -bool true"))
    XCTAssertFalse(pauseCommands.contains("org.p0deje.Maccy"))
    XCTAssertFalse(ignoreNextCommands.contains("org.p0deje.Maccy"))
  }

  func testShelfPasteWithoutPermissionShowsGuidance() {
    // Run this negative-path test before granting Accessibility to the app under
    // test. The runner's event permission is separate and may already be granted.
    popUpWithMouse()
    assertExists(items[copy1])
    typeInPopup(.return, modifiers: [.option])
    let later = app.buttons["accessibility-later"].firstMatch
    let openSettings = app.buttons["accessibility-open-settings"].firstMatch
    assertExists(later)
    assertExists(openSettings)
    assertExists(app.staticTexts["Accessibility permission needed"].firstMatch)
    later.click()
    assertNotExists(later)
    // A denied direct paste still leaves a valid copy for the user's manual Cmd-V.
    assertPasteboardStringEquals(copy1)
  }

  private func openSettingsFromShelf() -> XCUIElement {
    popUpWithMouse()
    shelfElement("shelf-more").click()
    let command = shelfElement("shelf-open-settings")
    let fallback = app.menuItems.matching(NSPredicate(format: "label IN %@", ["设置…", "Settings…"])).firstMatch
    let target = command.exists ? command : fallback
    assertExists(target)
    target.click()
    let settings = app.windows.containing(.any, identifier: "settings-page-general").firstMatch
    assertExists(settings)
    return settings
  }

  private func shelfElement(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func popUpWithHotkey() {
    simulatePopupHotkey()
    waitUntilPoppedUp()
  }

  // KeyboardShortcuts persists JSON strings in UserDefaults.standard. Passing them
  // as launch arguments places them in the isolated, higher-priority NSArgumentDomain.
  private func setKeyboardShortcut(_ name: String, keyCode: Int, modifiers: Int) {
    app.launchArguments.append(contentsOf: [
      "-KeyboardShortcuts_\(name)",
      #""{\"carbonKeyCode\":\#(keyCode),\"carbonModifiers\":\#(modifiers)}""#
    ])
  }

  // Click outside the popup to close it
  private func closePopupByClickingOutside() {
    let popup = app.dialogs.firstMatch
    guard popup.exists else {
      return
    }

    let popupFrame = popup.frame
    let screenWidth = NSScreen.screens.first?.frame.width ?? popupFrame.maxX + 100
    let margin: CGFloat = 50
    let targetX = popupFrame.maxX + margin < screenWidth
      ? popupFrame.maxX + margin
      : popupFrame.minX - margin
    popup.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: targetX - popupFrame.minX, dy: popupFrame.height / 2))
      .click()
  }

  private func popUpWithMouse() {
    clickStatusItem()
    waitUntilPoppedUp()
  }

  private func clickInNonactivatingPopup(_ element: XCUIElement) {
    assertExists(element)
    XCTAssertTrue(element.isHittable, "The popup control must be physically clickable")
    guard CGPreflightPostEventAccess() else {
      XCTFail("The signed UI test runner must have Accessibility permission for a native popup click.")
      return
    }
    let frame = element.frame
    guard !frame.isEmpty, !frame.isInfinite, !frame.isNull else {
      XCTFail("The popup control has no valid on-screen frame")
      return
    }
    // Resolve the current visible frame, then post exactly one real click without
    // XCTest's application activation step or an accessibility-action fallback.
    let point = CGPoint(x: frame.midX, y: frame.midY)
    let eventTypes: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp]
    let events = eventTypes.compactMap {
      CGEvent(mouseEventSource: nil, mouseType: $0, mouseCursorPosition: point, mouseButton: .left)
    }
    guard events.count == eventTypes.count else {
      XCTFail("Could not create the native popup mouse events")
      return
    }
    for event in events {
      event.flags = []
      event.post(tap: .cghidEventTap)
    }
  }

  private func clickStatusItem(modifiers: XCUIElement.KeyModifierFlags = []) {
    let statusItem = app.statusItems.firstMatch
    XCTAssertTrue(statusItem.waitForExistence(timeout: 3), "The app must expose its menu bar icon")
    XCTAssertTrue(statusItem.isHittable, "The menu bar icon must be physically clickable")
    guard CGPreflightPostEventAccess() else {
      XCTFail("The signed UI test runner must have Accessibility permission for a menu bar click.")
      return
    }
    let frame = statusItem.frame
    guard !frame.isEmpty, !frame.isInfinite, !frame.isNull else {
      XCTFail("The menu bar icon has no valid on-screen frame")
      return
    }
    // XCUIElement.click can reactivate the previous foreground app after opening
    // an accessory app's nonactivating panel. Post one actual mouse click instead.
    // Keep physical modifier down/up events so Option-Shift tests retain their
    // real menu-bar semantics; AXPress is deliberately not a fallback here.
    let keys: [(XCUIElement.KeyModifierFlags, Int, CGEventFlags)] = [
      (.command, kVK_Command, .maskCommand), (.shift, kVK_Shift, .maskShift),
      (.option, kVK_Option, .maskAlternate), (.control, kVK_Control, .maskControl)
    ]
    var flags: CGEventFlags = []
    for (modifier, code, flag) in keys where modifiers.contains(modifier) {
      flags.insert(flag)
      postKeyEvent(code, down: true, flags: flags)
    }
    defer {
      for (modifier, code, flag) in keys.reversed() where modifiers.contains(modifier) {
        flags.remove(flag)
        postKeyEvent(code, down: false, flags: flags)
      }
    }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    let eventTypes: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp]
    for type in eventTypes {
      let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
      event?.flags = flags
      event?.post(tap: .cghidEventTap)
    }
  }

  private func pressStatusItemViaAccessibility() {
    let appURL = Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "ClipContext.app")
    let bundleID = Bundle(url: appURL)?.bundleIdentifier ?? "com.benzema.ClipContext"
    let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }?
      .processIdentifier
    guard let pid else {
      XCTFail("Maccy is not running")
      return
    }

    let appElement = AXUIElementCreateApplication(pid)
    let deadline = Date.now.addingTimeInterval(3)
    var statusItem = axStatusItem(of: appElement)
    while statusItem == nil && Date.now < deadline {
      Thread.sleep(forTimeInterval: 0.1)
      statusItem = axStatusItem(of: appElement)
    }
    guard let statusItem else {
      XCTFail("Maccy has no status item exposed via accessibility")
      return
    }

    let result = AXUIElementPerformAction(statusItem, kAXPressAction as CFString)
    XCTAssertEqual(result, .success, "Failed to press status item via accessibility")
  }

  private func axStatusItem(of appElement: AXUIElement) -> AXUIElement? {
    guard let extrasMenuBar = axElement(appElement, attribute: kAXExtrasMenuBarAttribute) else {
      return nil
    }

    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(extrasMenuBar, kAXChildrenAttribute as CFString, &children) == .success else {
      return nil
    }
    return (children as? [AXUIElement])?.first
  }

  private func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return nil
    }
    return (value as! AXUIElement) // swiftlint:disable:this force_cast
  }

  private func requestRawKeyboardAccessIfConfigured() async throws {
    guard !CGPreflightPostEventAccess(),
          ProcessInfo.processInfo.environment["CLIPCONTEXT_TEST_REQUEST_KEY_EVENT_ACCESS"] == "1" else { return }
    print("Requesting macOS authorization to post keyboard events.")
    // Register the runner in the Accessibility list before requesting event
    // posting. CGRequestPostEventAccess alone may not show a prompt or add it.
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    if CGRequestPostEventAccess() { return }

    let deadline = ContinuousClock.now + .seconds(90)
    while !CGPreflightPostEventAccess() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(250))
    }
  }

  private func requireRawKeyboardAccess() throws {
    try requireTestPrecondition(
      CGPreflightPostEventAccess(),
      "macOS has not authorized this signed UI test runner to post keyboard events. "
        + "Enable it in System Settings > Privacy & Security > Accessibility."
    )
  }

  private func requireTestPrecondition(_ condition: Bool, _ message: String) throws {
    guard !condition else { return }
    if ProcessInfo.processInfo.environment["CLIPCONTEXT_TEST_REQUIRE_ALL_PERMISSIONS"] == "1" {
      XCTFail(message)
      throw TestPreconditionError.unavailable
    }
    throw XCTSkip(message)
  }

  private enum TestPreconditionError: Error { case unavailable }

  private func releaseRawKeyboardState() {
    guard CGPreflightPostEventAccess() else { return }
    for code in [kVK_ANSI_C, kVK_Shift, kVK_Command, kVK_Option, kVK_Control] {
      let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false)
      up?.flags = []
      up?.post(tap: .cghidEventTap)
    }
  }

  private func typeInPopup(_ key: XCUIKeyboardKey, modifiers: XCUIElement.KeyModifierFlags = []) {
    let keyCode: Int
    switch key {
    case .return: keyCode = kVK_Return
    case .enter: keyCode = kVK_ANSI_KeypadEnter
    case .escape: keyCode = kVK_Escape
    case .delete: keyCode = kVK_Delete
    case .upArrow: keyCode = kVK_UpArrow
    case .downArrow: keyCode = kVK_DownArrow
    case .leftArrow: keyCode = kVK_LeftArrow
    case .rightArrow: keyCode = kVK_RightArrow
    default:
      XCTFail("Unsupported physical key in popup test")
      return
    }
    assertExists(app.dialogs.firstMatch)
    postPhysicalKey(keyCode, modifiers: modifiers)
  }

  private func typeInPopup(_ key: String, modifiers: XCUIElement.KeyModifierFlags = []) {
    let codes = ["1": kVK_ANSI_1, "2": kVK_ANSI_2, "j": kVK_ANSI_J,
                 "k": kVK_ANSI_K, "p": kVK_ANSI_P, "v": kVK_ANSI_V, "w": kVK_ANSI_W]
    guard let code = codes[key] else {
      XCTFail("Unsupported physical key in popup test")
      return
    }
    assertExists(app.dialogs.firstMatch)
    postPhysicalKey(code, modifiers: modifiers)
  }

  private func postPhysicalKey(_ keyCode: Int, modifiers: XCUIElement.KeyModifierFlags = []) {
    guard CGPreflightPostEventAccess() else {
      XCTFail("The signed UI test runner must have Accessibility permission to send native keyboard events.")
      return
    }
    // XCTest's typeKey can activate an unrelated window while resolving a
    // nonactivating panel. Use the already-authorized hardware event path.
    let keys: [(XCUIElement.KeyModifierFlags, Int, CGEventFlags)] = [
      (.command, kVK_Command, .maskCommand), (.shift, kVK_Shift, .maskShift),
      (.option, kVK_Option, .maskAlternate), (.control, kVK_Control, .maskControl)
    ]
    var flags: CGEventFlags = []
    for (modifier, code, flag) in keys where modifiers.contains(modifier) {
      flags.insert(flag)
      postKeyEvent(code, down: true, flags: flags)
    }
    postKeyEvent(keyCode, down: true, flags: flags)
    postKeyEvent(keyCode, down: false, flags: flags)
    for (modifier, code, flag) in keys.reversed() where modifiers.contains(modifier) {
      flags.remove(flag)
      postKeyEvent(code, down: false, flags: flags)
    }
  }

  private func postKeyEvent(_ code: Int, down: Bool, flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
  }

  private func typeSearchText(_ text: String) {
    guard CGPreflightPostEventAccess() else {
      XCTFail("The signed UI test runner must have Accessibility permission to type into search.")
      return
    }
    let characters = Array(text.utf16)
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
      event?.flags = []
      event?.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
      event?.post(tap: .cghidEventTap)
    }
  }

  private func simulatePopupHotkey() {
    guard CGPreflightPostEventAccess() else {
      app.typeKey("c", modifierFlags: [.command, .shift])
      return
    }
    let commandDown = CGEvent(
      keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: true)!
    let commandUp = CGEvent(
      keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: false)!
    let shiftDown = CGEvent(
      keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: true)!
    let shiftUp = CGEvent(
      keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: false)!
    shiftDown.flags = [.maskCommand]
    shiftUp.flags = [.maskCommand]
    let cDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)!
    let cUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)!
    cDown.flags = [.maskCommand, .maskShift]
    cUp.flags = [.maskCommand, .maskShift]
    commandDown.post(tap: .cghidEventTap)
    shiftDown.post(tap: .cghidEventTap)
    cDown.post(tap: .cghidEventTap)
    cUp.post(tap: .cghidEventTap)
    shiftUp.post(tap: .cghidEventTap)
    commandUp.post(tap: .cghidEventTap)
  }

  private func waitUntilPoppedUp() {
    if !app.dialogs.firstMatch.waitForExistence(timeout: 3) {
      XCTFail("Maccy did not pop up")
    }
  }

  private func assertPopupDismissed() {
    if !app.dialogs.firstMatch.waitForNonExistence(timeout: 3) {
      XCTFail("Maccy did not dismiss")
    }
  }

  private func copyToClipboard(_ content: String) {
    pasteboard.clearContents()
    pasteboard.setString(content, forType: .string)
    waitTillClipboardCheck()
  }

  private func copyToClipboard(_ content: NSImage) {
    pasteboard.clearContents()
    pasteboard.setData(content.tiffRepresentation, forType: .tiff)
    waitTillClipboardCheck()
  }

  private func textImage(_ text: String) -> NSImage {
    let string = NSAttributedString(string: text, attributes: [
      .font: NSFont.boldSystemFont(ofSize: 48),
      .foregroundColor: NSColor.black
    ])
    let size = NSSize(width: string.size().width + 40, height: string.size().height + 40)
    return NSImage(size: size, flipped: false) { rect in
      NSColor.white.setFill()
      rect.fill()
      string.draw(at: NSPoint(x: 20, y: 20))
      return true
    }
  }

  private func assertImageFound(bySearching text: String) {
    let imageItem = items.query.matching(NSPredicate(format: "label BEGINSWITH %@", "Image, ")).firstMatch
    for _ in 0..<5 {
      search(text)
      if imageItem.waitForExistence(timeout: 2) {
        break
      }
      typeInPopup("w", modifiers: [.control])
      sleep(2)
    }
    XCTAssertTrue(imageItem.exists, "No image found by searching \"\(text)\"")
    XCTAssertEqual(items.allElementsBoundByIndex.count, 1)
  }

  private func copyToClipboard(_ content: URL) {
    pasteboard.clearContents()
    pasteboard.setData(content.dataRepresentation, forType: .fileURL)
    // WTF: The subsequent writes to pasteboard are not
    // visible unless we explicitly read the last one?!
    pasteboard.string(forType: .fileURL)
    waitTillClipboardCheck()
  }

  private func copyToClipboard(_ content: Data?, _ type: NSPasteboard.PasteboardType) {
    pasteboard.clearContents()
    pasteboard.setData(content, forType: type)
    waitTillClipboardCheck()
  }

  // Default interval for Maccy to check clipboard is 1 second
  private func waitTillClipboardCheck() {
    usleep(1_500_000)
  }

  private func pin(_ title: String) {
    hover(items[title].firstMatch)
    typeInPopup("p", modifiers: [.option])
    usleep(1_500_000)
  }

  private func drag(_ element: XCUIElement, before target: XCUIElement) {
    hover(element)
    let source = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let destination = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
    source.click(forDuration: 0.5, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.5)
    usleep(500_000)
  }

  private func hoverAndClick(_ element: XCUIElement) {
    assertExists(element)
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    usleep(200_000)
    // Hover can open the preview and resize the panel. Resolve the element's
    // current frame for the click rather than reusing the pre-hover coordinate.
    element.click()
  }

  private func scrollIntoViewIfNeeded(_ element: XCUIElement) {
    assertExists(element)
    if element.isHittable { return }

    let container = app.scrollViews["history-scroll-view"].firstMatch
    guard container.exists else {
      return
    }

    var attempts = 0
    while !container.frame.contains(element.frame) && attempts < 15 {
      // Negative deltaY scrolls down (reveals elements below the viewport).
      let delta: CGFloat = element.frame.midY > container.frame.midY ? -10 : 10
      container.scroll(byDeltaX: 0, deltaY: delta)
      usleep(100_000)
      attempts += 1
    }
  }

  private func hover(_ element: XCUIElement) {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).hover()
    usleep(50_000)
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    usleep(200_000)
  }

  private func search(_ string: String) {
    // NOTE: app.typeText is broken in Sonoma and causes some
    //       Chars to be submitted with a .command mask (e.g. 'p', 'k' or 'j')
    let field = app.textFields.firstMatch
    assertExists(field)
    field.click()
    typeSearchText(string)
    waitForSearch()
  }

  private func waitForSearch() {
    // NOTE: This is a hack and is flaky.
    // Ideally we should wait for a proper condition to detect that search has settled down.
    usleep(500000)  // wait for search throttle
  }

  private func assertExists(_ element: XCUIElement) {
    expectation(for: NSPredicate(format: "exists = 1"), evaluatedWith: element)
    waitForExpectations(timeout: 3)
  }

  private func assertNotExists(_ element: XCUIElement) {
    expectation(for: NSPredicate(format: "exists = 0"), evaluatedWith: element)
    waitForExpectations(timeout: 3)
  }

  private func assertNotVisible(_ element: XCUIElement) {
    expectation(
      for: NSPredicate(format: "(exists = 0) || (isHittable = 0)"), evaluatedWith: element)
    waitForExpectations(timeout: 3)
  }

  private func assertPasteboardDataEquals(
    _ expected: Data?, forType: NSPasteboard.PasteboardType = .string
  ) {
    let predicate = NSPredicate { (object, _) -> Bool in
      guard let copy = object as? Data else {
        return false
      }

      return self.pasteboard.data(forType: forType) == copy
    }
    expectation(for: predicate, evaluatedWith: expected)
    waitForExpectations(timeout: 3)
  }

  private func assertPasteboardDataCountEquals(
    _ expected: Int, forType: NSPasteboard.PasteboardType = .string
  ) {
    let predicate = NSPredicate { (object, _) -> Bool in
      guard let count = object as? Int else {
        return false
      }

      return self.pasteboard.data(forType: forType)!.count == count
    }
    expectation(for: predicate, evaluatedWith: expected)
    waitForExpectations(timeout: 3)
  }

  private func assertPasteboardStringEquals(_ expected: String?, forType: NSPasteboard.PasteboardType = .string) {
      let predicate = NSPredicate { (object, _) -> Bool in
        guard let copy = object as? String else {
          return false
        }
        return self.pasteboard.string(forType: forType) == copy
      }
      expectation(for: predicate, evaluatedWith: expected)
      waitForExpectations(timeout: 3)
    }

  private func assertSearchFieldValue(_ string: String) {
    let field = app.textFields.firstMatch
    expectation(for: NSPredicate { _, _ in
      field.exists && field.value as? String == string
    }, evaluatedWith: nil)
    waitForExpectations(timeout: 3)
  }

  private func clickClearAllWhileHoldingShift() {
    guard CGPreflightPostEventAccess() else {
      XCTFail("The signed UI test runner must have Accessibility permission for a held-modifier click.")
      return
    }
    // The footer observes actual flagsChanged events; XCTest's modifier wrapper
    // can set synthetic click flags without delivering the preceding key event.
    postKeyEvent(kVK_Shift, down: true, flags: .maskShift)
    defer { postKeyEvent(kVK_Shift, down: false, flags: []) }
    let button = app.buttons["Clear all"].firstMatch
    assertExists(button)
    XCTAssertTrue(button.isHittable, "Clear all must be physically clickable while Shift is held")
    let frame = button.frame
    guard !frame.isEmpty, !frame.isInfinite, !frame.isNull else {
      XCTFail("Clear all has no valid on-screen frame")
      return
    }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    let eventTypes: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp]
    for type in eventTypes {
      let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
      event?.flags = .maskShift
      event?.post(tap: .cghidEventTap)
    }
  }

  private func confirmClear() {
    let button = app.buttons["confirmation-confirm"].firstMatch
    expectation(for: NSPredicate(format: "isHittable = 1"), evaluatedWith: button)
    waitForExpectations(timeout: 3)
    button.click()
  }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length
