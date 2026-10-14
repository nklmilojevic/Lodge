import XCTest
@testable import Lodge

/// Token IDs must match the original Hugging Face tokenizer exactly (scripts/gen-tokenizer-fixtures.py). The
/// tokenizer file comes from TEST_RUNNER_LODGE_TOKENIZER (CI downloads the pinned file) or the installed model.
final class GemmaTokenizerTests: XCTestCase {
  private static var tokenizer: GemmaTokenizer?

  private func tokenizer() throws -> GemmaTokenizer {
    if let tokenizer = Self.tokenizer { return tokenizer }
    let installed = URL.applicationSupportDirectory
      .appending(path: "Lodge/Models/embeddinggemma-2-coreml/\(SemanticModelFiles.tokenizer)")
    let url = ProcessInfo.processInfo.environment["LODGE_TOKENIZER"].map { URL(fileURLWithPath: $0) } ?? installed
    try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "tokenizer.json is not available.")
    let tokenizer = try GemmaTokenizer(contentsOf: url)
    Self.tokenizer = tokenizer
    return tokenizer
  }

  func testTokenIDsMatchTheReferenceTokenizer() throws {
    let tokenizer = try tokenizer()
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tokenizer-fixtures", withExtension: "json"))
    let fixtures = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    XCTAssertGreaterThan(fixtures.count, 30)
    for fixture in fixtures {
      let text = try XCTUnwrap(fixture["text"] as? String)
      let ids = try XCTUnwrap(fixture["ids"] as? [Int]).map(Int32.init)
      XCTAssertEqual(tokenizer.encode(text), ids, text.debugDescription)
    }
  }

  func testLongTextKeepsBothSpecialTokens() throws {
    let ids = try tokenizer().encode(String(repeating: "word ", count: 2_000), limit: 512)
    XCTAssertEqual(ids.count, 512)
    XCTAssertEqual(ids.first, GemmaTokenizer.bosID)
    XCTAssertEqual(ids.last, GemmaTokenizer.eosID)
  }
}
