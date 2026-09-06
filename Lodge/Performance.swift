import os

/// Records durations without recording clipboard content.
enum AppPerformance {
  static let signposter = OSSignposter(subsystem: "com.nklmilojevic.Lodge", category: "Performance")
}
