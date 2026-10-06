# 028 — PR Status Tracking: Action Log

## Timeline

Grouped by problem wave; rows chronological within each wave.

### Wave 1 — Resolution correctness & batching (May)

| Date | Change | Ref |
| --- | --- | --- |
| 2026-05-08 | Fork-aware repo resolution (`gh repo view` before remote parsing); `--repo` on `gh pr merge`/`close`/`ready`; tightened batch matching for fork clones / same-branch false positives / deleted fork heads | PR #256 |
| 2026-05-19 | Ignore merged PRs when applying metadata to the main worktree; keep merged display for other worktrees | PR #305 |
| 2026-05-29 | `batchPullRequestsAcrossRepositories` (one GraphQL call per host, ≤15 repos aliased); `PullRequestRefreshCoordinator` (250 ms debounce, per-host inflight lock, per-repo fallback, 12 s soft timeout); per-repo `GithubRemoteInfo` cache; `git remote get-url` fast path; zero phase offset so repos co-fire | PR #366 |
| 2026-06-01 | Group refresh requests by GitHub repo key (fixes `Dictionary(uniqueKeysWithValues:)` trap on duplicate clones); fan repo results back to all requesting local repositories; same grouping on the fallback path | PR #379 |

### Wave 2 — Merge queue & fork remotes (June)

| Date | Change | Ref |
| --- | --- | --- |
| 2026-06-08 | GitHub merge-queue state: `mergeQueueEntry` in both GraphQL paths, `GithubMergeQueueEntry` + `PullRequestMergeQueueStatus`, brown "Queued" in sidebar/badges, "In merge queue" popover row (port of upstream #352) | PR #425 → [002](002-merge-queue-and-fork-remotes.md) |
| 2026-06-17 | Multi-remote PR lookup: query fork/upstream remote candidates (`origin` > `upstream` > others alphabetically); write actions resolved from the displayed PR's URL (fixes fork issue #452) | PR #456 → [002](002-merge-queue-and-fork-remotes.md) |
| 2026-06-17 | Watch each repo's git config for remote URL changes; debounced refresh of PR state + code-host labels; clear stale badges when no GitHub remote remains (fixes fork issue #463) | PR #469 → [002](002-merge-queue-and-fork-remotes.md) |
| 2026-06-27 | Filter PR matches by head repository; remove the fork fallback that surfaced unrelated same-name branches | PR #519 → [002](002-merge-queue-and-fork-remotes.md) |

### Wave 3 — Status fidelity & refresh cadence (late June)

| Date | Change | Ref |
| --- | --- | --- |
| 2026-06-24 | Yellow "N checks running" sidebar state via `PullRequestMergeBlockingReason.checksPending` (fixes fork issue #462) | PR #496 → [003](003-status-fidelity-and-refresh-cadence.md) |
| 2026-06-24 | Fold `EXPECTED` checks into the pending count (follow-up gap in #496) | PR #500 → [003](003-status-fidelity-and-refresh-cadence.md) |
| 2026-06-24 | Cancel the 5 s selection cooldown when switching to a *different* worktree (compare per-repo last selection, not global) | PR #499 → [003](003-status-fidelity-and-refresh-cadence.md) |
| 2026-06-24 | Prune `lastSelectedWorktreeIDByRepo` entries for removed repositories | PR #501 → [003](003-status-fidelity-and-refresh-cadence.md) |
| 2026-06-25 | Track CLOSED PRs: `states: [OPEN, MERGED, CLOSED]` in both queries; badge/summary/popover rendering (orange) | PR #505 → [003](003-status-fidelity-and-refresh-cadence.md) |
| 2026-06-28 | Hover link style (underline, blue, pointer) on CI check names in the checks popover | PR #521 |
| 2026-07-08 | Pointer cursor + unified accessibility hint on the PR title in the checks popover | PR #532 |

### Wave 4 — Flicker & no-PR semantics (July)

| Date | Change | Ref |
| --- | --- | --- |
| 2026-07-05 | Tri-state semantics: `confirmedNoPrBranches: Set<String>` distinguishes "confirmed no PR" from "not queried"; partial fetch failures preserve existing state | PR #533 → [004](004-flicker-and-no-pr-semantics.md) |
| 2026-07-05 | Supersedes #533: fix the nil-literal no-op clear (`updateValue(nil, forKey:)`); order-independent cross-host suppression via `prRefreshFailedBatchRepositoryIDs`; the missing non-empty-set test coverage | PR #538 → [004](004-flicker-and-no-pr-semantics.md) |
| 2026-07-08 | Preserve last-known `mergeable`/`mergeStateStatus` when GitHub returns transient `UNKNOWN` (kills the "Blocked" flash) | PR #539 → [004](004-flicker-and-no-pr-semantics.md) |

### Wave 5 — Rate limits & refresh load (October)

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-02 | Refresh only the repositories whose worktrees changed; background sweep every 60 s or 2 s per worktree, whichever is longer; one query in flight per host and account override, at least 15 s apart, with chunked batches and a sequential fallback | [006](006-refresh-pacing.md) |

## Outcome & current state (as of 2026-07-12)

Client layer, `supacode/Clients/Github/`:

- `GithubCLIClient.swift` — single-repo and cross-repo batch GraphQL builders; both
  request `states: [OPEN, MERGED, CLOSED]`, `headRepository`, and `mergeQueueEntry`;
  write actions append `--repo host/owner/repo` via `repoArgument(_:)`.
- `GithubPullRequest.swift`, `GithubMergeQueueEntry.swift`,
  `CrossRepoPullRequestResponse.swift`, `GithubGraphQLPullRequestResponse.swift` —
  decode models.
- `PullRequestMergeReadiness.swift` — blocker ordering (conflicts > changes requested >
  failed checks > pending checks > blocked); `checksPending` counts
  `breakdown.inProgress + breakdown.expected`.
- `PullRequestMergeQueueStatus.swift` — queue membership (open, non-draft, live entry
  only), 1-based position, estimated-time labels.
- `GithubRemoteInfo.swift` — resolved host/owner/repo identity.

Refresh pipeline:

- `supacode/Features/Repositories/BusinessLogic/PullRequestRefreshCoordinator.swift` —
  per-host buckets keyed by `RepoKey`, `KeyedDebouncer` (250 ms), `inflightHosts`
  serialization, per-repo fallback, `allowedHeadRepositories` for the head-repo filter.
- `supacode/Features/Repositories/BusinessLogic/WorktreeInfoWatcherManager.swift` —
  refresh scheduling; `lastSelectedWorktreeIDByRepo` (cooldown cancel + pruning);
  `remoteConfigMonitors` / `RemoteConfigMonitoring` with a 2 s `remoteConfigDebouncer`
  for git-remote-change refresh.
- `supacode/Features/Repositories/Reducer/RepositoriesFeature+GithubIntegration.swift`
  — `resolveGithubRemoteInfos` (multi-remote candidates), `pullRequestsByWorktreeID`
  (tri-state apply with explicit `updateValue(nil, forKey:)` clears),
  `prRefreshFailedBatchRepositoryIDs`, UNKNOWN-mergeable preservation before the
  equality check in `repositoryPullRequestsLoaded`, main-worktree merged filter
  (`worktree.isMain` + `state == "MERGED"`), write-action repo resolution from
  `pullRequest.url` via `GitClient.parseGithubRemoteInfo`.

UI:

- `supacode/Features/Repositories/Views/WorktreeRow.swift` — summary segments
  Merged / Closed (orange) / Queued (brown, priority over merge readiness) /
  merge-readiness label colored by `mergeStatusColor` (green / red / yellow).
- `PullRequestBadgeView.swift` (`closedColor = Color.orange`),
  `PullRequestStatusButton.swift` + `ToolbarStatusView.swift` (toolbar status;
  CLOSED early-returns like MERGED), `PullRequestChecksPopoverView.swift`
  (`.pointerStyle(.link)` on PR title and check names),
  `PullRequestChecksRingView.swift`, `WorktreePullRequestAccessoryView.swift`.

Tests: `supacodeTests/PullRequestRefreshCoordinatorTests.swift`,
`BatchedPullRequestRefreshReducerTests.swift`, `GithubBatchPullRequestsTests.swift`,
`GithubCLIClientTests.swift`, `PullRequestMergeReadinessTests.swift`,
`PullRequestMergeQueueStatusTests.swift`, `WorktreeInfoWatcherManagerTests.swift`.

User-facing behavior is documented in `docs/components/github-pull-requests.md`
(multi-remote preference order, head-repo filter, remote-change watching, merge queue,
check states).

## Deviations from plan

- #366's design survives intact; the only structural correction was #379's repo-key
  grouping (the coordinator originally assumed distinct GitHub repos per local repo).
- #256's remote-resolution order was itself revised twice: #366 inverted it
  (`git remote get-url` before `gh repo view`), and #456 replaced the single cached
  remote with per-refresh multi-remote candidate resolution.
- #533's tri-state design shipped, but its clearing path was dead code until #538
  (see amendment 004) — the plan-level semantics only became effective there.

## Open questions

- #425 explicitly deferred tinting the toolbar status button brown for queued PRs
  ("would require threading `isQueued` through `PullRequestStatusModel`"); no queued
  handling exists in `PullRequestStatusButton.swift` / `ToolbarStatusView.swift` today,
  so the follow-up was never picked up. Presumably still intentional (sidebar + popover
  + accessory cover the surfaces).
- #425 did not port upstream's GHES < 3.8 "retry without `mergeQueueEntry`" fallback;
  pointing Prowl at a pre-3.8 GitHub Enterprise Server would break the batch query.
  Accepted risk per the PR, unverified against a real GHES.
