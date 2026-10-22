# 084.002 — Load failures keep worktree membership (P0)

## Context

Slice P0 of [000-plan.md](000-plan.md), decision D8. When one repository failed to load,
`applyRepositories` still removed every pinned worktree ID and every
`prowlCreatedWorktreeIDs` entry that was not in the loaded list. Only archived worktrees
had a guard (`shouldPruneArchivedWorktrees: failures.isEmpty`). A repository that is
unavailable for a moment (git error, `git` not on `PATH`, later an unreachable host) lost
its pins and its "created by Prowl" marks for good. Remote folders make this a normal
state, so the guard comes first.

## Change

`applyRepositories(…, origin:)` takes a `RepositoryListOrigin` in place of
`shouldPruneArchivedWorktrees`. `removedWorktreeIDFilter` turns the origin into the test
that pins, archived worktrees and Prowl-created marks use:

| Origin | Worktree IDs that are removed |
| --- | --- |
| `.live(failedRootIDs: [])` | Every ID that is not in the loaded list (as before) |
| `.live(failedRootIDs:)`, not empty | Only IDs that the previous `state.repositories` listed under a repository that is not a failed root, and that the new list does not have: a worktree that left a loaded repository, or the worktrees of a removed repository |
| `.snapshot` | None. The repository order and worktree order prunes are also skipped |

A pin on a main worktree or an archived worktree is still removed on every load.

| Files | What |
| --- | --- |
| `RepositoriesFeature.swift` | `RepositoryListOrigin` |
| `RepositoriesFeature+RepositoryLoading.swift` | `origin:` parameter, `removedWorktreeIDFilter` |
| `RepositoriesFeature+Selection.swift` | `prunePinnedWorktreeIDs`, `pruneArchivedWorktrees` and the new `pruneProwlCreatedWorktreeIDs` take `where isRemoved:` |
| `RepositoriesFeature+CoreReducer.swift`, `+RepositoryManagement.swift` | `repositoriesLoaded` and `openRepositoriesFinished` pass `.live` with the failed roots; `repositorySnapshotLoaded` passes `.snapshot` |

### Tests

Added to `RepositoriesFeatureTests`: during a partial load, pins and Prowl-created marks of
an unknown worktree survive (no pin save), main and archived pins are still removed, a
worktree that left a loaded repository is pruned from all three, and the worktrees of a
removed repository are pruned; a complete load still prunes unavailable IDs;
`openRepositoriesFinished` with a failure keeps the marks; snapshot restore keeps pins,
archived worktrees, marks, repository order and worktree order that the snapshot does not
contain.

## Deviations from the plan

- The snapshot restore path prunes nothing. The snapshot is saved only after a load
  without failures, so while a repository fails, the snapshot can miss a repository or a
  worktree that was added later. Before this change, the next launch pruned their pins,
  marks, archived entries and order against the old snapshot (in memory; the next save
  wrote it). The live load that follows the snapshot does the pruning now. Decided
  2026-10-22.
- A partial load prunes by attribution, not "nothing at all". A global "no failures"
  gate (the first version, as for archived worktrees before) kept a stale mark for as
  long as any root failed. A stale Prowl-created mark lets archive cleanup delete the
  branch of a worktree that the user made again by hand at the same path. Found in the
  self-review.

## Result

A pin, archived entry or Prowl-created mark of a worktree that Prowl cannot attribute to
a loaded repository stays until a load without failures. One limit remains: a worktree
that was deleted outside Prowl while Prowl was not running keeps its entries until a load
without failures when the launch restored no snapshot (today the cache drops the whole
snapshot when one path is missing; B2 makes that per entry). The sidebar ignores pinned IDs
without a worktree.
