import SwiftUI

extension View {
  @ViewBuilder
  func popupCorners(minimumRadius: CGFloat) -> some View {
    if #available(macOS 26.0, *) {
      clipShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(minimumRadius))))
    } else {
      clipShape(.rect(cornerRadius: minimumRadius))
    }
  }
}

struct VisualEffectView: NSViewRepresentable {
  let visualEffectView = NSVisualEffectView()

  var material: NSVisualEffectView.Material = .popover
  var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

  func makeNSView(context: Context) -> NSVisualEffectView {
    return visualEffectView
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    visualEffectView.material = material
    visualEffectView.blendingMode = blendingMode
  }
}

@available(macOS 26.0, *)
struct GlassEffectView: NSViewRepresentable {
  let glassEffectView = NSGlassEffectView()

  var style: NSGlassEffectView.Style = .regular

  func makeNSView(context: Context) -> NSGlassEffectView {
    return glassEffectView
  }

  func updateNSView(_ view: NSGlassEffectView, context: Context) {
    glassEffectView.style = style
  }
}

#Preview {
  VisualEffectView(
    material: .popover,
    blendingMode: .behindWindow
  )
}
