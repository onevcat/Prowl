internal enum StandardViewMode: Equatable, Sendable {
  case normal
  case shelf
  case canvas
}

internal enum AppLaunchProfile: Equatable, Sendable {
  case standard(initialViewMode: StandardViewMode)
  case clean

  internal static func resolve(_ defaultViewMode: DefaultViewMode) -> Self {
    switch defaultViewMode {
    case .normal:
      return .standard(initialViewMode: .normal)
    case .shelf:
      return .standard(initialViewMode: .shelf)
    case .canvas:
      return .standard(initialViewMode: .canvas)
    case .clean:
      return .clean
    }
  }
}
