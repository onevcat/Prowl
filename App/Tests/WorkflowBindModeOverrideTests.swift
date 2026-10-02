import Foundation
import Testing

@testable import supacode

struct WorkflowBindModeOverrideTests {
  @Test func preferenceKeysIncludeTheRepositoryIdentity() {
    #expect(WorkflowPreferenceKey.make(scope: .bundle, workflowID: "review") == "bundle/review")
    #expect(WorkflowPreferenceKey.make(scope: .user, workflowID: "review") == "user/review")
    #expect(
      WorkflowPreferenceKey.make(
        scope: .repo(repositoryID: "/tmp/other/../repo/"), workflowID: "review")
        == "repo:/tmp/repo/review")
  }

  @Test func legacyRepositoryPreferencesMigrateToEveryRegisteredRepository() {
    var settings = UserGlobalSettings(
      customCommands: [],
      disabledWorkflowIDs: ["repo/review", "user/personal"],
      workflowBindModeOverrides: [
        WorkflowBindModeOverride(workflowKey: "repo/review", mode: .auto),
        WorkflowBindModeOverride(workflowKey: "user/personal", mode: .ask),
      ])

    let changed = settings.migrateLegacyRepositoryWorkflowPreferences(
      repositoryRootPaths: ["/tmp/zeta", "/tmp/alpha"])

    #expect(changed)
    #expect(
      settings.disabledWorkflowIDs == [
        "repo:/tmp/alpha/review",
        "repo:/tmp/zeta/review",
        "user/personal",
      ])
    #expect(
      settings.workflowBindModeOverrides == [
        WorkflowBindModeOverride(workflowKey: "repo:/tmp/alpha/review", mode: .auto),
        WorkflowBindModeOverride(workflowKey: "repo:/tmp/zeta/review", mode: .auto),
        WorkflowBindModeOverride(workflowKey: "user/personal", mode: .ask),
      ])
  }

  @Test func legacyRepositoryPreferencesWaitUntilARepositoryIsKnown() {
    var settings = UserGlobalSettings(
      customCommands: [],
      disabledWorkflowIDs: ["repo/review"],
      workflowBindModeOverrides: [WorkflowBindModeOverride(workflowKey: "repo/review", mode: .ask)])

    let changed = settings.migrateLegacyRepositoryWorkflowPreferences(repositoryRootPaths: [])

    #expect(!changed)
    #expect(settings.disabledWorkflowIDs == ["repo/review"])
    #expect(settings.workflowBindMode(for: "repo/review") == .ask)
  }

  @Test func overrideRoundTripsThroughCoding() throws {
    var settings = UserGlobalSettings(customCommands: [])
    settings.setWorkflowBindMode(.auto, for: "bundle/prowl.adversarial-review")
    settings.setWorkflowBindMode(.ask, for: "user/my-review")

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(UserGlobalSettings.self, from: data)

    #expect(decoded.workflowBindMode(for: "bundle/prowl.adversarial-review") == .auto)
    #expect(decoded.workflowBindMode(for: "user/my-review") == .ask)
    #expect(decoded.workflowBindMode(for: "repo:abc/other") == nil)
  }

  @Test func settingNilClearsTheOverride() {
    var settings = UserGlobalSettings(customCommands: [])
    settings.setWorkflowBindMode(.auto, for: "user/my-review")
    settings.setWorkflowBindMode(nil, for: "user/my-review")

    #expect(settings.workflowBindMode(for: "user/my-review") == nil)
    #expect(settings.workflowBindModeOverrides.isEmpty)
  }

  @Test func lastWriteWinsPerKeyAndOrderIsStable() {
    let overrides = [
      WorkflowBindModeOverride(workflowKey: "user/b", mode: .ask),
      WorkflowBindModeOverride(workflowKey: "user/a", mode: .ask),
      WorkflowBindModeOverride(workflowKey: "user/b", mode: .auto),
    ]

    let normalized = WorkflowBindModeOverride.normalized(overrides)

    #expect(
      normalized == [
        WorkflowBindModeOverride(workflowKey: "user/a", mode: .ask),
        WorkflowBindModeOverride(workflowKey: "user/b", mode: .auto),
      ])
  }

  @Test func decodingWithoutTheKeyDefaultsToEmpty() throws {
    let json = #"{"customCommands":[]}"#
    let decoded = try JSONDecoder().decode(UserGlobalSettings.self, from: Data(json.utf8))
    #expect(decoded.workflowBindModeOverrides.isEmpty)
  }

  @Test func normalizedForwardsOverrides() {
    var settings = UserGlobalSettings(customCommands: [])
    settings.setWorkflowBindMode(.auto, for: "user/my-review")
    #expect(settings.normalized().workflowBindMode(for: "user/my-review") == .auto)
  }
}
