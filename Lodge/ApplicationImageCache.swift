class ApplicationImageCache {
  static let shared = ApplicationImageCache()

  private let universalClipboardIdentifier: String =
  "com.apple.finder.Open-iCloudDrive"
  private let fallback = ApplicationImage(bundleIdentifier: nil)
  private var cache: [String: ApplicationImage] = [:]
  private var accessOrder: [String] = [] // Track access order for LRU eviction
  private let maxCacheSize = 50 // Limit cache to 50 unique applications

  func getImage(item: HistoryItem) -> ApplicationImage {
    guard let bundleIdentifier = bundleIdentifier(for: item) else {
      return fallback
    }

    if let image = cache[bundleIdentifier] {
      // Move to end of access order (most recently used)
      if let index = accessOrder.firstIndex(of: bundleIdentifier) {
        accessOrder.remove(at: index)
      }
      accessOrder.append(bundleIdentifier)
      return image
    }

    // Evict oldest entry if at capacity
    if cache.count >= maxCacheSize, let oldest = accessOrder.first {
      accessOrder.removeFirst()
      cache.removeValue(forKey: oldest)
    }

    let image = ApplicationImage(bundleIdentifier: bundleIdentifier)
    cache[bundleIdentifier] = image
    accessOrder.append(bundleIdentifier)

    return image
  }

  private func bundleIdentifier(for item: HistoryItem) -> String? {
    if item.universalClipboard {
      return universalClipboardIdentifier
    }

    if let bundleIdentifier = item.application {
      return bundleIdentifier
    }

    return nil
  }
}
