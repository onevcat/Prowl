import AppKit
import SwiftUI

enum TerminalTabBarColors {
  static var barBackground: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  // Selection is conveyed by a brightness ladder layered over `barBackground`,
  // but only in dark mode. There, `controlBackgroundColor` is actually *darker*
  // than `windowBackgroundColor`, so the old selection sank into the bar; a
  // `labelColor` (≈ `Color.primary`) tint brightens reliably instead, keeping
  // bar < inactive < hovered < active distinct. In light mode that same tint
  // would *darken* the tab and read unnaturally, so we keep the original system
  // appearance: a white tab floating on the gray bar.
  static var activeTabBackground: Color {
    adaptiveFill(dark: { .labelColor.withAlphaComponent(0.14) }, light: { .controlBackgroundColor })
  }

  static var hoveredTabBackground: Color {
    adaptiveFill(
      dark: { .labelColor.withAlphaComponent(0.08) },
      light: { .controlBackgroundColor.withAlphaComponent(0.5) }
    )
  }

  static var inactiveTabBackground: Color {
    adaptiveFill(dark: { .labelColor.withAlphaComponent(0.035) }, light: { .clear })
  }

  /// Resolves to `dark` under Dark Aqua and `light` otherwise, wrapped in a
  /// dynamic `NSColor` so callers stay appearance-agnostic.
  private static func adaptiveFill(
    dark: @escaping () -> NSColor,
    light: @escaping () -> NSColor
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark() : light()
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
