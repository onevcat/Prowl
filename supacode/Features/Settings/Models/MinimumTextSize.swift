/// Floor for text in the app chrome (sidebar, Active Agents panel, toolbar,
/// tab bar, and their popovers), in points — the same mechanism as Safari's
/// "Never use font sizes smaller than" setting. Styles below the floor are
/// lifted to it; styles at or above it are untouched, so body text stays at
/// the system size. macOS ignores `dynamicTypeSize`, which is why the app
/// enforces the floor itself. Terminal content is excluded — its size comes
/// from the Ghostty font settings.
enum MinimumTextSize: String, CaseIterable, Identifiable, Codable, Sendable {
  case system
  case points11 = "11"
  case points12 = "12"
  case points13 = "13"
  case points14 = "14"
  case points16 = "16"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system:
      return "System"
    default:
      return "\(rawValue) pt"
    }
  }

  /// The floor in points; nil means no floor (system sizes as-is).
  var points: Double? {
    switch self {
    case .system:
      return nil
    default:
      return Double(rawValue)
    }
  }
}
