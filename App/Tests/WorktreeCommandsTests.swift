import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct WorktreeCommandsTests {
  @Test func codeHostWorktreeIDUsesCanvasFocusedWorktreeInCanvasMode() {
    let rootPath = "/tmp/repo-canvas-command-code-host"
    let worktree = Self.makeWorktree(id: "\(rootPath)/wt-1", name: "feature/canvas", repoRoot: rootPath)
    let repository = Self.makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = SidebarSelection.canvas

    let result = codeHostWorktreeID(
      repositories: state,
      canvasFocusedWorktreeID: worktree.id
    )

    #expect(result == worktree.id)
  }

  @Test func codeHostWorktreeIDRequiresCodeHostSupport() {
    let repository = Repository(
      id: "/tmp/plain-folder-code-host",
      rootURL: URL(fileURLWithPath: "/tmp/plain-folder-code-host"),
      name: "Folder",
      kind: .plain,
      worktrees: []
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = SidebarSelection.canvas

    let result = codeHostWorktreeID(
      repositories: state,
      canvasFocusedWorktreeID: repository.id
    )

    #expect(result == nil)
  }

  @Test func renameBranchCommandTargetUsesCanvasFocusedWorktree() {
    let rootPath = "/tmp/repo-canvas-command-rename"
    let worktree = Self.makeWorktree(id: "\(rootPath)/wt-1", name: "feature/canvas", repoRoot: rootPath)
    let repository = Self.makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var repositories = RepositoriesFeature.State(repositories: [repository])
    repositories.selection = .canvas
    let state = AppFeature.State(repositories: repositories)

    let result = renameBranchCommandTargetID(
      appState: state,
      canvasFocusedWorktreeID: worktree.id
    )

    #expect(result == worktree.id)
  }

  @Test func renameBranchCommandTargetRejectsMultiSelection() {
    let rootPath = "/tmp/repo-multi-command-rename"
    let worktreeA = Self.makeWorktree(id: "\(rootPath)/wt-a", name: "a", repoRoot: rootPath)
    let worktreeB = Self.makeWorktree(id: "\(rootPath)/wt-b", name: "b", repoRoot: rootPath)
    let repository = Self.makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktreeA, worktreeB])
    var repositories = RepositoriesFeature.State(repositories: [repository])
    repositories.selection = .worktree(worktreeA.id)
    repositories.sidebarSelectedWorktreeIDs = [worktreeA.id, worktreeB.id]
    let state = AppFeature.State(repositories: repositories)

    let result = renameBranchCommandTargetID(appState: state, canvasFocusedWorktreeID: nil)

    #expect(result == nil)
  }

  @Test func renameBranchCommandTargetRejectsUnresolvedSelection() {
    var repositories = RepositoriesFeature.State()
    repositories.selection = .worktree("/tmp/repo-pending-command-rename/pending")
    repositories.sidebarSelectedWorktreeIDs = ["/tmp/repo-pending-command-rename/pending"]
    let state = AppFeature.State(repositories: repositories)

    let result = renameBranchCommandTargetID(appState: state, canvasFocusedWorktreeID: nil)

    #expect(result == nil)
  }

  @Test func renameBranchCommandTargetRejectsBlockingSheet() {
    let rootPath = "/tmp/repo-modal-command-rename"
    let worktree = Self.makeWorktree(id: "\(rootPath)/wt-1", name: "feature/modal", repoRoot: rootPath)
    let repository = Self.makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var repositories = RepositoriesFeature.State(repositories: [repository])
    repositories.selection = .worktree(worktree.id)
    repositories.sidebarSelectedWorktreeIDs = [worktree.id]
    repositories.deleteWorktreeConfirmation = DeleteWorktreeConfirmation(
      id: 0,
      title: "Delete worktree?",
      message: "Delete the worktree?",
      targets: [],
      deleteBranch: false
    )
    let state = AppFeature.State(repositories: repositories)

    let result = renameBranchCommandTargetID(appState: state, canvasFocusedWorktreeID: nil)

    #expect(result == nil)
  }

  private static func makeWorktree(id: String, name: String, repoRoot: String) -> Worktree {
    Worktree(
      id: id,
      name: name,
      detail: id,
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
  }

  private static func makeRepository(rootPath: String, name: String, worktrees: [Worktree]) -> Repository {
    Repository(
      id: rootPath,
      rootURL: URL(fileURLWithPath: rootPath),
      name: name,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }
}
