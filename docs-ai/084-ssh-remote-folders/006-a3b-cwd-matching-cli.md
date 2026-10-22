# 084.006 — Terminal cwd and cwd matching (A3b); A3 re-cut

## Context

Slice A3 of [000-plan.md](000-plan.md), part b. A3a (#958) covered identity and settings
keys. A sweep of the code after A3a found 164 reads of the local forwards
(`Repository.rootURL`, `Worktree.workingDirectory`, `Worktree.repositoryRootURL`):

- 9 in terminal cwd and environment;
- 12 in cwd matching;
- 6 in the CLI;
- 137 that read git state or files, or feed settings and UI.

## Decision: A3 has two PRs; the forwards go at the end of A6

The plan moved every category in A3 and then deleted the forwards. The host boundary
(A5–A6) comes after A3, so each git or file read would have been rewritten twice: first
to an explicit local unwrap in A3, then to a host operation in A5 or A6.

Instead, A3 ends with this PR. Git reads move off the forwards in A5 and repository
state reads move off them in A6, which then deletes the forwards. Until then, no code
path can reach a forward with a remote value, because remote repositories are only
created in C1, behind `PROWL_REMOTE_FOLDERS`. The slice table is amended. Decided
2026-10-23 in unattended mode.

## Change

### cwd matching

- `WorktreeDirectoryIndex` (the index and the cache signature) walks only worktrees
  with a `localURL` (`forEachLocalDirectory(of:_:)`, no intermediate arrays on the
  sidebar hot path). A local directory never matches a worktree on another host, even
  when the paths are equal.
- The `prowl open` resolver (`ProwlApp.resolveOpenPath`) skips repositories without a
  `localURL` and reads only local URLs.
- Canvas cards look up the appearance and the custom title by
  `WorktreeTerminalState.repositoryID` (`worktree.repositoryLocation.id`). The name
  fallback uses `Repository.name(for: RepositoryLocation)`. Before, the lookup used
  `PathPolicy.normalizePath(…, resolvingSymlinks: true)`, which resolves `/tmp` to
  `/private/tmp`. Live repository IDs keep the path as added, so a repository under a
  symlinked path never got its title or colour on Canvas. **Behaviour fix.** It stays
  partial for a terminal state that was created from the snapshot cache, whose restore
  mints symlink-resolved IDs, until B2 aligns the snapshot IDs.
- The terminal prune compares repository IDs without trailing slashes instead of URLs.
  This works for remote IDs too, so a remote repository whose load fails keeps its
  terminals, as P0 requires. It also fixes a local case: the failed ID is built from
  the entry path without a trailing slash, the state's root has one while the
  directory exists, and so the old URL comparison closed those sessions. **Behaviour
  fix.**
- The same-repository filter of branch-name suggestions compares
  `worktree.repositoryLocalURL`, which equals the old value for local worktrees.

### Terminal cwd

- Surface creation, the agent working directory fallback and the layout restore fall
  back to `worktree.localURL`. Each one already accepts a missing directory.
  `WorktreeTerminalState.init` still reads the repository settings through a forward,
  so a state for a remote worktree cannot exist yet (C3).

### Left on the forwards, with the owner

| Read | Owner |
| --- | --- |
| `prowl list` contexts and `--worktree` path matching; Mirror pane directory (`GhosttyMirrorPaneSource`) | C2. These need the `host` field: with a remote path but no host, a local path could match a worktree on another host |
| `Worktree.scriptEnvironment` (`PROWL_WORKTREE_PATH`, `PROWL_ROOT_PATH`) | C3. Local surfaces and scripts read it, so remote paths must reach only remote-executed scripts |
| `WorktreeTerminalState.init` repository settings, setup-script settings, Profile launch cwd | C3 (remote terminals); A4 refuses Profile launch for remote targets |
| Sidebar "new tab" directory (`.createTabInDirectory`), archive script cwd | C3 (remote tabs), A4 (archive script capability) |
| Workflow run path and repo scope (`WorkflowRunAdmission`, `WorkflowRuntimeComposition`) | C2 (workflow `rootKey`) |
| `orderedRepositoryRoots` fallback, `repositoryRoots` as URLs, snapshot IDs | B2 (remote entries, snapshot v3) |
| Canvas card icon root, other UI and settings reads, git and file reads | A4–A6 |

### Tests

- `WorktreeDirectoryIndexTests.remoteWorktreesAreNotMatchedByLocalDirectories`: remote
  git and plain repositories are skipped by the index and by the cache. Local matching
  still works. With the old code, this test trapped.
- `WorktreeTerminalStateRepositoryIDTests`: the terminal state's repository ID equals
  `Repository.id` and keeps a `/tmp` path unresolved.
- `WorktreeTerminalManagerTests.prunePreservesFailedRepositorySessionsWhenOnlyATrailingSlashDiffers`.
  It was red before the fix.
- `RepositoryLocationTests.repositoryNameComesFromTheLocationPath`.
