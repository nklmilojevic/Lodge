import Defaults
import SwiftUI

struct HistoryListView: View {
  @Binding var searchQuery: String
  @FocusState.Binding var searchFocused: Bool

  @Environment(AppState.self) private var appState
  @Environment(ModifierFlags.self) private var modifierFlags
  @Environment(\.scenePhase) private var scenePhase
  @Default(.pinTo) private var pinTo
  @Default(.popupFontSize) private var fontSize

  private var pinnedItems: [HistoryItemDecorator] { appState.history.visiblePinnedItems }
  private var unpinnedItems: [HistoryItemDecorator] { appState.history.visibleUnpinnedItems }
  private var rowHeight: CGFloat { max(28, CGFloat(fontSize) + 12) }

  var body: some View {
    GeometryReader { geometry in
      let pinnedHeight = min(CGFloat(pinnedItems.count) * rowHeight + 16, geometry.size.height * 0.4)
      VStack(spacing: 0) {
        if pinnedItems.isEmpty {
          historyList(unpinnedItems)
        } else if unpinnedItems.isEmpty {
          historyList(pinnedItems)
        } else {
          if pinTo == .top {
            historyList(pinnedItems).frame(height: pinnedHeight)
            Divider()
          }
          historyList(unpinnedItems)
          if pinTo == .bottom {
            Divider()
            historyList(pinnedItems).frame(height: pinnedHeight)
          }
        }
      }
      .task(id: pinnedHeight) {
        appState.popup.pinnedItemsHeight = pinnedItems.isEmpty ? 0 : pinnedHeight
      }
    }
    .onChange(of: scenePhase) {
      if scenePhase == .active {
        searchFocused = true
        appState.isKeyboardNavigating = true
        appState.selection = appState.history.unpinnedItems.first?.id ?? appState.history.pinnedItems.first?.id
      } else {
        modifierFlags.flags = []
        appState.isKeyboardNavigating = true
      }
    }
  }

  private func historyList(_ items: [HistoryItemDecorator]) -> some View {
    ScrollViewReader { proxy in
      List(selection: Binding<UUID?>(
        get: { appState.history.selectedItem?.id },
        set: { if let id = $0 { appState.selection = id } }
      )) {
        ForEach(items) { item in
          HistoryItemView(item: item)
            .tag(item.id)
        }
      }
      .listStyle(.sidebar)
      .environment(\.defaultMinListRowHeight, rowHeight)
      .task(id: appState.scrollTarget) {
        guard let selection = appState.scrollTarget, items.contains(where: { $0.id == selection }) else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        proxy.scrollTo(selection)
        if appState.scrollTarget == selection { appState.scrollTarget = nil }
      }
    }
  }
}
