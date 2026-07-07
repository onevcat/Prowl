import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Sharing
import SwiftUI

extension RepositoriesFeature {
  func detectCodeHostsEffect(for repositories: IdentifiedArrayOf<Repository>) -> Effect<Action>? {
    let targets =
      repositories
      .filter { $0.capabilities.supportsCodeHost }
      .map { (id: $0.id, rootURL: $0.rootURL) }
    guard !targets.isEmpty else { return nil }
    let gitClient = gitClient
    return .run { send in
      var detected: [Repository.ID: CodeHost] = [:]
      await withTaskGroup(of: (Repository.ID, CodeHost).self) { group in
        for target in targets {
          group.addTask {
            let host = await gitClient.repositoryWebURL(target.rootURL)?.host
            return (target.id, CodeHost.from(host: host))
          }
        }
        for await (id, host) in group {
          detected[id] = host
        }
      }
      // `codeHost(for:)` defaults to `.unknown`, so storing `.unknown`
      // explicitly is a no-op. Skip the round trip when nothing is known.
      let meaningful = detected.filter { $0.value != .unknown }
      guard !meaningful.isEmpty else { return }
      await send(.codeHostsDetected(meaningful))
    }
  }

  func loadPersistedRepositoryEntries(
    fallbackRoots: [URL] = []
  ) async -> [PersistedRepositoryEntry] {
    let entries = await repositoryPersistence.loadRepositoryEntries()
    let resolvedEntries: [PersistedRepositoryEntry]
    if !entries.isEmpty {
      resolvedEntries = entries
    } else {
      let loadedPaths = await repositoryPersistence.loadRoots()
      let pathSource =
        if !loadedPaths.isEmpty {
          loadedPaths
        } else {
          fallbackRoots.map { $0.path(percentEncoded: false) }
        }
      resolvedEntries = RepositoryEntryNormalizer.normalize(
        pathSource.map { PersistedRepositoryEntry(path: $0, kind: .git) }
      )
    }
    return await upgradedRepositoryEntriesIfNeeded(resolvedEntries)
  }

  func upgradedRepositoryEntriesIfNeeded(
    _ entries: [PersistedRepositoryEntry]
  ) async -> [PersistedRepositoryEntry] {
    let upgradedEntries = await withTaskGroup(of: (Int, PersistedRepositoryEntry).self) { group in
      for (index, entry) in entries.enumerated() {
        let gitClient = self.gitClient
        group.addTask {
          let normalizedPath = URL(fileURLWithPath: entry.path)
            .standardizedFileURL
            .path(percentEncoded: false)
          do {
            let repoRoot = try await gitClient.repoRoot(URL(fileURLWithPath: normalizedPath))
            let normalizedRepoRoot = repoRoot.standardizedFileURL.path(percentEncoded: false)
            if entry.kind == .plain, normalizedRepoRoot == normalizedPath {
              return (index, PersistedRepositoryEntry(path: normalizedPath, kind: .git))
            }
          } catch {
            return (index, PersistedRepositoryEntry(path: normalizedPath, kind: entry.kind))
          }
          return (index, PersistedRepositoryEntry(path: normalizedPath, kind: entry.kind))
        }
      }

      var results = [PersistedRepositoryEntry?](repeating: nil, count: entries.count)
      for await (index, entry) in group {
        results[index] = entry
      }
      return results.compactMap { $0 }
    }

    let normalizedEntries = RepositoryEntryNormalizer.normalize(upgradedEntries)
    if normalizedEntries != entries {
      await repositoryPersistence.saveRepositoryEntries(normalizedEntries)
    }
    return normalizedEntries
  }

  nonisolated static func isNotGitRepositoryError(_ error: any Error) -> Bool {
    guard case GitClientError.commandFailed(_, let message) = error else {
      return false
    }
    return message.localizedCaseInsensitiveContains("not a git repository")
  }

  nonisolated static func openRepositoryFailureMessage(path: String, error: any Error) -> String {
    let detail: String
    if case GitClientError.commandFailed(_, let message) = error,
      !message.isEmpty
    {
      detail = message
    } else {
      detail = error.localizedDescription
    }
    return "\(path): \(detail)"
  }

  func loadRepositories(
    fallbackRoots: [URL] = [],
    animated: Bool = false
  ) -> Effect<Action> {
    let gitClient = gitClient
    return .run { [animated, fallbackRoots] send in
      let entries = await loadPersistedRepositoryEntries(fallbackRoots: fallbackRoots)
      let roots = entries.map { URL(fileURLWithPath: $0.path) }
      for entry in entries where entry.kind == .git {
        _ = try? await gitClient.pruneWorktrees(URL(fileURLWithPath: entry.path))
      }
      let (repositories, failures) = await loadRepositoriesData(entries)
      await send(
        .repositoriesLoaded(
          repositories,
          failures: failures,
          roots: roots,
          animated: animated
        )
      )
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }

  private struct WorktreesFetchResult: Sendable {
    let entry: PersistedRepositoryEntry
    let repository: Repository?
    let errorMessage: String?
  }

  private struct FilteredLoadedRepositoryState {
    let repositories: IdentifiedArrayOf<Repository>
    let availableWorktreeIDs: Set<Worktree.ID>
    let pendingWorktrees: [PendingWorktree]
    let deletingWorktreeIDs: Set<Worktree.ID>
    let pendingSetupScriptWorktreeIDs: Set<Worktree.ID>
    let pendingTerminalFocusWorktreeIDs: Set<Worktree.ID>
    let archivingWorktreeIDs: Set<Worktree.ID>
    let archiveScriptProgressByWorktreeID: [Worktree.ID: ArchiveScriptProgress]
    let worktreeInfoByID: [Worktree.ID: WorktreeInfoEntry]
  }

  func loadRepositoriesData(_ entries: [PersistedRepositoryEntry]) async -> ([Repository], [LoadFailure]) {
    let fetchResults = await withTaskGroup(of: WorktreesFetchResult.self) { group in
      for entry in entries {
        group.addTask {
          await fetchRepositoryData(for: entry)
        }
      }

      var resultsByRootID: [Repository.ID: WorktreesFetchResult] = [:]
      for await result in group {
        resultsByRootID[Self.repositoryRootID(for: result.entry.path)] = result
      }
      return resultsByRootID
    }

    return Self.partitionFetchResults(fetchResults, orderedBy: entries)
  }

  private func fetchRepositoryData(for entry: PersistedRepositoryEntry) async -> WorktreesFetchResult {
    let rootURL = URL(fileURLWithPath: entry.path).standardizedFileURL
    switch entry.kind {
    case .git:
      do {
        let worktrees = try await gitClient.worktrees(rootURL)
        return WorktreesFetchResult(
          entry: entry,
          repository: Repository(
            id: rootURL.path(percentEncoded: false),
            rootURL: rootURL,
            name: Repository.name(for: rootURL),
            kind: .git,
            worktrees: IdentifiedArray(worktrees, uniquingIDsWith: { current, _ in current })
          ),
          errorMessage: nil
        )
      } catch {
        return WorktreesFetchResult(
          entry: entry,
          repository: nil,
          errorMessage: error.localizedDescription
        )
      }
    case .plain:
      return WorktreesFetchResult(
        entry: entry,
        repository: Repository(
          id: rootURL.path(percentEncoded: false),
          rootURL: rootURL,
          name: Repository.name(for: rootURL),
          kind: .plain,
          worktrees: IdentifiedArray()
        ),
        errorMessage: nil
      )
    }
  }

  nonisolated private static func partitionFetchResults(
    _ fetchResults: [Repository.ID: WorktreesFetchResult],
    orderedBy entries: [PersistedRepositoryEntry]
  ) -> ([Repository], [LoadFailure]) {
    var loaded: [Repository] = []
    var failures: [LoadFailure] = []
    for entry in entries {
      let rootID = repositoryRootID(for: entry.path)
      guard let result = fetchResults[rootID] else { continue }
      if let repository = result.repository {
        loaded.append(repository)
      } else {
        failures.append(
          LoadFailure(
            rootID: rootID,
            message: result.errorMessage ?? "Unknown error"
          )
        )
      }
    }
    return (loaded, failures)
  }

  nonisolated private static func repositoryRootID(for path: String) -> Repository.ID {
    URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false)
  }

  private func filteredLoadedRepositoryState(
    _ repositories: [Repository],
    state: inout State
  ) -> FilteredLoadedRepositoryState {
    let previousCounts = Dictionary(
      uniqueKeysWithValues: state.repositories.map { ($0.id, $0.worktrees.count) }
    )
    let repositoryIDs = Set(repositories.map(\.id))
    let newCounts = Dictionary(
      uniqueKeysWithValues: repositories.map { ($0.id, $0.worktrees.count) }
    )
    var addedCounts: [Repository.ID: Int] = [:]
    for (id, newCount) in newCounts {
      let oldCount = previousCounts[id] ?? 0
      let added = newCount - oldCount
      if added > 0 {
        addedCounts[id] = added
      }
    }

    let pendingWorktrees = state.pendingWorktrees.filter { pending in
      guard repositoryIDs.contains(pending.repositoryID) else { return false }
      guard let remaining = addedCounts[pending.repositoryID], remaining > 0 else { return true }
      addedCounts[pending.repositoryID] = remaining - 1
      return false
    }

    let availableWorktreeIDs = Set(repositories.flatMap { $0.worktrees.map(\.id) })
    let archivingWorktreeIDs = state.archivingWorktreeIDs
    state.$prowlCreatedWorktreeIDs.withLock {
      $0.removeAll { !availableWorktreeIDs.contains($0) }
    }

    return FilteredLoadedRepositoryState(
      repositories: IdentifiedArray(uniqueElements: repositories),
      availableWorktreeIDs: availableWorktreeIDs,
      pendingWorktrees: pendingWorktrees,
      deletingWorktreeIDs: state.deletingWorktreeIDs.intersection(availableWorktreeIDs),
      pendingSetupScriptWorktreeIDs: state.pendingSetupScriptWorktreeIDs.filter {
        availableWorktreeIDs.contains($0)
      },
      pendingTerminalFocusWorktreeIDs: state.pendingTerminalFocusWorktreeIDs.filter {
        availableWorktreeIDs.contains($0)
      },
      archivingWorktreeIDs: archivingWorktreeIDs,
      archiveScriptProgressByWorktreeID: state.archiveScriptProgressByWorktreeID.filter {
        availableWorktreeIDs.contains($0.key) || archivingWorktreeIDs.contains($0.key)
      },
      worktreeInfoByID: state.worktreeInfoByID.filter {
        availableWorktreeIDs.contains($0.key)
      }
    )
  }

  private func applyLoadedRepositoryState(
    _ filteredState: FilteredLoadedRepositoryState,
    state: inout State,
    animated: Bool
  ) {
    if animated {
      withAnimation {
        state.repositories = filteredState.repositories
        state.pendingWorktrees = filteredState.pendingWorktrees
        state.deletingWorktreeIDs = filteredState.deletingWorktreeIDs
        state.pendingSetupScriptWorktreeIDs = filteredState.pendingSetupScriptWorktreeIDs
        state.pendingTerminalFocusWorktreeIDs = filteredState.pendingTerminalFocusWorktreeIDs
        state.archivingWorktreeIDs = filteredState.archivingWorktreeIDs
        state.archiveScriptProgressByWorktreeID = filteredState.archiveScriptProgressByWorktreeID
        state.worktreeInfoByID = filteredState.worktreeInfoByID
      }
    } else {
      state.repositories = filteredState.repositories
      state.pendingWorktrees = filteredState.pendingWorktrees
      state.deletingWorktreeIDs = filteredState.deletingWorktreeIDs
      state.pendingSetupScriptWorktreeIDs = filteredState.pendingSetupScriptWorktreeIDs
      state.pendingTerminalFocusWorktreeIDs = filteredState.pendingTerminalFocusWorktreeIDs
      state.archivingWorktreeIDs = filteredState.archivingWorktreeIDs
      state.archiveScriptProgressByWorktreeID = filteredState.archiveScriptProgressByWorktreeID
      state.worktreeInfoByID = filteredState.worktreeInfoByID
    }
  }

  func applyRepositories(
    _ repositories: [Repository],
    roots: [URL],
    shouldPruneArchivedWorktrees: Bool,
    state: inout State,
    animated: Bool
  ) -> ApplyRepositoriesResult {
    @Shared(.appStorage(restoreCanvasModeOnLaunchAppStorageKey)) var restoreCanvasModeOnLaunch = false
    let filteredState = filteredLoadedRepositoryState(repositories, state: &state)
    applyLoadedRepositoryState(filteredState, state: &state, animated: animated)
    let didPrunePinned = prunePinnedWorktreeIDs(state: &state)
    let didPruneRepositoryOrder = pruneRepositoryOrderIDs(roots: roots, state: &state)
    let didPruneWorktreeOrder = pruneWorktreeOrderByRepository(roots: roots, state: &state)
    let didPruneArchivedWorktrees =
      shouldPruneArchivedWorktrees
      ? pruneArchivedWorktrees(availableWorktreeIDs: filteredState.availableWorktreeIDs, state: &state)
      : false
    if !state.isShowingArchivedWorktrees, !state.isShowingCanvas, !state.isShowingFreestyle,
      !isSidebarSelectionValid(state.selection, state: state)
    {
      state.selection = nil
    }
    var didRestoreCanvasModeOnLaunch = false
    var restoredCanvasTerminalTarget: Worktree?
    if state.shouldRestoreLastFocusedWorktree,
      state.selection == nil,
      restoreCanvasModeOnLaunch,
      !state.orderedWorktreeRows().isEmpty
    {
      let fallbackWorktreeID =
        if isSelectionValid(state.lastFocusedWorktreeID, state: state) {
          state.lastFocusedWorktreeID
        } else {
          state.orderedWorktreeRows().first?.id
        }
      state.preCanvasWorktreeID = fallbackWorktreeID
      state.preCanvasTerminalTargetID = fallbackWorktreeID
      if let fallbackWorktreeID {
        state.canvasReturnWorktreeID = fallbackWorktreeID
      }
      restoredCanvasTerminalTarget = terminalTarget(for: fallbackWorktreeID, state: state)
      state.selection = .canvas
      state.sidebarSelectedWorktreeIDs = []
      state.shouldCenterRestoredCanvasSoloTab = true
      state.shouldFocusRestoredCanvasAtScaleOne = true
      state.shouldRestoreLastFocusedWorktree = false
      didRestoreCanvasModeOnLaunch = true
    }
    if state.shouldRestoreLastFocusedWorktree {
      state.shouldRestoreLastFocusedWorktree = false
      if state.selection == nil,
        isSelectionValid(state.lastFocusedWorktreeID, state: state)
      {
        state.selection = state.lastFocusedWorktreeID.map(SidebarSelection.worktree)
      }
    }
    if state.selection == nil, state.shouldSelectFirstAfterReload {
      state.selection = firstAvailableWorktreeID(from: repositories, state: state)
        .map(SidebarSelection.worktree)
      state.shouldSelectFirstAfterReload = false
    }
    return ApplyRepositoriesResult(
      didPrunePinned: didPrunePinned,
      didPruneRepositoryOrder: didPruneRepositoryOrder,
      didPruneWorktreeOrder: didPruneWorktreeOrder,
      didPruneArchivedWorktrees: didPruneArchivedWorktrees,
      didRestoreCanvasModeOnLaunch: didRestoreCanvasModeOnLaunch,
      restoredCanvasTerminalTarget: restoredCanvasTerminalTarget
    )
  }

  func terminalTarget(
    for worktreeID: Worktree.ID?,
    state: State
  ) -> Worktree? {
    guard let worktreeID else { return nil }
    if let worktree = state.worktree(for: worktreeID) {
      return worktree
    }
    guard let repository = state.repositories[id: worktreeID],
      repository.capabilities.supportsRunnableFolderActions,
      !repository.capabilities.supportsWorktrees
    else {
      return nil
    }
    return Worktree(
      id: repository.id,
      name: repository.name,
      detail: repository.rootURL.path(percentEncoded: false),
      workingDirectory: repository.rootURL,
      repositoryRootURL: repository.rootURL
    )
  }

  func messageAlert(title: String, message: String) -> AlertState<Alert> {
    AlertState {
      TextState(title)
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState(message)
    }
  }

  func confirmationAlertForRepositoryRemoval(
    repositoryID: Repository.ID,
    state: State
  ) -> AlertState<Alert>? {
    guard let repository = state.repositories[id: repositoryID] else {
      return nil
    }
    return AlertState {
      TextState("Remove repository?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmRemoveRepository(repository.id)) {
        TextState("Remove repository")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(
        "This removes the repository from Prowl. "
          + "Worktrees and the main repository folder stay on disk."
      )
    }
  }

  func selectionDidChange(
    previousSelectionID: Worktree.ID?,
    previousSelectedWorktree: Worktree?,
    selectedWorktreeID: Worktree.ID?,
    selectedWorktree: Worktree?
  ) -> Bool {
    if previousSelectionID != selectedWorktreeID {
      return true
    }
    if previousSelectedWorktree?.workingDirectory != selectedWorktree?.workingDirectory {
      return true
    }
    if previousSelectedWorktree?.repositoryRootURL != selectedWorktree?.repositoryRootURL {
      return true
    }
    return false
  }
}
