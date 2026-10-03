import SwiftUI

private struct ResolvedKeybindingsEnvironmentKey: EnvironmentKey {
  static let defaultValue: ResolvedKeybindingMap = .appDefaults
}

extension EnvironmentValues {
  var resolvedKeybindings: ResolvedKeybindingMap {
    get { self[ResolvedKeybindingsEnvironmentKey.self] }
    set { self[ResolvedKeybindingsEnvironmentKey.self] = newValue }
  }
}
