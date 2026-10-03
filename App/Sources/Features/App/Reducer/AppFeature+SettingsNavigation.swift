import ComposableArchitecture

extension AppFeature {
  /// Resolves the destination before asking SwiftUI to surface its Settings
  /// window, so programmatic entry points never briefly show a stale section.
  func openSettingsEffect(selecting selection: SettingsSection) -> Effect<Action> {
    .concatenate(
      .send(.settings(.setSelection(selection))),
      .run { _ in
        await settingsWindowClient.show()
      }
    )
  }
}
