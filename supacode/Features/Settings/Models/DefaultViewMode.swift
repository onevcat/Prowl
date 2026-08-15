/// Which runtime or presentation the app enters on launch.
internal enum DefaultViewMode: String, CaseIterable, Identifiable, Codable, Sendable {
  case normal
  case shelf
  case canvas
  case clean

  internal var id: String { rawValue }

  internal var title: String {
    switch self {
    case .normal:
      return "Normal View"
    case .shelf:
      return "Shelf View"
    case .canvas:
      return "Canvas View"
    case .clean:
      return "Clean Mode"
    }
  }
}
