import XCTest
@testable import Lodge

final class PerformanceTests: XCTestCase {
  func testExactSearchWith200Items() { benchmark(count: 200) }
  func testExactSearchWith999Items() { benchmark(count: 999) }

  private func benchmark(count: Int) {
    let documents = (0..<count).map { index in
      SearchDocument(id: UUID(), title: "Clip \(index)",
                     text: String(repeating: "clipboard text ", count: 400) + "needle-\(index)", ocr: "")
    }
    measure {
      let results = SearchEngine.search(query: "needle-\(count - 1)", documents: documents, mode: "exact", ocr: false)
      XCTAssertEqual(results.count, 1)
    }
  }
}
