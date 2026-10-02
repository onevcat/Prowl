import SwiftUI

private let terminalHostLogger = SupaLogger("TerminalHost")

struct GhosttyTerminalView: NSViewRepresentable {
  let surfaceView: GhosttySurfaceView
  var pinnedSize: CGSize?

  private var hostKind: GhosttySurfaceScrollView.HostKind {
    pinnedSize == nil ? .terminal : .canvas
  }

  func makeNSView(context: Context) -> GhosttySurfaceScrollView {
    // Wrap in a signpost interval so the cost of NSView construction
    // (allocating the scroll view, attaching the Metal-backed surface)
    // shows up on the Points of Interest timeline. Frequency tells us
    // how often `.id(worktree.id)` on `ShelfOpenBookView` is forcing a
    // wholesale teardown/recreate on book switching — total time tells
    // us if AppKit/Metal initialization is on the hot path.
    return terminalHostLogger.interval("Ghostty.makeNSView") {
      let view = GhosttySurfaceScrollView(surfaceView: surfaceView, hostKind: hostKind)
      view.pinnedSize = pinnedSize
      return view
    }
  }

  func updateNSView(_ view: GhosttySurfaceScrollView, context: Context) {
    terminalHostLogger.interval("Ghostty.updateNSView") {
      view.pinnedSize = pinnedSize
      view.ensureSurfaceAttached()
    }
  }

  static func dismantleNSView(_ view: GhosttySurfaceScrollView, coordinator: Void) {
    // Pairs with `Ghostty.makeNSView` on the timeline so the interval
    // count of `make` minus `dismantle` gives a live count of attached
    // surface wrappers — and frequency confirms whether each book
    // switch tears down the wrapper layer.
    terminalHostLogger.event("Ghostty.dismantleNSView")
  }
}
