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
  Each timer reads the interval again after it fires, so a longer interval never restarts
  an unchanged repository's timer. A shorter one brings the refresh forward to when the
  shorter interval, counted from the start of the current wait, would have fired. The
  focused repository keeps its 30 s interval.
- **One query at a time, each paced.** The coordinator sends one query per call: it
  splits a batch into groups of at most 15 repositories and the fallback into groups of
  at most 25 branches, and waits `minimumQueryGap` (15 s) before every query after the
  first. After a batch it holds the host key for the same gap, and requests arriving
  meanwhile merge into the next batch. The client's own chunk concurrency is 1 as well.

Worst case for 50 worktrees across about 10 repositories on one host: one background
sweep every 100 s (36 per hour) plus the focused repository every 30 s (120 per hour),
about 156 GraphQL queries per hour. Because every query waits 15 s after the previous
one, any mix of refreshes stays at or below 240 per hour. The sampled incident ran at
roughly 1,300 per hour.

## Refs

Tests: `App/Tests/WorktreeInfoWatcherManagerTests.swift` (only the changed
repository refreshes; the sweep slows with the worktree count),
`PullRequestRefreshCoordinatorTests.swift` (requests within the gap merge into one later
batch; a large batch and the fallback space each query), `GithubCLIClientTests.swift`
(chunks run one at a time).
