# 071 — Git Environment Recovery: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-09-20 | Reproduced loss of worktree rows and blocked Shelf with an invalid developer directory. | #823 |
| 2026-09-20 | Added working Git selection, typed discovery failures, recovery controls, and plain-folder Shelf entry. | `fix/git-discovery-toolchain` |
| 2026-09-20 | Verified the built GUI with failed Apple Git, independent Git, restored access, and plain folders. | Validation below |

## Outcome & current state (as of 2026-09-20)

- `supacode/Clients/Git/GitExecutableResolver.swift` selects a working executable
  from process PATH, login PATH, or common locations. It caches successful selection,
  shares concurrent discovery, and revalidates for repository discovery. App-owned
  Git calls and bundled `wt` receive the selected executable's PATH. User terminal
  commands and arbitrary workflow scripts keep their existing environment policy.
- `GitClient.repoRoot` probes Git directly before `wt`. Only a confirmed native
  non-repository result without existing or inaccessible ancestor metadata can
  classify a folder as plain. Symlink paths are checked against physical ancestors.
- Repository loading preserves persisted kind on unknown failures. The existing
  failed row distinguishes unavailable Git from repository access errors and offers
  Retry and copyable details. It does not retain stale worktree models.
- `WorktreeTerminalManager.prune` preserves live sessions belonging to failed roots.
  Recovery exposes those sessions again; actual removal still uses normal pruning.
- Shelf accepts plain folders and can open their first terminal. Stale selection
  candidates do not prevent fallback to a valid folder.

## Validation

- Affected Git, repository, Shelf, workflow, handoff, and diff suites: 469 tests
  passed. The later terminal-preservation change passed 21 focused tests.
- `make check` passed, including 208 script tests, formatting, lint, workflow naming,
  and localization checks. `make build-app` passed without warnings or errors.
- Isolated GUI on macOS 27: main repository plus linked worktree, real Apple Git,
  process PATH restricted to system directories, and a controlled login PATH.
  Removing the disposable DEVELOPER_DIR symlink produced "Git is unavailable" with
  recovery guidance, Retry, and Copy Details. Persisted kind remained `git`.
- Restoring that symlink and clicking Retry restored branch rows. Selecting the
  worktree reopened Shelf with the same shell PID (`71782`) and terminal contents.
  Removing metadata read permissions instead produced "Unable to read repository";
  restoring permissions and retrying recovered it without reclassification.
- A separate GUI instance started with the same invalid developer path and a login
  PATH containing Nix Git 2.51.2. Apple Git still failed, but both worktree rows and
  Shelf worked. A plain-folder-only instance also entered Shelf directly while Git
  was unavailable, creating the folder's first terminal.
- Local screenshots and fixture data: `/tmp/prowl-823-fixed/`. Controlled shell
  fixtures only supplied login PATH; Git and `wt` were real executables. No system
  developer path was changed. Recovery claims above refer to explicit Retry.

## Deviations from plan

Final inspection found that the existing failed-load path pruned running terminals.
A narrow ownership-based pruning exception was added and verified first with a
failing test, then in the GUI. No repository snapshot or recovery state was added.

## Open questions

The reporter's original environment is unavailable. The reproduction establishes
the failure mechanism but does not prove which toolchain update resolved their case.
