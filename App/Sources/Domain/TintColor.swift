import AppKit
import SwiftUI

/// A persistable sRGB color value used for the user's custom window tint.
///
/// SwiftUI's `Color` is not `Codable`, so the custom tint is stored as
/// three sRGB components (opacity is intentionally dropped — the chrome
/// band applies its own fixed alpha, so a user-chosen alpha would have no
/// meaning). The project's "system colors only" rule is deliberately
/// relaxed here: the custom tint is an explicit, user-driven free color
/// choice, unlike the closed `RepositoryColorChoice` palette.
nonisolated struct TintColor: Codable, Equatable, Hashable, Sendable {
  var red: Double
  var green: Double
  var blue: Double

  init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  /// Resolves an arbitrary SwiftUI `Color` to sRGB components. Falls back
  /// to a mid-gray if the color cannot be expressed in sRGB (e.g. a
  /// pattern color), which never happens for `ColorPicker` output.
  init(_ color: Color) {
    let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.gray.usingColorSpace(.sRGB)
    red = Double(resolved?.redComponent ?? 0.5)
    green = Double(resolved?.greenComponent ?? 0.5)
    blue = Double(resolved?.blueComponent ?? 0.5)
  }

  var color: Color {
    Color(.sRGB, red: red, green: green, blue: blue)
  }

  /// Default custom tint shown before the user picks their own — a calm
  /// blue that reads well as a low-alpha chrome band in both appearances.
  static let `default` = TintColor(.blue)
}
