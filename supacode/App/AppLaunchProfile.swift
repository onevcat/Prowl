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

  internal var standardViewMode: StandardViewMode? {
    guard case .standard(let initialViewMode) = self else { return nil }
    return initialViewMode
  }

  internal var ghosttyRuntimeOverrideContents: String {
    switch self {
    case .standard:
      return ""
    case .clean:
      return "macos-option-as-alt = true"
    }
  }
}

internal enum AppRuntimeSelection<Standard, Clean> {
  case standard(Standard)
  case clean(Clean)
}

internal enum AppRuntimeSelector {
  @MainActor
  internal static func make<Standard, Clean>(
    profile: AppLaunchProfile,
    makeStandard: (StandardViewMode) -> Standard,
    makeClean: () -> Clean
  ) -> AppRuntimeSelection<Standard, Clean> {
    switch profile {
    case .standard(let initialViewMode):
      return .standard(makeStandard(initialViewMode))
    case .clean:
      return .clean(makeClean())
    }
  }
}
