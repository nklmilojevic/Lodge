import SwiftUI
import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import Settings

struct GeneralSettingsPane: View {
  private let notificationsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(Bundle.main.bundleIdentifier ?? "")"
  )

  @Default(.searchMode) private var searchMode

  @State private var copyModifier = HistoryItemAction.copy.modifierFlags.description
  @State private var pasteModifier = HistoryItemAction.paste.modifierFlags.description
  @State private var pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description

  @State private var updater = SoftwareUpdater()

  var body: some View {
    Settings.Container(contentWidth: 450) {
      Settings.Section(title: "", bottomDivider: true) {
        LaunchAtLogin.Toggle {
          Text("LaunchAtLogin", tableName: "GeneralSettings")
        }
        Toggle(isOn: $updater.automaticallyChecksForUpdates) {
          Text("CheckForUpdates", tableName: "GeneralSettings")
        }
        Button(
          action: { updater.checkForUpdates() },
          label: { Text("CheckNow", tableName: "GeneralSettings") }
        )
      }

      Settings.Section(label: { Text("Open", tableName: "GeneralSettings") }) {
        KeyboardShortcuts.Recorder(for: .popup, onChange: { newShortcut in
          if newShortcut == nil {
            // No shortcut is recorded. Remove keys monitor
            AppState.shared.popup.deinitEventsMonitor()
          } else {
            // User is using shortcut. Ensure keys monitor is initialized
            AppState.shared.popup.initEventsMonitor()
          }
        })
          .help(Text("OpenTooltip", tableName: "GeneralSettings"))
      }

      Settings.Section(label: { Text("Pin", tableName: "GeneralSettings") }) {
        KeyboardShortcuts.Recorder(for: .pin)
          .help(Text("PinTooltip", tableName: "GeneralSettings"))
      }
      Settings.Section(
        bottomDivider: true,
        label: { Text("Delete", tableName: "GeneralSettings") }
      ) {
        KeyboardShortcuts.Recorder(for: .delete)
          .help(Text("DeleteTooltip", tableName: "GeneralSettings"))
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("Search", tableName: "GeneralSettings") }
      ) {
        Picker("", selection: $searchMode) {
          ForEach(Search.Mode.allCases) { mode in
            Text(mode.description)
          }
        }
        .labelsHidden()
        .frame(width: 180, alignment: .leading)
        if searchMode == .ask {
          Text(askDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("Meaning:") }
      ) {
        SemanticSearchSettings()
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("Behavior", tableName: "GeneralSettings") }
      ) {
        Defaults.Toggle(key: .pasteByDefault) {
          Text("PasteAutomatically", tableName: "GeneralSettings")
        }
        .onChange(refreshModifiers)
        .fixedSize()

        Defaults.Toggle(key: .removeFormattingByDefault) {
          Text("PasteWithoutFormatting", tableName: "GeneralSettings")
        }
        .onChange(refreshModifiers)
        .fixedSize()

        Text(String(
          format: NSLocalizedString("Modifiers", tableName: "GeneralSettings", comment: ""),
          copyModifier, pasteModifier, pasteWithoutFormatting
        ))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
      }

      Settings.Section(title: "") {
        if let notificationsURL = notificationsURL {
          Link(destination: notificationsURL, label: {
            Text("NotificationsAndSounds", tableName: "GeneralSettings")
          })
        }
      }

      Settings.Section(title: "") {
        Text("Lodge \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
          .foregroundStyle(.secondary)
          .font(.caption)
      }
    }
  }

  private var askDescription: String {
    guard let message = AskSearch.availabilityMessage else {
      return "Type a request, then press Return. Ask runs on this Mac."
    }
    guard SemanticModelStore.shared.capability != .none else { return message }
    return "Ask searches by meaning. App, date, and website filters require Apple Intelligence."
  }

  private func refreshModifiers(_ sender: Sendable) {
    copyModifier = HistoryItemAction.copy.modifierFlags.description
    pasteModifier = HistoryItemAction.paste.modifierFlags.description
    pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description
  }
}

/// Downloads and removes the EmbeddingGemma 2 model and shows indexing progress.
private struct SemanticSearchSettings: View {
  @State private var store = SemanticModelStore.shared
  @Default(.groupSimilarItems) private var groupSimilarItems

  private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !SemanticModelStore.isSupported {
        caption("Semantic search requires macOS 15 or later on a Mac with Apple silicon.")
      } else {
        caption("Find items by meaning with EmbeddingGemma 2. The model runs on this Mac and sends nothing anywhere.")
        status
        if !store.isBusy { actions }
        Toggle("Group similar copies", isOn: $groupSimilarItems)
          .disabled(!store.textInstalled)
        caption("Ask ranks results by meaning. The preview lists similar versions.")
      }
    }
  }

  @ViewBuilder private var status: some View {
    switch store.phase {
    case .downloading(let fraction):
      HStack {
        ProgressView(value: fraction).frame(width: 180)
        Button("Cancel") { store.cancel() }
      }
    case .verifying:
      HStack {
        ProgressView().controlSize(.small)
        caption("Verifying the download…")
      }
    case .failed(let message):
      Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
    case .idle:
      EmptyView()
    }
  }

  @ViewBuilder private var actions: some View {
    let text = SemanticModelFiles.textBytes, media = SemanticModelFiles.imageBytes
    if !store.textInstalled {
      HStack {
        Button("Download (\(size(text)))") { store.install(images: false) }
        Button("Download with images (\(size(text + media)))") { store.install(images: true) }
      }
    } else {
      HStack {
        if store.imagesInstalled {
          Button("Remove image search") { store.remove(imagesOnly: true) }
        } else {
          Button("Add image search (\(size(media)))") { store.install(images: true) }
        }
        Button("Remove model") { store.remove(imagesOnly: false) }
      }
      let progress = AppState.shared.history.semanticProgress
      caption("\(progress.indexed) of \(progress.total) items indexed."
              + (progress.unreadable > 0 ? " \(progress.unreadable) could not be read." : ""))
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

#Preview {
  GeneralSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
