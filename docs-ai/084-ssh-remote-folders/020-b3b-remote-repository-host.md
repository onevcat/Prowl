# 084.020 — `RemoteRepositoryHost` (B3b)

## Context

A6a ([010](010-a6a-repository-host.md)) made `RepositoryHost` the place where reducers run
repository operations by location. A remote location then failed with
`RepositoryHostError.remoteUnavailable`. A5b ([009](009-a5b-git-executor.md)) gave
`GitClient` an executor so that a remote one could run its commands. It also listed the
`GitClient` methods that read the local disk, which a remote executor must not reach.

B3 is now four PRs. Worktree creation needs its own PR, because the `wt` script must be
staged on the host and the request's folders must be mapped there:

- **B3a:** the refresh ([019](019-b3a-refresh-parser.md));
- **B3b (this record):** the remote host;
- **B3c:** worktree creation on the host;
- **B3d:** the refresh cadence, the connection leases and the unreachable state.

## Change

Nothing creates a remote folder before C1, so nothing reaches this code yet. Exposure: none.

### The remote executor

`GitCommandExecutor.remote(lane:limits:)` (`GitCommandExecutor+Remote.swift`) runs `GitClient`
commands through `RemoteCommandLane`:

- **Command lines.** `GitExecutable.run` calls `/usr/bin/env NAME=value… git args`.
  `RemoteGitShell.command` turns that into a `RemoteShellCommand`, and the assignments
  become its environment, with two exceptions:
  - `PATH`: the lane sets the login `PATH`;
  - `DEVELOPER_DIR`: it names a folder on this Mac.

  `LC_ALL=C` and `LANG=C` still apply, so git's output is parsed as it is locally.
- **Exit status.**
  - A non-zero exit becomes a `ShellClientError`, as for a local process. `GitClient`
    therefore wraps it into the same `GitClientError.commandFailed`.
  - Exit 255 together with one of `ssh`'s own messages (the probe's classification)
    becomes `RemoteRepositoryHostError.connection`. Git can exit 255 too; without such a
    message it stays a git failure.
  - A timeout becomes `RemoteRepositoryHostError.timedOut`, and output cut off at the
    lane's budget becomes `outputTooLarge`. Truncated output is never parsed as complete.
  - `GitClient` rethrows a `RemoteRepositoryHostError` as it is, instead of wrapping it
    into `commandFailed`. So B3d can tell an unreachable host from a git failure. The
    local host never throws this error.
- **`git`.** The executor finds `git` once with `command -v git` on the login `PATH`, and it
  keeps the result. The two executors of a host (the normal and the long-running budget)
  share that result. When `git` is not found, the result is
  `RemoteRepositoryHostError.gitMissing`.
- **`wt`.** The executor has no `wt` script yet; B3c stages it.

### `RemoteRepositoryHost`

`RemoteRepositoryHost` (`App/Sources/Clients/Repositories/RemoteRepositoryHost.swift`) holds
the operations of one host profile. Its paths are paths on that host.

| Operation | Remote implementation |
| --- | --- |
| Worktree list | The batched refresh (B3a) |
| Prune, branch names, refs, base ref, bare check, remotes, code host and GitHub remote lookups, rename | The same `GitClient` method with the remote executor |
| Ignored and untracked counts | Counted on the host (`ls-files … \| wc -l` with `pipefail`), so a large list, such as an ignored `node_modules`, never crosses the connection or reaches the output budget |
| Branch-name check | This Mac's git, outside a repository. The rules do not depend on the repository, and a connection error must not read as an invalid name |
| Branch deletion | The local rules: not found, then protected (`main`, `master`, the default branch of `origin`), then `git branch -d/-D`. The local host ignores a failed read of the default branch; the remote host fails the deletion instead, because a dropped connection would otherwise remove the protection of the default branch |
| Fetch | The same `GitClient` method with the long-running budget (600 s) |
| Remove a worktree | Refuse a path that `git worktree list --porcelain` does not list. Then `git worktree remove --force` with the long-running budget, and delete the branch when asked. The local host moves the folder aside first; that is a fast path on this Mac, and the remote host does not need it |
| Branch name, line changes of one worktree | Nil. Only the local monitors ask for them, and they do not run for remote repositories. The refresh carries both (B3d) |
| Create a worktree | `remoteUnavailable` until B3c |

`GitClient.relativePath` (B3a) and the URL of a remote path never touch this Mac's disk:
paths become `URL(filePath:directoryHint: .notDirectory)` only so that `GitClient` can read
them back.

### `RepositoryHost` routing

- `RepositoryHost(local:remote:)` takes a `RemoteRepositoryHostClient`. The client finds the
  remote host of a host profile ID.
- For a remote location, `RepositoryHost` asks the client for the host:
  - throwing operations rethrow its error;
  - when there is no host, they throw `remoteUnavailable` as before;
  - operations without an error channel return no value.
- The client is a dependency of `RepositoriesFeature` and `RepositorySettingsFeature`.
  - `testValue` is `.unavailable`, so the existing remote-gate tests keep their behaviour.
  - `liveValue` reads the profile from `hosts.json`, and fails with
    `RepositoryHostError.hostProfileMissing` when it is not there. It builds the host on a
    lane that leases the profile's connection for each command
    (`RemoteCommandLane.leased`). It keeps one host per profile, so the resolved `git`
    lasts; an edited profile gets a new host.
  - Before each command, the leased lane resolves the recipe with `ssh -G`, as panes do.
    When the configuration now reaches another user, host name or port
    (`HostProfile.authorityChanged`), nothing runs (`RemoteRepositoryHostError.authorityChanged`):
    a removal or a branch deletion must not reach another machine. C1 asks the user to
    rebind. Options that `ssh -G` rejects give `configurationRejected`.
  - While nothing else holds a lease, each command connects again, so an operation of
    several git commands connects several times. B3d holds a lease while a remote
    repository is loaded, and then the commands share one connection.
- `RepositoryHost.removeWorktree` returns nothing now; both callers ignored the returned
  local URL.

The repository loading path still fails remote entries as B2a describes. B3d loads them
through the host, together with the refresh cadence.

### Error messages

`RemoteRepositoryRefreshError` and `RemoteRepositoryHostError` are `LocalizedError`s. A
connection failure names its kind: the login was refused, the host key is unknown or
changed, the name cannot be resolved, the host cannot be reached, or `ssh` could not
start. So the alerts that show these errors (removal, for example) tell the user what to
fix.

### Precision of creation times

The host's creation times are whole seconds (BSD `stat -f %B`, GNU `stat -c %W`). Locally,
`resourceValues` returns fractions of a second. So two worktrees created in the same
second keep git's order on a remote host, while the local host can order them by the
fraction.

## Tests

`RemoteRepositoryHostTests`:

- the command-line translation (`PATH` and `DEVELOPER_DIR` dropped, `LC_ALL` and `LANG`
  kept) and the outcome mapping (success, git failure, `ssh` exit 255, git's own exit
  255, timeout, truncated output);
- the leased lane: with a changed authority it runs nothing and holds no lease; with an
  unchanged one it runs the command and releases the lease;
- `git` resolved once, and a host without git;
- `hostProfileMissing` from the live client when `hosts.json` lacks the profile;
- against a real repository through a lane that runs `sh -s` and `bash -s` on this Mac:
  - every read gives the same result as the local `GitClient` on the same repository:
    branch names, refs, base ref, ignored count and GitHub remotes. The worktree list,
    the untracked count, the remote names, the code host URL and the branch-name check
    also run;
  - fetch, rename, remove with branch deletion, and prune change the repository;
  - a path that git does not list is not removed;
  - the default branch of `origin` and the protected names are not deleted, and when the
    connection drops while the default branch is read, nothing is deleted;
  - a dropped connection keeps its type through `GitClient`, and the branch-name check
    still works without a connection;
  - a failed git command keeps the local error shape (`GitClientError.commandFailed`);
- opt-in, against a real SSH host (`TEST_RUNNER_PROWL_REMOTE_LANE_HOST=mini`, run on
  2026-10-23): list, refs, branch-name check, remotes, GitHub remote, rename and remove on
  a repository that the test creates and deletes on the host.

`RepositoryHostTests` keeps its remote-gate tests, which now run with the `.unavailable`
client.
