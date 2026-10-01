# GitHub / Pull Request Integration

> See a worktree's PR status and CI, and act on it — merge, mark-ready, re-run
> failed jobs, copy failure logs — without leaving Prowl.

**Keywords:** github, pull request, PR, CI, checks, merge, mark ready, re-run, failing jobs, code host, gh cli

**Related:** [command-palette](command-palette.md) · [repositories-and-worktrees](repositories-and-worktrees.md) · [diff-view](diff-view.md) · [settings](settings.md)

## What it is

For git repositories hosted on GitHub, Prowl fetches the pull request associated
with a worktree's branch and exposes its status and actions. It works through the
**`gh` CLI**, so it uses your existing `gh auth` — Prowl never handles tokens
itself.

If a repository has multiple GitHub remotes, Prowl checks each remote for a PR on
the worktree branch. `origin` is preferred, `upstream` comes next, and other
named remotes are used alphabetically, so fork-based worktrees can show upstream
PRs without changing `origin` or restarting the app. A returned PR's head
repository must match one of the repository's configured GitHub remotes; PRs
from unrelated forks that happen to use the same branch name are ignored.

Prowl also watches the repository's git config while the app is running. When
remote URLs are added, removed, or changed, it refreshes the repository's PR
state and code-host label automatically; if the repository no longer has a
GitHub remote, stale PR badges are cleared.

## What it shows

- PR number, title, state (open/closed/merged), draft status.
- Additions/deletions, author, base/head branches.
- Review decision (approved / changes requested / pending).
- **CI status:** a rollup of all checks (success / failure / in-progress /
  expected / skipped) with failing/success counts and per-check detail URLs.
- **Merge readiness:** Prowl evaluates blockers in order — merge conflicts,
  changes requested, failed checks, other non-mergeable states.
- **Merge queue:** for repos that use GitHub merge queues, an open PR waiting in
  the queue shows a brown **Queued** state in the sidebar and badges, and the PR
  checks popover adds an "In merge queue" row with its position and estimated
  time remaining.

PR status can surface as a badge on the worktree and as a summary in the command
palette. The **PR #N** tag in a sidebar row is a link — click it to open the
pull request in the browser; right-click the row → **Open Pull Request** does
the same (falling back to the repository page when no PR URL is known).

## Actions (via Command Palette, when a PR exists)

Open the [Command Palette](command-palette.md) (`⌘P`) on a worktree that has a PR
(or focus that worktree's card in Canvas):

- **Open Pull Request on GitHub** — open it in the browser. (`⌘⌃G` "Open on Code
  Host" also opens the PR/repo page, including from Canvas.)
- **Mark PR Ready for Review** — convert a draft to ready (only when it's a draft).
- **Copy failing job URL** — copy the first failing check's URL.
- **Copy CI Failure Logs** — extract and copy the failed run's logs (great to hand
  back to an agent to fix).
- **Re-run Failed Jobs** — re-trigger the latest failed workflow.
- **Open Failing Check Details** — open a failing check in the browser.
- **Merge PR** — merge when mergeable (not draft, checks pass, no conflicts, no
  changes requested). Merge strategy comes from `pullRequestMergeStrategy`
  (global) or the per-repo override (`merge` / `squash` / `rebase`).
- **Close PR** — close an open PR.

## Requirements & settings

- The **`gh` CLI** must be installed and authenticated (`gh auth login`). Prowl
  locates `gh` via `which` (directly, then through a login shell), falling back to
  common install paths (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`)
  when the shell `PATH` misses it. Login-shell probing works even with a
  non-POSIX login shell (nushell, pwsh, …) — Prowl falls back to `/bin/zsh` for
  one-shot commands in that case.
- `githubIntegrationEnabled` (global) gates all GitHub features.
- Per repo: `fetchPullRequestState` (auto-fetch PR state; on by default — turn off
  for big/expensive repos), `pullRequestMergeStrategy` override, and
  `githubAccountOverride` for repositories that need a specific `gh` account.
- Settings → **GitHub** tab shows every authenticated `gh` host/account and which
  account is active for each host.

When a repository has `githubAccountOverride` set, Prowl temporarily runs
`gh auth switch --hostname <host> --user <login>` before GitHub operations for
that repository, then switches the host back to the previously active account.
This uses `gh`'s stored authentication state; Prowl still never reads or stores
GitHub tokens.

## How often Prowl asks GitHub

The `gh` account Prowl uses is usually shared with other tools and agents, so
Prowl paces its pull request queries:

- The selected worktree's repository refreshes every 30 seconds. Every other
  repository refreshes in one background sweep, every 60 seconds or every 2
  seconds per worktree Prowl tracks, whichever is longer — about every 100
  seconds with 50 worktrees.
- Adding or removing worktrees refreshes only the repositories they belong to.
- One query runs at a time, and Prowl waits at least 15 seconds between
  queries, including the queries of one large refresh. Refreshes requested in
  the meantime join the next query, so opening many worktrees at once costs one
  query, not one each.

## Gotchas for agents

- No `gh` / not authenticated → no PR features. If a human expects PR actions and
  they're missing, check `gh auth status`.
- If a repo is pinned to a specific GitHub identity and PR actions fail, verify
  that `gh auth status` lists that account on the repo's host.
- PR actions appear in the palette **only when the selected worktree's branch has a
  PR**. No PR → no actions.
- "Copy CI Failure Logs" is the high-value loop for agents: copy logs → feed to the
  agent → it fixes → "Re-run Failed Jobs".
