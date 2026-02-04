import AppKit
import Defaults
import Fuse

class Search {
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
    var object: Searchable
    var ranges: [Range<String.Index>] = []
  }

  typealias Searchable = HistoryItemDecorator

  private let fuse = Fuse(threshold: 0.7) // threshold found by trial-and-error
  private let fuzzySearchLimit = 5_000

  // Search result caching with LRU eviction
  private var searchCache: [String: [SearchResult]] = [:]
  private var cacheAccessOrder: [String] = []
  private let searchCacheMaxSize = 20

  func search(string: String, within: [Searchable]) -> [SearchResult] {
    guard !string.isEmpty else {
      return within.map { SearchResult(object: $0) }
    }

    // Simplified cache key - invalidateCache() is called on content changes
    let cacheKey = "\(string)_\(Defaults[.searchMode].rawValue)"

    if let cached = searchCache[cacheKey] {
      // Move to end of access order (most recently used)
      if let index = cacheAccessOrder.firstIndex(of: cacheKey) {
        cacheAccessOrder.remove(at: index)
      }
      cacheAccessOrder.append(cacheKey)
      return cached
    }

    let results: [SearchResult]
    switch Defaults[.searchMode] {
    case .mixed:
      results = mixedSearch(string: string, within: within)
    case .regexp:
      results = simpleSearch(string: string, within: within, options: .regularExpression)
    case .fuzzy:
      results = fuzzySearch(string: string, within: within)
    default:
      results = simpleSearch(string: string, within: within, options: .caseInsensitive)
    }

    // LRU eviction - remove oldest entry instead of clearing all
    if searchCache.count >= searchCacheMaxSize, let oldest = cacheAccessOrder.first {
      cacheAccessOrder.removeFirst()
      searchCache.removeValue(forKey: oldest)
    }

    searchCache[cacheKey] = results
    cacheAccessOrder.append(cacheKey)

    return results
  }

  func invalidateCache() {
    searchCache.removeAll()
    cacheAccessOrder.removeAll()
  }

  private func fuzzySearch(string: String, within: [Searchable]) -> [SearchResult] {
    let pattern = fuse.createPattern(from: string)
    let searchResults: [SearchResult] = within.compactMap { item in
      fuzzySearch(for: pattern, in: item.title, of: item)
        ?? fuzzySearchInOCR(for: pattern, of: item)
    }
    let sortedResults = searchResults.sorted(by: { ($0.score ?? 0) < ($1.score ?? 0) })
    return sortedResults
  }

  private func fuzzySearch(
    for pattern: Fuse.Pattern?,
    in searchString: String,
    of item: Searchable
  ) -> SearchResult? {
    var searchString = searchString
    if searchString.count > fuzzySearchLimit {
      // shortcut to avoid slow search
      let stopIndex = searchString.index(searchString.startIndex, offsetBy: fuzzySearchLimit)
      searchString = "\(searchString[...stopIndex])"
    }

    if let fuzzyResult = fuse.search(pattern, in: searchString) {
      return SearchResult(
        score: fuzzyResult.score,
        object: item,
        ranges: fuzzyResult.ranges.map {
          let startIndex = searchString.startIndex
          let lowerBound = searchString.index(startIndex, offsetBy: $0.lowerBound)
          let upperBound = searchString.index(startIndex, offsetBy: $0.upperBound + 1)

          return lowerBound..<upperBound
        }
      )
    } else {
      return nil
    }
  }

  private func simpleSearch(
    string: String,
    within: [Searchable],
    options: NSString.CompareOptions
  ) -> [SearchResult] {
    return within.compactMap { simpleSearch(for: string, in: $0.title, of: $0, options: options) }
  }

  private func simpleSearch(
    for string: String,
    in searchString: String,
    of item: Searchable,
    options: NSString.CompareOptions
  ) -> SearchResult? {
    if let range = searchString.range(of: string, options: options, range: nil, locale: nil) {
      return SearchResult(object: item, ranges: [range])
    }

    if Defaults[.ocrInImages], !item.ocrText.isEmpty,
       let _ = item.ocrText.range(of: string, options: options, range: nil, locale: nil) {
      // Match found only in OCR text; don't highlight in title.
      return SearchResult(object: item, ranges: [])
    }

    return nil
  }

  private func mixedSearch(string: String, within: [Searchable]) -> [SearchResult] {
    var results = simpleSearch(string: string, within: within, options: .caseInsensitive)
    guard results.isEmpty else {
      return results
    }

    results = simpleSearch(string: string, within: within, options: .regularExpression)
    guard results.isEmpty else {
      return results
    }

    results = fuzzySearch(string: string, within: within)
    guard results.isEmpty else {
      return results
    }

    return []
  }

  private func fuzzySearchInOCR(for pattern: Fuse.Pattern?, of item: Searchable) -> SearchResult? {
    guard Defaults[.ocrInImages], !item.ocrText.isEmpty else { return nil }
    guard let result = fuzzySearch(for: pattern, in: item.ocrText, of: item) else { return nil }
    return SearchResult(score: result.score, object: item, ranges: [])
  }
}
