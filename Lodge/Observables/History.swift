// swiftlint:disable file_length
import AppKit.NSRunningApplication
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import Settings
import SwiftData

@Observable
@MainActor
class History { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger = Logger(label: "com.nklmilojevic.Lodge")

  var items: [HistoryItemDecorator] = []
  var selectedItem: HistoryItemDecorator? {
    willSet {
      // Skip if setting to the same item (avoid redundant re-renders)
      guard selectedItem?.id != newValue?.id else { return }

      selectedItem?.isSelected = false
      newValue?.isSelected = true

      // Eagerly ensure text is cached before the detail view renders
      if let item = newValue {
        ensureTextCached(for: item)
      }
    }
  }

  /// Ensure text and hash are cached for an item before it's displayed.
  /// If not already cached, computes in background to avoid blocking selection.
  private func ensureTextCached(for item: HistoryItemDecorator) {
    // If already cached, nothing to do
    guard !item.isTextCached else { return }

    let text = item.item.previewableText.shortened(to: 5_000)
    item.precacheText(text, hash: text.hashValue)
  }

  // Cached filtered arrays to avoid repeated filtering on every access
  @ObservationIgnored
  private var _cachedPinnedItems: [HistoryItemDecorator]?
  @ObservationIgnored
  private var _cachedUnpinnedItems: [HistoryItemDecorator]?
  @ObservationIgnored
  private var _cachedVisiblePinnedItems: [HistoryItemDecorator]?
  @ObservationIgnored
  private var _cachedVisibleUnpinnedItems: [HistoryItemDecorator]?

  var pinnedItems: [HistoryItemDecorator] {
    // Always access `items` so @Observable tracks it even on cache hits.
    // Without this, views returning cached values lose their dependency on
    // `items` and won't re-render when search results change.
    let currentItems = items
    if let cached = _cachedPinnedItems { return cached }
    let filtered = currentItems.filter(\.isPinned)
    _cachedPinnedItems = filtered
    return filtered
  }

  var unpinnedItems: [HistoryItemDecorator] {
    let currentItems = items
    if let cached = _cachedUnpinnedItems { return cached }
    let filtered = currentItems.filter(\.isUnpinned)
    _cachedUnpinnedItems = filtered
    return filtered
  }

  // Pre-filtered visible items to avoid repeated filtering in views
  var visiblePinnedItems: [HistoryItemDecorator] {
    _ = items
    if let cached = _cachedVisiblePinnedItems { return cached }
    let filtered = pinnedItems.filter(\.isVisible)
    _cachedVisiblePinnedItems = filtered
    return filtered
  }

  var visibleUnpinnedItems: [HistoryItemDecorator] {
    _ = items
    if let cached = _cachedVisibleUnpinnedItems { return cached }
    let filtered = unpinnedItems.filter(\.isVisible)
    _cachedVisibleUnpinnedItems = filtered
    return filtered
  }

  // Dictionary for O(1) item lookup by ID
  @ObservationIgnored
  private var itemsById: [UUID: HistoryItemDecorator] = [:]
  @ObservationIgnored
  private var itemsByFingerprint: [String: HistoryItem] = [:]

  /// Fast O(1) lookup of item by ID
  func item(withId id: UUID) -> HistoryItemDecorator? {
    return itemsById[id]
  }

  /// Rebuild the items-by-ID dictionary
  private func rebuildItemsIndex() {
    itemsById = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    itemsByFingerprint = Dictionary(
      all.compactMap { decorator in
        let fingerprint = decorator.item.contentFingerprint
        return fingerprint.isEmpty ? nil : (fingerprint, decorator.item)
      },
      uniquingKeysWith: { first, _ in first }
    )
  }

  /// Invalidates all cached filter arrays and rebuilds index. Call this when `items` changes.
  private func invalidateFilterCaches() {
    _cachedPinnedItems = nil
    _cachedUnpinnedItems = nil
    _cachedVisiblePinnedItems = nil
    _cachedVisibleUnpinnedItems = nil
    rebuildItemsIndex()
  }

  var searchQuery: String = "" {
    didSet {
      throttler.throttle { [self] in
        applySearch()
      }
    }
  }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)
  private let repository: HistoryRepository

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]
  @ObservationIgnored
  private let sessionLogMaxSize = 100
  @ObservationIgnored
  private var ocrBackfillTask: Task<Void, Never>?

  // The distinction between `all` and `items` is the following:
  // - `all` stores all history items, even the ones that are currently hidden by a search
  // - `items` stores only visible history items, updated during a search
  @ObservationIgnored
  var all: [HistoryItemDecorator] = []

  init(repository: HistoryRepository? = nil) {
    self.repository = repository ?? .shared
    Task { [weak self] in
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        guard let self else { return }
        self.updateShortcuts()
      }
    }

    Task { [weak self] in
      for await _ in Defaults.updates(.sortBy, initial: false) {
        guard let self else { return }
        do {
          try await self.load()
        } catch {
          self.logger.error("Cannot reload history after sort change: \(error)")
        }
      }
    }

    Task { [weak self] in
      for await _ in Defaults.updates(.pinTo, initial: false) {
        guard let self else { return }
        do {
          try await self.load()
        } catch {
          self.logger.error("Cannot reload history after pin-position change: \(error)")
        }
      }
    }

    Task { [weak self] in
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        guard let self else { return }
        for item in self.items {
          self.updateTitle(item: item, title: item.item.generateTitle())
        }
      }
    }

    Task { [weak self] in
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        guard let self else { return }
        for item in self.items {
          item.cleanupImages()
        }
      }
    }

    Task { [weak self] in
      for await _ in Defaults.updates(.ocrInImages, initial: false) {
        guard let self else { return }
        self.search.invalidateCache()
        if Defaults[.ocrInImages] {
          self.backfillOCRIfNeeded()
        } else {
          self.ocrBackfillTask?.cancel()
        }
        if !self.searchQuery.isEmpty {
          self.applySearch()
        }
      }
    }
  }

  @MainActor
  func load() async throws {
    // The configured maximum is 999 items, so one stable fetch is both simpler and
    // safer than offset pagination whose ordering can change between requests.
    // Reclaim content rows (and their external blob files) left behind by earlier
    // versions. Idempotent, and a no-op once there is nothing to collect.
    do {
      let reclaimed = try repository.deleteOrphanedContents()
      if reclaimed > 0 {
        logger.info("Removed \(reclaimed) orphaned content rows")
      }
    } catch {
      logger.error("Cannot remove orphaned content rows: \(error)")
    }

    let results = try repository.fetchAll()
    var needsFingerprintSave = false
    for item in results where item.contentFingerprint.isEmpty {
      item.computeContentFingerprint()
      needsFingerprintSave = true
    }
    if needsFingerprintSave {
      try repository.save()
    }

    all = sorter.sort(results).map { HistoryItemDecorator($0) }
    limitHistorySize(to: Defaults[.size])
    items = all
    invalidateFilterCaches()
    updateShortcuts()

    // Pre-cache text for initial items SYNCHRONOUSLY before UI shows
    // This ensures instant selection for visible items
    precacheTextSynchronously(Array(all.prefix(50)))

    // Ensure that panel size is proper *after* loading initial items.
    Task {
      AppState.shared.popup.needsResize = true
    }

    if Defaults[.ocrInImages] {
      backfillOCRIfNeeded()
    }

    // Preload universal clipboard images in background to avoid main thread blocking
    preloadUniversalClipboardImages()

    // Backfill text stats for legacy items that don't have them stored
    try await backfillTextStatsIfNeeded()

    // Pre-cache text and hash for all items to ensure instant selection
    precacheTextForAllItems()
  }

  /// Pre-cache text content and hash for all items in background.
  /// This ensures instant display when selecting items in split view.
  @MainActor
  private func precacheTextForAllItems() {
    precacheTextForItems(all, priority: .utility)
  }

  /// Pre-cache text content and hash for specific items.
  /// - Parameters:
  ///   - items: Items to pre-cache
  ///   - priority: Task priority (use .userInitiated for visible items, .utility for background)
  @MainActor
  private func precacheTextForItems(_ items: [HistoryItemDecorator], priority: TaskPriority) {
    let snapshots = items.map { decorator in
      (decorator, decorator.item.previewableText.shortened(to: 50_000))
    }
    Task(priority: priority) { @MainActor in
      for (decorator, text) in snapshots {
        if Task.isCancelled { break }

        decorator.precacheText(text, hash: text.hashValue)
        await Task.yield()
      }
    }
  }

  /// Synchronously pre-cache text for items. Call this for initial visible items
  /// to ensure instant selection without any async delay.
  @MainActor
  private func precacheTextSynchronously(_ items: [HistoryItemDecorator]) {
    for decorator in items {
      guard !decorator.isTextCached else { continue }
      let text = decorator.item.previewableText.shortened(to: 5_000)
      let hash = text.hashValue
      decorator.precacheText(text, hash: hash)
    }
  }

  @MainActor
  private func preloadUniversalClipboardImages() {
    let itemsToPreload = all.filter { $0.item.universalClipboard }
    guard !itemsToPreload.isEmpty else { return }
    Task(priority: .utility) { @MainActor in
      for decorator in itemsToPreload {
        if Task.isCancelled { break }
        decorator.item.preloadUniversalClipboardImageData()
        await Task.yield()
      }
    }
  }

  /// Backfill text statistics for items that were created before stats were stored in the database.
  /// Also pre-caches text and hash for instant display.
  @MainActor
  private func backfillTextStatsIfNeeded() async throws {
    // Filter to items that need stats backfill (text items without stored stats)
    let itemsToProcess = all.filter { $0.item.characterCount == 0 && !$0.item.hasImageContent }
    guard !itemsToProcess.isEmpty else { return }

    let texts = itemsToProcess.map { $0.item.previewableText }
    let statistics = await Task.detached(priority: .background) {
      texts.map { text in
        (
          text.count,
          text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        )
      }
    }.value

    for (decorator, stats) in zip(itemsToProcess, statistics) {
      decorator.item.characterCount = stats.0
      decorator.item.wordCount = stats.1

      // Also pre-cache the text and hash in the decorator for instant display
      _ = decorator.text
      _ = decorator.textHash
    }

    try repository.save()
  }

  @MainActor
  func backfillOCRIfNeeded() {
    ocrBackfillTask?.cancel()

    let itemsToProcess = all.filter(\.hasImage)
    guard !itemsToProcess.isEmpty else { return }
    ocrBackfillTask = Task(priority: .background) { @MainActor in
      for item in itemsToProcess {
        if Task.isCancelled { break }
        item.item.scheduleOCRIfNeeded()
        try? await Task.sleep(for: .milliseconds(30))
      }
    }
  }

  @MainActor
  func refreshSearchResults(invalidateCache: Bool = false) {
    guard !searchQuery.isEmpty else { return }
    if invalidateCache {
      search.invalidateCache()
    }
    applySearch()
  }

  @MainActor
  private func limitHistorySize(to maxSize: Int) {
    let unpinned = all.filter(\.isUnpinned)
    guard unpinned.count >= maxSize else { return }

    let itemsToDelete = Array(unpinned[maxSize...])
    guard !itemsToDelete.isEmpty else { return }

    search.invalidateCache()

    do {
      try repository.delete(itemsToDelete.map(\.item))
    } catch {
      logger.error("Cannot enforce history size: \(error)")
      return
    }

    // Clean up images and remove from in-memory arrays
    for item in itemsToDelete {
      cleanup(item)
      sessionLog.removeValues { $0 == item.item }
    }

    all.removeAll { itemsToDelete.contains($0) }
    items.removeAll { itemsToDelete.contains($0) }

    invalidateFilterCaches()
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    logger.info("Inserting item with id '\(item.title)'")
    try repository.insert(item)
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    search.invalidateCache()
    if item.contentFingerprint.isEmpty {
      item.computeContentFingerprint()
    }

    if #available(macOS 15.0, *) {
      do {
        try insertIntoStorage(item)
      } catch {
        logger.error("Cannot persist new history item: \(error)")
      }
    } else {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      // It was already inserted after creation in Clipboard.swift
    }

    var removedItemIndex: Int?
    var reusableDecorator: HistoryItemDecorator?
    if let existingHistoryItem = findSimilarItem(item) {
      if isModified(item) == nil {
        // The new item was already persisted above, so it owns a full set of content
        // rows. Adopting the existing item's rows detaches those, and without deleting
        // them they linger forever with a null owner - one leaked set, plus any external
        // blob files, for every duplicate copy.
        let detachedContents = item.contents
        item.contents = existingHistoryItem.contents
        item.contentFingerprint = existingHistoryItem.contentFingerprint
        do {
          try repository.deleteContents(detachedContents)
        } catch {
          logger.error("Cannot remove detached content rows: \(error)")
        }
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      item.title = existingHistoryItem.title
      if !item.fromLodge {
        item.application = existingHistoryItem.application
      }
      logger.info("Removing duplicate item '\(item.title)'")
      do {
        try repository.delete(existingHistoryItem)
      } catch {
        logger.error("Cannot remove duplicate history item: \(error)")
      }
      removedItemIndex = all.firstIndex(where: { $0.item == existingHistoryItem })
      if let removedItemIndex {
        reusableDecorator = all.remove(at: removedItemIndex)
      }
    } else {
      Task {
        Notifier.notify(body: item.title, sound: .write)
      }
    }

    // Remove exceeding items. Do this after the item is added to avoid removing something
    // if a duplicate was found as then the size already stayed the same.
    limitHistorySize(to: Defaults[.size] - 1)

    addToSessionLog(item, changeCount: Clipboard.shared.changeCount)

    var itemDecorator: HistoryItemDecorator
    if let reusableDecorator {
      reusableDecorator.replaceItem(item)
      itemDecorator = reusableDecorator
      if let removedItemIndex {
        all.insert(itemDecorator, at: removedItemIndex)
      }
    } else if let pin = item.pin {
      itemDecorator = HistoryItemDecorator(item, shortcuts: KeyShortcut.create(character: pin))
      // Keep pins in the same place.
      if let removedItemIndex {
        all.insert(itemDecorator, at: removedItemIndex)
      }
    } else {
      itemDecorator = HistoryItemDecorator(item)

      let sortedItems = sorter.sort(all.map(\.item) + [item])
      if let index = sortedItems.firstIndex(of: item) {
        all.insert(itemDecorator, at: index)
      }

    }

    if searchQuery.isEmpty {
      items = all
      invalidateFilterCaches()
      updateShortcuts()
    } else {
      applySearch()
    }
    do {
      try repository.save()
    } catch {
      logger.error("Cannot save updated history: \(error)")
    }
    AppState.shared.popup.needsResize = true

    return itemDecorator
  }

  @MainActor
  private func withLogging(_ msg: String, _ block: () -> Void) {
    // Use in-memory counts instead of database queries to avoid blocking main thread
    let beforeCount = all.count
    logger.info("\(msg) Before: items=\(beforeCount)")
    block()
    let afterCount = all.count
    logger.info("\(msg) After: items=\(afterCount)")
  }

  @MainActor
  func clear() {
    search.invalidateCache()
    do {
      try repository.deleteUnpinned()
    } catch {
      logger.error("Cannot clear unpinned history: \(error)")
      return
    }
    withLogging("Clearing history") {
      all.forEach { item in
        if item.isUnpinned {
          cleanup(item)
        }
      }
      all.removeAll(where: \.isUnpinned)
      sessionLog.removeValues { $0.pin == nil }
      items = all
      invalidateFilterCaches()
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func clearAll() {
    search.invalidateCache()
    do {
      try repository.deleteAll()
    } catch {
      logger.error("Cannot clear history: \(error)")
      return
    }
    withLogging("Clearing all history") {
      all.forEach { item in
        cleanup(item)
      }
      all.removeAll()
      sessionLog.removeAll()
      items = all
      invalidateFilterCaches()
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    search.invalidateCache()
    do {
      try repository.delete(item.item)
    } catch {
      logger.error("Cannot remove history item: \(error)")
      return
    }
    cleanup(item)

    all.removeAll { $0 == item }
    items.removeAll { $0 == item }
    sessionLog.removeValues { $0 == item.item }
    invalidateFilterCaches()

    updateUnpinnedShortcuts()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func cleanup(_ item: HistoryItemDecorator) {
    item.cleanupImages()
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?) {
    guard let item else {
      return
    }

    let modifierFlags = NSApp.currentEvent?.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function]) ?? []

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    item.togglePin()

    let sortedItems = sorter.sort(all.map(\.item))
    if let currentIndex = all.firstIndex(of: item),
       let newIndex = sortedItems.firstIndex(of: item.item) {
      all.remove(at: currentIndex)
      all.insert(item, at: newIndex)
    }

    items = all
    invalidateFilterCaches()

    searchQuery = ""
    updateUnpinnedShortcuts()
    if item.isUnpinned {
      AppState.shared.scrollTarget = item.id
    }
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    // First check in-memory sessionLog (fast path for recent items)
    for existingItem in sessionLog.values {
      if existingItem != item && (existingItem == item || existingItem.supersedes(item)) {
        return existingItem
      }
    }

    // Check if this is a modified item
    if let modifiedItem = isModified(item) {
      return modifiedItem
    }

    // Exact copies are overwhelmingly the common case. Their stable fingerprint
    // avoids repeatedly hashing every Data payload in the full history.
    if !item.contentFingerprint.isEmpty,
       let exactMatch = itemsByFingerprint[item.contentFingerprint],
       exactMatch != item {
      return exactMatch
    }

    // Preserve the existing superset semantics for formatted/plain-text variants.
    for decorator in all {
      let existingItem = decorator.item
      if existingItem != item && (existingItem == item || existingItem.supersedes(item)) {
        return existingItem
      }
    }

    return nil
  }

  private func isModified(_ item: HistoryItem) -> HistoryItem? {
    if let modified = item.modified, sessionLog.keys.contains(modified) {
      return sessionLog[modified]
    }

    return nil
  }

  private func addToSessionLog(_ item: HistoryItem, changeCount: Int) {
    if sessionLog.count >= sessionLogMaxSize {
      // Remove oldest entry (lowest changeCount)
      if let oldest = sessionLog.keys.min() {
        sessionLog.removeValue(forKey: oldest)
      }
    }
    sessionLog[changeCount] = item
  }

  private func updateItems(_ newItems: [Search.SearchResult]) {
    items = newItems.map { result in
      let item = result.object
      item.highlight(searchQuery, result.ranges)

      return item
    }
    invalidateFilterCaches()

    updateUnpinnedShortcuts()
  }

  private func applySearch() {
    updateItems(search.search(string: searchQuery, within: all))

    if searchQuery.isEmpty {
      AppState.shared.selection = unpinnedItems.first?.id
    } else {
      AppState.shared.highlightFirst()
    }

    AppState.shared.popup.needsResize = true
  }

  private func updateShortcuts() {
    for item in pinnedItems {
      if let pin = item.item.pin {
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    updateUnpinnedShortcuts()
  }

  @MainActor
  private func updateTitle(item: HistoryItemDecorator, title: String) {
    item.title = title
    item.item.title = title
  }

  private func updateUnpinnedShortcuts() {
    let visibleUnpinnedItems = unpinnedItems.filter(\.isVisible)
    for item in visibleUnpinnedItems {
      item.shortcuts = []
    }

    var index = 1
    for item in visibleUnpinnedItems.prefix(10) {
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
  }
}
