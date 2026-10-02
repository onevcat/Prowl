import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct WindowTitleTests {
  @Test func formatIncludesTabWhenPresent() {
    #expect(WindowTitle.format(repository: "Prowl", tab: "codex") == "Prowl · codex")
  }

  @Test func formatDropsEmptyTab() {
    #expect(WindowTitle.format(repository: "Prowl", tab: nil) == "Prowl")
    #expect(WindowTitle.format(repository: "Prowl", tab: "") == "Prowl")
  }

  @Test func sanitizeRemovesControlCharacters() {
    #expect(WindowTitle.sanitize("codex\nsecret\u{1B}") == "codexsecret")
    #expect(WindowTitle.sanitize("\n\t\u{07}") == nil)
  }

  @Test func computeUsesAppTitleWithoutSelection() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let title = WindowTitle.compute(repositories: RepositoriesFeature.State(), terminalManager: manager)
    #expect(title == "Prowl")
  }

  @Test func computeUsesViewTitlesForCanvasAndArchive() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    var state = RepositoriesFeature.State()

    state.selection = .canvas
    #expect(WindowTitle.compute(repositories: state, terminalManager: manager) == "Canvas")

    state.selection = .archivedWorktrees
    #expect(
      WindowTitle.compute(repositories: state, terminalManager: manager) == "Archived Worktrees"
    )
  }

  @Test func computeFallsBackToAppNameWhenWorktreeHasNoActiveTab() {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktree = makeWorktree(rootURL: rootURL)
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)

    let terminalState = WorktreeTerminalState(runtime: GhosttyRuntime(), worktree: worktree)
    let tabId = terminalState.tabManager.createTab(title: "codex", icon: nil)
    terminalState.tabManager.closeTab(tabId)

    #expect(
      WindowTitle.compute(
        repositories: state,
        terminalState: { id in id == worktree.id ? terminalState : nil }
      ) == "Prowl"
    )

    #expect(
      WindowTitle.compute(
        repositories: state,
        terminalState: { _ in nil }
      ) == "Prowl"
    )
  }

  @Test func computeUsesCustomRepositoryTitleAndSelectedTabTitle() {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktree = makeWorktree(rootURL: rootURL)
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)
    state.repositoryCustomTitles[repository.id] = "Prowl"

    let terminalState = WorktreeTerminalState(runtime: GhosttyRuntime(), worktree: worktree)
    _ = terminalState.tabManager.createTab(title: "codex\nhidden", icon: nil)

    #expect(
      WindowTitle.compute(
        repositories: state,
        terminalState: { id in id == worktree.id ? terminalState : nil }
      ) == "Prowl · codexhidden"
    )
  }

  private func makeWorktree(rootURL: URL) -> Worktree {
    Worktree(
      id: rootURL.appendingPathComponent("main").path(percentEncoded: false),
      name: "main",
      detail: "detail",
      workingDirectory: rootURL.appendingPathComponent("main"),
      repositoryRootURL: rootURL
    )
  }
}
