import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

@MainActor
struct AgentProfilesFeatureTests {
  @Test(.dependencies) func taskLoadsSettingsWithoutPushingAnEditor() async {
    let profile = AgentProfile(name: "Codex", runtime: .codex)
    let storage = SettingsTestStorage()
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0.agentProfiles = [profile] }
      return TestStore(initialState: AgentProfilesFeature.State()) {
        AgentProfilesFeature()
      }
    }

    // The root page is the list; a non-empty path would push the drill-in.
    await store.send(.task)
    await store.receive(\.settingsLoaded) {
      $0.settings.agentProfiles = [profile]
    }
    #expect(store.state.path.isEmpty)
  }

  @Test(.dependencies) func addProfileAppendsOpensEditorAndPersists() async {
    let storage = SettingsTestStorage()
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      TestStore(initialState: AgentProfilesFeature.State()) {
        AgentProfilesFeature()
      } withDependencies: {
        $0.uuid = .incrementing
      }
    }

    let expected = AgentProfile(
      id: UUID(0),
      name: "Claude Code",
      runtime: .claude
    )
    await store.send(.addProfile(.claude)) {
      $0.settings.agentProfiles = [expected]
      $0.path.append(AgentProfileEditorFeature.State(profile: expected))
    }
    await store.receive(\.delegate.settingsChanged)
  }

  @Test(.dependencies) func systemBackPopsTheEditorPath() async {
    let profile = AgentProfile(name: "Codex", runtime: .codex)
    let storage = SettingsTestStorage()
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0.agentProfiles = [profile] }
      var initial = AgentProfilesFeature.State()
      initial.settings = settings
      return TestStore(initialState: initial) {
        AgentProfilesFeature()
      }
    }

    await store.send(
      .path(.push(id: 0, state: AgentProfileEditorFeature.State(profile: profile)))
    ) {
      $0.path.append(AgentProfileEditorFeature.State(profile: profile))
    }
    await store.send(.path(.popFrom(id: 0))) {
      $0.path.removeAll()
    }
  }

  @Test(.dependencies) func profileEditedDelegateUpdatesTheListAndSanitizesPersistence() async {
    let profile = AgentProfile(name: "Codex", runtime: .codex)
    let storage = SettingsTestStorage()
    let (store, persisted) = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0.agentProfiles = [profile] }
      var initial = AgentProfilesFeature.State()
      initial.settings = settings
      initial.path.append(AgentProfileEditorFeature.State(profile: profile))
      let store = TestStore(initialState: initial) {
        AgentProfilesFeature()
      }
      return (store, $settings)
    }

    // A blank in-progress name reaches the list state but never the disk —
    // the persisted profile keeps its last non-blank name.
    var edited = profile
    edited.name = "   "
    await store.send(
      .path(.element(id: 0, action: .delegate(.profileEdited(edited))))
    ) {
      $0.settings.agentProfiles[0].name = "   "
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(persisted.wrappedValue.agentProfiles.count == 1)
    #expect(persisted.wrappedValue.agentProfiles.first?.name == "Codex")

    // Typing the new name persists it normally.
    edited.name = "Codex · Deep"
    await store.send(
      .path(.element(id: 0, action: .delegate(.profileEdited(edited))))
    ) {
      $0.settings.agentProfiles[0].name = "Codex · Deep"
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(persisted.wrappedValue.agentProfiles.first?.name == "Codex · Deep")
  }

  @Test(.dependencies) func editorRemovalDelegatePopsAndTrashesTheHome() async {
    var bound = AgentProfile(name: "Codex · Work", runtime: .codex)
    bound.bindsDedicatedHome = true
    let storage = SettingsTestStorage()
    let trashed = LockIsolated<[AgentProfile.ID]>([])
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0.agentProfiles = [bound] }
      var initial = AgentProfilesFeature.State()
      initial.settings = settings
      initial.path.append(AgentProfileEditorFeature.State(profile: bound))
      return TestStore(initialState: initial) {
        AgentProfilesFeature()
      } withDependencies: {
        $0[AgentProfileHomeClient.self].trashHome = { id in
          trashed.withValue { $0.append(id) }
        }
      }
    }

    // Removal pops the editor path back to the list and trashes in the parent, so
    // the dismissal cannot cancel the file operation.
    await store.send(
      .path(.element(id: 0, action: .delegate(.removeProfile(bound.id, trashFiles: true))))
    ) {
      $0.settings.agentProfiles = []
      $0.path.removeAll()
    }
    await store.receive(\.delegate.settingsChanged)
    await store.finish()
    #expect(trashed.value == [bound.id])
  }

  @Test(.dependencies) func editorRemovalDelegateCanKeepFilesOnDisk() async {
    let preset = AgentProfile(name: "Claude", runtime: .claude)
    let storage = SettingsTestStorage()
    let trashed = LockIsolated<[AgentProfile.ID]>([])
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0.agentProfiles = [preset] }
      var initial = AgentProfilesFeature.State()
      initial.settings = settings
      initial.path.append(AgentProfileEditorFeature.State(profile: preset))
      return TestStore(initialState: initial) {
        AgentProfilesFeature()
      } withDependencies: {
        $0[AgentProfileHomeClient.self].trashHome = { id in
          trashed.withValue { $0.append(id) }
        }
      }
    }

    await store.send(
      .path(.element(id: 0, action: .delegate(.removeProfile(preset.id, trashFiles: false))))
    ) {
      $0.settings.agentProfiles = []
      $0.path.removeAll()
    }
    await store.receive(\.delegate.settingsChanged)
    await store.finish()
    #expect(trashed.value.isEmpty)
  }

  @Test(.dependencies) func togglingEnabledPersistsFromTheList() async {
    let profile = AgentProfile(name: "Codex", runtime: .codex)
    let storage = SettingsTestStorage()
    let (store, persisted) = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0.agentProfiles = [profile] }
      var initial = AgentProfilesFeature.State()
      initial.settings = settings
      let store = TestStore(initialState: initial) {
        AgentProfilesFeature()
      }
      return (store, $settings)
    }

    var edited = store.state.settings
    edited.agentProfiles[0].isEnabled = false
    await store.send(.binding(.set(\.settings, edited))) {
      $0.settings.agentProfiles[0].isEnabled = false
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(persisted.wrappedValue.agentProfiles.first?.isEnabled == false)
  }

  @Test func launchConfigRootOnlyAppliesToTheLaunchedRuntime() {
    let home = URL(fileURLWithPath: "/base/agent-profiles/ABC", isDirectory: true)
    let identity = WorktreeTerminalState.SurfaceLaunchProfile(
      profileID: UUID(),
      name: "Codex · Work",
      runtime: .codex,
      dedicatedHome: home
    )
    #expect(identity.configRoot(forDetected: .codex) == home)
    // A different agent started manually in the same pane uses its default
    // home; handing it the profile home would break session attribution.
    #expect(identity.configRoot(forDetected: .claude) == nil)

    let geminiRoot = home.appending(path: ".gemini", directoryHint: .isDirectory)
    let nestedIdentity = WorktreeTerminalState.SurfaceLaunchProfile(
      profileID: UUID(),
      name: "Gemini · Work",
      runtime: .gemini,
      dedicatedHome: home,
      sessionConfigRoot: geminiRoot
    )
    #expect(nestedIdentity.configRoot(forDetected: .gemini) == geminiRoot)
  }

  @Test(.dependencies) func moveReordersFallbackPriority() async {
    let first = AgentProfile(name: "First", runtime: .codex)
    let second = AgentProfile(name: "Second", runtime: .claude)
    let storage = SettingsTestStorage()
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0.agentProfiles = [first, second] }
      var initial = AgentProfilesFeature.State()
      initial.settings = settings
      return TestStore(initialState: initial) {
        AgentProfilesFeature()
      }
    }

    await store.send(.moveProfiles(IndexSet(integer: 1), 0)) {
      $0.settings.agentProfiles = [second, first]
    }
    await store.receive(\.delegate.settingsChanged)
  }

  @Test(.dependencies) func repositoryDefaultAgentProfilePersistsThroughDedicatedAction() async throws {
    let rootURL = URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)")
    let localStorage = RepositoryLocalSettingsTestStorage()
    let profileID = UUID()
    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: rootURL,
        repositoryKind: .plain,
        settings: .default,
        userSettings: .default
      )
    ) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.repositoryLocalSettingsStorage = localStorage.storage
    }

    await store.send(.setDefaultAgentProfileID(profileID)) {
      $0.userSettings.defaultAgentProfileID = profileID
    }
    await store.receive(\.delegate.settingsChanged)

    let persisted = try JSONDecoder().decode(
      UserRepositorySettings.self,
      from: #require(localStorage.data(at: SupacodePaths.userRepositorySettingsURL(for: rootURL)))
    )
    #expect(persisted.defaultAgentProfileID == profileID)

    await store.send(.setDefaultAgentProfileID(nil)) {
      $0.userSettings.defaultAgentProfileID = nil
    }
    await store.receive(\.delegate.settingsChanged)
  }

  @Test(.dependencies) func repositorySettingsWritebacksPreserveExternalLaunchMemory() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)")
    let localStorage = RepositoryLocalSettingsTestStorage()
    let launched = UUID()
    let designated = UUID()
    let (store, shared) = withDependencies {
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      let store = TestStore(
        initialState: RepositorySettingsFeature.State(
          rootURL: rootURL,
          repositoryKind: .plain,
          settings: .default,
          userSettings: .default
        )
      ) {
        RepositorySettingsFeature()
      }
      @Shared(.userRepositorySettings(rootURL)) var userRepositorySettings
      // A profile launch writes the memory while Settings stays open with a
      // stale snapshot.
      $userRepositorySettings.withLock { $0.lastLaunchedAgentProfileID = launched }
      return (store, $userRepositorySettings)
    }

    await store.send(.setDefaultAgentProfileID(designated)) {
      $0.userSettings.defaultAgentProfileID = designated
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(shared.wrappedValue.lastLaunchedAgentProfileID == launched)
    #expect(shared.wrappedValue.defaultAgentProfileID == designated)

    // The whole-struct binding writeback must also preserve (and refresh) it.
    var user = store.state.userSettings
    user.disabledGlobalCommandIDs = ["global-build"]
    await store.send(.binding(.set(\.userSettings, user))) {
      $0.userSettings.disabledGlobalCommandIDs = ["global-build"]
      $0.userSettings.lastLaunchedAgentProfileID = launched
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(shared.wrappedValue.lastLaunchedAgentProfileID == launched)
  }
}
