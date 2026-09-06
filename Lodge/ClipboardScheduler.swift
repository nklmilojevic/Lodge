import Foundation

@MainActor
protocol ClipboardTimer {
  func cancel()
}

@MainActor
protocol ClipboardScheduling {
  func schedule(interval: TimeInterval, action: @escaping @MainActor () -> Void) -> ClipboardTimer
}

@MainActor
final class SystemClipboardScheduler: ClipboardScheduling {
  func schedule(interval: TimeInterval, action: @escaping @MainActor () -> Void) -> ClipboardTimer {
    let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
      MainActor.assumeIsolated { action() }
    }
    timer.tolerance = min(interval * 0.1, 0.05)
    return Token(timer: timer)
  }

  private final class Token: ClipboardTimer {
    let timer: Timer
    init(timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
  }
}
