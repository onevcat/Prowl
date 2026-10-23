# 084.023 — Loading remote folders through their host (B3e)

## Context

Since B2a ([017](017-b2a-roots-by-location.md)), a remote entry in
`repository-entries.json` failed to load with "Remote folders are not available yet." After
B3b ([020](020-b3b-remote-repository-host.md)), the host can list a remote repository's
worktrees. The plan's "Remote refresh (D4)" section also covers the polling cadence, the
held connection leases and the state while a host is unreachable. That is too much for one
change, so B3 grows to six PRs:

- **B3e (this record):** repository loading through the host, and an unreachable mark on
  the load failure.
- **B3f:** the refresh cadence (the focused worktree faster than the others, with backoff
  while the host is unreachable), held leases while a remote repository is loaded,
  branch and line changes from the refresh, pull request refresh for remote folders, and
  keeping the last state through a failed poll.

## Change

No remote entry exists before C1. Exposure: none.

### Loading

`RepositoriesFeature.loadRepositoriesData` loads every entry through `RepositoryHost`, which
runs a local location on this Mac and a remote one on its host. Local and remote entries
share one path; only the location differs.

- **A git repository.** It lists its worktrees (`worktrees(in:)`, the batched refresh on a
  remote host). Its name follows `Repository.name(for:)` for both kinds of location.
- **A plain folder.** It loads without a check of its folder, as a local plain folder
  does. A remote one still needs its host to be known
  (`RepositoryHost.requireRemoteHost`), so a missing host profile or a build without a
  host connection fails it like a remote git repository. It has no workspace metadata,
  because workspaces are unavailable for remote folders (A4a).
- **A deadline.** A remote entry loads within `remoteLoadDeadline` (10 s, on the
  feature's clock). A host that does not answer then fails as unreachable ("The remote
  host did not answer in time."). One unreachable host never holds back the local
  repositories for the lane's 30 s deadline, on launch or on any reload, such as after a
  worktree creation. B3f tries the host again.
  - At the deadline, the load returns at once and only cancels the remote operation
    (`DeadlineRace`). A task group would wait for the operation to end, and some remote
    waits do not respond to cancellation: the shared read of the login `PATH` runs in a
    task of its own, with its own budget. With a task group, a 10 s deadline took 13 s in
    a reproduction.
  - A cancelled load returns at once too.
- **A failure.** It becomes a `LoadFailure` with the error's message, for example:
  - "The folder on the remote host is not a Git repository.";
  - "The remote host refused the SSH login.";
  - "The host of this remote folder is missing."
- **The prune.** The `git worktree prune` before each load runs for local git entries only.
  On a remote host it would add one connection per entry to every reload, and the refresh
  already lists a worktree whose folder is gone.
- **Without a host connection** (tests, `RemoteRepositoryHostClient.unavailable`), every
  remote entry, git or plain, still fails with "Remote folders are not available yet."

### The unreachable mark

`LoadFailure.isHostUnreachable` is set when the host did not answer: no route, a refused or
dropped connection (`RemoteProbeFailure.unreachable`), or a timeout, from either the remote
host or the refresh (`isRemoteHostUnreachable`). Other failures are not marked, because
the user must act on them or they concern the repository:
- a refused login, an unknown or changed host key, a name that does not resolve, or a
  local `ssh` that cannot start;
- a missing folder, or a folder that is not a repository.

The reducers keep the marked IDs in `State.unreachableRepositoryIDs`, next to
`gitUnavailableRepositoryIDs`, through one `recordLoadFailures` for both load paths. C1
shows the unreachable state in the sidebar; until then the failure row shows the message.

### Consent

Loading connects to every host that has a remote entry. D2 makes adding a remote folder
the consent for its host profile, and C1 adds the folder and stores that answer. No entry
exists before C1, so nothing connects without consent.

## Tests

`RemoteRepositoryHostTests`. The lane runs on this Mac, with real git:

- a remote git entry loads its worktrees through the host, with the main worktree at the
  repository's own location. A remote plain entry loads as a plain folder;
- a host that refuses the connection gives a failure marked unreachable, with the
  connection's message. A folder that is not a repository gives a failure that is not
  marked;
- a host that does not answer fails the load at the deadline, marked unreachable;
- a remote wait that ignores cancellation does not hold the load past the deadline. With
  the task-group race, this test hangs;
- only a host that does not answer, or a timeout, is unreachable: a refused login, a
  changed host key, a shell failure and a missing profile are not;
- a remote plain folder without a host connection fails to load.

`RepositoryHostTests` keeps the remote entry failure without a host connection.
