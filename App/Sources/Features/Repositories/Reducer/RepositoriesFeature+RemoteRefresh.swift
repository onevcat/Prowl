import ComposableArchitecture
import Foundation

private nonisolated let remoteRefreshLogger = ProwlLogger("RemoteRefresh")

/// The result of one batched refresh of a remote repository (docs-ai 084 B3f).
nonisolated enum RemoteRefreshResult: Equatable, Sendable {
  case refreshed(RemoteRepositoryRefresh)
  case failed(message: String, isHostUnreachable: Bool, needsRebind: Bool = false)
}

/// The refresh cadence of remote repositories (docs-ai 084 B3f, D4). The local monitors
/// of `WorktreeInfoWatcherManager` have no remote counterpart, so each loaded remote git
/// repository is polled with the batched refresh:
///
/// - the repository of the selected worktree every 10 s, the others every 45 s, which is
///   within the 60 s `ControlPersist` of the shared connection; selecting a remote
///   worktree refreshes its repository at once;
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
  /// Shorter than the connection's `ControlPersist` (60 s, `RemoteConnectionOwner`), so the
  /// next poll starts before an idle SSH master expires and reuses it.
  static let remoteRefreshBackgroundInterval: Duration = .seconds(45)
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
      effects.append(connectionHold(id, hostProfileID: hostProfileID))
    }
    return effects.isEmpty ? .none : .merge(effects)
  }

  /// Holds the connection of `repositoryID`'s host until the repository leaves. A host
  /// profile that needs a rebind holds nothing; the rebind starts it again.
  func connectionHold(_ repositoryID: Repository.ID, hostProfileID: HostProfile.ID) -> Effect<Action> {
    let hosts = remoteRepositoryHosts
    return .run { _ in
      guard let hold = try? await hosts.holdConnection(hostProfileID) else { return }
      // Held until the repository leaves; the cancellation ends the wait.
      try? await Task.never()
      await hold.release()
    }
    .cancellable(id: CancelID.remoteConnectionHold(repositoryID), cancelInFlight: true)
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
          result = .failed(
            message: error.localizedDescription, isHostUnreachable: isRemoteHostUnreachable(error),
            needsRebind: error as? RemoteRepositoryHostError == .authorityChanged)
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
    case .failed(let message, let isHostUnreachable, let needsRebind):
      // The last state stays; only the host's reachability changes. A host that answered
      // with another error is reachable.
      state.remoteRefreshFailureCounts[repositoryID, default: 0] += 1
      if isHostUnreachable {
        state.pollUnreachableRepositoryIDs.insert(repositoryID)
      } else {
        state.pollUnreachableRepositoryIDs.remove(repositoryID)
      }
      if let hostProfileID = repository.location.hostProfileID {
        // Another failure passed the authority check.
        if needsRebind {
          state.rebindHostProfileIDs.insert(hostProfileID)
        } else {
          state.rebindHostProfileIDs.remove(hostProfileID)
        }
      }
      remoteRefreshLogger.warning("Remote refresh failed for \(repositoryID): \(message)")
    case .refreshed(let refresh):
      state.remoteRefreshFailureCounts[repositoryID] = nil
      state.pollUnreachableRepositoryIDs.remove(repositoryID)
      if let hostProfileID = repository.location.hostProfileID {
        state.rebindHostProfileIDs.remove(hostProfileID)
      }
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

// MARK: - Rebind (docs-ai 084 C1)

extension RepositoriesFeature {
  /// Resolves the host profile's SSH configuration again, to show the new target before
  /// the user rebinds it.
  func reduceRemoteHostRebindRequested(_ hostProfileID: HostProfile.ID) -> Effect<Action> {
    let hosts = remoteRepositoryHosts
    return .run { send in
      do {
        await send(.remoteHostRebindResolved(try await hosts.resolveTarget(hostProfileID)))
      } catch {
        await send(.remoteHostRebindFailed(error.localizedDescription))
      }
    }
  }

  func rebindAlert(for target: RemoteHostTarget) -> AlertState<Alert> {
    let profile = target.profile
    guard profile.authorityChanged(to: target.resolved) else {
      return AlertState {
        TextState(String(localized: "Rebind \(profile.alias)?"))
      } actions: {
        ButtonState(action: .rebindRemoteHost(profile.id, target.resolved)) {
          TextState(String(localized: "Connect Again"))
        }
        ButtonState(role: .cancel) {
          TextState(String(localized: "Cancel"))
        }
      } message: {
        TextState(String(localized: "The SSH configuration of \(profile.alias) reaches its target again."))
      }
    }
    return AlertState {
      TextState(String(localized: "Rebind \(profile.alias)?"))
    } actions: {
      ButtonState(action: .rebindRemoteHost(profile.id, target.resolved)) {
        TextState(String(localized: "Use the New Target"))
      }
      ButtonState(role: .cancel) {
        TextState(String(localized: "Cancel"))
      }
    } message: {
      TextState(
        String(
          localized: """
            The SSH configuration of \(profile.alias) now reaches \(target.resolved.displayName). Its folders \
            were added for \(profile.connectionKey.displayName). Prowl does not connect to \(profile.alias) \
            until you use the new target.
            """))
    }
  }

  /// Stores `key` as the host profile's target, then connects its folders again. A file
  /// that changed since it was loaded is read again first (B2b).
  func reduceRebindRemoteHost(_ hostProfileID: HostProfile.ID, to key: ConnectionKey) -> Effect<Action> {
    .run { send in
      do {
        try await Self.storeTarget(key, for: hostProfileID)
        await send(.remoteHostRebound(hostProfileID))
      } catch {
        await send(.remoteHostRebindFailed(error.localizedDescription))
      }
    }
  }

  private static func storeTarget(_ key: ConnectionKey, for hostProfileID: HostProfile.ID) async throws {
    @Shared(.hostProfiles) var hostProfiles: [HostProfile]
    func bind() -> ConnectionKey? {
      $hostProfiles.withLock { profiles in
        guard let index = profiles.firstIndex(where: { $0.id == hostProfileID }) else { return nil }
        defer { profiles[index].connectionKey = key }
        return profiles[index].connectionKey
      }
    }
    guard var previous = bind() else { throw RepositoryHostError.hostProfileMissing(hostProfileID) }
    if case .changedSinceLoad? = $hostProfiles.saveError as? HostProfilesFileError {
      try await $hostProfiles.load()
      guard let reloaded = bind() else { throw RepositoryHostError.hostProfileMissing(hostProfileID) }
      previous = reloaded
    }
    guard let error = $hostProfiles.saveError else { return }
    // Nothing reads the unsaved target: it goes back at once, then the file's version loads.
    $hostProfiles.withLock { profiles in
      if let index = profiles.firstIndex(where: { $0.id == hostProfileID }) { profiles[index].connectionKey = previous }
    }
    try? await $hostProfiles.load()
    throw error
  }

  /// The host profile has its new target: its folders' holds start again, their polls run
  /// at once without backoff (a poll in flight used the old target), and they reload.
  func reduceRemoteHostRebound(_ hostProfileID: HostProfile.ID, state: inout State) -> Effect<Action> {
    state.rebindHostProfileIDs.remove(hostProfileID)
    let polled = state.remoteRefreshRepositoryIDs.filter {
      RepositoryLocation(id: $0)?.hostProfileID == hostProfileID
    }
    var cancellations: [Effect<Action>] = []
    var effects: [Effect<Action>] = [.send(.reloadRepositories(animated: false))]
    for id in polled {
      state.remoteRefreshFailureCounts[id] = nil
      state.remoteRefreshInFlightIDs.remove(id)
      cancellations.append(.cancel(id: CancelID.remoteRefreshRun(id)))
      effects.append(connectionHold(id, hostProfileID: hostProfileID))
      effects.append(.send(.remoteRepositoryRefreshDue(id)))
    }
    // The old poll ends before the new one starts; a hold never ends, so the rest merge.
    return .concatenate(.merge(cancellations), .merge(effects))
  }
}

/// A host profile and the target its SSH configuration resolves to now.
nonisolated struct RemoteHostTarget: Equatable, Sendable {
  let profile: HostProfile
  let resolved: ConnectionKey
}

extension ConnectionKey {
  /// `user@host`, with the port when it is not 22.
  nonisolated var displayName: String { port == 22 ? label : "\(label):\(port)" }
}
