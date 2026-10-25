# 084.009 — `GitClient(executor:)` (A5b)

## Context

The G3 row of [000-plan.md](000-plan.md) found two problems:

- `GitClient` took a `ShellClient` that defaulted to `.live`.
- Every `GitClientDependency.liveValue` closure built a default instance, and four
  ad-hoc `GitClient()` instances sat in the diff code.

Before a repository on another host can run git, the client needs one explicit place
that says what runs the commands.

## Change

- **The executor.** `GitCommandExecutor` (`App/Sources/Clients/Git/GitCommandExecutor.swift`)
  bundles the three things `GitClient` runs its commands with:
  - the shell;
  - the `git` resolver;
  - the location of the bundled `wt` script.

  `GitCommandExecutor.local` is the current local setup. A remote executor (B3) will
  supply a shell that runs over the host's command lane, the remote `git`, and the
  staged `wt` script. That covers only the command lines; see "Local-only `GitClient`
  paths" below.
- **The client.**
  - `GitClient.init(executor:)` is the designated initializer.
  - `GitClient.local` is the shared local client.
  - `init(shell:resolveGit:)` stays for tests and takes the rest from
    `GitCommandExecutor.local`. It has no default shell, and `GitExecutable.run` no
    longer defaults its shell to `.live`. A call that leaves out the shell does not
    compile, so it cannot bypass the executor by accident.
- **Callers.** `GitClientDependency.liveValue` (25 closures),
  `OutgoingChangesClient`, `ExternalDiffSnapshotClient` and `DiffWindowState` (×2) use
  `GitClient.local` instead of building a client per call.

Every command line, environment and error text is unchanged. The executor returns the
same `GitExecutable` and the same shell as before.

### Tests

- `GitCommandExecutorTests`: a client built from a custom executor runs `git` and `wt`
  from the executor, with its `PATH`, and asks it to revalidate `git` exactly as before.
  The local executor finds the bundled script.
- The existing git suites cover the local behaviour.

## Local-only `GitClient` paths

The executor covers the commands that `GitClient` runs. Several methods also read or
change the local disk directly. These are the local fast paths that the plan keeps
behind the host boundary (A6). A remote executor must not be plugged into them:

| Method | Local access |
| --- | --- |
| `removeWorktree` | Checks `.git` with `FileManager`, moves the folder aside, then deletes it in the background |
| `branchName` | Reads `HEAD` with `String(contentsOf:)` and `GitWorktreeHeadResolver` |
| `isWorktreeIndexLocked`, `indexEntryCount` | Read `index.lock` and the index header |
| `lineChanges` (untracked lines) | `resourceValues` and `FileHandle` on untracked files |
| Worktree creation times | `resourceValues` |
| `repoRoot` after a failure (`isConfirmedNonRepository`) | Walks the parent folders with `FileManager` |
| `GitExecutable.environment` | `DEVELOPER_DIR` from the local process |

For a remote repository, B3's `RemoteRepositoryHost` gives these operations their own
remote implementations, through the batched refresh and host operations. It does not
call these `GitClient` methods with a remote executor. With a remote path that also
exists on this Mac (the same home directory, for example), `removeWorktree` would act
on the local folder.

## Not routed, with the reason

These still run local processes outside `GitClient`. Each one is either local by
construction or behind a capability that refuses remote targets:

| Code | Why it stays local |
| --- | --- |
| Clone (`CloneRepositoryView`) | The destination is a local folder; there is no repository-scoped clone yet |
| Workspace git runner (`workspaceGitRunner`) | Workspaces refuse remote folders (A4a) |
| `HandoffStore`, `WorktreeBranchReader` (`WorkflowRuntimeComposition`), `WorkflowNativeActions` | Workflows refuse remote source worktrees at admission (A4a); C2 owns workflow roots |
| Diff code (`OutgoingChangesClient`, `ExternalDiffSnapshotClient`, `DiffWindowState`) | Uses `GitClient.local` directly, not the dependency, because the dependency has no diff operations. Diffs are unavailable for remote folders (A4a). If remote diffs ever become available, these sites move to host operations |

A5c moves the git reads off the local forwards. It gives `GitClientDependency`
location-based operations, so a remote repository can reach a remote executor.
