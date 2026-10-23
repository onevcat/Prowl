# 084.019 — The batched remote refresh and its parser (B3a)

## Context

The "Remote refresh (D4)" section of [000-plan.md](000-plan.md) describes what one poll of
a remote repository returns. B3 is split into three PRs (see the plan's slice table):

- **B3a (this record):** the refresh script, the reply format and its parser, and the
  mapping to `Worktree` and `GitLineChanges`;
- **B3b:** `RemoteRepositoryHost`, the remaining git operations on the command lane, and
  the remote input of `RepositoryHost`;
- **B3c:** the refresh cadence in the watcher, the connection leases, and the unreachable
  state.

## Change

All of this is unused until B3b and B3c. Exposure: none.

`RemoteRepositoryRefresh` (`App/Sources/Infrastructure/RemoteHost/RemoteRepositoryRefresh.swift`)
holds the script, the parser and the mapping.

### The script

- It runs on the command lane as a `RemoteScript` (`bash -s`, the repository path in `$1`).
  It needs bash 3.2 or later and works with BSD and GNU tools.
- One command reads everything for a poll:
  - the physical root (`pwd -P`);
  - `git rev-parse --is-bare-repository`;
  - a fingerprint of the remote URLs: `cksum` of `git config --get-regexp '^remote\..*\.url$'`;
  - each entry of `git worktree list --porcelain`, with its HEAD, its branch, its creation
    time, `git diff --numstat HEAD` and the count of untracked files that are not ignored.
- Creation time:
  - BSD: `stat -f %B`, or the modification time (`%m`) when the file system has no birth
    time;
  - GNU: `stat -c %W`, or the modification time (`%Y`).
  - This matches the local host, which uses the creation date and otherwise the
    modification date.
- `GIT_OPTIONAL_LOCKS=0`: a poll never writes the index, so it never takes `index.lock`
  from a git command that an agent runs on the host at the same time. The local host
  avoids the same race by skipping a worktree whose index is locked.
- A worktree where `git diff HEAD` fails (no commit yet) has no line counts, as on the
  local host.
- A folder that the script cannot refresh is reported in the reply, so the command itself
  fails only for a connection error. The script tells apart:
  - a path that does not exist: the deepest part of the path that the script can see is a
    folder that it can search, so the next part is really absent. The walk follows links
    (with `readlink`, at most 16), so a link to a repository below a folder that cannot be
    searched is not missing, and a link whose target is gone is;
  - a path that exists but cannot be entered (no permission, or not a folder), or a path
    below an ancestor that cannot be searched. `test -e` fails there too, but the path may
    still exist, so it is not reported as missing;
  - no `git` on the login `PATH`;
  - a folder that is not in a repository (`not a git repository`, read with `LC_ALL=C`);
  - any other git refusal, such as `safe.directory`, with git's last error line.

### The reply

- One tab-separated record per line, between a `PROWL_REFRESH 1` header and an `END` line.
  - The parser skips lines before the header. A shell startup file can print there.
  - The parser ignores record types that it does not know, so a later format can add
    records.
  - A reply without its header or its `END` line, or a reply that the lane cut off at its
    output budget, is `incompleteOutput`.
- A path is always the last field of its record (`ROOT` and `WORKTREE`), so a path with a
  tab still parses. Git does not allow tabs in branch names.
- Git lists the main worktree (or the bare repository) first. When that path is not the
  root, the stored path is a subfolder or a linked worktree, and the reply is refused
  (`notRepositoryRoot`). Otherwise the wrong worktree would take the repository's
  location. C1 stores the discovered root, as the local add flow does.
- The reply carries a fingerprint of the remote URLs, not the URLs. So a token in a URL does
  not travel on every poll. The host reads the URLs when the fingerprint changes (B3b).
- Each line is decoded on its own. A line that is not UTF-8 is read as Latin-1, so that it
  still parses, and the other lines keep their UTF-8 paths. A path that is not UTF-8 is
  then not the host's path; such paths are not supported.
- A path with a newline is not supported, because `git worktree list --porcelain` prints
  one record per line.

### Errors

`RemoteRepositoryRefreshError`:

| Case | When |
| --- | --- |
| `connection(RemoteProbeFailure)` | `ssh` failed, or the command exited non-zero; classified as the probe classifies (`RemoteConnectionOwner.failure`) |
| `timedOut` | The lane deadline passed |
| `missingFolder` | The repository folder does not exist on the host |
| `inaccessibleFolder` | The path exists, but the host user cannot enter it, or it is not a folder |
| `notGitRepository` | The folder is not in a git repository |
| `notRepositoryRoot` | The folder is in a repository, but it is not the main worktree or the bare repository |
| `gitMissing` | `git` is not on the host's login `PATH` |
| `gitFailed(String)` | Git refused the repository, for example for `safe.directory` |
| `incompleteOutput` | No header, no `END` line, or output cut off |

Only `missingFolder` says that the folder is gone. Code that acts on a missing folder
(B3c) must not act on the other cases.

### Mapping to app models

`worktrees(in:)` builds `Worktree` values as the local host builds them from `wt ls`:

- the name is the branch, or the folder name for a detached HEAD;
- the detail is the path relative to the root;
- the order is newest first, then git's order; a worktree without a creation time comes
  last;
- bare entries are left out.

Git lists the main worktree by its physical path. That path differs from the stored one
when the stored path goes through a link (on macOS, `/tmp` is a link to `/private/tmp`). The
main worktree therefore takes the repository's own location, so `isMain` holds and its ID
is the repository ID. The other worktrees keep the path that git reports.

`lineChanges(in:)` gives the tracked added and removed lines of each worktree that has its
folder. The untracked file count goes into `skippedUntrackedFileCount`. The row then shows
`+N…` with the existing tooltip "Addition count is incomplete because N untracked files were
not counted." This is the D4 presentation, and it needs no new UI.

A worktree whose folder is gone stays in the list, as `git worktree list` reports it, and
it has no line changes.

### Cost of a poll

Each poll diffs every worktree and lists its untracked files, as the local host does for
each worktree that it refreshes. The local host also lists every untracked file, because
it counts their lines. B3c sets how often background worktrees poll; the plan already
polls the focused worktree faster than the others.

`GitClient.relativePath(from:to:)` is now internal, so that the remote mapping uses the
same rule. It reads path components only and never touches the file system.

## Tests

`RemoteRepositoryRefreshTests`:

- replies recorded with the exact script text (`App/Tests/Fixtures/RemoteRepositoryRefresh/`),
  each one parsed in full:
  - a Mac host over `ssh … bash -s` (macOS 26.5, `/bin/bash` 3.2, BSD tools): the main
    worktree reached through a link, a linked worktree with a space in its path, a detached
    worktree, a worktree whose folder is gone, a binary change, untracked and ignored
    files, a bare repository, a plain folder and a missing path;
  - a Debian 13 container (GNU coreutils), for the GNU `stat` branch;
- the worktree mapping: names, details, order, the main worktree's location, and the line
  changes by worktree ID;
- the reply format: startup output before the header, a missing header or `END` line, a
  newer header version, a root and a worktree path with a tab, empty counts, unknown
  records, a line that is not UTF-8 next to UTF-8 lines, a main worktree that is not the
  root, and every error code;
- command failures: `ssh` refused, timeout, launch failure, output cut off;
- the script itself, run as the lane sends it (`/bin/bash -s`, arguments through
  `set --`) with this Mac's git:
  - a real repository with a linked worktree, tracked edits and an untracked file;
  - a missing path, a file, a folder without permission, a plain folder, a `PATH`
    without git, a subfolder of the repository and a linked worktree, each with its error;
  - a repository, and a path that is gone, below a folder that cannot be searched, each
    reached directly, through an absolute link and through a relative link to the parent:
    all are inaccessible; after the permission is back, the repository is found, and the
    path that is gone (also through its link) is missing. The same cases gave the same
    results for a non-root user in the Debian container (GNU tools);
  - a repository without a commit, which has no line changes.
