# 034 — Worktree Watcher Correctness: Plan

| | |
| --- | --- |
| **Status** | Implemented (retrospective) |
| **Anchor date** | 2026-05-25 |
| **Documented** | 2026-07-12 (backfilled) |
| **Primary PRs** | #346, #373, #406, #528, #553, #555 |
| **Sources** | PR #346/#373/#406/#528/#553/#555 descriptions, fork issue #526, Sentry issue `PROWL-MACOS-D6` (via PR #528) |
| **Related** | [010-plain-folder-support](../010-plain-folder-support/000-plan.md), [019-worktree-creation-and-lifecycle](../019-worktree-creation-and-lifecycle/000-plan.md), `docs/components/repositories-and-worktrees.md` |

## Background

Worktree discovery and watching depend on several path sources agreeing on identity:
`wt ls --json` (discovery), `git worktree list --porcelain` (the removal guard),
persisted repository entries, and file-system monitors keyed by URL. Prowl normalizes
paths with `standardizedFileURL`, but the sources report different forms — macOS
`/private` symlink prefixes, user-created symlinks, duplicate enumeration of the same
directory — and refresh was originally driven only by app launch, scene activation, and
a 30/60-second periodic timer.

The resulting symptoms, collected in this entry as one correctness arc:

- duplicate worktree rows in the sidebar (#346);
- worktree changes made outside Prowl (CLI, other tools) invisible until the next
  periodic refresh (#373);
- externally-created worktrees under symlinked roots like `/tmp` impossible to delete —
  the row disappeared briefly and reappeared, the directory never removed (#406);
- a Sentry-reported trap when duplicate `Worktree.ID` values reached the watcher (#528);
- `git init` inside a plain folder not upgrading the sidebar entry (#548/#553, owned by
  entry 010);
- a repository added through a symbolic link loading no branch/worktree info at all
  (fork issue #526 → #555).

## Goals

- Discovery never yields two `Worktree` values with the same identity, and downstream
  collection construction is defensive rather than trapping.
- The sidebar reflects git worktree registry changes made outside Prowl without waiting
  for the periodic refresh.
- Every comparison between a Prowl-tracked path and a git-reported path canonicalizes
  both sides through the same transform.
- The watcher layer tolerates inconsistent input (duplicate IDs, unavailable roots)
  instead of trapping or silently skipping work.
- Repositories added through symlinked paths resolve to a single canonical identity.

### Non-goals

- Replacing the discovery pipeline (`wt ls --json`) or the reload-everything refresh
  model; fixes are targeted at identity and event-delivery correctness.

## Design / Approach

The anchor wave (May 2026) established the two mechanisms the later fixes build on;
each later wave is a focused amendment.

**Discovery dedup (#346).** `GitClient.worktrees(for:)` deduplicates entries by their
standardized path (`Worktree.ID` is the standardized path string) with a first-wins
`seenWorktreeIDs` set, since `wt ls --json` can enumerate the same directory more than
once after path standardization. Defensively, the `IdentifiedArray` construction sites
at repository load and snapshot restore use `uniquingIDsWith: { current, _ in current }`
instead of the trapping `uniqueElements:` initializer.

**Registry-driven refresh (#373).** A new `GitWorktreeRegistryMonitor` (DispatchSource
file-system-object sources, not FSEvents) watches the repository's git common directory
and its `worktrees/` registry subdirectory, resolving `.git`-file `gitdir:` and
`commondir` indirection so linked worktree checkouts map to the right registry. Events
are debounced per repository root (2 s `KeyedDebouncer`) into a
`.repositoryWorktreesChanged` watcher event, which the reducer turns into the existing
`reloadRepositories(animated: true)` path — no separate incremental-update path. The
same PR also sends the current scene phase when `ContentView` first appears, so the
active refresh loop starts even when no phase transition ever fires.

**Later waves** (see Amendments): canonicalizing the worktree-removal guard for
`/private`-style symlinks (#406), hardening `setWorktrees` against duplicate IDs plus a
repo-wide lint ban on `Dictionary(uniqueKeysWithValues:)` (#528), plain-root upgrade
watchers (#553, detailed in
[010's amendment](../010-plain-folder-support/002-plain-upgrade-watchers.md)), and
migrating symlinked repository roots to the Git-reported canonical root (#555).

## Alternatives & decisions

- **Canonicalize at comparison boundaries, not in storage (#406).** Stored worktree
  paths remain `standardizedFileURL`; only the removal guard maps
  `git worktree list --porcelain` output through the same
  `GitClient.canonicalWorktreePath(_:)` transform before comparing.
- **Two canonicalization strengths deliberately coexist.** Worktree-path matching uses
  `standardizedFileURL` (resolves `/private`-style prefixes), while repository-root
  identity (#555) uses the stronger `resolvingSymlinksInPath()` — and instead of
  comparing loosely on every load, #555 migrates the persisted entry to the Git-reported
  root once, so branch and worktree loading use one identity afterwards.
- **Preserve nested-folder behavior (#555).** Only paths that resolve to the same
  file-system location as the Git root are migrated; a folder nested inside another
  repository still classifies as `.plain` (entry 010's conservative upgrade rule).
- **Ban the crash class, not just the call site (#528).** Rather than patching one
  `Dictionary(uniqueKeysWithValues:)` call, a custom SwiftLint rule
  (`dictionary_unique_keys_with_values`, severity error) bans the initializer repo-wide
  and all existing call sites were converted to explicit duplicate handling. Upstream
  fixed the same crash independently (upstream #517, 2026-06-29), but the fork's
  `2026.6.27` release predated that commit, so the fork shipped its own fix.
- **Event-driven refresh reuses the reload path (#373).** Registry events funnel into
  the existing repository reload rather than a bespoke diffing path — simpler, at the
  cost of full reloads on registry churn (bounded by the debounce).

## Amendments

- Updated 2026-07-12: the symlinked-roots series — worktree deletion under `/private`
  symlinks (#406, 2026-06-07) and symlinked repository root resolution (#555,
  2026-07-12) — see [002-symlinked-roots.md](002-symlinked-roots.md)
- Updated 2026-06-30: duplicate worktree watcher crash (#528) — see
  [003-duplicate-watcher-crash.md](003-duplicate-watcher-crash.md)
- Updated 2026-09-18: per-entry registry monitoring and vnode identity checks after
  file replacement — see [004-registry-vnode-lifecycle.md](004-registry-vnode-lifecycle.md)
