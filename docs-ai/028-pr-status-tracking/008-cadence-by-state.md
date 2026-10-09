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
| Never answered, on another branch than its checkpoint, or marked after an action or remote change | every refresh |
| Open, checks in progress or expected, mergeability `UNKNOWN`, or in the merge queue | every refresh |
| Open and settled | every 180 s |
| No pull request | every 300 s |
| Merged or closed | every 1,800 s |

`RepositoriesFeature.State.pullRequestRefreshCheckpointByWorktreeID` records GitHub's last
complete answer for each worktree as a `PullRequestRefreshCadence.Checkpoint`: the branch
the answer was for, when it arrived, and the interval the answer earns. A checkpoint is
recorded when the last host batch of a refresh comes back and every host answered in full,
and only for worktrees whose branch has a pull request or a confirmed absence of one. A
host whose batch failed, or whose repositories did not all answer even after the
per-repository fallback (`Outcome.refreshed(isPartial: true)`), leaves the branch status
on that host unknown: its found pull requests still show, but nothing is confirmed absent,
no checkpoint is recorded, and a sent mark goes back on completion, so the branch stays due.

The checkpoint reads its interval from the answer as GitHub gave it, not from the pull
request on screen: `repositoryPullRequestsLoaded` keeps the previous mergeability while
GitHub reports `UNKNOWN` (amendment 004), which would otherwise turn a pull request GitHub
is still computing into a settled one for the cadence. A checkpoint answers only for its
branch, so a worktree whose HEAD moved to another branch, through the HEAD watcher's branch
update or a repository reload, is due on the next sweep instead of inheriting the previous
branch's interval. `repositoryPullRequestRefreshRequested` filters the requested worktrees
through `isDue` and sends no query when none is due; it reads the date only when some
worktree has a checkpoint.

`pullRequestRefreshForcedWorktreeIDs` marks worktrees the next refresh must ask about
whatever their cadence says: the worktree a pull request action just changed
(`delayedPullRequestRefresh`), and every worktree of a repository whose remote
configuration changed. Sending a refresh moves its marks into
`sentPullRequestRefreshMarks`; a mark drops when GitHub answers for its branch, and any
still there when the refresh completes, because it failed or never reached GitHub, is
marked again. An answer to an older request, such as one to the previous remote still in
flight, never carried the new marks and cannot clear them. A worktree ID is its path, so removing a worktree forgets its
recorded time and mark; a worktree created again at that path starts as never answered.

The HEAD watcher sees branch switches, not pushes or new commits, so a pull request
opened outside Prowl appears within the no-pull-request interval, or immediately when
its worktree is selected.

`isActive` reads checks from `statusCheckRollup.checks`. Combined with the check-count
change (amendment 007, a separate change), it reads `GithubPullRequest.checkBreakdown`
instead, since background refreshes then carry counts without a list.

## Refs

Tests: `App/Tests/PullRequestRefreshCadenceTests.swift` (the interval for each state,
the selected, never-answered and switched-branch cases, the interval a checkpoint reads
from the answer), `BatchedPullRequestRefreshReducerTests.swift` (only due worktrees are
asked; nothing due sends nothing; the selected worktree is always asked; only answered
branches record a checkpoint; a switched branch is asked at once; an `UNKNOWN` answer keeps
the pull request on every sweep while the display keeps the known state; a partial host
answer shows its pull requests but records no checkpoint and keeps the mark; a marked
worktree is asked despite a recent answer; a mark survives a refresh that never reaches
GitHub, and one where a host fails after another confirmed no pull request; an answered
branch drops its mark and an unanswered one keeps it; a pull request action marks its
worktree), `PullRequestRefreshCoordinatorTests.swift` (a complete answer is not partial, a
candidate repository that failed makes it partial), `RepositoriesFeatureTests.swift` (a
remote change marks every branch; loading forgets the history of removed worktrees).
