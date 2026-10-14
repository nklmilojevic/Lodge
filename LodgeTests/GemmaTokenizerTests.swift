import XCTest
@testable import Lodge

/// Token IDs must match the original Hugging Face tokenizer exactly (scripts/gen-tokenizer-fixtures.py). The
/// tokenizer file comes from LODGE_TOKENIZER or the installed model. xcodebuild passes TEST_RUNNER_LODGE_TOKENIZER to
/// tests as LODGE_TOKENIZER; both names are read. With LODGE_REQUIRE_TOKENIZER set, as in CI, a missing file fails
/// the tests instead of skipping them.
final class GemmaTokenizerTests: XCTestCase {
  /// Thrown instead of a skip, so the test fails.
  private struct MissingTokenizer: Error {
    let path: String
  }

  private static var tokenizer: GemmaTokenizer?

  private func tokenizer() throws -> GemmaTokenizer {
    if let tokenizer = Self.tokenizer { return tokenizer }
    let installed = URL.applicationSupportDirectory
      .appending(path: "Lodge/Models/embeddinggemma-2-coreml/\(SemanticModelFiles.tokenizer)")
    let environment = ProcessInfo.processInfo.environment
    let path = environment["LODGE_TOKENIZER"] ?? environment["TEST_RUNNER_LODGE_TOKENIZER"]
    let url = path.map { URL(fileURLWithPath: $0) } ?? installed
    let available = FileManager.default.fileExists(atPath: url.path)
    if environment["LODGE_REQUIRE_TOKENIZER"] != nil || environment["TEST_RUNNER_LODGE_REQUIRE_TOKENIZER"] != nil {
      guard available else { throw MissingTokenizer(path: url.path) }
    }
    try XCTSkipUnless(available, "tokenizer.json is not available.")
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
