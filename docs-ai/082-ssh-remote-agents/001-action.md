# 082 — SSH Remote Agents: Action Log

The outcome of [000-plan.md](000-plan.md), slice by slice. Each row names the PR; the
sections below record what shipped and what differs from the plan.

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-17 | S1: typed process references (C2) and the `ConnectionKey` value type; local-only OS entry points; evidence retirement on an origin change. No behaviour change for local panes. Review Loop clean after 3 rounds | #924 |
| 2026-10-17 | S2: host identity (C1), connection owner (C4), snapshot contract (C3), structured commands (C5), probe and parser (C6), all unused by the app | S2 PR |

## S1 — Typed process references

- **Types** (`App/Sources/Domain/AgentDetection/ProcessRef.swift`). `ProcessRef` is
  `.local(pid)` or `.remote(RemoteProcessRef)`; `RemoteProcessRef` is connection key, boot
  id, pid and native start token, and its equality is generation equality.
  `LocalProcessGeneration` (pid + libproc start time) is the old `AgentProcessGeneration`
  struct; `AgentProcessGeneration` is now `.local(LocalProcessGeneration)` or
  `.remote(RemoteProcessRef)`. `ConnectionKey` carries user, hostname, port, jump chain and
  the `-F` file; its resolution lands in S2.
- **Where the reference replaced a pid.** `ForegroundProcess.ref` (the parent stays a
  namespace pid for walks inside one job), `ForegroundJob.launchProcess(of:)`,
  `IdentifiedAgentProcess.launchProcess`, `PaneAgentState.agentProcess` and `launchProcess`,
  and the coordinator's bound generation.
- **Local-only entry points.** `AgentSessionResolver` takes `LocalAgentProcess` (agent and
  local pid), produced only by `IdentifiedAgentProcess.local`. `CodexLogProvider`,
  `ClaudeRuntimeProvider`, `ClaudeRuntimeDecoder`, the hook observation store and CLI caller
  ancestry take `LocalProcessGeneration`. `processIsLiveAncestor` over references returns
  false for any remote pair. `currentAgentEvidence` and the `agents read` snapshot path
  read only local references.
- **Retirement by owner.**
  - Session and launch observation retire when the identified reference changes; a
    remote reference never equals a local one, so an origin change retires them.
  - The launch process survives an engine replacement while it stays a live ancestor; a
    launch on another origin is never an ancestor.
  - The coordinator rebinds on any origin change, for every agent. It creates providers only
    for a local generation, and a remote generation has no OSC fence yet (S3 adds it), so
    no record counts for it.
  - Profile launch context: a Profile launch runs on this Mac, so an agent whose launch is
    remote drops the pane's Profile name and config root.
  - Managed hooks: when the pane's agent is remote, the local managed hook is revoked and
    the evidence epoch rotates.
  - OSC records: the surface keeps the origin of its last identified agent and the
    moment that origin replaced another one, as long as its record store
    (`programStatusOriginBySurface`). The coordinator fence is the later of the
    generation's start and that moment, so records that arrived on a departed origin never
    decide for the returning agent, even after the coordinator is rebuilt (review round 1).
    The change is timestamped when the probe that saw it returns, so reports that landed
    while that probe ran are left out too (review round 2); the screen decides until the
    next report.

## S2 — Remote contracts

All under `App/Sources/Infrastructure/RemoteHost/`; nothing in the app calls it yet.

- **C6 probe** (`RemoteProbeScript`). A POSIX `sh` script piped to `sh -s`. Output: one
  record per line, TAB-separated, fields escaped (`%25`, `%09`, `%0A`, `%0D`), framed by
  `PROWL-PROBE 1` and `END <sessions> <processes>`.
  - Records: `H` (OS, boot id), `S` (pane id, anchor, tty, tpgid), `P` (pid, ppid, pgid,
    native start token, elapsed, comm, argv), `D` (cwd).
  - Linux: owned `/proc/*/stat` files are read in one pass, plus `environ`, `cmdline` and
    `cwd` for anchors and foreground members only. The start token is the start tick,
    the boot id is `boot_id`, and argv is a US-separated vector. Untrusted strings
    reach awk through `ENVIRON`, because `-v` decodes backslash escapes; a trailing
    newline survives command substitution (review round 1).
  - macOS: one `ps -A` pass for the table, one for `ucomm`, one `ps -E` and one `lsof`
    for the foreground members. The start token is `lstart`, the boot id is
    `kern.boottime`, and argv is the joined string. `lsof` prints names in an escaped
    display form (`\\`, `\t`, `\n`, `\xNN`, `^X`); the `D` record marks it (`l`, Linux `r`)
    and the parser decodes it, so a cwd with Chinese characters, a backslash or a tab
    round-trips (review round 1).
  - Cost: 0.14–0.22 s warm on mini (729 processes) and 0.13 s in the Debian container.
- **Parser** (`RemoteProbeParser`). It works on bytes and decodes field by field: UTF-8,
  else Latin-1, so a non-UTF-8 argv garbles only its own field. It returns `complete` only
  when the header, host record, records and `END` counts are all consistent; anything
  else is `partial` or `unrecognized` (for example a login banner). Fixtures were recorded
  on mini (Claude Code 2.1.302 with `comm` = version, Codex 0.163) and in the container
  (a cwd with a space, a tab and `%`).
- **C4 owner** (`RemoteConnectionOwner`, `RemoteConnectionRegistry`).
  - One actor per `ConnectionKey`, at most one probe in flight. A request while busy
    coalesces into one follow-up run.
  - After a failure: a jittered backoff (0.5 s doubling to 8 s), and the next run starts
    a new connection epoch.
  - Each snapshot carries epoch, sequence, start and end (local monotonic), and an outcome
    (`complete` / `partial` / `failed(reason)` / `timedOut`).
  - Failure reasons for the UX: authentication, host key, unresolvable, unreachable,
    launch, exit, unrecognized output.
  - `shutdown` sends `-O exit`.
  - The registry leases owners. The last release retires one, and an acquire for the
    same key waits until the old owner's `-O exit` finished, so two lifecycles never share
    a control socket (review round 1).
  - The side channel is `ssh <overrides> -o ControlMaster=auto -o ControlPath=<hash>
    -o ControlPersist=60 -T <recipe options> -- <destination> sh -s`. The overrides come
    first, because `ssh` keeps the first value it obtains:
    - `BatchMode`, `ClearAllForwardings`, `RemoteCommand=none`, `RequestTTY=no`,
      `PermitLocalCommand=no`
    - no agent, X11 or tunnel forwarding
    - `SessionType=default`, no fork, no escape character, `LogLevel=ERROR`, server-alive
      checks
  - Checked against a configuration with `LocalForward`, `RemoteCommand`, `LocalCommand`
    and `SessionType none`: nothing ran and nothing listened. Without the overrides, the
    forward and the local command ran.
  - **Finding:** `ConnectTimeout` together with `ControlPersist` (OpenSSH 10.3) holds the
    first command's output open for about 10 s, so it is not used; the runner's 5 s
    deadline bounds the whole command.
  - The ControlPath is a SHA-256 prefix of the key, under the user temp directory (78
    bytes, below the 104-byte `sun_path` minus the 17-byte creation suffix).
- **Runner** (`RemoteCommandRunner`). `posix_spawn` in a new process group, so a stop
  also reaches a `ProxyCommand`. The budget lasts until the command's I/O is finished, not
  only until the leader exits: a descendant that keeps a pipe open is stopped with the
  group, and reads are abandoned after the kill grace when a descendant left the group
  (review round 1).
  - Stdin input, a 256 KiB output cap (truncation stops the command and makes the
    snapshot `partial`), a 5 s deadline, and SIGTERM followed by SIGKILL after 1 s.
  - The `waitpid`, read and write threads start before the first suspension. With
  `Foundation.Process`, or with work started from `async let`, a busy cooperative pool
  delayed the exit notification by 40–50 s under the full test suite, and finished
  commands were reported as timeouts.
- **C3** (`RemoteProbeSnapshot`, `RemoteProcessPresence`). A snapshot is fresh for 10 s.
  Presence counts each sequence once, ignores older epochs and inconclusive or stale runs,
  and releases after two consecutive complete fresh snapshots without the process.
- **C5** (`RemoteShellCommand`). Executable, argv, cwd and environment become one POSIX
  script for `sh -s`: `cd -- … || exit 97`, then exported variables, then `exec`. It
  rejects NUL bytes and invalid variable names. Tested by running the script in a local
  `/bin/sh` with hostile argv.
- **C1** (`HostProfile`, `ConnectionKey(effectiveConfiguration:)`). The key comes from
  `ssh -G`. `authorityChanged(to:)` flags another user, hostname or port; persistence and
  the rebind prompt come with L1.
- **Live check.** `RemoteConnectionLiveTests` runs only with
  `TEST_RUNNER_PROWL_TEST_SSH_HOST`. It passed against mini and the Debian container
  (`-p 2222`): two complete snapshots on one master, and no socket left after release.

