import ComposableArchitecture

struct CustomShortcutRegistryClient {
  var setShortcuts: @MainActor @Sendable ([Keybinding]) -> Void
}

extension CustomShortcutRegistryClient: DependencyKey {
  static let liveValue = Self(
    setShortcuts: { keybindings in
      UserCustomShortcutRegistry.shared.setKeybindings(keybindings)
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
