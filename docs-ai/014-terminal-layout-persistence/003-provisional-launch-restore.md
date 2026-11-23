# 014 — Amendment: Restore From the Cached Repository List (2026-11)

## Context

Since this entry landed, launch restore waited for the live repository load
(`snapshotPersistencePhase.hasLoadedLiveRepositories`). The live load runs `wt ls` for all
repositories in parallel and finishes with the slowest one. Usually that is under one second.
The first launch after the 2026.11.20 update took 6.1 s (`loadPersistedRepositories` →
`repositoriesLoaded`), while the layout restore itself took 0.09 s. The cached repository
list was ready 0.55 s after launch, so the window showed the sidebar and the empty
"Open Repository" detail view for about 6 s. No code change in that release caused the delay:
later launches of the same build loaded in about 1 s.

## Change

- `repositoriesChanged` in the `.restoring` phase (the cached list) sends
  `.restoreLayoutSnapshot(worktrees:isProvisional: true)`. The live load sends the final
  request, as before.
- `WorktreeTerminalManager` restores once per launch. A provisional request restores only
  when the cached list holds every saved worktree and each local worktree folder exists
  (`firstUnrestorableWorktreeID`). Otherwise it does nothing and the final request restores.
  Without this check, a worktree created after the last cache save would be skipped, and the
  next save would drop its tabs. Both requests share one disk read of the snapshot.
- `launchRestoreMode` leaves `.restoreLayout` on the final request or on `.layoutRestored` /
  `.layoutRestoreFailed`. A declined provisional request leaves it set, so the #459 save
  guard stays in force until a restore runs.
- `AppFeature.State.isRestoringLaunchLayout` keeps the detail area on `AppLoadingView`, not
  `EmptyStateView`, until the restore settles. `AppLoadingView` now starts at a random message
  and shows the messages in a shuffled order.
- `ContentView` no longer shows a full-window `AppLoadingView` until
  `isInitialLoadComplete`. That made launch a two-step change: the full-window view, then the
  split view with a second loading view and a new message. The split view now shows from
  launch. The detail area shows one `AppLoadingView` branch for both "first list not loaded"
  and "restore not settled", so the view keeps its identity and its message. The sidebar hides
  its "Repositories you add will appear here" text until the first load, and the collapsed
  repository list is not pruned on the change from no repositories.

## Verification

An isolated Debug instance (`PROWL_DEBUG_DATA_DIRECTORY`) used copies of the real repository
list, repository cache, and layout snapshot. One extra repository had a `.git/config` include
that pointed at a FIFO, so its live load took 6 s:

| Case | Layout restored | Live load done |
|---|---|---|
| Cache matches the layout | +1.71 s (provisional) | +7.58 s, no second restore, no prune |
| Cache misses a saved worktree | +7.56 s (final), all 3 worktrees restored | +7.34 s |

The repository cache rejects a snapshot whose worktree folder is gone (`pathExists`), so a
deleted folder also falls back to the final request.
