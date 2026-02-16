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

    // Compute in background - the view will update when ready
    Task.detached(priority: .userInitiated) {
      let text = item.item.previewableText.shortened(to: 5_000)
      let hash = text.hashValue
      await MainActor.run {
        item.precacheText(text, hash: hash)
      }
    }
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

  /// Fast O(1) lookup of item by ID
  func item(withId id: UUID) -> HistoryItemDecorator? {
    return itemsById[id]
  }

  /// Rebuild the items-by-ID dictionary
  private func rebuildItemsIndex() {
    itemsById = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
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

  init() {
    Task {
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        updateShortcuts()
      }
    }

    Task {
      for await _ in Defaults.updates(.sortBy, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.pinTo, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        for item in items {
          await updateTitle(item: item, title: item.item.generateTitle())
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in items {
          await item.cleanupImages()
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.ocrInImages, initial: false) {
        if Defaults[.ocrInImages] {
          await backfillOCRIfNeeded()
        } else {
          ocrBackfillTask?.cancel()
        }
      }
    }
  }

  @MainActor
  func load() async throws {
    // Load first batch immediately (visible items)
    let initialBatchSize = 100
    var descriptor = FetchDescriptor<HistoryItem>()
    descriptor.fetchLimit = initialBatchSize
    descriptor.sortBy = [SortDescriptor(\.lastCopiedAt, order: .reverse)]

    let initialResults = try Storage.shared.context.fetch(descriptor)
    all = sorter.sort(initialResults).map { HistoryItemDecorator($0) }
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

    // Load remaining items in background
    let batchSize = initialBatchSize
    Task.detached(priority: .background) { [weak self] in
      guard let self else { return }

      await MainActor.run {
        var fullDescriptor = FetchDescriptor<HistoryItem>()
        fullDescriptor.fetchOffset = batchSize

        guard let remainingResults = try? Storage.shared.context.fetch(fullDescriptor),
              !remainingResults.isEmpty else {
          return
        }

        let remainingDecorators = self.sorter.sort(remainingResults)
          .map { HistoryItemDecorator($0) }
        self.all.append(contentsOf: remainingDecorators)
        self.limitHistorySize(to: Defaults[.size])
        self.search.invalidateCache()
      }
    }

    if Defaults[.ocrInImages] {
      backfillOCRIfNeeded()
    }

    // Preload universal clipboard images in background to avoid main thread blocking
    preloadUniversalClipboardImages()

    // Backfill text stats for legacy items that don't have them stored
    backfillTextStatsIfNeeded()

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
    Task.detached(priority: priority) {
      for decorator in items {
        if Task.isCancelled { break }

        // Compute text and hash on background thread (the expensive part)
        let text = decorator.item.previewableText.shortened(to: 50_000)
        let hash = text.hashValue

        // Store in cache on main thread (fast)
        await MainActor.run {
          decorator.precacheText(text, hash: hash)
        }
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
    let itemsToPreload = all
    Task.detached(priority: .utility) {
      for decorator in itemsToPreload {
        if Task.isCancelled { break }
        if decorator.item.universalClipboard {
          decorator.item.preloadUniversalClipboardImageData()
        }
      }
    }
  }

  /// Backfill text statistics for items that were created before stats were stored in the database.
  /// Also pre-caches text and hash for instant display.
  @MainActor
  private func backfillTextStatsIfNeeded() {
    // Filter to items that need stats backfill (text items without stored stats)
    let itemsToProcess = all.filter { $0.item.characterCount == 0 && !$0.item.hasImageContent }
    guard !itemsToProcess.isEmpty else { return }

    Task.detached(priority: .background) {
      for decorator in itemsToProcess {
        if Task.isCancelled { break }

        // Compute stats on background thread
        let text = decorator.item.previewableText
        let charCount = text.count
        let wordCount = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count

        await MainActor.run {
          decorator.item.characterCount = charCount
          decorator.item.wordCount = wordCount

          // Also pre-cache the text and hash in the decorator for instant display
          _ = decorator.text
          _ = decorator.textHash
        }

        // Small delay to avoid blocking other background work
        try? await Task.sleep(for: .milliseconds(10))
      }

      // Save changes to database
      await MainActor.run {
        try? Storage.shared.context.save()
      }
    }
  }

  @MainActor
  func backfillOCRIfNeeded() {
    ocrBackfillTask?.cancel()

    let itemsToProcess = all
    ocrBackfillTask = Task.detached(priority: .background) {
      for item in itemsToProcess {
        if Task.isCancelled { break }
        await MainActor.run {
          item.item.scheduleOCRIfNeeded()
        }
        try? await Task.sleep(for: .milliseconds(30))
      }
    }
  }

  @MainActor
  func refreshSearchResults() {
    guard !searchQuery.isEmpty else { return }
    applySearch()
  }

  @MainActor
  private func limitHistorySize(to maxSize: Int) {
    let unpinned = all.filter(\.isUnpinned)
    guard unpinned.count >= maxSize else { return }

    let itemsToDelete = Array(unpinned[maxSize...])
    guard !itemsToDelete.isEmpty else { return }

    search.invalidateCache()

    // Clean up images and remove from in-memory arrays
    for item in itemsToDelete {
      cleanup(item)
      sessionLog.removeValues { $0 == item.item }
    }

    all.removeAll { itemsToDelete.contains($0) }
    items.removeAll { itemsToDelete.contains($0) }

    // Batch delete from database with single save
    try? Storage.shared.context.transaction {
      for item in itemsToDelete {
        Storage.shared.context.delete(item.item)
      }
    }
    try? Storage.shared.context.save()
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    logger.info("Inserting item with id '\(item.title)'")
    Storage.shared.context.insert(item)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    search.invalidateCache()

    if #available(macOS 15.0, *) {
      try? History.shared.insertIntoStorage(item)
    } else {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      // It was already inserted after creation in Clipboard.swift
    }

    var removedItemIndex: Int?
    if let existingHistoryItem = findSimilarItem(item) {
      if isModified(item) == nil {
        item.contents = existingHistoryItem.contents
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      item.title = existingHistoryItem.title
      if !item.fromLodge {
        item.application = existingHistoryItem.application
      }
      logger.info("Removing duplicate item '\(item.title)'")
      Storage.shared.context.delete(existingHistoryItem)
      removedItemIndex = all.firstIndex(where: { $0.item == existingHistoryItem })
      if let removedItemIndex {
        all.remove(at: removedItemIndex)
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
    if let pin = item.pin {
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

      items = all
      invalidateFilterCaches()
      updateUnpinnedShortcuts()
      AppState.shared.popup.needsResize = true
    }

    return itemDecorator
  }

  @MainActor
  private func withLogging(_ msg: String, _ block: () throws -> Void) rethrows {
    // Use in-memory counts instead of database queries to avoid blocking main thread
    let beforeCount = all.count
    logger.info("\(msg) Before: items=\(beforeCount)")
    try? block()
    let afterCount = all.count
    logger.info("\(msg) After: items=\(afterCount)")
  }

  @MainActor
  func clear() {
    search.invalidateCache()
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

      // Note: HistoryItemContent is automatically deleted via cascade rule on HistoryItem.contents
      try? Storage.shared.context.transaction {
        try? Storage.shared.context.delete(
          model: HistoryItem.self,
          where: #Predicate { $0.pin == nil }
        )
      }
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
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
    withLogging("Clearing all history") {
      all.forEach { item in
        cleanup(item)
      }
      all.removeAll()
      sessionLog.removeAll()
      items = all
      invalidateFilterCaches()

      try? Storage.shared.context.delete(model: HistoryItem.self)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
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
    cleanup(item)
    withLogging("Removing history item") {
      Storage.shared.context.delete(item.item)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

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

    // Search in-memory `all` array for duplicates
    // This is more reliable than a database query with predicates on computed properties
    // and is fast for typical history sizes (up to a few thousand items)
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
