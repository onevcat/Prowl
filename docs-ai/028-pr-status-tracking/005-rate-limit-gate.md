# 028.005 — Rate-Limit Gate for Every gh Call

## Context

PR polling tripped GitHub's GraphQL secondary rate limit on a shared account twice
(2026-09-29 and 2026-09-30). While the limit held, every tool and agent on the account
was refused, and only disabling Prowl's GitHub integration ended it. Sampling the app
during the second incident showed three compounding causes in this pipeline:

- Nothing recognized a rate-limit answer. GitHub's refusal
  (`{"errors":[{"type":"RATE_LIMIT","code":"graphql_rate_limit",...}]}`) reached the
  coordinator as an ordinary failure.
- An ordinary failure starts the per-repository fallback, which runs every repository
  concurrently in chunks. A refusal therefore multiplied the request rate: 8 batched
  and 21 fallback queries in 45 seconds of sampling.
- Polling continued at full cadence through the refusals, and refused requests can
  extend a secondary limit. The hourly GraphQL budget read 4,979 of 5,000 throughout,
  so the primary counter carries no signal about this kind of block.

## Change

One account-wide gate, `GithubRateLimitGate` in
`App/Sources/Clients/Github/GithubRateLimit.swift`, sits in `runGh`, the single funnel for
gh commands that reach GitHub. `--version` and `auth switch` stay on the machine and
run through `runLocalGh`, outside the gate.

- **Classification** (`GithubRateLimitClassifier`). Both GraphQL calls pass `--include`,
  so gh prints the status line and headers ahead of the body. A request counts as
  refused on HTTP 429; on HTTP 403 only with rate-limit evidence (`Retry-After`,
  `X-RateLimit-Remaining: 0`, or a rate-limit message), because a 403 is also a
  permission answer; on a top-level GraphQL error of type `RATE_LIMITED` or
  `RATE_LIMIT`; or on a rate-limit message in stderr of a failed command. Payload
  text, such as a pull request title, is never read. A successful answer that spends
  the last of the budget blocks until `X-RateLimit-Reset` without discarding its data.
- **Backoff.** `Retry-After` sets the wait when present, then `X-RateLimit-Reset`.
  Otherwise the wait starts at 60 s and doubles per consecutive refusal, with up to
  25% added jitter, capped at 1 h.
- **Probe.** When the wait ends, exactly one request goes out. Requests arriving
  meanwhile wait for its answer instead of racing it. An answer that is not a refusal
  reopens the gate and resets the backoff; a refusal starts the next, longer wait. A
  request admitted before the gate closed cannot reopen it, and a cancelled probe
  passes the probe role on.
- **No fallback on a refusal.** `PullRequestRefreshCoordinator` emits
  `Outcome.rateLimited(retryAt:)` and skips the per-repository fallback; other
  failures still fall back.
- **Surface.** `RepositoriesFeature.State.githubRateLimitedUntil` is set by the
  rate-limited outcome and cleared by the next refresh GitHub answers. The toolbar
  status area shows "GitHub rate-limited, retrying at HH:MM" below a toast or running
  workflow and above PR status; Settings → GitHub shows the same. User PR actions fail
  with `GithubCLIError.rateLimited`, whose message is "GitHub rate-limited until HH:MM".

The gate is process-wide and keyed to nothing narrower: a limit on one account pauses
requests for every account and host Prowl uses. That is the conservative reading of a
shared account and costs nothing for the common one-account setup.

## Current state

This is the first of four slices. The remaining three reduce how much Prowl asks for in
the first place: a worktree-set change refreshes only the changed repository through a
paced queue with one query in flight per account; the badge query fetches check counts
instead of up to 100 check contexts per pull request; and polling cadence follows each
pull request's state.

Tests: `App/Tests/GithubRateLimitTests.swift` (classifier, gate, and a fake gh that
asserts no process starts before the retry time and that `Retry-After` is honored),
`PullRequestRefreshCoordinatorTests.swift` (no fallback on a refusal),
`BatchedPullRequestRefreshReducerTests.swift`, and
`WorkflowStatusCenterPresentationTests.swift` (toolbar precedence).
