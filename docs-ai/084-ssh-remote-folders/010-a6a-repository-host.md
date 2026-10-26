# 084.010 — `RepositoryHost` for repository git operations (A6a); A6 split

## Context

Slice A6 of [000-plan.md](000-plan.md) moves repository state reads and `observeChanges`
behind the host and then deletes the local forwards (`Repository.rootURL`,
`Worktree.workingDirectory`, `Worktree.repositoryRootURL`). A sweep after A5b counted:

- about 45 repository git calls in 12 files;
- 43 settings-key sites that take a root URL;
- about 146 forward reads in 39 source files and 145 in 28 test files;
- four monitor classes plus three local reads behind the watcher.

That is too much for one reviewable PR. A6 is split into four PRs. A5c ("git reads move
off the forwards") joins A6a. Decided 2026-10-23 in unattended mode.

| PR | Content |
| --- | --- |
| A6a (this one) | `RepositoryHost`; the repository and worktree git operations of the repositories reducer take locations |
| A6b | `observeChanges`: the local monitors behind one host stream; cadence stays in `WorktreeInfoWatcherManager` |
| A6c | Settings keys, `RepositorySettingsFeature`, the pull request and code host path, and the URL-keyed actions and watcher events use IDs or locations |
| A6d | The remaining forward reads (display paths, Finder, CLI snapshot, terminal, tests); then the forwards are deleted |

## Change

### `RepositoryHost` (`App/Sources/Clients/Repositories/RepositoryHost.swift`)

- Operations are addressed by `RepositoryLocation`. There are repository operations
  (worktrees, prune, branch names and refs, base ref, file counts, bare check, branch
  deletion, remotes, fetch, web URL, worktree creation) and worktree
  operations (remove, branch name, line changes, rename).
- A local location runs on `local`, the existing `GitClientDependency`. That keeps
  every local fast path of `GitClient`: HEAD reads, the index lock, untracked line
  counts, and the move-then-prune removal.
- A remote location never reaches `local`:
  - Throwing operations fail with `RepositoryHostError.remoteUnavailable`.
  - Operations without an error channel return no value: `nil`, an empty list, or
    `false` for the branch-name check.
  - Worktree creation finishes its stream with the error.

  B3 adds the remote host in this place.
- It is a value built from the reducer's `gitClient` dependency
  (`RepositoriesFeature.repositoryHost`), not a new dependency. Tests keep overriding
  `gitClient`, and B3 adds the remote host as a second input.
- Worktree creation takes the repository from the location: the host replaces the
  request's `repoRoot`, so the two cannot disagree. The other folders of the request
  (base directory, override) are local URLs; the remote host maps them in B3.
- The GitHub remote lookups (`remoteInfo`, `githubRemoteInfos`) move with their callers
  in A6c.

### Call sites

| Feature | Operations |
| --- | --- |
| Loading | worktrees, prune (entries are local until B2); code host detection (web URL) |
| Info refresh | branch name on `.branchChanged`, line changes on `.filesChanged` |
| Rename | rename branch |
| Remove | remove worktree, delete branch, force delete (`ForceDeleteBranchRequest` stores the repository location) |
| Create | refs, base ref, branch names, branch-name check, bare check, remotes, fetch, file counts, the create stream, and the cleanup after a failed create |

`RepositoriesFeature.gitClient` stays for local URLs that are not a repository
location: the add and open flow (`repoRoot` of a picked folder), workspace sources and
children, and the diff target probe. Workspaces and diffs are unavailable for remote
folders (A4a).

### Behaviour

No change for local repositories. For a remote repository:

- A branch change reads nothing.
- A rename shows "Remote folders are not available yet."
- A remote configuration change for another repository no longer traps on the remote
  one: the lookup compares `location.localURL`.

Remote folders can only exist after C1.

### Still on the forwards in the paths that A6a touched

The host calls are remote-safe, but the code around them still reads forwards before the
first host call. The forwards still trap, so these paths are not remote-safe yet:

| Path | Forward reads | Owner |
| --- | --- | --- |
| Worktree creation (prompt, start, run) | Settings key, base directory, `GitWorktreeCreateRequest` folders, failure payloads | A6c (settings), A6d (others) |
| Cleanup after a failed create | Path comparison of the registered worktrees | A6d |
| Branch name suggestions | `gatherContext` root URL | A6d |

In B3, the remote host returns `isValidBranchName` and the base ref for remote
repositories, and B3 lands before C1. So the `false` and `nil` fallbacks never reach a
build that has remote folders.

### Tests

`RepositoryHostTests`:

- A local location calls the local client with the location's URL.
- A local worktree creation runs in the location's repository, whatever `repoRoot` the
  request carries.
- Every remote operation fails or returns no value without calling the local client.
  The test client records an issue for every operation, so nothing falls through to
  real git. This covers worktree creation, removal and rename.
- On a remote worktree, `.branchChanged` reads nothing, and a rename shows the reason.
- A remote configuration change skips remote repositories in the lookup.

The existing reducer suites cover the local paths unchanged.
