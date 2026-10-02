import Dependencies
import DependenciesTestSupport
import Foundation
import ProwlCLIShared
import Sharing
import Testing

@testable import supacode

struct UserRepositorySettingsKeyTests {
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

  @Test func globalCommandOptOutPersistsAndLegacyCommandsDefaultToEnabled() throws {
    let legacyData = Data(
      #"""
      {
        "customCommands": [
          {
            "id": "legacy-build",
            "title": "Build",
            "systemImage": "hammer",
            "command": "make build",
            "execution": "shellScript"
          }
        ]
      }
      """#.utf8
    )
    let legacy = try JSONDecoder().decode(UserRepositorySettings.self, from: legacyData)
    #expect(legacy.customCommands[0].isEnabled)

    let settings = UserRepositorySettings(
      customCommands: legacy.customCommands,
      disabledGlobalCommandIDs: ["global-build"]
    )
    #expect(!settings.isGlobalCommandEnabled("global-build"))
    #expect(settings.isGlobalCommandEnabled("global-test"))

    let persisted = try JSONDecoder().decode(
      UserRepositorySettings.self,
      from: JSONEncoder().encode(settings)
    )
    #expect(persisted == settings)
  }

  @Test func globalCommandOptOutsEncodeInStableOrder() throws {
    let disabledIDs: Set<UserCustomCommand.ID> = [
      "zulu",
      "alpha",
      "middle",
      "bravo",
      "tango",
      "delta",
      "uniform",
      "echo",
      "charlie",
      "foxtrot",
    ]
    let settings = UserRepositorySettings(customCommands: [], disabledGlobalCommandIDs: disabledIDs)

    let encoded = try JSONEncoder().encode(settings)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let optOutIDs = try #require(object["disabledGlobalCommandIDs"] as? [String])

    #expect(optOutIDs == disabledIDs.sorted())
  }
}
