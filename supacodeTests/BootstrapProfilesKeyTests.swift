import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

struct BootstrapProfilesKeyTests {
  @Test(.dependencies) func saveAndReloadProfiles() throws {
    let storage = SettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/bootstrap-profiles-\(UUID().uuidString).json")

    withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.bootstrapProfilesFileURL = url
    } operation: {
      @Shared(.bootstrapProfiles) var profiles: [ProjectWorkspaceBootstrapProfile]
      $profiles.withLock {
        $0 = [
          ProjectWorkspaceBootstrapProfile(
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

    let reloaded: [ProjectWorkspaceBootstrapProfile] = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.bootstrapProfilesFileURL = url
    } operation: {
      @Shared(.bootstrapProfiles) var profiles: [ProjectWorkspaceBootstrapProfile]
      return profiles
    }

    #expect(
      reloaded == [
        ProjectWorkspaceBootstrapProfile(
          id: "sync-app",
          name: "Sync App",
          description: "Copies files",
          command: ProjectWorkspaceBootstrapProfile.defaultCommand,
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

    let profiles = try JSONDecoder().decode([ProjectWorkspaceBootstrapProfile].self, from: data)

    #expect(profiles.first?.normalized.command == #"/bin/zsh "$script""#)
  }
}
