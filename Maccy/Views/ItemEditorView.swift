import AppKit
import Combine
import Defaults
import SwiftUI

struct ItemEditorView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Default(.historyPresentation) private var historyPresentation

  let item: HistoryItemDecorator

  @State private var editableTitle: String
  @State private var editableContent: LargeTextView.EditorState
  @State private var selectedPin: String?
  @State private var availablePins: [String] = []
  @State private var isTextContent: Bool
  @State private var isRichText: Bool
  @State private var isContentTooLarge: Bool
  @State private var statistics: TextStatistics?
  @State private var showsMetadata = false

  private var usesShelfLayout: Bool { historyPresentation == .shelf }

  private var hasWarning: Bool {
    isContentTooLarge || (isRichText && editableContent.hasChanges)
  }

  private enum Field: Hashable {
    case title
    case pin
  }

  @FocusState private var focusedField: Field?

  init(for item: HistoryItemDecorator) {
    self.item = item
    self._editableTitle = State(initialValue: item.item.title)
    self._editableContent = State(initialValue: LargeTextView.EditorState(text: item.previewText.string))
    self._selectedPin = State(initialValue: item.item.pin)

    self._isContentTooLarge = State(initialValue: item.previewText.isTruncated)

    // Content can only be edited safely as plain text.
    self._isTextContent = State(
      initialValue: item.hasPlainText && !item.hasImage && !item.hasFileURLs
    )
    self._isRichText = State(
      initialValue: item.hasRichText && !item.hasImage && !item.hasFileURLs
    )
  }

  var body: some View {
    Group {
      if usesShelfLayout {
        shelfEditor
      } else {
        listEditor
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("EditItem", tableName: "PreviewItemView"))
    .onAppear {
      availablePins = appState.history.availablePins
      if !usesShelfLayout {
        focusedField = item.hasImage ? .pin : .title
      }
    }
    .onExitCommand { dismiss() }
  }

  private var shelfEditor: some View {
    VStack(alignment: .leading, spacing: 7) {
      shelfHeader

      if hasWarning {
        editorWarning
          .font(.caption)
          .padding(.horizontal, 6)
      }

      contentEditor

      if (isTextContent || isRichText), !isContentTooLarge {
        contentStatistics
          .padding(.horizontal, 7)
      }
    }
    .padding(.horizontal, 6)
    .padding(.top, 5)
    .padding(.bottom, 10)
    .frame(width: 390, height: 316)
    .background(Color(nsColor: .textBackgroundColor))
  }

  private var listEditor: some View {
    VStack(alignment: .leading, spacing: 16) {
      metadataFields

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Text("Content", tableName: "PinsSettings")
            .font(.headline)

          if hasWarning {
            editorWarning
          }
        }

        contentEditor
      }

      HStack {
        Spacer()
        cancelButton
        saveButton(Self.doneButtonTitle)
      }
    }
    .padding(16)
    .frame(minWidth: 540, minHeight: 360)
  }

  private var shelfHeader: some View {
    ZStack {
      if !item.hasImage || item.isPinned {
        Button {
          showsMetadata.toggle()
        } label: {
          Image(systemName: "slider.horizontal.3")
            .font(.system(size: 14, weight: .medium))
            .frame(width: 32, height: 26)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Alias", tableName: "PinsSettings"))
        .help(Text("Alias", tableName: "PinsSettings"))
        .popover(isPresented: $showsMetadata, arrowEdge: .bottom) {
          metadataFields
            .padding(14)
            .frame(width: 320)
            .onAppear {
              focusedField = item.hasImage ? .pin : .title
            }
        }
      }

      HStack {
        cancelButton
          .buttonStyle(ShelfEditorButtonStyle(isProminent: false))

        Spacer()

        saveButton(Self.appKitString("Save"))
          .buttonStyle(ShelfEditorButtonStyle(isProminent: true))
          .accessibilityLabel(Self.doneButtonTitle)
      }
      .padding(.horizontal, 3)
    }
    .frame(height: 26)
  }

  private var metadataFields: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("Alias", tableName: "PinsSettings")
          .frame(width: 80, alignment: .leading)

        TextField("", text: $editableTitle)
          .accessibilityLabel(Text("Alias", tableName: "PinsSettings"))
          .disabled(item.hasImage)
          .focused($focusedField, equals: .title)
          .onSubmit(saveChanges)
      }

      if item.isPinned {
        HStack(alignment: .firstTextBaseline) {
          Text("Key", tableName: "PinsSettings")
            .frame(width: 80, alignment: .leading)

          Picker("", selection: $selectedPin) {
            ForEach(uniquePins, id: \.self) { pin in
              Text(pin).tag(pin as String?)
            }
          }
          .labelsHidden()
          .accessibilityLabel(Text("Key", tableName: "PinsSettings"))
          .focused($focusedField, equals: .pin)
          .frame(maxWidth: 220, alignment: .leading)
        }
      }
    }
  }

  private var editorWarning: some View {
    Label {
      if isContentTooLarge {
        Text(NSLocalizedString(
          "ParagraphsTooLongToEdit",
          tableName: "PinsSettings",
          value: "Text contains paragraphs that are too long to edit.",
          comment: ""
        ))
      } else {
        Text("RichTextEditWarning", tableName: "PinsSettings")
      }
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
  }

  private var cancelButton: some View {
    Button(Self.cancelButtonTitle, role: .cancel) {
      dismiss()
    }
    .keyboardShortcut(.cancelAction)
  }

  private func saveButton(_ title: String) -> some View {
    Button(title, action: saveChanges)
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(!hasChangesToApply)
  }

  private static var cancelButtonTitle: String {
    appKitString("Cancel")
  }

  private static var doneButtonTitle: String {
    appKitString("Done")
  }

  private static func appKitString(_ key: String) -> String {
    guard let bundle = Bundle(identifier: "com.apple.AppKit") else {
      return key
    }

    return NSLocalizedString(key, bundle: bundle, value: key, comment: "")
  }

  @ViewBuilder
  private var contentEditor: some View {
    let border = RoundedRectangle(cornerRadius: usesShelfLayout ? 5 : 6, style: .continuous)
    Group {
      if isTextContent || isRichText {
        LargeTextView(
          editorState: editableContent,
          isEditable: !isContentTooLarge,
          accessibilityLabel: NSLocalizedString("Content", tableName: "PinsSettings", comment: ""),
          onCancel: { dismiss() }
        )
          .disabled(isContentTooLarge)
          .padding(.horizontal, usesShelfLayout ? 12 : 8)
          .padding(.vertical, usesShelfLayout ? 8 : 6)
      } else {
        Text("ContentIsNotText", tableName: "PinsSettings")
          .foregroundStyle(.secondary)
          .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
          )
          .padding(12)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: usesShelfLayout ? .infinity : nil)
    .background {
      border.fill(Color(nsColor: .textBackgroundColor))
    }
    .overlay {
      border.stroke(Color(nsColor: .separatorColor).opacity(usesShelfLayout ? 0.65 : 1), lineWidth: 1)
        .allowsHitTesting(false)
    }
    .clipShape(border)
  }

  private var contentStatistics: some View {
    HStack(spacing: 6) {
      if let statistics {
        Text(statistics.characters == 1 ? "1 character" : "\(statistics.characters) characters")
        Text("·").accessibilityHidden(true)
        Text(statistics.words == 1 ? "1 word" : "\(statistics.words) words")
        Text("·").accessibilityHidden(true)
        Text(statistics.lines == 1 ? "1 line" : "\(statistics.lines) lines")
      }
    }
    .font(.system(size: 13))
    .foregroundStyle(.secondary)
    .monospacedDigit()
    .frame(minHeight: 16)
    .accessibilityElement(children: .combine)
    .onAppear(perform: refreshStatistics)
    .onReceive(
      NotificationCenter.default.publisher(for: NSText.didChangeNotification)
        .debounce(for: .milliseconds(180), scheduler: RunLoop.main)
    ) { _ in
      refreshStatistics()
    }
  }

  private func refreshStatistics() {
    statistics = TextStatistics(editableContent.text)
  }

  private struct TextStatistics {
    let characters: Int
    let words: Int
    let lines: Int

    init(_ text: String) {
      characters = text.count
      lines = text.isEmpty ? 0 : 1 + text.lazy.filter(\.isNewline).count

      var wordCount = 0
      text.enumerateSubstrings(
        in: text.startIndex..<text.endIndex,
        options: [.byWords, .localized, .substringNotRequired]
      ) { _, _, _, _ in
        wordCount += 1
      }
      words = wordCount
    }
  }

  private var uniquePins: [String] {
    HistoryItem.sortedPins(Set(availablePins + [item.item.pin, selectedPin].compactMap { $0 }))
  }

  private var hasChangesToApply: Bool {
    let titleChanged = !item.hasImage && editableTitle != item.item.title
    let pinChanged = selectedPin != nil && selectedPin != item.item.pin
    let contentChanged = (isTextContent || isRichText) && editableContent.hasChanges
    return titleChanged || pinChanged || contentChanged
  }

  private func applyChanges() {
    if !item.hasImage && editableTitle != item.item.title {
      item.item.title = editableTitle
      item.title = editableTitle
    }

    if let selectedPin {
      appState.history.updatePin(item.item, to: selectedPin)
    }

    guard isTextContent || isRichText else { return }
    guard editableContent.hasChanges,
          let data = editableContent.text.data(using: .utf8) else { return }

    let historyItem = item.item
    let stringType = NSPasteboard.PasteboardType.string.rawValue
    historyItem.contents.removeAll { $0.type != stringType }

    if let index = historyItem.contents.firstIndex(where: {
      $0.type == stringType
    }) {
      historyItem.contents[index].value = data
    } else {
      historyItem.contents.append(
        HistoryItemContent(type: stringType, value: data)
      )
    }
  }

  private func saveChanges() {
    guard hasChangesToApply else { return }
    applyChanges()
    dismiss()
  }
}

private struct ShelfEditorButtonStyle: ButtonStyle {
  let isProminent: Bool

  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(isProminent ? .white.opacity(isEnabled ? 1 : 0.7) : .primary)
      .padding(.horizontal, 10)
      .frame(height: 22)
      .background(
        isProminent
          ? Color.accentColor.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.36)
          : Color.primary.opacity(configuration.isPressed ? 0.06 : 0),
        in: Capsule()
      )
      .overlay {
        if !isProminent {
          Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
      }
      .contentShape(Capsule())
  }
}
