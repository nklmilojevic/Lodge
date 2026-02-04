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

      Divider()

      // Fixed metadata section at bottom
      MetadataSectionView(item: item)
        .padding()
    }
    .task(id: item.id) {
      // Generate preview image when item changes
      await MainActor.run {
        item.ensurePreviewImage()
      }
    }
  }
}

struct PreviewContentView: View {
  var item: HistoryItemDecorator

  var body: some View {
    if item.hasImage {
      // Use item.item.image directly - it's cached in HistoryItem
      if let image = item.item.image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .clipShape(.rect(cornerRadius: 5))
      } else {
        // Image is loading
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 100)
      }
    } else {
      SelectableText(text: item.text)
        .frame(maxWidth: .infinity, alignment: .leading)
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

struct MetadataSectionView: View {
  var item: HistoryItemDecorator

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
        Text(item.item.lastCopiedAt, style: .date)
        Text("detail_panel_at")
        Text(item.item.lastCopiedAt, style: .time)
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
