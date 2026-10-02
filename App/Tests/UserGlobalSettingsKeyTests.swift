import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

struct UserGlobalSettingsKeyTests {
  @Test(.dependencies) func missingFileCreatesDefaultGlobalSettings() throws {
    let storage = UserGlobalSettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/prowl-global-settings-\(UUID().uuidString).json")

    let loaded = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.userGlobalSettingsURL = url
    } operation: {
      @Shared(.userGlobalSettings) var settings: UserGlobalSettings
      return settings
    }

    #expect(loaded == .default)
    #expect(try JSONDecoder().decode(UserGlobalSettings.self, from: #require(storage.data(at: url))) == .default)
  }

  @Test(.dependencies) func savingWritesOnlyTheGlobalSettingsFile() throws {
    let storage = UserGlobalSettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/prowl-global-settings-\(UUID().uuidString).json")
    let settings = UserGlobalSettings(customCommands: [
      UserCustomCommand(
        id: "global-build",
        title: "Build",
        systemImage: "hammer",
        command: "make build",
        execution: .split,
        splitDirection: .down,
        closeOnSuccess: true,
        shortcut: UserCustomShortcut(key: "b", modifiers: .init(command: true, shift: true))
      )
    ])

    withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.userGlobalSettingsURL = url
    } operation: {
      @Shared(.userGlobalSettings) var storedSettings: UserGlobalSettings
      $storedSettings.withLock { $0 = settings }
    }

    #expect(try JSONDecoder().decode(UserGlobalSettings.self, from: #require(storage.data(at: url))) == settings)
  }
}

nonisolated final class UserGlobalSettingsTestStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var dataByURL: [URL: Data] = [:]

  var storage: SettingsFileStorage {
    SettingsFileStorage(load: { try self.load($0) }, save: { try self.save($0, at: $1) })
  }

  func data(at url: URL) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return dataByURL[url]
  }

  private func load(_ url: URL) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let data = dataByURL[url] else { throw UserGlobalSettingsTestStorageError.missing }
    return data
  }

  private func save(_ data: Data, at url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    dataByURL[url] = data
  }
}

private enum UserGlobalSettingsTestStorageError: Error {
  case missing
}
