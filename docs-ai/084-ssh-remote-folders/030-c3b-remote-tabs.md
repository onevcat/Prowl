# 084.030 — Remote tabs (C3b)

## Context

C3a ([029](029-c3a-remote-launcher.md)) added the launcher, its staging and the completion
marker, with no caller. The plan's "Terminals (D5)" section and the C3 row give C3b:

- the tab of a remote folder;
- the typed `ssh` line;
- `RemoteLaunchOrigin` on the pane, so the agent tracker uses the stored recipe, asks for no
  consent and shows the profile alias;
- the marker mapped to the command completion, and the local OSC 133 finish of the outer
  `ssh` ignored.

Scripts (setup, run, custom commands), Close on Success and CLI waiters come with C3c.
Splits come with C4, and layout restore with C5.

## Change

### The tab (`WorktreeTerminalState.createRemoteTab`)

Every tab passes `createTab(_ creation:)`. For a remote folder, that function no longer
refuses (the C1c backstop). It branches to the remote tab:

1. It reads the host profile (`RemoteTerminalStager.profile`). When the profile is
   missing, no tab opens and the user gets the reason.
2. It inserts the tab with a deferred surface (`defersSurfaceCreation`), as the Agent
   Profile launch does. The local working directory is the recipe's `workingDirectory`, so
   relative `-F` and `-i` options resolve as when the host was added; without one, it is
   the home folder. The local pane gets no `PROWL_WORKTREE_PATH` or `PROWL_ROOT_PATH`:
   those paths are on the host.
3. It records the `RemoteLaunchOrigin` and stages a `RemoteLaunch` on the host (through
   `RemoteCommandLane.leased`). The launch has the remote folder as its working directory,
   `PROWL_WORKTREE_PATH`, `PROWL_ROOT_PATH` and `LC_PROWL_PANE` (the pane id), and no first
   command.
4. When staging returns, the pane gets its input (`GhosttySurfaceView.setInitialInput`,
   which works only before the surface exists), and the surface is created. A failure
   closes the tab without an undo record, because nothing ran in it. The user then gets a
   toast through the `remoteTerminalFailed` event: "The terminal on <alias> did not start:
   <reason>."

A tab closed while its launcher is staged never starts. The staging task is cancelled, and
a late result finds no surface. Undo does not keep a pane that has no surface yet
(`surfaceCreationArmed`).

A creation with a first command (a script) is refused, so a script never runs in a local
shell. The setup script is dropped for a remote folder: in `createTab`, in `ensureInitialTab`,
and in the reducer's `newTerminal` and `worktreeCreated`.

### The typed line (`RemoteTerminalLine.typed`)

The line is ` /usr/bin/ssh -t <options> -- <destination> exec sh <launcher>` plus a
newline:

- `/usr/bin/ssh` is the binary that the side channel resolves with. It also bypasses an
  `ssh` alias or function.
- The leading space keeps the line out of the history in shells that ignore such lines
  (zsh `HIST_IGNORE_SPACE`, bash `ignorespace`, fish).
- An argument made of safe characters (`[A-Za-z0-9@%+=:,./_-]`) is typed bare. Any other
  argument is single-quoted. A backslash or a control character is refused, because fish
  reads `\\` and `\'` inside single quotes. The launcher path must be safe as it is,
  because it is also a word of the remote command.

### The origin (`RemoteLaunchOrigin`)

Each remote pane keeps `hostProfileID`, `alias`, `recipe`, `nonce`, whether the launch has a
first command, the launch time, and the pane's `ssh` once a probe saw it. Undo keeps it
with the pane (`TerminalRetainedSurfaceContext`).

- **Agent tracking.** The first foreground `ssh` that a probe sees is the pane's own. While
  it is in front:
  - no consent is asked, because adding the folder was the consent (D2);
  - `PROWL_REMOTE_AGENT_DETECTION=0` still turns detection off;
  - the tracker uses the stored recipe, not the parsed command line;
  - the pane label and `RemoteAgentContext.hostLabel` (CLI `agents` `remote.host`, Active
    Agents) show the alias.
- **The end of the session.** When that `ssh` leaves the foreground, the session has
  ended. A later `ssh` in the same pane is the user's own and follows L0 (consent, parsed
  command line, `user@hostname`).

### Completion

- **The marker.** `handleProgramStatus` first consumes every OSC 7501 report whose id starts
  with `prowl-launch/`, so a marker is never a program status. The pane's own marker, with
  its nonce and for a launch with a first command, completes the command once:
  - the CLI waiter;
  - the custom command toast;
  - Close on Success;
  - the long-command notification, with the time since the launch.

  `handleCommandFinished` is split into `resumeCommandFinishedWaiter` and `completeCommand`
  for this. C3b launches have no first command, so the path waits for C3c. It is tested
  with an origin that has one.
- **The local finish.** In a remote pane, a local "command finished" (OSC 133) completes
  nothing while the session lasts. It is the `ssh` ending, or a remote shell's own OSC 133
  passing through. The detection hooks still see it. The first finish after the pane's
  `ssh` exited (`kill(pid)` start-time check) ends the session. So does the first finish
  of a pane whose `ssh` no probe saw, such as an authentication failure at once. After
  that, the pane is a local shell, and its commands complete as in any pane.

### What else changes

- `RepositoryFeature.terminalTab` is available for remote folders. A new
  `terminalScript` feature ("Scripts and custom commands do not run in remote folders
  yet.") now gates Run Script, custom commands, the palette's script items and the setup
  script.
- The sidebar's New Terminal Tab sends `createTab` for a remote folder; the tab starts in
  the remote folder.
- **Splits** in a remote folder fail with `SplitCreationError.remoteFolder` (C4). This covers
  the Ghostty binding, the CLI and Agent Profile splits.
- **Layout.** A remote folder's tabs are not saved, and a saved layout is not applied to a
  remote folder. Saving skips remote states, because a nil worktree snapshot would drop the
  whole layout. A restored leaf would be a local shell until C5.
- **CLI.**
  - `create tab` keeps refusing a remote folder until C3c, with "The CLI cannot open tabs in
    remote folders yet.".
  - A remote folder with a pane resolves like any worktree.
  - A remote folder without one gets "Worktree '…' is a remote folder with no open
    terminal.".

## Tests

- `RemoteTerminalTabTests`:
  - The typed line after staging: the quoting and the launch environment. The local pane
    has no host paths and starts in the recipe's directory.
  - A staging failure closes the tab and gives the message. A tab closed while staging never
    starts and leaves no undo record. A missing profile opens no tab.
  - A script and a split are refused.
  - The marker completes once (CLI waiter and custom command). Other markers are ignored, and
    no marker reaches the program status store (checked red without the consumption).
  - The `ssh` finish completes nothing, and later local commands do (checked red). An unseen
    `ssh` takes the first finish.
  - No layout is applied to a remote folder.
  - The typed line quotes options and refuses backslashes, control characters and unsafe
    launcher paths.
- `RemoteAgentDetectionTests`:
  - A remote folder pane uses the stored recipe without consent and shows the alias. A later
    `ssh` asks (checked red with the consent path).
  - The kill switch still applies.
- Reducer: New Terminal and the sidebar open a remote tab without the setup script. Scripts
  and custom commands give the new reason.

## E2E (isolated Debug instance, remote folder on mini)

All PASS:

- Selecting the remote folder opened a remote tab. Its pane typed the line and reached the
  host's zsh in `/private/tmp/prowl-c1-fx/app`. `PROWL_WORKTREE_PATH`, `PROWL_ROOT_PATH` and
  `LC_PROWL_PANE` (the pane id) were set, and `PROWL_LAUNCH_DIR` was unset.
- `claude` on the host appeared in `prowl agents` as `correlated`/`probed` with
  `remote.host` `mini`, and in Active Agents as "mini". The toolbar showed "mini · Agent
  detection on", and no consent was asked.
- `exit` returned the pane to the local shell ("Connection to mini closed."). After that,
  `prowl send --capture` completed with exit 0: local finishes complete again.
- ⌘T opened a second remote tab. ⌘D opened no split.
- A closed remote tab came back with Undo (⌘Z) with its live session.
- The host's launch directory was gone after each launch.

## Known limits

- **Agent project path.** An agent's project path in a remote pane is the local working
  directory (the home folder) until C4 gives the pane its remote cwd.
- **Status without an agent.** A plain zsh on a macOS host shows "Agents not detected":
  macOS hides the environment of platform binaries, so `LC_PROWL_PANE` does not correlate
  (082 L0). An agent correlates.
- **No progress indicator.** A tab shows an empty pane while its launcher is staged.
- **Suspending `ssh`.** Suspending the `ssh` (`~^Z`) ends the session for Prowl: when it
  comes back to the foreground, it is treated as the user's own `ssh`.
- **Remote OSC 133 before the first probe.** A remote shell's OSC 133 that arrives before
  the first probe sees the `ssh` is taken for its finish.
