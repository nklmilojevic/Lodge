import Foundation

/// One request per line from Lodge to the embedding helper.
struct EmbeddingRequest: Codable, Sendable {
  enum Kind: String, Codable, Sendable {
    case prepare
    case text
    case image
  }

  var id = 0
  var kind: Kind
  var texts: [String]?
  var path: String?
  /// A temporary file Lodge wrote from image data. It is decoded as data, without the file-source size limit.
  var ownedFile: Bool?
}

/// One response per line from the helper. Vectors are float32 bytes.
struct EmbeddingResponse: Codable, Sendable {
  var id: Int
  var vectors: [Data]?
  var error: String?
  var unreadable: Bool?
}

/// Lodge started as `Lodge --embedding-helper <model folder>`. The model loads only in this process. It reads
/// requests from standard input and exits when Lodge closes the pipe or after two idle minutes, which returns all of
/// the model's memory to the system.
enum EmbeddingHelper {
  static let argument = "--embedding-helper"
  static let idleTimeout: TimeInterval = 120

  static var requested: Bool { CommandLine.arguments.dropFirst().first == argument }

  static func main() -> Never {
    signal(SIGPIPE, SIG_IGN)
    guard CommandLine.arguments.count > 2 else { exit(64) }
    let folder = URL(fileURLWithPath: CommandLine.arguments[2])
    let activity = Activity()
    Task.detached {
      while true {
        try? await Task.sleep(for: .seconds(10))
        if activity.idleFor > idleTimeout { exit(0) }
      }
    }
    Task.detached {
      await serve(folder: folder, activity: activity)
      exit(0)
    }
    dispatchMain()
  }

  private static func serve(folder: URL, activity: Activity) async {
    guard #available(macOS 15, *) else { return }
    var embedder: CoreMLEmbedder?
    do {
      for try await line in FileHandle.standardInput.bytes.lines {
        activity.begin()
        defer { activity.end() }
        guard let request = try? JSONDecoder().decode(EmbeddingRequest.self, from: Data(line.utf8)) else { continue }
        var response = EmbeddingResponse(id: request.id)
        do {
          let model = try embedder ?? CoreMLEmbedder(files: SemanticModelFiles(folder: folder))
          embedder = model
          let vectors: [[Float]]
          switch request.kind {
          case .prepare:
            try await model.prepare()
            vectors = []
          case .text:
            vectors = try await model.embed(texts: request.texts ?? [])
          case .image:
            guard let path = request.path else { throw SemanticModelError.unreadableImage }
            let url = URL(fileURLWithPath: path)
            let source: ImageSource = request.ownedFile == true ? .data(try Data(contentsOf: url)) : .file(url)
            vectors = [try await model.embed(image: source)]
          }
          response.vectors = vectors.map { $0.withUnsafeBufferPointer { Data(buffer: $0) } }
        } catch SemanticModelError.unreadableImage {
          response.unreadable = true
        } catch {
          response.error = String(describing: error)
        }
        guard var data = try? JSONEncoder().encode(response) else { continue }
        data.append(0x0A)
        try? FileHandle.standardOutput.write(contentsOf: data)
      }
    } catch {}
  }

  /// When the helper last finished a request, and whether one is running.
  private final class Activity: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var last = Date()

    func begin() { lock.withLock { running += 1 } }
    func end() { lock.withLock { running -= 1; last = Date() } }
    var idleFor: TimeInterval { lock.withLock { running > 0 ? 0 : Date().timeIntervalSince(last) } }
  }
}

/// Starts the embedding helper on demand and matches its responses to requests. A helper that exits or crashes fails
/// its pending requests, and the next request starts a new one.
final class EmbeddingHelperClient: @unchecked Sendable {
  private let folder: URL
  private let executable: URL?
  private let lock = NSLock()
  /// Writes can block when the pipe is full, so they run here, never while holding `lock`, which the reader needs.
  private let writer = DispatchQueue(label: "com.nklmilojevic.Lodge.embedding-helper.writer")
  private var process: Process?
  private var input: FileHandle?
  private var pending: [Int: (process: Process, continuation: CheckedContinuation<[[Float]], Error>)] = [:]
  private var nextID = 0
  private var buffer = Data()

  /// `executable` defaults to Lodge's own binary.
  init(folder: URL, executable: URL? = nil) {
    self.folder = folder
    self.executable = executable
    // Writing to a helper that just exited must fail the write, not end Lodge.
    signal(SIGPIPE, SIG_IGN)
  }

  func send(_ request: EmbeddingRequest) async throws -> [[Float]] {
    try await withCheckedThrowingContinuation { continuation in
      let registered: (id: Int, line: Data, input: FileHandle?)
      do {
        registered = try lock.withLock {
          let process = try startIfNeeded()
          nextID += 1
          var request = request
          request.id = nextID
          var line = try JSONEncoder().encode(request)
          line.append(0x0A)
          pending[nextID] = (process, continuation)
          return (nextID, line, input)
        }
      } catch {
        continuation.resume(throwing: SemanticModelError.helper(String(describing: error)))
        return
      }
      writer.async { [weak self] in
        do {
          try registered.input?.write(contentsOf: registered.line)
        } catch {
          // The helper exited. Fail the request unless its termination already did.
          let request = self?.lock.withLock { self?.pending.removeValue(forKey: registered.id) }
          request?.continuation.resume(throwing: SemanticModelError.helper(String(describing: error)))
        }
      }
    }
  }

  func stop() {
    // terminate() raises an exception for a process that has already exited, for example after its idle timeout.
    lock.withLock {
      guard let process, process.isRunning else { return }
      process.terminate()
    }
  }

  /// Called with the lock held.
  private func startIfNeeded() throws -> Process {
    if let process, process.isRunning { return process }
    guard let executable = executable ?? Bundle.main.executableURL else { throw SemanticModelError.unavailable }
    let process = Process()
    let standardInput = Pipe(), standardOutput = Pipe()
    process.executableURL = executable
    process.arguments = [EmbeddingHelper.argument, folder.path]
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = FileHandle.nullDevice
    process.qualityOfService = .utility
    standardOutput.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil }
      guard let process else { return }
      self?.receive(data, from: process)
    }
    process.terminationHandler = { [weak self] process in self?.terminated(process) }
    try process.run()
    self.process = process
    input = standardInput.fileHandleForWriting
    buffer = Data()
    return process
  }

  /// Output from a helper that has been replaced is ignored, so it cannot mix with the new helper's responses.
  private func receive(_ data: Data, from source: Process) {
    var completed: [(CheckedContinuation<[[Float]], Error>, Result<[[Float]], Error>)] = []
    lock.withLock {
      guard source === process else { return }
      buffer.append(data)
      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(buffer.startIndex...newline)
        guard let response = try? JSONDecoder().decode(EmbeddingResponse.self, from: line),
              let request = pending.removeValue(forKey: response.id) else { continue }
        let result: Result<[[Float]], Error>
        if response.unreadable == true {
          result = .failure(SemanticModelError.unreadableImage)
        } else if let vectors = response.vectors {
          result = .success(vectors.map { data in data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } })
        } else {
          result = .failure(SemanticModelError.helper(response.error ?? "No response"))
        }
        completed.append((request.continuation, result))
      }
    }
    for (continuation, result) in completed { continuation.resume(with: result) }
  }

  private func terminated(_ process: Process) {
    let failed = lock.withLock {
      if self.process === process {
        self.process = nil
        input = nil
      }
      let failed = pending.filter { $0.value.process === process }
      for id in failed.keys { pending.removeValue(forKey: id) }
      return failed.values.map(\.continuation)
    }
    for continuation in failed { continuation.resume(throwing: SemanticModelError.helper("The embedding helper stopped.")) }
  }
}
