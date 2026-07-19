import Foundation
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  private(set) var loadError: String?
  var size: String {
    let storeDirectory = Self.storeURL.deletingLastPathComponent()
    guard let enumerator = FileManager.default.enumerator(
      at: storeDirectory,
      includingPropertiesForKeys: [.fileAllocatedSizeKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ) else {
      return ""
    }

    let size = enumerator.compactMap { entry -> Int64? in
      guard let url = entry as? URL,
            let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]) else {
        return nil
      }
      return Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
    }.reduce(0, +)

    guard size > 0 else { return "" }
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
    } catch {
      loadError = error.localizedDescription
      NSLog("Cannot load Lodge database; using temporary in-memory storage: \(error)")

      do {
        container = try ModelContainer(
          for: HistoryItem.self,
          configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
      } catch {
        preconditionFailure("Cannot create fallback database: \(error.localizedDescription).")
      }
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
      NSLog("Cannot migrate legacy Lodge database from \(legacyURL.path): \(error)")
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

/// Owns SwiftData access so History can be tested independently from persistence details.
@MainActor
final class HistoryRepository {
  static let shared = HistoryRepository()

  private let context: ModelContext

  init(context: ModelContext? = nil) {
    self.context = context ?? Storage.shared.context
  }

  func fetchAll() throws -> [HistoryItem] {
    try context.fetch(FetchDescriptor<HistoryItem>())
  }

  func insert(_ item: HistoryItem) throws {
    context.insert(item)
    context.processPendingChanges()
    try context.save()
  }

  func save() throws {
    try context.save()
  }

  func delete(_ item: HistoryItem) throws {
    context.delete(item)
    context.processPendingChanges()
    try context.save()
  }

  func delete(_ items: [HistoryItem]) throws {
    try context.transaction {
      items.forEach(context.delete)
    }
    try context.save()
  }

  func deleteUnpinned() throws {
    try context.transaction {
      try context.delete(model: HistoryItem.self, where: #Predicate { $0.pin == nil })
    }
    context.processPendingChanges()
    try context.save()
  }

  func deleteAll() throws {
    try context.delete(model: HistoryItem.self)
    context.processPendingChanges()
    try context.save()
  }
}
