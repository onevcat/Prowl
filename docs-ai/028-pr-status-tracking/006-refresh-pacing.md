# 028.006 — Refresh Pacing

## Context

PR polling tripped GitHub's GraphQL secondary rate limit on a shared account twice
(2026-09-29 and 2026-09-30), and both incidents followed Prowl adding many worktrees
at once: a restart that brought back about 15 panes, and about 8 new worktrees within
10 minutes. Three properties of the pipeline turned those events into bursts:

- `WorktreeInfoWatcherManager.setWorktrees` scheduled an immediate refresh for every
  repository whenever the worktree set changed, so each new worktree re-queried every
  repository.
- Cross-repository chunks and single-repository chunks ran three at a time, and the
  per-repository fallback ran every repository concurrently.
- Nothing spaced batches apart beyond the coordinator's per-host in-flight lock.

The account-wide rate-limit gate, amendment 005 in a separate change, handles a refusal
once it arrives. This amendment reduces the load that provokes one.

## Change

- **Changed repositories only.** `setWorktrees` compares each repository's worktree IDs
  before and after; only a repository whose set changed refreshes immediately. The
  others keep their schedule.
- **Sweep scales with worktrees.** The unfocused interval is
  `max(unfocusedInterval, unfocusedIntervalPerWorktree × tracked worktrees)`, defaults
  60 s and 2 s. All repositories still fire together so the coordinator folds them into
  one query per host; the interval keeps that query's cost per hour flat as it grows.
  The focused repository keeps its 30 s interval.
- **One query at a time.** `crossRepoBatchMaxConcurrentRequests` and
  `batchPullRequestsMaxConcurrentRequests` are 1, and the fallback queries one
  repository at a time. The coordinator's soft timeout scales with the number of
  cross-repository chunks, since they now run in sequence.
- **Minimum gap.** After a batch, `PullRequestRefreshCoordinator` holds the host key for
  `minimumBatchGap` (15 s) before the next batch starts. Requests arriving meanwhile
  merge into that next batch.

Worst case for 50 worktrees across about 10 repositories on one host: one background
sweep every 100 s (36 per hour) plus the focused repository every 30 s (120 per hour),
about 156 GraphQL queries per hour. The 15 s gap caps any mix of requests at 240 per
hour. The sampled incident ran at roughly 1,300 per hour.

## Refs

Tests: `App/Tests/WorktreeInfoWatcherManagerTests.swift` (only the changed
repository refreshes; the sweep slows with the worktree count),
`PullRequestRefreshCoordinatorTests.swift` (requests within the gap merge into one later
batch; the fallback runs one repository at a time), `GithubCLIClientTests.swift`
(chunks run one at a time).
