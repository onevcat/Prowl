import ComposableArchitecture
import Foundation
import SwiftUI

extension RepositoriesFeature {
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func reduceWorktreeLifecycle(
    state: inout State,
    action: WorktreeLifecycleAction
  ) -> Effect<Action> {
    switch action {
    case .requestArchiveWorktree(let worktreeID, let repositoryID):
      if state.removingRepositoryIDs.contains(repositoryID) {
        return .none
      }
      guard let repository = state.repositories[id: repositoryID],
        let worktree = repository.worktrees[id: worktreeID]
      else {
        return .none
      }
      if state.isMainWorktree(worktree) {
        return .none
      }
      if state.deletingWorktreeIDs.contains(worktree.id) {
        return .none
      }
      if state.archivingWorktreeIDs.contains(worktree.id) {
        return .none
      }
      if state.isWorktreeArchived(worktree.id) {
        return .none
      }
      if state.isWorktreeMerged(worktree) {
        return .send(.worktreeLifecycle(.archiveWorktreeConfirmed(worktree.id, repository.id)))
      }
      state.alert = AlertState {
        TextState("Archive worktree?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmArchiveWorktree(worktree.id, repository.id)) {
          TextState("Archive (⌘↩)")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState(archiveWorktreeAlertMessage(for: worktree.name))
      }
      return .none

    case .requestArchiveWorktrees(let targets):
      var validTargets: [ArchiveWorktreeTarget] = []
      var seenWorktreeIDs: Set<Worktree.ID> = []
      for target in targets {
        guard seenWorktreeIDs.insert(target.worktreeID).inserted else { continue }
        if state.removingRepositoryIDs.contains(target.repositoryID) {
          continue
        }
        guard let repository = state.repositories[id: target.repositoryID],
          let worktree = repository.worktrees[id: target.worktreeID]
        else {
          continue
        }
        if state.isMainWorktree(worktree)
          || state.deletingWorktreeIDs.contains(worktree.id)
          || state.archivingWorktreeIDs.contains(worktree.id)
          || state.isWorktreeArchived(worktree.id)
        {
          continue
        }
        validTargets.append(target)
      }
      guard !validTargets.isEmpty else {
        return .none
      }
      if validTargets.count == 1, let target = validTargets.first {
        return .send(.worktreeLifecycle(.requestArchiveWorktree(target.worktreeID, target.repositoryID)))
      }
      let count = validTargets.count
      state.alert = AlertState {
        TextState("Archive \(count) worktrees?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmArchiveWorktrees(validTargets)) {
          TextState("Archive \(count) (⌘↩)")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState(archiveWorktreesAlertMessage())
      }
      return .none

    case .archiveWorktreeConfirmed(let worktreeID, let repositoryID):
      guard let repository = state.repositories[id: repositoryID],
        let worktree = repository.worktrees[id: worktreeID]
      else {
        return .none
      }
      if state.isWorktreeArchived(worktreeID) || state.archivingWorktreeIDs.contains(worktreeID) {
        state.alert = nil
        return .none
      }
      state.alert = nil
      @Shared(.repositorySettings(worktree.repositoryRootURL)) var repositorySettings
      let script = resolvedRepositoryScript(
        profileID: repositorySettings.archiveScriptProfileID,
        inlineScript: repositorySettings.archiveScript,
        worktree: worktree
      )
      let commandText = archiveScriptCommand(script)
      let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        return .send(.worktreeLifecycle(.archiveWorktreeApply(worktreeID, repositoryID)))
      }
      state.archivingWorktreeIDs.insert(worktreeID)
      state.archiveScriptProgressByWorktreeID[worktreeID] = ArchiveScriptProgress(
        titleText: "Running archive script",
        detailText: "Preparing archive script",
        commandText: commandText
      )
      let shellClient = self.shellClient
      let scriptWithEnv = worktree.scriptEnvironmentExportPrefix + script
      return .run { send in
        let envURL = URL(fileURLWithPath: "/usr/bin/env")
        var progress = ArchiveScriptProgress(
          titleText: "Running archive script",
          detailText: "Running archive script",
          commandText: commandText
        )
        do {
          for try await event in shellClient.runLoginStream(
            envURL,
            ["bash", "-lc", scriptWithEnv],
            worktree.workingDirectory,
            log: false
          ) {
            switch event {
            case .line(let line):
              let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
              guard !text.isEmpty else { continue }
              progress.appendOutputLine(text, maxLines: archiveScriptProgressLineLimit)
              await send(.worktreeLifecycle(.archiveScriptProgressUpdated(worktreeID: worktreeID, progress: progress)))
            case .finished:
              await send(
                .worktreeLifecycle(
                  .archiveScriptSucceeded(
                    worktreeID: worktreeID,
                    repositoryID: repositoryID
                  )
                )
              )
            }
          }
        } catch {
          await send(
            .worktreeLifecycle(
              .archiveScriptFailed(
                worktreeID: worktreeID,
                message: error.localizedDescription
              )
            )
          )
        }
      }
      .cancellable(id: CancelID.archiveScript(worktreeID), cancelInFlight: true)

    case .archiveScriptProgressUpdated(let worktreeID, let progress):
      guard state.archivingWorktreeIDs.contains(worktreeID) else {
        return .none
      }
      state.archiveScriptProgressByWorktreeID[worktreeID] = progress
      return .none

    case .archiveScriptSucceeded(let worktreeID, let repositoryID):
      guard state.archivingWorktreeIDs.contains(worktreeID) else {
        return .none
      }
      state.archivingWorktreeIDs.remove(worktreeID)
      state.archiveScriptProgressByWorktreeID.removeValue(forKey: worktreeID)
      return .send(.worktreeLifecycle(.archiveWorktreeApply(worktreeID, repositoryID)))

    case .archiveScriptFailed(let worktreeID, let message):
      guard state.archivingWorktreeIDs.contains(worktreeID) else {
        return .none
      }
      state.archivingWorktreeIDs.remove(worktreeID)
      state.archiveScriptProgressByWorktreeID.removeValue(forKey: worktreeID)
      state.alert = messageAlert(title: "Archive script failed", message: message)
      return .none

    case .archiveWorktreeApply(let worktreeID, let repositoryID):
      guard let repository = state.repositories[id: repositoryID],
        let worktree = repository.worktrees[id: worktreeID]
      else {
        return .none
      }
      if state.isWorktreeArchived(worktreeID) {
        state.alert = nil
        return .none
      }
      let previousSelection = state.selectedWorktreeID
      let previousSelectedWorktree = state.worktree(for: previousSelection)
      let selectionWasRemoved = state.selectedWorktreeID == worktree.id
      let nextSelection =
        selectionWasRemoved
        ? nextWorktreeID(afterRemoving: worktree, in: repository, state: state)
        : nil
      var didUpdateWorktreeOrder = false
      let wasPinned = state.pinnedWorktreeIDs.contains(worktreeID)
      withAnimation {
        state.alert = nil
        state.pinnedWorktreeIDs.removeAll { $0 == worktreeID }
        if var order = state.worktreeOrderByRepository[repositoryID] {
          order.removeAll { $0 == worktreeID }
          if order.isEmpty {
            state.worktreeOrderByRepository.removeValue(forKey: repositoryID)
          } else {
            state.worktreeOrderByRepository[repositoryID] = order
          }
          didUpdateWorktreeOrder = true
        }
        state.archivedWorktrees.append(ArchivedWorktree(id: worktreeID, archivedAt: now))
        if selectionWasRemoved {
          let nextWorktreeID = nextSelection ?? firstAvailableWorktreeID(in: repositoryID, state: state)
          state.selection = nextWorktreeID.map(SidebarSelection.worktree)
          state.selectedWorkspaceChildID = nil
        }
      }
      let archivedWorktrees = state.archivedWorktrees
      let repositories = state.repositories
      let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
      let selectionChanged = selectionDidChange(
        previousSelectionID: previousSelection,
        previousSelectedWorktree: previousSelectedWorktree,
        selectedWorktreeID: state.selectedWorktreeID,
        selectedWorktree: selectedWorktree
      )
      var effects: [Effect<Action>] = [
        .send(.delegate(.repositoriesChanged(repositories))),
        .run { _ in
          await repositoryPersistence.saveArchivedWorktrees(archivedWorktrees)
        },
      ]
      if wasPinned {
        let pinnedWorktreeIDs = state.pinnedWorktreeIDs
        effects.append(
          .run { _ in
            await repositoryPersistence.savePinnedWorktreeIDs(pinnedWorktreeIDs)
          }
        )
      }
      if didUpdateWorktreeOrder {
        let worktreeOrderByRepository = state.worktreeOrderByRepository
        effects.append(
          .run { _ in
            await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
          }
        )
      }
      if selectionChanged {
        effects.append(.send(.delegate(.selectedWorktreeChanged(selectedWorktree))))
      }
      return .merge(effects)

    case .unarchiveWorktree(let worktreeID):
      if !state.isWorktreeArchived(worktreeID) {
        return .none
      }
      withAnimation {
        state.archivedWorktrees.removeAll { $0.id == worktreeID }
      }
      let archivedWorktrees = state.archivedWorktrees
      let repositories = state.repositories
      return .merge(
        .send(.delegate(.repositoriesChanged(repositories))),
        .run { _ in
          await repositoryPersistence.saveArchivedWorktrees(archivedWorktrees)
        }
      )

    case .requestDeleteWorktree(let worktreeID, let repositoryID):
      if state.removingRepositoryIDs.contains(repositoryID) {
        return .none
      }
      guard let repository = state.repositories[id: repositoryID],
        let worktree = repository.worktrees[id: worktreeID]
      else {
        return .none
      }
      if state.isMainWorktree(worktree) {
        state.alert = messageAlert(
          title: "Delete not allowed",
          message: "Deleting the main worktree is not allowed."
        )
        return .none
      }
      if state.archivingWorktreeIDs.contains(worktree.id) {
        return .none
      }
      if state.deletingWorktreeIDs.contains(worktree.id) {
        return .none
      }
      state.deleteWorktreeConfirmation = makeDeleteWorktreeConfirmation(
        id: state.nextDeleteWorktreeConfirmationID,
        targets: [DeleteWorktreeTarget(worktreeID: worktree.id, repositoryID: repository.id)],
        state: state
      )
      state.nextDeleteWorktreeConfirmationID += 1
      return .none

    case .requestDeleteWorktrees(let targets):
      var validTargets: [DeleteWorktreeTarget] = []
      var seenWorktreeIDs: Set<Worktree.ID> = []
      for target in targets {
        guard seenWorktreeIDs.insert(target.worktreeID).inserted else { continue }
        if state.removingRepositoryIDs.contains(target.repositoryID) {
          continue
        }
        guard let repository = state.repositories[id: target.repositoryID],
          let worktree = repository.worktrees[id: target.worktreeID]
        else {
          continue
        }
        if state.isMainWorktree(worktree)
          || state.deletingWorktreeIDs.contains(worktree.id)
          || state.archivingWorktreeIDs.contains(worktree.id)
        {
          continue
        }
        validTargets.append(target)
      }
      guard !validTargets.isEmpty else {
        return .none
      }
      state.deleteWorktreeConfirmation = makeDeleteWorktreeConfirmation(
        id: state.nextDeleteWorktreeConfirmationID,
        targets: validTargets,
        state: state
      )
      state.nextDeleteWorktreeConfirmationID += 1
      return .none

    case .deleteWorktreePromptDeleteBranchChanged(let deleteBranch):
      state.deleteWorktreeConfirmation?.deleteBranch = deleteBranch
      return .none

    case .deleteWorktreePromptDismissed:
      state.deleteWorktreeConfirmation = nil
      return .none

    case .deleteWorktreePromptConfirmed:
      guard let confirmation = state.deleteWorktreeConfirmation else {
        return .none
      }
      state.deleteWorktreeConfirmation = nil
      state.$deleteBranchOnManualWorktreeDelete.withLock { $0 = confirmation.deleteBranch }
      return .merge(
        confirmation.targets.map { target in
          .send(
            .worktreeLifecycle(
              .deleteWorktreeConfirmed(
                target.worktreeID,
                target.repositoryID,
                deleteBranch: confirmation.deleteBranch
              ))
          )
        }
      )

    case .deleteWorktreeConfirmed(let worktreeID, let repositoryID, let deleteBranch):
      guard let repository = state.repositories[id: repositoryID],
        let worktree = repository.worktrees[id: worktreeID]
      else {
        return .none
      }
      if state.archivingWorktreeIDs.contains(worktree.id) {
        return .none
      }
      if state.deletingWorktreeIDs.contains(worktree.id) {
        return .none
      }
      state.alert = nil
      state.deletingWorktreeIDs.insert(worktree.id)
      let selectionWasRemoved = state.selectedWorktreeID == worktree.id
      let nextSelection =
        selectionWasRemoved
        ? nextWorktreeID(afterRemoving: worktree, in: repository, state: state)
        : nil
      return .run { send in
        do {
          _ = try await gitClient.removeWorktree(
            worktree,
            false
          )
          let forceDeleteBranchRequest: ForceDeleteBranchRequest?
          if deleteBranch {
            do {
              _ = try await gitClient.deleteLocalBranch(worktree.name, worktree.repositoryRootURL, false)
              forceDeleteBranchRequest = nil
            } catch {
              forceDeleteBranchRequest = ForceDeleteBranchRequest(
                branchName: worktree.name,
                repositoryRootURL: worktree.repositoryRootURL,
                errorMessage: error.localizedDescription
              )
            }
          } else {
            forceDeleteBranchRequest = nil
          }
          await send(
            .worktreeLifecycle(
              .worktreeDeleted(
                worktree.id,
                repositoryID: repository.id,
                selectionWasRemoved: selectionWasRemoved,
                nextSelection: nextSelection,
                forceDeleteBranchRequest: forceDeleteBranchRequest
              )
            )
          )
        } catch {
          await send(.worktreeLifecycle(.deleteWorktreeFailed(error.localizedDescription, worktreeID: worktree.id)))
        }
      }

    case .worktreeDeleted(
      let worktreeID,
      let repositoryID,
      _,
      let nextSelection,
      let forceDeleteBranchRequest
    ):
      analyticsClient.capture("worktree_deleted", [String: Any]?.none)
      let previousSelection = state.selectedWorktreeID
      let previousSelectedWorktree = state.worktree(for: previousSelection)
      let wasPinned = state.pinnedWorktreeIDs.contains(worktreeID)
      var didUpdateWorktreeOrder = false
      let wasArchived = state.isWorktreeArchived(worktreeID)
      withAnimation(.easeOut(duration: 0.2)) {
        state.deletingWorktreeIDs.remove(worktreeID)
        state.archivingWorktreeIDs.remove(worktreeID)
        state.pendingWorktrees.removeAll { $0.id == worktreeID }
        state.pendingSetupScriptWorktreeIDs.remove(worktreeID)
        state.pendingTerminalFocusWorktreeIDs.remove(worktreeID)
        state.archiveScriptProgressByWorktreeID.removeValue(forKey: worktreeID)
        state.worktreeInfoByID.removeValue(forKey: worktreeID)
        state.pinnedWorktreeIDs.removeAll { $0 == worktreeID }
        state.archivedWorktrees.removeAll { $0.id == worktreeID }
        state.$prowlCreatedWorktreeIDs.withLock {
          $0.removeAll { $0 == worktreeID }
        }
        if var order = state.worktreeOrderByRepository[repositoryID] {
          order.removeAll { $0 == worktreeID }
          if order.isEmpty {
            state.worktreeOrderByRepository.removeValue(forKey: repositoryID)
          } else {
            state.worktreeOrderByRepository[repositoryID] = order
          }
          didUpdateWorktreeOrder = true
        }
        _ = removeWorktree(worktreeID, repositoryID: repositoryID, state: &state)
        let selectionNeedsUpdate = state.selection == .worktree(worktreeID)
        if selectionNeedsUpdate {
          let nextWorktreeID = nextSelection ?? firstAvailableWorktreeID(in: repositoryID, state: state)
          state.selection = nextWorktreeID.map(SidebarSelection.worktree)
          state.selectedWorkspaceChildID = nil
        }
      }
      let roots = state.repositories.map(\.rootURL)
      let repositories = state.repositories
      let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
      let selectionChanged = selectionDidChange(
        previousSelectionID: previousSelection,
        previousSelectedWorktree: previousSelectedWorktree,
        selectedWorktreeID: state.selectedWorktreeID,
        selectedWorktree: selectedWorktree
      )
      var immediateEffects: [Effect<Action>] = [
        .send(.delegate(.repositoriesChanged(repositories)))
      ]
      if selectionChanged {
        immediateEffects.append(.send(.delegate(.selectedWorktreeChanged(selectedWorktree))))
      }
      var followupEffects: [Effect<Action>] = [
        roots.isEmpty ? .none : .send(.reloadRepositories(animated: true))
      ]
      if wasPinned {
        let pinnedWorktreeIDs = state.pinnedWorktreeIDs
        followupEffects.append(
          .run { _ in
            await repositoryPersistence.savePinnedWorktreeIDs(pinnedWorktreeIDs)
          }
        )
      }
      if wasArchived {
        let archivedWorktrees = state.archivedWorktrees
        followupEffects.append(
          .run { _ in
            await repositoryPersistence.saveArchivedWorktrees(archivedWorktrees)
          }
        )
      }
      if didUpdateWorktreeOrder {
        let worktreeOrderByRepository = state.worktreeOrderByRepository
        followupEffects.append(
          .run { _ in
            await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
          }
        )
      }
      if let forceDeleteBranchRequest {
        state.pendingForceDeleteBranchRequests.append(forceDeleteBranchRequest)
        presentNextForceDeleteBranchAlert(state: &state)
      }
      return .concatenate(
        .merge(immediateEffects),
        .merge(followupEffects)
      )

    case .deleteWorktreeFailed(let message, let worktreeID):
      state.deletingWorktreeIDs.remove(worktreeID)
      state.alert = messageAlert(title: "Unable to delete worktree", message: message)
      return .none

    case .forceDeleteBranchConfirmed(let request):
      state.alert = nil
      removePendingForceDeleteBranchRequest(request, state: &state)
      presentNextForceDeleteBranchAlert(state: &state)
      return .run { send in
        do {
          _ = try await gitClient.deleteLocalBranch(request.branchName, request.repositoryRootURL, true)
        } catch {
          await send(.worktreeLifecycle(.forceDeleteBranchFailed(error.localizedDescription)))
        }
      }

    case .forceDeleteBranchFailed(let message):
      state.alert = messageAlert(title: "Unable to delete branch", message: message)
      return .none
    }
  }

  var worktreeLifecycleReducer: some ReducerOf<Self> {
    Reduce { state, action in
      guard case .worktreeLifecycle(let action) = action else {
        return .none
      }
      return reduceWorktreeLifecycle(state: &state, action: action)
    }
  }
}

private func archiveWorktreeAlertMessage(for name: String) -> String {
  let shortcut = AppShortcuts.archivedWorktrees.display
  return "Find \(name) later in Menu Bar > Worktrees > Archived Worktrees (\(shortcut))."
}

private func archiveWorktreesAlertMessage() -> String {
  let shortcut = AppShortcuts.archivedWorktrees.display
  return "Find them later in Menu Bar > Worktrees > Archived Worktrees (\(shortcut))."
}

private func makeDeleteWorktreeConfirmation(
  id: Int,
  targets: [RepositoriesFeature.DeleteWorktreeTarget],
  state: RepositoriesFeature.State
) -> DeleteWorktreeConfirmation {
  let count = targets.count
  let defaultDeleteBranch = state.deleteBranchOnManualWorktreeDelete
  if count == 1,
    let target = targets.first,
    let worktree = state.repositories[id: target.repositoryID]?.worktrees[id: target.worktreeID]
  {
    return DeleteWorktreeConfirmation(
      id: id,
      title: "Delete worktree?",
      message: "Delete \(worktree.name)? The worktree directory will be removed.",
      targets: targets,
      deleteBranch: defaultDeleteBranch
    )
  }
  return DeleteWorktreeConfirmation(
    id: id,
    title: "Delete \(count) worktrees?",
    message: "Delete \(count) worktrees? Their worktree directories will be removed.",
    targets: targets,
    deleteBranch: defaultDeleteBranch
  )
}

private func forceDeleteBranchAlert(_ request: ForceDeleteBranchRequest) -> AlertState<RepositoriesFeature.Alert> {
  AlertState {
    TextState("Force delete branch?")
  } actions: {
    ButtonState(role: .destructive, action: .confirmForceDeleteBranch(request)) {
      TextState("Force Delete")
    }
    ButtonState(role: .cancel) {
      TextState("Keep Branch")
    }
  } message: {
    TextState(
      """
      The worktree was deleted, but \(request.branchName) could not be deleted safely.

      \(request.errorMessage)
      """
    )
  }
}

func presentNextForceDeleteBranchAlert(state: inout RepositoriesFeature.State) {
  guard state.alert == nil, let request = state.pendingForceDeleteBranchRequests.first else {
    return
  }
  state.alert = forceDeleteBranchAlert(request)
}

func dismissCurrentForceDeleteBranchRequest(state: inout RepositoriesFeature.State) {
  guard let request = currentForceDeleteBranchRequest(from: state.alert) else {
    state.alert = nil
    return
  }
  state.alert = nil
  removePendingForceDeleteBranchRequest(request, state: &state)
  presentNextForceDeleteBranchAlert(state: &state)
}

private func removePendingForceDeleteBranchRequest(
  _ request: ForceDeleteBranchRequest,
  state: inout RepositoriesFeature.State
) {
  state.pendingForceDeleteBranchRequests.removeAll { $0 == request }
}

private func currentForceDeleteBranchRequest(
  from alert: AlertState<RepositoriesFeature.Alert>?
) -> ForceDeleteBranchRequest? {
  guard let alert else { return nil }
  for button in alert.buttons {
    if case .confirmForceDeleteBranch(let request)? = button.action.action {
      return request
    }
  }
  return nil
}
