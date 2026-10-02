# 028.008 — Refresh Cadence by Pull Request State

## Context

PR polling tripped GitHub's GraphQL secondary rate limit on a shared account twice
(2026-09-29 and 2026-09-30). Every periodic refresh asked about every branch of the
repository, so the batched query grew with the number of worktrees even when nearly all
of their pull requests were merged or settled and could not have changed.

The incident report suggested skipping branches whose head SHA had not changed. That
would freeze check results and review state, which change without a push, so the
cadence here follows the pull request's state instead.

## Change

`PullRequestRefreshCadence.isDue` decides, per worktree, whether a periodic refresh
asks GitHub about it:

| Worktree | Asked |
| --- | --- |
| Selected | every refresh |
| Never answered | every refresh |
| Open, checks in progress or expected, mergeability `UNKNOWN`, or in the merge queue | every refresh |
| Open and settled | every 180 s |
| No pull request | every 300 s |
| Merged or closed | every 1,800 s |

`RepositoriesFeature.State.pullRequestCheckedAtByWorktreeID` records when GitHub last
answered for each worktree. A `.refreshed` outcome records the time only for worktrees
whose branch is in `prsByBranch` or `confirmedNoPrBranches`, so a branch left unknown by a
partial failure stays due. `repositoryPullRequestRefreshRequested` filters the requested
worktrees through `isDue` and sends no query when none is due; it reads the date only
when some worktree has a recorded time. A remote configuration change clears the
repository's recorded times.

The HEAD watcher sees branch switches, not pushes or new commits, so a pull request
opened outside Prowl appears within the no-pull-request interval, or immediately when
its worktree is selected.

`isActive` reads checks from `statusCheckRollup.checks`. Combined with the check-count
change (amendment 007, a separate change), it reads `GithubPullRequest.checkBreakdown`
instead, since background refreshes then carry counts without a list.

## Refs

Tests: `App/Tests/PullRequestRefreshCadenceTests.swift` (the interval for each state,
the selected and never-answered cases), `BatchedPullRequestRefreshReducerTests.swift`
(only due worktrees are asked; nothing due sends nothing; the selected worktree is always
asked; only answered branches record a time), `RepositoriesFeatureTests.swift` (a remote
change clears recorded times).
