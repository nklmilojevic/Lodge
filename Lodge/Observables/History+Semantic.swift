import Defaults
import Foundation

/// Semantic vectors: background embedding, the in-memory index, Ask ranking, similar items, and grouping.
extension History {
  var canSearchByMeaning: Bool { semantic.map { $0.capability != .none } ?? false && !semanticIndex.isEmpty }

  /// Items with vectors and items that can have one, for the settings status.
  var semanticProgress: (indexed: Int, total: Int) {
    _ = semanticRevision
    guard let semantic, semantic.capability != .none else { return (0, 0) }
    var indexed = 0, total = 0
    for item in all {
      guard let desired = desiredEmbeddingSource(item.item, semantic) else { continue }
      total += 1
      if item.item.embeddingSource == desired { indexed += 1 }
    }
    return (indexed, total)
  }

  /// Near-duplicates and related items for the detail panel.
  func neighbors(of item: HistoryItemDecorator) -> (versions: [HistoryItemDecorator], related: [HistoryItemDecorator]) {
    let revision = semanticRevision
    let ids: (versions: [UUID], related: [UUID])
    if let cache = neighborCache, cache.id == item.id, cache.revision == revision {
      ids = (cache.versions, cache.related)
    } else {
      ids = SemanticRanking.neighbors(of: item.id, in: semanticIndex)
      neighborCache = (item.id, revision, ids.versions, ids.related)
    }
    guard !ids.versions.isEmpty || !ids.related.isEmpty else { return ([], []) }
    let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    return (ids.versions.compactMap { byID[$0] }, ids.related.compactMap { byID[$0] })
  }

  /// Each item's z-score for `text`, or nil when meaning search is not available.
  func meaning(of text: String?) async -> [UUID: Double]? {
    guard let semantic, canSearchByMeaning, let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty, let vector = try? await semantic.embed(query: text) else { return nil }
    return semanticIndex.meaning(vector).mapValues(\.z)
  }

  func desiredEmbeddingSource(_ item: HistoryItem, _ semantic: SemanticEmbedder) -> String? {
    let version = semantic.vectorVersion
    if item.hasImageContent { return semantic.capability.supportsImages ? "image\(version)" : nil }
    let text = item.previewableText.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "none\(version)" : "text\(version)"
  }

  /// Rebuilds the index from stored vectors of the current version. Existing image vectors stay searchable after the
  /// image model is removed, because queries only need the text model.
  func rebuildSemanticIndex() {
    guard let semantic, semantic.capability != .none else {
      if !semanticIndex.isEmpty {
        semanticIndex = SemanticIndex()
        vectorKeys = [:]
        semanticRevision &+= 1
      }
      return
    }
    let version = String(semantic.vectorVersion)
    var keys: [UUID: String] = [:]
    var stored: [(item: HistoryItem, data: Data)] = []
    for item in service.items {
      guard let data = item.embedding, item.embeddingSource.hasSuffix(version),
            item.embeddingSource.dropLast(version.count).allSatisfy(\.isLetter) else { continue }
      keys[item.uuid] = item.embeddingSource + item.contentFingerprint + String(data.hashValue)
      stored.append((item, data))
    }
    guard keys != vectorKeys else { return }
    var entries: [(id: UUID, isImage: Bool, vector: [Float])] = []
    for (item, data) in stored {
      let isImage = item.embeddingSource.hasPrefix("image")
      if vectorKeys[item.uuid] == keys[item.uuid], let vector = semanticIndex.vector(for: item.uuid) {
        entries.append((item.uuid, isImage, vector))
      } else if let vector = SemanticVectors.unpack(data) {
        entries.append((item.uuid, isImage, vector))
      }
    }
    vectorKeys = keys
    semanticIndex = SemanticIndex(entries)
    semanticRevision &+= 1
  }

  func waitForEmbeddings() async {
    while let task = embeddingTask { await task.value }
  }

  func semanticModelChanged() {
    embeddingFailed = false
    embeddingTask?.cancel()
    embeddingTask = nil
    rebuildSemanticIndex()
    applySearch(selectFirst: false)
    backfillEmbeddingsIfNeeded()
  }

  /// Embeds items without a current vector, newest first: up to 16 text items per batch, images one at a time.
  func backfillEmbeddingsIfNeeded() {
    guard let semantic, semantic.capability != .none, embeddingTask == nil, !embeddingFailed,
          service.items.contains(where: { needsEmbedding($0, semantic) }) else { return }
    embeddingGeneration &+= 1
    let generation = embeddingGeneration
    embeddingTask = Task { [weak self] in
      while let self, !Task.isCancelled {
        let pending = self.service.items.filter { self.needsEmbedding($0, semantic) }
        guard !pending.isEmpty else { break }
        let batch: [HistoryItem]
        if let image = pending.first(where: \.hasImageContent) {
          batch = [image]
        } else {
          batch = Array(pending.prefix(16))
        }
        let work = batch.map { item in
          (item: item, fingerprint: item.contentFingerprint, source: self.desiredEmbeddingSource(item, semantic) ?? "",
           text: String(item.previewableText.prefix(4_000)), image: item.hasImageContent ? item.imageSource : nil)
        }
        var updates: [(item: HistoryItem, embedding: Data?, source: String)] = []
        do {
          if let first = work.first, first.item.hasImageContent {
            // An unreadable image keeps no vector and is not tried again.
            var vector: [Float]?
            do {
              if let image = first.image { vector = try await semantic.embed(image: image) }
            } catch SemanticModelError.unreadableImage {}
            updates.append((first.item, vector.map(SemanticVectors.pack), first.source))
          } else {
            let texts = work.filter { !$0.source.hasPrefix("none") }
            let vectors = texts.isEmpty ? [] : try await semantic.embed(documents: texts.map(\.text))
            for (entry, vector) in zip(texts, vectors) { updates.append((entry.item, SemanticVectors.pack(vector), entry.source)) }
            for entry in work where entry.source.hasPrefix("none") { updates.append((entry.item, nil, entry.source)) }
          }
        } catch {
          guard !Task.isCancelled else { break }
          self.embeddingFailed = true
          self.logger.error("Semantic vectors could not be created")
          break
        }
        guard !Task.isCancelled else { break }
        let fingerprints = Dictionary(work.map { ($0.item.uuid, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
        let current = updates.filter { fingerprints[$0.item.uuid] == $0.item.contentFingerprint }
        do {
          try self.service.setEmbeddings(current)
        } catch {
          self.report("Semantic search data could not be saved.")
          self.embeddingFailed = true
          break
        }
        self.rebuildSemanticIndex()
        if Defaults[.groupSimilarItems] && self.searchQuery.isEmpty { self.applySearch(selectFirst: false) }
      }
      if let self, self.embeddingGeneration == generation { self.embeddingTask = nil }
    }
  }

  func needsEmbedding(_ item: HistoryItem, _ semantic: SemanticEmbedder) -> Bool {
    guard let desired = desiredEmbeddingSource(item, semantic) else { return false }
    return item.embeddingSource != desired
  }

  /// Hides older near-duplicates of an unpinned item when grouping is on and no search is active.
  func applyGrouping() {
    let grouping = Defaults[.groupSimilarItems] && searchQuery.isEmpty && semanticIndex.count > 1
    var heads: [UUID: UUID] = [:]
    if grouping {
      let order = all.filter(\.isUnpinned).map(\.id)
      if let cache = groupCache, cache.revision == semanticRevision, cache.order == order {
        heads = cache.heads
      } else {
        heads = SemanticRanking.groups(order, in: semanticIndex)
        groupCache = (semanticRevision, order, heads)
      }
    }
    var counts: [UUID: Int] = [:]
    for head in heads.values { counts[head, default: 0] += 1 }
    for item in all {
      let visible = heads[item.id] == nil
      if item.isVisible != visible { item.isVisible = visible }
      let count = counts[item.id] ?? 0
      if item.similarCount != count { item.similarCount = count }
    }
  }
}
