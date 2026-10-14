import AppKit
import Defaults
import SwiftData
import XCTest
@testable import Lodge

/// Vectors from named directions, so tests control which items are similar.
@MainActor
final class FakeEmbedder: SemanticEmbedder {
  var capability: SemanticCapability = .text
  var vectorVersion = 1
  var vectors: [String: [Float]] = [:]
  var imageVector: [Float]?
  var documentCalls = 0
  var imageCalls = 0
  var failure: Error?

  nonisolated static func vector(_ weights: [Int: Float]) -> [Float] {
    var vector = [Float](repeating: 0, count: SemanticVectors.dimension)
    for (dimension, weight) in weights { vector[dimension] = weight }
    let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return vector.map { $0 / length }
  }

  /// Unknown text gets its own direction, so unrelated items are orthogonal.
  func vector(for text: String) -> [Float] {
    if let vector = vectors[text] { return vector }
    let dimension = 100 + Int(UInt(bitPattern: text.hashValue) % 600)
    return Self.vector([dimension: 1])
  }

  func prepare() {}

  func embed(query: String) async throws -> [Float] {
    if let failure { throw failure }
    return vector(for: query)
  }

  func embed(documents: [String]) async throws -> [[Float]] {
    if let failure { throw failure }
    documentCalls += 1
    return documents.map(vector(for:))
  }

  func embed(image: ImageSource) async throws -> [Float] {
    imageCalls += 1
    guard let imageVector else { throw SemanticModelError.unreadableImage }
    return imageVector
  }
}

final class SemanticRankingTests: XCTestCase {
  private func ids(_ count: Int) -> [UUID] { (0..<count).map { _ in UUID() } }

  func testVectorsRoundTripAsHalfPrecision() throws {
    let vector = FakeEmbedder.vector([0: 3, 1: 4])
    let data = SemanticVectors.pack(vector)
    XCTAssertEqual(data.count, 1_536)
    let unpacked = try XCTUnwrap(SemanticVectors.unpack(data))
    XCTAssertEqual(unpacked[0], 0.6, accuracy: 0.001)
    XCTAssertEqual(unpacked[1], 0.8, accuracy: 0.001)
    XCTAssertNil(SemanticVectors.unpack(Data([1, 2, 3])))
  }

  func testMeaningStandsOutFromTheQueryAverage() {
    let ids = ids(12)
    var entries = ids.enumerated().map { (id: $1, isImage: false, vector: FakeEmbedder.vector([10 + $0: 1])) }
    entries[3].vector = FakeEmbedder.vector([0: 0.9, 13: 0.1])
    let index = SemanticIndex(entries)
    let meaning = index.meaning(FakeEmbedder.vector([0: 1]))
    XCTAssertEqual(meaning.count, 12)
    let best = meaning.max { $0.value.z < $1.value.z }
    XCTAssertEqual(best?.key, ids[3])
    XCTAssertGreaterThan(meaning[ids[3]]!.z, SemanticRanking.meaningGate)
    XCTAssertLessThan(meaning[ids[0]]!.z, 0)
    XCTAssertEqual(index.meaning(FakeEmbedder.vector([0: 1]), excluding: ids[3]).count, 11)
  }

  func testSmallHistoriesUseTheReferenceLevel() {
    // Cosines like EmbeddingGemma 2's: a match at 0.8, unrelated items near 0.6.
    let ids = ids(3)
    let query = FakeEmbedder.vector([0: 1])
    let entries: [(id: UUID, isImage: Bool, vector: [Float])] = [
      (ids[0], true, FakeEmbedder.vector([0: 0.8, 10: 0.6])),
      (ids[1], false, FakeEmbedder.vector([0: 0.6, 11: 0.8])),
      (ids[2], false, FakeEmbedder.vector([0: 0.62, 12: 0.78]))
    ]
    let meaning = SemanticIndex(entries).meaning(query)
    XCTAssertGreaterThan(meaning[ids[0]]!.z, SemanticRanking.meaningGate)
    XCTAssertLessThan(meaning[ids[1]]!.z, SemanticRanking.meaningGate)
    XCTAssertLessThan(meaning[ids[2]]!.z, SemanticRanking.meaningGate)
    XCTAssertEqual(SemanticIndex([entries[0]]).meaning(query)[ids[0]]!.z, (0.8 - 0.6) / 0.045, accuracy: 0.01)
  }

  func testImageScoresAreCenteredOnTheirOwnModality() {
    // Image vectors sit higher for this query, but only the one that stands out among images should pass.
    var entries: [(id: UUID, isImage: Bool, vector: [Float])] = []
    for offset in 0..<25 { entries.append((UUID(), false, FakeEmbedder.vector([0: 0.1, 200 + offset: 1]))) }
    for offset in 0..<25 { entries.append((UUID(), true, FakeEmbedder.vector([0: 1, 300 + offset: 1]))) }
    let target = UUID()
    entries.append((target, true, FakeEmbedder.vector([0: 3, 400: 1])))
    let meaning = SemanticIndex(entries).meaning(FakeEmbedder.vector([0: 1]))
    let passing = meaning.filter { $0.value.z >= SemanticRanking.meaningGate }.map(\.key)
    XCTAssertEqual(passing, [target])
  }

  func testRankCombinesMeaningAndWordsAndDropsWeakResults() {
    let ids = ids(5)
    let meaning: [UUID: Double] = [ids[0]: 3.5, ids[1]: 0.2, ids[2]: 2.1, ids[3]: 1.9, ids[4]: 0.1]
    let coverage: [UUID: Double] = [ids[1]: 1, ids[3]: 0.25, ids[4]: 0.5]
    let ranked = SemanticRanking.rank(ids, meaning: meaning, coverage: coverage, lookup: false)
    // 3.5 > 2 + 0.2 > 2.1 > 0.1 + 0.71; the last is under half of the top score.
    XCTAssertEqual(ranked, [ids[0], ids[1], ids[2]])
  }

  func testLookupQueriesWeighWordsMore() {
    let ids = ids(2)
    let meaning: [UUID: Double] = [ids[0]: 3, ids[1]: 0]
    let coverage: [UUID: Double] = [ids[1]: 1]
    XCTAssertTrue(SemanticRanking.isLookup(["INV-2026-0042"]))
    XCTAssertFalse(SemanticRanking.isLookup(["invoice"]))
    // Meaning alone falls below half of the exact match's score.
    XCTAssertEqual(SemanticRanking.rank(ids, meaning: meaning, coverage: coverage, lookup: true), [ids[1]])
    XCTAssertEqual(SemanticRanking.rank(ids, meaning: meaning, coverage: coverage, lookup: false), [ids[0], ids[1]])
  }

  func testTermsDropStopwords() {
    XCTAssertEqual(SemanticRanking.terms("Find the recipe I copied from Safari"), ["recipe", "safari"])
    XCTAssertEqual(SemanticRanking.terms("invoice INV-2026-0042, -draft_v2-"), ["invoice", "inv-2026-0042", "draft_v2"])
    XCTAssertTrue(SemanticRanking.isLookup(SemanticRanking.terms("INV-2026-0042")))
  }

  func testNeighborsSeparateVersionsFromRelatedItems() {
    let ids = ids(40)
    var entries = ids.enumerated().map { (id: $1, isImage: false, vector: FakeEmbedder.vector([20 + $0: 1])) }
    entries[0].vector = FakeEmbedder.vector([0: 1, 20: 0.05])
    entries[1].vector = FakeEmbedder.vector([0: 1, 21: 0.1])      // near-duplicate of 0
    entries[2].vector = FakeEmbedder.vector([0: 0.7, 22: 0.7])    // related to 0
    entries[3] = (ids[3], true, FakeEmbedder.vector([0: 1, 23: 0.05]))  // an image, never a version of text
    let neighbors = SemanticRanking.neighbors(of: ids[0], in: SemanticIndex(entries))
    XCTAssertEqual(neighbors.versions, [ids[1]])
    XCTAssertEqual(Set(neighbors.related), Set([ids[2], ids[3]]))
    XCTAssertEqual(SemanticRanking.neighbors(of: UUID(), in: SemanticIndex(entries)).versions, [])
  }

  func testGroupsAttachNearDuplicatesToTheFirstItem() {
    let ids = ids(4)
    let entries: [(id: UUID, isImage: Bool, vector: [Float])] = [
      (ids[0], false, FakeEmbedder.vector([0: 1])),
      (ids[1], false, FakeEmbedder.vector([1: 1])),
      (ids[2], false, FakeEmbedder.vector([0: 1, 5: 0.1])),
      (ids[3], false, FakeEmbedder.vector([0: 1, 6: 0.1]))
    ]
    let heads = SemanticRanking.groups(ids, in: SemanticIndex(entries))
    XCTAssertEqual(heads, [ids[2]: ids[0], ids[3]: ids[0]])
    XCTAssertEqual(SemanticRanking.groups([ids[3], ids[0]], in: SemanticIndex(entries)), [ids[0]: ids[3]])
  }
}

@MainActor
final class SemanticHistoryTests: XCTestCase {
  var history: History!
  var container: ModelContainer!
  var embedder: FakeEmbedder!
  let savedSearchMode = Defaults[.searchMode]
  let savedSize = Defaults[.size]
  let savedSortBy = Defaults[.sortBy]
  let savedOCR = Defaults[.ocrInImages]
  let savedGrouping = Defaults[.groupSimilarItems]

  override func setUpWithError() throws {
    container = try ModelContainer(for: HistoryItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    embedder = FakeEmbedder()
    makeHistory()
    Defaults[.searchMode] = .ask
    Defaults[.size] = 100
    Defaults[.sortBy] = .firstCopiedAt
    Defaults[.ocrInImages] = false
    Defaults[.groupSimilarItems] = false
  }

  override func tearDown() {
    history.stop()
    Defaults[.searchMode] = savedSearchMode
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    Defaults[.ocrInImages] = savedOCR
    Defaults[.groupSimilarItems] = savedGrouping
  }

  private func makeHistory(plan: @escaping @MainActor (String) async throws -> AskSearchPlan = { _ in
    throw AskSearchError.unavailable
  }) {
    history?.stop()
    history = History(repository: HistoryRepository(context: container.mainContext), observePreferences: false,
                      makeSearchPlan: plan, semantic: embedder)
  }

  @discardableResult
  private func add(_ text: String, application: String = "com.apple.Safari") throws -> HistoryItemDecorator {
    let capture = CapturedCopy(contents: [ContentSnapshot(type: NSPasteboard.PasteboardType.string.rawValue,
                                                          value: Data(text.utf8))],
                               application: application, copiedAt: Date(), changeCount: 0)
    return try history.add(ContentProcessor.prepare(capture))
  }

  /// Ten unrelated items, so a match can stand out by meaning.
  private func addFiller() throws {
    for index in 0..<10 { try add("filler \(index)") }
  }

  private func ask(_ query: String) async {
    history.searchQuery = query
    XCTAssertTrue(history.submitAskIfNeeded())
    await history.waitForSearch()
  }

  func testBackfillStoresVectorsOutsideTheDataLimit() async throws {
    let item = try add("chocolate cake recipe")
    try add("   ")
    let bytesBefore = item.item.payloadByteCount
    await history.waitForEmbeddings()
    XCTAssertEqual(item.item.embeddingSource, "text1")
    XCTAssertEqual(item.item.embedding?.count, 1_536)
    XCTAssertEqual(item.item.payloadByteCount, bytesBefore)
    XCTAssertEqual(history.semanticIndex.count, 1)
    XCTAssertEqual(history.semanticProgress.indexed, 1)
    XCTAssertEqual(history.semanticProgress.total, 1)
    let calls = embedder.documentCalls
    history.backfillEmbeddingsIfNeeded()
    await history.waitForEmbeddings()
    XCTAssertEqual(embedder.documentCalls, calls)
  }

  func testEditingClearsTheVectorAndEmbedsAgain() async throws {
    let item = try add("first text")
    await history.waitForEmbeddings()
    embedder.vectors["second text"] = FakeEmbedder.vector([7: 1])
    await history.edit(item.item, text: "second text")
    await history.waitForEmbeddings()
    XCTAssertEqual(history.semanticIndex.vector(for: item.id)?[7] ?? 0, 1, accuracy: 0.001)
  }

  func testAskFindsItemsByMeaningWithFilters() async throws {
    makeHistory(plan: { _ in AskSearchPlan(terms: ["dessert"], application: "Safari") })
    embedder.vectors["2 cups flour, 3 eggs, bake 25 minutes"] = FakeEmbedder.vector([0: 1, 1: 0.2])
    embedder.vectors["dessert"] = FakeEmbedder.vector([0: 1])
    let recipe = try add("2 cups flour, 3 eggs, bake 25 minutes")
    let fromNotes = try add("2 cups flour, 3 eggs, bake 25 minutes ", application: "com.apple.Notes")
    embedder.vectors[fromNotes.item.previewableText] = FakeEmbedder.vector([0: 1, 2: 0.2])
    try addFiller()
    await history.waitForEmbeddings()
    await ask("dessert I copied from Safari")
    XCTAssertEqual(history.items.map(\.id), [recipe.id])
  }

  func testAskWithoutMeaningRequiresEveryTerm() async throws {
    embedder.capability = .none
    makeHistory(plan: { _ in AskSearchPlan(terms: ["dessert"]) })
    try add("2 cups flour, 3 eggs")
    let match = try add("dessert ideas")
    await ask("dessert")
    XCTAssertEqual(history.items.map(\.id), [match.id])
  }

  func testAskSearchesByMeaningWhenFiltersAreUnavailable() async throws {
    embedder.vectors["port 3000 is already in use"] = FakeEmbedder.vector([0: 1])
    embedder.vectors["server will not start"] = FakeEmbedder.vector([0: 0.9, 3: 0.3])
    let item = try add("port 3000 is already in use")
    try addFiller()
    await history.waitForEmbeddings()
    await ask("server will not start")
    XCTAssertEqual(history.items.first?.id, item.id)
    XCTAssertEqual(history.askSearchMessage, "Searched by meaning. Press Return to use the selected item.")
  }

  func testAskUsesExactSearchWhenTheEmbedderFails() async throws {
    embedder.vectors["port 3000 is already in use"] = FakeEmbedder.vector([0: 1])
    try add("port 3000 is already in use")
    let exact = try add("server will not start today")
    try addFiller()
    await history.waitForEmbeddings()
    embedder.failure = SemanticModelError.unavailable
    await ask("server will not start")
    XCTAssertEqual(history.items.map(\.id), [exact.id])
  }

  func testGroupingHidesOlderNearDuplicatesUntilSearching() async throws {
    Defaults[.sortBy] = .lastCopiedAt
    embedder.vectors["Meeting moved to Thursday"] = FakeEmbedder.vector([0: 1, 1: 0.05])
    embedder.vectors["Meeting moved to Friday"] = FakeEmbedder.vector([0: 1, 2: 0.05])
    let older = try add("Meeting moved to Thursday")
    let other = try add("Something else")
    let newer = try add("Meeting moved to Friday")
    await history.waitForEmbeddings()
    history.refreshSearchResults()
    XCTAssertEqual(history.visibleUnpinnedItems.count, 3)
    Defaults[.groupSimilarItems] = true
    history.refreshSearchResults()
    await history.waitForGroups()
    XCTAssertEqual(history.visibleUnpinnedItems.map(\.id), [newer.id, other.id])
    XCTAssertEqual(newer.similarCount, 1)
    XCTAssertNil(history.item(withId: older.id))
    XCTAssertEqual(history.neighbors(of: newer).versions.map(\.id), [older.id])
    Defaults[.searchMode] = .exact
    history.searchQuery = "Meeting"
    await history.waitForSearch()
    XCTAssertEqual(Set(history.visibleUnpinnedItems.map(\.id)), Set([older.id, newer.id]))
    XCTAssertEqual(newer.similarCount, 0)
  }

  func testTheNewestCopyLeadsItsGroupInAnySortOrder() async throws {
    Defaults[.sortBy] = .numberOfCopies
    Defaults[.groupSimilarItems] = true
    embedder.vectors["Meeting moved to Thursday"] = FakeEmbedder.vector([0: 1, 1: 0.05])
    embedder.vectors["Meeting moved to Friday"] = FakeEmbedder.vector([0: 1, 2: 0.05])
    let older = try add("Meeting moved to Thursday")
    try add("Meeting moved to Thursday")
    let newer = try add("Meeting moved to Friday")
    await history.waitForEmbeddings()
    history.refreshSearchResults()
    await history.waitForGroups()
    XCTAssertEqual(history.visibleUnpinnedItems.map(\.id), [newer.id])
    XCTAssertFalse(older.isVisible)
  }

  func testAskFindsMeaningInASmallHistory() async throws {
    embedder.vectors["2 cups flour, 3 eggs"] = FakeEmbedder.vector([0: 0.8, 1: 0.6])
    embedder.vectors["kubectl get pods"] = FakeEmbedder.vector([0: 0.6, 2: 0.8])
    embedder.vectors["cake recipe"] = FakeEmbedder.vector([0: 1])
    let recipe = try add("2 cups flour, 3 eggs")
    try add("kubectl get pods")
    await history.waitForEmbeddings()
    await ask("cake recipe")
    XCTAssertEqual(history.items.map(\.id), [recipe.id])
  }

  func testAskFallbackRanksAnExactIdentifierFirst() async throws {
    embedder.vectors["INV-2026-0042"] = FakeEmbedder.vector([0: 1])
    embedder.vectors["Invoice draft for the March order"] = FakeEmbedder.vector([0: 1, 5: 0.1])
    embedder.vectors["Paid: INV-2026-0042"] = FakeEmbedder.vector([0: 0.5, 6: 0.85])
    try add("Invoice draft for the March order")
    let exact = try add("Paid: INV-2026-0042")
    try addFiller()
    await history.waitForEmbeddings()
    await ask("INV-2026-0042")
    XCTAssertEqual(history.items.first?.id, exact.id)
  }

  func testSelectionSkipsHiddenGroupMembers() async throws {
    Defaults[.sortBy] = .numberOfCopies
    Defaults[.groupSimilarItems] = true
    embedder.vectors["Meeting moved to Thursday"] = FakeEmbedder.vector([0: 1, 1: 0.05])
    embedder.vectors["Meeting moved to Friday"] = FakeEmbedder.vector([0: 1, 2: 0.05])
    try add("Meeting moved to Thursday")
    try add("Meeting moved to Thursday")
    let newer = try add("Meeting moved to Friday")
    let state = AppState(history: history)
    await history.waitForEmbeddings()
    history.refreshSearchResults()
    await history.waitForGroups()
    history.searchQuery = "x"
    history.searchQuery = ""
    await history.waitForGroups()
    XCTAssertEqual(state.selection, newer.id)
    XCTAssertEqual(history.selectedItem?.id, newer.id)
  }

  func testCompletedAskRefreshesWhenNewVectorsArrive() async throws {
    embedder.vectors["port 3000 is already in use"] = FakeEmbedder.vector([0: 1])
    embedder.vectors["server will not start"] = FakeEmbedder.vector([0: 0.9, 3: 0.3])
    try addFiller()
    await history.waitForEmbeddings()
    await ask("server will not start")
    XCTAssertTrue(history.items.isEmpty)
    let item = try add("port 3000 is already in use")
    await history.waitForEmbeddings()
    while history.items.isEmpty { try await Task.sleep(for: .milliseconds(20)); await history.waitForSearch() }
    XCTAssertEqual(history.items.first?.id, item.id)
    XCTAssertFalse(history.submitAskIfNeeded())
  }

  func testPinnedItemsAreNeverGrouped() async throws {
    Defaults[.groupSimilarItems] = true
    embedder.vectors["note one"] = FakeEmbedder.vector([0: 1, 1: 0.05])
    embedder.vectors["note two"] = FakeEmbedder.vector([0: 1, 2: 0.05])
    let first = try add("note one")
    try add("note two")
    history.togglePin(first)
    await history.waitForEmbeddings()
    history.refreshSearchResults()
    await history.waitForGroups()
    XCTAssertTrue(first.isVisible)
    XCTAssertEqual(history.visibleUnpinnedItems.count + history.visiblePinnedItems.count, 2)
  }

  func testImagesWaitForTheImageModel() async throws {
    let png = try XCTUnwrap(NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
      NSColor.red.setFill(); rect.fill(); return true
    }.tiffRepresentation)
    let capture = CapturedCopy(contents: [ContentSnapshot(type: NSPasteboard.PasteboardType.tiff.rawValue, value: png)],
                               application: nil, copiedAt: Date(), changeCount: 0)
    let image = try history.add(ContentProcessor.prepare(capture))
    await history.waitForEmbeddings()
    XCTAssertEqual(image.item.embeddingSource, "")
    XCTAssertEqual(embedder.imageCalls, 0)
    embedder.capability = .textAndImages
    embedder.imageVector = FakeEmbedder.vector([4: 1])
    history.semanticModelChanged()
    await history.waitForEmbeddings()
    XCTAssertEqual(image.item.embeddingSource, "image1")
    XCTAssertTrue(history.semanticIndex.isImage[history.semanticIndex.ids.firstIndex(of: image.id)!])
  }

  func testUnreadableImagesAreNotRetried() async throws {
    embedder.capability = .textAndImages
    let capture = CapturedCopy(contents: [ContentSnapshot(type: NSPasteboard.PasteboardType.png.rawValue,
                                                          value: Data([0, 1, 2]))],
                               application: nil, copiedAt: Date(), changeCount: 0)
    let image = try history.add(ContentProcessor.prepare(capture))
    await history.waitForEmbeddings()
    XCTAssertEqual(image.item.embeddingSource, "image1")
    XCTAssertNil(image.item.embedding)
    XCTAssertEqual(history.semanticProgress.indexed, 0)
    XCTAssertEqual(history.semanticProgress.unreadable, 1)
    history.backfillEmbeddingsIfNeeded()
    await history.waitForEmbeddings()
    XCTAssertEqual(embedder.imageCalls, 1)
  }
}
