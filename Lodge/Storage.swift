import Foundation
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let size = try? Self.storeURL.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  private static let storeURL = URL.applicationSupportDirectory.appending(path: "Lodge/Storage.sqlite")
  private static let legacyDatabaseCandidates: [URL] = {
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    let globalApplicationSupport = homeDirectory.appending(path: "Library/Application Support")
    return [
      globalApplicationSupport.appending(path: "ClipAid/Storage.sqlite"),
      globalApplicationSupport.appending(path: "ClipAid/ClipAid.sqlite"),
      homeDirectory.appending(path: "Library/Containers/org.p0deje.ClipAid/Data/Library/Application Support/ClipAid/Storage.sqlite"),
      homeDirectory.appending(path: "Library/Containers/org.p0deje.ClipAid/Data/Library/Application Support/ClipAid/ClipAid.sqlite")
    ]
  }()

  init() {
    Self.migrateLegacyDatabaseIfNeeded()
    var config = ModelConfiguration(url: Self.storeURL)

    #if DEBUG
    if CommandLine.arguments.contains("enable-testing") {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
  }

  private static func migrateLegacyDatabaseIfNeeded() {
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: Self.storeURL.path) else {
      return
    }

    guard let legacyURL = Self.legacyDatabaseCandidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
      return
    }

    let targetDirectory = Self.storeURL.deletingLastPathComponent()
    do {
      try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
      try Self.copyStoreFiles(from: legacyURL, to: Self.storeURL)
    } catch {
      return
    }
  }

  private static func copyStoreFiles(from legacyURL: URL, to targetURL: URL) throws {
    let fileManager = FileManager.default
    let legacyDirectory = legacyURL.deletingLastPathComponent()
    let targetDirectory = targetURL.deletingLastPathComponent()
    let legacyBaseName = legacyURL.lastPathComponent
    let targetBaseName = targetURL.lastPathComponent

    let storeFiles: [URL]
    if let contents = try? fileManager.contentsOfDirectory(
      at: legacyDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) {
      storeFiles = contents.filter { $0.lastPathComponent.hasPrefix(legacyBaseName) }
    } else {
      storeFiles = [
        legacyURL,
        URL(fileURLWithPath: legacyURL.path + "-wal"),
        URL(fileURLWithPath: legacyURL.path + "-shm")
      ]
    }

    for legacyFile in storeFiles where fileManager.fileExists(atPath: legacyFile.path) {
      let suffix = legacyFile.lastPathComponent.dropFirst(legacyBaseName.count)
      let targetFile = targetDirectory.appending(path: targetBaseName + suffix)
      guard !fileManager.fileExists(atPath: targetFile.path) else {
        continue
      }
      try fileManager.copyItem(at: legacyFile, to: targetFile)
    }
  }
}
