import AppKit
import CryptoKit
import Defaults
import ImageIO
import Sauce
import SwiftData
import Vision

@Model
class HistoryItem {
  private static let ocrMaxLength = 10_000

  // Pre-compiled regex patterns for generateTitle() to avoid repeated compilation
  private static let leadingSpacesRegex = try? NSRegularExpression(pattern: "^ +")
  private static let trailingSpacesRegex = try? NSRegularExpression(pattern: " +$")
  @MainActor
  static var supportedPins: Set<String> {
    // "a" reserved for select all
    // "q" reserved for quit
    // "v" reserved for paste
    // "w" reserved for close window
    // "z" reserved for undo/redo
    var keys = Set([
      "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l",
      "m", "n", "o", "p", "r", "s", "t", "u", "x", "y"
    ])

    if let deleteKey = KeyChord.deleteKey,
       let character = Sauce.shared.character(for: Int(deleteKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }

    if let pinKey = KeyChord.pinKey,
       let character = Sauce.shared.character(for: Int(pinKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }

    return keys
  }

  @MainActor
  static var availablePins: [String] {
    let descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin != nil }
    )
    let pins = try? Storage.shared.context.fetch(descriptor).compactMap({ $0.pin })
    let assignedPins = Set(pins ?? [])
    return Array(supportedPins.subtracting(assignedPins))
  }

  @MainActor
  static var randomAvailablePin: String { availablePins.randomElement() ?? "" }

  private static let transientTypes: [String] = [
    NSPasteboard.PasteboardType.modified.rawValue,
    NSPasteboard.PasteboardType.fromLodge.rawValue,
    NSPasteboard.PasteboardType.linkPresentationMetadata.rawValue,
    NSPasteboard.PasteboardType.customWebKitPasteboardData.rawValue,
    NSPasteboard.PasteboardType.source.rawValue,
    NSPasteboard.PasteboardType.customChromiumWebData.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceUrl.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceToken.rawValue,
    NSPasteboard.PasteboardType.notesRichText.rawValue
  ]

  var application: String?
  // Note: Indexes would improve query performance but require macOS 15+
  // @Attribute(.index) is not available in macOS 14's SwiftData
  var firstCopiedAt: Date = Date.now
  var lastCopiedAt: Date = Date.now
  var numberOfCopies: Int = 1
  var pin: String?
  var title = ""
  var ocrText: String?
  var contentFingerprint = ""

  // Pre-computed text statistics stored in database to avoid on-demand calculation
  var characterCount: Int = 0
  var wordCount: Int = 0

  // Cached parsed values to avoid repeated parsing
  @Transient private var cachedRtf: NSAttributedString?
  @Transient private var cachedHtml: NSAttributedString?
  @Transient private var cachedImage: NSImage?
  @Transient private var cachedUniversalClipboardImageData: Data?
  @Transient private var didLoadUniversalClipboardImageData = false
  @Transient private var isOCRInProgress = false

  @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
  var contents: [HistoryItemContent] = []

  init(contents: [HistoryItemContent] = []) {
    self.firstCopiedAt = firstCopiedAt
    self.lastCopiedAt = lastCopiedAt
    self.contents = contents
  }

  func supersedes(_ item: HistoryItem) -> Bool {
    // Build a set for O(1) lookups instead of O(n) nested iteration
    let myContentKeys = Set(contents.map { ContentKey(type: $0.type, value: $0.value) })

    return item.contents
      .filter { content in
        !Self.transientTypes.contains(content.type)
      }
      .allSatisfy { content in
        myContentKeys.contains(ContentKey(type: content.type, value: content.value))
      }
  }

  /// Helper struct for efficient content comparison in supersedes()
  private struct ContentKey: Hashable {
    let type: String
    let value: Data?
  }

  /// Compute and store text statistics. Call this when the item is first created.
  func computeTextStats() {
    let textContent = previewableText
    characterCount = textContent.count
    wordCount = textContent.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
  }

  /// Creates a stable digest once so common exact duplicates can be found in O(1).
  func computeContentFingerprint() {
    let digests = contents
      .filter { !Self.transientTypes.contains($0.type) }
      .map { content -> String in
        var hasher = SHA256()
        hasher.update(data: Data(content.type.utf8))
        hasher.update(data: Data([0]))
        if let value = content.value {
          hasher.update(data: value)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
      }
      .sorted()

    guard !digests.isEmpty else {
      contentFingerprint = ""
      return
    }

    let digest = SHA256.hash(data: Data(digests.joined(separator: ":").utf8))
    contentFingerprint = digest.map { String(format: "%02x", $0) }.joined()
  }

  @MainActor
  func generateTitle() -> String {
    guard !hasImageContent else {
      scheduleOCRIfNeeded()
      return title
    }

    // 1k characters is trade-off for performance
    var title = previewableText.shortened(to: 1_000)

    if Defaults[.showSpecialSymbols] {
      // Replace leading spaces with visible dots using pre-compiled regex
      if let regex = Self.leadingSpacesRegex {
        let range = NSRange(title.startIndex..., in: title)
        if let match = regex.firstMatch(in: title, range: range),
           let swiftRange = Range(match.range, in: title) {
          title = title.replacingOccurrences(of: " ", with: "·", range: swiftRange)
        }
      }
      // Replace trailing spaces with visible dots using pre-compiled regex
      if let regex = Self.trailingSpacesRegex {
        let range = NSRange(title.startIndex..., in: title)
        if let match = regex.firstMatch(in: title, range: range),
           let swiftRange = Range(match.range, in: title) {
          title = title.replacingOccurrences(of: " ", with: "·", range: swiftRange)
        }
      }
      title = title
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: "⇥")
    } else {
      title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return title
  }

  var previewableText: String {
    if !fileURLs.isEmpty {
      fileURLs
        .compactMap { $0.absoluteString.removingPercentEncoding }
        .joined(separator: "\n")
    } else if let text = text, !text.isEmpty {
      text
    } else if let rtf = rtf, !rtf.string.isEmpty {
      rtf.string
    } else if let html = html, !html.string.isEmpty {
      html.string
    } else {
      title
    }
  }

  var fileURLs: [URL] {
    guard !universalClipboardText else {
      return []
    }

    return allContentData([.fileURL])
      .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
  }

  var htmlData: Data? { contentData([.html]) }
  var html: NSAttributedString? {
    if let cachedHtml {
      return cachedHtml
    }
    guard let data = htmlData else {
      return nil
    }
    let parsed = NSAttributedString(html: data, documentAttributes: nil)
    cachedHtml = parsed
    return parsed
  }

  var imageData: Data? {
    var data: Data?
    data = contentData([.tiff, .png, .jpeg, .heic])
    // Load image from file URL if it points to an image file
    // (Universal Clipboard or apps like Telegram that copy images as file URLs)
    if data == nil, (universalClipboardImage || fileURLImage), let url = fileURLs.first {
      // Use cached data if available
      if didLoadUniversalClipboardImageData {
        return cachedUniversalClipboardImageData
      }
      // Load and cache (still synchronous but cached for subsequent access)
      data = try? Data(contentsOf: url)
      cachedUniversalClipboardImageData = data
      didLoadUniversalClipboardImageData = true
    }

    return data
  }

  /// Preload image data from file URLs in background to avoid blocking main thread
  @MainActor
  func preloadUniversalClipboardImageData() {
    guard !didLoadUniversalClipboardImageData,
          (universalClipboardImage || fileURLImage),
          let url = fileURLs.first else {
      return
    }

    Task(priority: .utility) { [weak self] in
      let data = await Self.loadData(from: url)
      guard let self else { return }
      self.cachedUniversalClipboardImageData = data
      self.didLoadUniversalClipboardImageData = true
    }
  }

  var image: NSImage? {
    if let cachedImage {
      return cachedImage
    }
    guard let data = imageData else {
      return nil
    }
    let image = NSImage(data: data)
    cachedImage = image
    return image
  }

  /// Pixel dimensions read from the image headers, without decoding the bitmap.
  var imagePixelSize: NSSize? {
    if let cachedImage {
      return cachedImage.size
    }

    guard let data = imageData,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
      return nil
    }

    return NSSize(width: width, height: height)
  }

  /// Releases decoded image caches. They are recreated on demand, so this is safe
  /// to call for any item that is no longer on screen.
  func releaseCachedImages() {
    cachedImage = nil
    cachedUniversalClipboardImageData = nil
    didLoadUniversalClipboardImageData = false
  }

  /// Decodes a downsampled image straight from the source data, so the
  /// full-resolution bitmap is never materialized.
  static func makeThumbnailCGImage(from data: Data, maxPixelSize: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return nil
    }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]

    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  var rtfData: Data? { contentData([.rtf]) }
  var rtf: NSAttributedString? {
    if let cachedRtf {
      return cachedRtf
    }
    guard let data = rtfData else {
      return nil
    }
    let parsed = NSAttributedString(rtf: data, documentAttributes: nil)
    cachedRtf = parsed
    return parsed
  }

  var text: String? {
    guard let data = contentData([.string]) else {
      return nil
    }

    return String(data: data, encoding: .utf8)
  }

  var modified: Int? {
    guard let data = contentData([.modified]),
          let modified = String(data: data, encoding: .utf8) else {
      return nil
    }

    return Int(modified)
  }

  var fromLodge: Bool { contentData([.fromLodge]) != nil }
  var universalClipboard: Bool { contentData([.universalClipboard]) != nil }

  /// Fast check for image content without loading data - just checks content types
  var hasImageContent: Bool {
    let imageTypes: Set<String> = [
      NSPasteboard.PasteboardType.tiff.rawValue,
      NSPasteboard.PasteboardType.png.rawValue,
      "public.jpeg",
      "public.heic"
    ]
    return contents.contains { imageTypes.contains($0.type) } || universalClipboardImage || fileURLImage
  }

  private var universalClipboardImage: Bool { universalClipboard && fileURLs.first?.pathExtension == "jpeg" }

  /// Check if file URL points to an image file (for apps like Telegram that copy images as file URLs)
  private var fileURLImage: Bool {
    guard let url = fileURLs.first else { return false }
    let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "tiff", "tif", "heic", "webp", "bmp"]
    return imageExtensions.contains(url.pathExtension.lowercased())
  }
  private var universalClipboardText: Bool {
    universalClipboard && contentData([.html, .tiff, .png, .jpeg, .rtf, .string, .heic]) != nil
  }

  private func contentData(_ types: [NSPasteboard.PasteboardType]) -> Data? {
    let content = contents.first(where: { content in
      return types.contains(NSPasteboard.PasteboardType(content.type))
    })

    return content?.value
  }

  private func allContentData(_ types: [NSPasteboard.PasteboardType]) -> [Data] {
    return contents
      .filter { types.contains(NSPasteboard.PasteboardType($0.type)) }
      .compactMap { $0.value }
  }

  @MainActor
  func scheduleOCRIfNeeded() {
    guard Defaults[.ocrInImages], ocrText == nil, !isOCRInProgress else {
      return
    }

    let embeddedData = contentData([.tiff, .png, .jpeg, .heic])
    let fileURL = embeddedData == nil && (universalClipboardImage || fileURLImage) ? fileURLs.first : nil
    guard embeddedData != nil || fileURL != nil else { return }

    isOCRInProgress = true
    Task(priority: .utility) { [weak self] in
      let data: Data?
      if let embeddedData {
        data = embeddedData
      } else if let fileURL {
        data = await Self.loadData(from: fileURL)
      } else {
        data = nil
      }

      guard let self else { return }
      guard let data, let recognizedText = await Self.recognizeText(in: data) else {
        self.isOCRInProgress = false
        return
      }

      self.isOCRInProgress = false
      self.ocrText = recognizedText
      if !History.shared.searchQuery.isEmpty {
        History.shared.refreshSearchResults(invalidateCache: true)
      }
    }
  }

  private nonisolated static func loadData(from url: URL) async -> Data? {
    await Task.detached(priority: .utility) {
      try? Data(contentsOf: url)
    }.value
  }

  private nonisolated static func recognizeText(in data: Data) async -> String? {
    await Task.detached(priority: .utility) { () -> String? in
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
      }

      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .fast

      do {
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
      } catch {
        return nil
      }

      return (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
        .shortened(to: Self.ocrMaxLength)
    }.value
  }
}
