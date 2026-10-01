# 028.007 — Check Counts for Badges

## Context

PR polling tripped GitHub's GraphQL secondary rate limit on a shared account twice
(2026-09-29 and 2026-09-30) while the account's hourly point budget stayed almost full:
4,979 of 5,000 remained during the second incident. The batch query was cheap in points
but expensive for GitHub to resolve. Every branch asked for up to five pull requests,
and every pull request for `statusCheckRollup.contexts(first: 100)` with each check's
name, status, conclusion, timestamps, and URL. A 34-branch query could ask GitHub to
resolve up to 17,000 check nodes, which secondary limits on server time count
against the account.

Only two places use the individual checks: the checks popover and the "Copy failing job
URL" and "Open failing check" actions. The badge, the checks ring, the toolbar status
text, merge readiness, and the command palette's failing-check items need per-state
counts.

## Change

- **Counts on every pull request.** The query selects
  `contexts { checkRunCountsByState { state count } statusContextCountsByState { state count } }`
  for every pull request, which needs no pagination arguments and adds no nodes.
  `GithubPullRequestStatusCheckRollup` decodes them into `counts`, mapping each state onto
  the bucket `GithubPullRequestStatusCheck.checkState` assigns to a single check of that
  state, and exposes `breakdown`: the counts when present, else a breakdown of the list.
  `GithubPullRequest.checkBreakdown` is the reader the badge, ring, status text, merge
  readiness, and palette use.
- **List for the selected worktree only.** `CrossRepoPullRequestRequest.detailBranches`
  names branches whose pull request also lists each check with
  `contexts(first: 100) { nodes { ... } }`. The reducer fills it with the selected
  worktree's branch, and the coordinator carries it through merged requests. Selecting a
  worktree already triggers an immediate refresh of its repository, so the list arrives
  with it. Counts win over the list when both are present, since the list stops at 100.
- **Shared selection.** Both query builders take the pull request fields from
  `pullRequestNodeFields(includeCheckDetails:)` instead of two copies.
- **Popover.** For a pull request fetched with counts only, the popover shows the ring
  and summary and the line "Select this worktree to list each check."

The single-repository fallback query asks for counts only.

## Refs

Tests: `App/Tests/PullRequestCheckCountsTests.swift` (every count state decodes into
the bucket of the matching single check; counts win over a capped list; merge readiness
reads counts; only detail branches list checks in the batch query),
`PullRequestRefreshCoordinatorTests.swift` (detail branches reach the batched query),
`BatchedPullRequestRefreshReducerTests.swift` (only the selected worktree's branch is a
detail branch).
