import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import ProwlCLIShared
import Sharing
import Testing

@testable import supacode

@MainActor
struct AppFeatureAgentProfileTests {
  @Test(.dependencies) func launchSendsPlanAndDefersMemoryToTheLaunchedEvent() async throws {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let profile = AgentProfile(name: "Codex · Work", runtime: .codex, model: "gpt-5.4")
    let storage = SettingsTestStorage()
    let sent = LockIsolated<[TerminalClient.Command]>([])

    let (store, repoSettings) = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var globalSettings
      $globalSettings.withLock { $0.agentProfiles = [profile] }
      @Shared(.userRepositorySettings(worktree.repositoryRootURL)) var repoSettings
      let store = TestStore(
        initialState: AppFeature.State(
          repositories: repositories,
          settings: SettingsFeature.State()
        )
      ) {
        AppFeature()
      } withDependencies: {
        $0.terminalClient.send = { command in
          sent.withValue { $0.append(command) }
        }
      }
      return (store, $repoSettings)
    }

    await store.send(.launchAgentProfile(profile.id))
    await store.finish()

    let expectedPlan = try AgentProfileLaunchPlanner.plan(
      for: profile,
      homeBaseDirectory: SupacodePaths.agentProfileHomesDirectory
    )
    #expect(sent.value == [.launchAgentProfile(worktree, plan: expectedPlan)])
    // Dispatch must not record launch memory: a launch that fails to create a
    // surface would otherwise shift Recommended (docs-ai 053/005).
    #expect(repoSettings.wrappedValue.lastLaunchedAgentProfileID == nil)

    await store.send(.terminalEvent(.agentProfileLaunched(worktreeID: worktree.id, profileID: profile.id)))
    #expect(repoSettings.wrappedValue.lastLaunchedAgentProfileID == profile.id)
  }

  @Test(.dependencies) func launchFailedEventShowsWarningToastWithoutRecordingMemory() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let storage = SettingsTestStorage()

    let (store, repoSettings) = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userRepositorySettings(worktree.repositoryRootURL)) var repoSettings
      let store = TestStore(
        initialState: AppFeature.State(
          repositories: repositories,
          settings: SettingsFeature.State()
        )
      ) {
        AppFeature()
      }
      return (store, $repoSettings)
    }
    // The toast auto-dismiss effect sleeps a real clock; non-exhaustive mode
    // lets the test end without draining it.
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(.agentProfileLaunchFailed(worktreeID: worktree.id, profileName: "Broken"))
    )
    await store.receive(\.repositories.showToast)
    #expect(store.state.repositories.statusToast == .warning("Couldn't launch “Broken”"))
    #expect(repoSettings.wrappedValue.lastLaunchedAgentProfileID == nil)
  }

  @Test(.dependencies) func degradedHookEventShowsOneNonBlockingWarningToast() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let storage = SettingsTestStorage()
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      TestStore(
        initialState: AppFeature.State(
          repositories: repositories,
          settings: SettingsFeature.State()
        )
      ) {
        AppFeature()
      }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .agentProfileLaunchWarning(
          worktreeID: worktree.id,
          profileName: "Codex",
          message: "Notifier resolver unavailable."
        )
      )
    )
    await store.receive(\.repositories.showToast)
    #expect(
      store.state.repositories.statusToast
        == .warning("“Codex” launched without managed signals. Notifier resolver unavailable.")
    )
  }

  @Test(.dependencies) func launchIgnoresDisabledOrUnknownProfiles() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let disabled = AgentProfile(name: "Disabled", isEnabled: false, runtime: .claude)
    let storage = SettingsTestStorage()
    let sent = LockIsolated<[TerminalClient.Command]>([])

    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var globalSettings
      $globalSettings.withLock { $0.agentProfiles = [disabled] }
      return TestStore(
        initialState: AppFeature.State(
          repositories: repositories,
          settings: SettingsFeature.State()
        )
      ) {
        AppFeature()
      } withDependencies: {
        $0.terminalClient.send = { command in
          sent.withValue { $0.append(command) }
        }
      }
    }

    await store.send(.launchAgentProfile(disabled.id))
    await store.send(.launchAgentProfile(UUID()))
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func seedingRunsOnceAndOnlyForInstalledRuntimes() {
    let storage = SettingsTestStorage()
    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      AgentProfileSeeder.seedIfNeeded { runtime in runtime == .codex }

      @Shared(.userGlobalSettings) var settings
      #expect(settings.didSeedAgentProfiles)
      #expect(settings.agentProfiles.map(\.name) == ["Codex"])
      #expect(settings.agentProfiles.first?.runtime == .codex)
      #expect(settings.agentProfiles.first?.bindsDedicatedHome == false)

      // Deleting the seed must not respawn it on the next launch.
      $settings.withLock { $0.agentProfiles = [] }
      AgentProfileSeeder.seedIfNeeded { _ in true }
      #expect(settings.agentProfiles.isEmpty)
    }
  }

  @Test(.dependencies) func paletteBuildsLaunchItemsWithRecommendedFirst() {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let storage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      let first = AgentProfile(name: "First", runtime: .codex)
      let second = AgentProfile(name: "Second", runtime: .claude, icon: "wand.and.stars")
      let disabled = AgentProfile(name: "Hidden", isEnabled: false, runtime: .claude)
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0.agentProfiles = [first, second, disabled] }
      @Shared(.userRepositorySettings(worktree.repositoryRootURL)) var repoSettings
      $repoSettings.withLock { $0.defaultAgentProfileID = second.id }

      let items = agentProfileLaunchItems(repositories, launchWarning: { _ in nil })

      #expect(items.map(\.title) == ["Launch Agent: Second", "Launch Agent: First"])
      #expect(items.first?.kind == .launchAgentProfile(second.id))
      #expect(items.first?.subtitle?.hasPrefix("Recommended") == true)
      #expect(items.last?.subtitle?.hasPrefix("Recommended") == false)
      #expect(items.first?.agentProfileIconSource == second.iconSource)
      #expect(items.last?.agentProfileIconSource == first.iconSource)
    }
  }

  @Test(.dependencies) func paletteAnnotatesButNeverBlocksUnavailableRuntimes() {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let storage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      let profile = AgentProfile(name: "Codex", runtime: .codex)
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0.agentProfiles = [profile] }

      let items = agentProfileLaunchItems(repositories, launchWarning: { _ in "Codex may not be installed" })

      // The soft heuristic surfaces as a subtitle warning; the row stays a
      // normal, activatable launch item (docs-ai 053/005).
      #expect(items.map(\.title) == ["Launch Agent: Codex"])
      #expect(items.first?.subtitle?.contains("may not be installed") == true)
      #expect(items.first?.kind == .launchAgentProfile(profile.id))
    }
  }

  @Test(.dependencies) func paletteBuildsLaunchItemsForFocusedCanvasCard() {
    let worktree = makeWorktree()
    var repositories = makeRepositoriesState(worktree: worktree)
    // Canvas: no selected terminal worktree, only the focused card passed as
    // the action target.
    repositories.selection = nil
    let storage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      let profile = AgentProfile(name: "Codex", runtime: .codex)
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0.agentProfiles = [profile] }

      #expect(agentProfileLaunchItems(repositories, launchWarning: { _ in nil }).isEmpty)
      let items = agentProfileLaunchItems(
        repositories,
        actionTargetWorktreeID: worktree.id,
        launchWarning: { _ in nil }
      )
      #expect(items.map(\.title) == ["Launch Agent: Codex"])
      #expect(items.first?.subtitle?.contains(worktree.name) == true)
    }
  }

  @Test func actionTargetResolverPrefersSelectionThenExplicitTerminalTarget() {
    let worktree = makeWorktree()
    var repositories = makeRepositoriesState(worktree: worktree)

    // Selection wins over any explicit target.
    #expect(
      repositories.actionTargetTerminalWorktree(explicitTargetID: "unknown")?.id == worktree.id
    )

    // Without a selection, the explicit target resolves through the full
    // terminal-target path — including synthesized plain-folder worktrees.
    repositories.selection = nil
    #expect(
      repositories.actionTargetTerminalWorktree(explicitTargetID: worktree.id)?.id == worktree.id
    )
    let rootURL = URL(fileURLWithPath: "/tmp/plain-folder")
    let plain = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "plain-folder",
      kind: .plain,
      worktrees: []
    )
    repositories.repositories.append(plain)
    #expect(
      repositories.actionTargetTerminalWorktree(explicitTargetID: plain.id)?.workingDirectory
        == rootURL
    )
    #expect(repositories.actionTargetTerminalWorktree(explicitTargetID: nil) == nil)
  }

  @Test(.dependencies) func paletteBuildsLaunchItemsForFocusedPlainFolderCanvasCard() {
    // A runnable plain folder's terminal target ID is its repository ID; the
    // factory must resolve it through the same synthesized-worktree path the
    // launch action uses.
    let rootURL = URL(fileURLWithPath: "/tmp/plain-folder")
    let plain = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "plain-folder",
      kind: .plain,
      worktrees: []
    )
    var repositories = RepositoriesFeature.State()
    repositories.repositories = IdentifiedArray(uniqueElements: [plain])
    repositories.selection = nil
    let storage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      let profile = AgentProfile(name: "Codex", runtime: .codex)
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0.agentProfiles = [profile] }

      let items = agentProfileLaunchItems(
        repositories,
        actionTargetWorktreeID: plain.id,
        launchWarning: { _ in nil }
      )
      #expect(items.map(\.title) == ["Launch Agent: Codex"])
      #expect(items.first?.subtitle?.contains("plain-folder") == true)
    }
  }

  @Test func launchedSurfaceEntryShowsProfileName() {
    var entry = ActiveAgentEntry(
      id: UUID(),
      worktreeID: "/tmp/repo/wt-1",
      worktreeName: "wt-1",
      workingDirectory: nil,
      tabID: TerminalTabID(),
      paneTitle: "codex",
      surfaceID: UUID(),
      paneIndex: 1,
      iconLookupToken: "codex",
      agent: .codex,
      session: nil,
      rawState: .idle,
      displayState: .idle,
      lastChangedAt: Date()
    )
    #expect(entry.displayName == "codex")

    entry.launchProfileName = "Codex · Work"
    #expect(entry.displayName == "Codex · Work")
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    let rootURL = worktree.repositoryRootURL
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: rootURL.lastPathComponent,
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = IdentifiedArray(uniqueElements: [repository])
    repositoriesState.selection = .worktree(worktree.id)
    return repositoriesState
  }
}
