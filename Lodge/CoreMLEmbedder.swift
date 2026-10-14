import Accelerate
import CoreML
import Foundation
import ImageIO

/// EmbeddingGemma 2 on Core ML (FluidInference/embeddinggemma-2-coreml). Text runs on the Neural Engine and images on
/// the GPU. Only the embedding helper process uses this, so model memory never stays in the app.
@available(macOS 15, *)
final class CoreMLEmbedder {
  static let imageBudget = 280
  private static let lengths = [32, 48, 64, 128, 256, 512]
  private static let width = 512
  private static let scale: Float = 22.627417
  private static let imageStart: Int32 = 255_999
  private static let imageEnd: Int32 = 258_882
  private static let patchCount = 2_520

  private let files: SemanticModelFiles
  private let tokenizer: GemmaTokenizer
  private let table: Data
  private var textModels: [Int: MLModel] = [:]
  private var vision: MLModel?
  private var positions: [Float]?

  init(files: SemanticModelFiles) throws {
    self.files = files
    tokenizer = try GemmaTokenizer(contentsOf: files.url(for: SemanticModelFiles.tokenizer))
    table = try Data(contentsOf: files.url(for: SemanticModelFiles.tokenTable), options: .alwaysMapped)
  }

  /// Loads the functions short queries use. The first load on a Mac compiles each one for the Neural Engine, which
  /// takes up to half a minute per function once; longer functions load when indexing needs them.
  func prepare() async throws {
    for length in Self.lengths.prefix(3) { _ = try await textModel(length) }
  }

  func embed(texts: [String]) async throws -> [[Float]] {
    var vectors: [[Float]] = []
    for text in texts {
      let ids = tokenizer.encode(text, limit: Self.lengths.last!)
      vectors.append(try await run(ids.map { .token($0) }))
    }
    return vectors
  }

  func embed(image source: ImageSource) async throws -> [Float] {
    guard let image = Self.pixels(source) else { throw SemanticModelError.unreadableImage }
    return try await embed(rgb: image.data, width: image.width, height: image.height)
  }

  /// Packed RGB pixels whose sides are multiples of 48, at most `imageBudget` × 9 patches of 16 px.
  func embed(rgb pixels: [UInt8], width: Int, height: Int) async throws -> [Float] {
    let columns = width / 16, rows = height / 16, count = columns * rows
    guard width % 48 == 0, height % 48 == 0, count <= Self.patchCount, pixels.count == width * height * 3 else {
      throw SemanticModelError.unreadableImage
    }
    let model = try await visionModel()
    let table = try positionTable()
    var patches = [Float](repeating: 0, count: Self.patchCount * 768)
    var coordinates = [Float](repeating: -1, count: Self.patchCount * 2)
    var embeddings = [Float](repeating: 0, count: Self.patchCount * 768)
    var valid = [Float](repeating: 0, count: Self.patchCount)
    for row in 0..<rows {
      for column in 0..<columns {
        let patch = row * columns + column
        for y in 0..<16 {
          let source = ((row * 16 + y) * width + column * 16) * 3
          let destination = patch * 768 + y * 48
          for offset in 0..<48 { patches[destination + offset] = Float(pixels[source + offset]) / 255 }
        }
        coordinates[patch * 2] = Float(column)
        coordinates[patch * 2 + 1] = Float(row)
        for index in 0..<768 {
          embeddings[patch * 768 + index] = table[column * 768 + index] + table[(1024 + row) * 768 + index]
        }
        valid[patch] = 1
      }
    }
    let groupColumns = columns / 3, tokens = (rows / 3) * groupColumns
    var pool = [Float](repeating: 0, count: Self.imageBudget * Self.patchCount)
    for token in 0..<tokens {
      let groupRow = token / groupColumns, groupColumn = token % groupColumns
      for dy in 0..<3 {
        for dx in 0..<3 {
          pool[token * Self.patchCount + (groupRow * 3 + dy) * columns + groupColumn * 3 + dx] = 1.0 / 9
        }
      }
    }
    let input = try MLDictionaryFeatureProvider(dictionary: [
      "patches": try Self.half(patches, shape: [1, Self.patchCount, 768]),
      "positions": try Self.half(coordinates, shape: [1, Self.patchCount, 2]),
      "position_embeddings": try Self.half(embeddings, shape: [1, Self.patchCount, 768]),
      "valid": try Self.half(valid, shape: [1, Self.patchCount]),
      "pool": try Self.half(pool, shape: [Self.imageBudget, Self.patchCount])
    ])
    let output = try await model.prediction(from: input)
    guard let imageTokens = output.featureValue(for: "image_tokens")?.multiArrayValue else {
      throw SemanticModelError.unavailable
    }
    let values = Self.floats(imageTokens)
    var sequence: [Row] = [.token(GemmaTokenizer.bosID), .token(Self.imageStart)]
    for token in 0..<tokens {
      sequence.append(.values(Array(values[(token * Self.width)..<((token + 1) * Self.width)])))
    }
    sequence += [.token(Self.imageEnd), .token(GemmaTokenizer.eosID)]
    return try await run(sequence)
  }

  private enum Row {
    case token(Int32)
    case values([Float])
  }

  /// Runs the smallest text function that fits and returns the L2-normalized embedding.
  private func run(_ sequence: [Row]) async throws -> [Float] {
    guard let length = Self.lengths.first(where: { $0 >= sequence.count }) else { throw SemanticModelError.unavailable }
    let model = try await textModel(length)
    var inputs = [Float](repeating: 0, count: length * Self.width)
    var mask = [Float](repeating: 0, count: length)
    table.withUnsafeBytes { raw in
      let bf16 = raw.bindMemory(to: UInt16.self)
      for (position, row) in sequence.enumerated() {
        let start = position * Self.width
        switch row {
        case .token(let id):
          let tableStart = Int(id) * Self.width
          for index in 0..<Self.width {
            inputs[start + index] = Float(bitPattern: UInt32(bf16[tableStart + index]) << 16) * Self.scale
          }
        case .values(let values):
          inputs.replaceSubrange(start..<(start + Self.width), with: values)
        }
        mask[position] = 1
      }
    }
    let input = try MLDictionaryFeatureProvider(dictionary: [
      "inputs_embeds": try Self.half(inputs, shape: [1, length, Self.width]),
      "attention_mask": try Self.half(mask, shape: [1, length])
    ])
    let output = try await model.prediction(from: input)
    guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue else {
      throw SemanticModelError.unavailable
    }
    let vector = Self.floats(embedding)
    let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return norm > 0 ? vector.map { $0 / norm } : vector
  }

  private func textModel(_ length: Int) async throws -> MLModel {
    if let model = textModels[length] { return model }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    configuration.functionName = "embed_\(length)"
    let model = try await MLModel.load(contentsOf: try await files.compiled(SemanticModelFiles.textPackage),
                                       configuration: configuration)
    textModels[length] = model
    return model
  }

  private func visionModel() async throws -> MLModel {
    if let vision { return vision }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndGPU
    configuration.functionName = "vision_\(Self.imageBudget)"
    let model = try await MLModel.load(contentsOf: try await files.compiled(SemanticModelFiles.visionPackage),
                                       configuration: configuration)
    vision = model
    return model
  }

  /// The x and y position tables, 2 × 1024 × 768.
  private func positionTable() throws -> [Float] {
    if let positions { return positions }
    let table = Self.floats(halves: try Data(contentsOf: files.url(for: SemanticModelFiles.positionTable)))
    positions = table
    return table
  }

  private static func half(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
    let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
    values.withUnsafeBufferPointer { source in
      var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress), height: 1,
                               width: vImagePixelCount(values.count), rowBytes: values.count * 4)
      var to = vImage_Buffer(data: array.dataPointer, height: 1, width: vImagePixelCount(values.count),
                             rowBytes: values.count * 2)
      vImageConvert_PlanarFtoPlanar16F(&from, &to, vImage_Flags(kvImageNoFlags))
    }
    return array
  }

  private static func floats(_ array: MLMultiArray) -> [Float] {
    switch array.dataType {
    case .float32:
      return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
    case .float16:
      return array.withUnsafeBytes { floats(halves: Data($0)) }
    default:
      return (0..<array.count).map { array[$0].floatValue }
    }
  }

  private static func floats(halves data: Data) -> [Float] {
    let count = data.count / 2
    var result = [Float](repeating: 0, count: count)
    data.withUnsafeBytes { source in
      result.withUnsafeMutableBufferPointer { destination in
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress), height: 1,
                                 width: vImagePixelCount(count), rowBytes: count * 2)
        var to = vImage_Buffer(data: destination.baseAddress, height: 1, width: vImagePixelCount(count),
                               rowBytes: count * 4)
        vImageConvert_Planar16FtoPlanarF(&from, &to, vImage_Flags(kvImageNoFlags))
      }
    }
    return result
  }

  /// Decodes an image into packed RGB on a white background, resized for `imageBudget`.
  static func pixels(_ source: ImageSource) -> (data: [UInt8], width: Int, height: Int)? {
    guard let result = ImageProcessor.thumbnail(source, maxDimension: 2048) else { return nil }
    let image = result.image
    let width = image.width, height = image.height
    guard let target = ImageSizing.targetSize(height: height, width: width, budget: imageBudget) else { return nil }
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    var rgb = [UInt8](repeating: 0, count: width * height * 3)
    for pixel in 0..<(width * height) {
      rgb[pixel * 3] = rgba[pixel * 4]
      rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
      rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
    }
    guard target != (height, width) else { return (rgb, width, height) }
    let resized = rgb.withUnsafeBufferPointer {
      ImageSizing.resizeBicubic($0.baseAddress!, width: width, height: height, toWidth: target.width,
                                toHeight: target.height)
    }
    return (resized, target.width, target.height)
  }
}
