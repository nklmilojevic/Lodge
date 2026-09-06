import AppKit
import Defaults
import Fuse

@MainActor
final class Search {
  enum Mode: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
    case exact
    case fuzzy
    case regexp
    case mixed

    var id: Self { self }

    var description: String {
      switch self {
      case .exact:
        return NSLocalizedString("Exact", tableName: "GeneralSettings", comment: "")
      case .fuzzy:
        return NSLocalizedString("Fuzzy", tableName: "GeneralSettings", comment: "")
      case .regexp:
        return NSLocalizedString("Regex", tableName: "GeneralSettings", comment: "")
      case .mixed:
        return NSLocalizedString("Mixed", tableName: "GeneralSettings", comment: "")
      }
    }
  }

  struct SearchResult: Equatable {
    var score: Double?
    var object: HistoryItemDecorator
    var ranges: [Range<String.Index>] = []
  }

  private struct CacheKey: Hashable {
    let revision: UInt64
    let query: String
    let mode: String
    let ocr: Bool
  }
  private var cache: [CacheKey: [SearchMatch]] = [:]
  private var accessOrder: [CacheKey] = []
  private var revision: UInt64?

  func invalidateCache() {
    cache.removeAll()
    accessOrder.removeAll()
    revision = nil
  }

  // Synchronous entry point for small fixtures and performance measurements.
  func search(string: String, within items: [HistoryItemDecorator]) -> [SearchResult] {
    resolve(SearchEngine.search(query: string, documents: documents(items),
                                mode: Defaults[.searchMode].rawValue, ocr: Defaults[.ocrInImages]), in: items)
  }

  func search(string: String, within items: [HistoryItemDecorator], revision: UInt64) async -> [SearchResult] {
    if self.revision != revision {
      invalidateCache()
      self.revision = revision
    }
    let key = CacheKey(revision: revision, query: string, mode: Defaults[.searchMode].rawValue,
                       ocr: Defaults[.ocrInImages])
    if let matches = cache[key] {
      touch(key)
      return resolve(matches, in: items)
    }
    let documents = documents(items)
    let worker = Task.detached(priority: .userInitiated) {
      SearchEngine.search(query: string, documents: documents, mode: key.mode, ocr: key.ocr)
    }
    let matches = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    guard !Task.isCancelled, self.revision == revision else { return [] }
    if cache.count >= 20, let oldest = accessOrder.first {
      cache.removeValue(forKey: oldest)
      accessOrder.removeFirst()
    }
    cache[key] = matches
    touch(key)
    return resolve(matches, in: items)
  }

  private func touch(_ key: CacheKey) {
    accessOrder.removeAll { $0 == key }
    accessOrder.append(key)
  }

  private func documents(_ items: [HistoryItemDecorator]) -> [SearchDocument] {
    items.map { SearchDocument(id: $0.id, title: $0.title, text: $0.searchableText, ocr: $0.ocrText,
                               normalizedText: $0.item.normalizedSearchText, normalizedOCR: $0.item.normalizedOCRText) }
  }

  private func resolve(_ matches: [SearchMatch], in items: [HistoryItemDecorator]) -> [SearchResult] {
    let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    return matches.compactMap { match in
      guard let item = byID[match.id] else { return nil }
      return SearchResult(score: match.score, object: item,
                          ranges: match.ranges.compactMap { Range($0, in: item.title) })
    }
  }
}

struct SearchDocument: Sendable {
  let id: UUID
  let title: String
  let text: String
  let ocr: String
  let normalizedText: String
  let normalizedOCR: String

  init(id: UUID, title: String, text: String, ocr: String, normalizedText: String? = nil, normalizedOCR: String? = nil) {
    self.id = id
    self.title = title
    self.text = text
    self.ocr = ocr
    self.normalizedText = normalizedText ?? ContentProcessor.normalize(text)
    self.normalizedOCR = normalizedOCR ?? ContentProcessor.normalize(ocr)
  }
}

struct SearchMatch: Sendable {
  let id: UUID
  var score: Double?
  var ranges: [NSRange] = []
}

/// Searches value snapshots without accessing models or popup state.
enum SearchEngine {
  static func search(query: String, documents: [SearchDocument], mode: String, ocr: Bool) -> [SearchMatch] {
    let interval = AppPerformance.signposter.beginInterval("Search")
    defer { AppPerformance.signposter.endInterval("Search", interval) }
    guard !query.isEmpty else { return documents.map { SearchMatch(id: $0.id) } }
    switch mode {
    case "fuzzy": return fuzzy(query, documents, ocr: ocr)
    case "regexp": return simple(query, documents, regexp: true, ocr: ocr)
    case "mixed":
      let exact = simple(query, documents, regexp: false, ocr: ocr)
      if !exact.isEmpty || Task.isCancelled { return exact }
      let regex = simple(query, documents, regexp: true, ocr: ocr)
      return regex.isEmpty && !Task.isCancelled ? fuzzy(query, documents, ocr: ocr) : regex
    default: return simple(query, documents, regexp: false, ocr: ocr)
    }
  }

  private static func simple(_ query: String, _ documents: [SearchDocument], regexp: Bool, ocr: Bool) -> [SearchMatch] {
    let normalizedQuery = ContentProcessor.normalize(query)
    let regex = regexp ? try? NSRegularExpression(pattern: query) : nil
    if regexp && regex == nil { return [] }
    func range(in text: String) -> NSRange? {
      guard !Task.isCancelled else { return nil }
      if let regex {
        var found: NSRange?
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) {
          result, _, stop in
          if let result { found = result.range }
          if found != nil || Task.isCancelled { stop.pointee = true }
        }
        return found
      }
      return text.range(of: query, options: .caseInsensitive).map { NSRange($0, in: text) }
    }
    var results: [SearchMatch] = []
    for document in documents {
      if Task.isCancelled { break }
      if let match = range(in: document.title) {
        results.append(SearchMatch(id: document.id, ranges: [match]))
      } else {
        let inText = regexp ? range(in: document.text) != nil :
          document.normalizedText.range(of: normalizedQuery, options: .literal) != nil
        let inOCR = ocr && (regexp ? range(in: document.ocr) != nil :
          document.normalizedOCR.range(of: normalizedQuery, options: .literal) != nil)
        if inText || inOCR { results.append(SearchMatch(id: document.id)) }
      }
    }
    return results
  }

  private static func fuzzy(_ query: String, _ documents: [SearchDocument], ocr: Bool) -> [SearchMatch] {
    let fuse = Fuse(threshold: 0.7)
    let contentFuse = Fuse(distance: 100_000, threshold: 0.7)
    let pattern = fuse.createPattern(from: query)
    func match(in text: String, fullText: Bool = false) -> (Double, [NSRange])? {
      let searcher = fullText ? contentFuse : fuse
      guard !text.isEmpty else { return nil }
      // Search the whole value in overlapping sections. Long clips remain searchable.
      var start = text.startIndex
      var best: (Double, [NSRange])?
      while start < text.endIndex && !Task.isCancelled {
        let end = text.index(start, offsetBy: max(5_000, query.count * 2), limitedBy: text.endIndex) ?? text.endIndex
        let section = String(text[start..<end])
        if let result = searcher.search(pattern, in: section), best == nil || result.score < best!.0 {
          let ranges = result.ranges.compactMap { bounds -> NSRange? in
            guard let lower = section.index(section.startIndex, offsetBy: bounds.lowerBound, limitedBy: section.endIndex),
                  let upper = section.index(section.startIndex, offsetBy: bounds.upperBound + 1, limitedBy: section.endIndex)
            else { return nil }
            let offset = text.utf16.distance(from: text.startIndex, to: start)
            let range = NSRange(lower..<upper, in: section)
            return NSRange(location: offset + range.location, length: range.length)
          }
          best = (result.score, ranges)
        }
        if end == text.endIndex { break }
        start = text.index(end, offsetBy: -min(query.count + 32, 2_500))
      }
      return best
    }
    var results: [(Int, SearchMatch)] = []
    for (index, document) in documents.enumerated() {
      if Task.isCancelled { break }
      if let title = match(in: document.title) {
        results.append((index, SearchMatch(id: document.id, score: title.0, ranges: title.1)))
      } else if let body = match(in: document.text, fullText: true) ?? (ocr ? match(in: document.ocr, fullText: true) : nil) {
        results.append((index, SearchMatch(id: document.id, score: body.0)))
      }
    }
    return results.sorted {
      let lhs = $0.1.score ?? 0, rhs = $1.1.score ?? 0
      return lhs == rhs ? $0.0 < $1.0 : lhs < rhs
    }.map(\.1)
  }
}
