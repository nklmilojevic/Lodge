import XCTest
import SwiftData
import Defaults
@testable import Lodge

@MainActor
final class MigrationTests: XCTestCase {
  func testLegacyStoreKeepsItemsPinsAndContent() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "Storage.sqlite")
    try createLegacyStore(at: url)
    let container = try ModelContainer(for: HistoryItem.self, configurations: ModelConfiguration(url: url))
    let service = HistoryService(repository: HistoryRepository(context: container.mainContext))
    try await service.load()
    XCTAssertEqual(service.items.count, 3)
    XCTAssertEqual(Set(service.items.map(\.uuid)).count, 3)
    XCTAssertEqual(service.items.filter { $0.pin == "b" }.count, 1)
    XCTAssertEqual(service.items.first { $0.pin == "b" }?.title, "Saved pin")
    XCTAssertTrue(service.items.allSatisfy { $0.searchText?.hasSuffix("needle") == true })
    XCTAssertTrue(service.items.allSatisfy { $0.previewText?.count == 5_000 })
    XCTAssertTrue(service.items.allSatisfy { $0.normalizedSearchText != nil })
    XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<HistoryItemContent>()), 3)
  }

  private func createLegacyStore(at url: URL) throws {
    let schema = Schema(LegacySchema.models)
    let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
    for index in 0..<3 {
      let item = LegacySchema.HistoryItem()
      container.mainContext.insert(item)
      item.title = index == 0 ? "Saved pin" : "Clip \(index)"
      item.pin = index == 0 ? "b" : nil
      let content = LegacySchema.HistoryItemContent()
      content.type = NSPasteboard.PasteboardType.string.rawValue
      content.value = Data(("\(index) " + String(repeating: "x", count: 20_000) + " needle").utf8)
      item.contents = [content]
    }
    try container.mainContext.save()
  }
}

private enum LegacySchema: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
  static var models: [any PersistentModel.Type] { [HistoryItem.self, HistoryItemContent.self] }

  @Model
  final class HistoryItem {
    var application: String?
    var firstCopiedAt: Date = Date.now
    var lastCopiedAt: Date = Date.now
    var numberOfCopies: Int = 1
    var pin: String?
    var title = ""
    var ocrText: String?
    var contentFingerprint = ""
    var characterCount: Int = 0
    var wordCount: Int = 0
    @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
    var contents: [HistoryItemContent] = []
    init() {}
  }

  @Model
  final class HistoryItemContent {
    var type: String = ""
    @Attribute(.externalStorage) var value: Data?
    @Relationship var item: HistoryItem?
    init() {}
  }
}
