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

A remote folder's saved layout restores when its terminals first open, not at launch.
`applyLayoutSnapshotPayload` keeps it in `pendingRemoteLayouts`, and hands it to the
folder's state as `pendingLayoutSnapshot`. The folder's first `ensureInitialTab` (its view
appears, or the reducer opens it) applies the layout once.

Each remote leaf becomes a new remote pane (`restoreRemoteLeaf`):

- a deferred surface in the recipe's local directory;
- a plain launch with no first command, so a script never runs again (R-9).

Its directory on the host is the saved one when the leaf was saved for the same host and
the directory lies inside the folder. Both checks are by text: `RemotePaths.canonicalPath`
and `RemotePaths.contains`. Otherwise the pane starts in the folder.

A failed restore, such as a missing host profile, opens a plain first tab instead.

Why lazy:

- launch opens no burst of staging commands and `ssh` logins, which could hit sshd's
  `MaxStartups` or authentication prompts;
- an unreachable host never makes the whole restore fail, which would clear the saved
  layout and lose the local tabs.

The saved layout outlives a session in which the folder did not restore.

- `makeLayoutSnapshotPayload` saves each pending layout as it was, even over the folder's
  tabs while their panes still stage. So a quit during staging keeps the saved
  directories, and so do tabs that failed.
- When the folder's first remote pane starts its `ssh` (`onRemoteLaunchStarted`), both the
  manager's copy and the state's copy are dropped. From then on, the live tabs are saved,
  and a later empty open makes a fresh first tab.
- A prune that removes the folder's terminal state also drops its saved layout. This is an
  explicit removal of the folder or worktree. A folder that never loaded has no state, so
  a prune keeps its layout. So a remote folder keeps its layout when:

- its host is unreachable for a whole session;
- remote folders are off (`PROWL_REMOTE_FOLDERS=0`);
- every restored pane fails to stage.

The C3b filter is removed, so the payload saves remote states again, and the selection may
name a remote folder.

### The flag

`RemoteFolders.isEnabled` is now true unless `PROWL_REMOTE_FOLDERS` is `0`, `false`, `off`
or `no` (any case). The menu item, the
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
  - A pending remote layout restores at the folder's first `ensureInitialTab`, once, and
    stages nothing before (checked red).
  - A folder without its host profile is not restored.
  - An older leaf decodes without an origin.
- `RemoteAgentDetectionTests/aRemoteLeafSavesItsHostDirectory`: a remote leaf saves where
  its own session is on the host, and nothing local.
- `WorktreeTerminalManagerTests`:
  - A remote folder is saved with its host, and a selected remote folder is the payload's
    selection (checked red).
  - A remote folder that does not load, or cannot restore, never drops the local layout. Its
    saved layout stays in the next save (checked red).
- `WorktreeTerminalManagerTests`:
  - A layout that is still staging at quit is saved as it was (checked red).
  - A started remote pane replaces the saved layout in both copies (checked red).
  - A removed remote folder drops its saved layout, and one that never loaded keeps it
    (checked red).
- `AddRemoteFolderFeatureTests`: the flag is on by default, and off with `0`, `false` or
  `off`.
- `CommandPaletteFeatureTests`: the global items include Add Remote Folder.

## Known limits

- When a folder opens on an unreachable host, each of its restored panes shows its own
  "did not start" toast. The saved layout stays.
- A folder removed while its host was unreachable (it never loaded, so it had no state)
  keeps its saved layout. Adding it again restores that layout.
- A restored pane's directory is the one its session showed when the layout was saved. On a
  macOS host's plain shell, which is never mapped, the pane opens in the folder.
