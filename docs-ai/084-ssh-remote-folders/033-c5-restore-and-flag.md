# 084.033 — Remote layout restore and the flag on (C5)

## Context

C3b ([030](030-c3b-remote-tabs.md)) left a remote folder's tabs out of the saved layout. A
restored leaf would have been a local shell. The plan's C5 row asks for:

- an origin on the snapshot leaf;
- a reconnect on restore, with no script replay (R-9);
- a `docs/` update;
- the flag on: D7 kept `PROWL_REMOTE_FOLDERS` until remote tabs, splits and restore all
  work.

## Change

### The snapshot leaf

`TerminalLayoutSnapshotPayload.SnapshotSplitNode` gains an optional `remote`
(`SnapshotRemoteOrigin`: `hostProfileID`, `cwdPath`).

- **Saving.** `makeLayoutSnapshotNode` writes it for every leaf of a remote folder:
  - the folder's host profile;
  - the pane's directory on the host, from its tracker, while the pane's own session runs;
  - no local `cwdPath`.
- **Compatibility.** The field is optional, so an older file decodes with none, and the
  version stays 2. An older app ignores the key.

### Restore

`applyLayoutSnapshot` no longer refuses a remote folder. `restoreSplitNode` restores a
remote leaf as a new remote pane (`restoreRemoteLeaf`):

- a deferred surface in the recipe's local directory;
- a plain launch with no first command, so a script never runs again (R-9).

Its directory on the host is the saved one when it lies inside the folder, checked by text
(`RemotePaths.canonicalPath`). Otherwise it is the folder. A missing host profile fails the
worktree's restore.

`makeLayoutSnapshotPayload` saves remote states again. The C3b filter is removed, and the
selection may name a remote folder.

A remote folder never makes the whole restore fail, which would clear the saved layout and
lose the local tabs:

- a saved remote worktree that did not load (its host is unreachable) is skipped, even
  when no repository failed to load;
- a remote worktree whose apply fails (no host profile) is skipped;
- its staging failures later close each pane with a toast (C3b).

### The flag

`RemoteFolders.isEnabled` is now true unless `PROWL_REMOTE_FOLDERS=0`. The menu item, the
Add popover button and the palette item show by default. With `0`, stored remote folders
stay stored but hidden (C1a).

### Docs

- New `docs/components/remote-folders.md`: adding, unreachable and changed hosts,
  terminals and splits, scripts and completion, agents, what does not work remotely, CLI,
  and gotchas.
- `docs/README.md` and `repositories-and-worktrees.md` link to it.

## Tests

- `RemoteTerminalTabTests`:
  - A restored remote leaf reconnects with a plain shell, never a script. It uses the saved
    directory inside the folder, normalized, and otherwise the folder (checked red).
  - A folder without its host profile is not restored.
  - An older leaf decodes without an origin.
- `WorktreeTerminalManagerTests`:
  - A remote folder is saved with its host, and a selected remote folder is the payload's
    selection (checked red).
  - A remote folder that did not load, or that cannot restore, is skipped, and the local
    layout is restored (checked red).
- `AddRemoteFolderFeatureTests`: the flag is on by default and off with `0`.

## Known limits

- At launch, every remote pane of an unreachable host shows its own "did not start" toast.
- A restored pane's directory is the one its session showed when the layout was saved. On a
  macOS host's plain shell, which is never mapped, the pane opens in the folder.
