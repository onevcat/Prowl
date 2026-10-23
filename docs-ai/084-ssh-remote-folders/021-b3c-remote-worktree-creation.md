# 084.021 — Worktree creation on the host (B3c)

## Context

[020](020-b3b-remote-repository-host.md) left worktree creation for a remote repository
unavailable. To create one on the host, the bundled `wt` script must run there. The request's
folders must also be paths on the host.

The creation flow in the reducer is built on local URLs: the base directory, the existence
check of the destination, and the cleanup after a failure. Moving it is its own change, so
B3 grows to five PRs:

- **B3a:** the refresh ([019](019-b3a-refresh-parser.md));
- **B3b:** the remote host ([020](020-b3b-remote-repository-host.md));
- **B3c (this record):** worktree creation on the host, behind `RepositoryHost`;
- **B3d:** the creation flow in the reducer by location: placement of remote worktrees,
  the destination check, cleanup after a failure, the prompt preview, and the end of the
  `worktreeCreation` gate for remote folders;
- **B3e:** the refresh cadence, loading through the host, held leases and the unreachable
  state. This is the work that 019 and 020 call B3c and B3d.

## Change

The reducer still refuses to create worktrees in remote folders, and no remote folder exists
before C1. Exposure: none.

### Running `wt` on the host

`RemoteRepositoryHost.createWorktreeStream(_:in:)`:

- **The script.** It sends the bundled `wt` script as a `RemoteScript` through the lane's new
  `stream` (`bash -s`, lines as they arrive):
  - `wt` becomes the body of a shell function, so that the script can read its standard
    output;
  - the script exports git's C locale (`LC_ALL`, `LANG`, `LC_MESSAGES`), as `GitClient`
    does locally;
  - it prints the output marker, runs the function, and prints `wt`'s standard output;
  - it then prints two records: the repository's physical path (`PROWL_ROOT`), and the
    new worktree's path, which is the last line of `wt`'s output, resolved with `pwd -P`
    (`PROWL_PATH`). The path is resolved in the same command, so no second command runs
    after `wt` succeeded: a dropped connection at that point cannot report a worktree
    that exists as a failure.
- **Budget.** `RemoteCommandLimits.worktreeCreation` gives one hour and 16 MiB of error
  output. Copying a large ignored tree can take long, and `wt --verbose` prints a line for
  each copied entry. The local creation has no limits. Without any deadline, a hung
  command would never end.
- **Arguments.** They are the same as on this Mac: `GitClient.createWorktreeArguments`,
  now internal and static. The working directory is the repository.
- **Output.**
  - Standard output before the marker is shell startup output, and it is dropped.
  - Every other line is a progress line, as from the local stream. The `PROWL_ROOT` and
    `PROWL_PATH` records are not progress.
  - The worktree's ID is its physical path, which is the path that git lists. The refresh
    then finds it under the same ID.
  - The detail is relative to the repository's physical path. It is built as text
    (`RemotePaths.relativePath`), because this Mac's rules, such as `standardizedFileURL`
    dropping `/private`, must not apply to host paths. The refresh mapping (B3a) uses the
    same function now.
- **Failure.**
  - A non-zero exit becomes `GitClientError.commandFailed` with `wt`'s error output, as
    locally.
  - A connection error keeps its `RemoteRepositoryHostError` type.
- **The new worktree.** Its creation time is the time it was created on this Mac. The
  host's time arrives with the next refresh.

`wt` already runs on bash 3.2, and it branches on `uname` for copies. It runs as a function
in a command substitution, which is a subshell, so its `set -euo pipefail` and its `exit`
stay inside it. The substitution must not be part of a condition (`… || exit`, `if`):
bash 5 then ignores `set -e` inside it, and `wt` would go on after a failed
`git worktree add`, copy files into a folder that git did not register, and exit 0. The
script reads the substitution's status on the next line instead. Bash 3.2 does not have
this problem, so the test runs under both.

### The host's home directory

`RemoteRepositoryHost.homeDirectory()` reads `$HOME` once per host. Concurrent first
callers share one read, and a failed read is not kept.
`RepositoryHost.remoteHomeDirectory(in:)` exposes it, and returns nil for a local repository.
B3d places remote worktrees under it by default.

### `RepositoryHost`

- `createWorktreeStream(in:_:)` runs on the remote host for a remote location. The request's
  folders then hold host paths.
- Without a host, the stream still fails with `remoteUnavailable`.
- A local location is unchanged.

### `RemoteCommandLane.stream`

The owner's lane and the leased lane stream through `RemoteConnectionOwner.stream`. A lane
built without `stream` replays a script's whole output as lines when the script ends.

### A missing script

When the app bundle lacks `git-wt/wt`, a remote creation fails with
`RemoteRepositoryHostError.bundledScriptMissing`. It does not stop the app; the local
`bundledWtScriptURL()` still does, as before.

## Tests

`RemoteRepositoryHostTests`. The lane of these tests streams `bash -s` on this Mac:

- the bundled `wt` creates a worktree from a base ref and copies untracked files. The
  events carry the progress lines, including `wt`'s copy report on standard error. The
  finished worktree has its physical path, its detail and the repository's location. A
  greeting from a startup file and the result records are not progress lines. The refresh
  lists the worktree under the same ID;
- a directory override places the worktree;
- a `git worktree add` that fails (a destination folder that is not empty) stops the
  creation under bash 3.2 and bash 5 (Homebrew): no copy into that folder, no finished
  event, and nothing registered. With the old `… || exit $?` line, the bash 5 case fails;
- a base ref that does not exist fails with `wt`'s message (`commandFailed`, `wt …`);
- the host's home directory: two concurrent first callers share one read, a later call
  reads nothing, and a local repository has none;
- host paths are related as text (`/private/tmp/…` stays as it is, `.` and `..` parts are
  handled);
- opt-in on a real SSH host (`TEST_RUNNER_PROWL_REMOTE_LANE_HOST=mini`, run on 2026-10-23):
  `wt` creates a worktree on the host, the refresh lists it, and it is removed with its
  branch.
