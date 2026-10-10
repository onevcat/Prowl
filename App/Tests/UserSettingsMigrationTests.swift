import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import Prowl

struct UserSettingsMigrationTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "user-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private let legacyData = Data(
    #"{"customCommands":[],"didSeedAgentProfiles":true,"disabledWorkflowIDs":["user/review"],"futureField":42}"#.utf8
  )

  @Test(.dependencies) func globalMigrationPreservesBytesAndOldFile() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oldURL = directory.appending(path: "global.onevcat.json")
    let newURL = directory.appending(path: "global.user.json")
    try legacyData.write(to: oldURL)

    withDependencies {
      $0.settingsFileStorage = SettingsFileStorageKey.liveValue
      $0.userGlobalSettingsURL = newURL
    } operation: {
      @Shared(.userGlobalSettings) var settings: UserGlobalSettings
      #expect(settings.didSeedAgentProfiles)
      #expect(settings.disabledWorkflowIDs == ["user/review"])
      #expect($settings.loadError == nil)
    }

    #expect(try Data(contentsOf: newURL) == legacyData)
    #expect(try Data(contentsOf: oldURL) == legacyData)
    let attributes = try FileManager.default.attributesOfItem(atPath: newURL.path())
    #expect(attributes[.posixPermissions] as? Int == 0o600)
  }

  @Test(.dependencies) func invalidCurrentFileBlocksFallbackAndAutomaticSaves() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oldURL = directory.appending(path: "global.onevcat.json")
    let newURL = directory.appending(path: "global.user.json")
    let invalid = Data("invalid".utf8)
    try legacyData.write(to: oldURL)
    try invalid.write(to: newURL)

    withDependencies {
      $0.settingsFileStorage = SettingsFileStorageKey.liveValue
      $0.userGlobalSettingsURL = newURL
    } operation: {
      @Shared(.userGlobalSettings) var settings: UserGlobalSettings
      #expect($settings.loadError != nil)
      $settings.withLock { $0.didSeedAgentProfiles = true }
      #expect($settings.saveError != nil)
    }

    #expect(try Data(contentsOf: newURL) == invalid)
    #expect(try Data(contentsOf: oldURL) == legacyData)
  }

  @Test(.dependencies) func legacyRelativeSymlinkKeepsDotfilesTarget() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appending(path: "dotfiles.json")
    let oldURL = directory.appending(path: "global.onevcat.json")
    let newURL = directory.appending(path: "global.user.json")
    try legacyData.write(to: target)
    try FileManager.default.createSymbolicLink(atPath: oldURL.path(), withDestinationPath: "dotfiles.json")

    withDependencies {
      $0.settingsFileStorage = SettingsFileStorageKey.liveValue
      $0.userGlobalSettingsURL = newURL
    } operation: {
      @Shared(.userGlobalSettings) var settings: UserGlobalSettings
      #expect(settings.didSeedAgentProfiles)
      $settings.withLock { $0.disabledWorkflowIDs = ["user/changed"] }
      #expect($settings.saveError == nil)
    }

    #expect(try newURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(try oldURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(try Data(contentsOf: newURL) == Data(contentsOf: target))
    let saved = try JSONDecoder().decode(UserGlobalSettings.self, from: Data(contentsOf: target))
    #expect(saved.disabledWorkflowIDs == ["user/changed"])
  }

  @Test(.dependencies, arguments: ["global.user.json", "global.onevcat.json"])
  func danglingSymlinkIsNotMissing(name: String) throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let link = directory.appending(path: name)
    let newURL = directory.appending(path: "global.user.json")
    let target = directory.appending(path: "missing.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    withDependencies {
      $0.settingsFileStorage = SettingsFileStorageKey.liveValue
      $0.userGlobalSettingsURL = newURL
    } operation: {
      @Shared(.userGlobalSettings) var settings: UserGlobalSettings
      #expect($settings.loadError != nil)
      $settings.withLock { $0.didSeedAgentProfiles = true }
      #expect($settings.saveError != nil)
    }

    #expect(!FileManager.default.fileExists(atPath: target.path()))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path()) == target.path())
  }
}
