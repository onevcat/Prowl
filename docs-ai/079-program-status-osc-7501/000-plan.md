# 079 — Program Status (OSC 7501): Plan

| | |
| --- | --- |
| **Status** | Planned |
| **Anchor date** | 2026-10-10 |
| **Primary PRs** | (fill in as they merge) |
| **Related** | [078-ghostty-1-4-upgrade-rehearsal](../078-ghostty-1-4-upgrade-rehearsal/000-plan.md), [068-agent-state-providers](../068-agent-state-providers/architecture.md), [064-agent-completion-signals](../064-agent-completion-signals/000-plan.md), `docs/components/agent-detection.md`, [producer-baseline.md](producer-baseline.md) |

## Background

OSC 7501 (the program status protocol, Rex revision 0.3 of 2026-10-07) lets a program put one
status record per terminal into the PTY stream: `idle`, `working`, `done`, `blocked` (with
`kind=permission|question|auth`), `error`, plus `clear`; optional `id` (`/` nests records),
`app`, `progress`, base64 `title` and `msg`. A program sends `OSC 7501 ; ?` and only reports
when the terminal echoes the query. Claude Code 2.1.295 and Pi 1.1.0 ship native support;
[producer-baseline.md](producer-baseline.md) records what each one actually sends.

Prowl decides Working/Blocked/Idle per pane from screen heuristics plus optional file
providers (Codex log, Claude native snapshot), through `AgentDetectionCoordinator` and the
pure `AgentStateMachine` (068). Screen rules are per-agent string matching and the file
providers poll on the detection clock. OSC 7501 is an explicit, push-based state signal from
the program itself, so it can become the first-priority *state* evidence. It carries no
identity (`id` is a record key, `app` is self-declared) and no delivery receipt, so it cannot
replace the session resolver, managed hooks, transcript readers, or workflow delivery.

Upstream Ghostty merged the parser and the libghostty-vt callback in upstream #14560
(1.4.0 milestone), with "The Ghostty app ignores these reports for now." On the 078 pin
(`9d479dcb1` + fork patches) `src/termio/stream_handler.zig` still lists `.program_status` as
unimplemented, `include/ghostty.h` (libghostty-internal, what GhosttyKit builds) has no action
for it, and the libghostty-vt callback cannot be attached to a `ghostty_surface_t`. Nothing
upstream (issues, PRs, discussions, branches) plans the app-side wiring. Prowl therefore needs
a fork patch; pure Swift cannot see the bytes.

## Goals

- Receive every valid OSC 7501 report in Prowl, per surface, through a GhosttyKit action.
- Answer the support query so producers start reporting inside Prowl.
- Keep a bounded record tree per surface with the protocol's lifetime rules.
- Feed the root and child records into `AgentStateMachine` ahead of native, log, and screen
  evidence for producers whose behaviour the baseline covers, with explicit fallback.
- Record producer behaviour as replayable baselines before enabling OSC-first.

### Non-goals

- No public `AgentSignal` from OSC reports: `source: .osc` stays reserved. Hook, receipt,
  `--min-confidence exact` and workflow delivery semantics do not change.
- No session identity from `app`/`id`; `logSessionID` keeps coming from native/log providers.
- No UI for non-agent producers (cargo, terraform) in this entry; the record store is generic
  so a later entry can show them.
- No upstream submission: the action stays a fork patch (decided 2026-10-10); the struct
  mirrors the libghostty-vt names so a later upstream action is a rename, not a redesign.

## Design / Approach

### Slice 1 — fork action and Swift copy (this entry's first PR)

| Fork file (`onevcat/ghostty`, branch `rehearsal/tip-9d479dcb1-patched`) | Change |
| --- | --- |
| `src/termio/stream_handler.zig` | `.program_status`: query → `write_stable` echo with the same terminator (always, Prowl consumes reports); report → copy the validated body into `apprt.surface.Message.WriteReq` and post to the surface mailbox; `fullReset` posts `clear` with an empty id |
| `src/apprt/surface.zig` | `Message.program_status` = `{ state, data: WriteReq }` (owned copy, like `pwd_change`) |
| `src/Surface.zig` | decode `id`/`app`/`kind`/`progress` and the base64 `title`/`msg` into stack buffers sized by the parser limits, perform the action, free the copy |
| `src/apprt/action.zig` | `ProgramStatus { report: *const Report }`; `Report` is the extern struct; `State`/`Kind` enums checked against `ghostty.h` by `checkGhosttyHEnum` tests; passed by pointer so `ghostty_action_u` keeps its 24-byte size |
| `include/ghostty.h` | `ghostty_action_program_status_state_e`, `ghostty_action_program_status_kind_e`, `ghostty_action_program_status_s` (NUL-terminated strings, empty when absent, valid only during the callback), `GHOSTTY_ACTION_PROGRAM_STATUS` appended to the tag enum, pointer member in the union |
| `src/apprt/gtk/class/application.zig` | listed as unimplemented so GTK keeps compiling |

Prowl side: `App/Sources/Infrastructure/Ghostty/GhosttyProgramStatusReport.swift` copies the C
struct into a `Sendable` value inside the synchronous action callback (`ghostty_app_tick`
dispatches surface actions on the main thread, so the strings are valid for the copy);
`GhosttySurfaceBridge.onProgramStatus` hands it to the terminal owner. The harness
`scripts/program_status_probe.py` replays producers outside Prowl.

### Slice 2 — record store and state machine

```text
GHOSTTY_ACTION_PROGRAM_STATUS
  -> GhosttySurfaceBridge: GhosttyProgramStatusReport (copied, main thread)
  -> ProgramStatusRecordStore (pure, per surface): replace / subtree clear / app inheritance / LRU / revision
  -> wakeAgentDetection(forSurfaceID:)   (existing adaptive loop; no new timer)
  -> AgentDetectionCoordinator.observe pulls a snapshot -> AgentDetectionEvent.programStatus
  -> AgentStateMachine.resolve: programStatus > native > log > screen
  -> AgentStateDecision.reason "osc.working" | "osc.blocked.permission" | ... (visible in `agents --json`)
```

- **Record store** (`App/Sources/Domain/AgentDetection/`): a report replaces its record
  completely; `clear` removes the record and its descendants, with an empty id everything;
  a record without `app` inherits the nearest ancestor's; at most 256 records, LRU eviction,
  a local monotonic revision per surface. `done`/`error` records stay until the pane is seen
  (`markAgentSeen`), `idle` may be dropped.
- **Lifecycle** uses existing signals only: `GHOSTTY_ACTION_SHOW_CHILD_EXITED` and
  `GHOSTTY_ACTION_COMMAND_FINISHED` remove `working`/`blocked`; a foreground process
  generation change (already the coordinator's reset trigger) drops the store; RIS arrives
  as the fork's `clear`. No silence timeout: the protocol has no heartbeat, and the 15 s
  OSC 9;4 stale watch in `GhosttySurfaceBridge` must not be reused.
- **Attribution fence**: a report is bound to the foreground process generation at arrival
  and only drives a decision when `app` matches the detected agent's declared name
  (`claude-code` for `.claude`, `pi` for `.pi`); otherwise it is stored for diagnostics only.
- **Mapping**: `idle` and `done` → Idle (the terminal owner already derives the unseen
  "done" presentation), `working` → Working, `blocked` → Blocked with the kind in the
  reason, `error` → Idle with reason `osc.error`. Any child `working` sets
  `hasOutstandingWork` and keeps the pane Working; a child `blocked` wins as Blocked. Root
  idle with child working therefore stays Working, as the protocol requires.
- **Fallback**: no root record, `app` mismatch, or generation change → the existing
  native/log/screen resolution, never a timeout-based downgrade.

### Rollout

| Phase | Gate |
| --- | --- |
| Shadow | OSC decision computed and logged next to the live decision; disagreements counted during dogfooding |
| OSC-first per producer | enabled for Claude Code ≥ 2.1.295 and Pi ≥ 1.1.0 after the baseline scenarios replay inside Prowl; explicit off switch |
| Shrink screen rules | remove heuristics the OSC path makes redundant, one producer at a time |

## Alternatives & decisions

- **libghostty-vt callback** (`GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS`): rejected, it attaches
  to a standalone `GhosttyTerminal`, and `ghostty.h` has no accessor to a surface's terminal.
- **Pure Swift or a second PTY parser**: rejected, the OSC is consumed by the parser and
  never reaches screen text; a second parser duplicates ownership and backpressure.
- **Wait for upstream**: rejected, there is no plan or timeline; the fork struct mirrors the
  libghostty-vt `GhosttyTerminalProgramStatus` field set and enum names so an eventual
  upstream action is a rename.
- **By-value C struct in the action union**: rejected, it would grow `ghostty_action_u`
  past the size upstream asserts; the report is passed by pointer like other owned payloads.
- **Opt-in query reply**: rejected for the fork, Prowl always consumes reports; the vt layer's
  "only answer when a handler is set" rule is satisfied by construction.
- **OSC as public signal / identity**: rejected (see Non-goals); the research note's boundary
  "state yes, identity and delivery no" is kept as the contract.

## Amendments

- Updated 2026-10-10: slice 1 landed (fork action, Swift copy, harness, baselines) — see [002-fork-action-and-bridge.md](002-fork-action-and-bridge.md)
