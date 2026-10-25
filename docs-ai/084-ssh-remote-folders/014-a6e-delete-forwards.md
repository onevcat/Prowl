# 084.014 — Delete the local forwards (A6e)

## Context

A2 added three computed forwards so that call sites could move to `RepositoryLocation`
one slice at a time:

- `Repository.rootURL`
- `Worktree.workingDirectory`
- `Worktree.repositoryRootURL`

Each one traps for a remote value. A3–A6d moved the git, settings, watcher and
pull request reads. This slice moves the rest and deletes the forwards, as the A3 re-cut
planned ([006](006-a3b-cwd-matching-cli.md)). The compiler listed 82 source reads and
about 190 test reads.

## Rule per call site

| Kind of read | Replacement | Remote behaviour now |
| --- | --- | --- |
| Local work: Finder, open in an app, diff target, archive script, terminal cwd, Profile launch, workflows, icon detection, workspaces | `localURL` / `repositoryLocalURL`, unwrapped at the start of the path | The path stops. Most are already refused by A4a; the others are listed below |
| Display and Copy Path | `RepositoryLocation.displayPath` (`URL.path` for local, without a trailing slash; the host path for remote) | The path on the host |
| Identity and comparison | `location` / `repositoryLocation` | Compared by location |
| Lists of repository roots (`orderedRepositoryRoots`, sidebar roots, snapshot roots, prune roots) | `compactMap(\.localURL)` | Not listed until remote entries join the roots (B2) |

Local repositories read the same values as before. For a local location,
`location.path` is `url.path(percentEncoded: false)` and `location.id` is the same
string, so display text, script environment values, CLI paths and workflow scope keys
are unchanged.

## Remote behaviour that this slice makes explicit

Before, each of these trapped on a forward. Remote folders can only exist after C1.

| Path | Now | Owner of the real behaviour |
| --- | --- | --- |
| Worktree creation (random and prompted) | Alert with the reason of the new `RepositoryFeature.worktreeCreation` | B3 and later |
| New terminal tab from the sidebar | Toast with the reason of the new `RepositoryFeature.terminalTab` | C3 |
| Profile launch context (`freezeAgentProfileLaunchContext`) | `AgentProfileLaunchError.unavailable` (the A4a backstop already refuses before) | 082 L1f |
| Archive script | The archive goes on without the script (as A4a) | — |
| Finder and Reveal in Finder in the sidebar menus | The item is hidden | A4b with C1 |
| CLI worktree contexts (`ListRuntimeSnapshotBuilder.orderedWorktreeContexts`) | Remote repositories are skipped, so a local path never matches a worktree on another host. These contexts also feed target resolution (`prowl send/focus --pane`), `prowl agents` and the mirror command service, so remote panes cannot be addressed from the CLI either | C2 adds the `host` field and must include remote worktrees again, including targeting by pane or tab ID. Remote panes exist only after C3 |
| Mirror pane directory | The path on the host | C2 |
| Snapshot cache (version 2) | Remote repositories are not saved. The snapshot load must then leave the state of the missing repositories alone: P0 (#954) makes the snapshot path prune nothing, and it lands before remote folders exist | B2 (version 3) |
| `DiffTarget(worktree:)` | Failable; nil for a remote worktree | Diff stays local (A4a) |
| `Worktree.scriptEnvironment` | `PROWL_WORKTREE_PATH` / `PROWL_ROOT_PATH` hold the path on the host | C3 (scripts run on the host) |
| `GitClient.removeWorktree` | Throws `RepositoryHostError.remoteUnavailable` for a non-local worktree (`RepositoryHost` already routes by location) | B3 |

`WorktreeRowModel.workingDirectory` becomes `folderName`, read from `location.path`, so a
remote worktree row gets its folder name like a local one.

After a worktree removal or archive, the reload runs when any repository is open. Before,
it checked the local roots, which skipped the reload when every repository was remote.

Models that carried a root URL for imported icons now carry an optional local URL:

- `SidebarRepositoryContainerModel.rootURL`;
- `ShelfBook.repositoryRootURL`;
- `ShelfSpineHeader.repositoryRootURL`;
- `WorktreeTerminalState.repositoryLocalURL` (renamed from `repositoryRootURL`).

## Tests

- The test fixtures are local. Their forward reads became `localURL!`,
  `repositoryLocalURL!` or `location`, without other changes.
- `DiffTarget(worktree:)` is unwrapped where a test builds one.
- `RepositoryHostTests`:
  - creating a worktree in a remote repository shows the `worktreeCreation` reason;
  - a new terminal tab in a remote worktree shows a toast and sends no terminal command.
- `RepositoryFeatureAvailabilityTests` covers the two new features through
  `RepositoryFeature.allCases`.
- The remote behaviour above keeps the A4a, A6a–A6d tests. Each remote test fixture now
  reaches these paths without a trap.
