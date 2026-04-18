import ComposableArchitecture
import Foundation

extension AppFeature {
  func reduceTerminalEvent(
    _ event: TerminalClient.Event,
    state: inout State
  ) -> Effect<Action> {
    if let effect = reduceTerminalNotificationEvent(event, state: &state) {
      return effect
    }
    if let effect = reduceTerminalStatusEvent(event, state: &state) {
      return effect
    }
    if let effect = reduceTerminalCommandPaletteEvent(event, state: state) {
      return effect
    }
    if let effect = reduceTerminalLayoutEvent(event, state: &state) {
      return effect
    }
    if let effect = reduceTerminalTabEvent(event, state: state) {
      return effect
    }
    if let effect = reduceTerminalAgentEvent(event, state: state) {
      return effect
    }
    return .none
  }

  func reduceTerminalNotificationEvent(
    _ event: TerminalClient.Event,
    state: inout State
  ) -> Effect<Action>? {
    switch event {
    case .notificationReceived(let worktreeID, let surfaceID, let title, let body):
      return terminalNotificationReceivedEffect(
        worktreeID: worktreeID,
        surfaceID: surfaceID,
        title: title,
        body: body,
        state: state
      )

    case .notificationIndicatorChanged(let count):
      state.notificationIndicatorCount = count
      let badgeCount = state.settings.showNotificationDotOnDock ? count : 0
      return .run { _ in
        await dockClient.setNotificationBadge(badgeCount)
      }

    default:
      return nil
    }
  }

  func reduceTerminalStatusEvent(
    _ event: TerminalClient.Event,
    state: inout State
  ) -> Effect<Action>? {
    switch event {
    case .customCommandSucceeded(_, let name, let durationMs):
      let message = "\(name) succeeded in \(formatCustomCommandDuration(durationMs))"
      return .send(.repositories(.showToast(.success(message))))

    case .runScriptStatusChanged(let worktreeID, let isRunning):
      if isRunning {
        state.runScriptStatusByWorktreeID[worktreeID] = true
      } else {
        state.runScriptStatusByWorktreeID.removeValue(forKey: worktreeID)
      }
      return .none

    default:
      return nil
    }
  }

  func reduceTerminalCommandPaletteEvent(
    _ event: TerminalClient.Event,
    state: State
  ) -> Effect<Action>? {
    switch event {
    case .commandPaletteToggleRequested(let worktreeID):
      return commandPaletteToggleRequestedEffect(worktreeID: worktreeID, state: state)

    case .setupScriptConsumed(let worktreeID):
      return .send(.repositories(.worktreeCreation(.consumeSetupScript(worktreeID))))

    case .fontSizeChanged(let fontSize):
      return .send(.settings(.setTerminalFontSize(fontSize)))

    default:
      return nil
    }
  }

  func reduceTerminalLayoutEvent(
    _ event: TerminalClient.Event,
    state: inout State
  ) -> Effect<Action>? {
    switch event {
    case .layoutRestored(let selectedWorktreeID):
      return layoutRestoredEffect(selectedWorktreeID: selectedWorktreeID, state: &state)

    case .layoutRestoreFailed(let message):
      state.isAwaitingLaunchLayoutRestore = false
      appLogger.warning("[LayoutRestore] layoutRestoreFailed: \(message)")
      return .merge(
        .send(.repositories(.showToast(.warning(message)))),
        applyDefaultViewMode(into: &state)
      )

    default:
      return nil
    }
  }

  func reduceTerminalTabEvent(
    _ event: TerminalClient.Event,
    state: State
  ) -> Effect<Action>? {
    switch event {
    case .tabCreated(let worktreeID):
      return tabCreatedEffect(worktreeID: worktreeID, state: state)

    case .tabClosed(let worktreeID, let remainingTabs):
      return tabClosedEffect(worktreeID: worktreeID, remainingTabs: remainingTabs, state: state)

    case .focusChanged(_, let surfaceID):
      // Keep the Active Agents panel's keyboard-navigation anchor in sync with
      // the surface that actually has focus, so control-option-up/down steps from the right place.
      return .send(.repositories(.activeAgents(.focusedSurfaceChanged(surfaceID))))

    default:
      return nil
    }
  }

  func reduceTerminalAgentEvent(
    _ event: TerminalClient.Event,
    state: State
  ) -> Effect<Action>? {
    switch event {
    case .agentEntryChanged(let entry):
      return .send(
        .repositories(
          .activeAgents(
            .agentEntryChanged(entry, autoShowPanel: state.settings.autoShowActiveAgentsPanel)
          )
        )
      )

    case .agentEntryRemoved(let id):
      return .send(.repositories(.activeAgents(.agentEntryRemoved(id))))

    default:
      return nil
    }
  }

  func terminalNotificationReceivedEffect(
    worktreeID: Worktree.ID,
    surfaceID: UUID,
    title: String,
    body: String,
    state: State
  ) -> Effect<Action> {
    var effects: [Effect<Action>] = [
      .send(.repositories(.worktreeOrdering(.worktreeNotificationReceived(worktreeID))))
    ]
    if state.settings.systemNotificationsEnabled {
      effects.append(
        .run { _ in
          await systemNotificationClient.send(title, body, worktreeID, surfaceID)
        }
      )
    }
    if state.settings.notificationSoundEnabled && !state.settings.systemNotificationsEnabled {
      effects.append(
        .run { _ in
          await notificationSoundClient.play()
        }
      )
    }
    let bounceMode = state.settings.dockBounceMode
    if bounceMode != .off {
      effects.append(
        .run { _ in
          await dockClient.bounce(bounceMode)
        }
      )
    }
    return .merge(effects)
  }

  func commandPaletteToggleRequestedEffect(
    worktreeID: Worktree.ID,
    state: State
  ) -> Effect<Action> {
    if state.commandPalette.isPresented {
      return .send(.commandPalette(.setPresented(false)))
    }
    if state.repositories.worktree(for: worktreeID) != nil {
      return .merge(
        .send(.repositories(.selectWorktree(worktreeID))),
        .send(.commandPalette(.setPresented(true)))
      )
    }
    if state.repositories.repositories[id: worktreeID]?.kind == .plain {
      return .merge(
        .send(.repositories(.selectRepository(worktreeID))),
        .send(.commandPalette(.setPresented(true)))
      )
    }
    return .send(.commandPalette(.setPresented(true)))
  }

  func layoutRestoredEffect(
    selectedWorktreeID: Worktree.ID?,
    state: inout State
  ) -> Effect<Action> {
    state.isAwaitingLaunchLayoutRestore = false
    appLogger.info(
      "[LayoutRestore] layoutRestored: selectedWorktreeID=\(selectedWorktreeID ?? "nil")"
        + " repositoriesSelection(before)=\(String(describing: state.repositories.selection))"
    )
    @Shared(.appStorage(restoreCanvasModeOnLaunchAppStorageKey)) var restoreCanvasModeOnLaunch = false
    let restoreTargetWorktreeID =
      selectedWorktreeID
      ?? state.repositories.lastFocusedWorktreeID
      ?? state.repositories.orderedWorktreeRows().first?.id
    if restoreCanvasModeOnLaunch {
      return .send(.repositories(.restoreCanvasOnLaunch(restoreTargetWorktreeID)))
    }
    // Layout restore has settled: tabs are re-created, selection is set.
    // Now apply the default view preference, which was deferred in
    // `repositoriesChanged` (via `shouldDeferDefaultView`) to avoid
    // stray spines and a selection flash.
    var effects: [Effect<Action>] = []
    if let restoreTargetWorktreeID {
      // Plain folders use .repository selection, not .worktree
      if let repo = state.repositories.repositories[id: restoreTargetWorktreeID],
        repo.kind == .plain
      {
        effects.append(.send(.repositories(.selectRepository(restoreTargetWorktreeID))))
      } else {
        effects.append(.send(.repositories(.selectWorktree(restoreTargetWorktreeID))))
      }
    }
    return .concatenate([.merge(effects), applyDefaultViewMode(into: &state)])
  }

  func tabCreatedEffect(
    worktreeID: Worktree.ID,
    state: State
  ) -> Effect<Action> {
    // Every tab creation (user +, CLI open, layout restore, ...)
    // marks its worktree as Shelf-visible. Layout restore in
    // particular only calls `selectWorktree` for the one active
    // worktree; other restored worktrees only surface here.
    var openedWorktreeIDs = openedWorktreeIDsForInfoWatcher(from: state.repositories)
    if state.repositories.worktree(for: worktreeID) != nil {
      openedWorktreeIDs.insert(worktreeID)
    }
    let syncedOpenedWorktreeIDs = openedWorktreeIDs
    return .merge(
      .send(.repositories(.markWorktreeOpened(worktreeID))),
      .run { _ in
        await worktreeInfoWatcher.send(.setOpenedWorktreeIDs(syncedOpenedWorktreeIDs))
      }
    )
  }

  func tabClosedEffect(
    worktreeID: Worktree.ID,
    remainingTabs: Int,
    state: State
  ) -> Effect<Action> {
    // Closing the last tab retires the book from the Shelf. Other
    // closes are routine and need no Reducer-side bookkeeping.
    guard remainingTabs == 0 else { return .none }
    var openedWorktreeIDs = openedWorktreeIDsForInfoWatcher(from: state.repositories)
    openedWorktreeIDs.remove(worktreeID)
    let syncedOpenedWorktreeIDs = openedWorktreeIDs
    return .merge(
      .send(.repositories(.markWorktreeClosed(worktreeID))),
      .run { _ in
        await worktreeInfoWatcher.send(.setOpenedWorktreeIDs(syncedOpenedWorktreeIDs))
      }
    )
  }
}
