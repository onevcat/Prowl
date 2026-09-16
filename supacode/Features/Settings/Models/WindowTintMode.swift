import Foundation

/// How Prowl tints its window chrome — the nav-panel band behind the
/// floating sidebar and the toolbar band behind the titlebar — across
/// every view mode (Normal, Shelf, Canvas).
///
/// Shelf spine tinting has its own adjacent settings: the fallback style for
/// uncolored repositories and whether spines follow per-repository colors.
///
/// Persistence: encoded as the raw `String` (case name). Cases must never
/// be renamed once shipped because user JSON references them by name.
enum WindowTintMode: String, CaseIterable, Identifiable, Codable, Sendable {
  /// No chrome tint. The nav and toolbar fall back to the neutral system
  /// chrome (the default, untinted look).
  case none
  /// Tint the chrome with the active repository's pinned color. An
  /// uncolored repo falls back to a neutral surface
  /// (near-black in dark mode / near-white in light).
  case repositoryColor
  /// Tint the chrome with a single user-chosen color, unconditionally —
  /// ignores per-repository colors entirely.
  case custom

  var id: String { rawValue }

  var title: String {
    switch self {
    case .none:
      return String(localized: "None")
    case .repositoryColor:
      return String(localized: "Repository Color")
    case .custom:
      return String(localized: "Custom Color")
    }
  }
}
