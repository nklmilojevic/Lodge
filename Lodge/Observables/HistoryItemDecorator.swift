import AppKit.NSWorkspace
import Defaults
import Foundation
import Observation
import Sauce

@Observable
class HistoryItemDecorator: Identifiable, Hashable {
  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  // Cap preview image size to reduce memory usage while maintaining quality
  static var previewImageSize: NSSize {
    let maxDimension: CGFloat = 1200 // Good quality without excessive memory
    let screenSize = NSScreen.forPopup?.visibleFrame.size ?? NSSize(width: 1200, height: 900)
    return NSSize(
      width: min(screenSize.width, maxDimension),
      height: min(screenSize.height, maxDimension)
    )
  }

  let id = UUID()

  var title: String = ""
  var attributedTitle: AttributedString?

  var isVisible: Bool = true
  var isSelected: Bool = false
  var shortcuts: [KeyShortcut] = []

  @ObservationIgnored
  private var cachedApplication: String??  // Double optional: nil = not computed, .some(nil) = computed but no app

  var application: String? {
    if let cached = cachedApplication {
      return cached
    }

    let result: String?
    if item.universalClipboard {
      result = "iCloud"
    } else if let bundle = item.application,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
      result = url.deletingPathExtension().lastPathComponent
    } else {
      result = nil
    }

    cachedApplication = .some(result)
    return result
  }

  @ObservationIgnored
  var previewImageGenerationTask: Task<Void, Never>?
  var previewImage: NSImage?
  var applicationImage: ApplicationImage

  @ObservationIgnored
  private var cachedText: String?
  @ObservationIgnored
  private var cachedTextHash: Int?
  @ObservationIgnored
  private var cachedCharacterCount: Int?
  @ObservationIgnored
  private var cachedWordCount: Int?
  @ObservationIgnored
  private var cachedContentTypeDescription: String?
  @ObservationIgnored
  private var pinObservationTask: Task<Void, Never>?
  @ObservationIgnored
  private var titleObservationTask: Task<Void, Never>?

  // Limit preview text for performance - large text causes UI lag
  // 5k characters is enough for previewing while keeping SwiftUI responsive
  private static let maxPreviewTextLength = 5_000

  var text: String {
    // Return cached text if available (pre-cached at load time)
    if let cachedText {
      return cachedText
    }

    // Fallback: compute synchronously (should rarely happen if pre-caching works)
    let text = item.previewableText.shortened(to: Self.maxPreviewTextLength)
    cachedText = text
    cachedTextHash = text.hashValue
    return text
  }

  /// Cached hash of the text for O(1) change detection in views
  var textHash: Int {
    if let cachedTextHash {
      return cachedTextHash
    }
    // Trigger text caching which also caches the hash
    _ = text
    return cachedTextHash ?? 0
  }

  /// Pre-cache text and hash from background thread computation.
  /// Called by History during startup.
  func precacheText(_ text: String, hash: Int) {
    guard cachedText == nil else { return }  // Don't overwrite if already cached
    cachedText = text
    cachedTextHash = hash
  }

  /// Check if text is already cached (for avoiding redundant computation)
  var isTextCached: Bool { cachedText != nil }

  var ocrText: String { item.ocrText ?? "" }

  /// Fast check - uses content types, doesn't load image data
  var hasImage: Bool { item.hasImageContent }

  var imageSizeDescription: String? {
    // Read the dimensions from the image headers rather than decoding the bitmap.
    guard let size = item.imagePixelSize else { return nil }
    let width = Int(size.width)
    let height = Int(size.height)
    return "\(NSLocalizedString("detail_panel_type_image", comment: "")) (\(width)×\(height))"
  }

  /// Character count - stored in the database, computed once when item is copied
  var characterCount: Int {
    // Use stored value from database (computed once at copy time)
    // Fall back to on-demand computation for legacy items without stored stats
    if item.characterCount > 0 {
      return item.characterCount
    }

    // Legacy fallback: compute and cache for items without stored stats
    if let cachedCharacterCount {
      return cachedCharacterCount
    }
    scheduleTextStatsComputation()
    return cachedCharacterCount ?? 0
  }

  /// Word count - stored in the database, computed once when item is copied
  var wordCount: Int {
    // Use stored value from database (computed once at copy time)
    // Fall back to on-demand computation for legacy items without stored stats
    if item.wordCount > 0 {
      return item.wordCount
    }

    // Legacy fallback: compute and cache for items without stored stats
    if let cachedWordCount {
      return cachedWordCount
    }
    scheduleTextStatsComputation()
    return cachedWordCount ?? 0
  }

  @ObservationIgnored
  private var textStatsTask: Task<Void, Never>?

  /// Fallback computation for legacy items that don't have stored stats.
  /// Also updates the database so future accesses are instant.
  private func scheduleTextStatsComputation() {
    guard textStatsTask == nil else { return }

    let textContent = text

    textStatsTask = Task.detached(priority: .userInitiated) { [weak self] in
      let charCount = textContent.count
      let wdCount = textContent.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count

      await MainActor.run {
        guard let self else { return }
        self.cachedCharacterCount = charCount
        self.cachedWordCount = wdCount

        // Backfill the database so we don't compute again
        if self.item.characterCount == 0 {
          self.item.characterCount = charCount
          self.item.wordCount = wdCount
        }
      }
    }
  }

  var contentTypeDescription: String {
    if let cached = cachedContentTypeDescription {
      return cached
    }

    let description = computeContentTypeDescription()
    cachedContentTypeDescription = description
    return description
  }

  private func computeContentTypeDescription() -> String {
    let types = item.contents.map { $0.type }

    // Check for images first - use hasImage which is cheaper than item.image
    if hasImage {
      if types.contains(NSPasteboard.PasteboardType.png.rawValue) {
        return NSLocalizedString("detail_panel_type_image_png", comment: "")
      } else if types.contains(NSPasteboard.PasteboardType.tiff.rawValue) {
        return NSLocalizedString("detail_panel_type_image_tiff", comment: "")
      } else if types.contains("public.jpeg") {
        return NSLocalizedString("detail_panel_type_image_jpeg", comment: "")
      } else if types.contains("public.heic") {
        return NSLocalizedString("detail_panel_type_image_heic", comment: "")
      }
      return NSLocalizedString("detail_panel_type_image", comment: "")
    }

    // Check for file URLs
    if !item.fileURLs.isEmpty {
      return NSLocalizedString("detail_panel_type_file_url", comment: "")
    }

    // Check for text types
    let hasRTF = types.contains(NSPasteboard.PasteboardType.rtf.rawValue)
    let hasHTML = types.contains(NSPasteboard.PasteboardType.html.rawValue)
    let hasPlainText = types.contains(NSPasteboard.PasteboardType.string.rawValue)

    let textTypeCount = [hasRTF, hasHTML, hasPlainText].filter { $0 }.count

    if textTypeCount > 1 {
      return NSLocalizedString("detail_panel_type_formatted", comment: "")
    } else if hasRTF {
      return NSLocalizedString("detail_panel_type_text_rich", comment: "")
    } else if hasHTML {
      return NSLocalizedString("detail_panel_type_text_html", comment: "")
    } else if hasPlainText {
      return NSLocalizedString("detail_panel_type_text_plain", comment: "")
    }

    return NSLocalizedString("detail_panel_type_mixed", comment: "")
  }

  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }

  func hash(into hasher: inout Hasher) {
    // We need to hash title and attributedTitle, so SwiftUI knows it needs to update the view if they chage
    hasher.combine(id)
    hasher.combine(title)
    hasher.combine(attributedTitle)
  }

  private(set) var item: HistoryItem

  init(_ item: HistoryItem, shortcuts: [KeyShortcut] = []) {
    self.item = item
    self.shortcuts = shortcuts
    self.title = item.title
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)

    synchronizeItemPin()
    synchronizeItemTitle()
  }

  deinit {
    // All of these are @ObservationIgnored, so they are safe to touch here.
    pinObservationTask?.cancel()
    titleObservationTask?.cancel()
    textStatsTask?.cancel()
    previewImageGenerationTask?.cancel()
  }

  @MainActor
  func ensurePreviewImage() {
    // `hasImage` is a content-type check, so this no longer decodes just to
    // find out whether there is an image at all.
    guard hasImage else {
      return
    }
    guard previewImage == nil else {
      return
    }
    guard previewImageGenerationTask == nil else {
      return
    }
    guard let data = item.imageData else {
      return
    }

    // Captured on the main thread - `previewImageSize` reads NSScreen.
    let targetSize = HistoryItemDecorator.previewImageSize
    let maxPixelSize = Int(max(targetSize.width, targetSize.height))

    previewImageGenerationTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let cgImage = HistoryItem.makeThumbnailCGImage(from: data, maxPixelSize: maxPixelSize),
            !Task.isCancelled else {
        await MainActor.run { self?.previewImageGenerationTask = nil }
        return
      }

      let size = NSSize(width: cgImage.width, height: cgImage.height)
      await MainActor.run {
        guard let self else { return }
        self.previewImage = NSImage(cgImage: cgImage, size: size)
        self.previewImageGenerationTask = nil
      }
    }
  }

  @MainActor
  func cleanupImages() {
    previewImageGenerationTask?.cancel()
    // Clearing this lets a later `ensurePreviewImage()` regenerate the preview.
    previewImageGenerationTask = nil
    previewImage?.recache()
    previewImage = nil
    // Drop the decoded full-resolution bitmap too, otherwise evicted and deleted
    // items keep it resident for the lifetime of the process.
    item.releaseCachedImages()
  }

  @MainActor
  private func generatePreviewImage() {
    guard let image = item.image else {
      return
    }
    previewImage = image.resized(to: HistoryItemDecorator.previewImageSize)
  }

  @MainActor
  func sizeImages() {
    generatePreviewImage()
  }

  func highlight(_ query: String, _ ranges: [Range<String.Index>]) {
    guard !query.isEmpty, !title.isEmpty else {
      attributedTitle = nil
      return
    }

    var attributedString = AttributedString(title.shortened(to: 500))
    for range in ranges {
      if let lowerBound = AttributedString.Index(range.lowerBound, within: attributedString),
         let upperBound = AttributedString.Index(range.upperBound, within: attributedString) {
        switch Defaults[.highlightMatch] {
        case .bold:
          attributedString[lowerBound..<upperBound].font = .bold(.body)()
        case .italic:
          attributedString[lowerBound..<upperBound].font = .italic(.body)()
        case .underline:
          attributedString[lowerBound..<upperBound].underlineStyle = .single
        default:
          attributedString[lowerBound..<upperBound].backgroundColor = .findHighlightColor
          attributedString[lowerBound..<upperBound].foregroundColor = .black
        }
      }
    }

    attributedTitle = attributedString
  }

  @MainActor
  func togglePin() {
    if item.pin != nil {
      item.pin = nil
    } else {
      let pin = HistoryItem.randomAvailablePin
      item.pin = pin
    }
  }

  // `guard let self` must stay inside the loop. Unwrapping it once outside held a
  // strong reference for the whole (never-ending) task, so the decorator - and via
  // it the HistoryItem and its decoded bitmaps - could never be deallocated.
  private func synchronizeItemPin() {
    pinObservationTask?.cancel()
    pinObservationTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        if let pin = self.item.pin {
          self.shortcuts = KeyShortcut.create(character: pin)
        } else {
          self.shortcuts = []
        }
        await Self.waitForChange { [weak self] in _ = self?.item.pin }
      }
    }
  }

  private func synchronizeItemTitle() {
    titleObservationTask?.cancel()
    titleObservationTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        self.title = self.item.title
        self.invalidateTextCache()
        await Self.waitForChange { [weak self] in _ = self?.item.title }
      }
    }
  }

  /// Suspends until a property read by `track` changes, or the surrounding task is
  /// cancelled. Holds no reference to the decorator while suspended, and resumes on
  /// cancellation so `deinit` can actually tear the observation loops down.
  private static func waitForChange(_ track: @escaping () -> Void) async {
    let resumer = Resumer()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        resumer.attach(continuation)
        _ = withObservationTracking(track) { resumer.fire() }
      }
    } onCancel: {
      resumer.fire()
    }
  }

  /// Resumes a continuation exactly once. `onChange` and `onCancel` can both fire,
  /// from any thread, so this needs to be locked.
  private final class Resumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func attach(_ continuation: CheckedContinuation<Void, Never>) {
      lock.lock()
      if fired {
        lock.unlock()
        continuation.resume()
        return
      }
      self.continuation = continuation
      lock.unlock()
    }

    func fire() {
      lock.lock()
      guard !fired else {
        lock.unlock()
        return
      }
      fired = true
      let continuation = self.continuation
      self.continuation = nil
      lock.unlock()
      continuation?.resume()
    }
  }

  private func invalidateTextCache() {
    cachedText = nil
    cachedTextHash = nil
    cachedCharacterCount = nil
    cachedWordCount = nil
    cachedContentTypeDescription = nil
    textStatsTask?.cancel()
    textStatsTask = nil
  }
}
