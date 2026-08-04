/// Discrete scale steps for text in the app chrome: sidebar, Active Agents
/// panel, toolbar, tab bar, and their popovers. macOS ignores
/// `dynamicTypeSize`, so the app scales chrome text itself; discrete steps
/// keep row layouts predictable across the supported range. Terminal
/// content is excluded — its size comes from the Ghostty font settings.
enum InterfaceTextSize: String, CaseIterable, Identifiable, Codable, Sendable {
  case standard
  case medium
  case large
  case extraLarge

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standard:
      return "Default"
    case .medium:
      return "Medium"
    case .large:
      return "Large"
    case .extraLarge:
      return "Extra Large"
    }
  }

  var scale: Double {
    switch self {
    case .standard:
      return 1.0
    case .medium:
      return 1.1
    case .large:
      return 1.25
    case .extraLarge:
      return 1.4
    }
  }
}
