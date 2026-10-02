import ComposableArchitecture

struct CustomShortcutRegistryClient {
  var setShortcuts: @MainActor @Sendable ([UserCustomShortcut]) -> Void
}

extension CustomShortcutRegistryClient: DependencyKey {
  static let liveValue = Self(
    setShortcuts: { shortcuts in
      UserCustomShortcutRegistry.shared.setShortcuts(shortcuts)
    }
  )

  static let testValue = Self(
    setShortcuts: { _ in }
  )
}

extension DependencyValues {
  var customShortcutRegistryClient: CustomShortcutRegistryClient {
    get { self[CustomShortcutRegistryClient.self] }
    set { self[CustomShortcutRegistryClient.self] = newValue }
  }
}
