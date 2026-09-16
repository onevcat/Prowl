import Foundation
import SwiftUI

/// A color a user can pin to a repository to make it identifiable in the
/// sidebar, shelf spine, and canvas card title bar — and, with window
/// tinting enabled, to tint the nav / toolbar chrome.
///
/// Either one of a fixed palette of system-provided colors (aligned with
/// macOS Finder's tag colors) or a free `.custom` color the user picks from
/// a color wheel. The named presets stay purely semantic system colors so
/// they adapt to light/dark mode; `.custom` is an explicit, user-driven
/// opt-out of that constraint (mirroring the window tint's custom color).
///
/// Persistence: a preset encodes as its bare case-name `String` — identical
/// to the legacy `String`-rawValue representation, so existing user JSON
/// keeps decoding unchanged. `.custom` encodes as a keyed object so it is
/// visually distinct in the file and never collides with a preset name.
nonisolated enum RepositoryColorChoice: Codable, Sendable, Hashable {
  case red
  case orange
  case yellow
  case green
  case mint
  case cyan
  case blue
  case purple
  case pink
  case gray
  case custom(TintColor)

  /// The named presets, in palette order. Excludes `.custom` (which carries
  /// an associated value and is surfaced through its own picker affordance).
  static let presets: [RepositoryColorChoice] = [
    .red, .orange, .yellow, .green, .mint, .cyan, .blue, .purple, .pink, .gray,
  ]

  /// User-facing label for the color picker.
  var displayName: String {
    switch self {
    case .red: String(localized: "Red")
    case .orange: String(localized: "Orange")
    case .yellow: String(localized: "Yellow")
    case .green: String(localized: "Green")
    case .mint: String(localized: "Mint")
    case .cyan: String(localized: "Cyan")
    case .blue: String(localized: "Blue")
    case .purple: String(localized: "Purple")
    case .pink: String(localized: "Pink")
    case .gray: String(localized: "Gray")
    case .custom: String(localized: "Custom")
    }
  }

  /// Resolved SwiftUI color. Presets use the bare named system colors (never
  /// custom RGB) so they adapt to light/dark mode; `.custom` resolves its
  /// stored sRGB components.
  var color: Color {
    switch self {
    case .red: .red
    case .orange: .orange
    case .yellow: .yellow
    case .green: .green
    case .mint: .mint
    case .cyan: .cyan
    case .blue: .blue
    case .purple: .purple
    case .pink: .pink
    case .gray: .gray
    case .custom(let tint): tint.color
    }
  }

  // MARK: - Codable

  /// Stable identifier for a preset — the legacy `String` raw value. `nil`
  /// for `.custom`.
  private var presetIdentifier: String? {
    switch self {
    case .red: "red"
    case .orange: "orange"
    case .yellow: "yellow"
    case .green: "green"
    case .mint: "mint"
    case .cyan: "cyan"
    case .blue: "blue"
    case .purple: "purple"
    case .pink: "pink"
    case .gray: "gray"
    case .custom: nil
    }
  }

  private init?(presetIdentifier: String) {
    switch presetIdentifier {
    case "red": self = .red
    case "orange": self = .orange
    case "yellow": self = .yellow
    case "green": self = .green
    case "mint": self = .mint
    case "cyan": self = .cyan
    case "blue": self = .blue
    case "purple": self = .purple
    case "pink": self = .pink
    case "gray": self = .gray
    default: return nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case custom
  }

  init(from decoder: any Decoder) throws {
    // Preset / legacy form: a bare case-name string.
    if let single = try? decoder.singleValueContainer(),
      let name = try? single.decode(String.self),
      let preset = Self(presetIdentifier: name)
    {
      self = preset
      return
    }
    // Custom form: { "custom": <TintColor> }.
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self = .custom(try container.decode(TintColor.self, forKey: .custom))
  }

  func encode(to encoder: any Encoder) throws {
    if let presetIdentifier {
      var container = encoder.singleValueContainer()
      try container.encode(presetIdentifier)
    } else if case .custom(let tint) = self {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(tint, forKey: .custom)
    }
  }
}
