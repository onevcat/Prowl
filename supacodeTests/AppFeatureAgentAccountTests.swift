import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import supacode

@MainActor
struct AppFeatureAgentAccountTests {
  /// Sign In creates the account's directories for real, so tests use their own
  /// name and remove it.
  private let account = "prowl-test-\(UUID().uuidString)"

  private func removeAccountDirectory() {
    try? FileManager.default.removeItem(at: SupacodePaths.agentAccountsDirectory.appending(path: account))
  }
  @Test(.dependencies) func signInOpensAPaneRunningTheAccountsOwnLoginCommand() async throws {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }

    await store.send(.settings(.delegate(.agentAccountAuth(account: account, cli: .claude, action: .signIn))))
    await store.finish()
    defer { removeAccountDirectory() }

    let command = try #require(
      sent.value.compactMap { command -> String? in
        guard case .createTabWithInput(_, let input, _, _, _, _, _) = command else { return nil }
        return input
      }.first
    )
    // The pane it lands in may resolve to a different account.
    #expect(command.hasPrefix("CLAUDE_CONFIG_DIR='"))
    #expect(command.contains("/accounts/\(account)/claude'"))
    #expect(command.hasSuffix(" claude auth login"))
  }

  @Test(.dependencies) func signOutRunsTheLogoutCommandForTheChosenCLI() async throws {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }

    await store.send(.settings(.delegate(.agentAccountAuth(account: account, cli: .codex, action: .signOut))))
    await store.finish()
    defer { removeAccountDirectory() }

    let command = try #require(
      sent.value.compactMap { command -> String? in
        guard case .createTabWithInput(_, let input, _, _, _, _, _) = command else { return nil }
        return input
      }.first
    )
    #expect(command.hasPrefix("CODEX_HOME='"))
    #expect(command.hasSuffix(" codex logout"))
  }

  /// Without a repository there is no pane to run the login in.
  @Test(.dependencies) func signInWithoutARepositoryWarnsInsteadOfOpeningAPane() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off

    await store.send(.settings(.delegate(.agentAccountAuth(account: account, cli: .claude, action: .signIn))))
    await store.receive(\.repositories.showToast)
    await store.finish()

    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func openingAccountSettingsSelectsTheAdvancedPane() async {
    let shown = LockIsolated(0)
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0[SettingsWindowClient.self] = SettingsWindowClient { shown.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off

    await store.send(.openAgentAccountSettings)
    await store.receive(\.settings.setSelection) {
      $0.settings.selection = .advanced
    }
    await store.finish()

    #expect(shown.value == 1)
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/worktree",
      name: "worktree",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/worktree"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = IdentifiedArray(
      uniqueElements: [
        Repository(
          id: worktree.repositoryRootURL.path(percentEncoded: false),
          rootURL: worktree.repositoryRootURL,
          name: worktree.repositoryRootURL.lastPathComponent,
          worktrees: IdentifiedArray(uniqueElements: [worktree])
        )
      ]
    )
    repositoriesState.selection = .worktree(worktree.id)
    return repositoriesState
  }
}
