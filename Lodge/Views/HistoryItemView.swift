import Defaults
import SwiftUI

struct HistoryItemView: View {
  @Bindable var item: HistoryItemDecorator

  @Default(.popupFontSize) private var fontSize
  @Default(.showApplicationIcons) private var showIcons
  @Environment(AppState.self) private var appState

  private var displayTitle: String { item.imageSizeDescription ?? item.title }

  var body: some View {
    HStack(spacing: 8) {
      if showIcons {
        Image(nsImage: item.applicationImage.nsImage)
          .resizable()
          .frame(width: 16, height: 16)
          .accessibilityHidden(true)
      }
      if let color = ColorImage.from(displayTitle) {
        Image(nsImage: color)
          .accessibilityHidden(true)
      }
      Text(item.hasImage ? AttributedString(displayTitle) : item.attributedTitle ?? AttributedString(displayTitle))
        .font(.system(size: CGFloat(fontSize), weight: item.isSelected ? .semibold : .regular))
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityIdentifier("copy-history-item")
      Spacer(minLength: 0)
      if item.similarCount > 0 {
        Text("+\(item.similarCount)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(.quaternary, in: Capsule())
          .help("Similar copies are grouped under this item")
          .accessibilityLabel("\(item.similarCount) similar copies")
      }
      if item.isPinned {
        Image(systemName: "pin.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Pinned")
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { appState.history.select(item) }
    .onHover { hovering in
      guard hovering else { return }
      if !appState.isKeyboardNavigating {
        appState.selectWithoutScrolling(item.id)
      } else {
        appState.hoverSelectionWhileKeyboardNavigating = item.id
      }
    }
  }
}
