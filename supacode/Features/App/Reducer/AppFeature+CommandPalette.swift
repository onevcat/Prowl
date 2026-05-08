import AppKit
import ComposableArchitecture

extension AppFeature {
  func reduceCommandPaletteAction(
    _ action: CommandPaletteFeature.Action,
    state: inout State
  ) -> Effect<Action> {
    switch action {
    case .setPresented(false):
      guard state.commandPalette.isPresented else { return .none }
      return restoreCommandPaletteTerminalFocusEffect(repositories: state.repositories)

    case .togglePresented:
      guard state.commandPalette.isPresented else { return .none }
      return restoreCommandPaletteTerminalFocusEffect(repositories: state.repositories)

    case .delegate(let delegate):
      return reduceCommandPaletteDelegate(delegate, state: &state)

    default:
      return .none
    }
  }

  func reduceCommandPaletteDelegate(
    _ delegate: CommandPaletteFeature.Delegate,
    state: inout State
  ) -> Effect<Action> {
    if let effect = reduceCommandPaletteNavigationDelegate(delegate, state: &state) {
      return effect
    }
    if let effect = reduceCommandPaletteCanvasDelegate(delegate) {
      return effect
    }
    if let effect = reduceCommandPaletteWorktreeFileDelegate(delegate, state: &state) {
      return effect
    }
    if let effect = reduceCommandPaletteWorktreeActionDelegate(delegate, state: &state) {
      return effect
    }
    if let effect = reduceCommandPalettePullRequestDelegate(delegate) {
      return effect
    }
    #if DEBUG
      if let effect = reduceCommandPaletteDebugDelegate(delegate) {
        return effect
      }
    #endif
    return .none
  }

  func reduceCommandPaletteNavigationDelegate(
    _ delegate: CommandPaletteFeature.Delegate,
    state: inout State
  ) -> Effect<Action>? {
    switch delegate {
    case .selectWorktree(let worktreeID):
      if state.repositories.isShowingCanvas {
        if state.repositories.worktree(for: worktreeID) == nil,
          state.repositories.repositories[id: worktreeID]?.kind == .plain
        {
          return .send(.repositories(.focusCanvasRepository(worktreeID)))
        }
        return .send(.repositories(.focusCanvasWorktree(worktreeID)))
      }
      return .send(.repositories(.selectWorktree(worktreeID)))

    case .checkForUpdates:
      return .send(.updates(.checkForUpdates))

    case .openSettings:
      return .merge(
        .send(.settings(.setSelection(.general))),
        .run { _ in
          await settingsWindowClient.show()
        }
      )

    case .newWorktree:
      return .send(.repositories(.worktreeCreation(.createRandomWorktree)))

    case .openRepository:
      return .send(.repositories(.setOpenPanelPresented(true)))

    case .deleteWorktree(let worktreeID, let repositoryID):
      return .send(.repositories(.worktreeLifecycle(.requestDeleteWorktree(worktreeID, repositoryID))))

    case .viewArchivedWorktrees:
      return .send(.repositories(.selectArchivedWorktrees))

    case .refreshWorktrees:
      return .send(.repositories(.refreshWorktrees))

    case .jumpToLatestUnread:
      return .send(.jumpToLatestUnread)

    case .installCLI:
      return .send(.settings(.installCLIButtonTapped(showAlert: false)))

    case .toggleLeftSidebar:
      return .send(.toggleLeftSidebar)

    case .toggleActiveAgentsPanel:
      return .send(.repositories(.activeAgents(.togglePanelVisibility)))

    default:
      return nil
    }
  }

  func reduceCommandPaletteCanvasDelegate(
    _ delegate: CommandPaletteFeature.Delegate
  ) -> Effect<Action>? {
    switch delegate {
    case .toggleCanvas:
      return .send(.repositories(.toggleCanvas))

    case .expandCanvasCard:
      return .send(.repositories(.requestCanvasCommand(.toggleExpand)))

    case .arrangeCanvasCards:
      return .send(.repositories(.requestCanvasCommand(.arrange)))

    case .layoutCenter:
      return .send(.repositories(.requestCanvasCommand(.center)))

    case .layoutArrange:
      return .send(.repositories(.requestCanvasCommand(.arrange)))

    case .layoutOverview:
      return .send(.repositories(.requestCanvasCommand(.overview)))

    case .organizeCanvasCards:
      return .send(.repositories(.requestCanvasCommand(.organize)))

    case .selectAllCanvasCards:
      return .send(.repositories(.requestCanvasCommand(.selectAll)))

    case .toggleShelf:
      return .send(.repositories(.toggleShelf))

    default:
      return nil
    }
  }

  func reduceCommandPaletteWorktreeFileDelegate(
    _ delegate: CommandPaletteFeature.Delegate,
    state: inout State
  ) -> Effect<Action>? {
    switch delegate {
    case .showDiff:
      guard let worktreeID = state.repositories.selectedWorktreeID,
        let worktree = state.repositories.worktree(for: worktreeID)
      else {
        return .none
      }
      let keybindings = state.resolvedKeybindings
      return .run { _ in
        await MainActor.run {
          DiffWindowManager.shared.show(
            worktreeURL: worktree.workingDirectory,
            branchName: worktree.name,
            resolvedKeybindings: keybindings
          )
        }
      }

    case .openInFork:
      guard let worktree = terminalCommandWorktree(repositories: state.repositories) else {
        return .none
      }
      let resolvedWorktree = commandPaletteResolvedWorktree(for: worktree)
      return .run { send in
        await workspaceClient.open(.fork, resolvedWorktree) { error in
          send(.openWorktreeFailed(error))
        }
      }

    case .revealInFinder:
      guard let worktree = terminalCommandWorktree(repositories: state.repositories) else {
        return .none
      }
      let revealWorktree = commandPaletteResolvedWorktree(for: worktree)
      return .run { send in
        await workspaceClient.open(.finder, revealWorktree) { error in
          send(.openWorktreeFailed(error))
        }
      }

    case .copyPath:
      guard let worktree = terminalCommandWorktree(repositories: state.repositories) else {
        return .none
      }
      let path = commandPaletteResolvedPath(for: worktree)
      return .run { _ in
        await clipboardClient.copyString(path)
      }

    case .revealInSidebar:
      guard state.repositories.selectedWorktreeID != nil else { return .none }
      return .merge(
        .send(.showLeftSidebar),
        .send(.repositories(.revealSelectedWorktreeInSidebar))
      )

    default:
      return nil
    }
  }

  func reduceCommandPaletteWorktreeActionDelegate(
    _ delegate: CommandPaletteFeature.Delegate,
    state: inout State
  ) -> Effect<Action>? {
    switch delegate {
    case .runScript:
      return .send(.runScript)

    case .stopRunScript:
      return .send(.stopRunScript)

    case .renameBranch:
      guard let worktreeID = state.repositories.selectedWorktreeID else { return .none }
      return .send(.repositories(.requestRenameBranchPrompt(worktreeID)))

    case .openRepositorySettings(let repositoryID):
      // Reuse the existing repo-side flow so the repo-existence guard and
      // settingsWindowClient.show() live in one place.
      return .send(.repositories(.repositoryManagement(.openRepositorySettings(repositoryID))))

    case .togglePinWorktree(let worktreeID, let isCurrentlyPinned):
      if isCurrentlyPinned {
        return .send(.repositories(.worktreeOrdering(.unpinWorktree(worktreeID))))
      }
      return .send(.repositories(.worktreeOrdering(.pinWorktree(worktreeID))))

    case .runCustomCommand(let index):
      return .send(.runCustomCommand(index))

    case .ghosttyCommand(let action):
      guard let worktree = actionTargetWorktree(repositories: state.repositories) else {
        return .none
      }
      // Capture the target surface synchronously: the async effect below races
      // AppKit's post-dismiss focus reshuffle, which can hand first responder
      // to a different pane before the binding action runs.
      let command: TerminalClient.Command
      if let surfaceID = terminalClient.selectedSurfaceID(worktree.id) {
        command = .performBindingActionOnSurface(worktree, surfaceID: surfaceID, action: action)
      } else {
        command = .performBindingAction(worktree, action: action)
      }
      return .run { _ in
        await terminalClient.send(command)
      }

    case .changeFocusedTabIcon(let worktreeID):
      guard let worktree = state.repositories.selectedTerminalWorktree,
        worktree.id == worktreeID
      else {
        return .none
      }
      return .run { _ in
        await terminalClient.send(.presentTabIconPicker(worktree))
      }

    default:
      return nil
    }
  }

  func reduceCommandPalettePullRequestDelegate(
    _ delegate: CommandPaletteFeature.Delegate
  ) -> Effect<Action>? {
    switch delegate {
    case .openPullRequest(let worktreeID):
      return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .openOnCodeHost))))

    case .markPullRequestReady(let worktreeID):
      return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .markReadyForReview))))

    case .mergePullRequest(let worktreeID):
      return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .merge))))

    case .closePullRequest(let worktreeID):
      return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .close))))

    case .copyFailingJobURL(let worktreeID):
      return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .copyFailingJobURL))))

    case .copyCiFailureLogs(let worktreeID):
      return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .copyCiFailureLogs))))

    case .rerunFailedJobs(let worktreeID):
      return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .rerunFailedJobs))))

    case .openFailingCheckDetails(let worktreeID):
      return .send(.repositories(.githubIntegration(.pullRequestAction(worktreeID, .openFailingCheckDetails))))

    default:
      return nil
    }
  }

  #if DEBUG
    func reduceCommandPaletteDebugDelegate(
      _ delegate: CommandPaletteFeature.Delegate
    ) -> Effect<Action>? {
      switch delegate {
      case .debugTestToast(let toast):
        return .send(.repositories(.showToast(toast)))

      case .debugSimulateUpdateFound:
        return .send(.updates(.debugSimulateUpdateFound))

      case .debugLightDockNotificationDot:
        return .run { _ in await dockClient.setNotificationBadge(1) }

      default:
        return nil
      }
    }
  #endif

  func commandPaletteResolvedPath(for worktree: Worktree) -> String {
    terminalClient.focusedDirectoryPath(worktree.id)
      ?? worktree.workingDirectory.path(percentEncoded: false)
  }

  func commandPaletteResolvedWorktree(for worktree: Worktree) -> Worktree {
    let resolvedURL = URL(
      fileURLWithPath: commandPaletteResolvedPath(for: worktree)
    ).standardizedFileURL
    return Worktree(
      id: worktree.id,
      name: worktree.name,
      detail: worktree.detail,
      workingDirectory: resolvedURL,
      repositoryRootURL: worktree.repositoryRootURL,
      createdAt: worktree.createdAt
    )
  }
}
