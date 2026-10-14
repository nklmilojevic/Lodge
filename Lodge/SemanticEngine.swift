import AppKit
import LlamaEmbedding
import Observation

enum SemanticCapability: Equatable, Sendable {
  case none
  case text
  case textAndImages

  var supportsImages: Bool { self == .textAndImages }
}

/// Produces vectors for queries, item text, and images.
@MainActor
protocol SemanticEmbedder: AnyObject {
  var capability: SemanticCapability { get }
  /// Identifies the vectors this embedder produces. Items with another version are embedded again.
  var vectorVersion: Int { get }
  func prepare()
  func embed(query: String) async throws -> [Float]
  func embed(documents: [String]) async throws -> [[Float]]
  func embed(image: ImageSource) async throws -> [Float]
}

/// The EmbeddingGemma 2 files in Application Support. Nothing is downloaded until the user asks.
@Observable
@MainActor
final class SemanticModelStore {
  static let shared = SemanticModelStore()

  enum Phase: Equatable {
    case idle
    case downloading(fraction: Double)
    case verifying
    case failed(String)
  }

  let folder: URL
  private(set) var phase: Phase = .idle
  private(set) var textInstalled = false
  private(set) var imagesInstalled = false
  @ObservationIgnored private var downloadTask: Task<Void, Never>?
  @ObservationIgnored private var installGeneration: UInt64 = 0
  @ObservationIgnored private var download: FileDownload?

  static var isSupported: Bool {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
  }

  init(folder: URL = URL.applicationSupportDirectory.appending(path: "Lodge/Models")) {
    self.folder = folder
    refresh()
  }

  var capability: SemanticCapability {
    guard Self.isSupported, textInstalled else { return .none }
    return imagesInstalled ? .textAndImages : .text
  }

  var textURL: URL { folder.appending(path: EmbeddingModelFiles.text.name) }
  var mediaURL: URL? { imagesInstalled ? folder.appending(path: EmbeddingModelFiles.media.name) : nil }
  var isBusy: Bool {
    switch phase {
    case .downloading, .verifying: return true
    default: return false
    }
  }

  func refresh() {
    let fileManager = FileManager.default
    textInstalled = fileManager.fileExists(atPath: folder.appending(path: EmbeddingModelFiles.text.name).path)
    imagesInstalled = textInstalled &&
      fileManager.fileExists(atPath: folder.appending(path: EmbeddingModelFiles.media.name).path)
  }

  /// Downloads the text model, and the image model when `images` is true.
  func install(images: Bool) {
    guard Self.isSupported, !isBusy else { return }
    var files: [EmbeddingModelFiles.File] = []
    if !textInstalled { files.append(EmbeddingModelFiles.text) }
    if images && !imagesInstalled { files.append(EmbeddingModelFiles.media) }
    guard !files.isEmpty else { return }
    let total = files.reduce(0) { $0 + $1.bytes }
    phase = .downloading(fraction: 0)
    installGeneration &+= 1
    let generation = installGeneration
    downloadTask = Task { [weak self] in
      guard let self else { return }
      var completed: Int64 = 0
      do {
        try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        var folder = self.folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        for file in files {
          let offset = completed
          let download = FileDownload(url: file.url) { [weak self] written in
            Task { @MainActor in
              guard let self, case .downloading = self.phase else { return }
              self.phase = .downloading(fraction: Double(offset + written) / Double(total))
            }
          }
          self.download = download
          let temporary = try await download.start()
          guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: temporary)
            throw CancellationError()
          }
          self.phase = .verifying
          let destination = self.folder.appending(path: file.name)
          try await Task.detached(priority: .utility) {
            defer { try? FileManager.default.removeItem(at: temporary) }
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(size) == file.bytes, try EmbeddingModelFiles.sha256(of: temporary) == file.sha256 else {
              throw SemanticModelError.verification
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
          }.value
          completed += file.bytes
          self.phase = .downloading(fraction: Double(completed) / Double(total))
          self.refresh()
        }
        self.phase = .idle
      } catch is CancellationError {
        self.phase = .idle
      } catch SemanticModelError.verification {
        self.phase = .failed("The downloaded model did not pass verification. Try again.")
      } catch {
        self.phase = Task.isCancelled ? .idle : .failed("The model could not be downloaded. Try again.")
      }
      self.refresh()
      guard generation == self.installGeneration else { return }
      self.download = nil
      self.downloadTask = nil
      NotificationCenter.default.post(name: .semanticModelChanged, object: nil)
    }
  }

  func cancel() {
    download?.cancel()
    downloadTask?.cancel()
  }

  /// Removes the image model only, or every model file.
  func remove(imagesOnly: Bool) {
    cancel()
    SemanticEngine.shared.unload()
    try? FileManager.default.removeItem(at: folder.appending(path: EmbeddingModelFiles.media.name))
    if !imagesOnly { try? FileManager.default.removeItem(at: folder.appending(path: EmbeddingModelFiles.text.name)) }
    phase = .idle
    refresh()
    NotificationCenter.default.post(name: .semanticModelChanged, object: nil)
  }
}

enum SemanticModelError: Error {
  case verification
  case unavailable
  case unreadableImage
}

extension Notification.Name {
  static let semanticModelChanged = Notification.Name("com.nklmilojevic.Lodge.semanticModelChanged")
}

/// One file download with progress. The finished file is moved to a temporary location the caller owns.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let url: URL
  private let progress: @Sendable (Int64) -> Void
  private let lock = NSLock()
  private var continuation: CheckedContinuation<URL, Error>?
  private var session: URLSession?
  private var reported: Int64 = 0
  private var cancelled = false

  init(url: URL, progress: @escaping @Sendable (Int64) -> Void) {
    self.url = url
    self.progress = progress
  }

  func start() async throws -> URL {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock { self.continuation = continuation }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let cancelled = lock.withLock {
          self.session = session
          return self.cancelled
        }
        guard !cancelled else {
          session.invalidateAndCancel()
          return finish(.failure(CancellationError()))
        }
        session.downloadTask(with: url).resume()
      }
    } onCancel: { cancel() }
  }

  func cancel() {
    lock.withLock {
      cancelled = true
      return session
    }?.invalidateAndCancel()
  }

  private func finish(_ result: Result<URL, Error>) {
    let continuation = lock.withLock {
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume(with: result)
    lock.withLock { session }?.finishTasksAndInvalidate()
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                  totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    // Report every 4 MB instead of every network chunk.
    guard totalBytesWritten - reported >= 4 << 20 else { return }
    reported = totalBytesWritten
    progress(totalBytesWritten)
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
      return finish(.failure(URLError(.badServerResponse)))
    }
    let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    do {
      try FileManager.default.moveItem(at: location, to: destination)
      finish(.success(destination))
    } catch { finish(.failure(error)) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error { finish(.failure(error)) }
  }
}

/// Runs EmbeddingGemma 2 on a serial queue. The model loads on first use and unloads after two idle minutes.
@MainActor
final class SemanticEngine: SemanticEmbedder {
  static let shared = SemanticEngine()

  private let worker = EmbeddingWorker()
  private let store: SemanticModelStore

  init(store: SemanticModelStore? = nil) { self.store = store ?? .shared }

  var capability: SemanticCapability { store.capability }
  var vectorVersion: Int { LlamaEmbedder.vectorVersion }

  func prepare() {
    guard capability != .none else { return }
    let text = store.textURL
    worker.run { _ = try $0.embedder(text: text, media: nil, images: false) }
  }

  func unload() { worker.run { $0.unload() } }

  func embed(query: String) async throws -> [Float] {
    try await embed(prompts: [EmbeddingPrompts.query(query)])[0]
  }

  func embed(documents: [String]) async throws -> [[Float]] {
    try await embed(prompts: documents.map(EmbeddingPrompts.document))
  }

  func embed(image: ImageSource) async throws -> [Float] {
    guard capability.supportsImages, let media = store.mediaURL else { throw SemanticModelError.unavailable }
    let text = store.textURL
    return try await worker.perform { state in
      guard let pixels = EmbeddingImage.pixels(image) else { throw SemanticModelError.unreadableImage }
      return try state.embedder(text: text, media: media, images: true)
        .embed(rgb: pixels.data, width: pixels.width, height: pixels.height)
    }
  }

  private func embed(prompts: [String]) async throws -> [[Float]] {
    guard capability != .none else { throw SemanticModelError.unavailable }
    let text = store.textURL
    return try await worker.perform { try $0.embedder(text: text, media: nil, images: false).embed(texts: prompts) }
  }
}

/// Owns the loaded model. Every access happens on its queue.
private final class EmbeddingWorker: @unchecked Sendable {
  final class State {
    private var embedder: LlamaEmbedder?
    private var loadedText: URL?
    fileprivate var idle: DispatchWorkItem?

    /// A loaded image model also serves text, so text requests keep it.
    func embedder(text: URL, media: URL?, images: Bool) throws -> LlamaEmbedder {
      if let embedder, loadedText == text, embedder.supportsImages || !images { return embedder }
      unload()
      let embedder = try LlamaEmbedder(text: text, media: images ? media : nil)
      self.embedder = embedder
      loadedText = text
      return embedder
    }

    func unload() {
      embedder?.close()
      embedder = nil
      loadedText = nil
    }
  }

  private let queue = DispatchQueue(label: "com.nklmilojevic.Lodge.embedding", qos: .utility)
  private let state = State()

  func run(_ work: @escaping @Sendable (State) throws -> Void) {
    queue.async { [self] in
      try? work(state)
      scheduleUnload()
    }
  }

  func perform<T: Sendable>(_ work: @escaping @Sendable (State) throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        continuation.resume(with: Result { try autoreleasepool { try work(state) } })
        scheduleUnload()
      }
    }
  }

  private func scheduleUnload() {
    state.idle?.cancel()
    let item = DispatchWorkItem { [state] in state.unload() }
    state.idle = item
    queue.asyncAfter(deadline: .now() + 120, execute: item)
  }
}

/// Decodes an image into the packed RGB pixels the vision encoder expects, on a white background.
enum EmbeddingImage {
  static func pixels(_ source: ImageSource) -> (data: [UInt8], width: Int, height: Int)? {
    guard let result = ImageProcessor.thumbnail(source, maxDimension: 2048) else { return nil }
    let image = result.image
    let width = image.width, height = image.height
    guard let target = ImageSizing.targetSize(height: height, width: width, budget: LlamaEmbedder.imageBudget) else {
      return nil
    }
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
