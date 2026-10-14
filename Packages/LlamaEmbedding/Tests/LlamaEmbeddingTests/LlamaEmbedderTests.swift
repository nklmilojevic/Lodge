import Foundation
import XCTest
@testable import LlamaEmbedding

/// Runs only when the model files are installed in Lodge's model folder.
final class LlamaEmbedderTests: XCTestCase {
  private var folder: URL {
    URL.applicationSupportDirectory.appending(path: "Lodge/Models")
  }

  private func embedder(images: Bool) throws -> LlamaEmbedder {
    let text = folder.appending(path: EmbeddingModelFiles.text.name)
    let media = folder.appending(path: EmbeddingModelFiles.media.name)
    try XCTSkipUnless(FileManager.default.fileExists(atPath: text.path), "The model is not installed.")
    if images { try XCTSkipUnless(FileManager.default.fileExists(atPath: media.path), "The image model is not installed.") }
    return try LlamaEmbedder(text: text, media: images ? media : nil)
  }

  private func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

  func testTextVectorsAreNormalizedAndRankMeaning() throws {
    let embedder = try embedder(images: false)
    let documents = ["EACCES: permission denied, open '/usr/local/lib/node_modules'",
                     "2 cups flour, 1 tsp baking soda, 3 eggs, bake at 180°C for 25 minutes",
                     "Meeting moved to Thursday 3pm, room 4B"].map(EmbeddingPrompts.document)
    let vectors = try embedder.embed(texts: documents)
    XCTAssertEqual(vectors.count, 3)
    for vector in vectors {
      XCTAssertEqual(vector.count, LlamaEmbedder.dimension)
      XCTAssertEqual(cosine(vector, vector), 1, accuracy: 0.001)
    }
    let query = try embedder.embed(texts: [EmbeddingPrompts.query("file access error in the terminal")])[0]
    let scores = vectors.map { cosine(query, $0) }
    XCTAssertEqual(scores.firstIndex(of: scores.max()!), 0)
    let recipe = try embedder.embed(texts: [EmbeddingPrompts.query("cake recipe")])[0]
    let recipeScores = vectors.map { cosine(recipe, $0) }
    XCTAssertEqual(recipeScores.firstIndex(of: recipeScores.max()!), 1)
  }

  func testImageVectorsShareTheTextSpace() throws {
    let embedder = try embedder(images: true)
    guard let size = ImageSizing.targetSize(height: 480, width: 480, budget: LlamaEmbedder.imageBudget) else {
      return XCTFail("No target size")
    }
    // A plain red square and a plain blue square.
    func square(_ rgb: [UInt8]) -> [UInt8] { Array((0..<(size.width * size.height)).map { _ in rgb }.joined()) }
    let red = try embedder.embed(rgb: square([220, 20, 20]), width: size.width, height: size.height)
    let blue = try embedder.embed(rgb: square([20, 40, 220]), width: size.width, height: size.height)
    XCTAssertEqual(cosine(red, red), 1, accuracy: 0.001)
    let query = try embedder.embed(texts: [EmbeddingPrompts.query("a red image")])[0]
    XCTAssertGreaterThan(cosine(query, red), cosine(query, blue))
  }
}
