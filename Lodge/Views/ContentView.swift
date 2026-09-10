import Defaults
import SwiftData
import SwiftUI

struct ContentView: View {
  @State private var appState = AppState.shared
  @State private var modifierFlags = ModifierFlags()
  @State private var scenePhase: ScenePhase = .background
  @Default(.compactView) private var compactView

  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      storageNotice
      mainContent
    }
    .onAppear {
      searchFocused = true
      adjustWindowSize()
    }
    .onMouseMove { appState.isKeyboardNavigating = false }
    .onChange(of: compactView) { adjustWindowSize() }
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
        .background(VisualEffectView(material: .sidebar))
    } else {
      HistorySplitView {
        listContent
          .environment(appState)
          .environment(modifierFlags)
          .environment(\.scenePhase, scenePhase)
      } detail: {
        DetailPanelView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(nsColor: .textBackgroundColor))
          .environment(appState)
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
          .padding(.horizontal, 8)
          .padding(.bottom, 8)
      }
    }
  }

}

#Preview {
  ContentView()
    .environment(\.locale, .init(identifier: "en"))
    .modelContainer(Storage.shared.container)
}

// AppKit owns the sidebar material, divider, and resize constraints.
struct HistorySplitView<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
  @ViewBuilder var sidebar: () -> Sidebar
  @ViewBuilder var detail: () -> Detail

  func makeNSViewController(context: Context) -> HistorySplitController<Sidebar, Detail> {
    HistorySplitController(sidebar: sidebar(), detail: detail())
  }

  func updateNSViewController(_ controller: HistorySplitController<Sidebar, Detail>, context: Context) {
    controller.sidebarController.rootView = sidebar()
    controller.detailController.rootView = detail()
  }
}

final class HistorySplitController<Sidebar: View, Detail: View>: NSSplitViewController {
  let sidebarController: NSHostingController<Sidebar>
  let detailController: NSHostingController<Detail>
  private var hasRestoredWidth = false
  private var isRestoringWidth = false
  private let initialSidebarWidth = Defaults[.listWidth]

  init(sidebar: Sidebar, detail: Detail) {
    sidebarController = NSHostingController(rootView: sidebar)
    detailController = NSHostingController(rootView: detail)
    super.init(nibName: nil, bundle: nil)
    sidebarController.sizingOptions = []
    detailController.sizingOptions = []
    sidebarController.safeAreaRegions = []
    detailController.safeAreaRegions = []
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    splitView.isVertical = true
    splitView.dividerStyle = .thin
    let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
    sidebar.minimumThickness = 220
    sidebar.maximumThickness = NSSplitViewItem.unspecifiedDimension
    sidebar.automaticMaximumThickness = NSSplitViewItem.unspecifiedDimension
    sidebar.canCollapse = false
    // Keep the sidebar width on window resize, but let divider dragging take priority.
    sidebar.holdingPriority = NSLayoutConstraint.Priority(260)
    let detail = NSSplitViewItem(viewController: detailController)
    detail.minimumThickness = 260
    addSplitViewItem(sidebar)
    addSplitViewItem(detail)
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    guard !hasRestoredWidth, !isRestoringWidth, view.window != nil else { return }
    isRestoringWidth = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      defer { self.isRestoringWidth = false }
      guard self.splitView.bounds.width >= 481 else { return }
      let maximum = self.splitView.bounds.width - self.splitView.dividerThickness - 260
      self.splitView.setPosition(min(max(self.initialSidebarWidth, 220), maximum), ofDividerAt: 0)
      self.splitView.layoutSubtreeIfNeeded()
      self.hasRestoredWidth = true
    }
  }

  override func splitViewDidResizeSubviews(_ notification: Notification) {
    super.splitViewDidResizeSubviews(notification)
    guard hasRestoredWidth else { return }
    Defaults[.listWidth] = sidebarController.view.frame.width
  }
}
