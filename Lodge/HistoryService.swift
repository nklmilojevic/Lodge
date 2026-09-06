import AppKit
import Defaults
import SwiftData

enum HistoryError: LocalizedError {
  case storageLimit
  case noAvailablePin
  case unpinLimit

  var errorDescription: String? {
    switch self {
    case .storageLimit: return "This item exceeds the history data limit. Increase the limit in Storage settings."
    case .noAvailablePin: return "All pin keys are in use. Remove a pin before adding another."
    case .unpinLimit:
      return "The history limit prevents removal of this pin. Delete other history items or increase the limit in Storage settings."
    }
  }
}

/// Owns history mutations. The popup receives changes only after a successful save.
@MainActor
final class HistoryService {
  private let repository: HistoryRepository
  private let sorter = Sorter()
  private(set) var items: [HistoryItem] = []
  private var byFingerprint: [String: HistoryItem] = [:]
  private var sessionLog: [Int: UUID] = [:]

  init(repository: HistoryRepository) {
    self.repository = repository
  }

  var byteCount: Int64 { items.reduce(0) { $0 + $1.payloadByteCount } }
  var byteLimit: Int64 { Int64(min(16_384, max(1, Defaults[.historyDataLimitMB]))) * 1024 * 1024 }
  var availablePins: [String] {
    Array(HistoryItem.supportedPins.subtracting(items.compactMap(\.pin))).sorted()
  }

  func load() async throws {
    let results = try repository.fetchAll()
    // A schema migration can assign the same default UUID to existing rows.
    var seen = Set<UUID>()
    let duplicateIDs = results.filter { !seen.insert($0.uuid).inserted }
    if !duplicateIDs.isEmpty {
      try repository.transaction(updating: duplicateIDs) {
        for item in duplicateIDs { item.uuid = UUID() }
      }
    }
    // Process one legacy item at a time to bound temporary memory.
    for item in results where item.metadataVersion < 1 || item.normalizedSearchText == nil {
      let capture = CapturedCopy(contents: item.snapshot, application: item.application,
                                 copiedAt: item.lastCopiedAt, changeCount: 0)
      let oldOCR = item.ocrText
      let processed = await Task.detached(priority: .utility) {
        (ContentProcessor.prepare(capture), oldOCR.map(ContentProcessor.normalize))
      }.value
      try Task.checkCancellation()
      try repository.transaction(updating: [item]) {
        item.apply(processed.0)
        item.normalizedOCRText = processed.1
        item.payloadByteCount += Int64((oldOCR?.utf8.count ?? 0) + (processed.1?.utf8.count ?? 0))
      }
    }
    let retained = try repository.transaction {
      try repository.deleteOrphanedContents()
      return prune(results)
    }
    publish(retained)
  }

  @discardableResult
  func add(_ prepared: PreparedCopy, title: String? = nil) throws -> HistoryItem {
    let modifiedCount = prepared.capture.contents.first { $0.type == NSPasteboard.PasteboardType.modified.rawValue }
      .flatMap(\.value).flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init)
    let modified = modifiedCount.flatMap { sessionLog[$0] }.flatMap { id in items.first { $0.uuid == id } }
    let existing = modified ?? match(prepared)
    let fromLodge = prepared.capture.contents.contains { $0.type == NSPasteboard.PasteboardType.fromLodge.rawValue }
    let result: (HistoryItem, [HistoryItem]) = try repository.transaction(updating: existing.map { [$0] } ?? []) {
      let item: HistoryItem
      if let existing {
        item = existing
        if modified != nil {
          let oldContents = item.contents
          item.contents = makeContents(prepared)
          repository.deleteContents(oldContents)
          item.apply(prepared)
          item.ocrText = nil
          item.normalizedOCRText = nil
          item.imageWidth = 0
          item.imageHeight = 0
        }
        item.numberOfCopies += 1
        item.lastCopiedAt = prepared.capture.copiedAt
        if item.application == nil && !fromLodge { item.application = prepared.capture.application }
      } else {
        item = HistoryItem()
        repository.insert(item)
        item.contents = makeContents(prepared)
        item.apply(prepared)
        item.application = prepared.capture.application
        item.firstCopiedAt = prepared.capture.copiedAt
        item.lastCopiedAt = prepared.capture.copiedAt
        item.title = title ?? item.generateTitle()
      }
      let candidates = existing == nil ? items + [item] : items
      let pinnedBytes = candidates.filter { $0.pin != nil && $0 != item }.reduce(Int64(0)) { $0 + $1.payloadByteCount }
      guard item.payloadByteCount + pinnedBytes <= byteLimit else { throw HistoryError.storageLimit }
      let retained = prune(candidates)
      guard retained.contains(item) else { throw HistoryError.storageLimit }
      return (item, retained)
    }
    publish(result.1)
    sessionLog[prepared.capture.changeCount] = result.0.uuid
    if sessionLog.count > 100, let oldest = sessionLog.keys.min() { sessionLog.removeValue(forKey: oldest) }
    return result.0
  }

  func delete(_ deleted: [HistoryItem]) throws {
    let ids = Set(deleted.map(\.uuid))
    try repository.transaction {
      deleted.forEach(repository.delete)
      try repository.deleteOrphanedContents()
    }
    publish(items.filter { !ids.contains($0.uuid) })
  }

  func enforceLimits() throws {
    let retained = try repository.transaction { prune(items) }
    publish(retained)
  }

  func setPin(_ pin: String?, for item: HistoryItem) throws {
    if let pin, !availablePins.contains(pin), item.pin != pin { throw HistoryError.noAvailablePin }
    if pin == nil && pruningCandidates(items, unpinnedItem: item).contains(item) {
      throw HistoryError.unpinLimit
    }
    let retained = try repository.transaction(updating: [item]) {
      item.pin = pin
      let retained = prune(items)
      guard retained.contains(item) else { throw HistoryError.unpinLimit }
      return retained
    }
    publish(retained)
  }

  func setTitle(_ title: String, for item: HistoryItem) throws {
    try repository.transaction(updating: [item]) { item.title = title }
  }

  func edit(_ item: HistoryItem, prepared: PreparedCopy) throws {
    let pinnedBytes = items.filter { $0.pin != nil && $0 != item }.reduce(Int64(0)) { $0 + $1.payloadByteCount }
    guard prepared.byteCount + pinnedBytes <= byteLimit else { throw HistoryError.storageLimit }
    try validateUpdate(item, byteCount: prepared.byteCount)
    let retained = try repository.transaction(updating: [item]) {
      let previous = item.contents
      item.contents = makeContents(prepared)
      repository.deleteContents(previous)
      item.apply(prepared)
      item.ocrText = nil
      item.normalizedOCRText = nil
      item.imageWidth = 0
      item.imageHeight = 0
      let retained = prune(items)
      guard retained.contains(item) else { throw HistoryError.storageLimit }
      return retained
    }
    publish(retained)
  }

  @discardableResult
  func setImageMetadata(for item: HistoryItem, text: String?, normalizedText: String? = nil,
                        width: Int, height: Int) throws -> Bool {
    guard items.contains(where: { $0.uuid == item.uuid }) else { return false }
    if text == nil && item.imageWidth == width && item.imageHeight == height { return false }
    var byteCount = item.payloadByteCount
    if let text {
      byteCount -= Int64((item.ocrText?.utf8.count ?? 0) + (item.normalizedOCRText?.utf8.count ?? 0))
      byteCount += Int64(text.utf8.count + (normalizedText?.utf8.count ?? 0))
    }
    try validateUpdate(item, byteCount: byteCount)
    let previousCount = items.count
    let retained = try repository.transaction(updating: [item]) {
      if let text {
        item.ocrText = text
        item.normalizedOCRText = normalizedText
      }
      item.payloadByteCount = byteCount
      item.imageWidth = width
      item.imageHeight = height
      let retained = prune(items)
      guard retained.contains(item) else { throw HistoryError.storageLimit }
      return retained
    }
    publish(retained)
    return retained.count != previousCount
  }

  func sort() { publish(items) }

  private func match(_ prepared: PreparedCopy) -> HistoryItem? {
    if !prepared.fingerprint.isEmpty, let exact = byFingerprint[prepared.fingerprint] { return exact }
    let incoming = Set(zip(prepared.capture.contents, prepared.fingerprints)
      .filter { !ContentProcessor.transientTypes.contains($0.0.type) }.map(\.1))
    guard !incoming.isEmpty else { return nil }
    return items.first { incoming.isSubset(of: Set($0.contents.map(\.contentDigest))) }
  }

  private func makeContents(_ prepared: PreparedCopy) -> [HistoryItemContent] {
    zip(prepared.capture.contents, prepared.fingerprints).map { snapshot, digest in
      let content = HistoryItemContent(type: snapshot.type, value: snapshot.value)
      content.fingerprint = digest
      return content
    }
  }

  private func prune(_ candidates: [HistoryItem]) -> [HistoryItem] {
    let removed = pruningCandidates(candidates)
    removed.forEach(repository.delete)
    let removedIDs = Set(removed.map(\.uuid))
    return candidates.filter { !removedIDs.contains($0.uuid) }
  }

  private func validateUpdate(_ item: HistoryItem, byteCount: Int64) throws {
    // Check retention before replacing content rows or changing metadata.
    guard !pruningCandidates(items, updatedItem: item, updatedByteCount: byteCount).contains(item)
    else { throw HistoryError.storageLimit }
  }

  private func pruningCandidates(_ candidates: [HistoryItem], updatedItem: HistoryItem? = nil,
                                 updatedByteCount: Int64 = 0, unpinnedItem: HistoryItem? = nil) -> [HistoryItem] {
    func byteCount(_ item: HistoryItem) -> Int64 {
      item == updatedItem ? updatedByteCount : item.payloadByteCount
    }
    let maxCount = min(999, max(1, Defaults[.size]))
    let unpinned = candidates.filter { $0.pin == nil || $0 == unpinnedItem }
      .sorted { $0.lastCopiedAt > $1.lastCopiedAt }
    var bytes = candidates.reduce(Int64(0)) { $0 + byteCount($1) }
    var count = unpinned.count
    var removed: [HistoryItem] = []
    for item in unpinned.reversed() where count > maxCount || bytes > byteLimit {
      removed.append(item)
      bytes -= byteCount(item)
      count -= 1
    }
    return removed
  }

  private func publish(_ items: [HistoryItem]) {
    self.items = sorter.sort(items)
    byFingerprint = Dictionary(items.filter { !$0.contentFingerprint.isEmpty }.map { ($0.contentFingerprint, $0) },
                               uniquingKeysWith: { first, _ in first })
    let retainedIDs = Set(items.map(\.uuid))
    sessionLog = sessionLog.filter { retainedIDs.contains($0.value) }
  }
}
