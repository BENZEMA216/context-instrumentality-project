import SwiftUI

struct CollapsedStackItem<Content: View>: View {
  let maxItems: Int
  let index: Int
  let open: Bool

  @State var height: CGFloat = -1
  var content: () -> Content

  private var offset: Double {
    if open || index == 0 {
      return 0
    }
    if index + 1 > maxItems {
      return -height
    }
    return -height * 0.75
  }

  private var scale: Double {
    if open {
      return 1
    }
    return pow(0.98, Double(index))
  }

  private var opacity: Double {
    if open {
      return 1
    }
    if index + 1 > maxItems {
      return 0
    }
    return pow(0.95, Double(index))
  }

  var body: some View {
    content()
      .background(
        GeometryReader { geo in
          Color.clear
            .task(id: geo.size.height) {
              DispatchQueue.main.async {
                height = geo.size.height
              }
            }
        }
      )
      .offset(y: offset)
      .padding(.bottom, offset)
      .opacity(opacity)
      .scaleEffect(scale, anchor: .center)
      .zIndex(Double(-index))
  }
}

struct PasteStackView: View {
  var stack: PasteStack
  var open: Bool = false

  @Environment(AppState.self) private var appState

  private func indexTagFor(_ index: Int) -> Int? {
    if open {
      return index
    }
    if index == 0 {
      return stack.items.count - 1
    }
    return nil
  }

  var body: some View {
    let maxItems = min(3, stack.items.count)
    LazyVStack(spacing: 0) {
      EnumeratedForEach(data: stack.items[..<maxItems]) { (element, index) in
        CollapsedStackItem(maxItems: maxItems, index: index, open: open) {
          PasteStackItemView(
            stack: self.stack,
            item: element,
            index: indexTagFor(index),
            isSelected: appState.navigator.pasteStackSelected
          )
          .opacity(index > 0 ? 0 : 1)
          .background(
            appState.navigator.pasteStackSelected
              ? Color.accentColor.opacity(0.8)
              : Color(nsColor: .tertiarySystemFill).opacity(0.8)
          )
          .background(.thinMaterial)
          .clipShape(SelectionAppearance.none.rect(cornerRadius: Popup.cornerRadius))
          .shadow(
            color: Color(.sRGBLinear, white: 0, opacity: open ? 0 : 0.1),
            radius: 2,
            y: 2
          )
        }
      }
    }
    .hoverSelectionId(stack.id)
  }
}


/// Shared, visible actions for the list and the shelf's temporary selection mode.
struct PasteSelectionControls: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    HStack(spacing: 12) {
      if appState.navigator.isMultiSelectInProgress {
        Text("已选 \(appState.navigator.selection.count) 条")
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("paste-selection-count")
        Button("开始顺序粘贴") { appState.startSelectedPasteStack() }
          .disabled(appState.navigator.selection.isEmpty)
          .accessibilityIdentifier("start-paste-stack")
          .help("按选择编号依次准备内容，返回目标应用后连续按 ⌘V。")
        Button("取消") { appState.cancelMultiSelection() }
          .accessibilityIdentifier("cancel-multiple-selection")
      } else if let stack = appState.history.pasteStack {
        Label("队列剩余 \(stack.items.count) 条", systemImage: "square.stack")
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("paste-stack-count")
        Spacer(minLength: 0)
        Button("停止顺序粘贴") { appState.removePasteStack() }
          .accessibilityIdentifier("stop-paste-stack")
      } else {
        Button("选择多条…", systemImage: "checkmark.circle") { appState.beginMultiSelection() }
          .disabled(appState.history.items.isEmpty)
          .accessibilityIdentifier("begin-multiple-selection")
          .help("点击后逐项选择，或按 ⇧↑↓ 扩展选择；回车启动顺序粘贴。")
        Spacer(minLength: 0)
      }
    }
    .font(.system(size: 12))
    .buttonStyle(.borderless)
    .frame(minHeight: 28)
  }
}
