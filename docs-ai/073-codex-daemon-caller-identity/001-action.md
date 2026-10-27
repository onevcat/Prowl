# 073 — Codex Daemon Caller Identity: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-09-28 | Codex 0.158 working pane showed idle; screen rules fixed separately | #838 |
| 2026-09-28 | Spike: TUI session log `client_user_message_id` ↔ rollout `client_id` maps panes to daemon threads | branch `spike/codex-daemon-log-detection` |
| 2026-09-29 | Isolated `CODEX_HOME` checks of daemon environment inheritance and ancestry | this entry |
| 2026-09-29 | Ancestry cut, `CODEX_THREAD_ID` mapping, `list` caller, skill and manual updates | #839 |
| 2026-10-14 | Profile launches add `--no-daemon` (Codex ≥ 0.156) even when the managed notifier degrades; workflow `read`/`deliver` accept the step token without a pane | #911 |

## Outcome & current state (as of 2026-09-29)

- `ProcessDetection` reads one variable from another process's `KERN_PROCARGS2`
  environment (`processEnvironmentValue`) and recognizes the Codex managed daemon
  (`isCodexManagedDaemon`). The kernel hides the environment of Apple platform binaries;
  the `prowl` CLI is not one.
- `CallerPaneResolver.processWalk` stops before the daemon. `pane(for:paneByShellPID:)` is
  the single resolution used by signal, dispatch-complete, native hook, workflow, and list
  handlers. A daemon caller resolves only through its mapped pane.
- `CLISocketServer` captures the daemon and the caller's `CODEX_THREAD_ID` at accept, then
  `CodexDaemonThreadMapper` (actor) maps it off the main actor before routing.
- `CallerPane.belongs(to:)` accepts a mapped caller for a signal's `current` binding when
  the pane's session log started within 120 s after the detected Codex process.
- `GhosttySurfaceView` adds the `CodexTUISessionLog` variables; `closeSurface` removes the
  log when the surface is freed, which happens after the undo-close window. Launch creates
  `SupacodePaths.codexTUISessionLogDirectory` (0700) and removes logs older than seven days.
- `ListCommandPayload.caller` reports the resolved pane; `skills/prowl-cli/SKILL.md` and
  `docs/components/cli.md` use it inside Codex.

Key files: `supacode/CLIService/CLICommandContext.swift`,
`supacode/CLIService/CodexDaemonThreadMapper.swift`,
`supacode/Infrastructure/AgentDetection/CodexTUISessionLog.swift`,
`supacode/CLIService/CLISocketServer.swift`, `supacodeTests/CodexDaemonThreadMapperTests.swift`.

Live acceptance (Debug instance on a dedicated socket, isolated `CODEX_HOME` daemon started
by pane X's Codex, so its parent chain reaches X's shell):

| Scenario | Result |
| --- | --- |
| Pane Z's Codex before any submit: `!prowl list` | `caller` absent, not X |
| Pane Y's Codex: env `PROWL_PANE_ID` | X's id |
| Pane Y's Codex: `prowl list` caller, `agents signal` | Y; binding `current` |
| External `agents dispatch` to Y; Codex runs `dispatch-complete` | receipt `completed` / `succeeded` for Y |
| Y's Codex runs `workflow run prowl.handoff --input next=save`, reads, delivers | run `completed`, `current` role Y |
| Close Y's tab | log removed after the undo window |
| Same signal on the installed release build (before the fix) | recorded on **A** (the starter pane) with binding `current` |

## Deviations from plan

- The signal binding needed a generation proof for mapped callers (`belongs(to:)`); the
  plan did not name it.
- The session log is removed when the surface is freed, not at close, because an undone
  close restores the same Codex process and log.

## Open questions

- `CODEX_TUI_RECORD_SESSION` / `CODEX_TUI_SESSION_LOG_PATH` are undocumented Codex
  variables; a Codex change would silently disable mapping (callers then get
  `SOURCE_REQUIRED`, never a wrong pane).
- Daemon-mode Codex log detection can reuse `CodexDaemonThreadMapper`; tracked as follow-up.
- Issue #911: a long-running daemon stopped mapping every pane until `codex app-server
  daemon restart`; not reproduced. The mapper returns nil for all panes when the fd inventory
  is incomplete, a held rollout cannot be read, one rollout exceeds the read budget, or two
  rollouts share a client id, and it logs none of these. A profile launch reached the daemon
  only because its notifier preparation degraded (1 s login-shell probe or `config/read`).
  Correction (2026-10-28): the "stopped mapping until restart" failure is a revoked tty that the
  daemon inherits from the pane that started it; see
  [005-revoked-daemon-descriptor.md](005-revoked-daemon-descriptor.md).
