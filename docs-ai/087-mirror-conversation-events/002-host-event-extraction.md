# 087.002 — Host event extraction and replay

## Context

First Host slice of [000-plan.md](000-plan.md) (S1 without the wire): the event model,
the two transcript adapters, the bounded log that replays by sequence, and the file tail.
Nothing subscribes yet; `MirrorHost` and the clients are unchanged.

## Change

- `App/Sources/Features/RemoteMirror/Conversation/MirrorConversationEvent.swift` and
  `MirrorConversationPayloads.swift`: the `conversation-v1` event (`seq`, `ts`, `kind`,
  `source`, `data`) with one payload struct per family; `kind` selects the family on decode
  and unknown kinds fail to decode. `MirrorBoundedText` cuts at a character boundary with
  `truncated` / `totalBytes`. Added `session.updated` for title, model and cost changes,
  which the plan folded into `session.changed`.
- `ClaudeConversationAdapter.swift`, `CodexConversationAdapter.swift`: record → events per
  the plan's table. Claude pairs `tool_use` with `tool_result` by id (status from
  `is_error` / `interrupted`, duration from the two timestamps), opens prompts for
  AskUserQuestion and ExitPlanMode from the tool input, and resolves permission prompts
  from a `permissionDecision` whose source is not `config`. Codex emits `tool.started` and
  `tool.completed` from one `item_completed`, maps `final_answer` to `phase: final`, and
  reports the model from `turn_context` / `thread_settings_applied`. Developer messages and
  unknown items are dropped silently.
- `MirrorConversationLog.swift`: sequences stay monotonic across `clear()`; retention by
  count and estimated bytes; `snapshot(since:)` reports `gap` when the requested point was
  evicted or precedes the current segment.
- `MirrorTranscriptTail.swift`: `MirrorJSONLineReader` (partial lines, CRLF, oversized
  lines dropped whole) and the queue-confined tail: bounded replay from a line boundary,
  vnode source plus a polling backstop, `rotated` on inode change or truncation,
  `missing` once until the file appears.
- `MirrorConversationStatusMapper.swift`: `PaneAgentState` → `agent.status` on change,
  with the OSC 7501 blocked kind and the decision reason identifier.
- `MirrorConversationFeed.swift`: composes tail → pipeline → log on the main actor;
  `follow` switches transcripts (`session.changed` with the reason, `session.pending` when
  none is known), `observe` feeds agent state, `stop()` is required.

## Findings

- `Date.ISO8601FormatStyle(includingFractionalSeconds:)` truncates: `.754` formatted as
  `.753`. Timestamps are rounded to whole milliseconds on parse and formatted by hand.
- Closing a vnode source's descriptor right after `cancel()` let the next `open()` reuse
  the number, and the replacement file was never observed. The descriptor now closes in
  the cancel handler.

## Refs

Tests: `App/Tests/RemoteMirror/MirrorConversationEventTests.swift`,
`ClaudeConversationAdapterTests.swift`, `CodexConversationAdapterTests.swift`,
`MirrorConversationLogTests.swift`, `MirrorTranscriptTailTests.swift`,
`MirrorConversationFeedTests.swift`. PR: (fill in).

## Review round 1 (2026-11-04)

Three reviews of `58810c6e` (the review-loop reviewer plus a Claude Code and a Codex
session reading their own transcripts) agreed on the material findings; all were fixed:

- Transcript tail: a same-inode truncate-and-rewrite is detected by re-reading the last
  256 bytes before the offset (`rotated`, then a full replay); a replay window that starts
  right after a newline is not mid-record; a bounded replay also delivers the file's first
  64 KiB as `head`, which the adapters use to announce the session (`bootstrap`).
- Feed: rotation and a lost file start a new log segment like a transcript switch; every
  segment restates the current `agent.status`; an unsupported transcript asked for twice
  does not repeat `session.pending`; unreadable records produce one `notice` per batch.
- Log: an empty segment still reports `gap` for a point before it; retention counts
  changed paths, choices and diffs.
- Claude adapter: compaction summaries, slash-command echoes and `<local-command-stdout>`
  are not human turns (a command echo is a `notice`); `dequeue` records carry no text, so
  the adapter keeps the queue and releases the oldest; AskUserQuestion / ExitPlanMode
  resolve as `answered` / `dismissed` from their tool result, and `permissionDecision`
  resolves a permission prompt only for `user*` sources; `turnOrigin` values `scheduled`,
  `sdk` and `task_notification` map to `automation` / `system`; edits carry a diff from
  `structuredPatch` or the written content; tool titles prefer descriptions and patterns;
  pending tools are dropped when the turn closes.
- Codex adapter: one compaction is one event (a `compacted` record and its
  `ContextCompaction` item arrive milliseconds apart); `turn_aborted` keeps its duration
  and reason; user messages count `local_image` blocks; FileChange carries the unified
  diff or added content; empty stdout/stderr are not joined.
- Status mapper: a `.native` decision reports source `native`, not `hook`.

Still unverified on real data: `interrupted` tool results, ExitPlanMode and NotebookEdit
input shapes, Codex `DynamicToolCall` items and `declined` command status, fork sessions.
Codex `SubAgentActivity` stays unmapped until S4.
