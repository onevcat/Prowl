import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import Prowl

struct UserSettingsFileTests {
  private let current = URL(filePath: "/test/global.user.json")
  private let legacy = URL(filePath: "/test/global.onevcat.json")

  private func file(_ storage: SettingsFileStorage) -> UserSettingsFile<UserGlobalSettings> {
    UserSettingsFile(
      url: current, legacyURLs: [legacy], loadData: storage.load,
      saveData: storage.save, createData: storage.create
    )
  }

  @Test func currentFileWinsAndLegacySnapshotDoesNotChangeAfterSave() throws {
    let storage = SettingsFileStorage.inMemory()
    let old = UserGlobalSettings(customCommands: [], didSeedAgentProfiles: true)
    let new = UserGlobalSettings(customCommands: [], disabledWorkflowIDs: ["user/current"])
    let original = try JSONEncoder().encode(old)
    try storage.save(original, legacy)
    try storage.save(JSONEncoder().encode(new), current)
    let file = file(storage)

    #expect(try file.load(initialValue: .default) == new)
    try file.save(.default)
    #expect(try storage.load(legacy) == original)
    #expect(try file.load(initialValue: old) == .default)
  }

  @Test func invalidLegacyFileBlocksCreationAndSaves() throws {
    let storage = SettingsFileStorage.inMemory()
    let invalid = Data("invalid".utf8)
    try storage.save(invalid, legacy)
    let file = file(storage)

    #expect(throws: DecodingError.self) { try file.load(initialValue: .default) }
    #expect(throws: DecodingError.self) { try file.save(.default) }
    #expect(throws: SettingsFileStorageError.self) { try storage.load(current) }
    #expect(try storage.load(legacy) == invalid)
  }

  @Test(arguments: [false, true]) func readFailureIsNotMissing(failAtLegacy: Bool) throws {
    let storage = SettingsFileStorage.inMemory()
    let failingURL = failAtLegacy ? legacy : current
    try storage.save(JSONEncoder().encode(UserGlobalSettings.default), legacy)
    var failing = storage
    failing.load = { url in
      if url == failingURL { throw CocoaError(.fileReadNoPermission) }
      return try storage.load(url)
    }
    let file = file(failing)

    #expect(throws: CocoaError.self) { try file.load(initialValue: .default) }
    #expect(throws: CocoaError.self) { try file.save(.default) }
    #expect(throws: SettingsFileStorageError.self) { try storage.load(current) }
  }

  @Test func failedMigrationLeavesSourceAndCanRetry() throws {
    let storage = SettingsFileStorage.inMemory()
    let value = UserGlobalSettings(customCommands: [], didSeedAgentProfiles: true)
    let data = try JSONEncoder().encode(value)
    try storage.save(data, legacy)
    var failing = storage
    failing.create = { _, _, _ in throw CocoaError(.fileWriteNoPermission) }

    #expect(throws: CocoaError.self) { try file(failing).load(initialValue: .default) }
    #expect(throws: CocoaError.self) { try file(failing).save(.default) }
    #expect(throws: SettingsFileStorageError.self) { try storage.load(current) }
    #expect(try storage.load(legacy) == data)
    #expect(try file(storage).load(initialValue: .default) == value)
    #expect(try file(storage).load(initialValue: .default) == value)
    #expect(try storage.load(current) == data)
  }

  @Test func fullGlobalModelSurvivesMigrationAndSave() throws {
    let storage = SettingsFileStorage.inMemory()
    let profile = AgentProfile(name: "Work", runtime: .codex)
    let value = UserGlobalSettings(
      customCommands: [
        UserCustomCommand(title: "Build", systemImage: "hammer", command: "make", execution: .split, shortcut: nil)
      ],
      agentProfiles: [profile], didSeedAgentProfiles: true, disabledWorkflowIDs: ["user/review"],
      workflowBindings: [
        WorkflowRememberedBinding(
          key: WorkflowBindingMemoryKey(scope: "user", workflowID: "review", role: "reviewer", digest: "digest"),
          profileID: profile.id
        )
      ],
      workflowBindModeOverrides: [WorkflowBindModeOverride(workflowKey: "user/review", mode: .auto)]
    )
    try storage.save(JSONEncoder().encode(value), legacy)
    let file = file(storage)

    #expect(try file.load(initialValue: .default) == value)
    try file.save(value)
    #expect(try JSONDecoder().decode(UserGlobalSettings.self, from: storage.load(current)) == value)
  }

  @Test(.dependencies, arguments: [0, 1]) func repositoryFallbackPreservesCompleteModel(legacyIndex: Int) throws {
    let root = URL(filePath: "/tmp/settings-migration-\(UUID().uuidString)")
    let storage = RepositoryLocalSettingsStorage.inMemory()
    let current = ProwlPaths.userRepositorySettingsURL(for: root)
    let candidates = ProwlPaths.legacyUserRepositorySettingsURLs(for: root)
    let value = UserRepositorySettings(
      customCommands: [
        UserCustomCommand(title: "Build", systemImage: "hammer", command: "make", execution: .split, shortcut: nil)
      ],
      disabledGlobalCommandIDs: ["global-build"], defaultAgentProfileID: UUID(), lastLaunchedAgentProfileID: UUID()
    )
    let data = try JSONEncoder().encode(value)
    try storage.save(data, candidates[legacyIndex])
    if legacyIndex == 0 {
      try storage.save(JSONEncoder().encode(UserRepositorySettings.default), candidates[1])
    }

    withDependencies {
      $0.repositoryLocalSettingsStorage = storage
    } operation: {
      @Shared(.userRepositorySettings(root)) var settings: UserRepositorySettings
      #expect(settings == value)
      #expect($settings.loadError == nil)
      $settings.withLock { $0.defaultAgentProfileID = nil }
      #expect($settings.saveError == nil)
    }

    let saved = try JSONDecoder().decode(UserRepositorySettings.self, from: storage.load(current))
    var expected = value
    expected.defaultAgentProfileID = nil
    #expect(saved == expected)
    #expect(try storage.load(candidates[legacyIndex]) == data)
  }

  @Test(.dependencies) func corruptRepositoryFileBlocksLegacyFallbackAndSave() throws {
    let root = URL(filePath: "/tmp/settings-migration-\(UUID().uuidString)")
    let storage = RepositoryLocalSettingsStorage.inMemory()
    let current = ProwlPaths.userRepositorySettingsURL(for: root)
    let legacy = ProwlPaths.legacyUserRepositorySettingsURLs(for: root)[0]
    let invalid = Data("invalid".utf8)
    try storage.save(invalid, current)
    try storage.save(JSONEncoder().encode(UserRepositorySettings.default), legacy)

    withDependencies {
      $0.repositoryLocalSettingsStorage = storage
    } operation: {
      @Shared(.userRepositorySettings(root)) var settings: UserRepositorySettings
      #expect($settings.loadError != nil)
      $settings.withLock { $0.defaultAgentProfileID = UUID() }
      #expect($settings.saveError != nil)
    }
    #expect(try storage.load(current) == invalid)
  }
}
