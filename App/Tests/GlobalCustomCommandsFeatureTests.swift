import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct GlobalCustomCommandsFeatureTests {
  @Test(.dependencies) func taskLoadsPersistedGlobalSettings() async throws {
    let storage = UserGlobalSettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/prowl-global-settings-\(UUID().uuidString).json")
    let persisted = UserGlobalSettings(customCommands: [makeCommand()])
    let encoder = JSONEncoder()
    try storage.storage.save(try encoder.encode(persisted), url)

    let store = TestStore(initialState: GlobalCustomCommandsFeature.State()) {
      GlobalCustomCommandsFeature()
    } withDependencies: {
      $0.settingsFileStorage = storage.storage
      $0.userGlobalSettingsURL = url
    }

    await store.send(.task)
    await store.receive(\.settingsLoaded) {
      $0.settings = persisted
    }
  }

  @Test(.dependencies) func bindingNormalizesPersistsAndNotifiesDelegate() async throws {
    let storage = UserGlobalSettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/prowl-global-settings-\(UUID().uuidString).json")
    let command = makeCommand(
      shortcut: UserCustomShortcut(key: " B ", modifiers: .init(command: true, shift: true))
    )
    let expected = UserGlobalSettings(customCommands: [command])

    let store = TestStore(initialState: GlobalCustomCommandsFeature.State()) {
      GlobalCustomCommandsFeature()
    } withDependencies: {
      $0.settingsFileStorage = storage.storage
      $0.userGlobalSettingsURL = url
    }

    await store.send(.binding(.set(\.settings, UserGlobalSettings(customCommands: [command])))) {
      $0.settings = expected
    }
    await store.receive(\.delegate.settingsChanged)

    let saved = try JSONDecoder().decode(
      UserGlobalSettings.self,
      from: #require(storage.data(at: url))
    )
    #expect(saved == expected)
    #expect(saved.customCommands.first?.shortcut?.key == "b")
  }

  private func makeCommand(shortcut: UserCustomShortcut? = nil) -> UserCustomCommand {
    UserCustomCommand(
      id: "global-build",
      title: "Build Everywhere",
      systemImage: "globe",
      command: "make build",
      execution: .shellScript,
      shortcut: shortcut
    )
  }
}
