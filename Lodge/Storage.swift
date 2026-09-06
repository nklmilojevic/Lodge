import Foundation
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  private(set) var loadError: String?
  private let location: URL

  func formattedSize() async -> String {
    let directory = location.deletingLastPathComponent()
    return await Task.detached(priority: .utility) { Self.directorySize(directory) }.value
  }

  private nonisolated static func directorySize(_ storeDirectory: URL) -> String {
    guard let enumerator = FileManager.default.enumerator(
      at: storeDirectory,
      includingPropertiesForKeys: [.fileAllocatedSizeKey, .fileSizeKey],
      options: []
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

  init(url: URL? = nil, makeContainer: ((ModelConfiguration) throws -> ModelContainer)? = nil) {
    location = url ?? Self.storeURL
    if url == nil && !CommandLine.arguments.contains("enable-testing") {
      Self.migrateLegacyDatabaseIfNeeded()
    }
    var config = ModelConfiguration(url: location)

    #if DEBUG
    if url == nil && CommandLine.arguments.contains("enable-testing") {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      if let makeContainer { container = try makeContainer(config) }
      else { container = try ModelContainer(for: HistoryItem.self, configurations: config) }
    } catch {
      loadError = error.localizedDescription
      NSLog("Cannot load Lodge database; using temporary in-memory storage.")

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
      NSLog("Cannot migrate the legacy Lodge database.")
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

/// Groups each history operation into one save. Failed changes are discarded.
@MainActor
final class HistoryRepository {
  static let shared = HistoryRepository()
  let context: ModelContext
  private let commit: (ModelContext) throws -> Void

  init(context: ModelContext? = nil, commit: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
    self.context = context ?? Storage.shared.context
    self.context.autosaveEnabled = false
    self.commit = commit
  }

  func fetchAll() throws -> [HistoryItem] {
    try context.fetch(FetchDescriptor<HistoryItem>())
  }

  func transaction<T>(updating items: [HistoryItem] = [], _ operation: () throws -> T) throws -> T {
    let restore = items.map { $0.rollbackAction() }
    let interval = AppPerformance.signposter.beginInterval("Save history")
    defer { AppPerformance.signposter.endInterval("Save history", interval) }
    do {
      let result = try operation()
      context.processPendingChanges()
      try commit(context)
      return result
    } catch {
      context.processPendingChanges()
      context.rollback()
      // SwiftData can retain cached properties after rollback. Restore the values seen by the popup too.
      restore.forEach { $0() }
      context.processPendingChanges()
      throw error
    }
  }

  func insert(_ item: HistoryItem) {
    context.insert(item)
    // Establish the model before setting its relationships on macOS 14.
    context.processPendingChanges()
  }

  func delete(_ item: HistoryItem) {
    context.delete(item)
  }

  func deleteContents(_ contents: [HistoryItemContent]) {
    contents.forEach(context.delete)
  }

  @discardableResult
  func deleteOrphanedContents() throws -> Int {
    let orphans = try context.fetch(
      FetchDescriptor<HistoryItemContent>(predicate: #Predicate { $0.item == nil })
    )
    orphans.forEach(context.delete)
    return orphans.count
  }
}
