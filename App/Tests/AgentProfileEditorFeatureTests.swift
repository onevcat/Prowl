import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

@MainActor
struct AgentProfileEditorFeatureTests {
  @Test(.dependencies) func editsDelegateProfileEdited() async {
    let profile = AgentProfile(name: "Codex", runtime: .codex)
    let store = TestStore(initialState: AgentProfileEditorFeature.State(profile: profile)) {
      AgentProfileEditorFeature()
    }

    var edited = profile
    edited.name = "Codex · Deep"
    await store.send(.binding(.set(\.profile, edited))) {
      $0.profile.name = "Codex · Deep"
    }
    await store.receive(\.delegate.profileEdited)
  }

  @Test(.dependencies) func changingRuntimeClearsRuntimeSpecificConfiguration() async {
    var profile = AgentProfile(name: "Codex", runtime: .codex)
    profile.model = "gpt-5.6-sol"
    profile.reasoningEffort = "xhigh"
    profile.extraArguments = "--search"
    profile.environmentOverrides = [
      AgentProfileEnvironmentOverride(name: "OPENAI_BASE_URL", value: "https://api.deepseek.com/v1")
    ]
    profile.executionMode = .unrestricted
    profile.icon = "wand.and.stars"
    profile.placement = .split
    profile.splitDirection = .left
    profile.bindsDedicatedHome = true
    let store = TestStore(initialState: AgentProfileEditorFeature.State(profile: profile)) {
      AgentProfileEditorFeature()
    }

    await store.send(.runtimeChanged(.claude)) {
      $0.profile.runtime = .claude
      $0.profile.model = nil
      $0.profile.reasoningEffort = nil
      $0.profile.extraArguments = ""
      $0.profile.environmentOverrides = []
      $0.profile.executionMode = .standard
      $0.profile.icon = "wand.and.stars"
      $0.profile.placement = .split
      $0.profile.splitDirection = .left
      $0.profile.bindsDedicatedHome = true
    }
    await store.receive(\.delegate.profileEdited)
  }

  @Test(.dependencies) func changingToRuntimeWithoutIsolationClearsDedicatedHomeBinding() async {
    var profile = AgentProfile(name: "Codex", runtime: .codex)
    profile.bindsDedicatedHome = true
    let store = TestStore(initialState: AgentProfileEditorFeature.State(profile: profile)) {
      AgentProfileEditorFeature()
    }

    await store.send(.runtimeChanged(.cursor)) {
      $0.profile.runtime = .cursor
      $0.profile.bindsDedicatedHome = false
    }
    await store.receive(\.delegate.profileEdited)
  }

  @Test(.dependencies) func changingToRuntimeWithoutExecutionSelectionClearsUnrestrictedMode() async {
    var profile = AgentProfile(name: "Codex", runtime: .codex)
    profile.executionMode = .unrestricted
    let store = TestStore(initialState: AgentProfileEditorFeature.State(profile: profile)) {
      AgentProfileEditorFeature()
    }

    await store.send(.runtimeChanged(.pi)) {
      $0.profile.runtime = .pi
      $0.profile.executionMode = .standard
    }
    await store.receive(\.delegate.profileEdited)
  }

  @Test func suggestionSelectionDistinguishesCustomValuesFromRuntimeDefault() {
    let suggestions = ["low", "medium", "high"]

    #expect(AgentProfileSuggestionSelection(value: nil, suggestions: suggestions) == .runtimeDefault)
    #expect(AgentProfileSuggestionSelection(value: "medium", suggestions: suggestions) == .suggestion("medium"))
    #expect(
      AgentProfileSuggestionSelection(value: "gateway-specific", suggestions: suggestions)
        == .custom("gateway-specific"))
    #expect(AgentProfileSuggestionSelection.custom("gateway-specific").value == "gateway-specific")
  }

  @Test(.dependencies) func settingProfileIconDelegatesTheEditedProfile() async {
    let profile = AgentProfile(name: "Codex", runtime: .codex)
    let store = TestStore(initialState: AgentProfileEditorFeature.State(profile: profile)) {
      AgentProfileEditorFeature()
    }

    await store.send(.setIcon("wand.and.stars")) {
      $0.profile.icon = "wand.and.stars"
    }
    await store.receive(\.delegate.profileEdited)

    await store.send(.setIcon(nil)) {
      $0.profile.icon = nil
    }
    await store.receive(\.delegate.profileEdited)
  }

  @Test(.dependencies) func addingAndRemovingEnvironmentOverrideRowsDelegates() async {
    let profile = AgentProfile(name: "Codex", runtime: .codex)
    let store = TestStore(initialState: AgentProfileEditorFeature.State(profile: profile)) {
      AgentProfileEditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }

    let rowID = UUID(0)
    await store.send(.addEnvironmentOverride) {
      $0.profile.environmentOverrides = [AgentProfileEnvironmentOverride(id: rowID)]
    }
    await store.receive(\.delegate.profileEdited)

    await store.send(.removeEnvironmentOverride(rowID)) {
      $0.profile.environmentOverrides = []
    }
    await store.receive(\.delegate.profileEdited)
  }

  @Test(.dependencies) func unrestrictedRequiresExplicitConfirmation() async {
    let profile = AgentProfile(name: "Codex", runtime: .codex)
    let storage = SettingsTestStorage()
    let (store, persisted) = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0.agentProfiles = [profile] }
      let store = TestStore(initialState: AgentProfileEditorFeature.State(profile: profile)) {
        AgentProfileEditorFeature()
      }
      return (store, $settings)
    }

    var edited = profile
    edited.executionMode = .unrestricted

    // The binding write reverts and asks first.
    await store.send(.binding(.set(\.profile, edited))) {
      $0.alert = AgentProfileEditorFeature.unrestrictedAlert()
    }

    await store.send(.alert(.presented(.confirmUnrestricted))) {
      $0.alert = nil
      $0.profile.executionMode = .unrestricted
    }
    await store.receive(\.delegate.profileEdited)
    #expect(persisted.wrappedValue.agentProfiles.first?.executionMode == .standard)
  }

  @Test(.dependencies) func removingBoundProfileConfirmsAndDelegatesTrash() async {
    var bound = AgentProfile(name: "Codex · Work", runtime: .codex)
    bound.bindsDedicatedHome = true
    let store = TestStore(initialState: AgentProfileEditorFeature.State(profile: bound)) {
      AgentProfileEditorFeature()
    }

    await store.send(.removeTapped) {
      $0.alert = AgentProfileEditorFeature.removalAlert(profile: bound, hasProfileHome: true)
    }
    await store.send(.alert(.presented(.removeTrashingFiles))) {
      $0.alert = nil
    }
    await store.receive(\.delegate.removeProfile)
  }

  @Test(.dependencies) func unboundProfileWithHomeOnDiskStillConfirmsRemoval() async {
    // bind → launch (home created) → unbind → remove: the gate keys on the
    // disk fact, so the credentials never get orphaned silently.
    let unbound = AgentProfile(name: "Codex · Was Bound", runtime: .codex)
    let store = TestStore(initialState: AgentProfileEditorFeature.State(profile: unbound)) {
      AgentProfileEditorFeature()
    } withDependencies: {
      $0[AgentProfileHomeClient.self].homeExists = { _ in true }
    }

    await store.send(.removeTapped) {
      $0.alert = AgentProfileEditorFeature.removalAlert(profile: unbound, hasProfileHome: true)
    }
    await store.send(.alert(.presented(.removeKeepingFiles))) {
      $0.alert = nil
    }
    await store.receive(\.delegate.removeProfile)
  }

  @Test(.dependencies) func removingPurePresetRequiresConfirmation() async {
    let preset = AgentProfile(name: "Claude", runtime: .claude)
    let store = TestStore(initialState: AgentProfileEditorFeature.State(profile: preset)) {
      AgentProfileEditorFeature()
    }

    await store.send(.removeTapped) {
      $0.alert = AgentProfileEditorFeature.removalAlert(profile: preset, hasProfileHome: false)
    }
    await store.send(.alert(.presented(.removeKeepingFiles))) {
      $0.alert = nil
    }
    await store.receive(\.delegate.removeProfile)
  }

  @Test(.dependencies) func revealRefreshesThePassiveHomeStatus() async {
    var bound = AgentProfile(name: "Codex · Work", runtime: .codex)
    bound.bindsDedicatedHome = true
    let homeOnDisk = LockIsolated(false)
    let store = TestStore(initialState: AgentProfileEditorFeature.State(profile: bound)) {
      AgentProfileEditorFeature()
    } withDependencies: {
      $0[AgentProfileHomeClient.self].homeExists = { _ in homeOnDisk.value }
      $0[AgentProfileHomeClient.self].revealHome = { _ in homeOnDisk.setValue(true) }
    }

    await store.send(.revealProfileFiles)
    await store.receive(\.homeStatusRefreshed) {
      $0.homeInitialized = true
    }
  }
}
