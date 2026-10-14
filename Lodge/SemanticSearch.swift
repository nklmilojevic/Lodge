import Accelerate
import Foundation

/// Stored item vectors: 768 half-precision values, L2-normalized.
enum SemanticVectors {
  static let dimension = 768

  /// Half precision through vImage, because Swift's Float16 is unavailable on Intel Macs.
  static func pack(_ vector: [Float]) -> Data {
    var halves = [UInt16](repeating: 0, count: vector.count)
    vector.withUnsafeBufferPointer { source in
      halves.withUnsafeMutableBufferPointer { destination in
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress), height: 1,
                                 width: vImagePixelCount(source.count), rowBytes: source.count * 4)
        var to = vImage_Buffer(data: destination.baseAddress, height: 1, width: vImagePixelCount(source.count),
                               rowBytes: source.count * 2)
        vImageConvert_PlanarFtoPlanar16F(&from, &to, vImage_Flags(kvImageNoFlags))
      }
    }
    return halves.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  static func unpack(_ data: Data) -> [Float]? {
    guard data.count == dimension * 2 else { return nil }
    var floats = [Float](repeating: 0, count: dimension)
    data.withUnsafeBytes { source in
      floats.withUnsafeMutableBufferPointer { destination in
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress), height: 1,
                                 width: vImagePixelCount(dimension), rowBytes: dimension * 2)
        var to = vImage_Buffer(data: destination.baseAddress, height: 1, width: vImagePixelCount(dimension),
                               rowBytes: dimension * 4)
        vImageConvert_Planar16FtoPlanarF(&from, &to, vImage_Flags(kvImageNoFlags))
      }
    }
    return floats
  }
}

/// Item vectors in one row-major matrix, so a query scores every item with one multiplication.
struct SemanticIndex: Sendable {
  private(set) var ids: [UUID] = []
  private(set) var isImage: [Bool] = []
  private var matrix: [Float] = []
  private var rows: [UUID: Int] = [:]

  init(_ entries: [(id: UUID, isImage: Bool, vector: [Float])] = []) {
    for entry in entries where entry.vector.count == SemanticVectors.dimension && rows[entry.id] == nil {
      rows[entry.id] = ids.count
      ids.append(entry.id)
      isImage.append(entry.isImage)
      matrix += entry.vector
    }
  }

  var count: Int { ids.count }
  var isEmpty: Bool { ids.isEmpty }

  func vector(for id: UUID) -> [Float]? {
    guard let row = rows[id] else { return nil }
    let start = row * SemanticVectors.dimension
    return Array(matrix[start..<(start + SemanticVectors.dimension)])
  }

  /// Cosine similarity of `query` with every row.
  func cosines(_ query: [Float]) -> [Float] {
    guard query.count == SemanticVectors.dimension, !ids.isEmpty else { return [] }
    var scores = [Float](repeating: 0, count: ids.count)
    vDSP_mmul(matrix, 1, query, 1, &scores, 1, vDSP_Length(ids.count), 1, vDSP_Length(SemanticVectors.dimension))
    return scores
  }

  /// Every pairwise cosine similarity, row-major.
  func pairwiseCosines() -> [Float] {
    let count = ids.count
    guard count > 0 else { return [] }
    var transposed = [Float](repeating: 0, count: matrix.count)
    vDSP_mtrans(matrix, 1, &transposed, 1, vDSP_Length(SemanticVectors.dimension), vDSP_Length(count))
    var result = [Float](repeating: 0, count: count * count)
    vDSP_mmul(matrix, 1, transposed, 1, &result, 1, vDSP_Length(count), vDSP_Length(count),
              vDSP_Length(SemanticVectors.dimension))
    return result
  }

  /// How far each item stands out for this query, in standard deviations. Text and image vectors sit at different
  /// levels for the same query, so each modality is centered on its own mean first. Modalities with fewer than 20
  /// vectors use the overall mean. Adapted from DigUp (https://github.com/ARahim3/DigUp), MIT License.
  func meaning(_ query: [Float], excluding excluded: UUID? = nil) -> [UUID: (z: Double, cosine: Float)] {
    let scores = cosines(query)
    guard scores.count == ids.count else { return [:] }
    let included = ids.indices.filter { ids[$0] != excluded }
    guard !included.isEmpty else { return [:] }
    var sums: [Bool: Double] = [:], counts: [Bool: Int] = [:]
    for row in included {
      sums[isImage[row], default: 0] += Double(scores[row])
      counts[isImage[row], default: 0] += 1
    }
    let overall = sums.values.reduce(0, +) / Double(included.count)
    let means = Dictionary(uniqueKeysWithValues: [false, true].map { modality in
      (modality, (counts[modality] ?? 0) >= 20 ? sums[modality]! / Double(counts[modality]!) : overall)
    })
    let centered = included.map { Double(scores[$0]) - means[isImage[$0]]! }
    let mean = centered.reduce(0, +) / Double(centered.count)
    let variance = centered.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(centered.count)
    let deviation = max(variance.squareRoot(), 0.02)
    var result: [UUID: (z: Double, cosine: Float)] = [:]
    for (offset, row) in included.enumerated() {
      result[ids[row]] = ((centered[offset] - mean) / deviation, scores[row])
    }
    return result
  }
}

enum SemanticRanking {
  /// An item matches by meaning when it stands this many deviations above the query's average.
  static let meaningGate = 2.0
  /// Related items must stand out more, because the list is not requested by the user.
  static let relatedGate = 2.5
  /// Small edits of the same text scored 0.97–0.98 with EmbeddingGemma 2; unrelated pairs stayed below 0.86.
  static let nearDuplicate: Float = 0.95
  /// Results below this share of the top score are dropped.
  static let strongRatio = 0.5

  /// Hybrid order of `candidates`: meaning z-score plus a bonus for the share of query words found.
  /// Codes and numbers mean little to an embedding, so a query made only of them weighs words more.
  static func rank(_ candidates: [UUID], meaning: [UUID: Double], coverage: [UUID: Double], lookup: Bool) -> [UUID] {
    let (meaningWeight, wordWeight) = lookup ? (0.5, 4.0) : (1.0, 2.0)
    var scored: [(id: UUID, score: Double, order: Int)] = []
    for (order, id) in candidates.enumerated() {
      let z = meaning[id] ?? 0
      let share = coverage[id] ?? 0
      guard z >= meaningGate || share >= 0.5 else { continue }
      scored.append((id, meaningWeight * max(z, 0) + wordWeight * pow(share, 1.5), order))
    }
    scored.sort { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
    guard let top = scored.first?.score, top > 0 else { return scored.map(\.id) }
    return scored.prefix { $0.score >= top * strongRatio }.map(\.id)
  }

  static func isLookup(_ terms: [String]) -> Bool {
    !terms.isEmpty && terms.allSatisfy {
      $0.contains(where: \.isNumber) && ($0.contains(where: \.isLetter) || $0.count >= 4)
    }
  }

  private static let stopwords: Set<String> = [
    "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "that", "this", "these",
    "those", "from", "about", "where", "what", "which", "who", "when", "is", "was", "are", "were", "be", "it", "its",
    "some", "any", "find", "show", "i", "copied", "copy"
  ]

  /// Content words of a free-form query, for keyword coverage when Ask has no filter plan.
  static func terms(_ query: String) -> [String] {
    var seen = Set<String>()
    return query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count >= 2 && !stopwords.contains($0) && seen.insert($0).inserted }
  }

  /// Items similar to `id`: near-duplicates of the same kind, and other items that stand out by meaning.
  static func neighbors(of id: UUID, in index: SemanticIndex, limit: Int = 5) -> (versions: [UUID], related: [UUID]) {
    guard let vector = index.vector(for: id) else { return ([], []) }
    let isImage = index.isImage[index.ids.firstIndex(of: id)!]
    let scores = index.meaning(vector, excluding: id)
    var versions: [(UUID, Float)] = []
    var related: [(UUID, Float)] = []
    for (row, other) in index.ids.enumerated() where other != id {
      guard let score = scores[other] else { continue }
      if score.cosine >= nearDuplicate && index.isImage[row] == isImage {
        versions.append((other, score.cosine))
      } else if score.z >= relatedGate {
        related.append((other, score.cosine))
      }
    }
    return (versions.sorted { $0.1 > $1.1 }.map(\.0), Array(related.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)))
  }

  /// Groups near-duplicates under the first item in `order` that has them. Returns each member's group head.
  static func groups(_ order: [UUID], in index: SemanticIndex) -> [UUID: UUID] {
    let rows = Dictionary(uniqueKeysWithValues: index.ids.enumerated().map { ($1, $0) })
    let ordered = order.filter { rows[$0] != nil }
    guard ordered.count > 1 else { return [:] }
    let similarity = index.pairwiseCosines()
    var head: [UUID: UUID] = [:]
    for (position, first) in ordered.enumerated() where head[first] == nil {
      let row = rows[first]!
      for other in ordered[(position + 1)...] where head[other] == nil {
        let column = rows[other]!
        if index.isImage[row] == index.isImage[column] && similarity[row * index.count + column] >= nearDuplicate {
          head[other] = first
        }
      }
    }
    return head
  }
}
