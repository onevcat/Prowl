# 071 — Git Environment Recovery: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-09-20 |
| **Related** | #823, [010 plain folders](../010-plain-folder-support/000-plan.md), [023 Shelf](../023-shelf-mode/000-plan.md) |

## Background

A GUI reproduction on macOS 27 confirmed that an unavailable Apple Git toolchain
causes `wt root` to append `not a git repository`. Prowl saves the repository as a
plain folder. Its worktree rows disappear and Shelf cannot open when no Git rows
remain. Restoring the toolchain and manually refreshing recovers both symptoms.
This establishes the failure mechanism, not the reporter's original environment.

## Goals

- Resolve a working Git executable across app-owned Git operations.
- Do not persist a repository type change when Git or repository access fails.
- Explain unavailable Git and repository read errors; offer retry and error details.
- Allow Shelf to open plain folders without requiring a Git worktree.

## Non-goals

No bundled Git, new Git path preference, system toolchain changes, or retention of
stale worktree lists after failed loads. Keep the existing failed-repository row.
Do not change Git chosen by user commands in terminal panes or workflow scripts.

## Approach

1. Use one executable resolver. Try the process PATH, login shell PATH, and common
   installation locations. Validate candidates with `git --version`, reuse successful
   resolution, merge concurrent discovery, and revalidate on repository discovery.
   Preserve the selected executable and its PATH for `wt` and other child processes.
   Do not replay failed mutation commands against another executable.
2. Give repository discovery a typed non-repository result. Classify only direct Git
   discovery output, with checks for inaccessible or existing Git metadata. Never
   classify `wt`'s error wrapper by substring. Keep genuine plain-folder support.
3. Preserve persisted kind on unknown failures. Reuse the existing failure row,
   add a clear status and Retry, and show recovery guidance plus copyable details.
   Terminal cleanup preserves sessions owned by failed roots; this uses existing
   terminal ownership rather than retaining stale repository models.
4. Use one Shelf availability predicate for Git rows and plain folders. Include an
   unopened folder in the initial selection fallback.
5. Migrate app-owned hardcoded Git callers: clone, external diff snapshots, native
   workflow actions, and branch observation. Keep binary output and workflow process
   cancellation semantics intact.

## Validation

Test error classification, executable fallback and recovery, failed load persistence,
plain-only Shelf entry, error presentation and retry. Run the affected suites,
`make check`, and `make build-app`. Repeat isolated GUI acceptance with a disposable
repository and worktree, controlled PATH and developer directory. Verify both the
no-working-Git error state and independent-Git fallback; restore and retry in the
same process. Record automatic recovery separately from explicit Retry.

## Alternatives and decisions

Retaining stale repository models requires separate navigation and terminal lifetime
policy. It is excluded. Clearing DEVELOPER_DIR hides user configuration and does not
repair an invalid system default, so it is excluded. Bundling Git is a separate
packaging and maintenance decision.

## Amendments

PR #824 review follow-up:

- Accept Git's filesystem-boundary non-repository diagnostic in addition to its
  root-directory diagnostic. Keep the exit-code and metadata checks. Do not accept
  extra error output or a `wt` wrapper as proof.
- Bound each executable and login-shell probe with the existing process-group
  executor. Stop probe descendants on timeout or cancellation; do not add a second
  process runner or change mutation execution.
- Track shared-discovery waiters separately. Cancellation releases that waiter
  immediately. Other waiters keep the probe alive; the last cancellation stops it.
  Ignore late completion from a cancelled discovery so Retry can start a new one.
- Cover boundary diagnostics, timeout fallback, cancellation isolation, and retry.
  Use controlled clocks or explicit gates for concurrency tests and real process
  fixtures for process-group termination.
