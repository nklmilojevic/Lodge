import CryptoKit
import Foundation

/// ggml-org's Q8_0 GGUF conversion of google/embeddinggemma-2 at one pinned revision. The F16 files are not used
/// because the model's activations overflow float16.
public enum EmbeddingModelFiles {
  public static let repository = "ggml-org/embeddinggemma-2-GGUF"
  public static let revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"

  public struct File: Sendable, Equatable {
    public let name: String
    public let bytes: Int64
    public let sha256: String

    public var url: URL {
      URL(string: "https://huggingface.co/\(EmbeddingModelFiles.repository)/resolve/\(EmbeddingModelFiles.revision)/\(name)")!
    }
  }

  /// The text model. Queries and text items need only this file.
  public static let text = File(name: "embeddinggemma-2-Q8_0.gguf", bytes: 309_855_456,
                                sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135")
  /// The image and audio encoders.
  public static let media = File(name: "mmproj-embeddinggemma-2-Q8_0.gguf", bytes: 554_821_024,
                                 sha256: "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f")

  public static func sha256(of url: URL) throws -> String {
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

public enum EmbeddingPrompts {
  public static func query(_ text: String) -> String { "task: search result | query: \(text)" }
  public static func document(_ text: String) -> String { "title: none | text: \(text)" }
}
