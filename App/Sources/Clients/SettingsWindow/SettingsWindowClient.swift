import ComposableArchitecture

struct SettingsWindowClient {
  var show: @MainActor @Sendable () -> Void
}

extension SettingsWindowClient: DependencyKey {
  static let liveValue = SettingsWindowClient {
    _ = SettingsWindowOpener.shared.openSettingsWindow()
  }

  static let testValue = SettingsWindowClient {}
}

extension DependencyValues {
  var settingsWindowClient: SettingsWindowClient {
    get { self[SettingsWindowClient.self] }
    set { self[SettingsWindowClient.self] = newValue }
  }
}
