import AppKit
import Defaults
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ShelfItemKind: String, CaseIterable, Identifiable {
  case text
  case link
  case image
  case file

  private static let imageTypes = Set(StorageType.images.types.map(\.rawValue))

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .text: "shelf_kind_text"
    case .link: "shelf_kind_link"
    case .image: "shelf_kind_image"
    case .file: "shelf_kind_file"
    }
  }

  var symbol: String {
    switch self {
    case .text: "text.alignleft"
    case .link: "link"
    case .image: "photo"
    case .file: "doc"
    }
  }

  init(_ item: HistoryItemDecorator) {
    // Classifying the shelf shouldn't decode every stored image.
    if item.item.contents.contains(where: { Self.imageTypes.contains($0.type) && $0.value != nil }) ||
        (item.item.universalClipboard && item.item.fileURLs.first?.pathExtension == "jpeg") {
      self = .image
    } else if item.hasFileURLs {
      self = .file
    } else if Self.webURL(in: item.previewText.string) != nil {
      self = .link
    } else {
      self = .text
    }
  }

  static func webURL(in text: String) -> URL? {
    let sample = text.prefix(2_049)
    guard sample.count <= 2_048 else { return nil }
    let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.contains(where: \.isWhitespace),
      let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      let host = url.host(), !host.isEmpty
    else { return nil }

    return url
  }
}

struct ShelfHistoryCard: View {
  static let width: CGFloat = 232
  static let height: CGFloat = 232

  private static let headerHeight: CGFloat = 48

  let item: HistoryItemDecorator
  let isSelected: Bool
  let isShared: Bool
  var boardColor: Color? = nil

  @Default(.showApplicationIcons) private var showApplicationIcons
  @Default(.showHexColorSwatch) private var showHexColorSwatch
  @Environment(ModifierFlags.self) private var modifierFlags
  @State private var imagePreview: ShelfImagePreview?

  var body: some View {
    let kind = ShelfItemKind(item)
    let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)

    VStack(spacing: 0) {
      header(kind)
      VStack(spacing: 0) {
        preview(kind)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
        footer(kind)
      }
      .background {
        if kind == .image {
          ShelfCheckerboard()
        }
      }
    }
    .frame(width: Self.width, height: Self.height)
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(shape)
    .overlay {
      if isSelected {
        shape
          .inset(by: -3)
          .strokeBorder(Color.accentColor, lineWidth: 3)
          .allowsHitTesting(false)
      } else {
        shape
          .strokeBorder(Color.primary.opacity(0.045), lineWidth: 1)
          .allowsHitTesting(false)
      }
    }
    .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
    .contentShape(shape)
    .task(id: item.id) {
      guard kind == .image, let data = item.item.imageData else {
        imagePreview = nil
        return
      }
      let maxPixelSize = Int(Self.width * 2)
      let worker = Task.detached(priority: .utility) {
        Task.isCancelled ? nil : ShelfImagePreview.make(from: data, maxPixelSize: maxPixelSize)
      }
      let preview = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      if !Task.isCancelled {
        imagePreview = preview
      }
    }
  }

  private func header(_ kind: ShelfItemKind) -> some View {
    HStack(spacing: 5) {
      Group {
        if boardColor != nil {
          if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(kind.title)
          } else {
            Text(verbatim: item.title)
          }
        } else {
          VStack(alignment: .leading, spacing: 0) {
            Text(kind.title)
            TimelineView(.periodic(from: .now, by: 60)) { _ in
              Text(item.item.lastCopiedAt.formatted(.relative(presentation: .named, unitsStyle: .wide)))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
            }
          }
        }
      }
      .font(.system(size: 14, weight: .semibold))
      .lineLimit(1)
      .padding(.leading, 12)

      Spacer(minLength: 0)

      if showApplicationIcons, boardColor == nil {
        sourceIcon(kind)
      }
    }
    .frame(height: Self.headerHeight)
    .foregroundStyle(.white)
    .background(boardColor ?? sourceTint(kind))
  }

  private func sourceIcon(_ kind: ShelfItemKind) -> some View {
    let plate = UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
    return Group {
      if item.applicationImage.bundleIdentifier != nil {
        AppImageView(appImage: item.applicationImage, size: CGSize(width: 59, height: 59))
          .offset(x: 3)
      } else {
        Image(systemName: kind.symbol)
          .font(.system(size: 28, weight: .medium))
      }
    }
    .frame(width: 55, height: Self.headerHeight)
    .background(.white.opacity(0.20), in: plate)
    .overlay {
      plate.strokeBorder(.white.opacity(0.18), lineWidth: 1)
    }
    .clipShape(plate)
    .help(item.application ?? "")
  }

  @ViewBuilder
  private func preview(_ kind: ShelfItemKind) -> some View {
    switch kind {
    case .image:
      if let imagePreview {
        Image(decorative: imagePreview.image, scale: 2)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: "photo")
          .font(.system(size: 26))
          .foregroundStyle(.tertiary)
      }

    case .file:
      filePreview

    case .link:
      ZStack {
        LinearGradient(
          colors: [.clear, Color.primary.opacity(0.05)],
          startPoint: .top,
          endPoint: .bottom
        )
        Image(systemName: "safari")
          .font(.system(size: 34, weight: .regular))
          .foregroundStyle(.tertiary)
      }

    case .text:
      textPreview
    }
  }

  private var textPreview: some View {
    let text = item.previewText.string
    let excerpt = text.prefix(420)
    let snippet = String(excerpt) + (excerpt.endIndex != text.endIndex || item.previewText.isTruncated ? "…" : "")

    return VStack(alignment: .leading, spacing: 7) {
      if showHexColorSwatch, let swatch = ColorImage.from(item.title) {
        Image(nsImage: swatch)
          .resizable()
          .frame(width: 36, height: 36)
          .clipShape(.rect(cornerRadius: 7))
          .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.1)) }
      }

      if let title = item.attributedTitle {
        Text(title)
      } else if snippet.isEmpty {
        Text("Empty text")
          .foregroundStyle(.secondary)
      } else {
        Text(verbatim: snippet)
      }
    }
    .font(.system(size: 13))
    .lineSpacing(1)
    .lineLimit(9)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var filePreview: some View {
    let urls = item.item.fileURLs
    return VStack(spacing: 7) {
      if let url = urls.first {
        if urls.count == 1 {
          let type = url.hasDirectoryPath ? UTType.folder : (UTType(filenameExtension: url.pathExtension) ?? .data)
          Image(nsImage: NSWorkspace.shared.icon(for: type))
            .resizable()
            .scaledToFit()
            .frame(width: 55, height: 55)
        } else {
          Image(systemName: "doc.on.doc")
            .font(.system(size: 32, weight: .light))
            .foregroundStyle(Color.accentColor)
            .frame(width: 55, height: 55)
        }

        Text(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(2)
          .truncationMode(.middle)
          .multilineTextAlignment(.center)
      }
    }
    .padding(.horizontal, 13)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func footer(_ kind: ShelfItemKind) -> some View {
    ZStack {
      if kind == .link, let url = ShelfItemKind.webURL(in: item.previewText.string) {
        linkLabel(url)
      } else {
        footerLabel(kind)
          .lineLimit(1)
          .padding(.horizontal, 48)
      }

      HStack(spacing: 5) {
        Spacer(minLength: 0)

        if kind != .link, let shortcut = visibleShortcut {
          KeyboardShortcutView(shortcut: shortcut)
        }
        if isShared {
          Image(systemName: "tray.and.arrow.up")
            .help("Shared with Agent")
        }
        if let index = item.multiSelectionIndex {
          Text("\(index + 1)")
            .fontWeight(.semibold)
            .padding(.horizontal, 4)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
        }
      }
      .padding(.horizontal, 12)
    }
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
    .frame(height: kind == .link ? 54 : 34)
  }

  private var visibleShortcut: KeyShortcut? {
    let pressed = modifierFlags.flags.intersection([.command, .option, .shift, .control])
    guard !pressed.isEmpty else { return nil }
    return item.shortcuts.first { $0.isVisible(item.shortcuts, pressed) }
  }

  private func linkLabel(_ url: URL) -> some View {
    let address = url.absoluteString
    let visibleAddress = String(address.dropFirst((url.scheme?.count ?? 0) + 3))
    let customTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = customTitle.isEmpty || customTitle == address ? url.host() ?? address : customTitle
    return VStack(alignment: .leading, spacing: 3) {
      Text(verbatim: title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
      Text(verbatim: visibleAddress.isEmpty ? address : visibleAddress)
    }
    .lineLimit(1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 12)
    .padding(.trailing, isShared || item.multiSelectionIndex != nil ? 44 : 12)
  }

  @ViewBuilder
  private func footerLabel(_ kind: ShelfItemKind) -> some View {
    switch kind {
    case .text:
      let count = item.previewText.string.count
      if item.previewText.isTruncated {
        Text("More than \(count) characters")
      } else if count == 1 {
        Text("1 character")
      } else {
        Text("\(count) characters")
      }

    case .link:
      Text("Web link")

    case .image:
      if let dimensions = imagePreview?.dimensions {
        Text(verbatim: dimensions)
          .monospacedDigit()
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(Color.primary.opacity(0.09), in: Capsule())
      }

    case .file:
      let urls = item.item.fileURLs
      if urls.count == 1, let ext = urls.first?.pathExtension, !ext.isEmpty {
        Text(verbatim: ext.uppercased())
      } else if urls.count == 1 {
        Text("1 file")
      } else {
        Text("\(urls.count) files")
      }
    }
  }

  private func sourceTint(_ kind: ShelfItemKind) -> Color {
    let bundleID = item.applicationImage.bundleIdentifier?.lowercased() ?? ""
    if bundleID.contains("anthropic") || bundleID.contains("claude") {
      return Color(red: 0.97, green: 0.34, blue: 0.14)
    }
    if bundleID.contains("calendar") || bundleID.contains("ical") {
      return Color(red: 0.95, green: 0.29, blue: 0.29)
    }
    if bundleID.contains("thebrowser") {
      return Color(red: 1, green: 0.23, blue: 0.36)
    }
    if bundleID.contains("wechat") || bundleID.contains("weixin") || bundleID.contains("facetime") {
      return Color(red: 0.07, green: 0.68, blue: 0.35)
    }
    if bundleID.contains("figma") || bundleID.contains("adobe") || bundleID.contains("photos") {
      return Color(red: 0.86, green: 0.25, blue: 0.55)
    }
    if bundleID.contains("tencent.qq") || bundleID.contains("wework") ||
        bundleID.contains("safari") || bundleID.contains("chrome") || bundleID.contains("edge") {
      return Color(red: 0.03, green: 0.59, blue: 0.95)
    }
    if bundleID.contains("finder") || bundleID.contains("preview") || bundleID.contains("icloud") {
      return Color(red: 0.10, green: 0.52, blue: 0.94)
    }
    if bundleID.contains("notes") || bundleID.contains("textedit") {
      return Color(red: 0.93, green: 0.55, blue: 0.09)
    }

    let swatches: [Color] = [
      Color(red: 0.06, green: 0.55, blue: 0.93),
      Color(red: 0.60, green: 0.34, blue: 0.90),
      Color(red: 0.04, green: 0.67, blue: 0.64),
      Color(red: 0.95, green: 0.35, blue: 0.20),
      Color(red: 0.94, green: 0.29, blue: 0.49)
    ]
    let key = bundleID.isEmpty ? kind.rawValue : bundleID
    let index = key.utf8.reduce(0) { ($0 * 31 + Int($1)) % swatches.count }
    return swatches[index]
  }
}

private struct ShelfCheckerboard: View {
  var body: some View {
    Canvas { context, size in
      let cell: CGFloat = 9
      for row in 0..<Int(ceil(size.height / cell)) {
        for column in stride(from: row % 2, to: Int(ceil(size.width / cell)), by: 2) {
          let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
          context.fill(Path(rect), with: .color(.primary.opacity(0.045)))
        }
      }
    }
    .background(Color.primary.opacity(0.025))
  }
}

nonisolated private struct ShelfImagePreview: Sendable {
  let image: CGImage
  let dimensions: String?

  static func make(from data: Data, maxPixelSize: Int) -> Self? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }

    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let dimensions: String?
    if let width = properties?[kCGImagePropertyPixelWidth] as? Int,
       let height = properties?[kCGImagePropertyPixelHeight] as? Int {
      let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
      dimensions = (5...8).contains(orientation) ? "\(height) × \(width)" : "\(width) × \(height)"
    } else {
      dimensions = nil
    }

    return Self(image: thumbnail, dimensions: dimensions)
  }
}
