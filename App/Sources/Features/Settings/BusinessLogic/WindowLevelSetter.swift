import AppKit
import SwiftUI

struct WindowLevelSetter: NSViewRepresentable {
  let level: NSWindow.Level

  func makeNSView(context: Context) -> WindowLevelView {
    let view = WindowLevelView()
    view.level = level
    return view
  }

  func updateNSView(_ nsView: WindowLevelView, context: Context) {
    nsView.level = level
  }
}

final class WindowLevelView: NSView {
  var level: NSWindow.Level = .normal {
    didSet {
      window?.level = level
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.level = level
  }
}
