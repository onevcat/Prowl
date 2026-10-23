import ComposableArchitecture
import Foundation
import IdentifiedCollections
import SwiftUI

extension RepositoriesFeature {
  func detectCodeHostsEffect(
    for repositories: IdentifiedArrayOf<Repository>,
    includeUnknown: Bool = false
  ) -> Effect<Action>? {
    let targets =
      repositories
      .filter { $0.capabilities.supportsCodeHost }
      .map { (id: $0.id, location: $0.location) }
    guard !targets.isEmpty else { return nil }
    let repositoryHost = repositoryHost
    return .run { send in
      var detected: [Repository.ID: CodeHost] = [:]
      await withTaskGroup(of: (Repository.ID, CodeHost).self) { group in
        for target in targets {
          group.addTask {
            let host = await repositoryHost.repositoryWebURL(for: target.location)?.host
            return (target.id, CodeHost.from(host: host))
          }
        }
        for await (id, host) in group {
          detected[id] = host
        }
      }
      // `codeHost(for:)` defaults to `.unknown`, so storing `.unknown`
      // explicitly is a no-op. Skip the round trip when nothing is known.
      let meaningful = includeUnknown ? detected : detected.filter { $0.value != .unknown }
      guard !meaningful.isEmpty else { return }
      await send(.codeHostsDetected(meaningful))
    }
  }

  func loadPersistedRepositoryEntries(
    fallbackRoots: [RepositoryLocation] = []
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
          fallbackRoots.map(\.id)
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
          // A remote entry is not a local path; its host checks it when it loads (docs-ai 084 B3).
          if RepositoryLocation.hasRemoteForm(entry.path) { return (index, entry) }
          let normalizedPath = URL(fileURLWithPath: entry.path)
            .standardizedFileURL
            .path(percentEncoded: false)
          if ProjectWorkspace.load(from: URL(fileURLWithPath: normalizedPath)) != nil {
            return (index, PersistedRepositoryEntry(path: normalizedPath, kind: .plain))
          }
          do {
            let repoRoot = try await gitClient.repoRoot(URL(fileURLWithPath: normalizedPath))
            let normalizedRepoRoot = repoRoot.standardizedFileURL.path(percentEncoded: false)
            if Self.pathsReferToSameFileSystemLocation(normalizedPath, normalizedRepoRoot) {
              return (index, PersistedRepositoryEntry(path: normalizedRepoRoot, kind: .git))
            }
            return (index, PersistedRepositoryEntry(path: normalizedPath, kind: .plain))
          } catch {
            if entry.kind == .git,
              Self.isNotGitRepositoryError(error),
              FileManager.default.fileExists(atPath: normalizedPath)
            {
              return (index, PersistedRepositoryEntry(path: normalizedPath, kind: .plain))
            }
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
    if case GitClientError.notRepository = error { return true }
    return false
  }

  nonisolated static func pathsReferToSameFileSystemLocation(_ lhs: String, _ rhs: String) -> Bool {
    let lhsURL = URL(fileURLWithPath: lhs).resolvingSymlinksInPath().standardizedFileURL
    let rhsURL = URL(fileURLWithPath: rhs).resolvingSymlinksInPath().standardizedFileURL
    return lhsURL == rhsURL
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
    fallbackRoots: [RepositoryLocation] = [],
    animated: Bool = false
  ) -> Effect<Action> {
    let repositoryHost = repositoryHost
    return .run { [animated, fallbackRoots] send in
      let entries = await loadPersistedRepositoryEntries(fallbackRoots: fallbackRoots)
      let roots = entries.map(\.location)
      // A remote prune would add a connection per entry to every reload; the refresh lists
      // a worktree whose folder is gone, so remote entries skip it (docs-ai 084 B3e).
      for entry in entries where entry.kind == .git && entry.location.localURL != nil {
        _ = try? await repositoryHost.pruneWorktrees(in: entry.location)
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
    var isGitUnavailable: Bool = false
    var isHostUnreachable: Bool = false
  }

  /// How long a load waits for a remote host before it reports the host unreachable, so a
  /// host that does not answer never holds back the other repositories. The refresh
  /// cadence (B3f) tries it again.
  static let remoteLoadDeadline: Duration = .seconds(10)

  func loadRepositoriesData(_ entries: [PersistedRepositoryEntry]) async -> ([Repository], [LoadFailure]) {
    let clock = clock
    let fetchResults = await withTaskGroup(of: WorktreesFetchResult.self) { group in
      for entry in entries {
        let repositoryHost = self.repositoryHost
        group.addTask {
          // A remote folder loads through its host, within a deadline (docs-ai 084 B3e).
          guard case .remote = entry.location else {
            return await Self.loadRepository(entry, host: repositoryHost)
          }
          return await Self.withDeadline(Self.remoteLoadDeadline, clock: clock) {
            await Self.loadRepository(entry, host: repositoryHost)
          } onTimeout: {
            WorktreesFetchResult(
              entry: entry, repository: nil,
              errorMessage: RemoteRepositoryHostError.timedOut.localizedDescription, isHostUnreachable: true)
          }
        }
      }

      var resultsByRootID: [Repository.ID: WorktreesFetchResult] = [:]
      for await result in group {
        resultsByRootID[result.entry.location.standardized.id] = result
      }
      return resultsByRootID
    }

    var loaded: [Repository] = []
    var failures: [LoadFailure] = []
    for entry in entries {
      let rootID = entry.location.standardized.id
      guard let result = fetchResults[rootID] else { continue }
      if let repository = result.repository {
        loaded.append(repository)
      } else {
        failures.append(
          LoadFailure(
            rootID: rootID,
            message: result.errorMessage ?? String(localized: "Unknown error"),
            isGitUnavailable: result.isGitUnavailable,
            isHostUnreachable: result.isHostUnreachable
          )
        )
      }
    }
    return (loaded, failures)
  }

  /// Loads one entry through `host`, which runs a local location on this Mac and a remote
  /// one on its host. A plain folder loads without a check, as before; a remote one only
  /// needs its host to be known. Workspaces are local only (A4a).
  private nonisolated static func loadRepository(
    _ entry: PersistedRepositoryEntry, host: RepositoryHost
  ) async -> WorktreesFetchResult {
    let location: RepositoryLocation =
      switch entry.location {
      case .local: .local(URL(fileURLWithPath: entry.path).standardizedFileURL)
      case .remote: entry.location
      }
    do {
      switch entry.kind {
      case .git:
        let worktrees = try await host.worktrees(in: location)
        return WorktreesFetchResult(
          entry: entry,
          repository: Repository(
            location: location, name: Repository.name(for: location), kind: .git,
            worktrees: IdentifiedArray(worktrees, uniquingIDsWith: { current, _ in current })),
          errorMessage: nil
        )
      case .plain:
        if location.localURL == nil { try await host.requireRemoteHost(for: location) }
        let workspace = location.localURL.flatMap(ProjectWorkspace.load(from:))
        return WorktreesFetchResult(
          entry: entry,
          repository: Repository(
            location: location, name: workspace?.title ?? Repository.name(for: location), kind: .plain,
            worktrees: IdentifiedArray(), workspace: workspace),
          errorMessage: nil
        )
      }
    } catch {
      return WorktreesFetchResult(
        entry: entry, repository: nil, errorMessage: error.localizedDescription,
        isGitUnavailable: {
          if case GitClientError.unavailable = error { return true }
          return false
        }(),
        isHostUnreachable: isRemoteHostUnreachable(error))
    }
  }

  /// `operation`'s result, or `onTimeout`'s when `deadline` passes first; the operation is
  /// then cancelled, which stops its command.
  private nonisolated static func withDeadline(
    _ deadline: Duration, clock: any Clock<Duration>,
    operation: @escaping @Sendable () async -> WorktreesFetchResult,
    onTimeout: @escaping @Sendable () -> WorktreesFetchResult
  ) async -> WorktreesFetchResult {
    await withTaskGroup(of: WorktreesFetchResult?.self) { group in
      group.addTask { await operation() }
      group.addTask {
        try? await clock.sleep(for: deadline)
        return Task.isCancelled ? nil : onTimeout()
      }
      for await result in group {
        guard let result else { continue }
        group.cancelAll()
        return result
      }
      return onTimeout()
    }
  }

  /// Keeps the failures of a load: their messages, and which ones lack git or a reachable
  /// host.
  func recordLoadFailures(_ failures: [LoadFailure], state: inout State) {
    state.loadFailuresByID = Dictionary(
      failures.map { ($0.rootID, $0.message) },
      uniquingKeysWith: { first, _ in first }
    )
    state.gitUnavailableRepositoryIDs = Set(failures.filter(\.isGitUnavailable).map(\.rootID))
    state.unreachableRepositoryIDs = Set(failures.filter(\.isHostUnreachable).map(\.rootID))
  }

  func applyRepositories(
    _ repositories: [Repository],
    roots: [RepositoryLocation],
    shouldPruneArchivedWorktrees: Bool,
    state: inout State,
    animated: Bool
  ) -> ApplyRepositoriesResult {
    let previousCounts = Dictionary(
      state.repositories.map { ($0.id, $0.worktrees.count) },
      uniquingKeysWith: { first, _ in first }
    )
    let repositoryIDs = Set(repositories.map(\.id))
    let newCounts = Dictionary(
      repositories.map { ($0.id, $0.worktrees.count) },
      uniquingKeysWith: { first, _ in first }
    )
    var addedCounts: [Repository.ID: Int] = [:]
    for (id, newCount) in newCounts {
      let oldCount = previousCounts[id] ?? 0
      let added = newCount - oldCount
      if added > 0 {
        addedCounts[id] = added
      }
    }
    let filteredPendingWorktrees = state.pendingWorktrees.filter { pending in
      guard repositoryIDs.contains(pending.repositoryID) else { return false }
      guard let remaining = addedCounts[pending.repositoryID], remaining > 0 else { return true }
      addedCounts[pending.repositoryID] = remaining - 1
      return false
    }
    let availableWorktreeIDs = Set(repositories.flatMap { $0.worktrees.map(\.id) })
    let filteredDeletingIDs = state.deletingWorktreeIDs.intersection(availableWorktreeIDs)
    let filteredSetupScriptIDs = state.pendingSetupScriptWorktreeIDs.filter {
      availableWorktreeIDs.contains($0)
    }
    let filteredFocusIDs = state.pendingTerminalFocusWorktreeIDs.filter {
      availableWorktreeIDs.contains($0)
    }
    let filteredArchivingIDs = state.archivingWorktreeIDs
    let filteredArchiveScriptProgress = state.archiveScriptProgressByWorktreeID.filter {
      availableWorktreeIDs.contains($0.key) || filteredArchivingIDs.contains($0.key)
    }
    let filteredWorktreeInfo = state.worktreeInfoByID.filter {
      availableWorktreeIDs.contains($0.key)
    }
    state.forgetPullRequestRefreshHistory(keeping: availableWorktreeIDs)
    state.$prowlCreatedWorktreeIDs.withLock {
      $0.removeAll { !availableWorktreeIDs.contains($0) }
    }
    let identifiedRepositories = IdentifiedArray(uniqueElements: repositories)
    if animated {
      withAnimation {
        state.repositories = identifiedRepositories
        state.pendingWorktrees = filteredPendingWorktrees
        state.deletingWorktreeIDs = filteredDeletingIDs
        state.pendingSetupScriptWorktreeIDs = filteredSetupScriptIDs
        state.pendingTerminalFocusWorktreeIDs = filteredFocusIDs
        state.archivingWorktreeIDs = filteredArchivingIDs
        state.archiveScriptProgressByWorktreeID = filteredArchiveScriptProgress
        state.worktreeInfoByID = filteredWorktreeInfo
      }
    } else {
      state.repositories = identifiedRepositories
      state.pendingWorktrees = filteredPendingWorktrees
      state.deletingWorktreeIDs = filteredDeletingIDs
      state.pendingSetupScriptWorktreeIDs = filteredSetupScriptIDs
      state.pendingTerminalFocusWorktreeIDs = filteredFocusIDs
      state.archivingWorktreeIDs = filteredArchivingIDs
      state.archiveScriptProgressByWorktreeID = filteredArchiveScriptProgress
      state.worktreeInfoByID = filteredWorktreeInfo
    }
    let didPrunePinned = prunePinnedWorktreeIDs(state: &state)
    let didPruneRepositoryOrder = pruneRepositoryOrderIDs(roots: roots, state: &state)
    let didPruneWorktreeOrder = pruneWorktreeOrderByRepository(roots: roots, state: &state)
    let didPruneArchivedWorktrees =
      shouldPruneArchivedWorktrees
      ? pruneArchivedWorktrees(availableWorktreeIDs: availableWorktreeIDs, state: &state)
      : false
    if !state.isShowingArchivedWorktrees, !state.isShowingCanvas,
      !isSidebarSelectionValid(state.selection, state: state)
    {
      state.selection = nil
      state.selectedWorkspaceChildID = nil
    }
    if state.shouldRestoreLastFocusedWorktree {
      state.shouldRestoreLastFocusedWorktree = false
      if state.selection == nil,
        isSelectionValid(state.lastFocusedWorktreeID, state: state)
      {
        state.selection = state.lastFocusedWorktreeID.map(SidebarSelection.worktree)
        state.selectedWorkspaceChildID = nil
      }
    }
    if state.selection == nil, state.shouldSelectFirstAfterReload {
      state.selection = firstAvailableWorktreeID(from: repositories, state: state)
        .map(SidebarSelection.worktree)
      state.selectedWorkspaceChildID = nil
      state.shouldSelectFirstAfterReload = false
    }
    pruneWorkspaceChildInfo(state: &state)
    return ApplyRepositoriesResult(
      didPrunePinned: didPrunePinned,
      didPruneRepositoryOrder: didPruneRepositoryOrder,
      didPruneWorktreeOrder: didPruneWorktreeOrder,
      didPruneArchivedWorktrees: didPruneArchivedWorktrees
    )
  }

  func messageAlert(title: String, message: String) -> AlertState<Alert> {
    AlertState {
      TextState(title)
    } actions: {
      ButtonState(role: .cancel) {
        TextState(String(localized: "OK"))
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
      TextState(String(localized: "Remove repository?"))
    } actions: {
      ButtonState(role: .destructive, action: .confirmRemoveRepository(repository.id)) {
        TextState(String(localized: "Remove repository"))
      }
      ButtonState(role: .cancel) {
        TextState(String(localized: "Cancel"))
      }
    } message: {
      TextState(
        String(
          localized: "This removes the repository from Prowl. Worktrees and the main repository folder stay on disk.")
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
    if previousSelectedWorktree?.location != selectedWorktree?.location {
      return true
    }
    if previousSelectedWorktree?.repositoryLocation != selectedWorktree?.repositoryLocation {
      return true
    }
    return false
  }
}
