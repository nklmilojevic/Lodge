import AppKit
import CryptoKit
import Defaults
import ImageIO
import Sauce
import SwiftData

@Model
class HistoryItem {

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

  var uuid: UUID = UUID()
  var searchText: String?
  var normalizedSearchText: String?
  var normalizedOCRText: String?
  var previewText: String?
  var metadataVersion: Int = 0
  var payloadByteCount: Int64 = 0
  var imageWidth: Int = 0
  var imageHeight: Int = 0
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
  @Transient private var cachedImage: NSImage?
  @Transient private var cachedUniversalClipboardImageData: Data?
  @Transient private var didLoadUniversalClipboardImageData = false

  @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
  var contents: [HistoryItemContent] = []

  init(contents: [HistoryItemContent] = []) {
    self.firstCopiedAt = firstCopiedAt
    self.lastCopiedAt = lastCopiedAt
    self.contents = contents
  }

  @MainActor
  func rollbackAction() -> () -> Void {
    let uuid = uuid
    let normalizedSearchText = normalizedSearchText
    let normalizedOCRText = normalizedOCRText
    let application = application
    let firstCopiedAt = firstCopiedAt
    let lastCopiedAt = lastCopiedAt
    let numberOfCopies = numberOfCopies
    let pin = pin
    let title = title
    let ocrText = ocrText
    let contentFingerprint = contentFingerprint
    let characterCount = characterCount
    let wordCount = wordCount
    let searchText = searchText
    let previewText = previewText
    let metadataVersion = metadataVersion
    let payloadByteCount = payloadByteCount
    let imageWidth = imageWidth
    let imageHeight = imageHeight
    let contents = contents
    let fingerprints = contents.map(\.fingerprint)
    return { [self] in
      self.uuid = uuid
      self.normalizedSearchText = normalizedSearchText
      self.normalizedOCRText = normalizedOCRText
      self.application = application
      self.firstCopiedAt = firstCopiedAt
      self.lastCopiedAt = lastCopiedAt
      self.numberOfCopies = numberOfCopies
      self.pin = pin
      self.title = title
      self.ocrText = ocrText
      self.contentFingerprint = contentFingerprint
      self.characterCount = characterCount
      self.wordCount = wordCount
      self.searchText = searchText
      self.previewText = previewText
      self.metadataVersion = metadataVersion
      self.payloadByteCount = payloadByteCount
      self.imageWidth = imageWidth
      self.imageHeight = imageHeight
      self.contents = contents
      for (content, fingerprint) in zip(contents, fingerprints) { content.fingerprint = fingerprint }
    }
  }

  func supersedes(_ item: HistoryItem) -> Bool {
    let keys = Set(contents.map { $0.contentDigest })
    return item.contents.filter { !ContentProcessor.transientTypes.contains($0.type) }
      .allSatisfy { keys.contains($0.contentDigest) }
  }

  var snapshot: [ContentSnapshot] {
    contents.map { ContentSnapshot(type: $0.type, value: $0.value) }
  }

  func apply(_ prepared: PreparedCopy) {
    contentFingerprint = prepared.fingerprint
    searchText = prepared.text
    normalizedSearchText = prepared.normalizedText
    previewText = prepared.preview
    characterCount = prepared.characterCount
    wordCount = prepared.wordCount
    payloadByteCount = prepared.byteCount
    metadataVersion = 1
    for (content, digest) in zip(contents, prepared.fingerprints) {
      content.fingerprint = digest
    }
  }

  // Used when constructing model fixtures. Capture and migration use worker tasks.
  func computeTextStats() {
    let prepared = ContentProcessor.prepare(CapturedCopy(
      contents: snapshot, application: application, copiedAt: lastCopiedAt, changeCount: 0
    ))
    apply(prepared)
  }

  func computeContentFingerprint() {
    computeTextStats()
  }

  @MainActor
  func generateTitle() -> String {
    guard !hasImageContent else {
      return title
    }

    // 1k characters is trade-off for performance
    var title = (previewText ?? previewableText).shortened(to: 1_000)

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
    searchText ?? ContentProcessor.plainText(snapshot)
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
    guard let data = htmlData else { return nil }
    return NSAttributedString(string: ContentProcessor.plainText([ContentSnapshot(type: NSPasteboard.PasteboardType.html.rawValue, value: data)]))
  }

  var imageSource: ImageSource? {
    if let data = contentData([.tiff, .png, .jpeg, .heic]) { return .data(data) }
    if (universalClipboardImage || fileURLImage), let url = fileURLs.first { return .file(url) }
    return nil
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

}
