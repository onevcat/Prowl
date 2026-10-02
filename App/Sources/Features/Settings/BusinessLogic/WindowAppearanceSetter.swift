import AppKit
import SwiftUI

struct WindowAppearanceSetter: NSViewRepresentable {
  let colorScheme: ColorScheme?

  func makeNSView(context: Context) -> WindowAppearanceView {
    let view = WindowAppearanceView()
    view.colorScheme = colorScheme
    return view
  }

  func updateNSView(_ nsView: WindowAppearanceView, context: Context) {
    nsView.colorScheme = colorScheme
  }
}

final class WindowAppearanceView: NSView {
  var colorScheme: ColorScheme? {
    didSet {
      applyAppearance()
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyAppearance()
  }

  private func applyAppearance() {
    guard let window else {
      return
    }
    switch colorScheme {
    case .none:
      window.appearance = nil
    case .some(let scheme):
      switch scheme {
      case .light:
        window.appearance = NSAppearance(named: .aqua)
      case .dark:
        window.appearance = NSAppearance(named: .darkAqua)
      @unknown default:
        window.appearance = nil
      }
    }
  }
}
