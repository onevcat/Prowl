import Foundation

/// How cards are first laid out when Canvas is opened for a fresh set of cards.
/// `uniform` opens every card at one comfortable size, packed to fit (the
/// historical behavior); `tile` resizes cards to tile and fill the viewport
/// (matching the Tile toolbar action), which adapts better as the card count
/// grows. Only the initial auto-layout is affected — once cards have saved
/// positions, Canvas restores them regardless of this setting.
enum CanvasDefaultLayout: String, CaseIterable, Identifiable, Codable, Sendable {
  case uniform
  case tile

  var id: String { rawValue }

  var title: String {
    switch self {
    case .uniform:
      return String(localized: "Uniform")
    case .tile:
      return String(localized: "Tile")
    }
  }

  /// One-line description shown under the Settings picker, following the
  /// current selection.
  var settingsDescription: String {
    switch self {
    case .uniform:
      return String(localized: "Cards open at the same size.")
    case .tile:
      return String(localized: "Cards resize to fill the screen, smaller as you add more.")
    }
  }
}
