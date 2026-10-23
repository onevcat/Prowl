# 084.022 — The worktree creation flow by location (B3d)

## Context

B3c ([021](021-b3c-remote-worktree-creation.md)) runs `wt` on a remote folder's host. The
creation flow in `RepositoriesFeature` was still built on local URLs:

- the base directory and the dialog's overrides came from `ProwlPaths`;
- the existence check of the destination used `FileManager`;
- the failure action and its cleanup carried local URLs;
- the prompt previewed local paths.

A remote repository was refused with "Worktrees cannot be created in remote folders yet."
The plan left one question open: where `wt` puts remote worktrees. The worktree base
directory setting is a local path.

## Change

No remote folder exists before C1. Exposure: none.

### Placement (`WorktreePlacement`)

`App/Sources/Domain/WorktreePlacement.swift` resolves the base directory, the dialog's
overrides and the preview by where the repository lives:

- **Local:** the existing `ProwlPaths` rules, unchanged.
- **Remote:**
  - **Default.** By default a worktree goes under `<home>/.prowl/repos/<repository>` on the
    host, which mirrors the local `~/.prowl/repos/<repository>`. `<home>` is the physical
    path of the host's `$HOME` (`pwd -P`), so the worktrees under it get the IDs that git
    lists. `<repository>` follows the local rule (`ProwlPaths.repositoryDirectoryName`),
    applied to the host path as text.
  - **Repository setting.** The repository's own base directory setting is read as a host
    path. `~` is the host's home, a relative path is relative to the repository, and an
    absolute path stays as it is. `.` and `..` resolve as text. Another user's home
    (`~user/…`) would need the host to expand it, so a creation that uses it fails with
    `WorktreePlacementError.anotherUsersHome`. Without that check, the path would be read
    as a folder inside the repository.
  - **Global setting.** The global default base directory is a path on this Mac, so it does
    not apply to remote folders.
  - **Dialog overrides.** The name and path overrides follow the same rules as locally:
    the path sets the parent, the name sets the leaf, and with neither, `wt` keeps
    `base/<branch>`.

This answers the plan's open question.

### The flow

- **The gate.** `RepositoryLocation.availability(of: .worktreeCreation)` is now available
  for remote folders. The reducer's guard for a local root is gone.
- **The prompt.**
  - When the prompt loads, it reads the host's home (`RepositoryHost.remoteHomeDirectory`),
    concurrently with the refs, and passes it with `promptedWorktreeCreationDataLoaded`.
    When the read fails, `promptLoadFailed` shows its error (a refused login, a missing
    host profile, a timeout) instead of opening the prompt.
  - The prompt state holds a `WorktreePlacement` instead of a local root. A convenience
    initializer keeps the local form.
  - The branch-name suggestion gathers terminal hints by repository location, not by a
    local root, so a remote repository never takes hints from a local repository at the
    same path text.
- **The creation.**
  - The flow resolves the placement inside its effect, right after it chose the name and
    before the fetch and the file counts. For a remote repository, that reads the host's
    home; a failure there fails the creation with its error before any long work.
  - The destination check goes through `RepositoryHost.pathExists`: `FileManager`
    locally, `test -e` on the host. A remote check that cannot reach the host says that
    the path exists. Cleanup then never takes over a folder that it did not create.
- **Failure and cleanup.**
  - `createRandomWorktreeFailed` carries `repositoryLocation` and `worktreeLocation`.
  - `cleanupFailedWorktree` builds the placeholder worktree from locations.
  - The cleanup effect compares destinations by location: local paths as before
    (`comparableWorktreePath`), and host paths as text on the same host. A remote
    destination is first resolved on the host (`RepositoryHost.physicalLocation`), because
    git lists worktrees by their physical paths, and a base directory setting can go
    through a link. Cleanup then removes the worktree that git lists, when its branch is
    the one that this attempt created.
- **A new remote worktree** opens no local tab. `AppFeature` sends `ensureInitialTab` only
  where terminal tabs are available. Remote terminals and setup scripts come with C3.

## Tests

- `RemoteRepositoryHostTests`:
  - the placement rules: the default under the host's home, the global default ignored,
    `~`, relative, absolute and `.`-part overrides, the dialog's name and path overrides,
    and the preview; the repository folder name of a `.bare` root and of `/`, as text;
    another user's home detected;
  - the prompt shows a refused SSH login when the host's home cannot be read, and does
    not open;
  - a base directory in another user's home fails the creation with its message, and
    nothing is created;
  - after a failed creation, cleanup removes the worktree that this attempt registered,
    through a destination placed by a link, and leaves a worktree of another branch at
    its destination;
  - the reducer's creation flow for a remote repository whose setting is `../worktrees`.
    The lane runs on this Mac, with the real `wt`. The worktree is created at the host
    path, and the repository lists it. The local git client is never asked (the test
    dependency fails on any call).
- `RepositoryHostTests`: without the host's home, the prompt does not open, and the alert
  names the unreachable host.
- `RepositoryFeatureAvailabilityTests`: every feature except worktree creation stays
  unavailable for remote folders.
- `AppFeatureTerminalSetupScriptTests`: a new remote worktree sends no terminal command.
- `BranchNameSanitizerTests`: the suggestion context takes a repository location.
- The existing local creation, placement and failure tests pass unchanged, except the two
  that build the failure action, which now pass locations.
