import SwiftUI

struct SearchFieldView: NSViewRepresentable {
  var placeholder: String
  @Binding var query: String
  @FocusState.Binding var searchFocused: Bool
  @Environment(AppState.self) private var appState

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> HistorySearchField {
    let field = HistorySearchField()
    field.placeholderString = NSLocalizedString(placeholder, comment: "")
    field.sendsSearchStringImmediately = true
    field.sendsWholeSearchString = false
    field.delegate = context.coordinator
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.onKeyEvent = { [weak coordinator = context.coordinator] event in
      coordinator?.handle(event) ?? false
    }
    field.onAttach = { [weak coordinator = context.coordinator, weak field] in
      guard let field else { return }
      coordinator?.updateFocus(field)
    }
    return field
  }

  func updateNSView(_ field: HistorySearchField, context: Context) {
    context.coordinator.parent = self
    field.placeholderString = NSLocalizedString(placeholder, comment: "")
    if field.stringValue != query, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
      field.stringValue = query
    }
    context.coordinator.updateFocus(field)
  }

  @MainActor
  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: SearchFieldView
    init(_ parent: SearchFieldView) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      parent.query = field.stringValue
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
      parent.searchFocused = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      parent.searchFocused = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard !textView.hasMarkedText(), let event = NSApp.currentEvent else { return false }
      return handle(event)
    }

    func handle(_ event: NSEvent) -> Bool {
      HistoryKeyHandler(appState: parent.appState, searchQuery: parent.$query) {
        self.parent.searchFocused = true
      }.handle(event)
    }

    func updateFocus(_ field: NSSearchField) {
      guard parent.searchFocused, let window = field.window, window.isKeyWindow,
            field.currentEditor() !== window.firstResponder else { return }
      DispatchQueue.main.async { [weak self, weak field] in
        guard let self, self.parent.searchFocused, let field,
              let window = field.window, window.isKeyWindow else { return }
        window.makeFirstResponder(field)
      }
    }
  }
}

final class HistorySearchField: NSSearchField {
  var onKeyEvent: ((NSEvent) -> Bool)?
  var onAttach: (() -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onAttach?()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if let editor = currentEditor() as? NSTextView, window?.firstResponder === editor,
       !editor.hasMarkedText(), onKeyEvent?(event) == true {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
