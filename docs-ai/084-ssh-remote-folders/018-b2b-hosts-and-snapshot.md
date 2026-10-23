# 084.018 — `hosts.json`, entry hosts, snapshot version 3 (B2b)

## Context

This is the second part of B2 in [000-plan.md](000-plan.md) ("Persistence (D6, D8)"). B2a
([017](017-b2a-roots-by-location.md)) moved the root lists to locations and made loading
keep remote entries remote. This part adds the remaining persistence that a remote folder
needs before B3 and C1 can use it.

## Change

All of this is unused until B3 and C1. Exposure: none.

### `~/.prowl/hosts.json`

- `HostProfilesKey` (`.hostProfiles`) stores `[HostProfile]` as
  `{"version": 1, "hosts": [...]}`. It uses the settings file storage and an injectable
  URL (`hostProfilesFileURL`), as the repository entries key does. The version leaves room
  for C1's rebind state.
- A missing file loads as no hosts.
- A file this build cannot read loads as no hosts too, with a warning. This covers a newer
  version, a damaged file, and any read error other than "no such file", such as a link
  into a volume that is not mounted or missing permissions. A save does not overwrite such
  a file (`HostProfilesFileError.unreadableFile`), so the hosts that remote folders refer
  to are never lost. Those folders show as unavailable until the file is readable again.
- When a save is refused, the shared value still holds the change in memory. C1's Add
  Remote Folder must check the save error before it writes an entry that refers to the new
  host.

### Entries

- `PersistedRepositoryEntry` gets the optional `host` of D6. A remote entry writes its
  host profile ID next to its encoded ID, so that the file reads plainly. A local entry
  writes no `host` key, so a local-only file is byte-identical to before.
- The path stays the source of truth. `host` is derived from it in `init(path:kind:)`,
  and decoding ignores a stored `host`, so the two can never disagree. Older files without
  `host` decode unchanged.

### Snapshot cache version 3

- `RepositorySnapshotCachePayload.currentVersion` is 3. Repositories and worktrees are
  stored by location ID: a local path as before, or an encoded remote location.
- **Remote repositories restore without a check on this Mac**, so a remote folder never
  makes the snapshot fail on a missing local path. Their host reloads them; B3 loads them,
  and until then they fail as B2a describes. Workspaces are local, so a remote repository
  restores without one. The restore does not check that the host profile still exists;
  the live load reports that (B3).
- Local repositories restore exactly as in version 2: the same path normalization, the
  same IDs and the same existence checks.
- **One repository that cannot be restored still discards the whole snapshot**, as in
  version 2. This includes a remote worktree on another host than its repository, or a
  value that does not decode.
- A local location's ID is its path, so a version 2 snapshot reads the same way, and
  updating Prowl keeps the warm sidebar.

### Deviation: no per-entry skip yet

The plan says that the snapshot "skips a single entry instead of dropping the snapshot".
That is deferred, because a partial snapshot loses state:

- On this stack, the snapshot load prunes against its own list. A left-out repository
  would lose its pins, its archived worktrees, its order and the worktrees Prowl created
  (`prowlCreatedWorktreeIDs` is written to disk at once). P0 (#954) stops these prunes,
  but it is not in this stack.
- Even with P0, a partial snapshot spends the one-time restore of the last focused
  worktree when that worktree is in the left-out repository.

Remote folders do not need the per-entry skip, because they never fail the local check.
The skip can come back once P0 has landed and the last-focus restore waits for the live
load.

## Tests

`RemoteRepositoryPersistenceTests`:

- `hosts.json` round trip, including the file version;
- a newer-version file loads as empty and is not overwritten by a save;
- a remote entry encodes and derives its host, and a tampered stored host is ignored;
- a local entry has no host, and the old format decodes and encodes without one;
- a file that cannot be read (a permission error) loads as empty, and a save neither
  writes it nor succeeds;
- a remote repository round-trips through snapshot version 3 without any local path check;
- a remote repository never fails the snapshot on a local path check;
- a missing local repository still discards the whole snapshot;
- a remote worktree on another host makes the snapshot unrestorable;
- a version 2 snapshot still restores its local repositories.

The existing snapshot tests run with version 3 fixtures.
