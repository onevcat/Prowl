# 084.005 — Identity through the codec, settings directory keyed by location (A3a)

## Context

Slice A3 of [000-plan.md](000-plan.md) moves call sites to locations in two or three
PRs. A3a is the identity category. It covers the places that mint repository and
worktree IDs, the places that decode an ID without a model, and the repository settings
key. The settings directory change also fixes the basename collision of D8.

## Change

### IDs minted through the codec

`Repository.init(location:…)` and `Worktree.init(name:detail:location:repositoryLocation:…)`
derive the ID from the location. They are used where IDs are minted today:

- repository loading;
- the worktree list and worktree creation in `GitClient`;
- the worktree of a failed creation.

The root-derived IDs in `orderedRepositoryRoots`, `orderedRepositoryIDs`, the order
prunes and the sidebar failure rows use `RepositoryLocation.local(url).id`. Each value
is the same string as before: the standardized URL path.

The snapshot restore keeps its own IDs. Its string comes from `PathPolicy`, not from the
URL, and B2 rewrites the snapshot.

### IDs decoded without a model

- Icon-detection cleanup of a failed or removed repository decodes the ID with
  `RepositoryLocation(id:)` and skips a non-local one.
- `WorktreeTerminalManager.prune` skips non-local failed IDs. It keeps
  `URL(fileURLWithPath:)` for local IDs, so the trailing slash that this API adds or omits
  is unchanged.
- `isSameRepositoryPath` (failed repository removal) compares strings without trailing
  slashes, which is already correct for remote IDs. It is unchanged.

### Settings directory

- `ProwlPaths.repositorySettingsDirectory(for: RepositoryLocation)` is now
  `~/.prowl/repo/<basename>-<hash>`.
  - `<hash>` is the first 8 hex digits of the SHA-256 of the local path (standardized,
    trailing slash removed), or of the remote ID.
  - The basename is the last path component (`_` for `/`).
  - The existing `for rootURL:` functions call it with `.local(rootURL)`.
- The directory of earlier builds, `~/.prowl/repo/<basename>/`, holds only legacy
  sources. Two repositories with one basename shared it, so nothing there is moved or
  deleted.
  - **Repository settings.** The load chain is the new `prowl.json`, then the old
    `prowl.json`, then the old `supacode.json`, then the global `settings.json`
    (`legacyRepositorySettingsURLs(for:)`). A copied file is created with
    `storage.create(…, source:)`, so a symlink to dotfiles stays a symlink (#478). When
    the new file exists but cannot be decoded, it is replaced with `save` as before.
  - **User repository settings.** `legacyUserRepositorySettingsURLs(for:)` lists the old
    `prowl.user.json`, then `prowl.onevcat.json`, then `supacode.onevcat.json`.
    `UserSettingsFile` already copies the first one it finds and keeps links.
  - **Icons.** They are read in place. `repositoryIconFileURL` and the store's `exists`
    also look in the old `icons/`. Imports and removals use the new directory only.
- The copy happens when a key first loads, not in a separate migration pass. A snapshot
  restore shows repositories before the live load, so their settings can load first.
  A pass after loading would let them load defaults and save over the copy.
- The worktree base directory (`~/.prowl/repos/<name>`) is not part of the plan and
  does not change.

### Docs

`docs/concepts.md`, `docs/components/settings.md`, `custom-actions.md`,
`agent-profiles.md`, and `docs/reference/settings-fields.md` now show
`~/.prowl/repo/<repo-name>-<hash>/` and the copy rule.

### Tests

- `ProwlPathsTests`:
  - fixed hashes for local paths, a remote ID and `/`;
  - one basename with two parents gives two directories;
  - a trailing slash gives the same directory;
  - legacy sources live in the basename directory;
  - icon fallback;
  - a long basename stays under the file name limit.
- `RepositorySettingsKeyTests`:
  - a copy from the basename directory leaves the source unchanged;
  - a failed link copy still writes the repository file;
  - two repositories with one basename split after the copy;
  - the copy goes through `create` with the old file as the source.
- `UserRepositorySettingsKeyTests`: the user settings copy.

## Behaviour change

- Repository settings move to the keyed directory on first load. The content stays
  the same, and the old directory stays in place.
- A user who has two repositories with one name gets separate settings after the
  first change to either repository. The exception is a symlinked file: it is copied
  as a link to the same target, so those repositories keep sharing it.
- Settings now follow the path. A moved or re-added repository does not take along
  edits made at its old path. If an old basename directory exists, it loads that
  directory again; otherwise it gets the defaults. Before this change, the basename
  key carried settings across a move only when the folder name stayed the same.
  Accepted with D8.

## Review fixes (self-review)

- If the link copy fails, the file is written with `save` instead. Otherwise later
  saves would go to the global file, the next load would read the legacy file first,
  and the edits would be lost.
- The basename is truncated to 200 UTF-8 bytes, so `<name>-<hash>` stays under the
  255-byte file name limit.
- The icon fallback is one helper, `ProwlPaths.iconFileURL(filename:in:fallback:)`,
  shared by the view and the store. A shared `PathPolicy.trimmingTrailingSlashes`
  replaces the copy in failed repository removal.
- Rejected:
  - Removing legacy icons. They may be shared, so they are never deleted.
  - Caching the icon URL. `RepositoryIconImage` already reads and decodes the image on
    each body evaluation, so one hash and one or two `stat` calls do not matter beside
    that.

## Left for later slices

- A3b:
  - git and file reads;
  - terminal cwd and cwd matching, including `CanvasView+Focus.repositoryID(for:)`,
    which still derives an ID from a root path;
  - CLI.
- A3c: delete the forwards.
- B2: the snapshot IDs.
- C2: the workflow `rootKey` (`WorkflowPreferenceKey`).
