# Remote projects

## What it is

A remote project is a git repository or a plain folder on another machine that Prowl
reaches over SSH. It shows in the sidebar next to your local repositories. Its terminals,
scripts and agents run on that host. Prowl installs nothing on the host and edits no
startup file there.

Remote projects are on by default. `PROWL_REMOTE_FOLDERS=0` (or `false`, `off`, `no`) in
Prowl's environment turns them off: the menu items go away, and stored remote projects and
their saved layouts stay stored but hidden.

## Adding a remote project

**File › Add Remote Project...**, **Add Remote Project** in the sidebar's add panel, or
**Add Remote Project** in the command palette:

1. Choose a host: one you added before, or a new SSH destination (`host`, `user@host`, or
   an alias from `~/.ssh/config`).
2. Enter the path on the host, or click **Browse…** to choose it from the folders on the
   host. The browser starts at the typed path (or at the home) and fills the path as you
   move. A Git repository has a branch mark. Return, a double-click, → or ⌘↓ opens a
   folder; ← or ⌘↑ goes to the enclosing folder. Browsing connects to the host, but it
   stores nothing until you add the folder.
3. Prowl checks the destination with `ssh -G`, connects, resolves the path with
   `pwd -P`, and checks for git. Then it stores the folder.

Adding a folder is your consent for that host. Prowl keeps a background SSH connection
to it (the side channel) for git state, agent detection and terminal setup. The toolbar
status shows that connection. `PROWL_REMOTE_AGENT_DETECTION=0` turns off every side-channel
connection, and remote projects then cannot load.

The folder's ID is `ssh:<host-profile-uuid>:<path>`. The CLI also accepts
`<alias>:<path>`.

## Unreachable and changed hosts

- **Unreachable host.** The folder stays listed and shows why it is not connected. Prowl
  tries again on its own.
- **Changed host.** When the SSH configuration now reaches another user, host or port, Prowl
  asks before it connects (**Rebind Host** on the folder's row). Rebinding stores the new
  target. Until you answer, the folder pauses.

## Terminals

A tab in a remote project is a local pane that runs `ssh` to the host. It lands in the
folder, in your login shell. Your startup files load once, as in any login. Before it
types the `ssh` line, Prowl stages a small launcher on the host over the side channel
(`~/.cache/prowl/launch/`, removed after use). The pane may show nothing until that
finishes. When the launcher cannot be staged, the tab closes with the reason.

- **Environment.** The shell has `PROWL_WORKTREE_PATH` and `PROWL_ROOT_PATH`, both paths on
  the host, and `LC_PROWL_PANE` (the pane's id). When the host has no terminfo entry for
  the local `TERM` (`xterm-ghostty`), `TERM` is `xterm-256color`, so that tmux and line
  editing work. Prowl installs nothing on the host.
- **Splits.** A split (`⌘D`, `prowl create pane`, a New Split custom command) is a new
  remote pane. It starts where its anchor pane is on the host. Otherwise it starts in the
  last known directory there, and then in the folder.
- **When `ssh` ends.** The pane returns to a local shell. A later `ssh` that you type in
  that pane is your own, and it follows the rules for manual SSH sessions in
  [agent detection](agent-detection.md#remote-agents-over-ssh).
- **Restore.** After a restart, a remote project's tabs and splits come back when you first
  open the folder. They connect again with a plain shell, where they were on the host. A
  script never runs again. An unreachable host never affects your local layout, and the
  folder keeps its saved layout until its panes connect again.

## Scripts and custom commands

- **Scripts run on the host.** Setup scripts, Run Script and custom commands run there as
  the first command of a new remote pane, in your login shell. The local shell never gets
  their text. A `cd`, an export or an activated environment stays at the prompt.
- **Completion.** The launcher reports the script's exit status to Prowl. This drives:
  - Close on Success;
  - the custom command toast;
  - command-finished notifications;
  - `prowl send` waits.

  A script that never ran, for example when a startup file replaced the shell or the
  connection dropped, completes nothing.
- **Missing folder.** When the folder is gone on the host, the script does not run. The pane
  says so and opens in the home folder.
- **In Place custom commands** do not run in remote projects. The focused pane could be the
  local shell, or a password prompt.

## Agents

Agents in remote panes show in Active Agents and in `prowl agents`:

- with the host's alias;
- with no consent panel;
- with their directory on the host.

See [agent detection](agent-detection.md#remote-agents-over-ssh).

## Not available in remote projects

Prowl shows the reason in the control's tooltip, or as a toast:

- diffs;
- Finder and opening in another app;
- workspaces;
- archive scripts;
- Agent Profile launches;
- workflows;
- In Place custom commands.

## CLI

- CLI and workflow error messages still name it a "remote folder" (for example "Workflows
  cannot run in a remote folder yet."). It is the same thing as a remote project.
- `prowl list` gives a remote project's worktrees a `host` object (`profile_id`, `label`).
  Their `path` is a path on the host. Text output shows `label:path`.
- `prowl create tab <alias>:<path> --path <host path>` opens a remote tab. The path is
  checked by its text only, and it must stay inside the folder.
- `prowl send` with a wait resumes when the host's shell reports the command's end (OSC
  133). A host without shell integration gives no answer: use `--no-wait`. While a pane's
  first script runs, the wait resumes on that script's own report.

## Gotchas for agents

- **Paths are on the host.** A remote project's paths are on the host, not on this Mac. Do
  not run local file tools on them.
- **macOS hosts.** On a macOS host, a plain shell session cannot be matched to its pane:
  macOS hides the environment of system binaries. The pane then shows "Agents not
  detected", and a split starts in the folder. An agent, a Homebrew shell or a tmux session
  can be matched.
- **Prowl's typed `ssh` line.** It overrides `RemoteCommand`, `SessionType`,
  `ForkAfterAuthentication` and `StdinNull` from your SSH configuration, so that the
  launcher runs. Forwardings and the agent stay as configured.
