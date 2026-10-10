import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import Prowl

struct UserSettingsLoadRecoveryTests {
  @Test(.dependencies) func failedLoadBlocksSavesUntilSuccessfulReload() async throws {
    let storage = SettingsFileStorage.inMemory()
    let url = URL(filePath: "/tmp/recovery-\(UUID().uuidString)/global.user.json")
    try storage.save(Data("invalid".utf8), url)
    let recovered = UserGlobalSettings(customCommands: [], disabledWorkflowIDs: ["user/recovered"])
    let data = try JSONEncoder().encode(recovered)

    try await withDependencies {
      $0.settingsFileStorage = storage
      $0.userGlobalSettingsURL = url
    } operation: {
      @Shared(.userGlobalSettings) var settings: UserGlobalSettings
      #expect($settings.loadError != nil)
      try storage.save(data, url)
      $settings.withLock { $0.didSeedAgentProfiles = true }
      #expect($settings.saveError != nil)
      #expect(try storage.load(url) == data)

      try await $settings.load()
      #expect(settings == recovered)
      $settings.withLock { $0.didSeedAgentProfiles = true }
      #expect($settings.saveError == nil)
      var expected = recovered
      expected.didSeedAgentProfiles = true
      #expect(try JSONDecoder().decode(UserGlobalSettings.self, from: storage.load(url)) == expected)
    }
  }
}
