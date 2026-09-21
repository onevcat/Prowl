# 071 — Git Environment Recovery: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-09-20 | Reproduced loss of worktree rows and blocked Shelf with an invalid developer directory. | #823 |
| 2026-09-20 | Added working Git selection, typed discovery failures, recovery controls, and plain-folder Shelf entry. | `fix/git-discovery-toolchain` |
| 2026-09-20 | Verified the built GUI with failed Apple Git, independent Git, restored access, and plain folders. | Validation below |
| 2026-09-21 | Hardened filesystem-boundary classification and shared Git discovery timeout/cancellation. | PR #824 follow-up |
| 2026-09-21 | Closed retained terminal states when a failed repository is removed. | Failed-root removal regression |

## Outcome & current state (as of 2026-09-21)

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
  Removing a failed root explicitly emits the repositories-changed delegate, since
  that root is already absent from the loaded models. Cleanup does not wait for a
  reload to change those models.
- Shelf accepts plain folders and can open their first terminal. Stale selection
  candidates do not prevent fallback to a valid folder.
- Direct Git discovery also accepts the two-line filesystem-boundary diagnostic.
  Exit-code and metadata checks still apply; additional error output is rejected.
- Executable and login-shell probes use `ShellClient.probe`, backed by the existing
  `WorkflowScriptExecutor`. Each probe has a five-second deadline and 64 KiB output
  limits. Timeout or cancellation terminates the process group, including children
  that ignore SIGTERM. Normal Git commands and mutations keep their existing runner.
- Shared discovery tracks each waiter. Cancellation releases only that waiter;
  the last cancellation stops discovery. A generation ID prevents a late cancelled
  probe from clearing a new discovery or its cache.

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

### PR #824 follow-up validation

- Added regression tests before implementation. The filesystem-boundary and
  cancelled-waiter tests both failed on the original code, then passed after the fix.
- 501 related Git, repository, terminal, Shelf, shell, handoff, workflow, and diff
  tests passed. Three real process-cancellation tests passed in a separate batch;
  both xcresult counts were checked explicitly. The new cancellation test joins
  the existing isolated batch in `make test-app` because bulk main-actor tests can
  delay the test's cancellation request beyond its real process deadline.
- Real process fixtures verified timeout fallback, retry after timeout, and cleanup
  of a probe and child that ignore SIGTERM. Controlled-clock tests verified waiter
  cancellation isolation and cancellation of discovery when no waiters remain.
  An explicit completion gate verified that a late cancelled probe cannot clear
  the cache populated by Retry.
- A standalone harness using the current classification function and real Apple Git
  accepted the filesystem-boundary results at `/nix` and `/Volumes/Recovery`.
- `make check` passed, including 208 script tests. `make build-app` passed with zero
  warnings and errors. The earlier GUI scenarios were not repeated for this
  client-layer follow-up.

### Failed-root removal regression

- Reproduced the leak through `TestStore`, `AppFeature`, and a real
  `WorktreeTerminalManager`: load failure preserves a terminal state, then the
  normal failed-repository removal action leaves that state behind. Both cases
  failed before the fix: removing the last root, and removing one root alongside
  healthy and still-failed repositories.
- After the explicit delegate was added, the same tests passed. They verify that
  the removed state is gone, its persisted entry is removed, and other terminal
  states retain their identity. No direct test call to `prune` bypasses the action.
- 337 related app, repository, terminal, Shelf, and sidebar tests passed.
  `make check` passed, including 208 script tests; `make build-app` passed without
  warnings or errors. This reproduction checks terminal ownership state, not GUI
  interaction or live shell PIDs.

## Deviations from plan

Final inspection found that the existing failed-load path pruned running terminals.
A narrow ownership-based pruning exception was added and verified first with a
failing test, then in the GUI. No repository snapshot or recovery state was added.

## Open questions

The reporter's original environment is unavailable. The reproduction establishes
the failure mechanism but does not prove which toolchain update resolved their case.
