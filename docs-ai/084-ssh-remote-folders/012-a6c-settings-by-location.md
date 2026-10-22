# 084.012 — Repository settings by location (A6c); A6 re-split

## Context

A6c of [010-a6a-repository-host.md](010-a6a-repository-host.md) covered three things:

- the settings keys;
- `RepositorySettingsFeature`;
- the pull request and code host path, with the URL-keyed actions.

A sweep found 53 settings-key sites in 18 source files and 46 in tests. The GitHub
integration path is a second, separate change: its pending and queued refresh state, the
coordinator and its actions are all keyed by a root URL. So the rest of A6 is split again.
Decided 2026-10-23 in unattended mode.

| PR | Content |
| --- | --- |
| A6c (this one) | Settings keys and `RepositorySettingsFeature` by location |
| A6d | The pull request and code host path by location |
| A6e | The remaining forward reads; then the forwards are deleted |

## Change

### Keys

- `RepositorySettingsKey(location:)` and `UserRepositorySettingsKey(location:)` are the
  designated initializers. `.repositorySettings(_:)` and `.userRepositorySettings(_:)`
  take a `RepositoryLocation`.
  - A local location is standardized as before, so the key ID is unchanged (`/tmp/repo`
    for `/tmp/repo/../repo`).
  - A remote location keeps its canonical ID.
- The URL forms stay as conveniences for a local root that is not a repository's location,
  such as workflow roots and tests. They wrap `.local(url)`.
- `ProwlPaths.repositorySettingsURL(for:)` and `userRepositorySettingsURL(for:)` take a
  location. They use the location-keyed settings directory of A3a.
- `legacyRepositorySettingsURLs(for:)` and `legacyUserRepositorySettingsURLs(for:)` with a
  location return no files for a remote location. A local repository with the same
  basename can leave files in the old basename directory, and a remote folder must not
  read them.

### Call sites

- Every production key that read `repository.rootURL` or `worktree.repositoryRootURL` now
  passes `repository.location` or `worktree.repositoryLocation`: AppFeature, the terminal
  manager and state, command palette, worktree detail, the repositories reducer
  (creation, lifecycle, line counts, custom title).
- `RepositoriesFeature.Action.refreshCustomTitle` takes a location. Its lookup no longer
  reads `Repository.rootURL`.
- `AppFeature.setRepositoryOpenActionID` takes a location.
- The GitHub integration path keeps its URL keys until A6d.

### `RepositorySettingsFeature`

- `State.rootURL` is replaced by `State.location`. The delegate action
  `settingsChanged` carries the location, and AppFeature compares it with
  `worktree.repositoryLocation`.
- The git reads (bare check, branch refs, base ref) go through `RepositoryHost`.
- New state helpers:
  - `folderName` (`Repository.name(for: location)`);
  - `localRootURL` (nil for a remote repository).

  `PROWL_ROOT_PATH` in the environment list shows `location.path`.
- These parts of the pane read or write folders on this Mac. For a remote location they
  are limited until the remote pane is designed (C1):

  | Part | Remote behaviour |
  | --- | --- |
  | Worktree base directory | Not normalized: `~` and relative paths belong to the remote host. Before, they were expanded against this Mac's home and saved back |
  | Worktree folder example | Hidden |
  | Icon preview | SF Symbols and bundled icons render. Imported images fall back like a missing file |
  | Icon image import | Refused with "Images are not available for remote folders yet." |
  | Symbol suggestions | Fail with "Suggestions are not available for remote folders yet." (no endless spinner) |
  | Workflows section, workspace section | Hidden |
  | Branch refs | Empty, without a warning log: `RepositoryHostError` is the expected state until B3 |
- `RepositoryIconImage` takes an optional root URL. Only imported images need it.
- Both settings keys standardize through `RepositoryLocation.standardized`. Repository and
  user settings of one repository cannot get different IDs.
- `RepositorySettingsFeature` builds its own `RepositoryHost(local: gitClient)`, as the
  repositories reducer does (A6a: tests keep overriding `gitClient`). B3 adds the remote
  host as an input and makes the host one dependency for both features.

## Behaviour

No change for local repositories:

- the same key IDs, files and legacy copy chain;
- the same settings pane;
- the same `settingsChanged` handling.

## Tests

- `RepositorySettingsKeyTests`:
  - a local location and its root URL name the same key;
  - a remote location reads its own file, and never reads the basename legacy file of a
    local repository with the same name.
- `UserRepositorySettingsKeyTests`: the same for user settings. A remote location gets a
  new file in its own directory.
- `RepositoryHostTests.remoteRepositorySettingsLoadWithoutLocalGit`: the settings pane of a
  remote repository loads without local git, shows `HEAD` as the base ref, skips the
  workflows scope, and has no folder example.
- `RepositoryHostTests.remoteRepositorySettingsKeepRemotePathsAndExplainLocalOnlyParts`:
  - a remote `~/worktrees` base directory stays unexpanded;
  - suggestions and image import report their reason.
- The existing settings, AppFeature and profile suites now build the pane state with
  `location:`, and their assertions are unchanged.
