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
