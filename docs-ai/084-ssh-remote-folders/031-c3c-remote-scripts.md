# 084.031 — Remote scripts (C3c)

## Context

C3b ([030](030-c3b-remote-tabs.md)) opens remote tabs with no first command, keeps scripts
behind a `terminalScript` gate and keeps the CLI `create tab` refused. The plan's C3 row
gives C3c:

- remote scripts: setup, run and custom commands;
- Close on Success;
- CLI waiters.

Acceptance criterion R-10 asks, on a host without shell integration:

- a custom command `true` with Close on Success closes its pane, and `false` stays open with
  a failure;
- the success notice fires once;
- a CLI command waiter completes while the remote shell stays connected;
- a later `ssh` exit after a failed script reports no success.

## Change

### Scripts run as the launch's first command

`createRemoteTab` takes the tab's input as `RemoteLaunch.firstCommand`, and the local pane
gets only the `ssh` line. The input is the same text as a local tab's: the trimmed script
plus a newline. The setup script and the command are joined in that order, as locally. So:

- **Run Script** opens the RUN SCRIPT tab in the remote folder. Its run state and Stop work
  as locally: Stop closes the tab, and the `ssh` with it.
- **Custom commands**:
  - **New Tab** runs in a new remote tab, with Close on Success and the success toast from
    the launch marker.
  - **In Place** is refused in a remote folder (new feature `inPlaceCommand`, "In Place
    commands do not run in remote folders yet."). The focused pane can be the local shell
    after the `ssh` ended, or a password prompt while it connects, and the command text
    would reach it.
  - **New Split** is refused with the `terminalSplit` reason (C4).

  `UserCustomCommandExecution.repositoryFeature` maps each execution to its feature.
  `applyWorktreeUserSettings` leaves out the commands that the action target cannot run, so
  the toolbar, the palette, the menu and the hotkeys never offer them. The reducer still
  refuses them.
- **Setup script.** A new remote worktree's setup script runs in its first tab. The
  `terminalScript` feature is removed, and so are its gates in AppFeature, the detail view,
  the palette and the terminal state. A remote tab consumes the setup script
  (`onSetupScriptConsumed`) only once its launcher is staged. A staging failure, or a tab
  closed while staging, keeps it pending for the next tab.
- **A folder that is gone.** The launcher no longer falls back to the home folder for a
  first command. When `cd` to the working directory fails, it prints "prowl: <dir> is not
  available on this host", and the first command reports `error/1` without running. The
  shell then opens in the home folder.

The launcher sources the script (C3a), so a `cd`, an export or an activated environment
stays at the prompt, in the user's login shell.

### Completion

- **Waiters.** While a pane's first command has not reported, a CLI waiter waits for its
  marker (`remoteLaunchHoldsWaiters`). A remote shell's OSC 133 is not the script's end.
  Without a first command, a waiter resumes on any finish, as in C3b.
- **The marker.** The pane's own marker completes the first command once:
  - the waiter gets the status;
  - the custom command toast fires on 0;
  - Close on Success closes the tab on 0;
  - the long-command notification may fire.

  The marker counts even after a probe saw the `ssh` exit: a script that ends with
  `exit` prints its marker just before the `ssh` ends, and the probe can see the exit
  before the main thread handles the marker. Its duration counts from the moment the pane
  started its `ssh`, after staging.
- **No marker.** A first command that sent no marker before its `ssh`'s finish did not run
  to its end. The launcher reports every command that started (C3a), so this means the
  startup files replaced the shell, or the connection dropped. It completes nothing:
  - no toast and no Close on Success;
  - no notification;
  - the CLI waiter resumes with no status.

  The decision starts at the `ssh`'s finish, which comes in the terminal stream after any
  marker, and waits `remoteMarkerGrace` (1 s, `remoteLaunchClock`). A remote shell's own
  OSC 133 can arrive after the `ssh` exited and just before the marker, and the marker must
  still count. A probe never starts the decision. When no probe saw the `ssh`, the decision
  starts at the next probe after the finish.
- **During the grace.** A local command that finishes during the grace completes nothing.
  The script's toast and Close on Success stay with the script, until its marker or the
  abandonment.
- **Undo.** A remote pane brought back by Undo waits for no marker any more. While the pane
  was closed, its marker found no origin and was dropped, and its reactions went with the
  close, so the restored origin counts as completed. A CLI waiter for that first command
  resumes then with no status, so it never takes a later command's status.
- **A suspended `ssh`.** When the `ssh` is suspended (still running) and no longer in the
  foreground, its first command completes nothing at once. A later local command then does
  not take its toast or its Close on Success, and a waiter does not wait forever.
- **Later finishes.** As in C3b, the outer `ssh`'s finish never completes anything. So a
  later `ssh` exit after a failed script reports no success.

### CLI

- `create tab` and the legacy `tab create` open remote tabs. The `--path` of a remote folder
  is a host path. It is normalized by its text only (`RemotePaths.canonicalPath`: `.`, `..`,
  repeated slashes), because a local normalization could resolve `/private` or a symlink on
  this Mac. It must stay inside the folder. Both handlers share one check, `allowedTabPath`.
- The `prowl` client sends an absolute `--path` as typed, without its trailing slash. It
  resolves only a relative one against its directory. The app normalizes a local path.
- The remote tab's working directory is that host path (`createRemoteTab` reads the
  override as a host path); without one, it is the folder.
- `prowl send` with a wait into a remote pane resumes on the host shell's OSC 133. During a
  first command, it resumes on the marker. A host without shell integration answers no wait
  for a typed command: use `--no-wait`.

## Tests

- `RemoteTerminalTabTests`:
  - A run script is the launch's first command, byte for byte (a zsh `${(U)…}` payload), and
    never reaches the local shell (checked red).
  - The setup script and the command join, and a host directory is the launch's working
    directory.
  - A waiter in a script pane waits for the marker (checked red).
  - A script without a marker completes nothing, and its waiter gets no status (checked red).
  - A marker after the probe saw the `ssh` exit still counts.
  - A marker right after a remote finish with the `ssh` gone still counts within the grace
    (checked red without it).
  - A local finish within the grace takes none of the script's reactions (checked red).
  - Undo brings back a script pane that waits for no marker, and the waiter for its script
    gets no status (checked red).
  - A suspended `ssh` abandons its script (checked red).
  - The setup script is consumed only once staged (checked red).
  - A split is refused.
- `RemoteLauncherTests/aMissingFolderRunsNoScript`, in each local shell: `error/1`, the
  script does not run, the message, the shell in the home folder (checked red).
- CLI: `create tab` and `tab create` check the host path by its text, and a path outside the
  folder is refused. `allowedTabPath` is tested on its own. The client sends an absolute
  path as typed (`ProwlCLIIntegrationTests`).
- Reducer:
  - Run Script and a tab custom command run in a remote folder. A split and an In Place
    custom command each show their reason and send nothing.
  - A created remote worktree runs its setup script.
  - The palette keeps Run Script and tab custom commands, and leaves split ones out.

## Known limits

- A first command in a split comes with C4.
- An In Place custom command in a remote pane has no completion, because the host shell gets
  it as typed text.
- A suspended `ssh` ends the session for Prowl (C3b). A script still running in it
  completes nothing.
- A relative `--path` resolves against the local directory, so for a remote folder only an
  absolute host path is useful.
