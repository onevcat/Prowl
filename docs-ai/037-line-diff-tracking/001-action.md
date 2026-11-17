# 037 — Line-Diff Tracking: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-05-18 | Sidebar diff badge truncation fix: `.fixedSize(horizontal: true, vertical: false)` on the change-count view so long `+N/-M` values don't clip (community PR by Norvon) | PR #298 |
| 2026-05-28 | Event-driven line-diff refresh replaces fixed-cadence polling: opened/selected worktrees get FSEvents invalidation (30 s debounce) + 300 s safety refresh; inactive worktrees only get one-shot initial/deferred/foreground refreshes; `setOpenedWorktreeIDs` + `refreshLineChanges` watcher commands | PR #365 |
| 2026-05-30 | Per-repository "Observe line diffs automatically" and "Fetch pull request state" toggles (default on, no schema bump); reducer-level gating at the work sites | PR #377 |
| 2026-06-22 | Adaptive per-repo debounce tiers from git index entry count (1–2 s small / 2–5 s medium / 5–15 s large); untracked file lines folded into the `+N` count | PR #491, [002](002-adaptive-debounce-and-untracked-lines.md) |
| 2026-06-25 | Fix badge not refreshing for up to 5 min after commit (`deferredLineChangeIDs` gate swallowed HEAD watcher events); deterministic HEAD watcher test seam | PR #508, #511, [003](003-deferred-refresh-after-commit.md) |
| 2026-11-18 | Refresh cached local repository tiers on app foreground; retain the last known tier if the index cannot be read | #561 |

## Outcome & current state (as of 2026-07-12)

Verified against the working tree:

- `supacode/Features/Repositories/BusinessLogic/WorktreeInfoWatcherManager.swift` —
  the orchestrator. `isLineChangesActive(_:)` = selected ∪ `openedWorktreeIDs`; active
  worktrees run an `FSEventsWorktreeFileEventMonitor` plus a 300 s safety refresh
  (`lineChangesSafetyRefreshInterval`). `LineChangesTiming` nests the tier table
  (`small`/`medium`/`large`, `tier(forIndexEntryCount:)` with `<5_000` / `<20_000`
  boundaries); per-repo tiers are cached in `repositoryLineChangesTimings` keyed by
  standardized repository root, populated by `refreshRepositoryTimings(for:)` via
  `indexEntryCountProvider` (default `GitClient.indexEntryCount(at:)`).
  `scheduleFilesChanged` (HEAD path) routes through `scheduleLineChangesRefresh` so
  `emitLineChangesChanged` clears `deferredLineChangeIDs` before emitting (the #508 fix,
  documented in an inline comment). Event debouncing uses `KeyedDebouncer` from
  `supacode/Support/Debouncer.swift` (extracted in #537, see
  [003-diff-window](../003-diff-window/003-render-pipeline-hardening.md)).
- `supacode/Clients/Git/GitClient.swift` — `lineChanges(at:)` runs
  `git diff HEAD --shortstat` and `git ls-files --others --exclude-standard -z`
  (with `core.quotePath=false`) concurrently via `async let`, adds
  `countLinesInFiles(_:relativeTo:)` output to the tracked `added` count, and skips
  entirely while the index is locked (`isWorktreeIndexLocked`, an upstream-era guard).
  `indexEntryCount(at:)` reads the 12-byte index header, validating the `DIRC` magic and
  version 2–4 before decoding the big-endian entry count. `countLines(in:)` streams in
  64 KB chunks, treats a NUL in the first 8 KB as binary (skip), and counts trailing
  unterminated lines.
- `supacode/Features/Settings/Models/RepositorySettings.swift` — optional overrides
  `observeLineDiffsAutomatically` / `fetchPullRequestState` with resolved accessors
  `observesLineDiffsAutomatically` / `fetchesPullRequestState` (default `true`).
- Gating sites: `.filesChanged` handler in
  `supacode/Features/Repositories/Reducer/RepositoriesFeature+CoreReducer.swift` guards
  on `observesLineDiffsAutomatically` before calling `gitClient.lineChanges`; the PR
  counterpart guards in `supacode/Features/Repositories/Reducer/RepositoriesFeature+GithubIntegration.swift`.
- `supacode/Features/Settings/Views/RepositorySettingsView.swift` — both toggles live in
  the "Diffs & Pull Requests" section.
- `supacode/Features/Repositories/Views/WorktreeRow.swift` —
  `WorktreeRowChangeCountView` renders the badge with the #298 `.fixedSize` fix in place.
- `supacode/Features/Repositories/BusinessLogic/WorktreeInfoMonitors.swift` — the #511
  seam: `WorktreeHeadEventMonitoring` protocol with the production
  `DispatchSourceWorktreeHeadEventMonitor`, alongside `WorktreeFileEventMonitoring`.
- Tests: `supacodeTests/WorktreeInfoWatcherManagerTests.swift` (activity gating,
  staggered deferred refresh, tier selection, HEAD-watcher-vs-deferred regression),
  `supacodeTests/GitClientLineChangesTests.swift` (untracked lines, binary skip, index
  header), `supacodeTests/RepositorySettingsKeyTests.swift` and
  `supacodeTests/RepositoriesFeatureTests.swift` (toggle defaults and gating).

## Deviations from plan

- The 2026-06-22 plan sketched a free function `lineChangesTimingTier(forFileCount:)`
  returning a `LineChangesTimingTier` struct; implemented instead as
  `LineChangesTiming.tier(forIndexEntryCount:)` nested in the watcher manager. Interval
  values match the plan exactly.
- The plan's `indexEntryCount` sketch read the count without validation; the
  implementation additionally checks the `DIRC` signature and index version 2–4.
- The initial implementation populated only missing roots on `setWorktrees`, so
  existing roots kept a stale tier after index growth or shrinkage. The #561 fix
  rereads each current local root once on app-foreground `refreshLineChanges`.
  Ordinary `setWorktrees` calls still reuse cached tiers and drop obsolete roots;
  an unreadable index retains the last known tier, or the default if none was read.
