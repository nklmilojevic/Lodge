import AppKit
import Defaults
import SwiftData
import XCTest
@testable import Lodge

/// End-to-end checks with the real EmbeddingGemma 2 model. They run only with TEST_RUNNER_LODGE_MODEL_TESTS=1 and the
/// model installed in Application Support.
@MainActor
final class SemanticModelTests: XCTestCase {
  var history: History!
  var container: ModelContainer!
  let savedSearchMode = Defaults[.searchMode]
  let savedSize = Defaults[.size]
  let savedGrouping = Defaults[.groupSimilarItems]

  override func setUp() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["LODGE_MODEL_TESTS"] != nil, "Model tests are off.")
    let store = SemanticModelStore()
    try XCTSkipUnless(store.capability == .textAndImages, "The model is not installed.")
    container = try ModelContainer(for: HistoryItem.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    history = History(repository: HistoryRepository(context: container.mainContext), observePreferences: false,
                      makeSearchPlan: { _ in throw AskSearchError.unavailable },
                      semantic: SemanticEngine(store: store))
    Defaults[.searchMode] = .ask
    Defaults[.size] = 200
    Defaults[.groupSimilarItems] = false
  }

  override func tearDown() {
    history?.stop()
    Defaults[.searchMode] = savedSearchMode
    Defaults[.size] = savedSize
    Defaults[.groupSimilarItems] = savedGrouping
  }

  private let corpus = [
    "EACCES: permission denied, open '/usr/local/lib/node_modules/.package-lock.json'",
    "Error: listen EADDRINUSE: address already in use :::3000",
    "git push origin feature/semantic-search --force-with-lease",
    "kubectl get pods -n monitoring -o wide",
    "SELECT id, email FROM users WHERE created_at > NOW() - INTERVAL '7 days';",
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    "2 cups flour, 1 tsp baking soda, 3 eggs, 200g sugar. Bake at 180°C for 25 minutes.",
    "Meeting moved to Thursday 3pm, room 4B. Please bring the Q3 numbers.",
    "Hi Ana, thanks for the quick reply! I'll send the contract over by Friday.",
    "Knez Mihailova 12, 11000 Beograd, Serbia",
    "Invoice #INV-2026-0042 total due: $1,240.00 by 2026-11-01",
    "Flight LH1411 departs BEG 06:40, arrives FRA 08:55. Gate C14.",
    "Remember to buy milk, eggs, bread and coffee beans",
    "docker run -p 8080:80 -v $(pwd):/usr/share/nginx/html nginx:alpine",
    "The quarterly revenue grew 18% year over year, driven by enterprise subscriptions.",
    "To be, or not to be, that is the question.",
    "The mitochondria is the powerhouse of the cell.",
    "brew install --cask lodge",
    "Thank you for your order! Your package will arrive Tuesday.",
    "Dependencies: Defaults, KeyboardShortcuts, Fuse, Sparkle, Sauce, SwiftSoup",
    "Meeting moved to Friday 3pm, room 4B. Please bring the Q3 numbers."
  ]

  private func add(_ contents: [ContentSnapshot]) throws -> HistoryItemDecorator {
    try history.add(ContentProcessor.prepare(CapturedCopy(contents: contents, application: nil, copiedAt: Date(),
                                                          changeCount: 0)))
  }

  private func image(_ color: NSColor) throws -> ContentSnapshot {
    let data = try XCTUnwrap(NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
      color.setFill(); rect.fill(); return true
    }.tiffRepresentation)
    return ContentSnapshot(type: NSPasteboard.PasteboardType.tiff.rawValue, value: data)
  }

  private func ask(_ query: String) async -> [String] {
    history.searchQuery = query
    _ = history.submitAskIfNeeded()
    await history.waitForSearch()
    return history.items.map { $0.hasImage ? "<image>" : $0.title }
  }

  func testRealModelSearchesNeighborsAndGroups() async throws {
    var items: [String: HistoryItemDecorator] = [:]
    for text in corpus {
      items[text] = try add([ContentSnapshot(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8))])
    }
    let red = try add([image(.red)])
    _ = try add([image(.blue)])
    let started = Date()
    await history.waitForEmbeddings()
    print("Embedded \(history.semanticIndex.count) items in \(Date().timeIntervalSince(started)) s")
    XCTAssertEqual(history.semanticIndex.count, corpus.count + 2)

    for query in ["cake recipe", "port already used", "flight to Frankfurt", "groceries", "address in Belgrade",
                  "INV-2026-0042", "a red picture"] {
      let results = await ask(query)
      print("\(query) -> \(results.prefix(3))")
    }
    let cake = await ask("cake recipe")
    XCTAssertEqual(cake.first, items[corpus[6]]?.title)
    let port = await ask("port already used")
    XCTAssertEqual(port.first, items[corpus[1]]?.title)
    let invoice = await ask("INV-2026-0042")
    XCTAssertEqual(invoice.first, items[corpus[10]]?.title)
    let redResults = await ask("a red picture")
    XCTAssertEqual(history.items.first?.id, red.id, "\(redResults)")

    history.searchQuery = ""
    let friday = try XCTUnwrap(items[corpus[20]])
    XCTAssertEqual(history.versions(of: friday).map(\.id), [items[corpus[7]]!.id])
  }
}
