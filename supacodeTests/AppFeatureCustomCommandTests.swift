import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct AppFeatureCustomCommandTests {
  @Test(.dependencies) func shellScriptCommandCreatesTabWithInput() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var state = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    state.selectedCustomCommands = [
      OnevcatCustomCommand(
        title: "Test",
        systemImage: "checkmark.circle",
        command: "swift test",
        execution: .shellScript,
        shortcut: nil,
      ),
    ]

    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.runCustomCommand(0))
    await store.finish()

    #expect(
      sent.value == [
        .createTabWithInput(worktree, input: "swift test", runSetupScriptIfNew: false)
      ],
    )
  }

  @Test(.dependencies) func terminalInputCommandSendsRawCommandText() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var state = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    state.selectedCustomCommands = [
      OnevcatCustomCommand(
        title: "Watch",
        systemImage: "terminal",
        command: "pnpm test --watch",
        execution: .terminalInput,
        shortcut: nil,
      ),
    ]

    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.runCustomCommand(0))
    await store.finish()

    #expect(
      sent.value == [
        .insertText(worktree, text: "pnpm test --watch")
      ],
    )
  }

  @Test(.dependencies) func invalidCommandIndexDoesNothing() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let state = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )

    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.runCustomCommand(0))
    await store.finish()

    #expect(sent.value.isEmpty)
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
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree]
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    return repositoriesState
  }
}
