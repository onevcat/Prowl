# 084.016 — The remote command lane (B1)

## Context

The "Remote command lane" section of [000-plan.md](000-plan.md) describes B1. B3's
remote host runs git, `wt` and a polling command on the host, and it needs more than
L0 provides. Today `RemoteConnectionOwner` runs only the probe, with a 5 s and 256 KiB
budget. `RemoteShellCommand` (docs-ai 082 C5) existed, but no production code called it.

## Change

All of this is unused until B3. Exposure: none.

### Command lane on `RemoteConnectionOwner`

The lane is an extension in `RemoteConnectionOwner.swift`, so its state stays private to
the actor. `RemoteScript` and `RemoteOutputLineSplitter` live in `RemoteScript.swift`.

- **The same connection.**
  - Each lane command runs as its own `ssh` process on the owner's shared connection:
    `ControlMaster=auto` with the probe's private `ControlPath` and `ControlPersist`.
  - The remote command is a fixed word list (`sh -s` or `bash -s`). The work travels on
    stdin, so the remote login shell (fish, for example) never parses data (G7).
- **Budgets.**
  - `RemoteCommandLimits.commandLane` sets a 30 s deadline, 8 MiB of output and 64 KiB of
    errors.
  - `RemoteCommandLimits.longRunning` sets a 600 s deadline. `stream` uses it by default,
    because a worktree creation checks out and copies files.
  - At most `Configuration.maxConcurrentCommands` (4) lane commands run at once. Further
    commands wait in order. `sshd` allows ten sessions per connection by default, and the
    probe needs one.
  - A cancelled waiter leaves the queue at once and fails without connecting.
- **Shutdown.** `shutdown()` closes the lane before `-O exit`. Queued commands and later
  commands fail with `launchFailed` and do not start `ssh`; such an `ssh` would create a new
  master that outlives the owner. Commands in flight end with the shared connection.
- **`run(_ RemoteShellCommand)`** sends `command.script()` to `sh -s`.
- **`run(_ RemoteScript)` and `stream(_ RemoteScript, onLine:)`** run a bundled script
  with `bash -s`, such as the bash 3.2 compatible `wt`. The stdin is built like this:
  1. `cd` to the working directory, or exit with status 97;
  2. `export PATH`;
  3. `set -- <arguments>`;
  4. the script text inside a function, which bash parses as a whole before it runs it;
  5. a call of that function with stdin from `/dev/null`.

  So the arguments never meet the login shell, and a command in the script that reads
  stdin cannot consume the rest of the script.

  This replaces the plan's `bash -s -- <args>`. That form passes the arguments in ssh's
  command string, which the login shell parses.
- **Line streaming.**
  - `RemoteCommandRunner` gets `executeStreaming`. The live runner hands each chunk of
    output and of error output to a handler as it reads it. git and `wt` report progress
    on stderr; `wt` sends git's stdout to `/dev/null`.
  - `stream(_:onLine:)` reports `(RemoteOutputStream, line)`, with one
    `RemoteOutputLineSplitter` per pipe. The order between the two pipes is not fixed.
  - The final line needs no newline. A line that is not UTF-8 is decoded as Latin-1, so it
    never turns empty.
  - Runners built with the original initializer (the test fakes) deliver each whole output
    as one chunk at the end.
  - Only a streaming caller pays for a chunk copy.
- **Login `PATH`.**
  - `loginPath()` runs the user's shell as a login shell. Like the local
    `ShellClient.loginShellInvocation`, it also sources the interactive rc file (`~/.zshrc`,
    `~/.bashrc`, fish `config.fish`), where Homebrew, mise or nvm often extend `PATH`. It
    uses zsh (or bash) for a shell it cannot drive.
  - The shell prints `PATH` between two U+0001 markers, so a banner from the login files
    cannot be taken for it. fish colon-joins `$PATH` in quotes.
  - The value is read once per owner, and concurrent callers share that one read. A
    failure is kept too, so a broken profile does not cost every command another login.
  - Lane commands export this `PATH`, unless the command sets its own. Without a value,
    commands keep the default `PATH` of a non-login session.
- `SSHSideChannel.scriptArguments` takes the remote command as a parameter. The default is
  `sh -s`, which the probe uses.

### Leases

- Folder users take their owner from `RemoteConnectionRegistry` with `acquire` and
  `release`, as L0 panes do. B1 adds no second owner and no second lease count.
- A folder and the panes on the same `ConnectionKey` share one connection, and `-O exit`
  still runs only on the last release.
- B3 holds one lease per remote repository host while the repository is loaded.

## Tests

`RemoteCommandLaneTests`:

- **The `bash -s` input, run by the local `/bin/bash`:**
  - arguments with spaces, quotes and `$` arrive unchanged;
  - the working directory is applied;
  - a `cat` in the script reads `/dev/null`, and the line after it still runs;
  - the login `PATH` is exported;
  - a missing directory exits with 97;
  - a NUL byte is rejected.
- **Login `PATH`:**
  - parsing between the markers, with a banner around them;
  - the script, run by the local `/bin/sh`, yields a `PATH`.
- **The lane on the owner, with a fake runner:**
  - `sh -s` and `bash -s` over `ControlMaster=auto`;
  - the login `PATH` is resolved once and exported first;
  - concurrent callers share one login `PATH` read, and a failure is kept;
  - at most two commands run at once with a limit of two, checked with a gate (no sleeps),
    and all slots are released;
  - a cancelled waiter leaves the queue without connecting;
  - after `shutdown`, the lane starts nothing;
  - streamed chunks of both pipes become tagged lines.
- **The live runner** delivers output chunks before the command exits, and error output
  chunks too.
- **Opt-in real host:** `TEST_RUNNER_PROWL_REMOTE_LANE_HOST=mini xcodebuild test …` runs:
  - the login `PATH`;
  - `git --version`;
  - a script with arguments and a working directory;
  - streaming of output and error output lines with a pause between them;
  - `shutdown`.

  This passed against `mini` (macOS, zsh) on 2026-10-23. Without the variable, the test is
  skipped.
