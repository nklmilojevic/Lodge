import Defaults
import SwiftData
import SwiftUI

struct ContentView: View {
  @State private var appState = AppState.shared
  @State private var modifierFlags = ModifierFlags()
  @State private var scenePhase: ScenePhase = .background
  @Default(.compactView) private var compactView
  @Default(.listWidth) private var listWidth
  @State private var dragStartWidth: Double?

  @FocusState private var searchFocused: Bool

  var body: some View {
    ZStack {
      if #available(macOS 26.0, *) {
        GlassEffectView()
      } else {
        VisualEffectView()
      }

      VStack(spacing: 0) {
        storageNotice
        mainContent
      }
        .animation(.default.speed(3), value: appState.history.items.count)
        .animation(.easeInOut(duration: 0.2), value: appState.searchVisible)
        .padding(.vertical, Popup.verticalPadding)
        .padding(.horizontal, Popup.horizontalPadding)
        .onAppear {
          searchFocused = true
          adjustWindowSize()
        }
        .onMouseMove {
          appState.isKeyboardNavigating = false
        }
        .onChange(of: compactView) { adjustWindowSize() }
    }
    .environment(appState)
    .environment(modifierFlags)
    .environment(\.scenePhase, scenePhase)
    // FloatingPanel is not a scene, so let's implement custom scenePhase..
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
      if let window = $0.object as? NSWindow,
         let bundleIdentifier = Bundle.main.bundleIdentifier,
         window.identifier == NSUserInterfaceItemIdentifier(bundleIdentifier) {
        scenePhase = .active
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
      if let window = $0.object as? NSWindow,
         let bundleIdentifier = Bundle.main.bundleIdentifier,
         window.identifier == NSUserInterfaceItemIdentifier(bundleIdentifier) {
        scenePhase = .background
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) {
      if let popover = $0.object as? NSPopover {
        // Prevent NSPopover from showing close animation when
        // quickly toggling FloatingPanel while popover is visible.
        popover.animates = false
        // Prevent NSPopover from becoming first responder.
        popover.behavior = .semitransient
      }
    }
  }

  private func adjustWindowSize() {
    appState.appDelegate?.panel.applyLayout()
  }

  @ViewBuilder
  private var storageNotice: some View {
    if appState.history.temporaryStorage {
      Label("History is in temporary storage. New copies will be lost when Lodge quits.", systemImage: "exclamationmark.triangle")
        .font(.callout)
        .foregroundStyle(.orange)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    if appState.history.exceedsDataLimit {
      Text("Pinned items exceed the history data limit. Remove pins or increase the limit in Storage settings.")
        .font(.callout).foregroundStyle(.orange).padding(8)
    }
    if let error = appState.history.errorMessage {
      HStack(alignment: .top) {
        Text(error).font(.callout).foregroundStyle(.red)
        Spacer()
        if !appState.history.isLoaded {
          Button("Retry") { Task { try? await appState.history.load() } }
        }
        Button("Dismiss") { appState.history.errorMessage = nil }
      }
      .padding(8)
    }
  }

  @ViewBuilder
  private var mainContent: some View {
    if compactView {
      listContent
        .frame(minWidth: 280)
    } else {
      GeometryReader { geometry in
        HStack(spacing: 0) {
          listContent.frame(width: min(max(listWidth, 220), max(220, geometry.size.width - 260)))
          Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 5)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
              .onChanged { value in
                if dragStartWidth == nil { dragStartWidth = listWidth }
                listWidth = min(max((dragStartWidth ?? listWidth) + value.translation.width, 220),
                                max(220, geometry.size.width - 260))
              }
              .onEnded { _ in dragStartWidth = nil })
            .accessibilityLabel("List width")
            .accessibilityAdjustableAction { direction in
              switch direction {
              case .increment: listWidth = min(listWidth + 20, geometry.size.width - 260)
              case .decrement: listWidth = max(220, listWidth - 20)
              @unknown default: break
              }
            }
          DetailPanelView().frame(maxWidth: .infinity)
        }
      }
      .frame(minWidth: 540)
    }
  }

  private var listContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      KeyHandlingView(searchQuery: $appState.history.searchQuery, searchFocused: $searchFocused) {
        HeaderView(searchFocused: $searchFocused, searchQuery: $appState.history.searchQuery)
        HistoryListView(searchQuery: $appState.history.searchQuery, searchFocused: $searchFocused)
        FooterView(footer: appState.footer)
      }
    }
  }

}

#Preview {
  ContentView()
    .environment(\.locale, .init(identifier: "en"))
    .modelContainer(Storage.shared.container)
}
