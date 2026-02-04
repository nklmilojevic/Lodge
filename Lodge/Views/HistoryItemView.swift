import Defaults
import SwiftUI

struct HistoryItemView: View {
  @Bindable var item: HistoryItemDecorator

  @Default(.popupFontSize) private var fontSize
  @Environment(AppState.self) private var appState

  private var displayTitle: String {
    if let imageSize = item.imageSizeDescription {
      return imageSize
    }
    return item.title
  }

  var body: some View {
    ListItemView(
      id: item.id,
      appIcon: item.applicationImage,
      image: nil,
      accessoryImage: ColorImage.from(displayTitle),
      attributedTitle: item.hasImage ? nil : item.attributedTitle,
      fontSize: CGFloat(fontSize),
      shortcuts: item.shortcuts,
      isSelected: item.isSelected
    ) {
      Text(verbatim: displayTitle)
    }
    .onTapGesture {
      appState.history.select(item)
    }
  }
}
