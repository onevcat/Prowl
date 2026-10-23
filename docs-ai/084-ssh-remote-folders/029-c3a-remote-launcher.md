# 084.029 — The remote terminal launcher (C3a)

## Context

The plan's "Terminals (D5)" section and decisions D5 and D5a describe how a remote folder
gets a terminal:

1. Prowl stages a launcher on the host over the side channel.
2. Prowl types one line into a local pane: `ssh -t <recipe> -- exec sh <launcher>`.
3. The launcher hands over to the user's interactive login shell.
4. A setup, run or custom script runs as that shell's first command, and its exit status
   comes back as a completion marker.

C3 is three PRs:

- **C3a (this record):** the launcher, its staging on the host, and the completion marker,
  tested with real shells. Nothing calls it yet.
- **C3b:** remote tabs. The typed line, `RemoteLaunchOrigin` on the surface, the tracker with
  the stored recipe and no consent panel, and the marker mapped to `handleCommandFinished`.
  The local OSC 133 finish of the outer `ssh` is ignored.
- **C3c:** remote scripts (setup, run, custom commands), Close on Success, and CLI command
  waiters.

## Change (`App/Sources/Infrastructure/RemoteHost/RemoteLauncher.swift`)

### `RemoteLaunch`

A launch has:

- a nonce of 16 lowercase hex digits, from `makeNonce`, checked by `isValidNonce`;
- a working directory on the host;
- environment variables, which C3b fills with the worktree's `PROWL_WORKTREE_PATH`,
  `PROWL_ROOT_PATH` and `LC_PROWL_PANE`;
- an optional first command.

### Staging (`stagingCommand`, `stagedLauncherPath`)

The staging command runs through `RemoteCommandLane.run`, which uses `sh -s`, so the host
needs no bash. The script and the command travel as arguments.

1. It creates `~/.cache/prowl/launch/<nonce>/` with `umask 077`, so the directory has mode
   0700.
2. It writes `launch.sh`, and `command` when there is a first command.
3. It removes launch directories older than a day (`find -mtime +0`), which are those that
   ssh never ran. This answers the plan's open question about where the launcher lives and
   how it is cleaned up.
4. It prints `PROWL_LAUNCH<tab><absolute path>`.

`stagedLauncherPath(from:for:)` accepts only this launch's own path
(`…/.cache/prowl/launch/<nonce>/launch.sh`). Login output or another line can therefore
never name the script that a pane runs.

The staging command refuses some launches before anything is sent:

- an environment name that is not a shell name;
- a launcher or first command above 100 000 bytes. Each travels as one argument, and Linux
  allows 128 KiB per argument;
- a NUL byte, which fails at `RemoteShellCommand.script()`.

### Launcher (POSIX `sh`)

The launcher first prepares the shell:

0. It checks that it runs from its own launch directory. The check is on the path as
   typed (`/…/.cache/prowl/launch/<nonce>`, from `dirname "$0"`). It is not the resolved
   path, because a symlinked `~/.cache` resolves elsewhere. Otherwise it stops before it
   removes anything: a launcher run as `sh -s` or with a wrong path would see `.` as its
   directory.
1. It `cd`s to the working directory. If the directory is missing, it falls back to the
   home directory.
2. It exports the environment.
3. It finds the user's shell from `$SHELL`, else `zsh`, then `bash`, then `/bin/sh`.

Without a first command, it removes its directory and `exec`s `"$SHELL" -l`. With one, it
hands over per shell:

| Shell | Hand-over | First command |
| --- | --- | --- |
| zsh | `ZDOTDIR` points at a wrapper with all four startup files, then `zsh -i -l`. Each wrapper file runs the user's own file at top level (a function would make its `typeset` declarations local, such as `typeset -U path`) with the user's `ZDOTDIR` in place, then points zsh back at the wrapper. A user `.zshenv` that moves `ZDOTDIR` (the XDG layout) moves the user's directory with it. The wrapper's `.zlogin` restores the user's `ZDOTDIR` for good | A one-time `precmd` hook, added after the user's `.zlogin`, so it runs after the user's own hooks (an instant prompt captures output until its hook ran) and before the first prompt |
| bash | `bash --noprofile --rcfile <wrapper> -i`. The wrapper sources `/etc/profile`, then the first of `~/.bash_profile`, `~/.bash_login`, `~/.profile` | At the end of the wrapper |
| fish | `fish -i -l --init-command 'source $PROWL_LAUNCH_DIR/init.fish'` | `init.fish`, which runs after the user's configuration |
| any other | `"$SHELL" -i -c <command>`, then `exec "$SHELL" -l` | Apart, without the persistent state |

- The first command is sourced (`source` / `.`), so a `cd`, an export or an activated
  environment stays at the prompt.
- Each wrapper clears its injection variables (`PROWL_LAUNCH_DIR`,
  `PROWL_USER_ZDOTDIR[_SET]`) before the first command, so a nested shell never replays it.
- Each wrapper removes the launch directory after the first command.
- **A launch always reports once.** The shell reports a first command that finished in it.
  The launcher runs zsh, bash and fish as a child, not with `exec`, and waits. When the
  shell ends and the launch directory is still there, the first command did not finish in
  the shell. Then the launcher removes the directory and reports the shell's exit status.
  This covers:
  - an `exit` in the first command;
  - an `errexit` failure, such as `set -e` with a failing step;
  - startup files that never ran the command (see the limits below).

  No trap is set, so the user's `EXIT` traps (from the startup files or from the command)
  stay as they are. A subshell that fails under `set -e` while the command goes on is not
  taken for the command's end. An earlier version set `EXIT` traps and a zsh `TRAPZERR`.
  It replaced the user's traps, and the inherited `TRAPZERR` reported a recovered subshell
  failure.

  The cost is one waiting `sh` process per terminal. Ctrl-C at the prompt does not reach it:
  an interactive shell takes the terminal in its own process group (measured on this Mac
  for zsh and bash under `sh`).
- `-i` is explicit. With a TTY it changes nothing, and it lets the tests run without one.

Known limits:

- **zsh hook removed.** A `.zshrc` or `.zlogin` that resets `precmd_functions` after the
  hook was added drops it. Then the first command does not run.
- **zsh `ZDOTDIR` set system-wide.** An `/etc/zshenv` that sets `ZDOTDIR` hides the
  wrapper. So does a login file that `exec`s another program, such as `tmux`. In both
  cases:
  - the first command does not run, and the injection variables stay in that session;
  - the marker comes only when the shell ends, with the shell's exit status.

  C3b must therefore treat a missing marker as "not complete yet", not as a hang.
- **zsh locals.** In zsh, the first command runs inside the `precmd` function, so a
  `typeset` or `local` in the script stays local to it. The user's startup files are not
  affected.
- **Debian-family bash.** bash built with `SYS_BASHRC` reads `/etc/bash.bashrc` even with
  `--rcfile`, and the replayed `/etc/profile` reads it again. Measured in the Debian image:
  one extra read. Removing the replay would lose the login semantics. Most of that file is
  safe to run twice; bash-completion guards its own reload.

### Completion marker

The marker is OSC 7501, which Ghostty already parses and passes to Swift as
`GHOSTTY_ACTION_PROGRAM_STATUS`. No Ghostty change is needed:

```
ESC ] 7501 ; state=done|error:id=prowl-launch/<nonce>/<exit status> BEL
```

- The exit status goes in the id, because an id segment allows digits and `msg` would need
  base64 on the host.
- `state` is `done` for status 0 and `error` for any other status.
- `RemoteLauncher.completion(fromMarkerID:)` parses the id strictly: three segments, a valid
  nonce, and a status of one to three ASCII digits in 0...255.
- C3b maps the marker with the pane's own nonce to the completion. It must consume every
  `prowl-launch/` id before `handleProgramStatus`. Otherwise each marker would stay in the
  program status record store as a finished record with a unique id.

The format was chosen over framed OSC 133 for two reasons:

- the local shell's 133 sequences around the typed `ssh` reach the same surface;
- 133 carries no nonce to Swift.

## Tests (`RemoteLauncherTests`)

- **Real shells on this Mac** (zsh, bash 3.2, bash 5; fish where installed), in a temporary
  home whose startup files log each load:
  - the first command runs once in the user's shell;
  - its `cd` and export stay at the prompt;
  - Unicode and quotes arrive intact;
  - the startup files load once, and a nested shell reloads them without the command;
  - the marker reports success once;
  - the launch directory is gone.
- **zsh syntax**: `${(U)value}` runs in zsh, with quotes, `$` and backquotes intact.
- **A failing first command** reports its status as `error`, and the shell stays.
- **A plain shell** starts in the working directory, or in the home directory when the
  directory is missing. It sends no marker and removes its files.
- **Staging** removes a launch directory older than a day, and creates its own with mode
  0700.
- **zsh order and XDG**: the first command runs after a `precmd` hook that the user's
  `.zshrc` adds, and a `~/.zshenv` that moves `ZDOTDIR` still loads `.zshrc` and `.zlogin`
  from there once (checked red with the hook added first).
- **Outside its directory**: a launcher outside its launch directory removes nothing and
  starts nothing (checked red without the check). A symlinked `~/.cache` still launches
  (checked red with the resolved path).
- **zsh top-level files**: a `typeset -U path` change and an associative array from `.zshrc`
  stay for the first command and the prompt (checked red with a function around the
  source).
- **Ending the shell**: a first command that ends the shell with `set -e` and a failing
  step, or with `exit 3`, reports its status once and removes its directory. This runs in
  zsh, bash 3.2 and bash 5 on this Mac, and with `exit 3` in fish, bash, zsh and dash in
  the container.
- **User traps**: in bash, an `EXIT` trap from `.bash_profile` runs at a normal end, after
  `exit 3` and after an `errexit` failure; an `EXIT` trap that the first command sets runs
  too. Each case reports once (checked red with the trap version).
- **Subshell failure**: in zsh, `(set -e; false)` followed by more commands reports once,
  `done` with status 0, after the rest ran (checked red with the `TRAPZERR` version).
- **No error at exit**: nothing prints "not found" at exit after a normal first command.
- **Strict parsing**: the nonce and the marker id are checked strictly (a signed, hex or
  out-of-range status is refused). A bad nonce, a bad environment name, an oversized
  script, a NUL byte and another launch's path are refused.
- **Runner**: the test runner reads output on another thread and kills a run that passes
  its deadline, so a regression fails instead of hanging the suite.
- **Opt-in, Linux shells**: `PROWL_LAUNCHER_DOCKER_IMAGE` names an image with fish, bash, zsh
  and dash. Each works; dash takes the other-shell path. This was run with a local Debian
  image that has these packages (fish 4.0.2, bash 5.2, zsh 5.9).
- **Opt-in, a real host**: `PROWL_REMOTE_LANE_HOST` stages through the side channel and runs
  the launcher over a plain `ssh` with the host's login shell. This was run against `mini`
  (macOS, zsh).
