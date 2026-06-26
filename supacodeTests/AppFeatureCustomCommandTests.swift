import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
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
      UserCustomCommand(
        title: "Test",
        systemImage: "checkmark.circle",
        command: "swift test",
        execution: .shellScript,
        shortcut: nil,
      )
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
        .createTabWithInput(
          worktree,
          input: "swift test",
          runSetupScriptIfNew: false,
          autoCloseOnSuccess: false,
          customCommandName: "Test",
          customCommandIcon: "checkmark.circle"
        )
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
      UserCustomCommand(
        title: "Watch",
        systemImage: "terminal",
        command: "pnpm test --watch",
        execution: .terminalInput,
        shortcut: nil,
      )
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

  @Test(.dependencies) func splitCommandCreatesSplitWithInput() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var state = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    state.selectedCustomCommands = [
      UserCustomCommand(
        title: "Tail",
        systemImage: "doc.text",
        command: "tail -f logs",
        execution: .split,
        splitDirection: .down,
        shortcut: nil,
      )
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
        .createSplitWithInput(
          worktree,
          direction: .down,
          input: "tail -f logs",
          autoCloseOnSuccess: false,
          customCommandName: "Tail",
          customCommandIcon: "doc.text"
        )
      ],
    )
  }

  @Test(.dependencies) func closeOnSuccessFlagIsForwarded() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var state = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    state.selectedCustomCommands = [
      UserCustomCommand(
        title: "Build",
        systemImage: "hammer",
        command: "make build",
        execution: .shellScript,
        closeOnSuccess: true,
        shortcut: nil,
      ),
      UserCustomCommand(
        title: "Lint",
        systemImage: "checkmark",
        command: "make lint",
        execution: .split,
        splitDirection: .right,
        closeOnSuccess: true,
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
    await store.send(.runCustomCommand(1))
    await store.finish()

    #expect(
      sent.value == [
        .createTabWithInput(
          worktree,
          input: "make build",
          runSetupScriptIfNew: false,
          autoCloseOnSuccess: true,
          customCommandName: "Build",
          customCommandIcon: "hammer"
        ),
        .createSplitWithInput(
          worktree,
          direction: .right,
          input: "make lint",
          autoCloseOnSuccess: true,
          customCommandName: "Lint",
          customCommandIcon: "checkmark"
        ),
      ],
    )
  }

  @Test func userCustomCommandDecodesWithoutNewFields() throws {
    let legacyJSON = """
      {
        "id": "abc",
        "title": "Legacy",
        "systemImage": "terminal",
        "command": "echo hi",
        "execution": "shellScript"
      }
      """
    let data = Data(legacyJSON.utf8)
    let decoded = try JSONDecoder().decode(UserCustomCommand.self, from: data)
    #expect(decoded.splitDirection == .right)
    #expect(decoded.closeOnSuccess == false)
    #expect(decoded.execution == .shellScript)
  }

  @Test func userCustomCommandDecodesScriptProfileID() throws {
    let data = Data(
      """
      {
        "id": "abc",
        "title": "Profile",
        "systemImage": "terminal",
        "command": "",
        "scriptProfileID": " build-profile ",
        "execution": "shellScript"
      }
      """.utf8
    )

    let decoded = try JSONDecoder().decode(UserCustomCommand.self, from: data)

    #expect(decoded.scriptProfileID == "build-profile")
    #expect(decoded.hasRunnableCommand)
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

  @Test(.dependencies) func supportsCustomCommandBeyondLegacyThreeItemLimit() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var state = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    state.selectedCustomCommands = [
      UserCustomCommand(
        title: "One",
        systemImage: "1.circle",
        command: "echo one",
        execution: .shellScript,
        shortcut: nil,
      ),
      UserCustomCommand(
        title: "Two",
        systemImage: "2.circle",
        command: "echo two",
        execution: .shellScript,
        shortcut: nil,
      ),
      UserCustomCommand(
        title: "Three",
        systemImage: "3.circle",
        command: "echo three",
        execution: .shellScript,
        shortcut: nil,
      ),
      UserCustomCommand(
        title: "Four",
        systemImage: "4.circle",
        command: "echo four",
        execution: .shellScript,
        shortcut: nil,
      ),
      UserCustomCommand(
        title: "Five",
        systemImage: "5.circle",
        command: "echo five",
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

    await store.send(.runCustomCommand(4))
    await store.finish()

    #expect(
      sent.value == [
        .createTabWithInput(
          worktree,
          input: "echo five",
          runSetupScriptIfNew: false,
          autoCloseOnSuccess: false,
          customCommandName: "Five",
          customCommandIcon: "5.circle"
        )
      ],
    )
  }

  @Test(.dependencies) func defaultTerminalIconIsTreatedAsUnsetForAutoDetection() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var state = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    state.selectedCustomCommands = [
      UserCustomCommand(
        title: "Default",
        systemImage: "terminal",
        command: "npm test",
        execution: .shellScript,
        shortcut: nil,
      )
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

    // The model's "terminal" placeholder should not be pinned as a
    // script icon — the auto-detector should remain free to brand the
    // tab from the executed command itself.
    #expect(
      sent.value == [
        .createTabWithInput(
          worktree,
          input: "npm test",
          runSetupScriptIfNew: false,
          autoCloseOnSuccess: false,
          customCommandName: "Default",
          customCommandIcon: nil
        )
      ],
    )
  }

  @Test(.dependencies) func emptyIconIsTreatedAsUnsetForAutoDetection() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var state = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    state.selectedCustomCommands = [
      UserCustomCommand(
        title: "Blank",
        systemImage: "   ",
        command: "swift test",
        execution: .shellScript,
        shortcut: nil,
      )
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
        .createTabWithInput(
          worktree,
          input: "swift test",
          runSetupScriptIfNew: false,
          autoCloseOnSuccess: false,
          customCommandName: "Blank",
          customCommandIcon: nil
        )
      ],
    )
  }

  @Test(.dependencies) func loadingUserSettingsKeepsCustomCommandsWithoutScript() async {
    let worktree = makeWorktree()
    let settings = UserRepositorySettings(
      customCommands: [
        UserCustomCommand(
          title: "Empty",
          systemImage: "sparkles",
          command: "",
          execution: .shellScript,
          shortcut: nil
        ),
        UserCustomCommand(
          title: "Runnable",
          systemImage: "terminal",
          command: "echo hello",
          execution: .shellScript,
          shortcut: nil
        ),
      ]
    )

    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.worktreeUserSettingsLoaded(settings, worktreeID: worktree.id)) {
      $0.selectedCustomCommands = settings.customCommands
      $0.resolvedKeybindings = KeybindingResolver.resolve(
        schema: .appResolverSchema(customCommands: settings.customCommands),
        migratedOverrides:
          LegacyCustomCommandShortcutMigration
          .migrate(commands: settings.customCommands)
          .overrides
      )
    }
  }

  @Test(.dependencies) func customCommandUsesCanvasFocusedWorktree() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var repositories = makeRepositoriesState(worktree: worktree)
    repositories.selection = .canvas
    var state = AppFeature.State(
      repositories: repositories,
      settings: SettingsFeature.State()
    )
    state.selectedCustomCommands = [
      UserCustomCommand(
        title: "Canvas Build",
        systemImage: "hammer",
        command: "make build",
        execution: .shellScript,
        shortcut: nil
      )
    ]

    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.canvasFocusedWorktreeID = { worktree.id }
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.runCustomCommand(0))
    await store.finish()

    #expect(
      sent.value == [
        .createTabWithInput(
          worktree,
          input: "make build",
          runSetupScriptIfNew: false,
          autoCloseOnSuccess: false,
          customCommandName: "Canvas Build",
          customCommandIcon: "hammer"
        )
      ]
    )
  }

  @Test(.dependencies) func canvasFocusLoadsFocusedWorktreeCustomCommands() async {
    let worktree = makeWorktree()
    var repositories = makeRepositoriesState(worktree: worktree)
    repositories.selection = .canvas
    let settings = UserRepositorySettings(
      customCommands: [
        UserCustomCommand(
          title: "Canvas Test",
          systemImage: "checkmark.circle",
          command: "swift test",
          execution: .terminalInput,
          shortcut: nil
        )
      ]
    )
    let store = withDependencies {
      $0.defaultFileStorage = .inMemory
    } operation: {
      @Shared(.userRepositorySettings(worktree.repositoryRootURL)) var userRepositorySettings
      $userRepositorySettings.withLock { $0 = settings }
      return TestStore(
        initialState: AppFeature.State(
          repositories: repositories,
          settings: SettingsFeature.State()
        )
      ) {
        AppFeature()
      } withDependencies: {
        $0.terminalClient.canvasFocusedWorktreeID = { worktree.id }
      }
    }

    // Canvas focus applies both repository and user settings in a single reduce
    // pass so the toolbar updates atomically with the focus change.
    await store.send(.canvasFocusedWorktreeChanged(worktree.id)) {
      $0.openActionSelection = expectedDefaultOpenAction()
      $0.selectedCustomCommands = settings.customCommands
      $0.resolvedKeybindings = KeybindingResolver.resolve(
        schema: .appResolverSchema(customCommands: settings.customCommands),
        migratedOverrides:
          LegacyCustomCommandShortcutMigration
          .migrate(commands: settings.customCommands)
          .overrides
      )
    }
    await store.finish()
  }

  @Test(.dependencies) func canvasFocusWithMultipleReposUsesPrimaryFocusedWorktree() async {
    let worktreeA = makeWorktree(id: "/tmp/repo-a/wt-a", name: "wt-a", repoRoot: "/tmp/repo-a")
    let worktreeB = makeWorktree(id: "/tmp/repo-b/wt-b", name: "wt-b", repoRoot: "/tmp/repo-b")
    let commandA = UserCustomCommand(
      title: "Repo A Build",
      systemImage: "a.circle",
      command: "make repo-a",
      execution: .shellScript,
      shortcut: nil
    )
    let commandB = UserCustomCommand(
      title: "Repo B Build",
      systemImage: "b.circle",
      command: "make repo-b",
      execution: .shellScript,
      shortcut: nil
    )
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = withDependencies {
      $0.defaultFileStorage = .inMemory
    } operation: {
      @Shared(.repositorySettings(worktreeA.repositoryRootURL)) var repositorySettingsA
      @Shared(.repositorySettings(worktreeB.repositoryRootURL)) var repositorySettingsB
      @Shared(.userRepositorySettings(worktreeA.repositoryRootURL)) var userRepositorySettingsA
      @Shared(.userRepositorySettings(worktreeB.repositoryRootURL)) var userRepositorySettingsB
      $repositorySettingsA.withLock { $0.runScript = "npm run repo-a" }
      $repositorySettingsB.withLock { $0.runScript = "npm run repo-b" }
      $userRepositorySettingsA.withLock { $0.customCommands = [commandA] }
      $userRepositorySettingsB.withLock { $0.customCommands = [commandB] }

      var repositories = makeRepositoriesState(worktrees: [worktreeA, worktreeB])
      repositories.selection = .canvas
      var state = AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
      state.selectedRunScript = "npm run repo-a"
      state.selectedCustomCommands = [commandA]

      return TestStore(initialState: state) {
        AppFeature()
      } withDependencies: {
        $0.terminalClient.canvasFocusedWorktreeID = { worktreeB.id }
        $0.terminalClient.send = { command in
          sent.withValue { $0.append(command) }
        }
      }
    }

    await store.send(.canvasFocusedWorktreeChanged(worktreeB.id)) {
      $0.openActionSelection = expectedDefaultOpenAction()
      $0.selectedRunScript = "npm run repo-b"
      $0.selectedCustomCommands = [commandB]
      $0.resolvedKeybindings = KeybindingResolver.resolve(
        schema: .appResolverSchema(customCommands: [commandB]),
        migratedOverrides:
          LegacyCustomCommandShortcutMigration
          .migrate(commands: [commandB])
          .overrides
      )
    }

    await store.send(.runScript)
    await store.send(.runCustomCommand(0))
    await store.finish()

    #expect(
      sent.value == [
        .runScript(worktreeB, script: "npm run repo-b"),
        .createTabWithInput(
          worktreeB,
          input: "make repo-b",
          runSetupScriptIfNew: false,
          autoCloseOnSuccess: false,
          customCommandName: "Repo B Build",
          customCommandIcon: "b.circle"
        ),
      ]
    )
  }

  private func makeWorktree() -> Worktree {
    makeWorktree(id: "/tmp/repo/wt-1", name: "wt-1", repoRoot: "/tmp/repo")
  }

  private func makeWorktree(id: String, name: String, repoRoot: String) -> Worktree {
    Worktree(
      id: id,
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    makeRepositoriesState(worktrees: [worktree])
  }

  private func makeRepositoriesState(worktrees: [Worktree]) -> RepositoriesFeature.State {
    let worktreesByRepository = Dictionary(
      grouping: worktrees,
      by: { $0.repositoryRootURL.path(percentEncoded: false) }
    )
    let repositories =
      worktreesByRepository.keys.sorted().compactMap { rootPath in
        worktreesByRepository[rootPath].map { worktrees in
          let rootURL = URL(fileURLWithPath: rootPath)
          return Repository(
            id: rootPath,
            rootURL: rootURL,
            name: rootURL.lastPathComponent,
            worktrees: IdentifiedArray(uniqueElements: worktrees)
          )
        }
      }
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = IdentifiedArray(uniqueElements: repositories)
    repositoriesState.selection = worktrees.first.map { .worktree($0.id) }
    return repositoriesState
  }

  private func expectedDefaultOpenAction() -> OpenWorktreeAction {
    OpenWorktreeAction.fromSettingsID(
      RepositorySettings.default.openActionID,
      defaultEditorID: OpenWorktreeAction.normalizedDefaultEditorID(
        SettingsFile.default.global.defaultEditorID
      )
    )
  }
}
