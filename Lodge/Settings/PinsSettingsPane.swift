import SwiftData
import SwiftUI

struct PinPickerView: View {
  let item: HistoryItem
  let history: History

  var body: some View {
    if let pin = item.pin {
      Picker("", selection: Binding(get: { item.pin }, set: { history.setPin($0, for: item) })) {
        ForEach(Array(Set(history.availablePins + [pin])).sorted(), id: \.self) { pin in
          Text(pin).tag(pin as String?)
        }
      }
      .controlSize(.small)
      .labelsHidden()
    }
  }
}

struct PinTitleView: View {
  let item: HistoryItem
  let history: History

  var body: some View {
    TextField("", text: Binding(get: { item.title }, set: { history.setTitle($0, for: item) }))
  }
}

struct PinValueView: View {
  let item: HistoryItem
  let history: History
  @State private var editableValue: String
  @FocusState private var isEditing: Bool

  init(item: HistoryItem, history: History) {
    self.item = item
    self.history = history
    self._editableValue = State(initialValue: item.previewableText)
  }

  private var isRichText: Bool { item.rtfData != nil || item.htmlData != nil }
  private var isEditable: Bool {
    !item.hasImageContent && item.fileURLs.isEmpty && (item.text != nil || isRichText)
  }

  var body: some View {
    if isEditable {
      HStack {
        TextField("", text: $editableValue)
          .focused($isEditing)
          .onSubmit { save() }
          .onChange(of: isEditing) { _, editing in if !editing { save() } }
        if isRichText && isEditing {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help(Text("RichTextEditWarning", tableName: "PinsSettings"))
        }
      }
    } else {
      Text("ContentIsNotText", tableName: "PinsSettings")
        .foregroundStyle(.secondary)
        .italic()
    }
  }

  private func save() {
    guard editableValue != item.previewableText else { return }
    let text = editableValue
    Task { await history.edit(item, text: text) }
  }
}

struct PinsSettingsPane: View {
  @Environment(AppState.self) private var appState
  @State private var selection: PersistentIdentifier?
  private var items: [HistoryItem] { appState.history.all.filter(\.isPinned).map(\.item) }

  var body: some View {
    VStack(alignment: .leading) {
      Table(items, selection: $selection) {
        TableColumn(Text("Key", tableName: "PinsSettings")) { item in
          PinPickerView(item: item, history: appState.history)
        }
        .width(60)
        TableColumn(Text("Alias", tableName: "PinsSettings")) { item in
          PinTitleView(item: item, history: appState.history)
        }
        TableColumn(Text("Content", tableName: "PinsSettings")) { item in
          PinValueView(item: item, history: appState.history)
        }
      }
      .onDeleteCommand {
        guard let selection,
              let item = appState.history.all.first(where: { $0.item.id == selection }) else { return }
        appState.history.delete(item)
      }
      if let error = appState.history.errorMessage {
        Text(error).foregroundStyle(.red)
      }
      Text("PinCustomizationDescription", tableName: "PinsSettings")
        .foregroundStyle(.secondary)
        .controlSize(.small)
    }
    .frame(minWidth: 500, minHeight: 400)
    .padding()
  }
}
