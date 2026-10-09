# 028 — PR Status Tracking: Plan

| | |
| --- | --- |
| **Status** | Implemented (retrospective) |
| **Anchor date** | 2026-05-08 |
| **Documented** | 2026-07-12 (backfilled) |
| **Primary PRs** | #256, #305, #366, #379 (anchor wave); #425, #456, #469, #519 (merge queue / fork remotes); #496, #499, #500, #501, #505 (status fidelity / cadence); #533, #538, #539 (flicker) |
| **Sources** | PR descriptions listed above; fork issues #452, #462, #463; upstream review ledger (2026-06-09 batch, upstream #352) — see `docs-ai/017-upstream-sync-process/upstream-ledger.md` |
| **Related** | [037-line-diff-tracking](../037-line-diff-tracking/000-plan.md) (sibling sidebar-badge pipeline; per-repo PR observation toggle), [039-gh-cli-hardening](../039-gh-cli-hardening/000-plan.md) (gh subprocess robustness), [017-upstream-sync-process](../017-upstream-sync-process/000-plan.md) (#425 port provenance), [033-ui-refresh-2026-05](../033-ui-refresh-2026-05/000-plan.md) (contributor of #521/#532/#533), `docs/components/github-pull-requests.md` |

## Background

Prowl inherited GitHub PR integration from upstream supacode: for each worktree branch it
queries the `gh` CLI for the matching pull request and shows state in the sidebar row
(`WorktreeRow`), a toolbar status button, a checks popover, and per-worktree badges, plus
write actions (merge, close, mark ready). The fork's real-world usage put that pipeline
under stress it was not designed for:

- **Fork clones resolved to the wrong repo.** Repo identity came from parsing the git
  remote URL; for fork clones (e.g. `onevcat/Prowl` forked from `supabitapp/supacode`)
  this mismatched where the PRs actually live, batch matching produced same-branch false
  positives, and write actions (`gh pr merge`/`close`/`ready`) ran without `--repo`, so
  they could target the wrong repository (#256, the anchor).
- **The main worktree showed a stale "merged" chip.** Old merged PRs whose head branch
  was the default branch got applied to the main worktree row (#305).
- **Refresh cost scaled 2N subprocesses per cycle.** Each of N open repositories spawned
  one `gh repo view` (remote resolution) plus one `gh api graphql` (PR fetch) every 30 s.
  With 14 repos open that was ~60 subprocesses per minute of steady-state CPU/energy
  burn (#366).

## Goals

- Resolve the owning GitHub repository correctly for fork clones, and route all PR write
  actions through an explicit `--repo`.
- Show only status that is true for the worktree (no stale merged chip on main).
- Collapse the per-repo subprocess storm into roughly one batched GraphQL call per host
  per refresh cycle, without letting one bad repo poison the batch.
- Keep the pipeline evolvable: later waves (merge-queue state, multi-remote/fork lookup,
  pending-checks fidelity, flicker-free updates) build on the same coordinator.

**Non-goals**

- Replacing the `gh` CLI transport with direct token-based API access — auth stays with
  `gh auth`; Prowl never handles tokens.
- Non-GitHub code hosts. Unresolved/non-GitHub remotes abort the refresh path.

## Design / Approach

As of the anchor wave (reconstructed from #256/#305/#366/#379 PR descriptions):

- **Repo resolution** (#256): resolve GitHub repository ownership with `gh repo view`
  before falling back to git remote parsing; cache the resolved `GithubRemoteInfo` per
  repository; pass it to `gh pr merge`/`close`/`ready` via `--repo`; tighten batch PR
  matching against fork clones, same-branch false positives, and deleted fork heads.
- **Main-worktree filter** (#305): ignore merged pull requests when applying PR metadata
  to the main worktree; keep merged-PR display for feature worktrees (where "Merged"
  drives the merged-worktree action flow).
- **Batching architecture** (#366), the load-bearing design of this entry:
  - `GithubCLIClient.batchPullRequestsAcrossRepositories` issues one multi-repository
    GraphQL query per host, aliasing each repo and its branches (up to 15 repos per
    call). Top-level `errors[]` entries are routed back to the owning repository so one
    bad permission cannot drop data for the rest.
  - A `@MainActor PullRequestRefreshCoordinator` sits between reducer effects and the
    client: buckets requests by host, debounces 250 ms to coalesce concurrent enqueues,
    serialises per-host work with an inflight lock (mid-flight enqueues queue and flush
    after the prior batch), falls back to per-repo `batchPullRequests` concurrently on
    partial errors, and applies a 12 s soft timeout that falls back the whole host.
  - `resolveGithubRemoteInfo` tries `git remote get-url` (~10 ms) before `gh repo view`
    (~200 ms); the batched query is authoritative about repo existence, so the gh call
    is redundant in steady state.
  - `WorktreeInfoWatcherManager.defaultPullRequestPhaseOffset` returns zero so all repos
    co-fire into the same debounce window instead of fragmenting across batches.
- **Fan-out correctness** (#379): group refresh requests by GitHub repo key before
  issuing cross-repo batches (multiple local clones of the same GitHub repo previously
  trapped `Dictionary(uniqueKeysWithValues:)`), and fan each repo-level result back out
  to every local repository that requested it.

## Alternatives & decisions

- **Batch GraphQL vs per-repo gh calls**: the 2N-subprocess model was rejected on
  measured CPU/energy cost; the coordinator+batch design replaced it (#366).
- **Staged rollout**: #366 shipped behind a `@Shared` app-storage flag during
  development and the flag was removed only after end-to-end verification against 14
  live repositories (including a non-GitHub remote exercising the unresolved-remote
  abort path).
- **Main-only merged filter** (#305): merged PRs are suppressed only on the main
  worktree; feature worktrees intentionally keep showing merged state.
- Later-wave decisions (strict head-repo matching replacing the fork fallback, Set-based
  tri-state PR semantics, UNKNOWN-mergeable preservation, expected-checks-as-pending)
  are recorded in the amendments below.

## Amendments

- Updated 2026-06-27: merge-queue state and fork/multi-remote lookup (#425, #456, #469,
  #519) — see [002-merge-queue-and-fork-remotes.md](002-merge-queue-and-fork-remotes.md)
- Updated 2026-07-08: pending-checks fidelity, CLOSED state, selection cooldown, popover
  affordances (#496, #499, #500, #501, #505, #521, #532) — see
  [003-status-fidelity-and-refresh-cadence.md](003-status-fidelity-and-refresh-cadence.md)
- Updated 2026-07-08: flicker elimination and explicit no-PR semantics (#533 → #538 →
  #539) — see [004-flicker-and-no-pr-semantics.md](004-flicker-and-no-pr-semantics.md)
- Updated 2026-10-02: an account-wide gate stops every gh call on a rate-limit answer,
  backs off, and skips the per-repository fallback — see
  [005-rate-limit-gate.md](005-rate-limit-gate.md)
- Updated 2026-10-02: badge refreshes fetch per-state check counts, and only the selected
  worktree's pull request lists each check — see [007-check-counts.md](007-check-counts.md)
- Updated 2026-10-02: periodic refreshes ask only about pull requests whose state can
  change soon; settled, absent, and finished ones follow slower intervals — see
  [008-cadence-by-state.md](008-cadence-by-state.md)
