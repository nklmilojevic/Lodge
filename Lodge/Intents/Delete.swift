import AppIntents

struct Delete: AppIntent, CustomIntentMigratedAppIntent {
  static let intentClassName = "DeleteIntent"

  static let title: LocalizedStringResource = "Delete Item from Clipboard History"
  static let description = IntentDescription("Deletes an item from Lodge clipboard history.")

  @Parameter(title: "Number", default: 1)
  var number: Int

  static var parameterSummary: some ParameterSummary {
    Summary("Delete \(\.$number) Item from Clipboard History")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    let items = AppState.shared.history.items
    let index = try HistoryItemPosition.index(number: number, count: items.count)

    guard AppState.shared.history.delete(items[index]) else { throw AppIntentError.storageFailure }

    return .result()
  }
}
