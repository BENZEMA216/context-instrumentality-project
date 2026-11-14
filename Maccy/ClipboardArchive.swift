import AppKit
import CryptoKit
import Defaults
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ClipboardArchive {
  static let shared: ClipboardArchive = {
    #if DEBUG
    if let directory = AppDelegate.qaDirectory {
      return ClipboardArchive(localURL: directory.appending(path: "Agent/clipboard.json"))
    }
    #endif
    return ClipboardArchive()
  }()

  enum Policy: String, CaseIterable, Identifiable {
    case off, manual, pinned, all

    var id: String { rawValue }
  }

  enum Destination: String, CaseIterable, Identifiable, Sendable {
    case iCloudDrive, googleDrive

    var id: String { rawValue }
  }

  private struct Part: Encodable, Sendable {
    let type: String
    let text: String?
    let base64: Data?
  }

  private struct Item: Encodable, Sendable {
    let id: String
    let application: String?
    let firstCopiedAt: String
    let lastCopiedAt: String
    let numberOfCopies: Int
    let pin: String?
    let title: String
    let contents: [Part]
  }

  nonisolated private struct Snapshot: Encodable {
    let schemaVersion = 1
    let deviceID: String
    let updatedAt: String
    let revision: Int
    let items: [Item]
  }

  nonisolated private struct SnapshotHeader: Decodable {
    let deviceID: String
    let revision: Int
  }

  private struct SelectedFolder: Sendable {
    let url: URL
    let bookmark: Data
  }

  private struct Publication: Sendable {
    let revision: Int
    let digest: String
    let data: Data
  }

  private let preferences: UserDefaults
  private let historyContext: () -> ModelContext
  private static let prefix = "ClipboardArchive."
  let deviceID: String
  let localURL: URL

  var policy: Policy {
    didSet {
      preferences.set(policy.rawValue, forKey: Self.prefix + "policy")
      syncNow()
    }
  }

  var intervalMinutes: Int {
    didSet {
      preferences.set(intervalMinutes, forKey: Self.prefix + "interval")
      restartTimer()
    }
  }

  private(set) var lastSync: Date?
  private(set) var lastItemCount = 0
  private(set) var localError: String?
  private(set) var isPublishing = false
  private(set) var remoteLastSync: Date?
  private(set) var remoteError: String?
  var remotePublisher: ((Data, String) async throws -> Void)?

  private var manualIncluded: Set<String>
  private var manualExcluded: Set<String>
  private var folders: [Destination: SelectedFolder] = [:]
  private var statuses: [Destination: String] = [:]

  @ObservationIgnored private var localRevision: Int
  @ObservationIgnored private var localDigest: String?
  @ObservationIgnored private var remoteRevision: Int?
  @ObservationIgnored private var remoteGeneration = 0
  @ObservationIgnored private var destinationRevisions: [Destination: Int] = [:]
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var pending = false

  init(
    preferences: UserDefaults = .standard,
    localURL: URL = URL.applicationSupportDirectory.appending(path: "ClipContext/Agent/clipboard.json"),
    historyContext: @escaping () -> ModelContext = { Storage.shared.context }
  ) {
    self.preferences = preferences
    self.localURL = localURL
    self.historyContext = historyContext
    let prefs = preferences
    let prefix = Self.prefix
    let deviceID = prefs.string(forKey: prefix + "deviceID") ?? UUID().uuidString.lowercased()
    self.deviceID = deviceID
    prefs.set(deviceID, forKey: prefix + "deviceID")
    policy = Policy(rawValue: prefs.string(forKey: prefix + "policy") ?? "") ?? .off
    let savedInterval = prefs.integer(forKey: prefix + "interval")
    intervalMinutes = savedInterval == 0 ? 5 : max(1, savedInterval)
    localRevision = prefs.integer(forKey: prefix + "revision")
    localDigest = prefs.string(forKey: prefix + "digest")
    manualIncluded = Set(prefs.stringArray(forKey: prefix + "included") ?? [])
    manualExcluded = Set(prefs.stringArray(forKey: prefix + "excluded") ?? [])

    for destination in Destination.allCases {
      guard let bookmark = prefs.data(forKey: prefix + destination.rawValue) else { continue }
      do {
        let url = try Self.resolve(bookmark)
        folders[destination] = SelectedFolder(url: url, bookmark: bookmark)
      } catch {
        statuses[destination] = "Select the folder again: \(error.localizedDescription)"
      }
    }
  }

  isolated deinit {
    timer?.invalidate()
  }

  func start() {
    guard !started else { return }
    started = true
    restartTimer()
    syncNow()
  }

  private func restartTimer() {
    timer?.invalidate()
    guard started else { return }
    timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, intervalMinutes)) * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.syncNow() }
    }
  }

  func folder(for destination: Destination) -> URL? { folders[destination]?.url }

  func destinationStatus(for destination: Destination) -> String? {
    statuses[destination] ?? (folders[destination] == nil ? nil : "Ready to write")
  }

  func setFolder(_ url: URL, for destination: Destination) throws {
    if folders.contains(where: { key, folder in
      key != destination && folder.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
    }) {
      throw CocoaError(.fileWriteFileExists, userInfo: [
        NSLocalizedDescriptionKey: "This folder is already assigned to the other destination."
      ])
    }
    let options: URL.BookmarkCreationOptions = [.withSecurityScope]
    let bookmark = try (try? url.bookmarkData(options: options)) ?? url.bookmarkData(options: [.minimalBookmark])
    if let existing = folders[destination], existing.url.standardizedFileURL != url.standardizedFileURL {
      try Self.removeSnapshot(in: existing, deviceID: deviceID)
    }
    folders[destination] = SelectedFolder(url: url, bookmark: bookmark)
    preferences.set(bookmark, forKey: Self.prefix + destination.rawValue)
    destinationRevisions[destination] = nil
    statuses[destination] = "Ready to write"
    syncNow()
  }

  func disconnect(_ destination: Destination) throws {
    if let selected = folders[destination] {
      try Self.removeSnapshot(in: selected, deviceID: deviceID)
    }
    folders[destination] = nil
    preferences.removeObject(forKey: Self.prefix + destination.rawValue)
    destinationRevisions[destination] = nil
    statuses[destination] = nil
  }

  func invalidateRemotePublication() {
    remoteGeneration += 1
    remoteRevision = nil
    remoteLastSync = nil
    remoteError = nil
    syncNow()
  }

  func isShared(_ item: HistoryItem) -> Bool {
    let id = Self.id(for: item)
    return selected(item, id: id) && canShare(item)
  }

  func canShare(_ item: HistoryItem) -> Bool {
    Self.eligible(item, filters: currentFilters())
  }

  func setShared(_ shared: Bool, for item: HistoryItem) {
    guard !shared || canShare(item) else { return }
    let id = Self.id(for: item)
    if shared {
      manualIncluded.insert(id)
      manualExcluded.remove(id)
      if policy == .off { policy = .manual }
    } else {
      manualIncluded.remove(id)
      manualExcluded.insert(id)
    }
    preferences.set(manualIncluded.sorted(), forKey: Self.prefix + "included")
    preferences.set(manualExcluded.sorted(), forKey: Self.prefix + "excluded")
    syncNow()
  }

  private func selected(_ item: HistoryItem, id: String) -> Bool {
    guard policy != .off, !manualExcluded.contains(id) else { return false }
    return manualIncluded.contains(id) || policy == .all || (policy == .pinned && item.pin != nil)
  }

  var canSync: Bool {
    policy != .off || lastSync != nil || localRevision > 0 || FileManager.default.fileExists(atPath: localURL.path)
  }

  func syncNow() {
    guard started else { return }
    if isPublishing {
      pending = true
      return
    }
    // An untouched install has no archive to clear.
    guard canSync else { return }
    isPublishing = true
    Task { await publish() }
  }

  private func publish() async {
    defer {
      isPublishing = false
      if pending {
        pending = false
        syncNow()
      }
    }

    do {
      let items = try collect()
      let localURL = localURL
      let deviceID = deviceID
      let previousRevision = localRevision
      let previousDigest = localDigest
      let publication = try await Task.detached(priority: .utility) {
        try Self.writeLocal(items, to: localURL, deviceID: deviceID, revision: previousRevision, digest: previousDigest)
      }.value

      localRevision = publication.revision
      localDigest = publication.digest
      preferences.set(localRevision, forKey: Self.prefix + "revision")
      preferences.set(localDigest, forKey: Self.prefix + "digest")
      lastItemCount = items.count
      lastSync = Date()
      localError = nil

      // If settings changed during the local write, publish the replacement to cloud folders next.
      guard !pending else { return }
      for (destination, selected) in folders where destinationRevisions[destination] != publication.revision {
        do {
          try Self.writeSnapshot(publication.data, in: selected, deviceID: deviceID)
          destinationRevisions[destination] = publication.revision
          statuses[destination] = "Written to folder at \(Date().formatted(date: .abbreviated, time: .shortened))"
        } catch {
          statuses[destination] = error.localizedDescription
        }
      }

      await publishRemote(publication)
    } catch {
      localError = error.localizedDescription
    }
  }

  private func publishRemote(_ publication: Publication) async {
    guard remoteRevision != publication.revision, let remotePublisher else { return }
    let generation = remoteGeneration
    do {
      try await remotePublisher(publication.data, deviceID)
      guard generation == remoteGeneration else { return }
      remoteRevision = publication.revision
      remoteLastSync = Date()
      remoteError = nil
    } catch {
      guard generation == remoteGeneration else { return }
      remoteError = error.localizedDescription
    }
  }

  private struct Filters {
    let apps: Set<String>
    let onlyListedApps: Bool
    let types: Set<String>
    let regexes: [NSRegularExpression]
  }

  private func currentFilters() -> Filters {
    let ignoredTypes: [NSPasteboard.PasteboardType] = [.autoGenerated, .concealed, .transient]
    return Filters(
      apps: Set(Defaults[.ignoredApps]),
      onlyListedApps: Defaults[.ignoreAllAppsExceptListed],
      types: Defaults[.ignoredPasteboardTypes].union(ignoredTypes.map(\.rawValue)),
      regexes: Defaults[.ignoreRegexp].compactMap { try? NSRegularExpression(pattern: $0) }
    )
  }

  private static func eligible(_ item: HistoryItem, filters: Filters) -> Bool {
    if filters.onlyListedApps {
      guard let application = item.application, filters.apps.contains(application) else { return false }
    } else if let application = item.application, filters.apps.contains(application) {
      return false
    }
    guard filters.types.isDisjoint(with: item.contents.map(\.type)) else { return false }
    if !filters.regexes.isEmpty, let text = item.text {
      let range = NSRange(text.startIndex..., in: text)
      return filters.regexes.allSatisfy { $0.firstMatch(in: text, range: range) == nil }
    }
    return true
  }

  private func collect() throws -> [Item] {
    guard policy != .off else { return [] }
    let records = try historyContext().fetch(FetchDescriptor<HistoryItem>())
    let liveIDs = Set(records.map(Self.id))
    pruneSelections(to: liveIDs)
    let filters = currentFilters()
    let formatter = Self.dateFormatter()
    return records.compactMap { record -> Item? in
      let id = Self.id(for: record)
      guard selected(record, id: id), Self.eligible(record, filters: filters) else { return nil }
      let contents = record.contents.compactMap(Self.exportPart).sorted(by: Self.compareParts)
      guard !contents.isEmpty else { return nil }
      return Item(
        id: id,
        application: record.application,
        firstCopiedAt: formatter.string(from: record.firstCopiedAt),
        lastCopiedAt: formatter.string(from: record.lastCopiedAt),
        numberOfCopies: record.numberOfCopies,
        pin: record.pin,
        title: record.title,
        contents: contents
      )
    }.sorted { $0.id < $1.id }
  }

  private func pruneSelections(to liveIDs: Set<String>) {
    let included = manualIncluded.intersection(liveIDs)
    let excluded = manualExcluded.intersection(liveIDs)
    if included != manualIncluded {
      manualIncluded = included
      preferences.set(included.sorted(), forKey: Self.prefix + "included")
    }
    if excluded != manualExcluded {
      manualExcluded = excluded
      preferences.set(excluded.sorted(), forKey: Self.prefix + "excluded")
    }
  }

  private static func id(for item: HistoryItem) -> String {
    item.archiveID?.uuidString.lowercased() ?? String(item.firstCopiedAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
  }

  private static let metadataTypes: Set<NSPasteboard.PasteboardType> = [
    .modified, .fromMaccy, .source, .customWebKitPasteboardData, .customChromiumWebData,
    .chromiumSourceToken, .linkPresentationMetadata, .notesRichText
  ]

  private static func exportPart(_ content: HistoryItemContent) -> Part? {
    let type = NSPasteboard.PasteboardType(content.type)
    guard let bytes = content.value, !bytes.isEmpty, !metadataTypes.contains(type) else { return nil }
    if type == .fileURL || type == .URL {
      guard let url = URL(dataRepresentation: bytes, relativeTo: nil, isAbsolute: true) else { return nil }
      return Part(type: content.type, text: url.absoluteString, base64: nil)
    }
    if type == .string || type == .html || type == .rtf || content.type == "public.utf8-tab-separated-values-text" {
      if let text = String(data: bytes, encoding: .utf8) {
        return Part(type: content.type, text: text, base64: nil)
      }
    }
    return Part(type: content.type, text: nil, base64: bytes)
  }

  private static func compareParts(_ lhs: Part, _ rhs: Part) -> Bool {
    if lhs.type != rhs.type { return lhs.type < rhs.type }
    if let lhsText = lhs.text, let rhsText = rhs.text { return lhsText < rhsText }
    if let lhsData = lhs.base64, let rhsData = rhs.base64 { return lhsData.lexicographicallyPrecedes(rhsData) }
    return lhs.text != nil && rhs.text == nil
  }

  nonisolated private static func dateFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }

  nonisolated private static func writeLocal(
    _ items: [Item], to url: URL, deviceID: String, revision: Int, digest: String?
  ) throws -> Publication {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let nextDigest = Data(SHA256.hash(data: try encoder.encode(items))).base64EncodedString()
    let existingData = try? Data(contentsOf: url)
    let existingHeader = existingData.flatMap { try? JSONDecoder().decode(SnapshotHeader.self, from: $0) }
    if nextDigest == digest, let existingData, let existingHeader,
       existingHeader.deviceID == deviceID, existingHeader.revision == revision {
      return Publication(revision: revision, digest: nextDigest, data: existingData)
    }

    let nextRevision = max(revision, existingHeader?.revision ?? 0) + 1
    let snapshot = Snapshot(deviceID: deviceID, updatedAt: dateFormatter().string(from: Date()), revision: nextRevision, items: items)
    let data = try encoder.encode(snapshot)
    let folder = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return Publication(revision: nextRevision, digest: nextDigest, data: data)
  }

  private static func resolve(_ bookmark: Data) throws -> URL {
    var stale = false
    if let scoped = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
      return scoped
    }
    return try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
  }

  private static func snapshotURL(in folder: URL, deviceID: String) -> URL {
    folder.appending(path: "ClipContext", directoryHint: .isDirectory)
      .appending(path: deviceID, directoryHint: .isDirectory)
      .appending(path: "clipboard.json", directoryHint: .notDirectory)
  }

  private static func writeSnapshot(_ data: Data, in folder: SelectedFolder, deviceID: String) throws {
    try access(folder) { root in
      let target = snapshotURL(in: root, deviceID: deviceID)
      try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try coordinate(target, options: .forReplacing) { try data.write(to: $0, options: .atomic) }
    }
  }

  private static func removeSnapshot(in folder: SelectedFolder, deviceID: String) throws {
    try access(folder) { root in
      let target = snapshotURL(in: root, deviceID: deviceID)
      try coordinate(target, options: .forDeleting) { url in
        do {
          try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
          // The snapshot already does not exist.
        }
      }
    }
  }

  private static func access(_ folder: SelectedFolder, operation: (URL) throws -> Void) throws {
    let url = try resolve(folder.bookmark)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    try operation(url)
  }

  private static func coordinate(
    _ url: URL, options: NSFileCoordinator.WritingOptions, operation: (URL) throws -> Void
  ) throws {
    var coordinationError: NSError?
    var operationError: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { coordinatedURL in
      do { try operation(coordinatedURL) } catch { operationError = error }
    }
    if let coordinationError { throw coordinationError }
    if let operationError { throw operationError }
  }
}
