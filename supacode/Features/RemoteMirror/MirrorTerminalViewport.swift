import AppKit
import SwiftUI

struct MirrorTerminalViewport: NSViewRepresentable {
  let surface: GhosttySurfaceView
  let displaySize: CGSize

  func makeNSView(context: Context) -> MirrorTerminalScrollView {
    MirrorTerminalScrollView(surface: surface, displaySize: displaySize)
  }

  func updateNSView(_ view: MirrorTerminalScrollView, context: Context) {
    view.displaySize = displaySize
  }
}

final class MirrorTerminalScrollView: NSScrollView {
  private let surface: GhosttySurfaceView
  var displaySize: CGSize {
    didSet { if displaySize != oldValue { needsLayout = true } }
  }
  private var hasLaidOut = false
  private var previousVisibleHeight: CGFloat = 0

  init(surface: GhosttySurfaceView, displaySize: CGSize) {
    self.surface = surface
    self.displaySize = displaySize
    super.init(frame: .zero)
    hasHorizontalScroller = true
    hasVerticalScroller = true
    autohidesScrollers = true
    scrollerStyle = .overlay
    drawsBackground = false
    documentView = surface
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func layout() {
    // AppKit's unflipped document starts at the bottom. Keep the input edge
    // visible across resizes, but preserve an explicit scroll away from it.
    let wasAtBottom = !hasLaidOut || contentView.bounds.minY <= 1
    let oldTop = contentView.bounds.minY + previousVisibleHeight
    super.layout()
    surface.setFrameSize(displaySize)
    surface.updateSurfaceSize()
    let maxY = max(0, displaySize.height - contentSize.height)
    let offsetY = wasAtBottom ? 0 : min(maxY, max(0, oldTop - contentSize.height))
    contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: offsetY))
    reflectScrolledClipView(contentView)
    previousVisibleHeight = contentSize.height
    hasLaidOut = true
  }
}
