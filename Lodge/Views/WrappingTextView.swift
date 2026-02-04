import SwiftUI

// A text view that properly wraps single-line content without extra horizontal or vertical spaces.
// https://www.reddit.com/r/SwiftUI/comments/1gx1w6v/how_to_wrap_a_text_inside_a_macos_popover/
struct WrappingTextView: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let text = subviews.first else {
      return .zero
    }

    let maxHeight = NSScreen.main?.visibleFrame.height ?? 1000
    let textSize = text.sizeThatFits(.unspecified)

    // Use proposed width if available, otherwise fall back to text's natural width
    let availableWidth = proposal.width ?? textSize.width

    let width: CGFloat
    let height: CGFloat

    if textSize.width > availableWidth {
      // Text needs to wrap to fit within available width
      width = availableWidth
      let scaledSize = text.sizeThatFits(.init(width: availableWidth, height: nil))
      height = min(scaledSize.height, maxHeight)
    } else {
      width = textSize.width
      height = min(textSize.height, maxHeight)
    }

    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    guard let text = subviews.first else {
      return
    }

    let maxHeight = NSScreen.main?.visibleFrame.height ?? 1000
    let textSize = text.sizeThatFits(.unspecified)

    // Apply the same width-based scaling logic
    let scaledSize = textSize.width > bounds.width
      ? text.sizeThatFits(.init(width: bounds.width, height: nil))
      : textSize

    let needsScrolling = scaledSize.height > maxHeight

    text.place(
      at: bounds.origin,
      proposal: ProposedViewSize(
        width: bounds.width,
        height: needsScrolling ? scaledSize.height : bounds.height
      )
    )
  }
}
