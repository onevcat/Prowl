# 073 — Codex Daemon Caller Identity: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-09-29 |
| **Primary PRs** | #839 |
| **Related** | [064-agent-completion-signals](../064-agent-completion-signals/000-plan.md), [064.020 selection research](../064-agent-completion-signals/020-selection-channel-research.md), `docs/components/cli.md` |

## Background

Codex 0.157 enabled `daemon_auto_start` by default. A `codex` TUI typed in a pane now
attaches to a shared `codex app-server --listen unix:// --managed-daemon` process. The
daemon runs every shell command, including user `!` commands:

- The command's parent process is the daemon, not the pane shell.
- The command's environment is the daemon's environment. The daemon copies the environment
  of the process that last started it: the first TUI, a `daemon restart` caller, or the
  `pid-update-loop` updater that restarts it on auto-update. The updater can live for days,
  so a daemon can carry the `PROWL_PANE_ID` of a pane that closed days ago.
- Only the working directory and `CODEX_THREAD_ID` (plus `CODEX_SESSION_ID`) are per thread.
- The daemon is started with `setsid` but keeps its parent. While the TUI that started it
  is alive, the ancestry of a command from any pane is
  `command → daemon → starter TUI → starter pane shell`.

Upstream documents this as intended ("per-client environment isolation is not provided",
`codex-rs/app-server-daemon/README.md`) and declined client environment forwarding
(openai/codex#44774). Profile launches are not affected: any non-allowlisted `-c` override
forces the embedded server, and Prowl always adds `-c notify=[…]`.

Observed impact for a Codex TUI typed by hand (verified live with Codex 0.158.0):

| Surface | Effect |
| --- | --- |
| `prowl agents signal`, `agents dispatch-complete`, managed/native hook attribution | `SOURCE_REQUIRED` after the starter exits; **wrong pane** while the starter TUI is alive |
| `prowl workflow deliver` / `read` / `status` / `run` (current role) | Same: a run stalls, or its delivery lands on another pane |
| `$PROWL_PANE_ID` used by skills (`skills/prowl-cli/SKILL.md`) | Names a closed pane, or another live pane |

## Goals

- Never attribute a CLI caller to a pane through a Codex managed daemon's ancestry.
- Resolve a caller that runs under the daemon to the pane whose TUI drives its thread,
  so signals, dispatch receipts, native hooks, and workflow commands work again.
- Give agents a server-resolved "who am I" so skills stop trusting `$PROWL_PANE_ID`
  inside Codex. Other agents keep using `PROWL_PANE_ID` unchanged.
- Keep the change small: resolve on demand, only for callers under the daemon.

### Non-goals

- Log-based working/idle detection for daemon-mode Codex. (Corrected: delivered as a
  stacked follow-up that reuses the mapper; see 002.)
- Fixing the other inherited variables (`PROWL_WORKTREE_PATH`, `SSH_AUTH_SOCK`, …).
- Forcing `--no-daemon` on user-typed commands.

## Design / Approach

The bridge is the TUI session log that Codex writes when `CODEX_TUI_RECORD_SESSION=1`
and `CODEX_TUI_SESSION_LOG_PATH` are set. These variables do not disable the daemon. Each
submit writes an `op` record `UserTurn` with a fresh `client_user_message_id`. The daemon
writes the same value as `item.client_id` of the `item_completed` `UserMessage` event in the
target rollout. A child thread's rollout header names its parent
(`source.subagent.thread_spawn.parent_thread_id`).

1. **Pane environment.** `GhosttySurfaceView` sets both variables for every pane, with the
   log at `SupacodePaths` cache `codex-tui-sessions/<pane UUID>.jsonl`, unless the launch
   environment already sets them. The file is removed when the surface closes. At launch
   Prowl creates the directory (0700) and removes files older than seven days. Debug and
   Release share the directory, so launch never clears live files.
2. **Ancestry cut.** `CallerPaneResolver.processAncestry` stops before a process whose
   argv contains `app-server` and `--managed-daemon`, and reports that daemon. The walk can
   then never reach the starter pane's shell.
3. **Capture at accept.** `CLISocketServer` records, in `CLICommandContext`, the daemon
   pid and the caller's `CODEX_THREAD_ID`, read from its `KERN_PROCARGS2` environment
   (`ProcessDetection`). The server reads it; the client does not claim it.
4. **Mapping off the main actor.** A new `CodexDaemonThreadMapper` actor keeps an
   incremental index of the rollouts the daemon holds open for writing: header id, parent,
   and ordered client ids (only lines containing `"client_id"` are decoded). For each pane
   log it takes the newest submit whose id is indexed (a newer unindexed id is a pending
   steer or turn start, as found in the spike) and derives that thread's root. The pane
   whose bound root equals the caller thread's root wins; ties go to the newest submit
   timestamp. No match means no pane. The mapped pane UUID goes into the context before
   the request reaches the main actor.
5. **One resolution path.** `CallerPaneResolver.pane(for:paneByShellPID:)` returns the
   mapped live pane for a daemon caller, and the existing ancestry result otherwise. Signal,
   dispatch-complete, native hook, workflow, and list handlers use it.
6. **Who am I.** `prowl list --json` gains an optional `caller` object with the resolved
   pane and worktree ids. `skills/prowl-cli/SKILL.md` uses it when `CODEX_THREAD_ID` is set
   and keeps `PROWL_PANE_ID` otherwise. `docs/components/cli.md` documents the field and
   the Codex daemon caveat.

Verification: unit tests for environment parsing, the ancestry cut, the mapper (fresh
turn, `/new`, pending steer, child lineage, two panes on one thread, no match), handler
wiring, and the list field. Live acceptance in a Debug instance with an isolated
`CODEX_HOME` daemon started from one pane: before the fix a second pane's signal is
attributed to the starter pane; after the fix it is attributed correctly, and a workflow
delivery and a dispatch receipt from a daemon-mode Codex pane succeed.

## Alternatives & decisions

| Option | Decision |
| --- | --- |
| Trust `PROWL_PANE_ID` from the caller | Rejected: the daemon's value belongs to another or a closed pane. |
| Token-only workflow delivery | Rejected as the fix: it covers one command and leaves signals, receipts, and wrong-pane ancestry. |
| Inject `--no-daemon` (PATH shim or alias) | Rejected: changes a user-typed command and removes Codex features. Documented as a user workaround. |
| Observe the daemon over its socket | Rejected: thread status is available, but the protocol has no client-to-thread ownership. |
| Terminal title `session-id` item | Rejected: needs user config and truncates the id. |
| Continuous per-pane binding (spike design) | Deferred: identity only needs an on-demand lookup; detection can adopt the same mapper later. |

The spike that validated the session-log mapping lives on branch
`spike/codex-daemon-log-detection` (`scripts/spikes/codex-daemon-map.py`).

## Amendments

- Updated 2026-09-29: daemon-mode Codex log detection reuses the thread mapper — see [002-daemon-log-detection.md](002-daemon-log-detection.md)

- Updated 2026-10-08: Use the daemon binding for transcript resolution and fence selected-session changes — see [003-daemon-transcript-resolution.md](003-daemon-transcript-resolution.md).
