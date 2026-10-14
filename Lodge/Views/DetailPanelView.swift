import AppKit
import SwiftUI

struct DetailPanelView: View {
  @Environment(AppState.self) private var appState

  private var selectedItem: HistoryItemDecorator? {
    appState.history.selectedItem
  }

  var body: some View {
    // Use Group to keep view structure stable and avoid full teardown/rebuild
    Group {
      if let item = selectedItem {
        DetailPanelContentView(item: item)
      } else {
        VStack {
          Spacer()
          Text("detail_panel_no_item")
            .foregroundStyle(.secondary)
          Spacer()
        }
        .frame(maxWidth: .infinity)
      }
    }
  }
}

/// Separate view for the content to isolate re-renders
struct DetailPanelContentView: View {
  var item: HistoryItemDecorator

  var body: some View {
    VStack(spacing: 0) {
      // Preview section with its own scrolling
      PreviewContentView(item: item)
        .padding()

      SimilarItemsView(item: item)

      Divider()

      // Fixed metadata section at bottom
      MetadataSectionView(item: item)
        .padding()
    }
    .task(id: item.id) { item.ensurePreviewImage() }
    .onDisappear { item.cleanupImages() }
  }
}

struct PreviewContentView: View {
  var item: HistoryItemDecorator
  @State private var showFullText = false

  var body: some View {
    if item.hasImage {
      // Render the downsampled preview. Using item.item.image here decoded the
      // image at full resolution on the main thread and kept it resident.
      if let image = item.previewImage {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .clipShape(.rect(cornerRadius: 5))
      } else if item.previewFailed {
        Text("Image preview is not available.").foregroundStyle(.secondary)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 100)
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        SelectableText(text: item.text)
          .frame(maxWidth: .infinity, alignment: .leading)
        if item.isTextTruncated {
          HStack {
            Text("The preview shows the first 5,000 characters.")
              .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("View full text") { showFullText = true }
          }
        }
      }
      .sheet(isPresented: $showFullText) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Full text").font(.headline)
          SelectableText(text: item.fullText)
          HStack {
            Spacer()
            Button("Close") { showFullText = false }.keyboardShortcut(.cancelAction)
          }
        }
        .padding()
        .frame(minWidth: 600, idealWidth: 700, minHeight: 400, idealHeight: 500)
      }
    }
  }
}

/// NSTextView wrapper for efficient text rendering with full selection support
struct SelectableText: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    let textView = scrollView.documentView as! NSTextView

    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    textView.textColor = NSColor.labelColor
    textView.textContainerInset = NSSize(width: 0, height: 4)
    textView.textContainer?.lineFragmentPadding = 0

    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let textView = scrollView.documentView as! NSTextView
    if textView.string != text {
      textView.string = text
    }
  }
}

/// Near-duplicates and related items found by semantic search.
struct SimilarItemsView: View {
  var item: HistoryItemDecorator
  @Environment(AppState.self) private var appState

  var body: some View {
    let neighbors = appState.history.neighbors(of: item)
    if !neighbors.versions.isEmpty || !neighbors.related.isEmpty {
      Divider()
      VStack(alignment: .leading, spacing: 4) {
        if !neighbors.versions.isEmpty {
          Text("Similar versions").font(.headline)
          ForEach(neighbors.versions.prefix(5)) { row($0) }
        }
        if !neighbors.related.isEmpty {
          Text("Related").font(.headline)
            .padding(.top, neighbors.versions.isEmpty ? 0 : 6)
          ForEach(neighbors.related) { row($0) }
        }
      }
      .controlSize(.small)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
    }
  }

  private func row(_ other: HistoryItemDecorator) -> some View {
    let visible = appState.history.item(withId: other.id) != nil
    return Button {
      if visible { appState.selection = other.id } else { appState.history.select(other) }
    } label: {
      HStack(spacing: 6) {
        Image(nsImage: other.applicationImage.nsImage)
          .resizable()
          .frame(width: 14, height: 14)
          .accessibilityHidden(true)
        Text(other.imageSizeDescription ?? other.title)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(visible ? "Show this item" : "Copy this item")
  }
}

struct MetadataSectionView: View {
  var item: HistoryItemDecorator

  private static let copiedDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("detail_panel_information")
        .font(.headline)
        .padding(.bottom, 4)

      // Source application
      if let application = item.application {
        MetadataRow(label: "detail_panel_source") {
          HStack(spacing: 4) {
            Image(nsImage: item.applicationImage.nsImage)
              .resizable()
              .frame(width: 14, height: 14)
            Text(application)
          }
        }
      }

      // Content type
      MetadataRow(label: "detail_panel_content_type") {
        Text(item.contentTypeDescription)
      }

      // Character count (only for text, not images)
      if !item.hasImage {
        MetadataRow(label: "detail_panel_characters") {
          Text(String(item.characterCount))
        }

        MetadataRow(label: "detail_panel_words") {
          Text(String(item.wordCount))
        }
      }

      // Timestamps
      MetadataRow(label: "detail_panel_copied") {
        Text(Self.copiedDateFormatter.string(from: item.item.lastCopiedAt))
          .fixedSize(horizontal: false, vertical: true)
      }

      if item.item.numberOfCopies > 1 {
        MetadataRow(label: "detail_panel_times_copied") {
          Text(String(item.item.numberOfCopies))
        }
      }
    }
    .controlSize(.small)
  }
}

struct MetadataRow<Content: View>: View {
  let label: LocalizedStringKey
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: 4) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(width: 100, alignment: .trailing)
      content()
      Spacer()
    }
  }
}
