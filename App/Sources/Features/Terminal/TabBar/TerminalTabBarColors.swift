import AppKit
import SwiftUI

enum TerminalTabBarColors {
  static var barBackground: Color {
    adaptiveFill(dark: { .labelColor.withAlphaComponent(0.10) }, light: { .labelColor.withAlphaComponent(0.08) })
  }

  // Selection is conveyed by a brightness ladder layered over `barBackground`,
  // but only in dark mode. There, `controlBackgroundColor` is actually *darker*
  // than `windowBackgroundColor`, so the old selection sank into the bar; a
  // `labelColor` (≈ `Color.primary`) tint brightens reliably instead, keeping
  // bar < inactive < hovered < active distinct. In light mode that same tint
  // would *darken* the tab and read unnaturally, so we keep the original system
  // appearance: a white tab floating on the gray bar.
  static var activeTabBackground: Color {
    adaptiveFill(dark: { .labelColor.withAlphaComponent(0.25) }, light: { .controlBackgroundColor })
  }

  static var hoveredTabBackground: Color {
    adaptiveFill(
      dark: { .labelColor.withAlphaComponent(0.08) },
      light: { .controlBackgroundColor.withAlphaComponent(0.5) }
    )
  }

  static var inactiveTabBackground: Color {
    .clear
  }

  /// Resolves to `dark` under Dark Aqua and `light` otherwise, wrapped in a
  /// dynamic `NSColor` so callers stay appearance-agnostic.
  ///
  /// SwiftUI's async renderer calls the provider on its display-link thread
  /// while it holds the view graph lock, so the provider must resolve on the
  /// calling thread: waiting for the main thread there deadlocks whenever the
  /// main thread is itself waiting for that lock.
  private nonisolated static func adaptiveFill(
    dark: @escaping @Sendable () -> NSColor,
    light: @escaping @Sendable () -> NSColor
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        // Build the fill under the provider's appearance: `withAlphaComponent`
        // freezes a dynamic system color at the appearance current when it runs.
        var color: NSColor?
        appearance.performAsCurrentDrawingAppearance {
          color = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark() : light()
        }
        guard let color else {
          preconditionFailure("NSAppearance did not resolve a terminal tab bar color")
        }
        return color
      }
    )
  }

  static var activeText: Color {
    Color(nsColor: .labelColor)
  }

  static var inactiveText: Color {
    Color(nsColor: .secondaryLabelColor)
  }

  static var separator: Color {
    Color(nsColor: .separatorColor)
  }

  static var dropIndicator: Color {
    Color.accentColor
  }

  static var dirtyIndicator: Color {
    Color(nsColor: .labelColor).opacity(0.6)
  }
}
