import AppKit
import ImageIO
import Vision

enum ImageSource: Sendable {
  case data(Data)
  case file(URL)

  func load() -> CGImageSource? {
    switch self {
    case .data(let data): return CGImageSourceCreateWithData(data as CFData, nil)
    case .file(let url):
      guard url.isFileURL,
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= 50 * 1024 * 1024 else { return nil }
      return CGImageSourceCreateWithURL(url as CFURL, nil)
    }
  }
}

struct ImageResult: Sendable {
  let image: CGImage
  let width: Int
  let height: Int
  var cost: Int { image.bytesPerRow * image.height }
}

enum ImageProcessor {
  static func thumbnail(_ input: ImageSource, maxDimension: Int) -> ImageResult? {
    let interval = AppPerformance.signposter.beginInterval("Image thumbnail")
    defer { AppPerformance.signposter.endInterval("Image thumbnail", interval) }
    guard !Task.isCancelled, let source = input.load(),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxDimension,
      kCGImageSourceShouldCacheImmediately: true
    ]
    guard !Task.isCancelled,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return ImageResult(image: image, width: width, height: height)
  }
}

private actor ThumbnailWorker {
  func make(_ source: ImageSource) -> ImageResult? {
    autoreleasepool { ImageProcessor.thumbnail(source, maxDimension: 1200) }
  }
}

@MainActor
final class ImagePreviewCache {
  private var values: [UUID: ImageResult] = [:]
  private var order: [UUID] = []
  private(set) var totalCost = 0
  let costLimit: Int

  init(costLimit: Int = 32 * 1024 * 1024) { self.costLimit = max(0, costLimit) }

  func value(for id: UUID) -> ImageResult? {
    guard let value = values[id] else { return nil }
    order.removeAll { $0 == id }
    order.append(id)
    return value
  }

  func insert(_ value: ImageResult, for id: UUID) {
    remove(id)
    guard value.cost <= costLimit else { return }
    while totalCost + value.cost > costLimit, let oldest = order.first { remove(oldest) }
    values[id] = value
    order.append(id)
    totalCost += value.cost
  }

  func remove(_ id: UUID) {
    if let value = values.removeValue(forKey: id) { totalCost -= value.cost }
    order.removeAll { $0 == id }
  }
}

@MainActor
final class ImageProcessingService {
  static let shared = ImageProcessingService()
  let cache: ImagePreviewCache
  private let worker = ThumbnailWorker()

  init(cache: ImagePreviewCache? = nil) { self.cache = cache ?? ImagePreviewCache() }

  func preview(for id: UUID, source: () -> ImageSource?) async -> ImageResult? {
    if let value = cache.value(for: id) { return value }
    guard !Task.isCancelled, let source = source() else { return nil }
    guard let result = await worker.make(source), !Task.isCancelled else { return nil }
    cache.insert(result, for: id)
    return result
  }
}

struct OCRResult: Sendable {
  let text: String
  let width: Int
  let height: Int
  let normalizedText: String

  init(text: String, width: Int, height: Int) {
    self.text = text
    self.width = width
    self.height = height
    self.normalizedText = ContentProcessor.normalize(text)
  }
}

/// The lock protects a Vision request while its worker receives cancellation.
private final class OCRCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var request: VNRequest?
  private var cancelled = false

  func register(_ request: VNRequest) {
    lock.lock()
    self.request = request
    let cancelled = cancelled
    lock.unlock()
    if cancelled { request.cancel() }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let request = request
    lock.unlock()
    request?.cancel()
  }
}

@MainActor
final class OCRService {
  typealias Recognizer = @Sendable (ImageSource) async -> OCRResult?
  private struct Job {
    let id: UUID
    let source: () -> ImageSource?
    let completion: (OCRResult) -> Void
  }
  private var queue: [Job] = []
  private var running: [UUID: Task<Void, Never>] = [:]
  private let workerLimit: Int
  private let recognize: Recognizer
  var activeCount: Int { running.count }
  var queuedCount: Int { queue.count }

  init(workerLimit: Int = 2, recognize: @escaping Recognizer = { await OCRService.recognize($0) }) {
    self.workerLimit = max(1, workerLimit)
    self.recognize = recognize
  }

  func enqueue(id: UUID, source: @escaping () -> ImageSource?, completion: @escaping (OCRResult) -> Void) {
    guard running[id] == nil || running[id]?.isCancelled == true, !queue.contains(where: { $0.id == id }) else { return }
    queue.append(Job(id: id, source: source, completion: completion))
    startNext()
  }

  func cancel(_ id: UUID) {
    queue.removeAll { $0.id == id }
    running[id]?.cancel()
  }

  func cancelAll() {
    queue.removeAll()
    running.values.forEach { $0.cancel() }
  }

  private func startNext() {
    while running.count < workerLimit, let next = queue.firstIndex(where: { running[$0.id] == nil }) {
      let job = queue.remove(at: next)
      guard let source = job.source() else { continue }
      let recognize = recognize
      running[job.id] = Task { [weak self] in
        let result = await recognize(source)
        if !Task.isCancelled, let result { job.completion(result) }
        self?.running.removeValue(forKey: job.id)
        self?.startNext()
      }
    }
  }

  private nonisolated static func recognize(_ source: ImageSource) async -> OCRResult? {
    let cancellation = OCRCancellation()
    let worker = Task.detached(priority: .utility) { () -> OCRResult? in
      autoreleasepool {
        guard let result = ImageProcessor.thumbnail(source, maxDimension: 2400), !Task.isCancelled else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        cancellation.register(request)
        do {
          try VNImageRequestHandler(cgImage: result.image, options: [:]).perform([request])
        } catch { return nil }
        guard !Task.isCancelled else { return nil }
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
          .joined(separator: "\n")
        return OCRResult(text: String(text.prefix(10_000)), width: result.width, height: result.height)
      }
    }
    return await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
      cancellation.cancel()
    }
  }
}
