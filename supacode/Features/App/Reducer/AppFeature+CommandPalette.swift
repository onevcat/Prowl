import AppKit
import ComposableArchitecture
import ProwlCLIShared

extension AppFeature {
  func reduceCommandPaletteAction(
    _ action: CommandPaletteFeature.Action,
    state: inout State
  ) -> Effect<Action> {
    switch action {
    case .setPresented(true):
      refreshWorkflowPaletteItems(state: &state)
      return .none

    case .setPresented(false):
      guard state.commandPalette.isPresented else { return .none }
      return restoreCommandPaletteTerminalFocusEffect(repositories: state.repositories)

    case .togglePresented:
      guard state.commandPalette.isPresented else {
        refreshWorkflowPaletteItems(state: &state)
        return .none
      }
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
    if let effect = reduceCommandPaletteRepositoryDelegate(delegate) {
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
    if let effect = reduceCommandPaletteHandoffDelegate(delegate, state: &state) {
      return effect
    }
    if let effect = reduceCommandPaletteWorkflowDelegate(delegate, state: &state) {
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
      return openSettingsEffect(selecting: .general)

    case .newWorktree:
      return .send(.repositories(.worktreeCreation(.createRandomWorktree)))

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

  func reduceCommandPaletteRepositoryDelegate(
    _ delegate: CommandPaletteFeature.Delegate
  ) -> Effect<Action>? {
    switch delegate {
    case .openRepository:
      return .send(.repositories(.setOpenPanelPresented(true)))

    case .newWorkspace:
      return .send(.repositories(.workspaceCreation(.promptRequested)))

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

    case .organizeCanvasCards:
      return .send(.repositories(.requestCanvasCommand(.organize)))

    case .tileCanvasCards:
      return .send(.repositories(.requestCanvasCommand(.tile)))

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
      return openSelectedWorktreeDiffEffect(state: state)

    case .showOutgoingChanges:
      return openSelectedWorktreeOutgoingChangesEffect(state: state)

    case .revealInFinder:
      return .send(.openWorktree(.finder))

    case .copyPath:
      guard let worktree = state.repositories.selectedTerminalWorktree else {
        return .none
      }
      let path = worktree.workingDirectory.path
      return .run { _ in
        await MainActor.run {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(path, forType: .string)
        }
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

  /// A workspace child's sync-resolved root comes from workspace metadata,
  /// which may record a subdirectory or a nested worktree. Canonicalize it
  /// through the same `repoRoot` normalization that keys registered
  /// repositories, at the moment the action runs, so `repositorySettings` and
  /// `{repoPath}` match the source repository. Worktree targets already carry
  /// their registered root; a failed lookup keeps the metadata fallback.
  func canonicalizedDiffTarget(_ target: DiffTarget) async -> DiffTarget {
    guard case .workspaceChild = target.id,
      let root = try? await gitClient.repoRoot(target.workingDirectory)
    else {
      return target
    }
    var target = target
    target.repositoryRootURL = root
    return target
  }

  func openDiffEffect(
    target: DiffTarget,
    resolvedKeybindings: ResolvedKeybindingMap
  ) -> Effect<Action> {
    @Shared(.settingsFile) var settingsFile
    let settings = ExternalDiffSettings(
      toolID: settingsFile.global.externalDiffToolID,
      customCommand: settingsFile.global.externalDiffCustomCommand
    )
    return .run { send in
      let target = await canonicalizedDiffTarget(target)
      await externalDiffToolClient.open(settings, target, resolvedKeybindings) { error in
        send(.openWorktreeFailed(error))
      }
    }
  }

  func openSelectedWorktreeDiffEffect(state: State) -> Effect<Action> {
    guard let targetID = state.repositories.selectedDiffTargetID,
      let target = state.repositories.diffTarget(for: targetID)
    else {
      return .none
    }
    return openDiffEffect(target: target, resolvedKeybindings: state.resolvedKeybindings)
  }

  func openSelectedWorktreeOutgoingChangesEffect(state: State) -> Effect<Action> {
    guard let targetID = state.repositories.selectedDiffTargetID else {
      return .none
    }
    return openOutgoingChangesEffect(targetID: targetID, state: state)
  }

  func openOutgoingChangesEffect(targetID: DiffTargetID, state: State) -> Effect<Action> {
    guard let target = state.repositories.diffTarget(for: targetID) else {
      return .none
    }
    let resolvedKeybindings = state.resolvedKeybindings
    return .run { send in
      let target = await canonicalizedDiffTarget(target)
      await outgoingChangesClient.open(target, resolvedKeybindings) { error in
        send(.openWorktreeFailed(error))
      }
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
      guard
        let worktreeID = renameBranchCommandTargetID(
          appState: state,
          canvasFocusedWorktreeID: terminalClient.canvasFocusedWorktreeID()
        )
      else {
        return .none
      }
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

    case .runCustomCommand(let id):
      return .send(.runCustomCommand(id))

    case .launchAgentProfile(let profileID):
      return .send(.launchAgentProfile(profileID))

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

  func reduceCommandPaletteHandoffDelegate(
    _ delegate: CommandPaletteFeature.Delegate,
    state: inout State
  ) -> Effect<Action>? {
    guard case .handOff = delegate else { return nil }
    // One execution path: the palette row opens the same staged HUD as the
    // toolbar capsule (docs-ai 049).
    return openHandoffHud(state: &state)
  }

  func reduceCommandPaletteWorkflowDelegate(
    _ delegate: CommandPaletteFeature.Delegate,
    state: inout State
  ) -> Effect<Action>? {
    guard case .runWorkflow(let key) = delegate else { return nil }
    // One execution path: the palette row goes through the same opener as the
    // Agents popover and the Active Agents menu (docs-ai 063.011 decision 1).
    return openWorkflowStart(
      state: &state, workflowKey: key, worktreeID: nil, sourceSurfaceID: nil, forceSheet: false)
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
}
