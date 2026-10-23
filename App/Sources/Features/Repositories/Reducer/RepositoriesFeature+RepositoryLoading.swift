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

  /// The entries that load and show. While remote folders are off (`PROWL_REMOTE_FOLDERS`),
  /// a stored remote folder stays stored but does not load, show or connect (docs-ai 084
  /// D7); the prunes keep its pins and orders (`keepsHiddenRemoteID`).
  func shownEntries(_ entries: [PersistedRepositoryEntry]) -> [PersistedRepositoryEntry] {
    remoteFoldersEnabled ? entries : entries.filter { !RepositoryLocation.hasRemoteForm($0.path) }
  }

  /// Whether a prune keeps `id` although it is not loaded: the ID of a remote folder, or
  /// of its worktree, while remote folders are off.
  var keepsHiddenRemoteID: @Sendable (String) -> Bool {
    let hidesRemoteFolders = !remoteFoldersEnabled
    return { hidesRemoteFolders && RepositoryLocation.hasRemoteForm($0) }
  }

  /// The IDs that the prunes keep although they are not loaded.
  private func keptIDs(keepsRemoteIDs: Bool) -> @Sendable (String) -> Bool {
    let keepsHidden = keepsHiddenRemoteID
    return { keepsRemoteIDs ? RepositoryLocation.hasRemoteForm($0) : keepsHidden($0) }
  }

  /// `visibleOrder` with the hidden IDs of `storedOrder` put back at their places, so a
  /// reorder while remote folders are off keeps the hidden folders' places.
  nonisolated static func mergingHiddenRepositoryIDs(
    _ visibleOrder: [Repository.ID], into storedOrder: [Repository.ID], isHidden: (Repository.ID) -> Bool
  ) -> [Repository.ID] {
    let visible = Set(visibleOrder)
    var merged = visibleOrder
    for (index, id) in storedOrder.enumerated() where isHidden(id) && !visible.contains(id) {
      merged.insert(id, at: min(index, merged.count))
    }
    return merged
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

  /// `knownRemoteRepositories` are loaded remote repositories that the load keeps as they
  /// are instead of asking their hosts (docs-ai 084 B3f). Every caller passes
  /// `State.retainedRemoteRepositories`, so no load can evict them or roll them back.
  func loadRepositories(
    fallbackRoots: [RepositoryLocation] = [],
    animated: Bool = false,
    knownRemoteRepositories: [Repository]
  ) -> Effect<Action> {
    let repositoryHost = repositoryHost
    return .run { [animated, fallbackRoots] send in
      let entries = await shownEntries(await loadPersistedRepositoryEntries(fallbackRoots: fallbackRoots))
      let roots = entries.map(\.location)
      // A remote prune would add a connection per entry to every reload; the refresh lists
      // a worktree whose folder is gone, so remote entries skip it (docs-ai 084 B3e).
      for entry in entries where entry.kind == .git && entry.location.localURL != nil {
        _ = try? await repositoryHost.pruneWorktrees(in: entry.location)
      }
      let (repositories, failures) = await loadRepositoriesData(
        entries, knownRemoteRepositories: knownRemoteRepositories)
      await send(
        .repositoriesLoaded(
          repositories,
          failures: failures,
          roots: roots,
          animated: animated,
          reusedRemoteRepositoryIDs: Self.reusedIDs(knownRemoteRepositories, in: repositories)
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

  func loadRepositoriesData(
    _ entries: [PersistedRepositoryEntry], knownRemoteRepositories: [Repository] = []
  ) async -> ([Repository], [LoadFailure]) {
    let clock = clock
    let known = Dictionary(knownRemoteRepositories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let fetchResults = await withTaskGroup(of: WorktreesFetchResult.self) { group in
      for entry in entries {
        let repositoryHost = self.repositoryHost
        group.addTask {
          // A remote folder loads through its host, within a deadline (docs-ai 084 B3e).
          guard case .remote = entry.location else {
            return await Self.loadRepository(entry, host: repositoryHost)
          }
          if let repository = known[entry.location.standardized.id] {
            return WorktreesFetchResult(entry: entry, repository: repository, errorMessage: nil)
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

  /// `operation`'s result, or `onTimeout`'s when `deadline` passes first. On a timeout this
  /// returns at once and only cancels the operation: a remote wait that does not respond to
  /// cancellation (such as a shared read of the login `PATH`) must not hold the load past
  /// its deadline. A cancelled caller gets `onTimeout`'s result too.
  private nonisolated static func withDeadline(
    _ deadline: Duration, clock: any Clock<Duration>,
    operation: @escaping @Sendable () async -> WorktreesFetchResult,
    onTimeout: @escaping @Sendable () -> WorktreesFetchResult
  ) async -> WorktreesFetchResult {
    let race = DeadlineRace<WorktreesFetchResult>()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        race.start(
          continuation: continuation,
          operation: Task { race.finish(with: await operation()) },
          timer: Task {
            try? await clock.sleep(for: deadline)
            race.finish(with: onTimeout())
          })
      }
    } onCancel: {
      race.finish(with: onTimeout())
    }
  }

  /// Keeps the failures of a load: their messages, and which ones lack git or a reachable
  /// host. `State.currentLoadFailures` reads them back.
  func recordLoadFailures(_ failures: [LoadFailure], state: inout State) {
    state.loadFailuresByID = Dictionary(
      failures.map { ($0.rootID, $0.message) },
      uniquingKeysWith: { first, _ in first }
    )
    state.gitUnavailableRepositoryIDs = Set(failures.filter(\.isGitUnavailable).map(\.rootID))
    state.loadUnreachableRepositoryIDs = Set(failures.filter(\.isHostUnreachable).map(\.rootID))
  }

  /// `keepsRemoteIDs` keeps every remote-form ID through the prunes. The snapshot sets it:
  /// a snapshot that a session without the flag wrote has no remote repositories, and the
  /// live load that follows decides for them.
  func applyRepositories(
    _ repositories: [Repository],
    roots: [RepositoryLocation],
    shouldPruneArchivedWorktrees: Bool,
    keepsRemoteIDs: Bool = false,
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
    let isKept = keptIDs(keepsRemoteIDs: keepsRemoteIDs)
    state.$prowlCreatedWorktreeIDs.withLock {
      $0.removeAll { !availableWorktreeIDs.contains($0) && !isKept($0) }
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
    let didPrunePinned = prunePinnedWorktreeIDs(state: &state, keeping: isKept)
    let didPruneRepositoryOrder = pruneRepositoryOrderIDs(roots: roots, state: &state, keeping: isKept)
    let didPruneWorktreeOrder = pruneWorktreeOrderByRepository(roots: roots, state: &state, keeping: isKept)
    let didPruneArchivedWorktrees =
      shouldPruneArchivedWorktrees
      ? pruneArchivedWorktrees(availableWorktreeIDs: availableWorktreeIDs, state: &state, keeping: isKept)
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

/// The first of an operation and its deadline to finish resumes the caller; the other is
/// cancelled and its result dropped.
private nonisolated final class DeadlineRace<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Never>?
  private var pending: Value?
  private var tasks: [Task<Void, Never>] = []
  private var isFinished = false

  func start(continuation: CheckedContinuation<Value, Never>, operation: Task<Void, Never>, timer: Task<Void, Never>) {
    let early: Value? = lock.withLock {
      tasks = [operation, timer]
      if isFinished { return pending }
      self.continuation = continuation
      return nil
    }
    if let early {
      operation.cancel()
      timer.cancel()
      continuation.resume(returning: early)
    }
  }

  func finish(with value: Value) {
    let (continuation, tasks): (CheckedContinuation<Value, Never>?, [Task<Void, Never>]) = lock.withLock {
      guard !isFinished else { return (nil, []) }
      isFinished = true
      pending = value
      defer { self.continuation = nil }
      return (self.continuation, self.tasks)
    }
    for task in tasks { task.cancel() }
    continuation?.resume(returning: value)
  }
}

extension RepositoriesFeature {
  /// The kept remote repositories that the load returned.
  nonisolated static func reusedIDs(_ known: [Repository], in loaded: [Repository]) -> Set<Repository.ID> {
    Set(known.map(\.id)).intersection(loaded.map(\.id))
  }
}

extension RepositoriesFeature.State {
  /// The loaded remote repositories that a load keeps as they are once the first live load
  /// is done: their refresh cadence keeps them current (docs-ai 084 B3f).
  var retainedRemoteRepositories: [Repository] {
    isInitialLoadComplete ? Array(repositories.filter { $0.location.localURL == nil }) : []
  }

  /// `loaded`, with the current version of each kept remote repository: a poll may have
  /// changed it while the load ran.
  func reconcilingReusedRemoteRepositories(
    _ loaded: [Repository], reusedIDs: Set<Repository.ID>
  ) -> [Repository] {
    guard !reusedIDs.isEmpty else { return loaded }
    return loaded.map { repository in
      reusedIDs.contains(repository.id) ? (repositories[id: repository.id] ?? repository) : repository
    }
  }

  /// The failures of the last load, as `recordLoadFailures` kept them.
  var currentLoadFailures: [RepositoriesFeature.LoadFailure] {
    loadFailuresByID.keys.sorted().map { id in
      RepositoriesFeature.LoadFailure(
        rootID: id, message: loadFailuresByID[id] ?? "",
        isGitUnavailable: gitUnavailableRepositoryIDs.contains(id),
        isHostUnreachable: loadUnreachableRepositoryIDs.contains(id))
    }
  }
}
