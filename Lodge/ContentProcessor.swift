import AppKit
import CryptoKit
import SwiftSoup

struct ContentSnapshot: Sendable, Equatable {
  let type: String
  let value: Data?
}

struct CapturedCopy: Sendable {
  let contents: [ContentSnapshot]
  let application: String?
  let copiedAt: Date
  let changeCount: Int
}

struct PreparedCopy: Sendable {
  let capture: CapturedCopy
  let fingerprints: [String]
  let fingerprint: String
  let text: String
  let normalizedText: String
  let preview: String
  let characterCount: Int
  let wordCount: Int
  let byteCount: Int64
}

enum ContentProcessor {
  static let previewLength = 5_000
  static let transientTypes: Set<String> = [
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

  static func prepare(_ capture: CapturedCopy) -> PreparedCopy {
    let interval = AppPerformance.signposter.beginInterval("Prepare copy")
    defer { AppPerformance.signposter.endInterval("Prepare copy", interval) }
    let fingerprints = capture.contents.map(fingerprint)
    let persistentDigests = zip(capture.contents, fingerprints)
      .filter { !transientTypes.contains($0.0.type) }.map(\.1).sorted()
    let digest = persistentDigests.isEmpty ? "" : hex(SHA256.hash(data: Data(persistentDigests.joined(separator: ":").utf8)))
    let text = plainText(capture.contents)
    let normalizedText = normalize(text)
    return PreparedCopy(
      capture: capture,
      fingerprints: fingerprints,
      fingerprint: digest,
      text: text,
      normalizedText: normalizedText,
      preview: String(text.prefix(previewLength)),
      characterCount: text.count,
      wordCount: text.split(whereSeparator: { $0.isWhitespace }).count,
      byteCount: capture.contents.reduce(0) { $0 + Int64($1.value?.count ?? 0) } + Int64(text.utf8.count) + Int64(normalizedText.utf8.count) + Int64(text.prefix(previewLength).utf8.count)
    )
  }

  static func normalize(_ text: String) -> String {
    text.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
      .precomposedStringWithCanonicalMapping
  }

  static func fingerprint(_ content: ContentSnapshot) -> String {
    var hash = SHA256()
    hash.update(data: Data(content.type.utf8))
    hash.update(data: Data([0]))
    if let value = content.value { hash.update(data: value) }
    return hex(hash.finalize())
  }

  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    let digits = Array("0123456789abcdef".utf8)
    return String(decoding: digest.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
  }

  static func plainText(_ contents: [ContentSnapshot]) -> String {
    func data(_ type: NSPasteboard.PasteboardType) -> Data? {
      contents.first { $0.type == type.rawValue }?.value
    }
    let hasUniversalText = data(.universalClipboard) != nil &&
      [.html, .tiff, .png, .jpeg, .rtf, .string, .heic].contains { data($0) != nil }
    if !hasUniversalText {
      let urls = contents.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
        .compactMap(\.value)
        .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
      if !urls.isEmpty {
        return urls.compactMap { $0.absoluteString.removingPercentEncoding }.joined(separator: "\n")
      }
    }
    if let data = data(.string), let text = String(data: data, encoding: .utf8), !text.isEmpty { return text }
    if [.tiff, .png, .jpeg, .heic].contains(where: { data($0) != nil }) { return "" }
    if let data = data(.rtf), let text = NSAttributedString(rtf: data, documentAttributes: nil)?.string,
       !text.isEmpty { return text }
    if let data = data(.html) {
      // Parse bytes locally. The parser does not load images, styles, or other URLs.
      return (try? SwiftSoup.parse(data).text()) ?? ""
    }
    return ""
  }
}
