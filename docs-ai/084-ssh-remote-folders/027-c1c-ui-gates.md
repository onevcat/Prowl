# 084.027 — UI gates for remote folders and the folder connection status (C1c)

## Context

A4a ([007](007-a4a-capability-enforcement.md)) enforces the location rules at the reducer
and the launch boundary, and leaves the UI to A4b: disabled controls with the reason as
tooltip, palette filtering, and the view-level Finder and Copy Path actions. A4b moved to
C1, so that a real remote folder exists for the toolbar's visual check. The plan's
"Consent (D2)" also says that the toolbar side-channel status shows folder connections.
C1a ([025](025-c1a-add-remote-folder.md)) and C1b ([026](026-c1b-unreachable-and-rebind.md))
add the folders and their host state. This is the last part of C1.

## Change

All of it shows only for a remote folder, which exists only with `PROWL_REMOTE_FOLDERS=1`.

### Disabled controls with the reason

| Control | Remote folder |
| --- | --- |
| Toolbar Open button | Enabled, with the reason as tooltip ("Opening in an app is not available…" or "Finder is not available…"); a click shows it as a toast (`OpenWorktreeAction.repositoryFeature`, also used by the reducer). A disabled toolbar button shows no tooltip |
| Toolbar Open menu: the app items | Disabled, with the reason as tooltip |
| Toolbar Open menu: Copy Path | Enabled; copies the host path |
| Sidebar menus (worktree and repository): Reveal in Finder | Shown disabled with the reason; before, it was hidden |
| Worktree menu: Show Diff, Show Outgoing Changes | Disabled with the reason |
| Worktree menu: New Terminal Tab | Disabled with the reason (found in the visual check) |
| Worktree row change counts | Not a button; the tooltip gives the reason and the untracked-file note |
| Agents popover: Agent Profile rows | Disabled and dimmed, with the reason as subtitle |
| Quick Launch (toolbar) | Enabled, with the reason as tooltip; a click shows it as a toast (A4a) |
| Agents popover: workflow rows | Not listed. Workflows run in local worktrees only (A4a), now the `RepositoryFeature.workflow` case that the palette, the popover and the palette refresh read |

### Hidden terminal commands

A remote folder opens no terminal until C3. Before this change, Run Script and a custom
command created a local shell tab and ran the script there. That is a real risk: the
user's script ran on this Mac in another directory.

- The reducer now refuses both with the reason (`.runScript`, `.runCustomCommand`).
- The toolbar shows no Run button or custom commands for a remote folder. The detail
  pane already says "Terminals cannot open in remote folders yet." (B3d).

### Command palette

For a remote target, the palette leaves out the items below. Reveal in Finder follows the
selected worktree, as its action does; the others follow the action target.

- Reveal in Finder;
- Run Script and Stop Script;
- custom commands;
- Agent Profile launches;
- workflow runs.

Copy Path, navigation, Rename Branch and the pull request items stay.

### Folder connection in the toolbar status

`RemoteFolderToolbarStatus` shows the selected worktree's host:

- the alias, with "Connected", "Not answering" or "SSH configuration changed";
- an orange symbol when the host does not answer as it should.

Only a remote git folder with a known host profile shows it. A plain folder is not polled
and holds no connection (B3f), and a folder without its profile cannot connect.

A click opens a panel. It tells what the background connection does. It reads the
folders' worktrees and changes at the cadence constants of B3f, which the copy reads
(10 s for the selected folder, 45 s for the others, at most every 5 minutes while the host
does not answer). For a changed configuration, the panel has **Rebind Host…**, the C1b
prompt.

In `ToolbarStatusSelection`, a host that does not answer as it should comes after the
focused pane's side channel (082 L0) and before the pull request. A connected folder comes
after the pull request, so a folder with a pull request shows its checks. A pane of a
remote folder (C3) shows its own channel first.

### Not changed

- **Finder and Copy Path stay in the views.** A4a planned to route them through the
  reducer, so that a reducer would see them. Each view now checks `availability(of: .finder)`
  before it calls `NSWorkspace`. The view call is the only path, so the check enforces the
  rule where the call is, and a reducer action would add no gate.
- **Repository Settings keep every section for a remote folder.** The setup, run and
  archive scripts and the custom commands are stored settings of the folder, and C3 runs
  them on the host. The kind still decides which sections show.
- **Active Agents rows.** The Finder items of a remote L0 agent (082) stay hidden: its
  directory is the local `ssh`'s, not the host's.

## Verification

Tests (`RemoteFolderUIGateTests`):

- the open actions map to their features;
- the toolbar status of a remote folder follows its host (connected, unreachable, needs a
  rebind); a local worktree, a plain remote folder and a folder without its profile have
  none; the order against the pane channel holds;
- the palette leaves out Finder, scripts, custom commands, Agent Profiles (with an enabled
  profile, so the profile gate is what removes them) and workflows for a remote target
  (checked red);
- Run Script and a custom command in a remote folder show the reason and send nothing
  (checked red).

The disabled controls are view code. Their visual check needs an unlocked screen with a
real remote folder. That check is part of the C1 row and is still open: the screen was
locked during this slice (see the PR).
