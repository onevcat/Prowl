# 082 — SSH Remote Agents: Action Log

The outcome of [000-plan.md](000-plan.md), slice by slice. Each row names the PR; the
sections below record what shipped and what differs from the plan.

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-17 | S1: typed process references (C2) and the `ConnectionKey` value type; local-only OS entry points; evidence retirement on an origin change. No behaviour change for local panes. Review Loop clean after 3 rounds | #924 |
| 2026-10-17 | S2: host identity (C1), connection owner (C4), snapshot contract (C3), structured commands (C5), probe and parser (C6), all unused by the app. Review Loop clean after 2 rounds | #925 |
| 2026-10-17 | S3a: manual-session correlation behind `PROWL_REMOTE_AGENT_DETECTION` — `LC_PROWL_PANE`, argv grammar, per-pane tracker, identity, snapshot release, remote OSC fence. Review Loop: 4 rounds plus a 2-round follow-up, clean (R1–R10) | #926 |
| 2026-10-18 | S3b: stale projection and refusal of remote agents in conditions, dispatch and workflow admission (behind the flag). Review Loop clean after 3 rounds | #927 |
| 2026-10-18 | S3c: degraded OSC-only binding for panes the host cannot map or probe (behind the flag) | S3c PR |

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

## S3a — Manual-session correlation (behind a flag)

The plan's S3 is split: S3a binds and releases remote agents; S3b adds the stale projection,
the degraded OSC-only binding and admission refusal. Both stay behind
`PROWL_REMOTE_AGENT_DETECTION=1` (or the `remoteAgentDetectionEnabled` default) until S4.

- **Pane id.** Every pane exports `LC_PROWL_PANE` next to `PROWL_PANE_ID`, whatever the
  flag says, so panes opened before the flag is turned on can be correlated.
- **Argv grammar** (`SSHInvocation`). Connection-shaping options are replayed. These are
  dropped: forwarding, session and control options, including `ConnectTimeout`,
  `SendEnv`, `SetEnv` and `LogLevel`. These are `unsupported`: `-N`, `-f`, `-W`, `-s`,
  `-G`, `-O`, `-Q`, `-V`, unknown flags, unknown `-o` keys, and a missing destination.
  The remote command is never replayed. As in OpenSSH, options are read before and after
  the destination, up to the first other argument. The tracker runs `ssh -G` and the side
  channel in the local `ssh`'s working directory, so relative `-F`/`-i` operands mean the
  same files (review round 1).
- **Trigger.** A foreground `ssh` with no local agent. It must be the terminal's own `ssh`:
  one that another `ssh` of the job started (the `-W` transport of `-J`, or one under a
  `ProxyCommand` shell) is skipped (review round 3). The tracker belongs to that `ssh`
  generation (pid and start time); a new `ssh`, a local agent, the flag off or a closed
  pane retire it and close the lease, and snapshots that arrive later are dropped.
- **Tracker** (`RemotePaneTracker`). It leases the host's owner (`ssh -G`, then the
  registry) and consumes snapshots on the main actor. A failed connection is retried with a
  bounded backoff (1 s doubling to 30 s), and at once on the next wake (follow-up review).
  - Correlation: `pending`, `correlated`, `ambiguous`, `unmapped`, `probeUnavailable`,
    `unsupported`. Only `correlated` binds. The session that first carried the pane id is
    also recognized by its anchor pid: back at the macOS system shell the id is hidden again.
    Only that single mapped session is evidence; an unmapped or ambiguous scan neither
    releases nor confirms the bound agent (review round 1). The anchor is valid only in the
    connection epoch and boot it was seen in (review round 2).
  - The bound agent is held across ticks, so the coordinator can delegate. It is
    released by the C3 rule (two complete fresh snapshots without it) or at once when the
    local `ssh` is gone. An OSC 133 D from the remote shell asks for a snapshot right away.
  - Cadence: 1 s while an agent is bound or the pane settles after a wake, 3 s otherwise.
    A pane with a foreground `ssh` never goes cold, and a bound agent is ticked at least
    every second, even on the two-second delegated schedule (review round 1).
    It counts from the host's shared latest snapshot, so panes on one host do not double
    the probe rate. Wakes (input, reports) request at once; a snapshot interrupts the
    loop's sleep without opening a settle window.
- **Remote OSC fence.** The first agent since the `ssh` started counts reports from the
  `ssh` start; a successor counts only reports after the snapshot that confirmed it,
  timestamped after the tick's local probe returns (review round 1). The fence belongs to the
  `ssh` generation and lives with the surface's record store (`remoteFenceHistoryBySurface`),
  so a tracker recreated by an undone close never moves it back (review round 2). The surface
  origin record also keeps when each origin was last seen. When the pane returns to a remote
  origin and the origin it left was seen after the `ssh` started, the remote fence rises to
  the switch, so a local agent run while the `ssh` was suspended cannot decide for the
  resumed remote one (review round 4). The S1
  origin fence applies to local generations only.
- **Measured** in a Debug instance with the flag on:
  - mini (macOS 26.5), Claude Code 2.1.302 started by hand: appeared 0.62 s after the
    command; trust prompt Blocked; `osc.idle` → `osc.working` → `osc.done` through ssh;
    released 2.69 s after Ctrl+C.
  - mini, Codex 0.162.1 (no OSC): appeared 1.13 s after the command; screen rules. Killing
    the local `ssh` released it in 0.44 s.
  - Debian container, Claude Code 2.1.302 over `-p 2222 -o UserKnownHostsFile=…`:
    appeared 2.39 s after the command (node start and a new master); released 2.35 s
    after Ctrl+C.
  - Two panes on one host: separate attribution, one control socket.
  - Claude inside remote tmux: no entry (S5).
  - After review round 1: `ssh host -l user` bound Claude in 0.36 s; release after Ctrl+C
    through the anchor-pinned session took 2.87 s; after 40 s idle, `sleep 5; codex` was
    found 2.6 s after Codex started.
  - After review round 3: `ssh -J mini onevcat@127.0.0.1` (ProxyJump to mini's loopback):
    Claude bound in 0.37 s, released in 2.91 s.
  - Debug build CPU: a delegated remote Claude costs 0.1–0.8 % of a core. A screen-rule
    agent costs as much as it does locally. Before the bound agent was held across ticks,
    a remote OSC producer could not delegate and read the screen every 300 ms.

## S3b — Stale projection and remote refusals (behind the flag)

The plan's S3 remainder is split once more: S3b covers staleness and admission; S3c adds the
degraded OSC-only binding.

- **Context.** `RemoteAgentContext` (host, correlation, staleness) rides on `PaneAgentState`
  and `ActiveAgentEntry` for agents on a remote origin. The tracker records when a snapshot
  last confirmed the bound agent, counted from the snapshot's acquisition, not from when a
  tick read it (review round 1). Without a confirmation for 10 s the context is stale and
  carries that time. While fresh it carries no time, so a steady probe stream changes no
  published entry.
- **Stale proves nothing.** A stale entry keeps its agent and last state. Condition evidence
  reports it as `unavailable`, so `agents wait --until idle|blocked` and dispatch readiness
  never resolve on it. `exit` still needs the entry to go (an `ssh` exit or the snapshot
  rule), not a stale observation. A remote agent whose state is unknown (an unrecognized
  screen with no eligible OSC record, for example after a withdrawn root or a successor
  start) stays listed: its context marks the state unknown, and conditions read it as
  `unknown`. No earlier state is carried over, so a predecessor's Blocked never describes
  a successor (review rounds 1–2).
- **Admission.**
  - `agents dispatch` refuses a remote agent with `REMOTE_AGENT_UNSUPPORTED` before typing
    anything: the receipt is reported with `prowl agents dispatch-complete` from inside the
    pane, which the remote host cannot run. Human input (`agents input`, which the Mirror
    Send uses) needs no receipt and is still delivered (review round 1).
  - Workflow admission refuses a `current` or `pick` role on such a pane with the same code.
- **Measured** in a Debug instance with the flag on:
  - `agents dispatch` to a remote Claude in the Debian container returned
    `REMOTE_AGENT_UNSUPPORTED` before anything was typed (an unverifiable composer no
    longer masks the reason).
  - mini, Claude idle through OSC:
    - `agents wait --until idle` resolved while the observation was fresh.
    - With Prowl's side-channel master stopped (`SIGSTOP` on the `[mux]` process), the
      same wait timed out after 12 s, and the entry kept its agent and last state.
    - After `SIGCONT`, the wait resolved again.

## S3c — Degraded OSC-only binding (behind the flag)

- **When.** The pane's foreground is a local `ssh` whose tracker is `unmapped`,
  `probeUnavailable`, or `unsupported`, and no probed agent is bound. The surface's root
  record must come from a `.verified` producer and must have arrived after that `ssh`
  started. The plan names `unmapped` and `probeUnavailable`; `unsupported` (argv outside the
  grammar) is a pane that cannot be probed either.
- **Identity.** `ProcessRef.unprobedRemote(ssh generation)` (with matching
  `AgentProcessGeneration` and `ProcessOrigin` cases) names the local `ssh`, never a remote
  pid. Its origin is not local, so local providers, hooks, sessions and admission treat it as
  remote. The OSC fence is the `ssh` start.
- **Release and confidence.** Only the `ssh` exit releases the binding. A withdrawal or a
  quiet producer only ages it: the context is stale 10 s after the producer's last root
  report (OSC has no heartbeat). `RemoteAgentContext.isUnprobed` marks it heuristic. Once the
  pane is mapped (`correlated`), the probed path takes over. A later verified producer in the
  same `ssh` (Claude exits, Pi starts) replaces the binding. Only the bound producer's own
  report confirms it. Records count from the `ssh` start, raised to the start of the
  `ssh`'s current foreground interval and to the retained successor fence. A tracker that
  takes over an `ssh` an earlier tracker followed means the `ssh` left the foreground (a
  local agent ran while it was suspended) or the pane was closed and restored. Records from
  before that interval, or ones an earlier binding excluded, never acquire or confirm the
  agent (review rounds 1–2).
- **Measured** in a Debug instance with the flag on. `ssh -F /dev/null -t mini` skips the
  system `SendEnv`, so the host shows the session as pane `-` and the pane is `unmapped`.
  - Claude Code bound through `osc.idle` 1.49 s after the command, then went
    `osc.working` → `osc.done`; dispatch was refused.
  - After `/exit` the entry stayed listed (by design, stale after 10 s); the `ssh` exit
    released it.
