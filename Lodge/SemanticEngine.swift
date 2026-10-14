import AppKit
import CoreML
import CryptoKit
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

/// The pinned EmbeddingGemma 2 Core ML files (FluidInference/embeddinggemma-2-coreml, Apache 2.0), and where they live.
struct SemanticModelFiles: Sendable {
  static let repository = "FluidInference/embeddinggemma-2-coreml"
  static let revision = "3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4"
  /// Changes whenever the vectors change: the model, the tokenizer, image preparation, or the prompts.
  static let vectorVersion = 2
  static let documentPrompt = "title: none | text: "
  static let queryPrompt = "task: search result | query: "

  struct File: Sendable, Equatable {
    let path: String
    let bytes: Int64
    let sha256: String

    var url: URL {
      URL(string: "https://huggingface.co/\(SemanticModelFiles.repository)/resolve/\(SemanticModelFiles.revision)/\(path)")!
    }
  }

  static let textPackage = "EmbeddingGemma2Text.mlpackage"
  static let visionPackage = "EmbeddingGemma2Vision.mlpackage"
  static let tokenizer = "tokenizer.json"
  static let tokenTable = "embeddings.bf16"
  static let positionTable = "position_embeddings.f16"

  static let text = [
    File(path: tokenizer, bytes: 32_170_510,
         sha256: "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4"),
    File(path: tokenTable, bytes: 268_435_456,
         sha256: "56ebbdbfd706c827f3fae1d97aa39135c7ddc0f1e6d9b12f8565f84bbfbda877"),
    File(path: "\(textPackage)/Manifest.json", bytes: 617,
         sha256: "83eace80b69b46f8415af620ba1b40d7c490d00f7c00ba9dedd2e29da6e9ac19"),
    File(path: "\(textPackage)/Data/com.apple.CoreML/model.mlmodel", bytes: 7_323_423,
         sha256: "0df9aca02807cf490db6d4f1c68607a8c7f486ad23b376d1968fd3be5eb14677"),
    File(path: "\(textPackage)/Data/com.apple.CoreML/weights/weight.bin", bytes: 276_815_424,
         sha256: "75b97ab036ca87eae60560c4034a63d604201498dc4b6f6971dd0b1e4558d61f")
  ]
  static let images = [
    File(path: positionTable, bytes: 3_145_728,
         sha256: "17de9480acc23638c0634a97ed89e51ed664433256d7d6f109587dcd91c79124"),
    File(path: "\(visionPackage)/Manifest.json", bytes: 617,
         sha256: "376afe7b51608637312cd15a0a89b1d7863f9779502aaf5f12fa6b14c4272d8d"),
    File(path: "\(visionPackage)/Data/com.apple.CoreML/model.mlmodel", bytes: 2_053_174,
         sha256: "0085b5e04a13d000fe5969adeaa13d897f5a3cb7be60c76c8685c023747f89ef"),
    File(path: "\(visionPackage)/Data/com.apple.CoreML/weights/weight.bin", bytes: 304_078_400,
         sha256: "5b5b6dd8d80aa438bf91ba143fbe90d56a2e25bfcf685a56b990aad71cf75232")
  ]
  static var textBytes: Int64 { text.reduce(0) { $0 + $1.bytes } }
  static var imageBytes: Int64 { images.reduce(0) { $0 + $1.bytes } }

  let folder: URL

  func url(for path: String) -> URL { folder.appending(path: path) }

  func installed(_ files: [File]) -> Bool {
    files.allSatisfy { FileManager.default.fileExists(atPath: url(for: $0.path).path) }
  }

  /// The compiled model, cached beside the package so later launches skip compilation.
  func compiled(_ package: String) async throws -> URL {
    let destination = folder.appending(path: "Compiled/\((package as NSString).deletingPathExtension).mlmodelc")
    if FileManager.default.fileExists(atPath: destination.path) { return destination }
    let temporary = try await MLModel.compileModel(at: url(for: package))
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: temporary, to: destination)
    return destination
  }

  static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let done = try autoreleasepool { () -> Bool in
        guard let data = try handle.read(upToCount: 8 << 20), !data.isEmpty else { return true }
        hasher.update(data: data)
        return false
      }
      if done { break }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
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

  let files: SemanticModelFiles
  private(set) var phase: Phase = .idle
  private(set) var textInstalled = false
  private(set) var imagesInstalled = false
  @ObservationIgnored private var downloadTask: Task<Void, Never>?
  @ObservationIgnored private var installGeneration: UInt64 = 0
  @ObservationIgnored private var download: FileDownload?

  /// Core ML multi-function models need macOS 15. The text model runs on the Neural Engine of Apple silicon.
  static var isSupported: Bool {
    #if arch(arm64)
    if #available(macOS 15, *) { return true }
    #endif
    return false
  }

  nonisolated static let modelsFolder = URL.applicationSupportDirectory.appending(path: "Lodge/Models")

  init(folder: URL = SemanticModelStore.modelsFolder.appending(path: "embeddinggemma-2-coreml")) {
    files = SemanticModelFiles(folder: folder)
    refresh()
  }

  var folder: URL { files.folder }

  var capability: SemanticCapability {
    guard Self.isSupported, textInstalled else { return .none }
    return imagesInstalled ? .textAndImages : .text
  }

  var isBusy: Bool {
    switch phase {
    case .downloading, .verifying: return true
    default: return false
    }
  }

  func refresh() {
    textInstalled = files.installed(SemanticModelFiles.text)
    imagesInstalled = textInstalled && files.installed(SemanticModelFiles.images)
  }

  /// Lodge 2.1 used llama.cpp GGUF files beside this model's folder. Because the user opted in then, this downloads
  /// the Core ML model with the same image choice. The old files stay until the replacement is installed, so a failed
  /// download is retried at the next launch, and they stay on Macs that cannot run the Core ML model.
  func migrateLegacyModel() {
    guard Self.isSupported, let images = legacyModel() else { return }
    if textInstalled && (imagesInstalled || !images) {
      removeLegacyModel()
    } else {
      install(images: images)
    }
  }

  /// Whether a legacy model is installed with images, or nil when there is none.
  func legacyModel() -> Bool? {
    guard FileManager.default.fileExists(atPath: legacyFiles.text.path) else { return nil }
    return FileManager.default.fileExists(atPath: legacyFiles.media.path)
  }

  func removeLegacyModel() {
    try? FileManager.default.removeItem(at: legacyFiles.text)
    try? FileManager.default.removeItem(at: legacyFiles.media)
  }

  private var legacyFiles: (text: URL, media: URL) {
    let legacy = folder.deletingLastPathComponent()
    return (legacy.appending(path: "embeddinggemma-2-Q8_0.gguf"), legacy.appending(path: "mmproj-embeddinggemma-2-Q8_0.gguf"))
  }

  /// Downloads the text model, and the image model when `images` is true.
  func install(images: Bool) {
    guard Self.isSupported, !isBusy else { return }
    let pending = missingFiles(images: images)
    guard !pending.isEmpty else {
      refresh()
      return
    }
    phase = .downloading(fraction: 0)
    installGeneration &+= 1
    let generation = installGeneration
    downloadTask = Task { [weak self] in
      guard let self else { return }
      let outcome: Phase
      do {
        try await self.download(pending, generation: generation)
        outcome = .idle
      } catch is CancellationError {
        outcome = .idle
      } catch SemanticModelError.verification {
        outcome = .failed("The downloaded model did not pass verification. Try again.")
      } catch {
        outcome = Task.isCancelled ? .idle : .failed("The model could not be downloaded. Try again.")
      }
      self.finishInstall(generation: generation, outcome: outcome)
    }
  }

  private func missingFiles(images: Bool) -> [SemanticModelFiles.File] {
    var wanted: [SemanticModelFiles.File] = []
    if !textInstalled { wanted += SemanticModelFiles.text }
    if images && !imagesInstalled { wanted += SemanticModelFiles.images }
    var missing: [SemanticModelFiles.File] = []
    for file in wanted where !FileManager.default.fileExists(atPath: files.url(for: file.path).path) {
      missing.append(file)
    }
    return missing
  }

  private func download(_ pending: [SemanticModelFiles.File], generation: UInt64) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var folder = folder
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? folder.setResourceValues(values)
    var total: Int64 = 0
    for file in pending { total += file.bytes }
    var completed: Int64 = 0
    for file in pending {
      try await download(file, generation: generation, completed: completed, total: total)
      completed += file.bytes
      phase = .downloading(fraction: Double(completed) / Double(total))
    }
  }

  /// Downloads, verifies, and stages one file on the destination volume, then commits it only if no cancel or
  /// removal superseded this install. An existing file is replaced atomically.
  private func download(_ file: SemanticModelFiles.File, generation: UInt64, completed: Int64, total: Int64)
    async throws {
    let download = FileDownload(url: file.url) { [weak self] written in
      Task { @MainActor [weak self] in self?.reportProgress(Double(completed + written) / Double(total)) }
    }
    self.download = download
    let temporary = try await download.start()
    guard !Task.isCancelled else {
      try? FileManager.default.removeItem(at: temporary)
      throw CancellationError()
    }
    let destination = files.url(for: file.path)
    let staged = destination.appendingPathExtension("partial")
    try await Self.stage(temporary, as: file, at: staged)
    do {
      guard generation == installGeneration, !Task.isCancelled else { throw CancellationError() }
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
      } else {
        try FileManager.default.moveItem(at: staged, to: destination)
      }
    } catch {
      try? FileManager.default.removeItem(at: staged)
      throw error
    }
  }

  private func reportProgress(_ fraction: Double) {
    guard case .downloading = phase else { return }
    phase = .downloading(fraction: fraction)
  }

  /// Checks the size and SHA-256 off the main actor and moves the file to `staged`.
  private nonisolated static func stage(_ temporary: URL, as file: SemanticModelFiles.File, at staged: URL)
    async throws {
    try await Task.detached(priority: .utility) {
      defer { try? FileManager.default.removeItem(at: temporary) }
      let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard Int64(size) == file.bytes, try SemanticModelFiles.sha256(of: temporary) == file.sha256 else {
        throw SemanticModelError.verification
      }
      try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
      try FileManager.default.moveItem(at: temporary, to: staged)
    }.value
  }

  private func finishInstall(generation: UInt64, outcome: Phase) {
    refresh()
    if let images = legacyModel(), textInstalled, imagesInstalled || !images { removeLegacyModel() }
    // A cancel, removal, or newer install owns the state now.
    guard generation == installGeneration else { return }
    phase = outcome
    download = nil
    downloadTask = nil
    NotificationCenter.default.post(name: .semanticModelChanged, object: nil)
  }

  func cancel() {
    guard isBusy || downloadTask != nil else { return }
    installGeneration &+= 1
    download?.cancel()
    downloadTask?.cancel()
    download = nil
    downloadTask = nil
    phase = .idle
    refresh()
    NotificationCenter.default.post(name: .semanticModelChanged, object: nil)
  }

  /// Removes the image model only, or every model file.
  func remove(imagesOnly: Bool) {
    cancel()
    // Otherwise the next launch would migrate the old model and download this one again.
    removeLegacyModel()
    SemanticEngine.shared.stop()
    let fileManager = FileManager.default
    for file in SemanticModelFiles.images { try? fileManager.removeItem(at: files.url(for: file.path)) }
    try? fileManager.removeItem(at: files.url(for: SemanticModelFiles.visionPackage))
    try? fileManager.removeItem(at: files.url(for: "Compiled/EmbeddingGemma2Vision.mlmodelc"))
    if !imagesOnly { try? fileManager.removeItem(at: files.folder) }
    phase = .idle
    refresh()
    NotificationCenter.default.post(name: .semanticModelChanged, object: nil)
  }
}

enum SemanticModelError: Error, Equatable {
  case verification
  case unavailable
  case unreadableImage
  case helper(String)
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


/// The app's side of semantic search. Vectors come from the embedding helper process, so the model's memory and any
/// model crash stay out of the app.
@MainActor
final class SemanticEngine: SemanticEmbedder {
  static let shared = SemanticEngine()

  private let store: SemanticModelStore
  private let helper: EmbeddingHelperClient

  init(store: SemanticModelStore? = nil) {
    self.store = store ?? .shared
    helper = EmbeddingHelperClient(folder: self.store.folder)
  }

  var capability: SemanticCapability { store.capability }
  var vectorVersion: Int { SemanticModelFiles.vectorVersion }

  /// Starts the helper and loads the text model, so the first query does not wait for it.
  func prepare() {
    guard capability != .none else { return }
    Task { _ = try? await helper.send(EmbeddingRequest(kind: .prepare)) }
  }

  func stop() { helper.stop() }

  func embed(query: String) async throws -> [Float] {
    try await embed(texts: [SemanticModelFiles.queryPrompt + query])[0]
  }

  func embed(documents: [String]) async throws -> [[Float]] {
    try await embed(texts: documents.map { SemanticModelFiles.documentPrompt + $0 })
  }

  func embed(image: ImageSource) async throws -> [Float] {
    guard capability.supportsImages else { throw SemanticModelError.unavailable }
    var request = EmbeddingRequest(kind: .image)
    var temporary: URL?
    switch image {
    case .file(let url): request.path = url.path
    case .data(let data):
      // Image data goes through a private temporary file rather than the pipe. The helper reads it as data, so
      // the size limit for file sources does not apply.
      request.ownedFile = true
      let url = FileManager.default.temporaryDirectory.appending(path: "LodgeEmbedding-\(UUID().uuidString)")
      try data.write(to: url, options: .atomic)
      temporary = url
      request.path = url.path
    }
    defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
    guard let vector = try await helper.send(request).first else { throw SemanticModelError.unavailable }
    return vector
  }

  private func embed(texts: [String]) async throws -> [[Float]] {
    guard capability != .none else { throw SemanticModelError.unavailable }
    var request = EmbeddingRequest(kind: .text)
    request.texts = texts
    let vectors = try await helper.send(request)
    guard vectors.count == texts.count else { throw SemanticModelError.unavailable }
    return vectors
  }
}
