import XCTest
@testable import Lodge

@MainActor
final class ImageProcessingTests: XCTestCase {
  func testPreviewCacheEvictsByByteCost() throws {
    let image = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                                        bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
    let result = ImageResult(image: image, width: 100, height: 100)
    let cache = ImagePreviewCache(costLimit: result.cost * 2)
    let first = UUID(), second = UUID(), third = UUID()
    cache.insert(result, for: first)
    cache.insert(result, for: second)
    XCTAssertNotNil(cache.value(for: first))
    cache.insert(result, for: third)
    XCTAssertNil(cache.value(for: second))
    XCTAssertNotNil(cache.value(for: first))
    XCTAssertNotNil(cache.value(for: third))
    XCTAssertLessThanOrEqual(cache.totalCost, cache.costLimit)
    cache.remove(first)
    XCTAssertEqual(cache.totalCost, result.cost)
  }

  func testOCRWorkerLimitAndCancellation() async {
    let gate = OCRTestGate()
    let started = expectation(description: "Two workers started")
    started.expectedFulfillmentCount = 2
    let finished = expectation(description: "Only the retained item is updated")
    let service = OCRService(workerLimit: 2) { _ in
      started.fulfill()
      await gate.wait()
      return OCRResult(text: "text", width: 1, height: 1)
    }
    let first = UUID(), second = UUID(), queued = UUID()
    var completed: [UUID] = []
    for id in [first, second, queued] {
      service.enqueue(id: id, source: { .data(Data()) }) { _ in
        completed.append(id)
        finished.fulfill()
      }
    }
    await fulfillment(of: [started], timeout: 2)
    XCTAssertEqual(service.activeCount, 2)
    XCTAssertEqual(service.queuedCount, 1)
    service.cancel(first)
    service.cancel(queued)
    XCTAssertEqual(service.queuedCount, 0)
    XCTAssertEqual(service.activeCount, 2)
    await gate.release()
    await fulfillment(of: [finished], timeout: 2)
    XCTAssertEqual(completed, [second])
    service.cancelAll()
  }

  func testMissingImageShowsFailureAndCanBeRetried() async {
    let item = HistoryItem(contents: [HistoryItemContent(type: NSPasteboard.PasteboardType.fileURL.rawValue,
      value: URL(fileURLWithPath: "/private/tmp/lodge-missing-\(UUID()).png").dataRepresentation)])
    let decorator = HistoryItemDecorator(item)
    decorator.ensurePreviewImage()
    await decorator.waitForPreview()
    XCTAssertNil(decorator.previewImage)
    XCTAssertTrue(decorator.previewFailed)
    decorator.cleanupImages()
    XCTAssertFalse(decorator.previewFailed)
  }
}

private actor OCRTestGate {
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var released = false
  func wait() async {
    if released { return }
    await withCheckedContinuation { waiting.append($0) }
  }
  func release() {
    released = true
    waiting.forEach { $0.resume() }
    waiting.removeAll()
  }
}
