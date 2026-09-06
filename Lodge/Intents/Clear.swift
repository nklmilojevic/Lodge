import AppIntents
import Defaults

struct Clear: AppIntent, CustomIntentMigratedAppIntent {
  static let intentClassName = "ClearIntent"

  static let title: LocalizedStringResource = "Clear Clipboard History"
  static let description = IntentDescription("Clears all Lodge clipboard history except for pinned items.")

  static var parameterSummary: some ParameterSummary {
    Summary("Clear Clipboard History")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    if !Defaults[.suppressClearAlert] {
      try await requestConfirmation()
    }

    guard AppState.shared.history.clear() else { throw AppIntentError.storageFailure }
    return .result()
  }
}
