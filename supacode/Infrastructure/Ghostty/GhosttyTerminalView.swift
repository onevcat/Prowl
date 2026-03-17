import SwiftUI

struct GhosttyTerminalView: NSViewRepresentable {
  let surfaceView: GhosttySurfaceView
  var pinnedSize: CGSize?

  func makeNSView(context: Context) -> GhosttySurfaceScrollView {
    let view = GhosttySurfaceScrollView(surfaceView: surfaceView)
    view.pinnedSize = pinnedSize
    return view
  }

  func updateNSView(_ view: GhosttySurfaceScrollView, context: Context) {
    view.pinnedSize = pinnedSize
  }
}
