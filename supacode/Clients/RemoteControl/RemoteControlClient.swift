import ComposableArchitecture

struct RemoteControlClient {
  var setEnabled: @MainActor @Sendable (Bool) -> Bool
}

extension RemoteControlClient: DependencyKey {
  static let liveValue = RemoteControlClient(setEnabled: { _ in false })
  static let testValue = RemoteControlClient(setEnabled: { _ in true })
}

extension DependencyValues {
  var remoteControlClient: RemoteControlClient {
    get { self[RemoteControlClient.self] }
    set { self[RemoteControlClient.self] = newValue }
  }
}
