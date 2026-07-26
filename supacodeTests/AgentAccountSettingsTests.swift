import ComposableArchitecture
import CustomDump
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

@MainActor
struct AgentAccountSettingsTests {
  private static let unusableRule = AgentAccountRule(pathPrefix: "~/work", account: "bad/name")

  @Test func globalStateRoundTripKeepsRulesExactlyAsTyped() {
    var settings = GlobalSettings.default
    settings.defaultAgentAccount = "personal"
    settings.agentAccountRules = [
      AgentAccountRule(pathPrefix: "~/work", account: "work"),
      Self.unusableRule,
      AgentAccountRule(),
    ]

    let state = SettingsFeature.State(settings: settings)

    expectNoDifference(state.agentAccountRules, settings.agentAccountRules)
    #expect(state.defaultAgentAccount == "personal")
    // The half-typed and unusable rows must survive the trip back to the file.
    expectNoDifference(state.globalSettings.agentAccountRules, settings.agentAccountRules)
    #expect(state.globalSettings.defaultAgentAccount == "personal")
  }

  @Test func unusableDefaultAccountIsPersistedRatherThanErased() {
    var state = SettingsFeature.State(settings: .default)
    state.defaultAgentAccount = "  work/child  "

    #expect(state.globalSettings.defaultAgentAccount == "work/child")
  }

  @Test func blankDefaultAccountClearsTheSetting() {
    var state = SettingsFeature.State(settings: .default)
    state.defaultAgentAccount = "   "

    #expect(state.globalSettings.defaultAgentAccount == nil)
  }

  @Test(.dependencies) func addingAndRemovingRulesPersists() async throws {
    let existing = AgentAccountRule(id: "existing", pathPrefix: "~/work", account: "work")
    var initialSettings = GlobalSettings.default
    initialSettings.agentAccountRules = [existing]
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.addAgentAccountRuleButtonTapped)
    let added = try #require(settingsFile.global.agentAccountRules.last)
    #expect(added.pathPrefix.isEmpty)
    #expect(added.account.isEmpty)
    expectNoDifference(settingsFile.global.agentAccountRules, [existing, added])

    // Removal is keyed by identity, so the surviving row is unambiguous.
    await store.send(.removeAgentAccountRuleButtonTapped(id: existing.id))
    expectNoDifference(settingsFile.global.agentAccountRules, [added])

    await store.send(.removeAgentAccountRuleButtonTapped(id: "already-gone"))
    expectNoDifference(settingsFile.global.agentAccountRules, [added])
  }

  @Test func repositorySettingsRoundTripKeepsAnUnusableAccount() throws {
    var settings = RepositorySettings.default
    settings.agentAccount = "work/child"

    let decoded = try JSONDecoder().decode(
      RepositorySettings.self,
      from: try JSONEncoder().encode(settings)
    )

    #expect(decoded.agentAccount == "work/child")
    #expect(AgentAccount.normalizedName(decoded.agentAccount) == nil)
  }

  @Test(.dependencies) func repositoryBindingTrimsAccountAndClearsBlankInput() async throws {
    let rootURL = URL(fileURLWithPath: "/tmp/agent-account-\(UUID().uuidString)")
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsStorage = SettingsTestStorage()
    @Shared(.repositorySettings(rootURL)) var repositorySettings

    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: rootURL,
        repositoryKind: .git,
        settings: .default,
        userSettings: .default
      )
    ) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.repositoryLocalSettingsStorage = localStorage.storage
      $0.settingsFileStorage = settingsStorage.storage
    }
    store.exhaustivity = .off

    await store.send(.binding(.set(\.settings.agentAccount, "  work  ")))
    await store.receive(\.delegate.settingsChanged)
    #expect(repositorySettings.agentAccount == "work")

    // An unusable name is stored as typed; only resolution rejects it.
    await store.send(.binding(.set(\.settings.agentAccount, "work/child")))
    await store.receive(\.delegate.settingsChanged)
    #expect(repositorySettings.agentAccount == "work/child")

    await store.send(.binding(.set(\.settings.agentAccount, "   ")))
    await store.receive(\.delegate.settingsChanged)
    #expect(repositorySettings.agentAccount == nil)
  }
}
