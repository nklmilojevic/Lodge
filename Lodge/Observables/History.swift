import AppKit
import Defaults
import Logging
import Observation
import Sauce

/// Popup state. HistoryService owns storage and ImageProcessingService owns image work.
@Observable
@MainActor
final class History {
  static let shared = History(repository: .shared, temporaryStorage: Storage.shared.loadError != nil)
  let logger = Logger(label: "com.nklmilojevic.Lodge")
  private(set) var items: [HistoryItemDecorator] = []
  private(set) var all: [HistoryItemDecorator] = []
  private(set) var isSearching = false
  private(set) var isLoaded = false
  var errorMessage: String?
  let temporaryStorage: Bool
  var selectedItem: HistoryItemDecorator? {
    willSet {
      guard selectedItem?.id != newValue?.id else { return }
      selectedItem?.isSelected = false
      selectedItem?.cleanupImages()
      newValue?.isSelected = true
    }
  }
  var onResultsChange: (Bool) -> Void = { _ in }
  var onClear: () -> Void = {}
  var onSelect: (HistoryItemDecorator) -> Void = { _ in }
  var onNewItem: (String) -> Void = { _ in }
  var onReady: () -> Void = {}

  var pinnedItems: [HistoryItemDecorator] { items.filter(\.isPinned) }
  var unpinnedItems: [HistoryItemDecorator] { items.filter(\.isUnpinned) }
  var visiblePinnedItems: [HistoryItemDecorator] { pinnedItems.filter(\.isVisible) }
  var visibleUnpinnedItems: [HistoryItemDecorator] { unpinnedItems.filter(\.isVisible) }
  var availablePins: [String] { _ = all; return service.availablePins }
  var storedByteCount: Int64 { _ = all; return service.byteCount }
  var exceedsDataLimit: Bool { _ = all; return service.byteCount > service.byteLimit }

  var searchQuery = "" {
    didSet {
      guard searchQuery != oldValue else { return }
      applySearch(selectFirst: true)
    }
  }

  @ObservationIgnored private let service: HistoryService
  @ObservationIgnored private let search = Search()
  @ObservationIgnored private let ocrSearchThrottler = Throttler(minimumDelay: 0.1)
  @ObservationIgnored private let images: ImageProcessingService
  @ObservationIgnored private let ocr: OCRService
  @ObservationIgnored private var loadTask: Task<Void, Error>?
  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private var captureTask: Task<Void, Never>?
  @ObservationIgnored private var observers: [Task<Void, Never>] = []
  @ObservationIgnored private var revision: UInt64 = 0
  @ObservationIgnored private var searchGeneration: UInt64 = 0
  @ObservationIgnored private var captureGeneration: UInt64 = 0
  @ObservationIgnored private var pendingCopies: [CapturedCopy] = []
  @ObservationIgnored private var pendingBytes = 0
  @ObservationIgnored private var itemsByID: [UUID: HistoryItemDecorator] = [:]
  @ObservationIgnored private var editGenerations: [UUID: UUID] = [:]

  init(repository: HistoryRepository, temporaryStorage: Bool = false,
       images: ImageProcessingService? = nil, ocr: OCRService? = nil, observePreferences: Bool = true) {
    service = HistoryService(repository: repository)
    self.temporaryStorage = temporaryStorage
    self.images = images ?? ImageProcessingService()
    self.ocr = ocr ?? OCRService()
    if observePreferences { observeDefaults() }
  }

  func load() async throws {
    guard !isLoaded else { return }
    if let loadTask { return try await loadTask.value }
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.service.load()
        self.isLoaded = true
        self.synchronize()
        self.onReady()
      } catch {
        self.report("History could not be loaded. Try again.")
        throw error
      }
    }
    loadTask = task
    defer { loadTask = nil }
    try await task.value
  }

  func receive(_ capture: CapturedCopy) {
    let bytes = capture.contents.reduce(0) { $0 + ($1.value?.count ?? 0) }
    guard pendingBytes + bytes <= 200 * 1024 * 1024 else {
      report("A copy could not be saved because other large copies are still being processed.")
      return
    }
    pendingCopies.append(capture)
    pendingBytes += bytes
    guard captureTask == nil else { return }
    let generation = captureGeneration
    captureTask = Task { [weak self] in
      while let self, !self.pendingCopies.isEmpty, !Task.isCancelled {
        let capture = self.pendingCopies.removeFirst()
        let worker = Task.detached(priority: .utility) { ContentProcessor.prepare(capture) }
        let prepared = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, generation == self.captureGeneration else { return }
        self.pendingBytes -= capture.contents.reduce(0) { $0 + ($1.value?.count ?? 0) }
        do { _ = try self.add(prepared) } catch { }
      }
      if let self, generation == self.captureGeneration { self.captureTask = nil }
    }
  }

  @discardableResult
  func add(_ prepared: PreparedCopy, title: String? = nil) throws -> HistoryItemDecorator {
    do {
      let previousIDs = Set(all.map(\.id))
      let item = try service.add(prepared, title: title)
      errorMessage = nil
      synchronize(changedID: item.uuid)
      guard let decorator = all.first(where: { $0.id == item.uuid }) else { throw HistoryError.storageLimit }
      if !previousIDs.contains(item.uuid) { onNewItem(item.title) }
      return decorator
    } catch {
      report((error as? HistoryError)?.errorDescription ?? "The copy could not be saved. Try again.")
      throw error
    }
  }

  @discardableResult
  func clear() -> Bool { remove(all.filter(\.isUnpinned), clearClipboard: true) }

  @discardableResult
  func clearAll() -> Bool { remove(all, clearClipboard: true) }

  @discardableResult
  func delete(_ item: HistoryItemDecorator?) -> Bool {
    guard let item else { return false }
    return remove([item], clearClipboard: false)
  }

  func select(_ item: HistoryItemDecorator?) {
    guard let item else { return }
    onSelect(item)
    searchQuery = ""
  }

  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }
    if item.isPinned {
      setPin(nil, for: item.item)
    } else if let pin = availablePins.first {
      setPin(pin, for: item.item)
    } else {
      report(HistoryError.noAvailablePin.errorDescription!)
    }
  }

  func setPin(_ pin: String?, for item: HistoryItem) {
    do {
      try service.setPin(pin, for: item)
      synchronize(changedID: item.uuid)
    } catch { report((error as? HistoryError)?.errorDescription ?? "The pin could not be saved.") }
  }

  func setTitle(_ title: String, for item: HistoryItem) {
    do {
      try service.setTitle(title, for: item)
      synchronize(changedID: item.uuid)
    } catch { report("The title could not be saved.") }
  }

  func edit(_ item: HistoryItem, text: String) async {
    let generation = UUID()
    editGenerations[item.uuid] = generation
    defer {
      if editGenerations[item.uuid] == generation { editGenerations.removeValue(forKey: item.uuid) }
    }
    let capture = CapturedCopy(contents: [ContentSnapshot(type: NSPasteboard.PasteboardType.string.rawValue,
                                                         value: Data(text.utf8))],
                               application: item.application, copiedAt: item.lastCopiedAt, changeCount: 0)
    let prepared = await Task.detached(priority: .userInitiated) { ContentProcessor.prepare(capture) }.value
    guard !Task.isCancelled, editGenerations[item.uuid] == generation,
          service.items.contains(where: { $0.uuid == item.uuid }) else { return }
    do {
      try service.edit(item, prepared: prepared)
      synchronize(changedID: item.uuid)
    } catch { report((error as? HistoryError)?.errorDescription ?? "The text could not be saved.") }
  }

  func enforceLimits() {
    do {
      try service.enforceLimits()
      synchronize()
    } catch { report("The history data limit could not be applied.") }
  }

  func item(withId id: UUID) -> HistoryItemDecorator? { itemsByID[id] }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else { return nil }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
    guard HistoryItemAction(flags) != .unknown else { return nil }
    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains { $0.key == key } }
  }

  func waitForSearch() async { await searchTask?.value }
  func waitForCopies() async { await captureTask?.value }

  func refreshSearchResults(invalidateCache: Bool = false) {
    if invalidateCache { revision &+= 1 }
    applySearch(selectFirst: false)
  }

  func stop() {
    loadTask?.cancel()
    observers.forEach { $0.cancel() }
    observers.removeAll()
    searchTask?.cancel()
    ocrSearchThrottler.cancel()
    cancelCopies()
    ocr.cancelAll()
  }

  private func report(_ message: String) {
    errorMessage = message
    // Do not include clipboard text or model descriptions in logs.
    logger.error("A history operation failed")
  }

  private func remove(_ removed: [HistoryItemDecorator], clearClipboard: Bool) -> Bool {
    do {
      try service.delete(removed.map(\.item))
      if clearClipboard { cancelCopies() }
      synchronize()
      if clearClipboard { onClear() }
      return true
    } catch {
      report("History could not be deleted. Try again.")
      return false
    }
  }

  private func cancelCopies() {
    captureGeneration &+= 1
    captureTask?.cancel()
    captureTask = nil
    pendingCopies.removeAll()
    pendingBytes = 0
  }

  private func synchronize(changedID: UUID? = nil) {
    let retained = Set(service.items.map(\.uuid))
    for decorator in all where !retained.contains(decorator.id) || decorator.id == changedID {
      decorator.cleanupImages()
      images.cache.remove(decorator.id)
      ocr.cancel(decorator.id)
    }
    let previous = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    all = service.items.map { item in
      if let decorator = previous[item.uuid] {
        if item.uuid == changedID { decorator.refresh() }
        return decorator
      }
      let decorator = HistoryItemDecorator(item, images: images)
      decorator.onImageMetadata = { [weak self, weak item] width, height in
        guard let self, let item else { return }
        do { try self.service.setImageMetadata(for: item, text: nil, width: width, height: height) }
        catch { self.report("Image details could not be saved.") }
      }
      return decorator
    }
    if let selectedItem, !retained.contains(selectedItem.id) { self.selectedItem = nil }
    if selectedItem?.id == changedID { selectedItem?.ensurePreviewImage() }
    revision &+= 1
    applySearch(selectFirst: false)
    backfillOCRIfNeeded()
  }

  func backfillOCRIfNeeded() {
    guard Defaults[.ocrInImages] else { ocr.cancelAll(); return }
    for decorator in all where decorator.hasImage && decorator.item.ocrText == nil {
      let item = decorator.item
      let fingerprint = item.contentFingerprint
      ocr.enqueue(id: item.uuid, source: { [weak item] in item?.imageSource }) { [weak self, weak item] result in
        guard let self, let item, item.contentFingerprint == fingerprint,
              self.service.items.contains(where: { $0.uuid == item.uuid }) else { return }
        do {
          let pruned = try self.service.setImageMetadata(for: item, text: result.text, normalizedText: result.normalizedText,
                                                         width: result.width, height: result.height)
          if pruned { self.synchronize(); return }
          self.revision &+= 1
          self.ocrSearchThrottler.throttle { [weak self] in self?.applySearch(selectFirst: false) }
        } catch { self.report("Image text could not be saved.") }
      }
    }
  }

  private func applySearch(selectFirst: Bool) {
    searchTask?.cancel()
    searchGeneration &+= 1
    let generation = searchGeneration
    if searchQuery.isEmpty {
      isSearching = false
      updateItems(all.map { Search.SearchResult(object: $0) }, selectFirst: selectFirst)
      return
    }
    isSearching = true
    let query = searchQuery
    let snapshot = all
    let revision = revision
    searchTask = Task { [weak self] in
      guard let self else { return }
      let results = await self.search.search(string: query, within: snapshot, revision: revision)
      guard !Task.isCancelled, generation == self.searchGeneration else { return }
      self.isSearching = false
      self.updateItems(results, selectFirst: selectFirst)
    }
  }

  private func updateItems(_ results: [Search.SearchResult], selectFirst: Bool) {
    items = results.map { result in
      result.object.highlight(searchQuery, result.ranges)
      return result.object
    }
    itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    if let selectedItem, itemsByID[selectedItem.id] == nil { self.selectedItem = nil }
    updateShortcuts()
    onResultsChange(selectFirst)
  }

  private func updateShortcuts() {
    for item in all {
      item.shortcuts = item.item.pin.map { KeyShortcut.create(character: $0) } ?? []
    }
    for (index, item) in visibleUnpinnedItems.prefix(10).enumerated() {
      item.shortcuts = KeyShortcut.create(character: String(index + 1))
    }
  }

  private func observeDefaults() {
    observers.append(Task { [weak self] in
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        guard let self else { return }; self.updateShortcuts()
      }
    })
    observers.append(Task { [weak self] in
      for await _ in Defaults.updates(.sortBy, initial: false) {
        guard let self else { return }; self.service.sort(); self.synchronize()
      }
    })
    observers.append(Task { [weak self] in
      for await _ in Defaults.updates(.pinTo, initial: false) {
        guard let self else { return }; self.service.sort(); self.synchronize()
      }
    })
    observers.append(Task { [weak self] in
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        guard let self else { return }
        self.all.forEach { $0.refresh() }
        self.revision &+= 1
        self.applySearch(selectFirst: false)
      }
    })
    observers.append(Task { [weak self] in
      for await _ in Defaults.updates(.searchMode, initial: false) {
        guard let self else { return }; self.applySearch(selectFirst: true)
      }
    })
    observers.append(Task { [weak self] in
      for await _ in Defaults.updates(.ocrInImages, initial: false) {
        guard let self else { return }
        self.backfillOCRIfNeeded()
        self.revision &+= 1
        self.applySearch(selectFirst: false)
      }
    })
    observers.append(Task { [weak self] in
      for await _ in Defaults.updates(.size, initial: false) {
        guard let self else { return }; self.enforceLimits()
      }
    })
    observers.append(Task { [weak self] in
      for await _ in Defaults.updates(.historyDataLimitMB, initial: false) {
        guard let self else { return }; self.enforceLimits()
      }
    })
  }
}
