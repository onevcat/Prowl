import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

struct UserRepositorySettingsKeyTests {
  @Test func decodeLegacyPayloadIgnoresAnonymousTmux() throws {
    let legacyJSON = """
      {
        "customCommands": [],
        "useAnonymousTmuxBackedTerminals": true
      }
      """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(UserRepositorySettings.self, from: legacyJSON)

    #expect(decoded == .default)
  }

  @Test(.dependencies) func loadMissingFileReturnsDefaultAndCreatesLocalFile() throws {
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let localURL = SupacodePaths.userRepositorySettingsURL(for: rootURL)

    let loaded = withDependencies {
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.userRepositorySettings(rootURL)) var settings: UserRepositorySettings
      return settings
    }

    #expect(loaded == .default)

    let localData = try #require(localStorage.data(at: localURL))
    let decoded = try JSONDecoder().decode(UserRepositorySettings.self, from: localData)
    #expect(decoded == .default)
  }

  @Test(.dependencies) func savePersistsCustomCommandsToUserFile() throws {
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let localURL = SupacodePaths.userRepositorySettingsURL(for: rootURL)

    let customSettings = UserRepositorySettings(
      customCommands: [
        UserCustomCommand(
          title: "Test",
          systemImage: "checkmark.circle",
          command: "swift test",
          execution: .shellScript,
          shortcut: UserCustomShortcut(
            key: "u",
            modifiers: UserCustomShortcutModifiers(command: true)
          )
        )
      ]
    )

    withDependencies {
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.userRepositorySettings(rootURL)) var settings: UserRepositorySettings
      $settings.withLock {
        $0 = customSettings
      }
    }

    let localData = try #require(localStorage.data(at: localURL))
    let decoded = try JSONDecoder().decode(UserRepositorySettings.self, from: localData)
    #expect(decoded == customSettings)
  }

  @Test(.dependencies) func loadMigratesLegacyRepositoryRootUserFile() throws {
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let localURL = SupacodePaths.userRepositorySettingsURL(for: rootURL)
    let legacyURL = SupacodePaths.legacyUserRepositorySettingsURL(for: rootURL)

    let customSettings = UserRepositorySettings(
      customCommands: [
        UserCustomCommand(
          title: "Legacy",
          systemImage: "terminal",
          command: "echo legacy",
          execution: .shellScript,
          shortcut: UserCustomShortcut(
            key: "u",
            modifiers: UserCustomShortcutModifiers(command: true)
          )
        )
      ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try localStorage.save(try encoder.encode(customSettings), at: legacyURL)

    let loaded = withDependencies {
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.userRepositorySettings(rootURL)) var settings: UserRepositorySettings
      return settings
    }

    #expect(loaded == customSettings)

    let localData = try #require(localStorage.data(at: localURL))
    let decoded = try JSONDecoder().decode(UserRepositorySettings.self, from: localData)
    #expect(decoded == customSettings)
  }

  @Test(.dependencies) func savePersistsMoreThanThreeCustomCommands() throws {
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let localURL = SupacodePaths.userRepositorySettingsURL(for: rootURL)

    let commands = (0..<5).map { index in
      UserCustomCommand(
        title: "Command \(index + 1)",
        systemImage: "terminal",
        command: "echo \(index + 1)",
        execution: .shellScript,
        shortcut: nil
      )
    }
    let customSettings = UserRepositorySettings(customCommands: commands)

    withDependencies {
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.userRepositorySettings(rootURL)) var settings: UserRepositorySettings
      $settings.withLock {
        $0 = customSettings
      }
    }

    let localData = try #require(localStorage.data(at: localURL))
    let decoded = try JSONDecoder().decode(UserRepositorySettings.self, from: localData)
    #expect(decoded.customCommands.count == 5)
    #expect(decoded == customSettings)
  }
}
