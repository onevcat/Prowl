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
        uniqueKeysWithValues: failures.map { ($0.rootID, $0.message) }
      )
      let openFailureMessages = invalidRoots.map { "\($0) is not a Git repository." } + openFailures
      if !openFailureMessages.isEmpty {
        state.alert = messageAlert(
          title: "Some folders couldn't be opened",
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
      return .merge(allEffects)

    case .requestRemoveRepository(let repositoryID):
      state.alert = confirmationAlertForRepositoryRemoval(repositoryID: repositoryID, state: state)
      return .none

    case .removeFailedRepository(let repositoryID):
      state.alert = nil
      state.loadFailuresByID.removeValue(forKey: repositoryID)
      state.repositoryRoots.removeAll {
        $0.standardizedFileURL.path(percentEncoded: false) == repositoryID
      }
      let remainingRoots = state.repositoryRoots
      return .run { send in
        let loadedEntries = await loadPersistedRepositoryEntries(fallbackRoots: remainingRoots)
        let remainingEntries = loadedEntries.filter { $0.path != repositoryID }
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

    case .repositoryRemoved(let repositoryID, let selectionWasRemoved):
      analyticsClient.capture("repository_removed", [String: Any]?.none)
      state.removingRepositoryIDs.remove(repositoryID)
      if selectionWasRemoved {
        state.selection = nil
        state.shouldSelectFirstAfterReload = true
      }
      let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
      let remainingRoots = state.repositoryRoots
      return .merge(
        .send(.delegate(.selectedWorktreeChanged(selectedWorktree))),
        .run { send in
          let loadedEntries = await loadPersistedRepositoryEntries(fallbackRoots: remainingRoots)
          let remainingEntries = loadedEntries.filter { $0.path != repositoryID }
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
}
