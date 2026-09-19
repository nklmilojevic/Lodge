import Sauce
import SwiftUI

struct KeyHandlingView<Content: View>: View {
  @Binding var searchQuery: String
  @FocusState.Binding var searchFocused: Bool
  @ViewBuilder let content: () -> Content

  @Environment(AppState.self) private var appState

  var body: some View {
    content()
      .onKeyPress { _ in
        guard let event = NSApp.currentEvent else { return .ignored }
        let handler = HistoryKeyHandler(appState: appState, searchQuery: $searchQuery) {
          searchFocused = true
        }
        return handler.handle(event) ? .handled : .ignored
      }
  }
}

@MainActor
struct HistoryKeyHandler {
  let appState: AppState
  @Binding var searchQuery: String
  var focusSearch: () -> Void

  func handle(_ event: NSEvent) -> Bool {
    // Let the input method finish composing text before handling shortcuts.
    if let inputClient = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
       inputClient.hasMarkedText() {
      return false
    }

    switch KeyChord(event) {
    case .clearHistory:
      if let item = appState.footer.items.first(where: { $0.title == "clear" }),
         item.confirmation != nil,
         let suppressConfirmation = item.suppressConfirmation {
        if suppressConfirmation.wrappedValue {
          item.action()
        } else {
          item.showConfirmation = true
        }
        return true
      } else {
        return false
      }
    case .clearHistoryAll:
      if let item = appState.footer.items.first(where: { $0.title == "clear_all" }),
         item.confirmation != nil,
         let suppressConfirmation = item.suppressConfirmation {
        if suppressConfirmation.wrappedValue {
          item.action()
        } else {
          item.showConfirmation = true
        }
        return true
      } else {
        return false
      }
    case .clearSearch:
      searchQuery = ""
      return true
    case .deleteCurrentItem:
      if let item = appState.history.selectedItem {
        appState.highlightNext()
        appState.history.delete(item)
      }
      return true
    case .deleteOneCharFromSearch:
      focusSearch()
      _ = searchQuery.popLast()
      return true
    case .deleteLastWordFromSearch:
      focusSearch()
      let newQuery = searchQuery.split(separator: " ").dropLast().joined(separator: " ")
      if newQuery.isEmpty {
        searchQuery = ""
      } else {
        searchQuery = "\(newQuery) "
      }

      return true
    case .moveToNext:
      guard NSApp.characterPickerWindow == nil else {
        return false
      }

      appState.highlightNext()
      return true
    case .moveToLast:
      guard NSApp.characterPickerWindow == nil else {
        return false
      }

      appState.highlightLast()
      return true
    case .moveToPrevious:
      guard NSApp.characterPickerWindow == nil else {
        return false
      }

      appState.highlightPrevious()
      return true
    case .moveToFirst:
      guard NSApp.characterPickerWindow == nil else {
        return false
      }

      appState.highlightFirst()
      return true
    case .openPreferences:
      appState.openPreferences()
      return true
    case .pinOrUnpin:
      appState.history.togglePin(appState.history.selectedItem)
      return true
    case .selectCurrentItem:
      if appState.history.submitAskIfNeeded() { return true }
      appState.select()
      return true
    case .close:
      appState.popup.close()
      return true
    default:
      ()
    }

    if let item = appState.history.pressedShortcutItem {
      appState.selection = item.id
      Task {
        try? await Task.sleep(for: .milliseconds(50))
        appState.history.select(item)
      }
      return true
    }

    return false
  }
}
