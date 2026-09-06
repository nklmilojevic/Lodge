import Foundation

enum AppIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
  case notFound
  case storageFailure

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .storageFailure: return "History could not be saved. Open Lodge for details."
    case .notFound: return "Clipboard item not found"
    }
  }
}

enum HistoryItemPosition {
  static func index(number: Int, count: Int) throws -> Int {
    let index = number - 1
    guard (0..<count).contains(index) else {
      throw AppIntentError.notFound
    }
    return index
  }
}
