import AppKit
import SwiftUI

struct CanvasCardBackdropView: View {
  let backdrop: CanvasCardDebugStyleConfiguration.Backdrop
  let cornerRadius: CGFloat?

  var body: some View {
    content
      .opacity(backdrop.opacity)
  }

  @ViewBuilder
  private var content: some View {
    switch backdrop.style {
    case .clear:
      Color.clear
    case .bar:
      Rectangle().fill(.bar)
    case .glassRegular:
      if #available(macOS 26.0, *) {
        CanvasCardGlassEffectView(style: .regular, cornerRadius: cornerRadius)
      } else {
        visualEffectBackdrop
      }
    case .glassClear:
      if #available(macOS 26.0, *) {
        CanvasCardGlassEffectView(style: .clear, cornerRadius: cornerRadius)
      } else {
        visualEffectBackdrop
      }
    case .visualEffect:
      visualEffectBackdrop
    }
  }

  private var visualEffectBackdrop: some View {
    CanvasCardVisualEffectView(
      material: backdrop.material.nsMaterial,
      blendingMode: backdrop.blendingMode.nsBlendingMode
    )
  }
}

private struct CanvasCardVisualEffectView: NSViewRepresentable {
  let material: NSVisualEffectView.Material
  let blendingMode: NSVisualEffectView.BlendingMode

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.state = .active
    view.material = material
    view.blendingMode = blendingMode
    return view
  }

  func updateNSView(
    _ nsView: NSVisualEffectView,
    context: Context
  ) {
    nsView.state = .active
    nsView.material = material
    nsView.blendingMode = blendingMode
  }
}

@available(macOS 26.0, *)
private struct CanvasCardGlassEffectView: NSViewRepresentable {
  let style: NSGlassEffectView.Style
  let cornerRadius: CGFloat?

  func makeNSView(context: Context) -> NSGlassEffectView {
    let view = NSGlassEffectView()
    view.style = style
    view.cornerRadius = cornerRadius ?? 0
    return view
  }

  func updateNSView(
    _ nsView: NSGlassEffectView,
    context: Context
  ) {
    nsView.style = style
    nsView.cornerRadius = cornerRadius ?? 0
  }
}

private extension CanvasCardDebugStyleConfiguration.VisualEffectMaterial {
  var nsMaterial: NSVisualEffectView.Material {
    switch self {
    case .contentBackground:
      .contentBackground
    case .fullScreenUI:
      .fullScreenUI
    case .headerView:
      .headerView
    case .hudWindow:
      .hudWindow
    case .menu:
      .menu
    case .popover:
      .popover
    case .selection:
      .selection
    case .sheet:
      .sheet
    case .sidebar:
      .sidebar
    case .titlebar:
      .titlebar
    case .toolTip:
      .toolTip
    case .underPageBackground:
      .underPageBackground
    case .underWindowBackground:
      .underWindowBackground
    case .windowBackground:
      .windowBackground
    }
  }
}

private extension CanvasCardDebugStyleConfiguration.VisualEffectBlendingMode {
  var nsBlendingMode: NSVisualEffectView.BlendingMode {
    switch self {
    case .behindWindow:
      .behindWindow
    case .withinWindow:
      .withinWindow
    }
  }
}
