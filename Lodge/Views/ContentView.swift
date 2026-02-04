import Defaults
import SwiftData
import SwiftUI

struct ContentView: View {
  @State private var appState = AppState.shared
  @State private var modifierFlags = ModifierFlags()
  @State private var scenePhase: ScenePhase = .background

  @FocusState private var searchFocused: Bool

  var body: some View {
    ZStack {
      if #available(macOS 26.0, *) {
        GlassEffectView()
      } else {
        VisualEffectView()
      }

      mainContent
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
        .task {
          try? await appState.history.load()
        }
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
    guard let window = NSApp.windows.first(where: {
      $0.identifier?.rawValue == Bundle.main.bundleIdentifier
    }) else { return }

    let minWidth: CGFloat = 700
    if window.frame.width < minWidth {
      var newSize = Defaults[.windowSize]
      newSize.width = max(newSize.width, minWidth)
      Defaults[.windowSize] = newSize
      window.setContentSize(newSize)
    }
  }

  @ViewBuilder
  private var mainContent: some View {
    HStack(spacing: 0) {
      // Left column: list view (fixed width)
      VStack(alignment: .leading, spacing: 0) {
        KeyHandlingView(searchQuery: $appState.history.searchQuery, searchFocused: $searchFocused) {
          HeaderView(
            searchFocused: $searchFocused,
            searchQuery: $appState.history.searchQuery
          )

          HistoryListView(
            searchQuery: $appState.history.searchQuery,
            searchFocused: $searchFocused
          )

          FooterView(footer: appState.footer)
        }
      }
      .frame(width: 300)

      Divider()

      // Right column: detail panel (flexible, text wraps)
      DetailPanelView()
        .frame(maxWidth: .infinity)
    }
    .frame(minWidth: 600)
  }
}

#Preview {
  ContentView()
    .environment(\.locale, .init(identifier: "en"))
    .modelContainer(Storage.shared.container)
}
