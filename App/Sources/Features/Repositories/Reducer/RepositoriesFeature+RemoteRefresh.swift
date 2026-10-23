import ComposableArchitecture
import Foundation

private nonisolated let remoteRefreshLogger = ProwlLogger("RemoteRefresh")

/// The result of one batched refresh of a remote repository (docs-ai 084 B3f).
nonisolated enum RemoteRefreshResult: Equatable, Sendable {
  case refreshed(RemoteRepositoryRefresh)
  case failed(message: String, isHostUnreachable: Bool)
}

/// The refresh cadence of remote repositories (docs-ai 084 B3f, D4). The local monitors
/// of `WorktreeInfoWatcherManager` have no remote counterpart, so each loaded remote git
/// repository is polled with the batched refresh:
///
/// - the repository of the selected worktree every `focusedInterval`, the others every
///   `backgroundInterval`; selecting a remote worktree refreshes its repository at once;
/// - after a failed poll, the interval doubles up to `maximumBackoff`, and the last state
///   stays as it was;
/// - each loaded remote repository holds a lease on its host's connection, so the polls
///   and the other commands share one connection;
/// - polls pause while the app is inactive or in the background, and run at once when it
///   becomes active again.
///
/// A reload keeps the remote repositories that are already loaded (`loadRepositories`):
/// the cadence keeps them current, so a reload never waits for a host and a host that is
/// down never empties the list.
extension RepositoriesFeature {
  static let remoteRefreshFocusedInterval: Duration = .seconds(10)
  static let remoteRefreshBackgroundInterval: Duration = .seconds(60)
  static let remoteRefreshMaximumBackoff: Duration = .seconds(300)

  /// The delay before the next poll of `repositoryID`.
  static func remoteRefreshDelay(isFocused: Bool, failures: Int) -> Duration {
    let base = isFocused ? remoteRefreshFocusedInterval : remoteRefreshBackgroundInterval
    guard failures > 0 else { return base }
    let factor = 1 << min(failures, 16)
    return min(base * factor, remoteRefreshMaximumBackoff)
  }

  /// Starts the cadence of new remote git repositories and stops it for those that left.
  func syncRemoteRefreshSchedules(state: inout State) -> Effect<Action> {
    guard remoteRepositoryHosts.isAvailable else { return .none }
    let desired = Set(
      state.repositories.filter { $0.kind == .git && $0.location.localURL == nil }.map(\.id))
    let added = desired.subtracting(state.remoteRefreshRepositoryIDs)
    let removed = state.remoteRefreshRepositoryIDs.subtracting(desired)
    state.remoteRefreshRepositoryIDs = desired
    var effects: [Effect<Action>] = []
    for id in removed {
      // A load that failed it keeps its own mark (`loadUnreachableRepositoryIDs`).
      state.pollUnreachableRepositoryIDs.remove(id)
      state.remoteRefreshFailureCounts[id] = nil
      state.remoteRefreshFingerprints[id] = nil
      state.remoteRefreshInFlightIDs.remove(id)
      effects.append(.cancel(id: CancelID.remoteRefreshTimer(id)))
      effects.append(.cancel(id: CancelID.remoteRefreshRun(id)))
      effects.append(.cancel(id: CancelID.remoteConnectionHold(id)))
    }
    for id in added {
      guard let repository = state.repositories[id: id],
        case .remote(let hostProfileID, _) = repository.location
      else { continue }
      effects.append(scheduleRemoteRefresh(id, state: state))
      let hosts = remoteRepositoryHosts
      effects.append(
        .run { _ in
          guard let hold = try? await hosts.holdConnection(hostProfileID) else { return }
          // Held until the repository leaves; the cancellation ends the wait.
          try? await Task.never()
          await hold.release()
        }
        .cancellable(id: CancelID.remoteConnectionHold(id), cancelInFlight: true)
      )
    }
    return effects.isEmpty ? .none : .merge(effects)
  }

  func scheduleRemoteRefresh(_ repositoryID: Repository.ID, state: State) -> Effect<Action> {
    guard !state.isRemoteRefreshPaused else { return .none }
    let isFocused = state.repositoryID(for: state.selectedWorktreeID) == repositoryID
    let delay = Self.remoteRefreshDelay(
      isFocused: isFocused, failures: state.remoteRefreshFailureCounts[repositoryID] ?? 0)
    let clock = clock
    return .run { send in
      try await clock.sleep(for: delay)
      await send(.remoteRepositoryRefreshDue(repositoryID))
    }
    .cancellable(id: CancelID.remoteRefreshTimer(repositoryID), cancelInFlight: true)
  }

  func reduceRemoteRefreshDue(_ repositoryID: Repository.ID, state: inout State) -> Effect<Action> {
    guard !state.isRemoteRefreshPaused, state.remoteRefreshRepositoryIDs.contains(repositoryID),
      !state.remoteRefreshInFlightIDs.contains(repositoryID),
      let location = state.repositories[id: repositoryID]?.location
    else { return .none }
    state.remoteRefreshInFlightIDs.insert(repositoryID)
    let repositoryHost = repositoryHost
    return .merge(
      .cancel(id: CancelID.remoteRefreshTimer(repositoryID)),
      .run { send in
        let result: RemoteRefreshResult
        do {
          result = .refreshed(try await repositoryHost.remoteRefresh(in: location))
        } catch {
          result = .failed(message: error.localizedDescription, isHostUnreachable: isRemoteHostUnreachable(error))
        }
        await send(.remoteRepositoryRefreshed(repositoryID, result))
      }
      .cancellable(id: CancelID.remoteRefreshRun(repositoryID), cancelInFlight: true)
    )
  }

  func reduceRemoteRefreshed(
    _ repositoryID: Repository.ID, _ result: RemoteRefreshResult, state: inout State
  ) -> Effect<Action> {
    state.remoteRefreshInFlightIDs.remove(repositoryID)
    guard state.remoteRefreshRepositoryIDs.contains(repositoryID),
      let repository = state.repositories[id: repositoryID]
    else { return .none }
    var effects: [Effect<Action>] = []
    switch result {
    case .failed(let message, let isHostUnreachable):
      // The last state stays; only the host's reachability changes. A host that answered
      // with another error is reachable.
      state.remoteRefreshFailureCounts[repositoryID, default: 0] += 1
      if isHostUnreachable {
        state.pollUnreachableRepositoryIDs.insert(repositoryID)
      } else {
        state.pollUnreachableRepositoryIDs.remove(repositoryID)
      }
      remoteRefreshLogger.warning("Remote refresh failed for \(repositoryID): \(message)")
    case .refreshed(let refresh):
      state.remoteRefreshFailureCounts[repositoryID] = nil
      state.pollUnreachableRepositoryIDs.remove(repositoryID)
      effects.append(contentsOf: applyRemoteRefresh(refresh, to: repository, state: &state))
    }
    effects.append(scheduleRemoteRefresh(repositoryID, state: state))
    return .merge(effects)
  }

  /// Applies a refresh as the local monitors' events would: a changed worktree list
  /// reloads, a changed branch renames the worktree, changed line counts update its row,
  /// and changed remote URLs refresh its pull requests.
  private func applyRemoteRefresh(
    _ refresh: RemoteRepositoryRefresh, to repository: Repository, state: inout State
  ) -> [Effect<Action>] {
    var effects: [Effect<Action>] = []
    let worktrees = refresh.worktrees(in: repository.location)
    if Set(worktrees.map(\.id)) != Set(repository.worktrees.map(\.id)) {
      // As a load would bring them; a reload keeps loaded remote repositories as they are.
      var repositories = Array(state.repositories)
      if let index = repositories.firstIndex(where: { $0.id == repository.id }) {
        repositories[index] = Repository(
          location: repository.location, name: repository.name, kind: repository.kind,
          worktrees: IdentifiedArray(worktrees, uniquingIDsWith: { current, _ in current }))
      }
      effects.append(
        .send(
          .repositoriesLoaded(
            repositories, failures: state.currentLoadFailures, roots: state.repositoryRoots, animated: true)))
    } else {
      for worktree in worktrees where repository.worktrees[id: worktree.id]?.name != worktree.name {
        updateWorktreeName(worktree.id, name: worktree.name, state: &state)
      }
    }
    @Shared(.repositorySettings(repository.location)) var repositorySettings
    if repositorySettings.observesLineDiffsAutomatically {
      for (worktreeID, changes) in refresh.lineChanges(in: repository.location) {
        updateWorktreeLineChanges(worktreeID: worktreeID, changes: changes, state: &state)
      }
    }
    let previousFingerprint = state.remoteRefreshFingerprints.updateValue(
      refresh.remotesFingerprint, forKey: repository.id)
    if let previousFingerprint, previousFingerprint != refresh.remotesFingerprint {
      effects.append(remoteConfigurationChanged(repository, state: &state))
    }
    return effects
  }

  /// Pauses the polls while the app is inactive, and polls every remote repository at
  /// once when it is active again.
  func setRemoteRefreshActive(_ isActive: Bool, state: inout State) -> Effect<Action> {
    guard state.isRemoteRefreshPaused == isActive else { return .none }
    state.isRemoteRefreshPaused = !isActive
    let ids = state.remoteRefreshRepositoryIDs
    guard isActive else {
      state.remoteRefreshInFlightIDs.removeAll()
      return .merge(
        ids.flatMap { [.cancel(id: CancelID.remoteRefreshTimer($0)), .cancel(id: CancelID.remoteRefreshRun($0))] })
    }
    return .merge(ids.map { .send(.remoteRepositoryRefreshDue($0)) })
  }

  /// A repository's remote URLs changed: every branch can point at other pull requests,
  /// and the code host may be another.
  func remoteConfigurationChanged(_ repository: Repository, state: inout State) -> Effect<Action> {
    let repositories = IdentifiedArrayOf(uniqueElements: [repository])
    var effects: [Effect<Action>] = []
    let worktreeIDs = repository.worktrees.map(\.id)
    state.pullRequestRefreshForcedWorktreeIDs.formUnion(worktreeIDs)
    if repository.capabilities.supportsPullRequests, !worktreeIDs.isEmpty {
      effects.append(
        .send(
          .githubIntegration(
            .repositoryPullRequestRefreshRequested(
              repositoryLocation: repository.location,
              worktreeIDs: worktreeIDs
            )
          ))
      )
    }
    if let effect = detectCodeHostsEffect(for: repositories, includeUnknown: true) {
      effects.append(effect)
    }
    return effects.isEmpty ? .none : .concatenate(effects)
  }
}
