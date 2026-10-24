import ComposableArchitecture
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import ProwlCLIShared
import Sharing
import Testing

@testable import Prowl

/// The UI gates of remote folders and the toolbar status of their connection
/// (docs-ai 084 A4b, C1c).
@MainActor
struct RemoteFolderUIGateTests {
  private static let profile = HostProfile(
    id: RemoteRepositoryFixtures.hostProfileID, alias: "mini", recipe: SSHConnectionRecipe(destination: "mini"),
    connectionKey: ConnectionKey(user: "dev", hostname: "mini.local"))

  private static let workflow = WorkflowStartCatalogItem(
    key: "user/review", scope: .user, fileURL: URL(filePath: "/tmp/review.pwlworkflow"), workflowID: "review",
    name: "Review", workflowDescription: nil, icon: nil, validationFailure: nil)

  private static func localState() -> RepositoriesFeature.State {
    let root = RepositoryLocation.local(URL(filePath: "/tmp/prowl-gate/"))
    let main = Worktree(name: "main", detail: "", location: root, repositoryLocation: root)
    var state = RepositoriesFeature.State()
    state.repositories = [Repository(location: root, name: "app", worktrees: [main])]
    state.repositoryRoots = [root]
    state.selection = .worktree(main.id)
    return state
  }

  private static func remoteState() -> RepositoriesFeature.State {
    let repository = RemoteRepositoryFixtures.gitRepository()
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    state.repositoryRoots = [repository.location]
    state.selection = .worktree(repository.worktrees[0].id)
    return state
  }

  @Test func openActionsNeedFinderOrAnApp() {
    #expect(OpenWorktreeAction.finder.repositoryFeature == .finder)
    #expect(OpenWorktreeAction.editor.repositoryFeature == .openInEditor)
  }

  /// The selected remote folder shows its host and how it answers, after the focused
  /// pane's side channel and before the pull request.
  @Test(.dependencies) func theToolbarShowsTheConnectionOfTheSelectedRemoteFolder() throws {
    @Shared(.hostProfiles) var hostProfiles: [HostProfile]
    $hostProfiles.withLock { $0 = [Self.profile] }
    var state = Self.remoteState()
    let worktree = try #require(state.repositories.first?.worktrees.first)

    let connected = try #require(RemoteFolderToolbarStatus(worktree: worktree, repositories: state))
    #expect(connected == RemoteFolderToolbarStatus(hostProfileID: Self.profile.id, alias: "mini", hostStatus: nil))
    state.pollUnreachableRepositoryIDs = [worktree.repositoryLocation.id]
    #expect(RemoteFolderToolbarStatus(worktree: worktree, repositories: state)?.hostStatus == .unreachable)
    state.rebindHostProfileIDs = [Self.profile.id]
    #expect(
      RemoteFolderToolbarStatus(worktree: worktree, repositories: state)?.hostStatus == .needsRebind(Self.profile.id))

    let local = Worktree(
      name: "main", detail: "", location: .local(URL(filePath: "/tmp/app/")),
      repositoryLocation: .local(URL(filePath: "/tmp/app/")))
    #expect(RemoteFolderToolbarStatus(worktree: local, repositories: state) == nil)

    let workflow = WorkflowStatusCenterPresentation(state: .init(), selectedWorktreeID: nil, now: .distantPast)
    #expect(
      ToolbarStatusSelection(toast: nil, workflow: workflow, pullRequest: nil, remoteFolder: connected)
        == .remoteFolder(connected))
    let unreachable = RemoteFolderToolbarStatus(hostProfileID: Self.profile.id, alias: "mini", hostStatus: .unreachable)
    #expect(
      ToolbarStatusSelection(toast: nil, workflow: workflow, pullRequest: nil, remoteFolder: unreachable)
        == .remoteFolder(unreachable))
    // A plain remote folder holds no connection, and shows no status.
    var plainState = state
    let plain = RemoteRepositoryFixtures.plainFolder()
    plainState.repositories.append(plain)
    let plainWorktree = Worktree(
      name: "notes", detail: "", location: plain.location, repositoryLocation: plain.location)
    #expect(RemoteFolderToolbarStatus(worktree: plainWorktree, repositories: plainState) == nil)
    // A folder whose host profile is missing cannot connect, and shows no status.
    $hostProfiles.withLock { $0 = [] }
    #expect(RemoteFolderToolbarStatus(worktree: worktree, repositories: state) == nil)
    let channel = try #require(
      RemoteChannelToolbarStatus(
        .connected(host: "mini", ssh: LocalProcessGeneration(pid: 1, startedAt: Date(timeIntervalSince1970: 1)))))
    #expect(
      ToolbarStatusSelection(
        toast: nil, workflow: workflow, pullRequest: nil, remoteChannel: channel, remoteFolder: connected)
        == .remoteChannel(channel))
  }

  /// The palette leaves out what a remote folder cannot do: Finder, In Place custom
  /// commands, Agent Profiles and workflows. Copy Path, Run Script, tab and split custom
  /// commands stay (docs-ai 084 C3c, C4).
  @Test(.dependencies) func thePaletteLeavesOutWhatARemoteFolderCannotDo() {
    let state = Self.remoteState()
    let commands = [
      EffectiveCustomCommand(
        source: .global,
        command: UserCustomCommand(
          id: "build", title: "Build", systemImage: "hammer", command: "make", execution: .shellScript, shortcut: nil)),
      EffectiveCustomCommand(
        source: .global,
        command: UserCustomCommand(
          id: "watch", title: "Watch", systemImage: "eye", command: "make watch", execution: .split, shortcut: nil)),
      EffectiveCustomCommand(
        source: .global,
        command: UserCustomCommand(
          id: "type", title: "Type", systemImage: "keyboard", command: "ls", execution: .terminalInput, shortcut: nil)),
    ]
    let items = CommandPaletteFeature.commandPaletteItems(from: state, customCommands: commands)
    let kinds = items.map(\.kind)

    #expect(kinds.contains(.copyPath))
    #expect(!kinds.contains(.revealInFinder))
    #expect(kinds.contains(.runScript))
    let customIDs = kinds.compactMap { kind -> EffectiveCustomCommand.Identifier? in
      if case .runCustomCommand(let id, _) = kind { id } else { nil }
    }
    #expect(customIDs == commands.prefix(2).map(\.id))
    @Shared(.userGlobalSettings) var globalSettings
    $globalSettings.withLock {
      $0.agentProfiles = [AgentProfile(id: UUID(), name: "Codex", runtime: .codex)]
    }
    #expect(!agentProfileLaunchItems(Self.localState()).isEmpty)
    #expect(agentProfileLaunchItems(state).isEmpty)
    #expect(
      workflowCommandItems(
        [Self.workflow], repositories: state, actionTargetWorktreeID: state.selectedWorktreeID
      ).isEmpty)
  }

  /// A selected remote plain folder has no worktree ID; the palette filters by its terminal
  /// target, as the actions do: no In Place command. A local plain folder keeps it.
  @Test(.dependencies) func thePaletteFiltersASelectedRemotePlainFolder() {
    let command = EffectiveCustomCommand(
      source: .global,
      command: UserCustomCommand(
        id: "type", title: "Type", systemImage: "keyboard", command: "ls", execution: .terminalInput, shortcut: nil))
    func hasCustomCommand(_ folder: Repository) -> Bool {
      var state = RepositoriesFeature.State()
      state.repositories = [folder]
      state.repositoryRoots = [folder.location]
      state.selection = .repository(folder.id)
      return CommandPaletteFeature.commandPaletteItems(from: state, customCommands: [command]).contains {
        if case .runCustomCommand = $0.kind { true } else { false }
      }
    }
    let local = Repository(
      location: .local(URL(filePath: "/tmp/prowl-plain/")), name: "plain", kind: .plain, worktrees: [])

    #expect(!hasCustomCommand(RemoteRepositoryFixtures.plainFolder()))
    #expect(hasCustomCommand(local))
  }

  /// A refused login or a changed host key is not "connected": the toolbar and the sidebar
  /// show the reason until a poll succeeds.
  @Test(.dependencies) func aFailedLoginShowsTheFolderAsNotConnected() async throws {
    @Shared(.hostProfiles) var hostProfiles: [HostProfile]
    $hostProfiles.withLock { $0 = [Self.profile] }
    var state = Self.remoteState()
    let repository = try #require(state.repositories.first)
    state.remoteRefreshRepositoryIDs = [repository.id]
    state.remoteRefreshInFlightIDs = [repository.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    let reason = "The remote host refused the SSH login."

    await store.send(
      .remoteRepositoryRefreshed(
        repository.id, .failed(message: reason, isHostUnreachable: false, isConnectionFailure: true)))
    #expect(store.state.remoteHostStatus(for: repository.id) == .connectionFailed(reason))
    let worktree = repository.worktrees[0]
    #expect(
      RemoteFolderToolbarStatus(worktree: worktree, repositories: store.state)?.hostStatus == .connectionFailed(reason))

    await store.send(
      .remoteRepositoryRefreshed(repository.id, .failed(message: "git failed", isHostUnreachable: false)))
    #expect(store.state.remoteHostStatus(for: repository.id) == nil)
  }

  @Test func connectionFailuresAreThoseTheUserMustFix() {
    #expect(isRemoteConnectionFailure(RemoteRepositoryHostError.connection(.authentication)))
    #expect(isRemoteConnectionFailure(RemoteRepositoryRefreshError.connection(.hostKey)))
    #expect(isRemoteConnectionFailure(RemoteRepositoryHostError.sideChannelDisabled))
    #expect(isRemoteConnectionFailure(RemoteRepositoryHostError.configurationRejected))
    #expect(!isRemoteConnectionFailure(RemoteRepositoryHostError.connection(.unreachable)))
    #expect(!isRemoteConnectionFailure(RemoteRepositoryHostError.authorityChanged))
    #expect(!isRemoteConnectionFailure(RemoteRepositoryHostError.gitMissing))
  }

  /// A script or a custom command in a remote folder runs there (docs-ai 084 C3c), a split
  /// command too (C4), but not an In Place command (the focused pane may be the local shell
  /// or a password prompt): it shows its reason and sends nothing.
  @Test(.dependencies) func scriptsAndCustomCommandsRunInARemoteFolderButInPlaceDoesNot() async {
    var state = AppFeature.State(repositories: Self.remoteState(), settings: SettingsFeature.State())
    state.selectedRunScript = "make dev"
    state.selectedCustomCommands = [
      EffectiveCustomCommand(
        source: .global,
        command: UserCustomCommand(
          id: "build", title: "Build", systemImage: "hammer", command: "make", execution: .shellScript, shortcut: nil)),
      EffectiveCustomCommand(
        source: .global,
        command: UserCustomCommand(
          id: "watch", title: "Watch", systemImage: "eye", command: "make watch", execution: .split, shortcut: nil)),
      EffectiveCustomCommand(
        source: .global,
        command: UserCustomCommand(
          id: "type", title: "Type", systemImage: "keyboard", command: "ls", execution: .terminalInput, shortcut: nil)),
    ]
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off

    await store.send(.runScript)
    await store.send(.runCustomCommand(state.selectedCustomCommands[0].id))
    await store.finish()
    let commands = sent.value
    #expect(commands.contains { if case .runScript = $0 { true } else { false } })
    #expect(
      commands.contains {
        if case .createTabWithInput(_, let input, _, _, let autoClose, let name, _) = $0 {
          input == "make" && !autoClose && name == "Build"
        } else {
          false
        }
      })
    await store.send(.runCustomCommand(state.selectedCustomCommands[1].id))
    await store.finish()
    #expect(sent.value.contains { if case .createSplitWithInput = $0 { true } else { false } })
    let count = sent.value.count
    await store.send(.runCustomCommand(state.selectedCustomCommands[2].id))
    await store.receive(\.repositories.showToast)
    #expect(store.state.repositories.statusToast == .warning("In Place commands do not run in remote folders yet."))
    await store.finish()
    #expect(sent.value.count == count)
  }

  /// New Terminal (menu bar and shortcut) in a remote folder opens a remote tab (docs-ai 084
  /// C3b), with a pending setup script (C3c); a remote plain folder too.
  @Test(.dependencies) func newTerminalInARemoteFolderOpensARemoteTab() async throws {
    var repositories = Self.remoteState()
    repositories.pendingSetupScriptWorktreeIDs = [repositories.selectedWorktreeID!]
    let plain = RemoteRepositoryFixtures.plainFolder()
    var plainRepositories = RepositoriesFeature.State()
    plainRepositories.repositories = [plain]
    plainRepositories.repositoryRoots = [plain.location]
    plainRepositories.selection = .repository(plain.id)
    for repositories in [repositories, plainRepositories] {
      let sent = LockIsolated<[TerminalClient.Command]>([])
      let store = TestStore(
        initialState: AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
      ) {
        AppFeature()
      } withDependencies: {
        $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
      }
      store.exhaustivity = .off
      await store.send(.newTerminal)
      await store.finish()
      let worktree = try #require(store.state.repositories.selectedTerminalWorktree)
      let pending = repositories.pendingSetupScriptWorktreeIDs.contains(worktree.id)
      #expect(sent.value == [.createTab(worktree, runSetupScriptIfNew: pending)])
      #expect(store.state.repositories.statusToast == nil)
    }
  }
}
