# 084.004 — `RepositoryLocation` and the ID codec (A2)

## Context

Slice A2 of [000-plan.md](000-plan.md), decision D1. Remote folders need IDs that are
not paths. A2 adds the location model and the one codec for IDs. It also stops the
persistence normalizers from rewriting IDs that are not local paths. Every repository
today is local, so nothing changes for users.

## Change

### Codec

`RepositoryLocation` (`App/Sources/Domain/RepositoryLocation.swift`) is
`.local(URL)` or `.remote(hostProfileID: UUID, path: String)`.

- `location.id` encodes the location. A local ID is `url.path(percentEncoded: false)`,
  unchanged, so it matches the IDs stored today byte for byte, including a trailing
  slash. A remote ID is `ssh:<lowercase UUID>:<path>`, with the path stored raw.
- `RepositoryLocation(id:)` decodes an ID and is nil for a string in neither form. A
  local ID decodes with `URL(filePath:directoryHint: .inferFromPath)`, without touching
  the filesystem.
  - A remote ID must have a lowercase UUID, then `:`, then a canonical path: absolute,
    with no empty, `.` or `..` component, and no trailing slash except for `/`.
    An uppercase UUID or a non-canonical path is rejected, so every location has
    exactly one ID.
- `localURL` is nil for a remote location. `path` is the path on the location's own
  host.

### Models

- `Repository` stores `location` instead of `rootURL`. `Worktree` stores `location` and
  `repositoryLocation` instead of `workingDirectory` and `repositoryRootURL`.
- New designated initializers take locations. The existing `init(id:rootURL:…)` and
  `init(…workingDirectory:repositoryRootURL:…)` build `.local` locations, so no
  constructor call changes.
- `localURL` and `repositoryLocalURL` are optional.
- `rootURL`, `workingDirectory` and `repositoryRootURL` are now computed forwards to the
  local URL. They trap with the ID for a remote value. A3 moves their call sites and
  deletes them.
- `Worktree.isMain` compares two local URLs as before (fast equality, then standardized).
  It compares two remote locations by equality. Mixed hosts are never main.
- `Repository.terminalWorktree` builds from `location`, with `location.path` as the
  detail (unchanged for a local folder), so a remote plain folder does not reach a
  forward.

### Normalizers

`RepositoryPathNormalizer` is renamed to `RepositoryIDNormalizer`, with one rule for IDs
and one for roots.

- **IDs.** `normalize(_:)` sends a string through path normalization only when it has
  the local path form (`/` or `~` after trimming, `RepositoryLocation.isLocalPathForm`).
  Every other non-blank string, remote or unknown, is kept exactly as stored, so the
  home directory is no longer prepended to a relative string. This rule applies to:
  - pinned worktree IDs;
  - archived worktree IDs (symlink resolution is kept for local paths) and the legacy
    archived list;
  - repository order;
  - the keys and the values of worktree order. The keys used to go through
    `URL(fileURLWithPath:)` while the values went through `PathPolicy`, so a `~` key
    never matched its own repository ID; both now use one rule.
- **Roots.** `normalizeRoots(_:)` and `normalizeRoot(_:)` apply to entry paths
  (`RepositoryEntryNormalizer`) and legacy roots. They are paths, so only a remote ID
  (`ssh:` prefix) is kept as stored. Every other string resolves as before, and a
  relative root still resolves against the home directory. The workspace metadata check
  skips remote entries.

For an absolute local string, both rules make the same calls as before, so the result
does not change.

### Tests

`RepositoryLocationTests` and `RepositoryIDNormalizerTests` cover:

- R-1: local IDs are byte-identical, local and remote IDs round-trip with spaces, `%`,
  `#`, `:`, Unicode and emoji, and strings in neither form and non-canonical remote
  paths are rejected;
- the `.local` initializers;
- R-7: a linked local worktree keeps distinct paths, `isMain == false`, and both script
  environment paths;
- remote `isMain`, and the terminal worktree of a remote plain folder;
- normalizers that keep remote IDs, order keys and values, and entry paths; IDs that
  never gain the home directory; relative roots that still do; and one rule for order
  keys and values.

## Deviations from the plan

- The forwards are not marked `@available(*, deprecated)`. About 500 reads (sources and
  tests) would each produce a warning and hide real warnings during A3. Deleting the
  forwards at the end of A3 gives the same complete list from the compiler.
- `~` stays a local path form for the normalizers, as before. Legacy roots may hold it.
  The codec still rejects `~` as an ID.
- `Repository.id` is still passed in, not derived from `location`. Repository loading
  and snapshot restore mint IDs from paths, and A3 owns those sites.
- Worktree order keys that start with `~` now expand like every other ID (see
  Normalizers). Before, such a key resolved against the process working directory.

## Left for later slices

- A3: call sites move off the forwards; IDs are minted with the codec; settings keys
  move; `terminalWorktree`'s display path.
- B2: remote entries in repository loading (`upgradedRepositoryEntriesIfNeeded` and
  `loadRepositoriesData` still treat each entry path as local), and the snapshot cache.
  `SnapshotRepository` restore still normalizes paths, and the snapshot save reads the
  forwards, so a remote repository in state traps there. Like every other forward
  read, that cannot happen before remote repositories exist (C1, behind the flag).
