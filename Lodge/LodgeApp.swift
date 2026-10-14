import SwiftUI

/// The same binary runs the app or, with `--embedding-helper`, the semantic search model.
@main
enum LodgeMain {
  static func main() {
    if EmbeddingHelper.requested { EmbeddingHelper.main() }
    LodgeApp.main()
  }
}

struct LodgeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  // It's impossible to create sceneless application,
  // so we are hacking this around by creating a menubar
  // scene that is always hidden.
  @State private var hiddenMenu: Bool = false

  var body: some Scene {
    MenuBarExtra("", isInserted: $hiddenMenu) {
      EmptyView()
    }
  }
}
