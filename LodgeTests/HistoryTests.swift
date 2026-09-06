import XCTest
import Defaults
import SwiftData
@testable import Lodge

@MainActor
final class HistoryTests: XCTestCase {
  var history: History!
  var container: ModelContainer!
  let savedSize = Defaults[.size]
  let savedSortBy = Defaults[.sortBy]
  let savedOCR = Defaults[.ocrInImages]
  let savedLimit = Defaults[.historyDataLimitMB]

  override func setUpWithError() throws {
    container = try ModelContainer(for: HistoryItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    history = History(repository: HistoryRepository(context: container.mainContext), observePreferences: false)
    Defaults[.size] = 10
    Defaults[.sortBy] = .firstCopiedAt
    Defaults[.ocrInImages] = false
    Defaults[.historyDataLimitMB] = 512
  }

  override func tearDown() {
    history.stop()
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    Defaults[.ocrInImages] = savedOCR
    Defaults[.historyDataLimitMB] = savedLimit
  }

  func testDefaultIsEmpty() { XCTAssertTrue(history.items.isEmpty) }

  func testAdding() throws {
    let first = try add("foo")
    let second = try add("bar")
    XCTAssertEqual(history.items, [second, first])
  }

  func testAddingSame() throws {
    let first = try add("foo", title: "xyz")
    history.togglePin(first)
    let pin = first.item.pin
    let second = try add("bar")
    let duplicate = try add("foo")
    XCTAssertTrue(first === duplicate)
    XCTAssertEqual(history.items, [first, second])
    XCTAssertEqual(first.item.numberOfCopies, 2)
    XCTAssertEqual(first.item.pin, pin)
    XCTAssertEqual(first.item.title, "xyz")
    XCTAssertGreaterThan(first.item.lastCopiedAt, first.item.firstCopiedAt)
  }

  func testAddingItemThatIsSupersededByExisting() throws {
    let contents = [ContentSnapshot(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("one".utf8)),
                    ContentSnapshot(type: NSPasteboard.PasteboardType.rtf.rawValue, value: Data("two".utf8))]
    let first = try add(contents)
    let second = try add([contents[0]])
    XCTAssertTrue(first === second)
    XCTAssertEqual(history.items.count, 1)
    XCTAssertEqual(second.item.snapshot.sorted { $0.type < $1.type }, contents.sorted { $0.type < $1.type })
  }

  func testAddingItemWithDifferentModifiedType() throws {
    let first = try add([ContentSnapshot(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("one".utf8)),
                         ContentSnapshot(type: NSPasteboard.PasteboardType.modified.rawValue, value: Data("12".utf8))])
    let second = try add([ContentSnapshot(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("one".utf8)),
                          ContentSnapshot(type: NSPasteboard.PasteboardType.modified.rawValue, value: Data("13".utf8))])
    XCTAssertTrue(first === second)
    XCTAssertEqual(history.items.count, 1)
    XCTAssertEqual(second.item.modified, 12)
  }

  func testAddingItemFromLodge() throws {
    let first = try add("one")
    let second = try add([ContentSnapshot(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("one".utf8)),
                          ContentSnapshot(type: NSPasteboard.PasteboardType.fromLodge.rawValue, value: Data())])
    XCTAssertTrue(first === second)
    XCTAssertEqual(second.item.application, "com.apple.dt.Xcode")
  }

  func testModifiedAfterCopying() throws {
    let first = try add("foo", changeCount: 42)
    let second = try add([ContentSnapshot(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("bar".utf8)),
                          ContentSnapshot(type: NSPasteboard.PasteboardType.modified.rawValue, value: Data("42".utf8))])
    XCTAssertTrue(first === second)
    XCTAssertEqual(history.items, [second])
    XCTAssertEqual(second.text, "bar")
  }

  func testClearingUnpinned() throws {
    let pinned = try add("foo")
    history.togglePin(pinned)
    _ = try add("bar")
    XCTAssertTrue(history.clear())
    XCTAssertEqual(history.items, [pinned])
  }

  func testClearingAll() throws {
    let pinned = try add("foo")
    history.togglePin(pinned)
    XCTAssertTrue(history.clearAll())
    XCTAssertTrue(history.items.isEmpty)
  }

  func testMaxSize() throws {
    let first = try add("0")
    for index in 1...10 { _ = try add(String(index)) }
    XCTAssertEqual(history.items.count, 10)
    XCTAssertFalse(history.items.contains(first))
  }

  func testMaxSizeIgnoresPinned() throws {
    let pinned = try add("0")
    history.togglePin(pinned)
    for index in 1...11 { _ = try add(String(index)) }
    XCTAssertEqual(history.items.count, 11)
    XCTAssertTrue(history.items.contains(pinned))
    XCTAssertFalse(history.items.contains { $0.text == "1" })
  }

  func testMaxSizeIsChanged() throws {
    for index in 0...10 { _ = try add(String(index)) }
    Defaults[.size] = 5
    history.enforceLimits()
    XCTAssertEqual(history.items.count, 5)
    XCTAssertEqual(history.items.first?.text, "10")
  }

  func testRemoving() throws {
    let foo = try add("foo")
    let bar = try add("bar")
    XCTAssertTrue(history.delete(foo))
    XCTAssertEqual(history.items, [bar])
  }

  func testDuplicateMovesToTopWhenSortingByLastCopy() throws {
    Defaults[.sortBy] = .lastCopiedAt
    let older = try add("older")
    _ = try add("newer")
    let duplicate = try add("older")
    XCTAssertEqual(history.items.first, older)
    XCTAssertTrue(older === duplicate)
  }

  func testDuplicateMovesToTopWhenSortingByCopyCount() throws {
    Defaults[.sortBy] = .numberOfCopies
    let older = try add("older")
    _ = try add("newer")
    _ = try add("newer")
    _ = try add("older")
    _ = try add("older")
    XCTAssertEqual(history.items.first, older)
    XCTAssertEqual(older.item.numberOfCopies, 3)
  }

  func testPositionValidationRejectsEveryOutOfBoundsValue() throws {
    XCTAssertEqual(try HistoryItemPosition.index(number: 1, count: 2), 0)
    XCTAssertEqual(try HistoryItemPosition.index(number: 2, count: 2), 1)
    for number in [0, -1, 3] { XCTAssertThrowsError(try HistoryItemPosition.index(number: number, count: 2)) }
    XCTAssertThrowsError(try HistoryItemPosition.index(number: 1, count: 0))
  }

  func testLoadReturnsAllItemsBeyondTheOldFirstPage() async throws {
    Defaults[.size] = 150
    for index in 0..<150 { _ = try add(String(index)) }
    let loaded = History(repository: HistoryRepository(context: container.mainContext), observePreferences: false)
    defer { loaded.stop() }
    try await loaded.load()
    XCTAssertEqual(loaded.items.count, 150)
  }

  func testFullTextSearchAndLatestQueryWins() async throws {
    let long = try add(String(repeating: "x", count: 8_000) + " find-me")
    _ = try add("different")
    history.searchQuery = "different"
    history.searchQuery = "find-me"
    await history.waitForSearch()
    XCTAssertEqual(history.items, [long])
    XCTAssertTrue(long.isTextTruncated)
    XCTAssertEqual(long.text.count, 5_000)
    XCTAssertTrue(long.fullText.hasSuffix("find-me"))
  }

  func testEditingPinnedContentInvalidatesSearchResults() async throws {
    let item = try add("before")
    history.togglePin(item)
    history.searchQuery = "after"
    await history.waitForSearch()
    XCTAssertTrue(history.items.isEmpty)
    await history.edit(item.item, text: "after")
    await history.waitForSearch()
    XCTAssertEqual(history.items, [item])
    XCTAssertEqual(item.characterCount, 5)
  }

  func testRejectedUnpinKeepsTheItemAndShowsTheLimitError() throws {
    let item = try add(String(repeating: "a", count: 600_000))
    history.togglePin(item)
    let pin = item.item.pin
    Defaults[.historyDataLimitMB] = 1
    history.enforceLimits()

    history.togglePin(item)

    XCTAssertEqual(history.items, [item])
    XCTAssertEqual(item.item.pin, pin)
    XCTAssertTrue(history.errorMessage?.contains("history limit") == true)
  }

  private func add(_ text: String, changeCount: Int = 0, title: String? = nil) throws -> HistoryItemDecorator {
    try add([ContentSnapshot(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8))],
            changeCount: changeCount, title: title)
  }

  private func add(_ contents: [ContentSnapshot], changeCount: Int = 0, title: String? = nil) throws -> HistoryItemDecorator {
    let capture = CapturedCopy(contents: contents, application: "com.apple.dt.Xcode", copiedAt: Date(), changeCount: changeCount)
    return try history.add(ContentProcessor.prepare(capture), title: title)
  }
}
