# 064.018 — Foreground Identity and Subagent Lifecycle Findings

| | |
| --- | --- |
| **Status** | Findings verified on Codex 0.154.0; implementation remains planned |
| **Anchor date** | 2026-09-12 |
| **Related** | [017 state decision](017-agent-state-decision.md), [045 session identity](../045-native-agent-session-detection/000-plan.md) |

## Decision

**File timestamps and writable ownership cannot determine the foreground chat.**
The same-PID `/resume` test produced different foreground chats with identical
rollout contents, modification times, and writable file paths.

**Logs can support Working while direct subagents run, but the parent's turn-end
event alone cannot.** The state decision must combine parent-turn activity with
scoped child activity. This is the user's requested behavior, not a claim that
Codex keeps its parent turn open until every child finishes.

The follow-up used isolated, hook-disabled real TUIs, seven session logs (four
roots and three direct children), and captured input, PTY output, file statistics,
descriptor transitions, and native records. Probes and detailed evidence remain
local, with no new spike PR or production code change.

## `/new` and `/resume`: observed sequence

| Step | UI/process | Files |
| --- | --- | --- |
| Complete A | PID P, foreground A | One writable A rollout |
| `/new` B, before first prompt | Same P, empty foreground B | Only A exists; no new rollout or log boundary yet |
| Complete B's first prompt | Same P, foreground B | A and B both open for writing; B is newer |
| `/resume`, select A, no prompt | Same P, foreground A; `/status` confirms A's ID | A and B have exactly the same sizes, mtimes, row counts, and writable paths as before selection |
| Submit a new prompt to A | Same P, foreground A | A receives a new `task_started` and paired completion |

Thus creation time picks B incorrectly after return to A, and modification time
does the same until A next writes. File discovery after `/new` is also delayed
until the new chat's first prompt. A new file or new root-turn event remains useful
candidate evidence; it is not a general foreground-selection contract.

A second counterexample rejects mtime even when files actively change: another
root R spawned a background child and returned. After `/new` C, C completed its
prompt at 01:15:56.788 UTC. R then recorded its child's completion at
01:15:56.984 UTC. R became the newer root log while the UI remained on C.

A later attempt to resume B again ended the transition-test TUI with status 0.
It is not counted as a successful second same-PID switch. Its internal cause was
not investigated. The successful B-to-A switch and background-write counterexample
already disprove timestamp-only identity. No claim of universal resume behavior
is based on the later exit.

## Direct-child lifecycle

| Case | Measured behavior |
| --- | --- |
| Parent explicitly waits | Child completed at 01:14:42.347; parent completed at 01:14:43.976. The parent turn stayed open through child work. |
| Parent returns immediately | Parent completed 43.942 s before its child. Parent log still received the child completion after the UI switched to C. |
| Repeat without switching chats | Parent completed 24.361 s before its child; completion was appended while the foreground parent was idle. |
| Follow-up on an existing idle child | Parent completed 18.766 s before the reused child. A new child turn was recorded. |
| Message to an idle child | `send_message` produced an interaction record but no child turn before the next real follow-up. |
| Explicit child interruption | Parent recorded `SubAgentActivity` with `kind: interrupted`; child recorded matching `turn_aborted`. |

The parent log contains `event_msg` / `item_completed` records whose `item.type`
is `SubAgentActivity`, with `agent_thread_id`, `agent_path`, and observed kinds
`started`, `completed`, `interacted`, and `interrupted`. The outer `turn_id` supplies
parent-turn context. Completions remain meaningful after that parent turn ends.

`interacted` is **not** a work-start signal by itself. Both `followup_task` and
`send_message` produced it. In these samples, the item's `id` matched the recorded
function call's `call_id`, allowing those operations to be distinguished by
`namespace: collaboration` and the function `name`. Child logs independently
recorded fresh starts for follow-up work, and no start for the message-only case.
Future providers must verify work activation instead of marking every interaction
Working.

Child `session_meta.source.subagent.thread_spawn` includes `parent_thread_id` and
`depth`, providing a structured lineage link. Child logs also contain inherited
parent history, including parent start/completion records with timestamps written
at child creation. Timestamp freshness alone must not turn that copied history
into new child work; initial replay and live child turns need distinct treatment.

## State decision requirements

Maintain separate parent-turn state and active-child work state. Subject to current
blocked UI and valid attribution, the desired busy predicate is:

```text
working = parent_turn_active OR verified_child_work_active
```

- Parent `task_complete` closes only the parent turn. It cannot clear active children.
- Track child identity and work generation; do not use an unscoped counter or let an
  older completion close a newer child task. Explicit interruption can arrive under
  a later parent turn and still end that child's work.
- Keep child evidence until completion/interruption or lifecycle invalidation. An
  idle parent or quiet log is not a child cancellation signal.
- Use structured lineage so a child's log is not mistaken for the foreground root.
- Keep current Blocked UI precedence and fallback behavior from 017. An in-progress
  child turn may itself be waiting; subtree approval UX was not tested here.
- Apply process/session invalidation and history baselines. These observations do
  not turn a stale log into a live channel after restart.

Foreground identity remains a separate gate. A future product choice to aggregate
all retained root sessions in a pane, rather than the selected root and its children,
would change the meaning of Working after `/new`; that policy is not decided here.

## Validation and limits

Local assertions verified unchanged B-to-A file/descriptor observations, the older
background root becoming newer than C, all three early-parent completion intervals,
the message/follow-up distinction, and explicit child cancellation. PTY processes
were stopped or exited; the temporary auth symlink was removed.
Across root and child logs there were 16 distinct turn IDs, 15 completions, and one
cancellation after deduplicating inherited records. Document references, local
Python syntax, and evidence assertions passed. `make build-app` passed with zero
warnings and errors.

This establishes feasibility for the tested direct-child paths on 0.154.0. Nested
descendants, child crashes, child approval prompts, concurrent reuse races, recovery
after lost records, remote/shared-daemon modes, and native Prowl GUI integration
remain unverified. No production watcher or state machine is implemented by this record.
