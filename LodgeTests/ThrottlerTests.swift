import XCTest
@testable import Lodge

final class ThrottlerTests: XCTestCase {
  func testFirstRequestRunsWithoutTheMinimumDelay() {
    let ready = expectation(description: "First request runs immediately")
    let throttler = Throttler(minimumDelay: 5)
    throttler.throttle { ready.fulfill() }
    wait(for: [ready], timeout: 0.5)
  }

  func testCancelDropsPendingWork() {
    let ready = expectation(description: "Cancelled request does not run")
    ready.isInverted = true
    let queue = DispatchQueue(label: "throttler.test")
    queue.suspend()
    let throttler = Throttler(minimumDelay: 0.01, queue: queue)
    throttler.throttle { ready.fulfill() }
    throttler.cancel()
    queue.resume()
    wait(for: [ready], timeout: 0.05)
  }
}
