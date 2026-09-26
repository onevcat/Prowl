import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct AppFeatureWorkspaceEditingTests {
  private func makeWorkspaceRepository(id: String) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: "Workspace",
      kind: .plain,
      worktrees: [],
      workspace: ProjectWorkspace(
        title: "Workspace",
        repositories: [ProjectWorkspaceRepositoryEntry(id: "app", name: "App", path: "app")])
    )
  }

  @Test(.dependencies) func settingsEditWorkspaceSurfacesMainWindowAndOpensEditor() async {
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [makeWorkspaceRepository(id: "/tmp/ws")]
    let surfaced = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.appLifecycleClient.surfaceMainWindow = {
        surfaced.withValue { $0 = true }
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.settings(.delegate(.editWorkspace("/tmp/ws"))))
    // Surfacing must already have happened when the request is dispatched,
    // so the sheet never attaches to a hidden or minimized main window.
    #expect(surfaced.value)
    await store.receive(\.repositories.workspaceEditing.promptRequested)
    await store.finish()
  }

  @Test(.dependencies) func settingsEditWorkspaceIgnoresNonWorkspaceRepositories() async {
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [
      Repository(id: "/tmp/git", rootURL: URL(fileURLWithPath: "/tmp/git"), name: "Git", kind: .git, worktrees: [])
    ]
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    ) {
      AppFeature()
    }

    await store.send(.settings(.delegate(.editWorkspace("/tmp/git"))))
  }

  @Test(.dependencies) func repositorySettingsEditTappedBubblesToSettingsDelegate() async {
    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: URL(fileURLWithPath: "/tmp/ws"),
        repositoryID: "/tmp/ws",
        repositoryKind: .plain,
        workspace: ProjectWorkspace(title: "Workspace"),
        settings: .default,
        userSettings: .default)
    ) {
      RepositorySettingsFeature()
    }

    await store.send(.editWorkspaceTapped)
    await store.receive(\.delegate.editWorkspace)
  }

  @Test(.dependencies) func paletteEditWorkspaceDispatchesPromptRequest() async {
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [makeWorkspaceRepository(id: "/tmp/ws")]
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.editWorkspace("/tmp/ws"))))
    await store.receive(\.repositories.workspaceEditing.promptRequested)
  }

  @Test func paletteOffersEditWorkspaceOnlyForSelectedWorkspace() {
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [
      makeWorkspaceRepository(id: "/tmp/ws"),
      Repository(id: "/tmp/git", rootURL: URL(fileURLWithPath: "/tmp/git"), name: "Git", kind: .git, worktrees: []),
    ]
    repositoriesState.selection = .repository("/tmp/ws")

    let workspaceItems = CommandPaletteFeature.commandPaletteItems(from: repositoriesState)
    #expect(workspaceItems.contains { $0.kind == .editWorkspace("/tmp/ws") })

    repositoriesState.selection = .repository("/tmp/git")
    let repositoryItems = CommandPaletteFeature.commandPaletteItems(from: repositoriesState)
    #expect(!repositoryItems.contains { $0.kind == .editWorkspace("/tmp/git") })
    #expect(!repositoryItems.contains { $0.kind == .editWorkspace("/tmp/ws") })
  }
}
