import AppKit
import ComposableArchitecture
import Foundation

private let unresolvedGithubRepositoryMessage =
  "Prowl could not determine which GitHub repository owns this pull request. Check the repository remote and try again."

extension RepositoriesFeature {
  static func resolveGithubRemoteInfo(
    repositoryRootURL: URL,
    githubCLI: GithubCLIClient,
    gitClient: GitClientDependency
  ) async -> GithubRemoteInfo? {
    // Parsing the local git remote URL is ~20x faster than spawning `gh repo view`
    // (no gh subprocess, no network round trip). The batched GraphQL query that
    // follows is itself authoritative about whether the repo exists on GitHub, so
    // gh is only useful as a fallback for non-standard remotes that the regex in
    // GitClient cannot parse.
    if let remoteInfo = await gitClient.remoteInfo(repositoryRootURL) {
      return remoteInfo
    }
    return await githubCLI.resolveRemoteInfo(repositoryRootURL)
  }

  static func resolveGithubRemoteInfos(
    repositoryRootURL: URL,
    githubCLI: GithubCLIClient,
    gitClient: GitClientDependency
  ) async -> [GithubRemoteInfo] {
    let remoteInfos = await gitClient.githubRemoteInfos(repositoryRootURL)
    if !remoteInfos.isEmpty {
      return remoteInfos
    }
    if let remoteInfo = await githubCLI.resolveRemoteInfo(repositoryRootURL) {
      return [remoteInfo]
    }
    return []
  }

  static func resolveGithubRemoteInfo(
    for pullRequest: GithubPullRequest,
    repositoryRootURL: URL,
    githubCLI: GithubCLIClient,
    gitClient: GitClientDependency
  ) async -> GithubRemoteInfo? {
    if let remoteInfo = GitClient.parseGithubRemoteInfo(pullRequest.url) {
      return remoteInfo
    }
    return await resolveGithubRemoteInfo(
      repositoryRootURL: repositoryRootURL,
      githubCLI: githubCLI,
      gitClient: gitClient
    )
  }
}

extension RepositoriesFeature {
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func reduceGithubIntegration(
    state: inout State,
    action: GithubIntegrationAction
  ) -> Effect<Action> {
    switch action {
    case .delayedPullRequestRefresh(let worktreeID):
      guard let worktree = state.worktree(for: worktreeID),
        let repositoryID = state.repositoryID(containing: worktreeID),
        let repository = state.repositories[id: repositoryID]
      else {
        return .none
      }
      let repositoryRootURL = worktree.repositoryRootURL
      let worktreeIDs = repository.worktrees.map(\.id)
      return .run { send in
        try? await ContinuousClock().sleep(for: .seconds(2))
        await send(
          .worktreeInfoEvent(
            .repositoryPullRequestRefresh(
              repositoryRootURL: repositoryRootURL,
              worktreeIDs: worktreeIDs
            )
          )
        )
      }
      .cancellable(id: CancelID.delayedPRRefresh(worktreeID), cancelInFlight: true)

    case .repositoryPullRequestRefreshRequested(let repositoryRootURL, let worktreeIDs):
      @Shared(.repositorySettings(repositoryRootURL)) var repositorySettings
      guard repositorySettings.fetchesPullRequestState else {
        return .none
      }
      let worktrees = worktreeIDs.compactMap { state.worktree(for: $0) }
      guard let firstWorktree = worktrees.first,
        let repositoryID = state.repositoryID(containing: firstWorktree.id)
      else {
        return .none
      }
      var seen = Set<String>()
      let branches =
        worktrees
        .map(\.name)
        .filter { !$0.isEmpty && seen.insert($0).inserted }
      guard !branches.isEmpty else {
        return .none
      }
      switch state.githubIntegrationAvailability {
      case .available:
        if state.inFlightPullRequestRefreshRepositoryIDs.contains(repositoryID) {
          queuePullRequestRefresh(
            repositoryID: repositoryID,
            repositoryRootURL: repositoryRootURL,
            worktreeIDs: worktreeIDs,
            refreshesByRepositoryID: &state.queuedPullRequestRefreshByRepositoryID
          )
          return .none
        }
        state.inFlightPullRequestRefreshRepositoryIDs.insert(repositoryID)
        return enqueueBatchedPullRequestRefresh(
          repositoryID: repositoryID,
          repositoryRootURL: repositoryRootURL,
          worktrees: worktrees,
          branches: branches
        )
      case .unknown:
        queuePullRequestRefresh(
          repositoryID: repositoryID,
          repositoryRootURL: repositoryRootURL,
          worktreeIDs: worktreeIDs,
          refreshesByRepositoryID: &state.pendingPullRequestRefreshByRepositoryID
        )
        return .send(.githubIntegration(.refreshGithubIntegrationAvailability))
      case .checking:
        queuePullRequestRefresh(
          repositoryID: repositoryID,
          repositoryRootURL: repositoryRootURL,
          worktreeIDs: worktreeIDs,
          refreshesByRepositoryID: &state.pendingPullRequestRefreshByRepositoryID
        )
        return .none
      case .unavailable:
        queuePullRequestRefresh(
          repositoryID: repositoryID,
          repositoryRootURL: repositoryRootURL,
          worktreeIDs: worktreeIDs,
          refreshesByRepositoryID: &state.pendingPullRequestRefreshByRepositoryID
        )
        return .none
      case .disabled:
        return .none
      }

    case .refreshGithubIntegrationAvailability:
      guard state.githubIntegrationAvailability != .checking,
        state.githubIntegrationAvailability != .disabled
      else {
        return .none
      }
      state.githubIntegrationAvailability = .checking
      let githubIntegration = githubIntegration
      return .run { send in
        let isAvailable = await githubIntegration.isAvailable()
        await send(.githubIntegration(.githubIntegrationAvailabilityUpdated(isAvailable)))
      }
      .cancellable(id: CancelID.githubIntegrationAvailability, cancelInFlight: true)

    case .githubIntegrationAvailabilityUpdated(let isAvailable):
      guard state.githubIntegrationAvailability != .disabled else {
        return .none
      }
      state.githubIntegrationAvailability = isAvailable ? .available : .unavailable
      guard isAvailable else {
        for (repositoryID, queued) in state.queuedPullRequestRefreshByRepositoryID {
          queuePullRequestRefresh(
            repositoryID: repositoryID,
            repositoryRootURL: queued.repositoryRootURL,
            worktreeIDs: queued.worktreeIDs,
            refreshesByRepositoryID: &state.pendingPullRequestRefreshByRepositoryID
          )
        }
        state.queuedPullRequestRefreshByRepositoryID.removeAll()
        state.inFlightPullRequestRefreshRepositoryIDs.removeAll()
        clearAllPullRequestRefreshTracking(state: &state)
        return .run { send in
          while !Task.isCancelled {
            try? await ContinuousClock().sleep(for: githubIntegrationRecoveryInterval)
            guard !Task.isCancelled else {
              return
            }
            await send(.githubIntegration(.refreshGithubIntegrationAvailability))
          }
        }
        .cancellable(id: CancelID.githubIntegrationRecovery, cancelInFlight: true)
      }
      let pendingRefreshes = state.pendingPullRequestRefreshByRepositoryID.values.sorted {
        $0.repositoryRootURL.path(percentEncoded: false)
          < $1.repositoryRootURL.path(percentEncoded: false)
      }
      state.pendingPullRequestRefreshByRepositoryID.removeAll()
      return .merge(
        .cancel(id: CancelID.githubIntegrationRecovery),
        .merge(
          pendingRefreshes.map { pending in
            .send(
              .worktreeInfoEvent(
                .repositoryPullRequestRefresh(
                  repositoryRootURL: pending.repositoryRootURL,
                  worktreeIDs: pending.worktreeIDs
                )
              )
            )
          }
        )
      )

    case .repositoryPullRequestRefreshCompleted(let repositoryID):
      state.inFlightPullRequestRefreshRepositoryIDs.remove(repositoryID)
      clearPullRequestRefreshTracking(repositoryID: repositoryID, state: &state)
      guard state.githubIntegrationAvailability == .available,
        let pending = state.queuedPullRequestRefreshByRepositoryID.removeValue(
          forKey: repositoryID
        )
      else {
        return .none
      }
      return .send(
        .worktreeInfoEvent(
          .repositoryPullRequestRefresh(
            repositoryRootURL: pending.repositoryRootURL,
            worktreeIDs: pending.worktreeIDs
          )
        )
      )

    case .pullRequestRefreshBatchCountResolved(let repositoryID, let count, let remotePriorities):
      guard state.inFlightPullRequestRefreshRepositoryIDs.contains(repositoryID) else {
        return .none
      }
      state.prRefreshBatchCountsByRepositoryID[repositoryID] = max(1, count)
      state.prRefreshRemotePrioritiesByRepositoryID[repositoryID] = remotePriorities
      state.prRefreshResultPrioritiesByRepositoryID.removeValue(forKey: repositoryID)
      return .none

    case .repositoryPullRequestsLoaded(let repositoryID, let pullRequestsByWorktreeID):
      guard let repository = state.repositories[id: repositoryID] else {
        return .none
      }
      var mergedWorktreeIDs: [Worktree.ID] = []
      for worktreeID in pullRequestsByWorktreeID.keys.sorted() {
        guard let worktree = repository.worktrees[id: worktreeID] else {
          continue
        }
        let loadedPullRequest = pullRequestsByWorktreeID[worktreeID] ?? nil
        let displayedPullRequest = Self.displayPullRequest(loadedPullRequest, for: worktree)
        let previousPullRequest = state.worktreeInfoByID[worktreeID]?.pullRequest
        let pullRequest = Self.preservingMergeableState(
          displayedPullRequest,
          previous: previousPullRequest
        )
        guard previousPullRequest != pullRequest else {
          continue
        }
        let previousMerged = previousPullRequest?.state == "MERGED"
        let nextMerged = pullRequest?.state == "MERGED"
        updateWorktreePullRequest(
          worktreeID: worktreeID,
          pullRequest: pullRequest,
          state: &state
        )
        if state.mergedWorktreeAction != nil,
          !previousMerged,
          nextMerged,
          !state.isMainWorktree(worktree),
          !state.isWorktreeArchived(worktreeID),
          !state.deletingWorktreeIDs.contains(worktreeID)
        {
          mergedWorktreeIDs.append(worktreeID)
        }
      }
      guard !mergedWorktreeIDs.isEmpty else {
        return .none
      }
      switch state.mergedWorktreeAction {
      case .archive:
        return .merge(
          mergedWorktreeIDs.map { worktreeID in
            .send(.worktreeLifecycle(.archiveWorktreeConfirmed(worktreeID, repositoryID)))
          }
        )
      case .delete:
        @Shared(.settingsFile) var settingsFile
        return .merge(
          mergedWorktreeIDs.map { worktreeID in
            let shouldDeleteBranch =
              settingsFile.global.deleteBranchOnAutomaticWorktreeCleanup
              && state.prowlCreatedWorktreeIDs.contains(worktreeID)
            return .send(
              .worktreeLifecycle(
                .deleteWorktreeConfirmed(
                  worktreeID,
                  repositoryID,
                  deleteBranch: shouldDeleteBranch
                ))
            )
          }
        )
      case nil:
        return .none
      }

    case .pullRequestAction(let worktreeID, let action):
      guard let worktree = state.worktree(for: worktreeID),
        let repositoryID = state.repositoryID(containing: worktreeID),
        let repository = state.repositories[id: repositoryID]
      else {
        return .send(
          .presentAlert(
            title: "Repository not available",
            message: "Prowl could not find the selected repository."
          )
        )
      }
      let repoRoot = worktree.repositoryRootURL
      let worktreeRoot = worktree.workingDirectory
      let optionalPullRequest = state.worktreeInfo(for: worktreeID)?.pullRequest
      if case .openOnCodeHost = action {
        let gitClient = gitClient
        let openURLClient = openURLClient
        let pullRequestURL = optionalPullRequest.flatMap { Self.validWebURL($0.url) }
        return .run { send in
          if let pullRequestURL {
            await openURLClient.open(pullRequestURL)
            return
          }
          guard let repositoryURL = await gitClient.repositoryWebURL(repoRoot) else {
            await send(
              .presentAlert(
                title: "Repository URL not available",
                message: "Prowl could not determine a code host URL for this repository."
              )
            )
            return
          }
          await openURLClient.open(repositoryURL)
        }
      }
      guard let pullRequest = optionalPullRequest else {
        return .send(
          .presentAlert(
            title: "Pull request not available",
            message: "Prowl could not find a pull request for this worktree."
          )
        )
      }
      let pullRequestRefresh = WorktreeInfoWatcherClient.Event.repositoryPullRequestRefresh(
        repositoryRootURL: repoRoot,
        worktreeIDs: repository.worktrees.map(\.id)
      )
      let branchName = pullRequest.headRefName ?? worktree.name
      let failingCheckDetailsURL = (pullRequest.statusCheckRollup?.checks ?? []).first {
        $0.checkState == .failure && $0.detailsUrl != nil
      }?.detailsUrl
      switch action {
      case .openOnCodeHost:
        return .none

      case .copyFailingJobURL:
        guard let failingCheckDetailsURL, !failingCheckDetailsURL.isEmpty else {
          return .send(
            .presentAlert(
              title: "Failing check not found",
              message: "Prowl could not find a failing check URL."
            )
          )
        }
        return .run { send in
          await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(failingCheckDetailsURL, forType: .string)
          }
          await send(.showToast(.success("Failing job URL copied")))
        }

      case .openFailingCheckDetails:
        guard let failingCheckDetailsURL, let url = URL(string: failingCheckDetailsURL) else {
          return .send(
            .presentAlert(
              title: "Failing check not found",
              message: "Prowl could not find a failing check with details."
            )
          )
        }
        return .run { @MainActor _ in
          NSWorkspace.shared.open(url)
        }

      case .markReadyForReview:
        let githubCLI = githubCLI
        let githubIntegration = githubIntegration
        let gitClient = gitClient
        return .run { send in
          guard await githubIntegration.isAvailable() else {
            await send(
              .presentAlert(
                title: "GitHub integration unavailable",
                message: "Enable GitHub integration to mark a pull request as ready."
              )
            )
            return
          }
          await send(.showToast(.inProgress("Marking PR ready…")))
          do {
            @Shared(.repositorySettings(repoRoot)) var repositorySettings
            guard
              let remoteInfo = await Self.resolveGithubRemoteInfo(
                for: pullRequest,
                repositoryRootURL: repoRoot,
                githubCLI: githubCLI,
                gitClient: gitClient
              )
            else {
              await send(.dismissToast)
              await send(
                .presentAlert(title: "GitHub repository not resolved", message: unresolvedGithubRepositoryMessage))
              return
            }
            try await githubCLI.markPullRequestReady(
              worktreeRoot,
              remoteInfo,
              pullRequest.number,
              repositorySettings.githubAccountOverride
            )
            await send(.showToast(.success("Pull request marked ready")))
            await send(.githubIntegration(.delayedPullRequestRefresh(worktreeID)))
          } catch {
            await send(.dismissToast)
            await send(
              .presentAlert(
                title: "Failed to mark pull request ready",
                message: error.localizedDescription
              )
            )
          }
        }

      case .merge:
        let githubCLI = githubCLI
        let githubIntegration = githubIntegration
        let gitClient = gitClient
        return .run { send in
          guard await githubIntegration.isAvailable() else {
            await send(
              .presentAlert(
                title: "GitHub integration unavailable",
                message: "Enable GitHub integration to merge a pull request."
              )
            )
            return
          }
          @Shared(.repositorySettings(repoRoot)) var repositorySettings
          @Shared(.settingsFile) var settingsFile
          let strategy = repositorySettings.pullRequestMergeStrategy ?? settingsFile.global.pullRequestMergeStrategy
          await send(.showToast(.inProgress("Merging pull request…")))
          do {
            guard
              let remoteInfo = await Self.resolveGithubRemoteInfo(
                for: pullRequest,
                repositoryRootURL: repoRoot,
                githubCLI: githubCLI,
                gitClient: gitClient
              )
            else {
              await send(.dismissToast)
              await send(
                .presentAlert(title: "GitHub repository not resolved", message: unresolvedGithubRepositoryMessage))
              return
            }
            try await githubCLI.mergePullRequest(
              worktreeRoot,
              remoteInfo,
              pullRequest.number,
              strategy,
              repositorySettings.githubAccountOverride
            )
            await send(.showToast(.success("Pull request merged")))
            await send(.worktreeInfoEvent(pullRequestRefresh))
            await send(.githubIntegration(.delayedPullRequestRefresh(worktreeID)))
          } catch {
            await send(.dismissToast)
            await send(
              .presentAlert(
                title: "Failed to merge pull request",
                message: error.localizedDescription
              )
            )
          }
        }

      case .close:
        let githubCLI = githubCLI
        let githubIntegration = githubIntegration
        let gitClient = gitClient
        return .run { send in
          guard await githubIntegration.isAvailable() else {
            await send(
              .presentAlert(
                title: "GitHub integration unavailable",
                message: "Enable GitHub integration to close a pull request."
              )
            )
            return
          }
          await send(.showToast(.inProgress("Closing pull request…")))
          do {
            @Shared(.repositorySettings(repoRoot)) var repositorySettings
            guard
              let remoteInfo = await Self.resolveGithubRemoteInfo(
                for: pullRequest,
                repositoryRootURL: repoRoot,
                githubCLI: githubCLI,
                gitClient: gitClient
              )
            else {
              await send(.dismissToast)
              await send(
                .presentAlert(title: "GitHub repository not resolved", message: unresolvedGithubRepositoryMessage))
              return
            }
            try await githubCLI.closePullRequest(
              worktreeRoot,
              remoteInfo,
              pullRequest.number,
              repositorySettings.githubAccountOverride
            )
            await send(.showToast(.success("Pull request closed")))
            await send(.worktreeInfoEvent(pullRequestRefresh))
            await send(.githubIntegration(.delayedPullRequestRefresh(worktreeID)))
          } catch {
            await send(.dismissToast)
            await send(
              .presentAlert(
                title: "Failed to close pull request",
                message: error.localizedDescription
              )
            )
          }
        }

      case .copyCiFailureLogs:
        let githubCLI = githubCLI
        let githubIntegration = githubIntegration
        return .run { send in
          guard await githubIntegration.isAvailable() else {
            await send(
              .presentAlert(
                title: "GitHub integration unavailable",
                message: "Enable GitHub integration to copy CI failure logs."
              )
            )
            return
          }
          guard !branchName.isEmpty else {
            await send(
              .presentAlert(
                title: "Branch name unavailable",
                message: "Prowl could not determine the pull request branch."
              )
            )
            return
          }
          await send(.showToast(.inProgress("Fetching CI logs…")))
          do {
            @Shared(.repositorySettings(repoRoot)) var repositorySettings
            let accountOverride = repositorySettings.githubAccountOverride
            guard let run = try await githubCLI.latestRun(worktreeRoot, branchName, accountOverride) else {
              await send(.dismissToast)
              await send(
                .presentAlert(
                  title: "No workflow runs found",
                  message: "Prowl could not find any workflow runs for this branch."
                )
              )
              return
            }
            guard run.conclusion?.lowercased() == "failure" else {
              await send(.dismissToast)
              await send(
                .presentAlert(
                  title: "No failing workflow run",
                  message: "Prowl could not find a failing workflow run to copy logs from."
                )
              )
              return
            }
            let failedLogs = try await githubCLI.failedRunLogs(worktreeRoot, run.databaseId, accountOverride)
            let logs =
              if failedLogs.isEmpty {
                try await githubCLI.runLogs(worktreeRoot, run.databaseId, accountOverride)
              } else {
                failedLogs
              }
            guard !logs.isEmpty else {
              await send(.dismissToast)
              await send(
                .presentAlert(
                  title: "No CI logs available",
                  message: "The workflow run failed but produced no logs."
                )
              )
              return
            }
            await MainActor.run {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(logs, forType: .string)
            }
            await send(.showToast(.success("CI failure logs copied")))
          } catch {
            await send(.dismissToast)
            await send(
              .presentAlert(
                title: "Failed to copy CI failure logs",
                message: error.localizedDescription
              )
            )
          }
        }

      case .rerunFailedJobs:
        let githubCLI = githubCLI
        let githubIntegration = githubIntegration
        return .run { send in
          guard await githubIntegration.isAvailable() else {
            await send(
              .presentAlert(
                title: "GitHub integration unavailable",
                message: "Enable GitHub integration to re-run failed jobs."
              )
            )
            return
          }
          guard !branchName.isEmpty else {
            await send(
              .presentAlert(
                title: "Branch name unavailable",
                message: "Prowl could not determine the pull request branch."
              )
            )
            return
          }
          await send(.showToast(.inProgress("Re-running failed jobs…")))
          do {
            @Shared(.repositorySettings(repoRoot)) var repositorySettings
            let accountOverride = repositorySettings.githubAccountOverride
            guard let run = try await githubCLI.latestRun(worktreeRoot, branchName, accountOverride) else {
              await send(.dismissToast)
              await send(
                .presentAlert(
                  title: "No workflow runs found",
                  message: "Prowl could not find any workflow runs for this branch."
                )
              )
              return
            }
            guard run.conclusion?.lowercased() == "failure" else {
              await send(.dismissToast)
              await send(
                .presentAlert(
                  title: "No failing workflow run",
                  message: "Prowl could not find a failing workflow run to re-run."
                )
              )
              return
            }
            try await githubCLI.rerunFailedJobs(worktreeRoot, run.databaseId, accountOverride)
            await send(.showToast(.success("Failed jobs re-run started")))
            await send(.githubIntegration(.delayedPullRequestRefresh(worktreeID)))
          } catch {
            await send(.dismissToast)
            await send(
              .presentAlert(
                title: "Failed to re-run failed jobs",
                message: error.localizedDescription
              )
            )
          }
        }
      }

    case .setGithubIntegrationEnabled(let isEnabled):
      if isEnabled {
        state.githubIntegrationAvailability = .unknown
        state.pendingPullRequestRefreshByRepositoryID.removeAll()
        state.queuedPullRequestRefreshByRepositoryID.removeAll()
        state.inFlightPullRequestRefreshRepositoryIDs.removeAll()
        clearAllPullRequestRefreshTracking(state: &state)
        return .merge(
          .cancel(id: CancelID.githubIntegrationRecovery),
          .send(.githubIntegration(.refreshGithubIntegrationAvailability))
        )
      }
      state.githubIntegrationAvailability = .disabled
      state.pendingPullRequestRefreshByRepositoryID.removeAll()
      state.queuedPullRequestRefreshByRepositoryID.removeAll()
      state.inFlightPullRequestRefreshRepositoryIDs.removeAll()
      clearAllPullRequestRefreshTracking(state: &state)
      let worktreeIDs = Array(state.worktreeInfoByID.keys)
      for worktreeID in worktreeIDs {
        updateWorktreePullRequest(
          worktreeID: worktreeID,
          pullRequest: nil,
          state: &state
        )
      }
      return .merge(
        .cancel(id: CancelID.githubIntegrationAvailability),
        .cancel(id: CancelID.githubIntegrationRecovery)
      )

    case .setMergedWorktreeAction(let action):
      state.mergedWorktreeAction = action
      return .none

    case .pullRequestRefreshBatchOutcome(let outcome):
      return reduceBatchOutcome(state: &state, outcome: outcome)
    }
  }

  private func reduceBatchOutcome(
    state: inout State,
    outcome: PullRequestRefreshCoordinator.Outcome
  ) -> Effect<Action> {
    switch outcome {
    case .refreshed(let repositoryID, _, let worktreeIDs, let prsByBranch, let confirmedNoPrBranches):
      guard let repository = state.repositories[id: repositoryID] else {
        state.inFlightPullRequestRefreshRepositoryIDs.remove(repositoryID)
        clearPullRequestRefreshTracking(repositoryID: repositoryID, state: &state)
        return .none
      }
      mergePullRequestRefreshResults(
        repositoryID: repositoryID,
        prsByBranch: prsByBranch,
        confirmedNoPrBranches: confirmedNoPrBranches,
        state: &state
      )
      guard consumePullRequestRefreshBatch(repositoryID: repositoryID, state: &state) else {
        return .none
      }
      let mergedPRsByBranch =
        state.prRefreshResultsByRepositoryID.removeValue(
          forKey: repositoryID
        ) ?? [:]
      let hadFailedBatch = state.prRefreshFailedBatchRepositoryIDs.remove(repositoryID) != nil
      let accumulatedConfirmedNoPrBranches =
        state.prRefreshNoPrBranchesByID.removeValue(
          forKey: repositoryID
        ) ?? []
      // A failed host batch means branch status on that host is unknown, even when
      // it arrived before this final refreshed outcome — suppress confirmed clears.
      let confirmedNoPrBranches = hadFailedBatch ? [] : accumulatedConfirmedNoPrBranches
      state.prRefreshResultPrioritiesByRepositoryID.removeValue(forKey: repositoryID)
      let prsByWorktreeID = pullRequestsByWorktreeID(
        repository: repository,
        worktreeIDs: worktreeIDs,
        prsByBranch: mergedPRsByBranch,
        confirmedNoPrBranches: confirmedNoPrBranches
      )
      return .merge(
        .send(
          .githubIntegration(
            .repositoryPullRequestsLoaded(
              repositoryID: repositoryID,
              pullRequestsByWorktreeID: prsByWorktreeID
            )
          )
        ),
        .send(.githubIntegration(.repositoryPullRequestRefreshCompleted(repositoryID)))
      )
    case .failed(let repositoryID, let worktreeIDs, _):
      state.prRefreshFailedBatchRepositoryIDs.insert(repositoryID)
      guard consumePullRequestRefreshBatch(repositoryID: repositoryID, state: &state) else {
        return .none
      }
      let mergedPRsByBranch =
        state.prRefreshResultsByRepositoryID.removeValue(
          forKey: repositoryID
        ) ?? [:]
      state.prRefreshFailedBatchRepositoryIDs.remove(repositoryID)
      _ = state.prRefreshNoPrBranchesByID.removeValue(forKey: repositoryID)
      state.prRefreshResultPrioritiesByRepositoryID.removeValue(forKey: repositoryID)
      guard !mergedPRsByBranch.isEmpty,
        let repository = state.repositories[id: repositoryID]
      else {
        return .send(.githubIntegration(.repositoryPullRequestRefreshCompleted(repositoryID)))
      }
      return .merge(
        .send(
          .githubIntegration(
            .repositoryPullRequestsLoaded(
              repositoryID: repositoryID,
              pullRequestsByWorktreeID: pullRequestsByWorktreeID(
                repository: repository,
                worktreeIDs: worktreeIDs,
                prsByBranch: mergedPRsByBranch,
                confirmedNoPrBranches: []
              )
            )
          )
        ),
        .send(.githubIntegration(.repositoryPullRequestRefreshCompleted(repositoryID)))
      )
    }
  }

  private func mergePullRequestRefreshResults(
    repositoryID: Repository.ID,
    prsByBranch: [String: GithubPullRequest],
    confirmedNoPrBranches: Set<String>,
    state: inout State
  ) {
    var merged = state.prRefreshResultsByRepositoryID[repositoryID] ?? [:]
    var resultPriorities = state.prRefreshResultPrioritiesByRepositoryID[repositoryID] ?? [:]
    let remotePriorities = state.prRefreshRemotePrioritiesByRepositoryID[repositoryID] ?? [:]
    // Host batches race independently. Use the returned PR URL to recover its
    // source repo, then compare against the original remote order before replacing.
    for (branch, pullRequest) in prsByBranch {
      let priority = remotePriority(for: pullRequest, remotePriorities: remotePriorities)
      if merged[branch] == nil || priority < (resultPriorities[branch] ?? .max) {
        merged[branch] = pullRequest
        resultPriorities[branch] = priority
      }
    }
    // Accumulate confirmed-no-PR branches. Only clear when all repos for a
    // branch succeeded and none returned a PR — partial failures leave the
    // branch out of confirmedNoPrBranches so existing state is preserved.
    var existingConfirmed = state.prRefreshNoPrBranchesByID[repositoryID] ?? []
    existingConfirmed.formUnion(confirmedNoPrBranches)
    // Remove any confirmed-no-PR entries that now have a PR (priority-based
    // merge may have resolved a later host's PR over an earlier "no PR").
    existingConfirmed.subtract(merged.keys)
    state.prRefreshNoPrBranchesByID[repositoryID] = existingConfirmed
    state.prRefreshResultsByRepositoryID[repositoryID] = merged
    state.prRefreshResultPrioritiesByRepositoryID[repositoryID] = resultPriorities
  }

  private func remotePriority(
    for pullRequest: GithubPullRequest,
    remotePriorities: [String: Int]
  ) -> Int {
    guard let remoteInfo = GitClient.parseGithubRemoteInfo(pullRequest.url) else {
      return .max
    }
    return remotePriorities[Self.pullRequestRefreshRemotePriorityKey(remoteInfo)] ?? .max
  }

  private func clearPullRequestRefreshTracking(
    repositoryID: Repository.ID,
    state: inout State
  ) {
    state.prRefreshBatchCountsByRepositoryID.removeValue(forKey: repositoryID)
    state.prRefreshResultsByRepositoryID.removeValue(forKey: repositoryID)
    state.prRefreshNoPrBranchesByID.removeValue(forKey: repositoryID)
    state.prRefreshFailedBatchRepositoryIDs.remove(repositoryID)
    state.prRefreshRemotePrioritiesByRepositoryID.removeValue(forKey: repositoryID)
    state.prRefreshResultPrioritiesByRepositoryID.removeValue(forKey: repositoryID)
  }

  private func clearAllPullRequestRefreshTracking(state: inout State) {
    state.prRefreshBatchCountsByRepositoryID.removeAll()
    state.prRefreshResultsByRepositoryID.removeAll()
    state.prRefreshNoPrBranchesByID.removeAll()
    state.prRefreshFailedBatchRepositoryIDs.removeAll()
    state.prRefreshRemotePrioritiesByRepositoryID.removeAll()
    state.prRefreshResultPrioritiesByRepositoryID.removeAll()
  }

  private func consumePullRequestRefreshBatch(
    repositoryID: Repository.ID,
    state: inout State
  ) -> Bool {
    let remaining = (state.prRefreshBatchCountsByRepositoryID[repositoryID] ?? 1) - 1
    guard remaining > 0 else {
      state.prRefreshBatchCountsByRepositoryID.removeValue(forKey: repositoryID)
      return true
    }
    state.prRefreshBatchCountsByRepositoryID[repositoryID] = remaining
    return false
  }

  private func pullRequestsByWorktreeID(
    repository: Repository,
    worktreeIDs: [Worktree.ID],
    prsByBranch: [String: GithubPullRequest],
    confirmedNoPrBranches: Set<String>
  ) -> [Worktree.ID: GithubPullRequest?] {
    var prsByWorktreeID: [Worktree.ID: GithubPullRequest?] = [:]
    for worktreeID in worktreeIDs {
      guard let worktree = repository.worktrees[id: worktreeID] else { continue }
      if let pullRequest = prsByBranch[worktree.name] {
        prsByWorktreeID[worktreeID] = pullRequest
      } else if confirmedNoPrBranches.contains(worktree.name) {
        // All repos confirmed no PR for this branch — explicitly clear. A nil
        // literal through the subscript would remove the key instead of storing
        // an explicit nil, so downstream would never see the clear.
        prsByWorktreeID.updateValue(nil, forKey: worktreeID)
      }
      // Otherwise: unknown status (partial failure) — omit to preserve existing.
    }
    return prsByWorktreeID
  }

  func enqueueBatchedPullRequestRefresh(
    repositoryID: Repository.ID,
    repositoryRootURL: URL,
    worktrees: [Worktree],
    branches: [String]
  ) -> Effect<Action> {
    let worktreeIDs = worktrees.map(\.id)
    let coordinatorClient = pullRequestRefreshCoordinator
    let githubCLI = self.githubCLI
    let gitClient = self.gitClient
    return .run { send in
      let remoteInfos = await RepositoriesFeature.resolveGithubRemoteInfos(
        repositoryRootURL: repositoryRootURL,
        githubCLI: githubCLI,
        gitClient: gitClient
      )
      guard !remoteInfos.isEmpty else {
        // No GitHub remote configured for this repository — preserve existing PR
        // values rather than clearing them, which would cause a flicker during
        // refresh cycles.
        await send(.githubIntegration(.repositoryPullRequestRefreshCompleted(repositoryID)))
        return
      }
      @Shared(.repositorySettings(repositoryRootURL)) var repositorySettings
      let remoteInfosByHost = Dictionary(grouping: remoteInfos, by: \.host)
      await send(
        .githubIntegration(
          .pullRequestRefreshBatchCountResolved(
            repositoryID: repositoryID,
            count: remoteInfosByHost.count,
            remotePriorities: Self.pullRequestRefreshRemotePriorities(remoteInfos)
          )
        )
      )
      for (host, hostRemoteInfos) in remoteInfosByHost {
        coordinatorClient.enqueue(
          PullRequestRefreshCoordinator.Request(
            repositoryID: repositoryID,
            repositoryRootURL: repositoryRootURL,
            host: host,
            repositories: hostRemoteInfos,
            accountOverride: repositorySettings.githubAccountOverride,
            branches: branches,
            worktreeIDs: worktreeIDs
          )
        )
      }
    }
  }

  nonisolated private static func displayPullRequest(
    _ pullRequest: GithubPullRequest?,
    for worktree: Worktree
  ) -> GithubPullRequest? {
    if worktree.isMain, pullRequest?.state.uppercased() == "MERGED" {
      return nil
    }
    return pullRequest
  }

  nonisolated private static func preservingMergeableState(
    _ pullRequest: GithubPullRequest?,
    previous: GithubPullRequest?
  ) -> GithubPullRequest? {
    guard var pullRequest else { return pullRequest }
    let newMergeable = pullRequest.mergeable?.uppercased()
    let previousMergeable = previous?.mergeable?.uppercased()
    let isUnknown = newMergeable == "UNKNOWN"
    let hasKnownPrevious = previousMergeable != nil && previousMergeable != "UNKNOWN"
    if isUnknown && hasKnownPrevious, let previous {
      pullRequest.mergeable = previous.mergeable
      pullRequest.mergeStateStatus = previous.mergeStateStatus
    }
    return pullRequest
  }

  nonisolated private static func pullRequestRefreshRemotePriorities(
    _ remoteInfos: [GithubRemoteInfo]
  ) -> [String: Int] {
    var priorities: [String: Int] = [:]
    for (index, remoteInfo) in remoteInfos.enumerated() {
      let key = pullRequestRefreshRemotePriorityKey(remoteInfo)
      if priorities[key] == nil {
        priorities[key] = index
      }
    }
    return priorities
  }

  nonisolated private static func pullRequestRefreshRemotePriorityKey(
    _ remoteInfo: GithubRemoteInfo
  ) -> String {
    [
      remoteInfo.host.lowercased(),
      remoteInfo.owner.lowercased(),
      remoteInfo.repo.lowercased(),
    ].joined(separator: "/")
  }

  nonisolated private static func validWebURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw),
      let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      url.host != nil
    else {
      return nil
    }
    return url
  }

  var githubIntegrationReducer: some ReducerOf<Self> {
    Reduce { state, action in
      guard case .githubIntegration(let action) = action else {
        return .none
      }
      return reduceGithubIntegration(state: &state, action: action)
    }
  }
}
