# 084.003 — One terminal worktree, ID reversals become lookups (A1)

## Context

Slice A1 of [000-plan.md](000-plan.md). A repository without worktrees of its own (a
plain folder or a workspace) is represented in the terminal system by a synthesized
`Worktree` that shares the repository's ID. Six places built that value by hand, each
with its own capability check. Some code also turned a `Repository.ID` or `Worktree.ID`
back into a path. Both patterns break when A2 gives remote repositories IDs that are not
paths, so this slice collects them first. No behaviour changes.

## Change

### `Repository.terminalWorktree`

`Repository.terminalWorktree: Worktree?` returns the root folder under the repository's
ID when the repository can run folder actions and has no worktrees, and nil otherwise.
It replaces:

| Place | Before |
| --- | --- |
| `RepositoriesFeature+StateQueries.swift` | `static plainFolderWorktree(for:)` (deleted) and its guards in `selectedTerminalWorktree`, `terminalWorktree(for:)`, `canvasNavigationWorktree(forRepositoryID:)` and the workspace-child `diffTarget(for:)` |
| `AppFeature+Support.swift` | A copy in `makeTerminalRestorableWorktrees`, and `terminalWorktree(for:repositories:)` (deleted; callers use `RepositoriesFeature.State.terminalWorktree(for:)`) |
| `WorktreeDetailView.swift` | A copy in `canvasFocusedTerminalWorktree` |
| `ProwlApp.swift` | A copy in `resolveCLITerminalWorktree` |
| `RepositoriesFeature+CoreReducer.swift` | A copy in `.openWorkspaceChild` |

The same check also decided "this repository is its own terminal target" in places that
did not build a `Worktree`. They now read `terminalWorktree` too:
`workflowRunRoots(of:)`, `ListRuntimeSnapshotBuilder` (`prowl list`),
`WorktreeDirectoryIndex` (the index and its signature), `terminalStateIDs`, and the
exact-root and inside-root branches of the `prowl open` resolver (`ProwlApp.swift`).

A workspace is always `.plain` (`Repository.init`), so the guards that now require a
terminal worktree for a workspace never fail.

### ID → path reversals

| Place | Before | After |
| --- | --- | --- |
| `cleanupFailedWorktree` (`RepositoriesFeature+WorktreeState.swift`) | `URL(fileURLWithPath: repositoryID)` | `createRandomWorktreeFailed` carries `repositoryRootURL` from the creation effect. A lookup is not enough: the repository can be removed while the creation runs, and the git cleanup still needs its root |
| `WorktreeRowsView.worktreeName(for:)` | `URL(fileURLWithPath: row.id).lastPathComponent` | `WorktreeRowModel.workingDirectory` (nil for a pending row) |
| `ShelfSpineView.headerButton` | `URL(fileURLWithPath: book.repositoryID)` | `ShelfBook.repositoryRootURL` |

### Tests

`RepositoryTerminalWorktreeTests`: a plain folder and a workspace get a terminal
worktree with the repository's ID, name, root and `isMain`; a git repository gets none.
`failedWorktreeCreationCleansUpWithCarriedRootAfterRepositoryRemoval`: with the
repository gone from the list and an ID that is not a path, the git cleanup lists,
removes and prunes against the carried root. The existing suites cover the other call
sites.

### Kept as they are

- `selectCLIWorktreeContext` (`ProwlApp.swift`) checks only `supportsRunnableFolderActions`,
  so a bare git repository ID selects the repository. `terminalWorktree` would change that.
- `resolveCLITerminalWorktree` (`ProwlApp.swift`) matches per repository (its worktrees,
  then its own ID), while `RepositoriesFeature.State.terminalWorktree(for:)` matches all
  worktrees first. Sharing one lookup would change the result when a plain folder's ID
  equals a worktree ID of a later repository.
- Capability checks that gate UI or settings (`SidebarListView`,
  `RepositorySettingsFeature`, `AppFeature`) stay for A4.

## Left for later slices

A sweep found reversals where no model is available. They need the ID codec of A2 or
the identity work of A3:

- Failed repositories have no `Repository` value:
  - `RepositoriesFeature+IconDetection.swift` (the `URL(fileURLWithPath: repositoryID)` fallbacks);
  - `WorktreeTerminalManager.swift` (`preservingRepositoryIDs` → URLs);
  - `RepositoriesFeature+RepositoryManagement.swift` (`isSameRepositoryPath(_, repositoryID)` in the failed-repository removal);
  - `SidebarPresentation.swift` (failures keyed by a root path).
- Persisted ID lists normalized as paths: pins, archived worktrees, repository order and worktree order (`RepositoryPersistenceKeys.swift`, `RepositoryPersistenceClient.swift`). A2's normalizers keep non-local IDs unchanged.
- IDs minted from paths: repository loading, snapshot restore, `orderedRepositoryIDs()`, the order prunes, `cleanupFailedWorktree`'s worktree ID, the canvas appearance lookup, the settings keys, and `WorkflowPreferenceKey`, whose `repositoryID` is a root path. These belong to A3.
