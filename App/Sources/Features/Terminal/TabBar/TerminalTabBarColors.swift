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
  private nonisolated static func adaptiveFill(
    dark: @escaping @MainActor () -> NSColor,
    light: @escaping @MainActor () -> NSColor
  ) -> Color {
    let resolver = TerminalTabBarAdaptiveFillResolver(dark: dark, light: light)
    return Color(
      nsColor: NSColor(name: nil) { appearance in
        resolver.resolve(for: appearance)
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

// `NSAppearance` is read-only here and lives only through the synchronous main-queue handoff.
private nonisolated struct TerminalTabBarAppearanceBox: @unchecked Sendable {
  let appearance: NSAppearance
}

// The stored closures are immutable and invoked only from `resolvedColor(for:)` on the main actor.
private nonisolated final class TerminalTabBarAdaptiveFillResolver: @unchecked Sendable {
  private let dark: @MainActor () -> NSColor
  private let light: @MainActor () -> NSColor

  init(
    dark: @escaping @MainActor () -> NSColor,
    light: @escaping @MainActor () -> NSColor
  ) {
    self.dark = dark
    self.light = light
  }

  func resolve(for appearance: NSAppearance) -> NSColor {
    let appearanceBox = TerminalTabBarAppearanceBox(appearance: appearance)
    if Thread.isMainThread {
      return MainActor.assumeIsolated {
        resolvedColor(for: appearanceBox.appearance)
      }
    }
    return DispatchQueue.main.sync {
      MainActor.assumeIsolated {
        resolvedColor(for: appearanceBox.appearance)
      }
    }
  }

  @MainActor
  private func resolvedColor(for appearance: NSAppearance) -> NSColor {
    var color: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      color = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark() : light()
    }
    guard let color else {
      preconditionFailure("NSAppearance did not resolve a terminal tab bar color")
    }
    return color
  }
}
