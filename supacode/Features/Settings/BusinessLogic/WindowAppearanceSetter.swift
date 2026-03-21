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
      guard colorScheme != oldValue else { return }
      applyAppearance()
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyAppearance()
  }

  private func applyAppearance() {
    guard let window else {
      SupaLogger("Appearance").debug("applyAppearance: no window")
      return
    }
    let desiredName: NSAppearance.Name? = switch colorScheme {
    case .light: .aqua
    case .dark: .darkAqua
    default: nil
    }
    SupaLogger("Appearance").debug(
      "applyAppearance: colorScheme=\(String(describing: colorScheme)), " +
      "desired=\(desiredName?.rawValue ?? "nil"), " +
      "current=\(window.appearance?.name.rawValue ?? "nil")"
    )
    let resolvedName: NSAppearance.Name = desiredName
      ?? NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
      ?? .darkAqua
    guard window.appearance?.name != resolvedName else { return }
    window.appearance = NSAppearance(named: resolvedName)
  }
}
