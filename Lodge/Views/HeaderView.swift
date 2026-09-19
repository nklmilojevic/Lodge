import Defaults
import SwiftUI

struct HeaderView: View {
  @FocusState.Binding var searchFocused: Bool
  @Binding var searchQuery: String

  @Environment(AppState.self) private var appState
  @Environment(\.scenePhase) private var scenePhase

  @Default(.searchMode) private var searchMode

  @Default(.showTitle) private var showTitle

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        if showTitle {
          Text("Lodge")
            .foregroundStyle(.secondary)
        }

        SearchFieldView(placeholder: searchMode == .ask ? "Ask about your clipboard…" : "search_placeholder",
                        query: $searchQuery, searchFocused: $searchFocused)
          .frame(maxWidth: .infinity)
          .onChange(of: scenePhase) {
            if scenePhase == .background && !searchQuery.isEmpty {
              searchQuery = ""
            }
          }
          // Only reliable way to disable the cursor. allowsHitTesting() does not work
          .offset(y: appState.searchVisible ? 0 : -Popup.itemHeight)
        Menu {
          Picker("Search mode", selection: $searchMode) {
            ForEach(Search.Mode.allCases) { mode in
              Text(mode.description).tag(mode)
            }
          }
        } label: {
          Image(systemName: searchMode == .ask ? "sparkles" : "magnifyingglass")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Search mode")
        .accessibilityLabel("Search mode")
      }
      if searchMode == .ask {
        HStack(spacing: 6) {
          if appState.history.isSearching {
            ProgressView().controlSize(.mini)
          }
          Text(appState.history.askSearchMessage ?? AskSearch.availabilityMessage ?? "Press Return to search on this Mac.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
    .frame(height: appState.searchVisible ? (searchMode == .ask ? 54 : 28) : 0)
    .opacity(appState.searchVisible ? 1 : 0)
    .padding(.horizontal, 12)
    .padding(.vertical, appState.searchVisible ? 12 : 0)
    .clipped()
    .background {
      GeometryReader { geo in
        Color.clear
          .task(id: geo.size.height) {
            appState.popup.headerHeight = geo.size.height
          }
      }
    }
  }
}
