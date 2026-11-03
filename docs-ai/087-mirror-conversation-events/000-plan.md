# 087 — Mirror Conversation Events: Plan

| | |
| --- | --- |
| **Status** | Planned |
| **Anchor date** | 2026-11-04 |
| **Primary PRs** | (fill in as they merge) |
| **Related** | [067-remote-mirror](../067-remote-mirror/000-plan.md), [064-agent-completion-signals](../064-agent-completion-signals/000-plan.md), [073-codex-daemon-caller-identity](../073-codex-daemon-caller-identity/000-plan.md), [079-program-status-osc-7501](../079-program-status-osc-7501/000-plan.md), `docs/remote-mirror-wire.md`, issue #989 |

## Background

Mobile mirrors render `text-v1`: the Host's terminal viewport as plain text, reflowed on
the phone. For an agent TUI (Claude Code, Codex) this is a rendering of a conversation
made for an 80-column terminal: box-drawing composer borders, a status footer, spinner
frames and hard-wrapped tool output. On an iPhone it is unusable (device check on
2026-11-03: the composer box became a column of horizontal rules, the footer took the
bottom third of the screen, the transcript was lost in between).

Decision with onevcat (2026-11-04): the Host normalizes agent events into a Prowl-defined
conversation event set and streams those; the phone renders a chat-style GUI; the user can
switch to the plain-text Screen view to see the real Host state; panes without an agent or
with an unsupported agent fall back to `text-v1`. This entry records the capability
boundary found by the spike and the plan built on it.

## Goals

- A `conversation-v1` representation beside `vt-v1` / `text-v1`, additive on the wire.
- One event model for every supported agent; per-agent adapters on the Host only.
- Prompts that need a person (permission, question, auth) are events with the content
  the Host can prove, and can be answered from the phone without replaying input.
- Session changes (`/clear`, `/new`, resume, fork) are explicit events; an uncertain
  mapping sends the client to the Screen view instead of showing stale content.
- Reconnect resumes from the last seen sequence; a bounded snapshot replaces history paging.

### Non-goals

- Token-level streaming of assistant text (no source provides it; see Boundaries).
- Replacing the terminal: Screen view, Mac `vt-v1`, History and remote scrolling stay.
- Push notifications and an internet relay (issue #989 items 1–2); the event model only
  carries what a later notification needs (pane, kind, one-line summary).
- Agents beyond Claude Code and Codex in the first release.

## Spike findings (2026-11-04, Claude Code 2.1.317, Codex 0.166.0)

Probe: `scripts/spikes/mirror-events-normalize.py` (this branch) renders a Claude session
file and a Codex rollout as normalized events. Run on this session (791 records) and a
Codex review-loop rollout (165 records); both produced a readable chat stream.

| Source | Claude Code | Codex |
| --- | --- | --- |
| Transcript file | `~/.claude/projects/<cwd>/<session>.jsonl`; `user`, `assistant`, `system` (`turn_duration`, `compact_boundary`, hook summaries), `queue-operation` (queued mid-turn messages), `ai-title`, `cost-state`. `tool_use` is appended at the moment the tool starts (measured 67 ms before its `tool_result`); file mtime tracks the last event within seconds. | `~/.codex/sessions/.../rollout-*.jsonl`; `session_meta`, `turn_context` (model, approval policy), `event_msg` `task_started` / `task_complete` (with `last_agent_message`), `item_completed` carrying `UserMessage`, `AgentMessage` (phase `commentary` / `final_answer`), `Reasoning`, `CommandExecution` (command, cwd, exit code, aggregated output), `FileChange` (unified diff), `McpToolCall`, `Extension` (web search), `ImageView`, `ContextCompaction`. Items appear only on completion: no start record, no output deltas. A rollout holding only `session_meta` exists before the first submit. |
| Approval content | Pending `tool_use` with no `tool_result`; `PermissionRequest` hook (`tool_name`, `tool_input`, `permission_suggestions`); `Notification` hook `permission_prompt`; `AskUserQuestion` input holds the questions and options; the decision lands as `permissionDecision` on the `tool_result` record. | Nothing in the rollout. `PermissionRequest` hook (`turn_id`, `tool_name`, `tool_input.command`) when the hook is trusted; `request_user_input` questions are structured in the app-server protocol only. Screen rules in `App/Sources/Infrastructure/AgentDetection/CodexScreenProfile.swift` already recognise the approval footer and choice rows. |
| Program status (OSC 7501) | Verified: `working` / `idle` / `blocked` with kind `permission`, `question`, `auth` (079.004). | Verified since 0.163: `idle` / `working` / `blocked`, kind unspecified (079.007). |
| Native hooks | 33 events; Prowl's managed hook already forwards the full stdin payload (`CLI/Sources/prowl/Commands/AgentsHookCommand.swift`), and `Shared/Sources/ProwlCLIShared/AgentNativeHookPayload.swift` keeps only `detail`. | `~/.codex/hooks.json` or `config.toml`, Claude-shaped payloads: `SessionStart`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `SubagentStart/Stop`, `PreCompact`, `Interrupt`. Every non-managed hook must be trusted once (`/hooks`), or run with `--dangerously-bypass-hook-trust` per invocation. Prowl only consumes the `notify` `agent-turn-complete` today. |
| Pane → session identity | pid registry `~/.claude/sessions/<pid>.json` (exact; rotates on `/clear` and `/resume`), `App/Sources/Infrastructure/AgentDetection/AgentSessionResolver.swift`. | `App/Sources/CLIService/CodexDaemonThreadMapper.swift`: bound after the first indexed submit; `/new` fences the binding until the next submit (073.002, 073.003). |
| Daemon socket as observer | n/a | Not viable as probed: the managed daemon accepts the Unix connection but never answers `initialize` and closes it; `codex app-server proxy` exits silently. The protocol would give `item/started`, output deltas, `thread/status/changed` with `waitingOnApproval` / `waitingOnUserInput`, and `thread/resume` "rejoins" a running thread. 073 rejected the socket for identity; it stays an open question for events. |

## Design / Approach

Host-only normalization. A new `MirrorConversationSource` next to
`App/Sources/Features/RemoteMirror/GhosttyMirrorPaneSource.swift` owns one tail per
subscribed pane, fed by three inputs the Host already has: the pane's
`AgentSession.transcriptPath`, the pane's `PaneAgentState` (OSC 7501 and screen state),
and the native hook signals. Per-agent adapters (`ClaudeConversationAdapter`,
`CodexConversationAdapter`) map file records and hook payloads to the event set below.
No sampling without a subscription, as today.

### Event set (`conversation-v1`)

Envelope: `seq` (monotonic per subscription), `ts`, `kind`, `source`
(`transcript` / `hook` / `osc` / `screen` / `host`), `data`. Unknown kinds are ignored by clients.

| Kind | Data | Claude | Codex |
| --- | --- | --- | --- |
| `session.started` / `session.changed` / `session.pending` / `session.ended` | session id, cwd, model, title, reason (`clear`, `new`, `resume`, `fork`, `uncertain`) | transcript + registry | rollout + 073 mapper; `pending` until the first submit after `/new` |
| `turn.started` / `turn.completed` | turn id, origin (`human`, `queued`, `automation`), duration, status (`completed`, `aborted`) | `user` prompt record, `system.turn_duration` | `task_started`, `task_complete`, `turn_aborted` |
| `user.message` / `user.queued` / `user.unqueued` | text (bounded), image count, origin | transcript, `queue-operation` | `UserMessage` item; no queue records |
| `assistant.message` | markdown text (bounded), phase | `assistant` text block, on completion | `AgentMessage` item (`commentary` / `final_answer`) |
| `assistant.reasoning` | duration or summary; content never sent | `thinking` block duration | `Reasoning` summary when present |
| `tool.started` / `tool.completed` | tool id, kind (`shell`, `edit`, `read`, `search`, `web`, `mcp`, `agent`, `question`, `plan`, `other`), title, command, path, status, exit code, bounded output, diff | `tool_use` at start, `tool_result` + `toolUseResult` | `CommandExecution` / `FileChange` / `McpToolCall` …, both events from one completion record |
| `agent.status` | `working` / `idle` / `blocked`, kind, source | OSC 7501, hooks | OSC 7501, hooks, screen |
| `prompt.opened` / `prompt.resolved` | prompt id, kind (`permission`, `question`, `plan-approval`, `auth`, `trust`), title, detail (tool input), choices (canonical ids + labels), freeform flag, outcome | transcript + `PermissionRequest` / `Notification` hooks + OSC kind | hooks when trusted; otherwise OSC `blocked` + screen rules, detail from the screen text |
| `context.compacted`, `subagent.started` / `subagent.completed`, `notice` | — | `compact_boundary`, `SubagentStart/Stop` hooks | `ContextCompaction`, `SubAgentActivity` |

### Wire and client behaviour

- `subscribe` with `representation: conversation-v1` and optional `since: seq`. The Host
  replies with a bounded `conversationSnapshot` (last N events, oldest first) and then
  `conversationEvent` controls on the same ordered connection. Backpressure reuses the
  one-outstanding-frame rule by batching events into frames with an ACK.
- `panes` descriptors gain `conversation: available | unsupported | pending`, so the
  phone opens the GUI for a supported agent and the Screen view for a Shell.
- GUI ↔ Screen switches re-subscribe on the same lease with the other representation;
  `vt-v1` and the Mac client do not change. `History` stays as is.
- `promptRespond` command: prompt id, canonical choice or freeform text, lease. The Host
  re-checks the lease, that the prompt is still open (OSC or screen), and that the prompt
  identity matches, then injects the per-agent key sequence through the existing input
  path. Uncertain delivery keeps the prompt open and never replays, like `agents.input`.
- Reconnect sends the last `seq`; the Host resumes or, after a session change, sends a
  fresh snapshot with a `session.changed` event first.

### Host rules

- Thinking content is never sent; developer/system messages are omitted; tool output is
  truncated per event (target 4 KiB) with a `truncated` flag; subagent transcripts are
  summarized by their stop hook, not tailed.
- Tails use `DispatchSource` file watchers and parse only appended bytes; a rewrite,
  truncation or session rotation restarts the tail with a `session.*` event.
- `session.pending` and `session.changed(uncertain)` are produced from the existing
  resolver confidence; the client shows the Screen view until a new `session.started`.

## Alternatives & decisions

| Option | Decision |
| --- | --- |
| Hide the composer and footer from `text-v1` using the composer detectors in `App/Sources/CLIService/AgentPromptDelivery.swift` | Rejected. Those detectors answer "is it safe to type now" and refuse when unsure; a per-frame layout cut must be right every time. The remaining transcript area still reflows badly. |
| Run agents headless (SDK / `codex app-server`) instead of the TUI | Rejected. Prowl is a terminal orchestrator; the Host keyboard and the TUI stay primary. |
| Observe the Codex daemon socket for real-time deltas and approval status | Deferred. Not reachable as probed; revisit if Codex documents a second-client handshake. Rollout + hooks + OSC cover the v1 set. |
| Let the `PermissionRequest` hook hold and answer approvals from the phone | Deferred to a later slice. It would hide the local dialog while the hook waits, breaking "the Host keyboard stays available". v1 answers with verified keystrokes. |
| Read `tool.started` for Codex from `PreToolUse` hooks | Accepted as an optional improvement: with trusted hooks Codex gains start events and approval content; without them the stream degrades to completion-only, which is documented, not an error. |

## Boundaries

- Assistant text arrives when a message completes; `working` comes from OSC 7501.
- Codex without trusted hooks: no tool start, no approval content; `blocked` from OSC
  and the screen only.
- Agents other than Claude Code and Codex, and Shell panes, use `text-v1`.
- A Codex pane between `/new` and its first submit has no bound rollout.
- Reasoning content and permission-free auto-approved tools are not distinguished from
  prompted ones beyond `permissionDecision.source`.

## Slices

| Slice | Content | Verification |
| --- | --- | --- |
| S1 | Host: event model, `ClaudeConversationAdapter` from transcript + hooks + OSC, bounded tail, unit tests on fixture JSONL | Real Claude pane in an isolated Debug instance: start/clear/resume, tool runs, permission prompt, AskUserQuestion |
| S2 | Wire: `conversation-v1` subscribe, snapshot, events, `since`; iOS chat UI with fixture; Screen switch | Wire vectors on Mac and iOS; iPhone device acceptance |
| S3 | `prompt.opened` / `promptRespond` for Claude permission, question and plan prompts | Real prompts answered from the phone; refusal when the prompt closed locally |
| S4 | `CodexConversationAdapter` from rollout + OSC + screen; optional hooks with trust flow | Real Codex pane: `/new`, approval, `request_user_input`, abort |
| S5 | Android client | Emulator UI tests on the shared fixture |

## Amendments

(none yet)
