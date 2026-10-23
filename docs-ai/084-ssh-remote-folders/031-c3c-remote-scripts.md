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
  - **In Place** types into the focused pane, which is the host shell in a remote pane. It
    gets no completion, as before.
  - **New Split** is refused with the `terminalSplit` reason (C4). The toolbar and the
    palette leave it out for a remote folder.
- **Setup script.** A new remote worktree's setup script runs in its first tab. The
  `terminalScript` feature is removed, and so are its gates in AppFeature, the detail view,
  the palette and the terminal state.

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
  before the main thread handles the marker.
- **No marker.** A first command that sent no marker before its `ssh`'s finish did not run
  to its end. The launcher reports every command that started (C3a), so this means the
  startup files replaced the shell, or the connection dropped. It completes nothing:
  - no toast and no Close on Success;
  - no notification;
  - the CLI waiter resumes with no status.

  The decision is taken at the `ssh`'s finish, which comes in the terminal stream after any
  marker. A probe never takes it. When no probe saw the `ssh`, the decision comes at the
  next probe after the finish.
- **Later finishes.** As in C3b, the outer `ssh`'s finish never completes anything. So a
  later `ssh` exit after a failed script reports no success.

### CLI

- `create tab` and the legacy `tab create` open remote tabs. The `--path` of a remote folder
  is a host path. It is normalized by its text only (`normalizedHostPath`: `.`, `..`, repeated
  slashes), because a local normalization could resolve `/private` or a symlink on this Mac.
  It must stay inside the folder.
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
  - A split is refused.
- CLI: `create tab` and `tab create` check the host path by its text, and a path outside the
  folder is refused. `normalizedHostPath` is tested on its own.
- Reducer:
  - Run Script and a tab custom command run in a remote folder; a split custom command shows
    the split reason and sends nothing.
  - A created remote worktree runs its setup script.
  - The palette keeps Run Script and tab custom commands, and leaves split ones out.

## Known limits

- A first command in a split comes with C4.
- An In Place custom command in a remote pane has no completion, because the host shell gets
  it as typed text.
- A suspended `ssh` ends the session for Prowl (C3b). A script still running in it is never
  completed.
