import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

struct ScriptProfilesKeyTests {
  @Test(.dependencies) func saveAndReloadProfiles() throws {
    let storage = SettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/script-profiles-\(UUID().uuidString).json")

    withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.scriptProfilesFileURL = url
    } operation: {
      @Shared(.scriptProfiles) var profiles: [ScriptProfile]
      $profiles.withLock {
        $0 = [
          ScriptProfile(
            id: " sync-app ",
            name: " Sync App ",
            description: " Copies files ",
            command: " ",
            environment: [
              " CUSTOM ": "1",
              "": "ignored",
            ],
            script: "echo hello",
            timeoutSeconds: 0
          )
        ]
      }
    }

    let reloaded: [ScriptProfile] = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.scriptProfilesFileURL = url
    } operation: {
      @Shared(.scriptProfiles) var profiles: [ScriptProfile]
      return profiles
    }

    #expect(
      reloaded == [
        ScriptProfile(
          id: "sync-app",
          name: "Sync App",
          description: "Copies files",
          command: ScriptProfile.defaultCommand,
          environment: ["CUSTOM": "1"],
          script: "echo hello",
          timeoutSeconds: 1
        )
      ])
  }

  @Test func decodesLegacyShellAsCommand() throws {
    let data = Data(
      """
      [
        {
          "id": "legacy",
          "name": "Legacy",
          "shell": "/bin/zsh",
          "script": "echo legacy"
        }
      ]
      """.utf8
    )

    let profiles = try JSONDecoder().decode([ScriptProfile].self, from: data)

    #expect(profiles.first?.normalized.command == #"/bin/zsh "$PROWL_SCRIPT""#)
  }
}
