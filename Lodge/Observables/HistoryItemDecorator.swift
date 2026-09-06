import AppKit
import Defaults
import Observation

@Observable
@MainActor
final class HistoryItemDecorator: Identifiable, Hashable {
  nonisolated let id: UUID
  nonisolated static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool { lhs.id == rhs.id }
  nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

  let item: HistoryItem
  var title: String
  var attributedTitle: AttributedString?
  var isVisible = true
  var isSelected = false
  var shortcuts: [KeyShortcut] = []
  var applicationImage: ApplicationImage
  var previewImage: NSImage?
  var previewFailed = false
  var onImageMetadata: (Int, Int) -> Void = { _, _ in }
  @ObservationIgnored private let images: ImageProcessingService
  @ObservationIgnored private var previewTask: Task<Void, Never>?
  @ObservationIgnored private var previewGeneration: UInt64 = 0
  @ObservationIgnored private var cachedApplication: String??

  init(_ item: HistoryItem, shortcuts: [KeyShortcut] = [], images: ImageProcessingService? = nil) {
    self.item = item
    self.id = item.uuid
    self.title = item.title
    self.shortcuts = shortcuts
    self.images = images ?? .shared
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)
    refresh()
  }

  var application: String? {
    if let cachedApplication { return cachedApplication }
    let name: String?
    if item.universalClipboard {
      name = "iCloud"
    } else if let bundle = item.application, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
      name = url.deletingPathExtension().lastPathComponent
    } else { name = nil }
    cachedApplication = .some(name)
    return name
  }

  var text: String { item.previewText ?? String(item.previewableText.prefix(ContentProcessor.previewLength)) }
  var fullText: String { item.previewableText }
  var searchableText: String { item.searchText ?? item.previewableText }
  var isTextTruncated: Bool { characterCount > ContentProcessor.previewLength }
  var characterCount: Int { item.metadataVersion > 0 ? item.characterCount : fullText.count }
  var wordCount: Int { item.metadataVersion > 0 ? item.wordCount : fullText.split(whereSeparator: \.isWhitespace).count }
  var ocrText: String { item.ocrText ?? "" }
  var hasImage: Bool { item.hasImageContent }
  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }
  var contentTypeDescription: String { computeContentTypeDescription() }

  var imageSizeDescription: String? {
    guard hasImage else { return nil }
    let label = NSLocalizedString("detail_panel_type_image", comment: "")
    guard item.imageWidth > 0, item.imageHeight > 0 else { return label }
    return "\(label) (\(item.imageWidth)×\(item.imageHeight))"
  }

  func refresh() {
    title = item.pin != nil ? item.title : item.generateTitle()
    attributedTitle = nil
    cachedApplication = nil
    applicationImage = ApplicationImageCache.shared.getImage(item: item)
    shortcuts = item.pin.map { KeyShortcut.create(character: $0) } ?? []
  }

  func ensurePreviewImage() {
    guard hasImage, previewImage == nil, previewTask == nil else { return }
    let generation = previewGeneration
    previewFailed = false
    previewTask = Task { [weak self] in
      guard let self else { return }
      let result = await self.images.preview(for: self.id) { self.item.imageSource }
      guard !Task.isCancelled, generation == self.previewGeneration else { return }
      if let result {
        self.previewImage = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
        self.onImageMetadata(result.width, result.height)
      } else { self.previewFailed = true }
      self.previewTask = nil
    }
  }

  func waitForPreview() async { await previewTask?.value }

  func cleanupImages() {
    previewGeneration &+= 1
    previewTask?.cancel()
    previewTask = nil
    previewImage = nil
    previewFailed = false
    item.releaseCachedImages()
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

}
