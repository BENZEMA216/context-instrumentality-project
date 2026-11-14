import Defaults
import Foundation
import Observation
import SwiftUI

nonisolated enum ShelfBoardColor: String, CaseIterable, Codable, Identifiable, Sendable {
  case red, orange, yellow, green, blue, purple, gray

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .red: "红色"
    case .orange: "橙色"
    case .yellow: "黄色"
    case .green: "绿色"
    case .blue: "蓝色"
    case .purple: "紫色"
    case .gray: "灰色"
    }
  }

  var color: Color {
    switch self {
    case .red: Color(red: 1, green: 0.23, blue: 0.26)
    case .orange: Color(red: 1, green: 0.55, blue: 0.12)
    case .yellow: Color(red: 0.95, green: 0.75, blue: 0.08)
    case .green: Color(red: 0.27, green: 0.74, blue: 0.38)
    case .blue: Color(red: 0.12, green: 0.57, blue: 0.97)
    case .purple: Color(red: 0.61, green: 0.36, blue: 0.9)
    case .gray: Color(red: 0.57, green: 0.58, blue: 0.61)
    }
  }
}

nonisolated struct ShelfBoard: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var name: String
  var color: ShelfBoardColor
  var itemIDs: Set<String>
}

@MainActor
@Observable
final class ShelfBoards {
  static let shared = ShelfBoards()

  private(set) var boards: [ShelfBoard]
  var selectedBoardID: UUID?

  var selectedBoard: ShelfBoard? {
    boards.first { $0.id == selectedBoardID }
  }

  @ObservationIgnored private let preferences: UserDefaults
  private static let storageKey = "clipcontext.shelfBoards.v1"

  init(preferences: UserDefaults? = nil) {
    let preferences = preferences ?? Self.defaultPreferences
    self.preferences = preferences
    if let data = preferences.data(forKey: Self.storageKey),
       let saved = try? JSONDecoder().decode([ShelfBoard].self, from: data) {
      boards = saved
    } else {
      boards = []
    }
  }

  @discardableResult
  func create(name: String) -> ShelfBoard {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let board = ShelfBoard(
      id: UUID(),
      name: trimmed.isEmpty ? "新建收藏板" : trimmed,
      color: ShelfBoardColor.allCases[boards.count % ShelfBoardColor.allCases.count],
      itemIDs: []
    )
    boards.append(board)
    persist()
    return board
  }

  func rename(_ boardID: UUID, name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let index = boards.firstIndex(where: { $0.id == boardID }) else { return }
    boards[index].name = trimmed
    persist()
  }

  func delete(_ boardID: UUID) {
    boards.removeAll { $0.id == boardID }
    if selectedBoardID == boardID { selectedBoardID = nil }
    persist()
  }

  func setColor(_ color: ShelfBoardColor, for boardID: UUID) {
    guard let index = boards.firstIndex(where: { $0.id == boardID }) else { return }
    boards[index].color = color
    persist()
  }

  func contains(_ item: HistoryItem, in boardID: UUID) -> Bool {
    boards.first { $0.id == boardID }?.itemIDs.contains(Self.itemID(for: item)) ?? false
  }

  func containsAny(_ item: HistoryItem) -> Bool {
    let itemID = Self.itemID(for: item)
    return boards.contains { $0.itemIDs.contains(itemID) }
  }

  func toggleMember(_ item: HistoryItem, in boardID: UUID) {
    guard let index = boards.firstIndex(where: { $0.id == boardID }) else { return }
    let itemID = Self.itemID(for: item)
    if boards[index].itemIDs.contains(itemID) {
      boards[index].itemIDs.remove(itemID)
    } else {
      boards[index].itemIDs.insert(itemID)
    }
    persist()
  }

  func removeItem(_ item: HistoryItem) {
    let itemID = Self.itemID(for: item)
    guard boards.contains(where: { $0.itemIDs.contains(itemID) }) else { return }
    for index in boards.indices {
      boards[index].itemIDs.remove(itemID)
    }
    persist()
  }

  // Match the archive's existing identity for pre-MVP items without assigning
  // a new archiveID or changing their Agent sharing preferences.
  private static func itemID(for item: HistoryItem) -> String {
    item.archiveID?.uuidString.lowercased()
      ?? String(item.firstCopiedAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(boards) else { return }
    preferences.set(data, forKey: Self.storageKey)
  }

  private static var defaultPreferences: UserDefaults {
    #if DEBUG
    if AppDelegate.isTesting {
      return UserDefaults(suiteName: Defaults.Keys.testingSuiteName) ?? .standard
    }
    #endif
    return .standard
  }
}
