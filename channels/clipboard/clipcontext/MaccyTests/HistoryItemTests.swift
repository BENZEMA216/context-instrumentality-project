import AppKit
import Testing
import Defaults
@testable import Maccy

private final class BundleToken {}

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

private let stringTitleCases: [(input: String, title: String)] = [
  ("foo", "foo"),
  ("   foo bar   ", "···foo bar···"),
  ("\nfoo\nbar\n", "⏎foo⏎bar⏎"),
  ("\tfoo\tbar\t", "⇥foo⇥bar⇥")
]

private let objectReplacementTitleCases: [(input: String, title: String)] = [
  ("\u{FFFC}foo\u{FFFC}bar\u{FFFC}", "foobar"),
  ("\u{FFFC}\u{FFFC}", "")
]

extension SharedStateTests {
  @MainActor
  struct HistoryItemTests {
    @Test("Sorted pins place letters before symbols")
    func sortedPinsPlacesLettersBeforeSymbols() {
      #expect(
        HistoryItem.sortedPins(["/", "c", "[", "b", "-", "\\", "y"]) ==
        ["b", "c", "y", "-", "/", "[", "\\"]
      )
    }

    @Test("Title for string", arguments: stringTitleCases)
    func titleForString(input: String, title: String) {
      #expect(historyItem(input).title == title)
    }

    // U+FFFC arrives from rich text with inline attachments and hangs CoreText
    // on macOS 26. See https://github.com/p0deje/Maccy/issues/1520.
    @Test("Title without object replacement characters", arguments: objectReplacementTitleCases)
    func titleWithObjectReplacementCharacters(input: String, title: String) {
      #expect(historyItem(input).title == title)
    }

    @Test("Title for RTF")
    func titleWithRTF() {
      let rtf = NSAttributedString(string: "foo").rtf(
        from: NSRange(0...2),
        documentAttributes: [:]
      )
      #expect(historyItem(rtf, .rtf).title == "foo")
    }

    @Test("Title for HTML")
    func titleWithHTML() {
      let html = "<a href='#'>foo</a>".data(using: .utf8)
      #expect(historyItem(html, .html).title == "foo")
    }

    @Test("Image has an empty title")
    func image() throws {
      let image = try #require(NSImage(named: "NSBluetoothTemplate"))
      #expect(historyItem(image).title == "")
    }

    @Test("Image title becomes the recognized text")
    func imageTitleBecomesRecognizedText() async throws {
      let item = historyItem(textImage("Hello Maccy"))
      let deadline = ContinuousClock.now + .seconds(10)
      while item.title.isEmpty && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(100))
      }
      #expect(item.title == "Hello Maccy")
    }

    @Test("Title for file", arguments: ["/tmp/foo.bar", "/tmp/产品培训/产品培训.txt"])
    func file(path: String) {
      let url = URL(fileURLWithPath: path)
      #expect(historyItem(url).title == "file://\(path)")
    }

    @Test("Text from Universal Clipboard")
    func textFromUniversalClipboard() {
      let url = URL(fileURLWithPath: "/tmp/foo.bar")
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let textContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: url.lastPathComponent.data(using: .utf8)
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, textContent, universalClipboardContent]
      item.title = item.generateTitle()
      #expect(item.title == "foo.bar")
    }

    @Test("Image from Universal Clipboard")
    func imageFromUniversalClipboard() throws {
      let url = try #require(Bundle(for: BundleToken.self).url(forResource: "guy", withExtension: "jpeg"))
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, universalClipboardContent]
      let image = try #require(item.image)
      let expected = try #require(NSImage(data: try Data(contentsOf: url)))
      #expect(image.tiffRepresentation == expected.tiffRepresentation)
    }

    @Test("File from Universal Clipboard")
    func fileFromUniversalClipboard() {
      let url = URL(fileURLWithPath: "/tmp/foo.bar")
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, universalClipboardContent]
      item.title = item.generateTitle()
      #expect(item.title == "file:///tmp/foo.bar")
    }

    @Test("Item without data has an empty title")
    func itemWithoutData() {
      #expect(historyItem(nil).title == "")
    }

    @Test("RTF replay ignores synthesized matching UTF-16 text")
    func rtfReplayWithSynthesizedText() throws {
      let text = "Clipboard 中文 📝"
      let styled = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
      let rtf = try #require(styled.rtf(from: NSRange(location: 0, length: styled.length), documentAttributes: [:]))
      let original = HistoryItem(contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: text.data(using: .utf8)),
        HistoryItemContent(type: NSPasteboard.PasteboardType.rtf.rawValue, value: rtf),
        HistoryItemContent(type: "public.utf16-external-plain-text", value: nil)
      ])
      let replay = HistoryItem(contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: text.data(using: .utf8)),
        HistoryItemContent(type: NSPasteboard.PasteboardType.rtf.rawValue, value: rtf),
        HistoryItemContent(type: "public.utf16-external-plain-text", value: text.data(using: .utf16)),
        HistoryItemContent(type: NSPasteboard.PasteboardType.fromMaccy.rawValue, value: Data())
      ])

      #expect(original.supersedes(replay))
      #expect(replay.supersedes(original))
    }

    @Test("Different rich text formatting is not deduplicated")
    func differentRichTextFormatting() throws {
      let text = "Same words"
      func item(font: NSFont) throws -> HistoryItem {
        let styled = NSAttributedString(string: text, attributes: [.font: font])
        let rtf = try #require(styled.rtf(from: NSRange(location: 0, length: styled.length), documentAttributes: [:]))
        return HistoryItem(contents: [
          HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: text.data(using: .utf8)),
          HistoryItemContent(type: NSPasteboard.PasteboardType.rtf.rawValue, value: rtf),
          HistoryItemContent(type: "public.utf16-external-plain-text", value: text.data(using: .utf16))
        ])
      }
      let regular = try item(font: .systemFont(ofSize: 14))
      let bold = try item(font: .boldSystemFont(ofSize: 14))
      #expect(!regular.supersedes(bold))
      #expect(!bold.supersedes(regular))
    }

    @Test("Different alternate text and private payloads are not discarded")
    func distinctAlternateRepresentations() {
      let original = historyItem("same")
      let changedText = historyItem("different")
      let conflictingUTF16 = historyItem("same")
      conflictingUTF16.contents.append(HistoryItemContent(
        type: "public.utf16-external-plain-text", value: "different".data(using: .utf16)
      ))
      let privateData = historyItem("same")
      privateData.contents.append(HistoryItemContent(type: "com.example.rich-data", value: Data([1, 2, 3])))
      #expect(!original.supersedes(changedText))
      #expect(!original.supersedes(conflictingUTF16))
      #expect(!original.supersedes(privateData))
      let unavailable = HistoryItem(contents: [HistoryItemContent(type: "empty")])
      #expect(!original.supersedes(unavailable))
    }

    @Test("Several items can have an empty pin")
    func severalItemsCanHaveEmptyPin() {
      let item1 = historyItem("foo")
      item1.pin = ""
      let item2 = historyItem("bar")
      item2.pin = ""
      #expect(throws: Never.self) {
        try Storage.shared.context.save()
      }
      #expect(item1.pin == "")
      #expect(item2.pin == "")
    }

    private func historyItem(_ value: String?) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value?.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()

      return item
    }

    private func historyItem(_ data: Data?, _ type: NSPasteboard.PasteboardType) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: type.rawValue,
          value: data
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()

      return item
    }

    private func historyItem(_ value: NSImage) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.tiff.rawValue,
          value: value.tiffRepresentation
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()

      return item
    }

    private func historyItem(_ value: URL) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.fileURL.rawValue,
          value: value.dataRepresentation
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.lastPathComponent.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()

      return item
    }
  }
}
