# 087.003 — `conversation-v1` on the wire

## Context

S2's Host half: serve the event stream of [002](002-host-event-extraction.md) to clients
through the existing Mirror connection, with resume by sequence and view switching, so
the mobile clients can be rebuilt on it.

## Change

- `MirrorMessage.Representation.conversation` (`conversation-v1`), capability
  `conversation-v1`, `subscribe.since`, and two controls: `conversationSnapshot`
  (`events`, `gap`, `sequence`) and `conversationEvents` (`events`, `sequence`), both
  acknowledged with the existing `acknowledge` like frames; one batch outstanding.
- `MirrorPaneDescriptor` gains `agent`, `agentState` and `conversation`
  (`available` / `pending` / `unsupported`); `MirrorPaneSource.agentState(_:)` exposes the
  pane's `PaneAgentState`, and `GhosttyMirrorPaneSource` fills the descriptor from it.
- `MirrorHost` keeps one `MirrorConversationFeed` per pane in `conversationFeeds`,
  created on the first conversation subscription and released ten minutes after the last
  subscription ends (`conversationFeedRetention`), so a reconnecting client resumes with
  `since` and the same sequences. Each poll tick points the feed at the pane's current
  transcript (`session.changed(switched)` when it moves) and agent state, then flushes
  events after the previous batch's acknowledgement; a gap sends a snapshot instead.
- A peer may subscribe its own pane again with another representation; the old
  subscription is replaced in place and exclusivity is unchanged for other peers.
  `input` and `scroll` are rejected on a conversation subscription.
- The event model (`MirrorConversationEvent`, payloads) moved to `Mirror/Shared/` so the
  iOS client compiles the same type; the iOS `MirrorProtocol.swift` copy carries the
  same message additions.
- Docs: `docs/remote-mirror-wire.md` ("Conversation stream"), `docs/remote-mirror.md`
  ("Conversation view").

## Refs

Tests: `App/Tests/RemoteMirror/MirrorHostConversationTests.swift` (snapshot, batching and
acknowledgement, wrong acknowledgement, unsupported pane, representation switch, resume
by sequence from the retained feed, transcript change, status events, descriptor
support). PR: (fill in).
