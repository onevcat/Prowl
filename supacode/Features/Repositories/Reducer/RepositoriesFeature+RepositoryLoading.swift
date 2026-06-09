import ComposableArchitecture
import Foundation
import IdentifiedCollections
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
          if ProjectWorkspace.load(from: URL(fileURLWithPath: normalizedPath)) != nil {
            return (index, PersistedRepositoryEntry(path: normalizedPath, kind: .plain))
          }
          do {
            let repoRoot = try await gitClient.repoRoot(URL(fileURLWithPath: normalizedPath))
            let normalizedRepoRoot = repoRoot.standardizedFileURL.path(percentEncoded: false)
            switch entry.kind {
            case .plain:
              if normalizedRepoRoot == normalizedPath {
                return (index, PersistedRepositoryEntry(path: normalizedPath, kind: .git))
              }
              return (index, PersistedRepositoryEntry(path: normalizedPath, kind: .plain))
            case .git:
              if normalizedRepoRoot == normalizedPath {
                return (index, PersistedRepositoryEntry(path: normalizedPath, kind: .git))
              }
              return (index, PersistedRepositoryEntry(path: normalizedPath, kind: .plain))
            }
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

  func loadRepositoriesData(_ entries: [PersistedRepositoryEntry]) async -> ([Repository], [LoadFailure]) {
    let fetchResults = await withTaskGroup(of: WorktreesFetchResult.self) { group in
      for entry in entries {
        let gitClient = self.gitClient
        group.addTask {
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
            let workspace = ProjectWorkspace.load(from: rootURL)
            return WorktreesFetchResult(
              entry: entry,
              repository: Repository(
                id: rootURL.path(percentEncoded: false),
                rootURL: rootURL,
                name: workspace?.title ?? Repository.name(for: rootURL),
                kind: .plain,
                worktrees: IdentifiedArray(),
                workspace: workspace
              ),
              errorMessage: nil
            )
          }
        }
      }

      var resultsByRootID: [Repository.ID: WorktreesFetchResult] = [:]
      for await result in group {
        let rootID = URL(fileURLWithPath: result.entry.path).standardizedFileURL.path(percentEncoded: false)
        resultsByRootID[rootID] = result
      }
      return resultsByRootID
    }

    var loaded: [Repository] = []
    var failures: [LoadFailure] = []
    for entry in entries {
      let normalizedRoot = URL(fileURLWithPath: entry.path).standardizedFileURL
      let rootID = normalizedRoot.path(percentEncoded: false)
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

  func applyRepositories(
    _ repositories: [Repository],
    roots: [URL],
    shouldPruneArchivedWorktrees: Bool,
    state: inout State,
    animated: Bool
  ) -> ApplyRepositoriesResult {
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
      didPruneArchivedWorktrees: didPruneArchivedWorktrees
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
