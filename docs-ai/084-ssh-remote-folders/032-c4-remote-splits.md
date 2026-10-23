# 084.032 — Remote splits and the remote directory (C4)

## Context

C3b and C3c ([030](030-c3b-remote-tabs.md), [031](031-c3c-remote-scripts.md)) refuse splits
in remote folders through a `terminalSplit` feature, because a split would be a local
shell. The plan's C4 row adds:

- a tracker accessor for the directory on the host;
- remote splits;
- the remote agent directory.

The plan's "Terminals (D5)" section says: a split asks for a fresh probe, then falls back
to the last known directory, then to the worktree root. Agent entries use this directory
for remote origins, which also fixes the local directory that L0 reports for agents behind
a manual `ssh`.

## Change

### The directory on the host (`RemotePaneTracker`)

- `foregroundWorkingDirectory` gives the directory of the foreground process of the pane's
  own session in the latest snapshot. Inside tmux, it is the client's active pane. A tmux
  client whose server Prowl cannot read hides where the user works, so it gives none. A
  failed or unmapped snapshot keeps the last known directory. It is nil when no snapshot
  mapped the session, for example on a macOS host whose platform shell hides
  `LC_PROWL_PANE`.
- `agentWorkingDirectory` gives the bound remote agent's own directory, or else the
  foreground one.
- `refreshedWorkingDirectory(timeout:clock:)` asks the connection for a fresh snapshot.
  Within the timeout, it returns the directory from that snapshot; otherwise, the last
  known one.
  - Each caller has its own waiter and its own timeout.
  - A waiter resumes only on a snapshot that started after its request. A cadence probe
    that was already running may predate the user's last `cd`.
  - A waiter also resumes at its timeout, or when the tracker retires.

### Remote splits (`createSplit`)

In a remote folder, `createSplit` makes a new remote pane, as `createRemoteTab` makes a tab:

- a deferred local surface in the recipe's directory;
- its own launch and `RemoteLaunchOrigin`;
- the input as the launch's first command, never typed into a local shell.

This covers the Ghostty split binding, `prowl create pane`, and New Split custom commands
with their Close on Success.

The split's directory on the host is resolved before staging (`remoteSplitDirectory`):

1. a working-directory override (a host path);
2. when the anchor's own `ssh` session runs, its tracker's directory after a fresh
   snapshot, within `splitDirectoryTimeout` (1 s), or the last known one;
3. the folder.

A missing host profile opens no split and tells the user (`SplitCreationError.remoteFolder`).

- A split that cannot stage closes alone, without an undo record. The tab and its other
  panes stay.
- A split closed while it waits for its launcher is not kept for Undo. Before C4, such a
  pane was always a tab's only pane; now the single-pane close path checks it too.
- A split closed during the directory wait stages nothing on the host: the launch task
  checks for cancellation after the wait.

`terminalSplit` is removed. The New Split custom command maps to `terminalTab`. In Place
commands stay refused (C3c).

### The remote agent directory

`activeAgentWorkingDirectory` returns the tracker's `agentWorkingDirectory` for an agent
whose process is remote, before the pane's OSC 7 or local launch directory. The Active
Agents entry and `prowl agents` then name the host's project. The same holds for agents
behind a manual `ssh` (L0).

That directory is a path on the host, so it never resolves against this Mac's worktrees.
`ActiveAgentEntry.localWorkingDirectory` is nil for a remote agent. `remoteWorktreeID`
resolves the agent only to its own pane's remote folder, when the directory lies inside
it; otherwise the row names the directory's last component. A host with the same layout as
this Mac (such as mini with `/Users/onevcat/…`) would otherwise show the local repository.

Shared helpers: `remoteLaunch(surfaceID:workingDirectory:firstCommand:)`,
`localDirectory(for:)`, and `startRemoteLaunch(…, resolveWorkingDirectory:)`, which
resolves the directory in the staging task.

## Tests

- `RemoteTerminalTabTests`:
  - A remote split is a new remote pane. It has its own launch and pane id, its input is
    the first command, and the local shell gets only the `ssh` line. Without a known anchor
    directory, it starts in the folder.
  - A split without its host profile opens nothing and tells the user.
- `RemoteAgentDetectionTests`:
  - A remote agent's directory is the host's (checked red).
  - A split starts where its anchor is after a fresh snapshot, and in the last known
    directory at the timeout, with a `TestClock` (checked red).
- Reducer and palette: split custom commands run in remote folders; In Place commands do
  not.
- A split that cannot stage closes alone (checked red). A split closed while staging is not
  kept for Undo (checked red). A failed snapshot keeps the last known directory (checked
  red). A remote agent's directory resolves only to its remote folder
  (`RemoteAgentPresentationTests`, checked red).

## Known limits

- A macOS host maps no plain shell session (hidden environment), so a split there starts in
  the folder unless an agent or tmux makes the session known.
- A split waits up to 1 s for the fresh snapshot before staging.
