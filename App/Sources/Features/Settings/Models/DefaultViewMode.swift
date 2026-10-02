import Foundation

/// Which presentation the app enters on launch. `normal` keeps the
/// historical behavior (sidebar + terminal detail); `shelf` boots
/// straight into Shelf and `canvas` boots straight into Canvas, so
/// power users who live in those views don't have to toggle them
/// every time they open Prowl.
enum DefaultViewMode: String, CaseIterable, Identifiable, Codable, Sendable {
  case normal
  case shelf
  case canvas

  var id: String { rawValue }

  var title: String {
    switch self {
    case .normal:
      return String(localized: "Normal View")
    case .shelf:
      return String(localized: "Shelf View")
    case .canvas:
      return String(localized: "Canvas View")
    }
  }
}
