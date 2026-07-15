# 019 — Worktree Creation & Lifecycle: Plan

| | |
| --- | --- |
| **Status** | Implemented (retrospective) |
| **Anchor date** | 2026-04-12 |
| **Documented** | 2026-07-12 (backfilled) |
| **Primary PRs** | #167, #189, #190, #192 (initial wave); later waves #260/#419, #375/#383, #424/#427, #520 |
| **Sources** | PR descriptions #167/#189/#190/#192/#260/#375/#383/#419/#424/#427/#520; fork issues #166/#175/#176/#178; `docs-ai/017-upstream-sync-process/upstream-ledger.md` (2026-04-08 and 2026-05-08 review batches) |
| **Related** | [018-archived-worktrees](../018-archived-worktrees/000-plan.md), [028-pr-status-tracking](../028-pr-status-tracking/000-plan.md), [034-worktree-watcher-correctness](../034-worktree-watcher-correctness/000-plan.md), [044-foundation-model-branch-names](../044-foundation-model-branch-names/000-plan.md), `docs/components/repositories-and-worktrees.md` |

## Background

Worktrees are Prowl's unit of parallel agent work: each agent session normally lives in
its own git worktree created from the New Worktree dialog. By April 2026 the inherited
creation and merge handling had several rough edges:

- The base-ref picker dropped local branches that track a remote (`branchRefs(for:)`
  mapped each local branch to its upstream ref), so the picker looked remote-only
  (fork issue #166).
- Creation used whatever the local remote-tracking refs happened to be — starting a
  worktree from a stale `origin/main` was easy (fork issue #176).
- When a worktree's PR merged, the only automation was a boolean "automatically archive"
  toggle; there was no "delete" option (fork issue #175).
- `copyIgnoredOnWorktreeCreate`, `copyUntrackedOnWorktreeCreate`, and
  `pullRequestMergeStrategy` existed only as per-repo settings, so every repository had
  to be configured individually (fork issue #178).

This entry covers that April wave plus the later lifecycle waves that accreted on the
same flows: worktree history navigation, deletion safety, per-creation placement
overrides, and the redesigned repository intake ("Add to Prowl") popover.

## Goals

- Base-ref options include local branches alongside upstream refs (dedup/sort kept).
- Optional (default-on) `git fetch <remote>` before worktree creation, resolved against
  the base ref; fetch failure logs and continues — it must never block creation.
- Replace the auto-archive boolean with a `MergedWorktreeAction?` picker: do nothing /
  archive / delete, with legacy settings migration.
- Promote copy flags and PR merge strategy to global defaults with per-repo optional
  overrides (`nil` = use global), shown as "Global (current value)" pickers per repo.

**Non-goals** (initially): per-creation placement control, branch-name suggestion,
deletion-safety rework, clone-from-URL intake — all later waves (see Amendments).

## Design / Approach

- **Base refs** (#167): `GitClient.branchRefs(for:)` returns both the local branch ref
  and its upstream ref instead of collapsing tracking branches into their upstream.
- **Fetch before creation** (#189): global `fetchOriginBeforeWorktreeCreation` (default
  `true`) plus a per-creation toggle in the prompt. After resolving the base ref, match
  it against `git remote` output (longest prefix) and run `git fetch <remote>`; a
  dedicated fetch stage in `WorktreeCreationProgress` surfaces it in the progress UI.
- **Merged worktree action** (#190): `MergedWorktreeAction` enum (`archive`/`delete`),
  optional in `GlobalSettings`; legacy `automaticallyArchiveMergedWorktrees: true`
  decodes to `.archive`, `false` to `nil`. `.delete` dispatches the same
  `deleteWorktreeConfirmed` path as manual deletion and honors the "Delete local branch
  with worktree" setting.
- **Global defaults** (#192): the three settings move into `GlobalSettings` with UI in
  the Worktree and GitHub settings tabs; `RepositorySettings` keeps optional overrides
  and creation/merge logic falls back to the global value when the repo value is `nil`.

## Alternatives & decisions

- **Fork-first despite known upstream overlap**: the 2026-04-08 upstream review (see the
  ledger) had already spotted upstream's own merged-action picker (`4db25220`) and global
  defaults (`ce214902`) in v0.8.0, while the fork branches for #190/#192 were in flight.
  The recorded decision: merge the fork implementation now, and on the next upstream sync
  "prefer upstream's implementation where equivalent; keep fork extensions if any".
- **Fetch is best-effort**: errors append to progress output but never abort creation,
  trading strict freshness for a creation flow that works offline.
- **Delete action reuses the manual path**: automated post-merge deletion goes through
  `deleteWorktreeConfirmed` rather than a separate code path, so safety changes to manual
  deletion (amendment 003) automatically apply to it.

## Amendments

- Updated 2026-05-09/2026-06-08: browser-style worktree history navigation (#260, upstream
  port) + terminal focus after keyboard navigation (#419) — see
  [002-worktree-history-navigation.md](002-worktree-history-navigation.md)
- Updated 2026-05-30/2026-06-03: explicit + safe branch deletion (#375) and failed-cleanup
  hardening (#383) — see
  [003-safe-branch-deletion-and-cleanup.md](003-safe-branch-deletion-and-cleanup.md)
- Updated 2026-06-08/2026-06-09: Advanced placement overrides in the New Worktree dialog
  (#424, upstream port) + field labels (#427) — see
  [004-advanced-placement-overrides.md](004-advanced-placement-overrides.md)
- Updated 2026-06-28: Add to Prowl popover redesign with clone support (#520) — see
  [005-add-to-prowl-clone.md](005-add-to-prowl-clone.md)
- Updated 2026-07-12: worktree deletion now verifies Git registration removal and
  propagates cleanup failures (fork issue #454) — see
  [006-verified-worktree-deletion.md](006-verified-worktree-deletion.md)
- Updated 2026-07-16: manual branch-choice persistence and separate automatic-cleanup
  branch deletion setting — see
  [007-manual-delete-choice-and-automatic-cleanup.md](007-manual-delete-choice-and-automatic-cleanup.md)
