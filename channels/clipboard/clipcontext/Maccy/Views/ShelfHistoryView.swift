import Defaults
import SwiftUI

struct ShelfHistoryView: View {
  static let height: CGFloat = 324

  @FocusState.Binding var searchFocused: Bool
  @Environment(AppState.self) private var appState
  @Environment(ModifierFlags.self) private var modifierFlags
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.colorScheme) private var colorScheme
  @Default(.showSearch) private var showSearch
  @Default(.ignoreEvents) private var paused
  @Default(.ignoreOnlyNextEvent) private var ignoreOnlyNextEvent
  @State private var boards = ShelfBoards.shared
  @State private var boardFormPresented = false
  @State private var boardName = ""
  @State private var editingBoardID: UUID?
  @State private var archive = ClipboardArchive.shared
  @State private var searchExpanded = false
  @State private var previewPresented = false
  @State private var editingItem: HistoryItemDecorator?
  @State private var creatingText = false

  private var history: History { appState.history }
  private var navigator: NavigationManager { appState.navigator }
  private var cards: [HistoryItemDecorator] { Array(history.items) }
  private var searchIsVisible: Bool {
    showSearch && (searchExpanded || !history.searchQuery.isEmpty)
  }

  var body: some View {
    @Bindable var history = appState.history

    KeyHandlingView(
      searchQuery: $history.searchQuery,
      searchFocused: $searchFocused,
      toggleShelfPreview: togglePreview
    ) {
      VStack(spacing: 0) {
        toolbar(searchQuery: $history.searchQuery)
        if cards.isEmpty {
          emptyState
        } else {
          cardStrip
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background {
      Rectangle().fill(.ultraThinMaterial)
      Color(nsColor: colorScheme == .dark ? .windowBackgroundColor : NSColor(calibratedWhite: 0.98, alpha: 1)).opacity(0.96)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 24)
        .strokeBorder(.white.opacity(colorScheme == .dark ? 0.14 : 0.58), lineWidth: 1)
        .allowsHitTesting(false)
    }
    .clipShape(.rect(cornerRadius: 24))
    .onMouseMove { navigator.isKeyboardNavigating = false }
    .onChange(of: scenePhase, initial: true) {
      if scenePhase == .active {
        searchFocused = true
        navigator.isKeyboardNavigating = true
        navigator.highlightFirst()
      } else {
        history.searchQuery = ""
        searchExpanded = false
        previewPresented = false
        modifierFlags.flags = []
        navigator.hoverSelectionWhileKeyboardNavigating = nil
      }
    }
    .onChange(of: cards.map(\.id)) {
      if cards.isEmpty { previewPresented = false }
      if let lead = navigator.leadHistoryItem, cards.contains(lead) { return }
      navigator.highlightFirst()
    }
    .sheet(item: $editingItem, onDismiss: finishEditing) { item in
      ItemEditorView(for: item)
    }
    .sheet(isPresented: $creatingText, onDismiss: finishEditing) {
      ShelfNewTextView()
    }
    .sheet(isPresented: $boardFormPresented, onDismiss: finishEditing) {
      boardForm
    }
  }

  private func toolbar(searchQuery: Binding<String>) -> some View {
    HStack(spacing: 14) {
      if navigator.isMultiSelectInProgress {
        PasteSelectionControls()
          .fixedSize(horizontal: true, vertical: false)
      } else {
        searchField(searchQuery)
        shelfTab("剪贴板", icon: "clock.arrow.circlepath", favorites: false)
        shelfTab("收藏", icon: "circle.fill", favorites: true)
        boardTabs
        if !searchIsVisible {
          Button {
            boardName = ""
            editingBoardID = nil
            appState.isEditingItem = true
            boardFormPresented = true
          } label: {
            Image(systemName: "plus")
              .font(.system(size: 17, weight: .regular))
              .frame(width: 28, height: 28)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("新建收藏板")
          .accessibilityIdentifier("shelf-add-board")
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 64)
    .frame(height: 64)
    .overlay(alignment: .trailing) {
      moreMenu.padding(.trailing, 16)
    }
    .overlay(alignment: .leading) {
      if let stack = history.pasteStack {
        Menu {
          Text("返回目标应用连续按 ⌘V，按选择顺序粘贴。")
          Button("停止顺序粘贴") { appState.removePasteStack() }
            .accessibilityIdentifier("stop-paste-stack")
        } label: {
          Label("\(stack.items.count)", systemImage: "square.stack")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.leading, 16)
        .accessibilityLabel("顺序粘贴队列剩余 \(stack.items.count) 条")
        .accessibilityIdentifier("shelf-paste-stack")
      } else if paused {
        Image(systemName: "pause")
          .foregroundStyle(.secondary)
          .padding(.leading, 22)
          .accessibilityLabel("剪贴板记录已暂停")
      }
    }
  }

  private func searchField(_ query: Binding<String>) -> some View {
    ZStack(alignment: .leading) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField("搜索剪贴板", text: query)
          .textFieldStyle(.plain)
          .disableAutocorrection(true)
          .lineLimit(1)
          .accessibilityIdentifier("shelf-search")
          .focused($searchFocused)
          .onSubmit {
            history.prepareShelfSearchForSelection()
            appState.select(flags: .currentModifierFlags)
          }
        if !query.wrappedValue.isEmpty {
          Button {
            query.wrappedValue = ""
            searchFocused = true
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
              .frame(width: 20, height: 24)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("清除搜索")
          .accessibilityIdentifier("shelf-clear-search")
        }
        filterMenu
      }
      .padding(.horizontal, 10)
      .frame(width: 432, height: 30)
      .background(.primary.opacity(0.085), in: Capsule())
      .overlay {
        Capsule().strokeBorder(
          searchFocused ? Color.accentColor.opacity(0.5) : .primary.opacity(0.09),
          lineWidth: searchFocused ? 3 : 1
        )
        .allowsHitTesting(false)
      }
      .opacity(searchIsVisible ? 1 : 0)
      .allowsHitTesting(searchIsVisible)
      .accessibilityHidden(!searchIsVisible)

      if !searchIsVisible {
        HStack(spacing: 3) {
          if showSearch {
            Button {
              searchExpanded = true
              searchFocused = true
            } label: {
              Image(systemName: "magnifyingglass").frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索剪贴板")
            .accessibilityIdentifier("shelf-open-search")
          }
        }

      }
    }
    .frame(width: searchIsVisible ? 432 : 28, alignment: .leading)
  }

  private func shelfTab(_ title: LocalizedStringKey, icon: String, favorites: Bool) -> some View {
    let active = boards.selectedBoardID == nil && favorites == history.shelfFavoritesOnly
    return Button {
      boards.selectedBoardID = nil
      history.applyShelfFilter(favoritesOnly: favorites, kind: history.shelfKind)
      searchFocused = true
    } label: {
      HStack(spacing: 6) {
        Image(systemName: icon)
          .font(.system(size: favorites ? 12 : 14))
          .foregroundStyle(favorites ? Color.red : Color.primary)
        if !searchIsVisible { Text(title).font(.system(size: 13)) }
      }
      .lineLimit(1)
      .padding(.horizontal, searchIsVisible ? 4 : 10)
      .frame(height: 28)
      .background {
        if active && !searchIsVisible {
          Capsule().fill(.primary.opacity(0.075))
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(active ? .isSelected : [])
    .accessibilityIdentifier(favorites ? "shelf-favorites-tab" : "shelf-history-tab")
  }

  @ViewBuilder
  private var boardTabs: some View {
    if boards.boards.count > 2 {
      ScrollView(.horizontal) {
        HStack(spacing: 14) { boardTabButtons }
      }
      .scrollIndicators(.hidden)
      .frame(width: searchIsVisible ? 100 : 300, height: 32)
    } else {
      boardTabButtons
    }
  }

  private var boardTabButtons: some View {
    ForEach(boards.boards) { board in
      Button {
        boards.selectedBoardID = board.id
        history.applyShelfFilter(favoritesOnly: false, kind: history.shelfKind)
        searchFocused = true
      } label: {
        HStack(spacing: 6) {
          Circle().fill(board.color.color).frame(width: 12, height: 12)
          if !searchIsVisible {
            Text(board.name).font(.system(size: 13)).lineLimit(1)
          }
        }
        .padding(.horizontal, searchIsVisible ? 4 : 10)
        .frame(height: 28)
        .background {
          if boards.selectedBoardID == board.id && !searchIsVisible {
            Capsule().fill(.primary.opacity(0.075))
          }
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel(board.name)
      .accessibilityIdentifier("shelf-board-\(board.id)")
      .contextMenu {
        Button("重命名…") {
          editingBoardID = board.id
          boardName = board.name
          appState.isEditingItem = true
          boardFormPresented = true
        }
        Menu("颜色") {
          ForEach(ShelfBoardColor.allCases, id: \.self) { color in
            Button {
              boards.setColor(color, for: board.id)
            } label: {
              Label(color.title, systemImage: board.color == color ? "checkmark.circle.fill" : "circle.fill")
            }
          }
        }
        Divider()
        Button("删除收藏板", role: .destructive) {
          boards.delete(board.id)
          history.applyShelfFilter(favoritesOnly: false, kind: history.shelfKind)
        }
      }
    }
  }

  private var boardForm: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(editingBoardID == nil ? "新建收藏板" : "重命名收藏板")
        .font(.headline)
      TextField("名称", text: $boardName)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("shelf-board-name")
        .onSubmit(saveBoard)
      HStack {
        Spacer()
        Button("取消", role: .cancel) { boardFormPresented = false }
          .keyboardShortcut(.cancelAction)
        Button("保存", action: saveBoard)
          .keyboardShortcut(.defaultAction)
          .disabled(boardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("shelf-board-save")
      }
    }
    .padding(24)
    .frame(width: 320)
  }

  private func saveBoard() {
    guard !boardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if let editingBoardID {
      boards.rename(editingBoardID, name: boardName)
    } else {
      boards.selectedBoardID = boards.create(name: boardName).id
      history.applyShelfFilter(favoritesOnly: false, kind: history.shelfKind)
    }
    boardFormPresented = false
  }

  private var filterMenu: some View {
    Menu {
      Button {
        history.applyShelfFilter(favoritesOnly: history.shelfFavoritesOnly, kind: nil)
      } label: {
        menuChoice("全部类型", symbol: "line.3.horizontal.decrease", selected: history.shelfKind == nil)
      }
      .accessibilityIdentifier("shelf-filter-all")
      Divider()
      ForEach(ShelfItemKind.allCases, id: \.id) { kind in
        Button {
          history.applyShelfFilter(favoritesOnly: history.shelfFavoritesOnly, kind: kind)
        } label: {
          menuChoice(kind.title, symbol: kind.symbol, selected: history.shelfKind == kind)
        }
        .accessibilityIdentifier("shelf-filter-\(kind.id)")
      }
    } label: {
      Image(systemName: history.shelfKind == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(history.shelfKind == nil ? Color.secondary : Color.accentColor)
        .frame(width: 25, height: 28)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("筛选内容类型")
    .accessibilityIdentifier("shelf-filter")
  }

  private func menuChoice(_ title: LocalizedStringKey, symbol: String, selected: Bool) -> some View {
    Label(title, systemImage: selected ? "checkmark" : symbol)
  }

  private var moreMenu: some View {
    let clear = appState.footer.items[0]
    let clearAll = appState.footer.items[1]
    return Menu {
      if navigator.isMultiSelectInProgress {
        Button("开始顺序粘贴") { appState.startSelectedPasteStack() }
          .disabled(navigator.selection.isEmpty)
        Button("取消多选") { appState.cancelMultiSelection() }
      } else {
        Button("选择多条…", systemImage: "checkmark.circle") { appState.beginMultiSelection() }
          .disabled(cards.isEmpty)
          .accessibilityIdentifier("begin-multiple-selection")
      }
      if history.pasteStack != nil {
        Button("停止顺序粘贴", systemImage: "stop.circle") { appState.removePasteStack() }
      }
      Divider()
      Button("新建文本", systemImage: "square.and.pencil") {
        appState.isEditingItem = true
        creatingText = true
      }
      Divider()
      Button("设置…", systemImage: "gearshape") { appState.openPreferences() }
        .accessibilityIdentifier("shelf-open-settings")
      Button("Agent 目录…", systemImage: "folder") { appState.openPreferences(showArchive: true) }
      Button("切换到列表视图", systemImage: "list.bullet") {
        appState.popup.close()
        Defaults[.historyPresentation] = .list
        appState.popup.open(height: appState.popup.height)
      }
      Divider()
      if paused {
        Button("恢复剪贴板记录", systemImage: "play") {
          ignoreOnlyNextEvent = false
          paused = false
        }
      } else {
        Menu("暂停剪贴板记录", systemImage: "pause") {
          Button("暂停，直到手动恢复") {
            ignoreOnlyNextEvent = false
            paused = true
          }
          Button("只忽略下一次复制") {
            ignoreOnlyNextEvent = true
            paused = true
          }
        }
      }
      Button("清除历史记录", systemImage: "trash") { clear.requestConfirmation() }
      Button("清除所有记录（含收藏）", systemImage: "trash") { clearAll.requestConfirmation() }
      Divider()
      if let guide = Bundle.main.url(forResource: "ClipContext-Guide", withExtension: "html") {
        Button("使用指南", systemImage: "questionmark.circle") { NSWorkspace.shared.open(guide) }
      }
      Button("关于 ClipContext", systemImage: "info.circle") { appState.openAbout() }
      Button("退出 ClipContext", systemImage: "power") { appState.quit() }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 28, height: 28)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("更多")
    .accessibilityIdentifier("shelf-more")
    .popover(isPresented: $previewPresented, arrowEdge: .bottom) {
      if let item = navigator.leadHistoryItem {
        PreviewItemView(item: item)
          .id(item.id)
          .padding(16)
          .frame(width: 384, height: 260)
      }
    }
    .historyConfirmation(for: clear)
    .background { Color.clear.historyConfirmation(for: clearAll) }
  }

  private var cardStrip: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        LazyHStack(spacing: 24) {
          ForEach(cards) { item in
            cardButton(item).id(item.id)
          }
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 24)
      }
      .scrollIndicators(.hidden)
      .accessibilityIdentifier("history-scroll-view")
      .task(id: navigator.scrollTarget) {
        guard let target = navigator.scrollTarget else { return }
        await Task.yield()
        guard !Task.isCancelled, navigator.scrollTarget == target else { return }
        proxy.scrollTo(target)
        navigator.scrollTarget = nil
      }
    }
  }

  private func cardButton(_ item: HistoryItemDecorator) -> some View {
    let shared = archive.isShared(item.item)
    let canShare = archive.canShare(item.item)
    return Button {
      if NSEvent.modifierFlags.contains(.command) || navigator.isMultiSelectInProgress {
        navigator.addToSelection(item: item)
      } else {
        appState.history.select(item, flags: .currentModifierFlags)
      }
    } label: {
      ShelfHistoryCard(
        item: item,
        isSelected: item.isSelected,
        isShared: shared,
        boardColor: boards.selectedBoard?.color.color ?? (history.shelfFavoritesOnly ? .red : nil)
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(verbatim: shared ? "\(item.accessibilityLabel)，已共享给 Agent" : item.accessibilityLabel))
    .accessibilityAddTraits(item.isSelected ? .isSelected : [])
    .accessibilityIdentifier("copy-history-item")
    .accessibilityAction(named: Text(item.isPinned ? "history_item_unpin_action" : "history_item_pin_action")) {
      history.togglePin(item)
    }
    .accessibilityAction(named: Text("history_item_delete_action")) {
      history.delete(item)
    }
    .onHover { hovering in
      if hovering {
        if navigator.isKeyboardNavigating || navigator.isMultiSelectInProgress {
          navigator.hoverSelectionWhileKeyboardNavigating = item.id
        } else {
          navigator.selectWithoutScrolling(item: item)
        }
      } else if navigator.hoverSelectionWhileKeyboardNavigating == item.id {
        navigator.hoverSelectionWhileKeyboardNavigating = nil
      }
    }
    .contextMenu {
      Button(navigator.isMultiSelectInProgress ? (item.isSelected ? "移出多选" : "加入多选") : "选择多条…") {
        if navigator.isMultiSelectInProgress {
          navigator.addToSelection(item: item)
        } else {
          appState.beginMultiSelection(with: item)
        }
      }
      .accessibilityIdentifier("history-select-multiple")
      Divider()
      Button("粘贴", systemImage: "arrow.turn.down.left") {
        history.select(item, flags: HistoryItemAction.paste.modifierFlags)
      }
      Button("粘贴为纯文本", systemImage: "text.alignleft") {
        history.select(item, flags: HistoryItemAction.pasteWithoutFormatting.modifierFlags)
      }
      .disabled(!item.hasPlainText)
      Button("复制", systemImage: "doc.on.doc") {
        history.select(item, flags: HistoryItemAction.copy.modifierFlags)
      }
      Divider()
      Button("编辑…", systemImage: "pencil") {
        appState.isEditingItem = true
        editingItem = item
      }
      .disabled(!item.hasPlainText && !item.hasRichText && !item.hasImage)
      Button("预览", systemImage: "eye") {
        navigator.select(item: item)
        previewPresented = true
      }
      Button(item.isPinned ? "取消收藏" : "收藏", systemImage: item.isPinned ? "star.slash" : "star") {
        history.togglePin(item)
      }
      if !boards.boards.isEmpty {
        Menu("加入收藏板", systemImage: "folder") {
          ForEach(boards.boards) { board in
            Button {
              boards.toggleMember(item.item, in: board.id)
            } label: {
              Label(board.name, systemImage: boards.contains(item.item, in: board.id) ? "checkmark" : "folder")
            }
          }
        }
      }
      Button(shared ? "撤销 Agent 共享" : "分享给 Agent", systemImage: "tray.and.arrow.up") {
        archive.setShared(!shared, for: item.item)
      }
      .disabled(!canShare)
      Divider()
      Button("删除", systemImage: "trash", role: .destructive) {
        history.delete(item)
      }
    }
  }

  private var emptyState: some View {
    let searching = !history.searchQuery.isEmpty || history.shelfKind != nil
    let message: LocalizedStringKey = searching ? "未找到匹配内容" :
      (history.shelfFavoritesOnly || boards.selectedBoardID != nil ? "暂无收藏" : "暂无剪贴板记录")
    return VStack(spacing: 9) {
      Text(message)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("shelf-empty")
      if !searching {
        Text(history.shelfFavoritesOnly || boards.selectedBoardID != nil ?
             "右键点击卡片即可加入收藏" : "复制的文字、图片和文件会显示在这里")
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.bottom, 24)
  }

  private func togglePreview() {
    if navigator.leadHistoryItem != nil {
      previewPresented.toggle()
    }
  }

  private func finishEditing() {
    appState.isEditingItem = false
    searchFocused = true
  }
}

private struct ShelfNewTextView: View {
  @Environment(\.dismiss) private var dismiss
  @FocusState private var editorFocused: Bool
  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Button("取消", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Text("新建文本").font(.headline)
        Spacer()
        Button("创建") {
          Clipboard.shared.copyInMaccy(text)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      TextEditor(text: $text)
        .font(.system(size: 14))
        .scrollContentBackground(.hidden)
        .padding(8)
        .background(.primary.opacity(0.045), in: .rect(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.13))
        }
        .accessibilityLabel("文本内容")
        .focused($editorFocused)
      Text("\(text.count) 个字符")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(18)
    .frame(width: 550, height: 340)
    .onAppear { editorFocused = true }
  }
}
