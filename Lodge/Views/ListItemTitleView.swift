import SwiftUI

struct ListItemTitleView<Title: View>: View {
  var attributedTitle: AttributedString?
  var fontSize: CGFloat?
  @ViewBuilder var title: () -> Title

  var body: some View {
    if let attributedTitle {
      Text(attributedTitle)
        .font(fontSize.map { .system(size: $0) })
        .accessibilityIdentifier("copy-history-item")
        .lineLimit(1)
        .truncationMode(.middle)
    } else {
      // Apply drawingGroup workaround only on macOS 26+ where the bug exists
      // to avoid GPU/memory overhead on earlier versions
      // https://github.com/nklmilojevic/Lodge/issues/1113
      if #available(macOS 26.0, *) {
        title()
          .font(fontSize.map { .system(size: $0) })
          .accessibilityIdentifier("copy-history-item")
          .lineLimit(1)
          .truncationMode(.middle)
          .drawingGroup()
      } else {
        title()
          .font(fontSize.map { .system(size: $0) })
          .accessibilityIdentifier("copy-history-item")
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
  }
}
