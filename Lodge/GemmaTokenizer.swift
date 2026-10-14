import Foundation

/// The Gemma tokenizer from `tokenizer.json`, matching Hugging Face tokenizers: added tokens are matched in the raw
/// text, spaces become "▁", each remaining segment is one BPE word, and characters outside the vocabulary fall back
/// to UTF-8 byte tokens.
///
/// Tokens are keyed by their exact UTF-8 bytes. Swift strings compare by canonical equivalence and NSString keys
/// ignore some format characters, and either would merge distinct vocabulary entries (Bengali, "\u{FEFF}#").
final class GemmaTokenizer: @unchecked Sendable {
  static let padID: Int32 = 0
  static let eosID: Int32 = 1
  static let bosID: Int32 = 2

  private struct Pair: Hashable {
    let left: Int32
    let right: Int32
  }

  private let vocab: [[UInt8]: Int32]
  private let merges: [Pair: (rank: Int32, id: Int32)]
  /// Longest first, so the leftmost match is also the longest one.
  private let added: [(text: [Unicode.Scalar], id: Int32)]
  private let bytes: [Int32?]
  private let unknown: Int32

  init(contentsOf url: URL) throws {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let file = try data.withUnsafeBytes { buffer in
      var parser = TokenizerFileParser(buffer.bindMemory(to: UInt8.self))
      return try parser.parse()
    }
    vocab = file.vocab
    var merges: [Pair: (rank: Int32, id: Int32)] = [:]
    merges.reserveCapacity(file.merges.count)
    for (rank, pair) in file.merges.enumerated() {
      guard let left = vocab[pair.0], let right = vocab[pair.1], let merged = vocab[pair.0 + pair.1] else { continue }
      merges[Pair(left: left, right: right)] = (Int32(rank), merged)
    }
    self.merges = merges
    added = file.added.map { (Array(String(decoding: $0.text, as: UTF8.self).unicodeScalars), $0.id) }
      .sorted { $0.text.count > $1.text.count }
    bytes = (0...255).map { file.vocab[Array(String(format: "<0x%02X>", $0).utf8)] }
    unknown = file.vocab[Array("<unk>".utf8)] ?? 3
  }

  /// `<bos>`, the text's tokens, `<eos>`, cut to `limit` tokens with both special tokens kept.
  func encode(_ text: String, limit: Int = .max) -> [Int32] {
    var ids: [Int32] = [Self.bosID]
    let scalars = Array(text.unicodeScalars)
    var start = 0, index = 0
    while index < scalars.count, ids.count < limit {
      if let match = addedToken(in: scalars, at: index) {
        if start < index { ids += bpe(scalars[start..<index]) }
        ids.append(match.id)
        index += match.length
        start = index
      } else {
        index += 1
      }
    }
    if start < scalars.count, ids.count < limit { ids += bpe(scalars[start...]) }
    if ids.count > limit - 1 { ids.removeLast(ids.count - (limit - 1)) }
    return ids + [Self.eosID]
  }

  private func addedToken(in scalars: [Unicode.Scalar], at index: Int) -> (id: Int32, length: Int)? {
    guard scalars[index] == "<" else { return nil }
    for token in added where index + token.text.count <= scalars.count {
      if scalars[index..<(index + token.text.count)].elementsEqual(token.text) { return (token.id, token.text.count) }
    }
    return nil
  }

  private struct Symbol {
    var id: Int32
    var previous: Int
    var next: Int
    var alive = true
  }

  private struct Candidate: Comparable {
    let rank: Int32
    let position: Int
    let id: Int32
    static func < (lhs: Candidate, rhs: Candidate) -> Bool {
      lhs.rank == rhs.rank ? lhs.position < rhs.position : lhs.rank < rhs.rank
    }
  }

  private static let space = Array("▁".utf8)

  /// Hugging Face's BPE word merge: always apply the lowest-ranked pair, leftmost first.
  private func bpe(_ scalars: ArraySlice<Unicode.Scalar>) -> [Int32] {
    var symbols: [Symbol] = []
    var previousUnknown = false
    for scalar in scalars {
      let utf8 = scalar == " " ? Self.space : Array(String(scalar).utf8)
      if let id = vocab[utf8] {
        symbols.append(Symbol(id: id, previous: symbols.count - 1, next: symbols.count + 1))
        previousUnknown = false
        continue
      }
      let fallback = utf8.compactMap { bytes[Int($0)] }
      if fallback.count == utf8.count {
        for id in fallback { symbols.append(Symbol(id: id, previous: symbols.count - 1, next: symbols.count + 1)) }
        previousUnknown = false
      } else if !previousUnknown {
        symbols.append(Symbol(id: unknown, previous: symbols.count - 1, next: symbols.count + 1))
        previousUnknown = true
      }
    }
    guard !symbols.isEmpty else { return [] }
    symbols[symbols.count - 1].next = -1
    var queue = Heap<Candidate>()
    for position in 0..<(symbols.count - 1) {
      if let merge = merges[Pair(left: symbols[position].id, right: symbols[position + 1].id)] {
        queue.push(Candidate(rank: merge.rank, position: position, id: merge.id))
      }
    }
    while let top = queue.pop() {
      let position = top.position
      guard symbols[position].alive, symbols[position].next >= 0 else { continue }
      let right = symbols[position].next
      guard let merge = merges[Pair(left: symbols[position].id, right: symbols[right].id)], merge.id == top.id
      else { continue }
      symbols[position].id = merge.id
      symbols[position].next = symbols[right].next
      symbols[right].alive = false
      if symbols[right].next >= 0 { symbols[symbols[right].next].previous = position }
      let previous = symbols[position].previous
      if previous >= 0, let merge = merges[Pair(left: symbols[previous].id, right: symbols[position].id)] {
        queue.push(Candidate(rank: merge.rank, position: previous, id: merge.id))
      }
      let next = symbols[position].next
      if next >= 0, let merge = merges[Pair(left: symbols[position].id, right: symbols[next].id)] {
        queue.push(Candidate(rank: merge.rank, position: position, id: merge.id))
      }
    }
    var ids: [Int32] = []
    var position = 0
    while position >= 0 {
      ids.append(symbols[position].id)
      position = symbols[position].next
    }
    return ids
  }
}

/// A binary min-heap.
private struct Heap<Element: Comparable> {
  private var items: [Element] = []

  mutating func push(_ item: Element) {
    items.append(item)
    var child = items.count - 1
    while child > 0 {
      let parent = (child - 1) / 2
      guard items[child] < items[parent] else { break }
      items.swapAt(child, parent)
      child = parent
    }
  }

  mutating func pop() -> Element? {
    guard !items.isEmpty else { return nil }
    items.swapAt(0, items.count - 1)
    let top = items.removeLast()
    var parent = 0
    while true {
      let left = 2 * parent + 1, right = left + 1
      var smallest = parent
      if left < items.count && items[left] < items[smallest] { smallest = left }
      if right < items.count && items[right] < items[smallest] { smallest = right }
      guard smallest != parent else { break }
      items.swapAt(parent, smallest)
      parent = smallest
    }
    return top
  }
}

/// Reads the parts of `tokenizer.json` the tokenizer needs, keeping every string as its exact UTF-8 bytes.
struct TokenizerFileParser {
  struct File {
    var vocab: [[UInt8]: Int32] = [:]
    var merges: [([UInt8], [UInt8])] = []
    var added: [(text: [UInt8], id: Int32)] = []
  }

  enum ParseError: Error { case invalid(Int) }

  private let bytes: UnsafeBufferPointer<UInt8>
  private var index = 0

  init(_ bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

  mutating func parse() throws -> File {
    var file = File()
    try object { key, parser in
      switch key {
      case Array("model".utf8):
        try parser.object { key, parser in
          switch key {
          case Array("vocab".utf8):
            file.vocab.reserveCapacity(262_144)
            try parser.object { token, parser in file.vocab[token] = Int32(try parser.integer()) }
          case Array("merges".utf8):
            file.merges.reserveCapacity(514_906)
            try parser.array { parser in
              var pair: [[UInt8]] = []
              try parser.array { parser in pair.append(try parser.string()) }
              if pair.count == 2 { file.merges.append((pair[0], pair[1])) }
            }
          default: try parser.skip()
          }
        }
      case Array("added_tokens".utf8):
        try parser.array { parser in
          var id: Int32?, content: [UInt8]?
          try parser.object { key, parser in
            switch key {
            case Array("id".utf8): id = Int32(try parser.integer())
            case Array("content".utf8): content = try parser.string()
            default: try parser.skip()
            }
          }
          if let id, let content { file.added.append((content, id)) }
        }
      default: try parser.skip()
      }
    }
    return file
  }

  private mutating func whitespace() {
    while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
  }

  private mutating func expect(_ byte: UInt8) throws {
    whitespace()
    guard index < bytes.count, bytes[index] == byte else { throw ParseError.invalid(index) }
    index += 1
  }

  private mutating func peek() -> UInt8? {
    whitespace()
    return index < bytes.count ? bytes[index] : nil
  }

  mutating func object(_ member: (_ key: [UInt8], _ parser: inout TokenizerFileParser) throws -> Void) throws {
    try expect(UInt8(ascii: "{"))
    if peek() == UInt8(ascii: "}") { index += 1; return }
    while true {
      let key = try string()
      try expect(UInt8(ascii: ":"))
      try member(key, &self)
      if peek() == UInt8(ascii: ",") { index += 1; continue }
      try expect(UInt8(ascii: "}"))
      return
    }
  }

  mutating func array(_ element: (_ parser: inout TokenizerFileParser) throws -> Void) throws {
    try expect(UInt8(ascii: "["))
    if peek() == UInt8(ascii: "]") { index += 1; return }
    while true {
      try element(&self)
      if peek() == UInt8(ascii: ",") { index += 1; continue }
      try expect(UInt8(ascii: "]"))
      return
    }
  }

  mutating func integer() throws -> Int {
    whitespace()
    var value = 0, negative = false, digits = 0
    if index < bytes.count, bytes[index] == UInt8(ascii: "-") { negative = true; index += 1 }
    while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
      value = value * 10 + Int(bytes[index] - 0x30)
      index += 1
      digits += 1
    }
    guard digits > 0 else { throw ParseError.invalid(index) }
    return negative ? -value : value
  }

  mutating func string() throws -> [UInt8] {
    try expect(UInt8(ascii: "\""))
    var result: [UInt8] = []
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      switch byte {
      case UInt8(ascii: "\""): return result
      case UInt8(ascii: "\\"):
        guard index < bytes.count else { throw ParseError.invalid(index) }
        let escape = bytes[index]
        index += 1
        switch escape {
        case UInt8(ascii: "n"): result.append(0x0A)
        case UInt8(ascii: "t"): result.append(0x09)
        case UInt8(ascii: "r"): result.append(0x0D)
        case UInt8(ascii: "b"): result.append(0x08)
        case UInt8(ascii: "f"): result.append(0x0C)
        case UInt8(ascii: "u"):
          var scalar = try hex4()
          if (0xD800...0xDBFF).contains(scalar), index + 1 < bytes.count,
             bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
            index += 2
            let low = try hex4()
            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
          }
          guard let unicode = Unicode.Scalar(scalar) else { throw ParseError.invalid(index) }
          result += Array(String(Character(unicode)).utf8)
        default: result.append(escape)
        }
      default: result.append(byte)
      }
    }
    throw ParseError.invalid(index)
  }

  private mutating func hex4() throws -> UInt32 {
    guard index + 4 <= bytes.count else { throw ParseError.invalid(index) }
    var value: UInt32 = 0
    for _ in 0..<4 {
      let byte = bytes[index]
      index += 1
      switch byte {
      case 0x30...0x39: value = value * 16 + UInt32(byte - 0x30)
      case 0x41...0x46: value = value * 16 + UInt32(byte - 0x37)
      case 0x61...0x66: value = value * 16 + UInt32(byte - 0x57)
      default: throw ParseError.invalid(index)
      }
    }
    return value
  }

  /// Skips any JSON value.
  mutating func skip() throws {
    switch peek() {
    case UInt8(ascii: "{"): try object { _, parser in try parser.skip() }
    case UInt8(ascii: "["): try array { parser in try parser.skip() }
    case UInt8(ascii: "\""): _ = try string()
    case .some:
      while index < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(bytes[index]) {
        index += 1
      }
    case .none: throw ParseError.invalid(index)
    }
  }
}
