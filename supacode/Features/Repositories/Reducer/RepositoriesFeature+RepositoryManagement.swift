import ComposableArchitecture
import Foundation

extension RepositoriesFeature {
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func reduceRepositoryManagement(
    state: inout State,
    action: RepositoryManagementAction
  ) -> Effect<Action> {
    switch action {
    case .openRepositories(let urls):
      analyticsClient.capture("repository_added", ["count": urls.count])
      state.alert = nil
      return .run { send in
        let existingEntries = await loadPersistedRepositoryEntries()
        var resolvedEntries: [PersistedRepositoryEntry] = []
        var invalidRoots: [String] = []
        var openFailures: [String] = []
        for url in urls {
          let normalizedURL = url.standardizedFileURL
          if ProjectWorkspace.load(from: normalizedURL) != nil {
            resolvedEntries.append(
              PersistedRepositoryEntry(
                path: normalizedURL.path(percentEncoded: false),
                kind: .plain
              )
            )
            continue
          }
          do {
            let root = try await gitClient.repoRoot(url)
            resolvedEntries.append(
              PersistedRepositoryEntry(
                path: root.path(percentEncoded: false),
                kind: .git
              )
            )
          } catch {
            let normalizedPath = url.standardizedFileURL.path(percentEncoded: false)
            if normalizedPath.isEmpty {
              invalidRoots.append(url.path(percentEncoded: false))
            } else if Self.isNotGitRepositoryError(error) {
              resolvedEntries.append(
                PersistedRepositoryEntry(
                  path: normalizedPath,
                  kind: .plain
                )
              )
            } else {
              openFailures.append(
                Self.openRepositoryFailureMessage(
                  path: normalizedPath,
                  error: error
                )
              )
            }
          }
        }
        let mergedEntries = RepositoryEntryNormalizer.normalize(existingEntries + resolvedEntries)
        let mergedRoots = mergedEntries.map { URL(fileURLWithPath: $0.path) }
        await repositoryPersistence.saveRepositoryEntries(mergedEntries)
        let (repositories, failures) = await loadRepositoriesData(mergedEntries)
        await send(
          .repositoryManagement(
            .openRepositoriesFinished(
              repositories,
              failures: failures,
              invalidRoots: invalidRoots,
              openFailures: openFailures,
              roots: mergedRoots
            )
          )
        )
      }
      .cancellable(id: CancelID.load, cancelInFlight: true)

    case .openRepositoriesFinished(
      let repositories,
      let failures,
      let invalidRoots,
      let openFailures,
      let roots
    ):
      state.isRefreshingWorktrees = false
      let wasRestoringSnapshot = state.snapshotPersistencePhase == .restoring
      if failures.isEmpty, state.snapshotPersistencePhase != .active {
        state.snapshotPersistencePhase = .active
      }
      let wasAlreadyLoaded = state.isInitialLoadComplete
      let previousRepoIDs = Set(state.repositories.ids)
      let previousSelection = state.selectedWorktreeID
      let previousSelectedWorktree = state.worktree(for: previousSelection)
      let applyResult = applyRepositories(
        repositories,
        roots: roots,
        shouldPruneArchivedWorktrees: failures.isEmpty,
        state: &state,
        animated: false
      )
      state.repositoryRoots = roots
      state.isInitialLoadComplete = true
      state.loadFailuresByID = Dictionary(
        failures.map { ($0.rootID, $0.message) },
        uniquingKeysWith: { first, _ in first }
      )
      let openFailureMessages = invalidRoots.map { "\($0) is not a Git repository." } + openFailures
      if !openFailureMessages.isEmpty {
        state.alert = messageAlert(
          title: String(localized: "Some folders couldn't be opened"),
          message: openFailureMessages.joined(separator: "\n")
        )
      }
      let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
      let selectionChanged = selectionDidChange(
        previousSelectionID: previousSelection,
        previousSelectedWorktree: previousSelectedWorktree,
        selectedWorktreeID: state.selectedWorktreeID,
        selectedWorktree: selectedWorktree
      )
      var allEffects: [Effect<Action>] = [
        .send(.delegate(.repositoriesChanged(state.repositories)))
      ]
      if selectionChanged {
        allEffects.append(.send(.delegate(.selectedWorktreeChanged(selectedWorktree))))
      }
      if applyResult.didPrunePinned {
        let pinnedWorktreeIDs = state.pinnedWorktreeIDs
        allEffects.append(
          .run { _ in
            await repositoryPersistence.savePinnedWorktreeIDs(pinnedWorktreeIDs)
          })
      }
      if applyResult.didPruneRepositoryOrder {
        let repositoryOrderIDs = state.repositoryOrderIDs
        allEffects.append(
          .run { _ in
            await repositoryPersistence.saveRepositoryOrderIDs(repositoryOrderIDs)
          })
      }
      if applyResult.didPruneWorktreeOrder {
        let worktreeOrderByRepository = state.worktreeOrderByRepository
        allEffects.append(
          .run { _ in
            await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
          })
      }
      if applyResult.didPruneArchivedWorktrees {
        let archivedWorktrees = state.archivedWorktrees
        allEffects.append(
          .run { _ in
            await repositoryPersistence.saveArchivedWorktrees(archivedWorktrees)
          }
        )
      }
      if failures.isEmpty, !wasRestoringSnapshot {
        let repositories = Array(state.repositories)
        allEffects.append(
          .run { _ in
            await repositoryPersistence.saveRepositorySnapshot(repositories)
          }
        )
      }
      if let effect = detectCodeHostsEffect(for: state.repositories) {
        allEffects.append(effect)
      }
      allEffects.append(refreshWorkspaceChildrenEffect(state: state))
      if wasAlreadyLoaded, !wasRestoringSnapshot {
        let newRepos = state.repositories.filter { !previousRepoIDs.contains($0.id) }
        if let firstNew = newRepos.first {
          if let worktreeID = firstNew.worktrees.first?.id {
            allEffects.append(.send(.selectWorktree(worktreeID, focusTerminal: true)))
          } else if firstNew.capabilities.supportsRunnableFolderActions {
            state.pendingTerminalFocusWorktreeIDs.insert(firstNew.id)
            allEffects.append(.send(.selectRepository(firstNew.id)))
          }
        }
        allEffects.append(contentsOf: iconDetectionEffects(for: Array(newRepos)))
      }
      return .merge(allEffects)

    case .requestRemoveRepository(let repositoryID):
      if let repository = state.repositories[id: repositoryID], repository.isWorkspace {
        let branchOptions = (repository.workspace?.repositories ?? []).compactMap {
          entry -> RemoveWorkspaceConfirmation.BranchOption? in
          guard entry.sourceKind != .remote,
            let branchName = entry.branchName,
            entry.sourceLocation != nil
          else {
            return nil
          }
          return RemoveWorkspaceConfirmation.BranchOption(
            id: entry.id,
            repositoryName: entry.name,
            branchName: branchName
          )
        }
        state.removeWorkspaceConfirmation = RemoveWorkspaceConfirmation(
          repositoryID: repositoryID,
          workspaceTitle: repository.name,
          rootPath: repository.rootURL.path(percentEncoded: false),
          branchOptions: branchOptions
        )
        return .none
      }
      state.alert = confirmationAlertForRepositoryRemoval(repositoryID: repositoryID, state: state)
      return .none

    case .removeWorkspaceDeleteFilesChanged(let deleteFiles):
      state.removeWorkspaceConfirmation?.deleteFiles = deleteFiles
      return .none

    case .removeWorkspaceDeleteBranchChanged(let entryID, let isSelected):
      guard var confirmation = state.removeWorkspaceConfirmation,
        let index = confirmation.branchOptions.firstIndex(where: { $0.id == entryID })
      else {
        return .none
      }
      confirmation.branchOptions[index].isSelected = isSelected
      state.removeWorkspaceConfirmation = confirmation
      return .none

    case .removeWorkspacePromptDismissed:
      state.removeWorkspaceConfirmation = nil
      return .none

    case .removeWorkspacePromptConfirmed:
      guard let confirmation = state.removeWorkspaceConfirmation else {
        return .none
      }
      state.removeWorkspaceConfirmation = nil
      guard let repository = state.repositories[id: confirmation.repositoryID],
        !state.removingRepositoryIDs.contains(repository.id)
      else {
        return .none
      }
      state.removingRepositoryIDs.insert(repository.id)
      let selectionWasRemoved =
        state.selection == .repository(repository.id)
        || (state.selectedWorktreeID.map { id in
          repository.worktrees.contains(where: { $0.id == id })
        } ?? false)
      guard confirmation.deleteFiles, let workspace = repository.workspace else {
        return .send(
          .repositoryManagement(
            .repositoryRemoved(repository.id, selectionWasRemoved: selectionWasRemoved)
          )
        )
      }
      let repositoryID = repository.id
      let rootURL = repository.rootURL
      // Resolve the (source repo, branch) pairs the user opted to delete. The
      // deletion itself is routed through GitClient's guarded entry point so a
      // protected branch (main/master/default) can never be force-deleted.
      let branchDeletions: [WorkspaceBranchDeletion] =
        confirmation.branchOptions
        .filter(\.isSelected)
        .compactMap { option in
          guard let entry = workspace.repositories.first(where: { $0.id == option.id }),
            let sourceLocation = entry.sourceLocation,
            let branchName = entry.branchName
          else {
            return nil
          }
          return WorkspaceBranchDeletion(sourceLocation: sourceLocation, branchName: branchName)
        }
      let gitRunner = Self.workspaceGitRunner(shellClient: shellClient)
      let gitClient = self.gitClient
      return .run { send in
        let failedRepositoryNames = await ProjectWorkspace.removeWorktrees(
          workspace,
          rootURL: rootURL,
          gitRunner: gitRunner
        )
        for deletion in branchDeletions {
          let outcome = try? await gitClient.deleteLocalBranch(
            deletion.branchName,
            URL(fileURLWithPath: deletion.sourceLocation),
            true
          )
          if case .protected? = outcome {
            workspaceRemovalLog.warning(
              "Skipped deleting protected branch \(deletion.branchName) in \(deletion.sourceLocation)"
            )
          }
        }
        // Only delete the workspace folder when every worktree was unregistered;
        // otherwise ask the user, since deleting it would orphan a live worktree
        // registration in the source repository.
        if failedRepositoryNames.isEmpty {
          ProjectWorkspace.removeWorkspaceFolder(at: rootURL)
          await send(
            .repositoryManagement(
              .repositoryRemoved(repositoryID, selectionWasRemoved: selectionWasRemoved)
            )
          )
        } else {
          await send(
            .repositoryManagement(
              .workspaceCleanupReportedFailures(
                repositoryID: repositoryID,
                rootPath: rootURL.path(percentEncoded: false),
                failedRepositoryNames: failedRepositoryNames,
                selectionWasRemoved: selectionWasRemoved
              )
            )
          )
        }
      }

    case .workspaceCleanupReportedFailures(
      let repositoryID,
      let rootPath,
      let failedRepositoryNames,
      let selectionWasRemoved
    ):
      state.alert = workspaceCleanupFailureAlert(
        repositoryID: repositoryID,
        rootPath: rootPath,
        failedRepositoryNames: failedRepositoryNames,
        selectionWasRemoved: selectionWasRemoved
      )
      return .none

    case .removeFailedRepository(let repositoryID):
      state.alert = nil
      state.loadFailuresByID.removeValue(forKey: repositoryID)
      state.repositoryRoots.removeAll {
        isSameRepositoryPath($0.standardizedFileURL.path(percentEncoded: false), repositoryID)
      }
      let failedIconCleanup = iconDetectionRemovalEffect(
        repositoryID: repositoryID,
        rootURL: state.repositories[id: repositoryID]?.rootURL
      )
      let remainingRoots = state.repositoryRoots
      return .merge(
        failedIconCleanup,
        .run { send in
          let loadedEntries = await loadPersistedRepositoryEntries(fallbackRoots: remainingRoots)
          let remainingEntries = loadedEntries.filter { !isSameRepositoryPath($0.path, repositoryID) }
          await repositoryPersistence.saveRepositoryEntries(remainingEntries)
          let roots = remainingEntries.map { URL(fileURLWithPath: $0.path) }
          let (repositories, failures) = await loadRepositoriesData(remainingEntries)
          await send(
            .repositoriesLoaded(
              repositories,
              failures: failures,
              roots: roots,
              animated: true
            )
          )
        }
        .cancellable(id: CancelID.load, cancelInFlight: true)
      )

    case .repositoryRemoved(let repositoryID, let selectionWasRemoved):
      analyticsClient.capture("repository_removed", [String: Any]?.none)
      state.removingRepositoryIDs.remove(repositoryID)
      if selectionWasRemoved {
        state.selection = nil
        state.selectedWorkspaceChildID = nil
        state.shouldSelectFirstAfterReload = true
      }
      let iconCleanup = iconDetectionRemovalEffect(
        repositoryID: repositoryID,
        rootURL: state.repositories[id: repositoryID]?.rootURL
      )
      let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
      let remainingRoots = state.repositoryRoots
      return .merge(
        iconCleanup,
        .send(.delegate(.selectedWorktreeChanged(selectedWorktree))),
        .run { send in
          let loadedEntries = await loadPersistedRepositoryEntries(fallbackRoots: remainingRoots)
          let remainingEntries = loadedEntries.filter { !isSameRepositoryPath($0.path, repositoryID) }
          await repositoryPersistence.saveRepositoryEntries(remainingEntries)
          let roots = remainingEntries.map { URL(fileURLWithPath: $0.path) }
          let (repositories, failures) = await loadRepositoriesData(remainingEntries)
          await send(
            .repositoriesLoaded(
              repositories,
              failures: failures,
              roots: roots,
              animated: true
            )
          )
        }
        .cancellable(id: CancelID.load, cancelInFlight: true)
      )

    case .openRepositorySettings(let repositoryID):
      return .send(.delegate(.openRepositorySettings(repositoryID)))

    case .repositoryIconDetected(let repositoryID, let filename):
      return reduceIconDetected(state: &state, repositoryID: repositoryID, filename: filename)

    case .cancelPendingIconDetections:
      return .cancel(id: Self.iconDetectionUmbrellaID)
    }
  }

  var repositoryManagementReducer: some ReducerOf<Self> {
    Reduce { state, action in
      guard case .repositoryManagement(let action) = action else {
        return .none
      }
      return reduceRepositoryManagement(state: &state, action: action)
    }
  }

  func workspaceCleanupFailureAlert(
    repositoryID: Repository.ID,
    rootPath: String,
    failedRepositoryNames: [String],
    selectionWasRemoved: Bool
  ) -> AlertState<Alert> {
    AlertState {
      TextState(String(localized: "Some worktrees couldn't be removed"))
    } actions: {
      ButtonState(
        role: .destructive,
        action: .confirmWorkspaceRootDeletion(
          repositoryID: repositoryID,
          rootPath: rootPath,
          selectionWasRemoved: selectionWasRemoved
        )
      ) {
        TextState(String(localized: "Delete Folder Anyway"))
      }
      ButtonState(
        role: .cancel,
        action: .keepWorkspaceFolderAfterCleanupFailure(
          repositoryID: repositoryID,
          selectionWasRemoved: selectionWasRemoved
        )
      ) {
        TextState(String(localized: "Keep Folder"))
      }
    } message: {
      TextState(
        String(
          localized: """
            Couldn't unregister worktrees for \(failedRepositoryNames.joined(separator: ", ")). \
            Deleting the workspace folder now would leave those worktrees registered in their source \
            repositories. Delete it anyway?
            """
        )
      )
    }
  }
}

nonisolated private let workspaceRemovalLog = SupaLogger("workspace")

nonisolated struct WorkspaceBranchDeletion: Sendable, Equatable {
  let sourceLocation: String
  let branchName: String
}

// Path-based URL APIs append a trailing slash only while the directory exists
// on disk, so an ID captured before a deletion may not equal the re-normalized
// entry path afterwards.
nonisolated private func isSameRepositoryPath(_ lhs: String, _ rhs: String) -> Bool {
  comparableRepositoryPath(lhs) == comparableRepositoryPath(rhs)
}

nonisolated private func comparableRepositoryPath(_ path: String) -> String {
  var path = path
  while path.count > 1, path.hasSuffix("/") {
    path.removeLast()
  }
  return path
}
