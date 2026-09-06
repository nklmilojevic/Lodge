import XCTest
import Defaults
import SwiftData
@testable import Lodge

@MainActor
final class HistoryServiceTests: XCTestCase {
  enum TestError: Error { case save }
  var container: ModelContainer!
  var repository: HistoryRepository!
  var service: HistoryService!
  var failSave = false
  var saves = 0
  let savedSize = Defaults[.size]
  let savedLimit = Defaults[.historyDataLimitMB]

  override func setUpWithError() throws {
    container = try ModelContainer(for: HistoryItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    repository = HistoryRepository(context: container.mainContext) { [unowned self] context in
      self.saves += 1
      if self.failSave { throw TestError.save }
      try context.save()
    }
    service = HistoryService(repository: repository)
    Defaults[.size] = 10
    Defaults[.historyDataLimitMB] = 512
  }

  override func tearDown() {
    Defaults[.size] = savedSize
    Defaults[.historyDataLimitMB] = savedLimit
  }

  func testDuplicateUsesOneSaveAndKeepsItsContentRows() throws {
    let item = try service.add(prepared("same"))
    let contents = item.contents.map(\.persistentModelID)
    saves = 0
    let duplicate = try service.add(prepared("same"))
    XCTAssertTrue(item === duplicate)
    XCTAssertEqual(saves, 1)
    XCTAssertEqual(duplicate.contents.map(\.persistentModelID), contents)
    XCTAssertEqual(try repository.context.fetchCount(FetchDescriptor<HistoryItemContent>()), 1)
  }

  func testInsertAndPruneRollbackTogether() throws {
    Defaults[.size] = 1
    let first = try service.add(prepared("first"))
    failSave = true
    XCTAssertThrowsError(try service.add(prepared("second")))
    XCTAssertEqual(service.items, [first])
    XCTAssertEqual(try repository.fetchAll().map(\.previewableText), ["first"])
    XCTAssertEqual(try repository.context.fetchCount(FetchDescriptor<HistoryItemContent>()), 1)
  }

  func testDuplicateCounterRollback() throws {
    let item = try service.add(prepared("same"))
    let copiedAt = item.lastCopiedAt
    failSave = true
    XCTAssertThrowsError(try service.add(prepared("same")))
    XCTAssertEqual(item.numberOfCopies, 1)
    XCTAssertEqual(item.lastCopiedAt, copiedAt)
    XCTAssertEqual(try repository.fetchAll().count, 1)
  }

  func testFailedDeleteKeepsDisplayedHistory() throws {
    let history = History(repository: repository, observePreferences: false)
    defer { history.stop() }
    let item = try history.add(prepared("keep"))
    failSave = true
    XCTAssertFalse(history.delete(item))
    XCTAssertEqual(history.items, [item])
    XCTAssertNotNil(history.errorMessage)
    XCTAssertEqual(try repository.fetchAll().count, 1)
  }

  func testModifiedContentIsReplacedWithoutOrphans() throws {
    let original = try service.add(prepared("before", changeCount: 24))
    let capture = CapturedCopy(contents: [
      ContentSnapshot(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("after".utf8)),
      ContentSnapshot(type: NSPasteboard.PasteboardType.modified.rawValue, value: Data("24".utf8))
    ], application: nil, copiedAt: Date(), changeCount: 25)
    let changed = try service.add(ContentProcessor.prepare(capture))
    XCTAssertTrue(original === changed)
    XCTAssertEqual(changed.previewableText, "after")
    XCTAssertEqual(try repository.context.fetchCount(FetchDescriptor<HistoryItemContent>()), 2)
    XCTAssertEqual(try repository.context.fetch(FetchDescriptor<HistoryItemContent>()).filter { $0.item == nil }.count, 0)
  }

  func testContentLimitPrunesOldestUnpinnedItem() throws {
    Defaults[.historyDataLimitMB] = 1
    let first = try service.add(prepared(String(repeating: "a", count: 165_000)))
    let second = try service.add(prepared(String(repeating: "b", count: 165_000)))
    let third = try service.add(prepared(String(repeating: "c", count: 165_000)))
    XCTAssertFalse(service.items.contains(first))
    XCTAssertTrue(service.items.contains(second))
    XCTAssertTrue(service.items.contains(third))
    XCTAssertLessThanOrEqual(service.byteCount, service.byteLimit)
  }

  func testOversizeCopyDoesNotDeleteExistingHistory() throws {
    let first = try service.add(prepared("keep"))
    Defaults[.historyDataLimitMB] = 1
    XCTAssertThrowsError(try service.add(prepared(String(repeating: "x", count: 600_000))))
    XCTAssertEqual(service.items, [first])
    XCTAssertEqual(try repository.fetchAll().count, 1)
  }

  func testPinnedItemsSurviveLimitReduction() throws {
    let item = try service.add(prepared(String(repeating: "x", count: 600_000)))
    try service.setPin("b", for: item)
    Defaults[.historyDataLimitMB] = 1
    try service.enforceLimits()
    XCTAssertEqual(service.items, [item])
    XCTAssertGreaterThan(service.byteCount, service.byteLimit)
  }

  func testLegacyTextMetadataIsBackfilled() async throws {
    let item = HistoryItem()
    repository.insert(item)
    item.contents = [HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue,
                                       value: Data((String(repeating: "x", count: 6_000) + " needle").utf8))]
    try repository.transaction { }
    try await service.load()
    XCTAssertEqual(item.metadataVersion, 1)
    XCTAssertEqual(item.previewText?.count, 5_000)
    XCTAssertTrue(item.searchText?.hasSuffix("needle") == true)
    XCTAssertFalse(item.contents[0].fingerprint.isEmpty)
  }

  func testLegacyOrphanCleanup() async throws {
    repository.context.insert(HistoryItemContent(type: "public.data", value: Data(repeating: 1, count: 1024)))
    try repository.transaction { }
    try await service.load()
    XCTAssertEqual(try repository.context.fetchCount(FetchDescriptor<HistoryItemContent>()), 0)
  }

  func testLargeContentDeletionOnDisk() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let diskContainer = try ModelContainer(for: HistoryItem.self,
                                           configurations: ModelConfiguration(url: directory.appending(path: "Storage.sqlite")))
    let diskRepository = HistoryRepository(context: diskContainer.mainContext)
    let diskService = HistoryService(repository: diskRepository)
    let capture = CapturedCopy(contents: [ContentSnapshot(type: NSPasteboard.PasteboardType.png.rawValue,
                                                         value: Data(repeating: 7, count: 2 * 1024 * 1024))],
                               application: nil, copiedAt: Date(), changeCount: 1)
    let prepared = ContentProcessor.prepare(capture)
    let original = try diskService.add(prepared)
    func largeFiles() -> [URL] {
      let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
      return (files?.allObjects as? [URL] ?? []).filter {
        ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) >= 2 * 1024 * 1024
      }
    }
    XCTAssertFalse(largeFiles().isEmpty, "The fixture must use an external content file.")
    for _ in 0..<5 { _ = try diskService.add(prepared) }
    XCTAssertEqual(try diskRepository.context.fetchCount(FetchDescriptor<HistoryItemContent>()), 1)
    try diskService.delete([original])
    XCTAssertEqual(try diskRepository.context.fetchCount(FetchDescriptor<HistoryItemContent>()), 0)
    XCTAssertEqual(try diskRepository.fetchAll().count, 0)
    XCTAssertTrue(largeFiles().isEmpty, "Deletion must remove the external content file.")
  }

  func testHTMLParserDoesNotNeedRemoteResources() {
    let html = "<html><head><link href='https://invalid.example/style.css'></head><body><p>A &amp; B</p><img src='https://invalid.example/a.png'><script>secret()</script></body></html>"
    let text = ContentProcessor.plainText([ContentSnapshot(type: NSPasteboard.PasteboardType.html.rawValue,
                                                          value: Data(html.utf8))])
    XCTAssertEqual(text, "A & B")
  }

  func testUnavailableStoreUsesTemporaryStorage() {
    let storage = Storage(makeContainer: { _ in throw TestError.save })
    XCTAssertNotNil(storage.loadError)
    let history = History(repository: HistoryRepository(context: storage.context),
                          temporaryStorage: storage.loadError != nil, observePreferences: false)
    defer { history.stop() }
    XCTAssertTrue(history.temporaryStorage)
  }

  private func prepared(_ text: String, changeCount: Int = 1) -> PreparedCopy {
    ContentProcessor.prepare(CapturedCopy(contents: [ContentSnapshot(type: NSPasteboard.PasteboardType.string.rawValue,
                                                                    value: Data(text.utf8))],
                                          application: nil, copiedAt: Date(), changeCount: changeCount))
  }
}
