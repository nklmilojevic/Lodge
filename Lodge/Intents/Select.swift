import AppIntents

struct Select: AppIntent, CustomIntentMigratedAppIntent {
  static let intentClassName = "SelectIntent"

  static let title: LocalizedStringResource = "Select Item in Clipboard History"
  static let description = IntentDescription("""
  Selects an item in Lodge clipboard history.
  Depending on Lodge settings, it might trigger pasting of the selected item.
  """)

  static var parameterSummary: some ParameterSummary {
    Summary("Select \(\.$number) Item in Clipboard History")
  }

  @Parameter(title: "Number", default: 1, requestValueDialog: "What is the number of the item?")
  var number: Int

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let items = AppState.shared.history.items
    let index = try HistoryItemPosition.index(number: number, count: items.count)

    let value = items[index].title
    AppState.shared.history.select(items[index])

    return .result(value: value)
  }
}
