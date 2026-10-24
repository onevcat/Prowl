# 084.017 — Repository roots by location (B2a); B2 split

## Context

B2 in [000-plan.md](000-plan.md) covers three things: `hosts.json`, remote entries, and
the per-entry snapshot cache (version 3). A6e
([014-a6e-delete-forwards.md](014-a6e-delete-forwards.md)) left the lists of repository
roots to B2. These lists are:

- `State.repositoryRoots`;
- the `roots` of `repositoriesLoaded` and `applyRepositories`;
- the order prunes;
- `orderedRepositoryRoots`;
- the sidebar.

They held `[URL]` and dropped remote repositories (`compactMap(\.localURL)`). A remote
entry could not join them until they hold locations. That change touches about 20 source
sites and 100 test sites, so B2 is split. Decided 2026-10-23 in unattended mode.

| PR | Content |
| --- | --- |
| B2a (this one) | The root lists hold `RepositoryLocation` |
| B2b | `hosts.json`, remote entries in loading, snapshot version 3 per entry |

## Change

- `PersistedRepositoryEntry.location`:
  - A remote ID decodes to its location.
  - Every other path becomes `.local(URL(fileURLWithPath: path))`, which is exactly how
    loading built root URLs before. That initializer adds a trailing slash for an existing
    directory, and local repository IDs depend on it.
- These now hold `[RepositoryLocation]`:
  - `State.repositoryRoots`;
  - `repositoriesLoaded(roots:)`, `openRepositoriesFinished(roots:)`;
  - `applyRepositories(roots:)`;
  - `pruneRepositoryOrderIDs(roots:)`, `pruneWorktreeOrderByRepository(roots:)`;
  - `loadRepositories(fallbackRoots:)`, `loadPersistedRepositoryEntries(fallbackRoots:)`.

  Roots come from `entries.map(\.location)` and `repositories.map(\.location)`.
- `orderedRepositoryRoots()` returns standardized locations. `orderedRepositoryIDs()` and
  the sidebar read their IDs from `location.standardized.id`, which for a local root equals
  the old `RepositoryLocation.local(url.standardizedFileURL).id`.
- The sidebar's failed-repository row reads its name and path from the location.
- The A6e fallbacks `repositories.compactMap(\.localURL)` become
  `repositories.map(\.location)`, standardized, so a remote repository is no longer
  dropped from the lists.
- Each root is standardized once. The sidebar uses `orderedRepositoryRoots()` directly.

### Loading, now that remote roots reach it

Since remote IDs can now reach the loading path, it no longer treats an entry path as a
local path:

- `upgradedRepositoryEntriesIfNeeded` returns a remote entry unchanged. Before, it would
  have standardized `ssh:<uuid>:/srv/app` into `/ssh:<uuid>:/srv/app` and saved that.
- The load-time prune goes through `RepositoryHost` with `entry.location`. A remote entry
  is refused there and never runs local git.
- `loadRepositoriesData` fails a remote entry with "Remote folders are not available
  yet." (`RepositoryHostError.remoteUnavailable`) until B3 loads it through its host. Its
  failure is keyed by `entry.location.standardized.id`, the key that the sidebar and the
  prunes use.
- `RepositoryEntryNormalizer` drops a string in the remote form that does not decode, and
  logs a warning. Such a string would otherwise load as a relative local path, and it
  could never be removed again.
- The watcher's plain-folder roots stay `[URL]`: they are local folders by definition (A6b).

## Behaviour

No change for local repositories:

- the same IDs, including the trailing slash;
- the same order and prunes;
- the same sidebar.

Remote repositories can now appear in the root lists. No production code creates one yet
(B2b loads them, C1 adds them).

## Tests

- `PersistedRepositoryEntryLocationTests`:
  - a local entry of an existing directory, stored without a trailing slash, keeps the
    trailing slash in its ID;
  - a remote entry decodes its location;
  - a malformed remote entry is dropped.
- `RepositoryHostTests`:
  - a remote repository stays in the roots, the order and the ordered IDs after a
    snapshot load;
  - a remote entry is not rewritten by the upgrade, and it fails to load under its own ID.
- The repositories, sidebar, AppFeature, shelf, palette and notification suites now build
  their roots as locations (`.local(url)`, `repository.location`). Their assertions are
  unchanged.
