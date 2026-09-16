import Foundation

/// Fallback color used by Shelf spine surfaces when a repository has no
/// pinned color, or for every spine when repository colors are ignored.
///
/// Persistence: encoded as the raw `String` (case name). Cases must never
/// be renamed once shipped because user JSON references them by name.
enum ShelfSpineTintFallback: String, CaseIterable, Identifiable, Codable, Sendable {
  /// Use the neutral primary-color surface (near-black in dark mode /
  /// near-white in light) matching the current Shelf behavior.
  case neutral
  /// Use the system accent tint for the spine surface.
  case systemTint

  var id: String { rawValue }

  var title: String {
    switch self {
    case .neutral:
      return String(localized: "Neutral")
    case .systemTint:
      return String(localized: "System Tint")
    }
  }
}
