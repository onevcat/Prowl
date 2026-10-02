import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct GitEnvironmentRecoveryTests {
  @Test func wrappedToolchainErrorIsNotProofOfPlainFolder() {
    let error = GitClientError.commandFailed(
      command: "wt root",
      message: "xcrun: error: missing DEVELOPER_DIR path: /missing\nerror: not a git repository")
    #expect(!RepositoriesFeature.isNotGitRepositoryError(error))
  }

  @Test(.dependencies, arguments: [false, true])
  func plainFolderCanEnterShelfFromCanvas(staleSelection: Bool) async {
    let root = URL(fileURLWithPath: "/tmp/plain-shelf")
    let repo = Repository(id: root.path, rootURL: root, name: "plain-shelf", kind: .plain, worktrees: [])
    var state = RepositoriesFeature.State(repositories: [repo])
    state.selection = .canvas
    if staleSelection { state.preCanvasWorktreeID = "/tmp/removed-worktree" }
    let store = TestStore(initialState: state) { RepositoriesFeature() }
    await store.send(.toggleShelf) {
      $0.isShelfActive = true
      $0.pendingTerminalFocusWorktreeIDs = [repo.id]
    }
    await store.receive(\.selectRepository) {
      $0.selection = .repository(repo.id)
      $0.openedWorktreeIDs = [repo.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }
  @Test(.dependencies) func unavailableGitKeepsPersistedRepositoryKind() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = RepositoryEntryNormalizer.normalize([
      PersistedRepositoryEntry(path: root.path(percentEncoded: false), kind: .git)
    ])
    let upgraded = await withDependencies {
      $0.gitClient.repoRoot = { _ in throw GitClientError.unavailable(details: "xcrun failed") }
      $0.repositoryPersistence.saveRepositoryEntries = { _ in Issue.record("Failure must not persist a type change") }
    } operation: {
      await RepositoriesFeature().upgradedRepositoryEntriesIfNeeded(entries)
    }
    #expect(upgraded == entries)
    let (repositories, failures) = await withDependencies {
      $0.gitClient.worktrees = { _ in throw GitClientError.unavailable(details: "xcrun failed") }
    } operation: {
      await RepositoriesFeature().loadRepositoriesData(entries)
    }
    #expect(repositories.isEmpty)
    #expect(failures.count == 1)
    #expect(failures.first?.isGitUnavailable == true)
    #expect(failures.first?.message.contains("Check your Git installation") == true)
  }

  @Test(.dependencies) func failureDetailsOfferRetryAndCopy() async {
    var state = RepositoriesFeature.State()
    let id = "/tmp/repo"
    state.loadFailuresByID[id] = "Git unavailable details"
    state.gitUnavailableRepositoryIDs = [id]
    let store = TestStore(initialState: state) { RepositoriesFeature() }
    await store.send(.showRepositoryLoadFailure(id)) {
      $0.alert = AlertState {
        TextState("Git is unavailable")
      } actions: {
        ButtonState(action: .retryRepositoryLoad) { TextState("Retry") }
        ButtonState(action: .copyRepositoryLoadFailure("/tmp/repo\n\nGit unavailable details")) {
          TextState("Copy Details")
        }
        ButtonState(role: .cancel) { TextState("OK") }
      } message: {
        TextState("Git unavailable details")
      }
    }
    await store.send(.alert(.presented(.retryRepositoryLoad)))
    await store.receive(\.refreshWorktrees) { $0.isRefreshingWorktrees = true }
    await store.receive(\.reloadRepositories) {
      $0.alert = nil
      $0.isRefreshingWorktrees = false
    }
    await store.finish()
  }

}

nonisolated extension GitExecutable {
  static let testExecutable = GitExecutable(url: URL(fileURLWithPath: "/usr/bin/git"), searchPath: "/usr/bin:/bin")
}
