# 088 — Mirror iOS App: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-04 | Plan written; conversation fixtures recorded from real Claude Code and Codex sessions (`Mirror/Fixtures/conversation/`) with a sanitizer and a golden-event test | this branch |
| 2026-11-04 | Client rebuilt: `MirrorHostStore`, `MirrorHostSession(s)`, `MirrorConversationStore`, `HostsView` / `AddHostView`, `PanesView`, `PaneView` with `ConversationView`, `ScreenView` and `ComposerBar`; `MirrorSession` gained `Mode`, `open(_:mode:)`, `switchMode`, conversation subscribe/ack | this branch |
| 2026-11-04 | Fixture launch modes (`--mirror-ui-conversation-fixture [claude\|codex]`, `--mirror-ui-connection-fixture`) and the UI suite rewritten for the new flow; obsolete sidebar / connection-editor tests removed | this branch |
| 2026-11-04 | Host fix found by the simulator E2E: the `.list` reply rebuilt descriptors and dropped `agent` / `agentState` / `conversation` | #1040 (wire slice) |

## Outcome & current state (as of 2026-11-04)

- `Mirror/iOS/ProwlMirror-iOS/Infrastructure/MirrorHostStore.swift`: paired Hosts in `UserDefaults`
  (`mirror.hosts`), credential per Host in Keychain (`host:<address>:<port>`), one-time adoption of the
  old `last-verified-host` entry, `rename` and `remove` (deletes the credential).
- `Features/Hosts/MirrorHostSession.swift`: one roster connection per Host (`list` every 3 s while
  visible, `profiles` / `create` commands correlated by request ID, several in flight); the pane
  roster carries `agent`, `agentState`, `conversation`. `MirrorHostSessions` keeps them per Host and
  suspends / resumes with the scene phase.
- `Features/Sessions/MirrorSession.swift`: `Mode` (`conversation` / `screen`), `open(_:mode:)`,
  `switchMode` on the same connection, `conversation: MirrorConversationStore`, resume by sequence,
  fallback to the screen on `CONVERSATION_UNSUPPORTED`.
- `Features/Conversation/MirrorConversationStore.swift`: events keyed by sequence (last 2000), items
  derived from them (tool start + end merged, prompt open + resolve merged, queued messages removed
  when taken, attention rows only while blocked), `agentState` from the latest status.
- Views: `HostsView` (list, Add Host sheet with scanner, rename, forget), `PanesView` (sections by
  project, state dot, badge, launch sheet), `PaneView` (status pill, Chat | Screen picker, `…` menu,
  auto-switch to Chat when the roster reports `available`, header hidden while composing on a
  sideways phone), `ConversationView` (eager layout with "Show earlier" paging, Latest button),
  `ScreenView` (the former live reader and History), `ComposerBar` (Send inside the field, hint
  from agent state, receipts).
- Fixtures: `--mirror-ui-conversation-fixture [claude|codex]` replays the bundled events through the
  fake transport; `--mirror-ui-connection-fixture` serves the Hosts → panes → pane flow without a
  network; the fixture pane ID is fixed (`MirrorUIFixture.paneID`).
- Tests: `MirrorConversationStoreTests` (fixture snapshots, resume, queued, prompts) and the
  rewritten UI suite (`ProwlMirror_iOSUITests`, 19 tests) — see Verification.

## Verification (2026-11-04)

| Check | Result |
| --- | --- |
| `make check` (worktree, iOS branch) | passed |
| Mac `ProwlTests/MirrorHostConversationTests` (wire branch, with the roster pass-through test) | 9 passed |
| iOS unit tests (`ProwlMirror-iOSTests`, iPhone 18 Pro simulator) | 70 passed, incl. `MirrorConversationStoreTests` |
| iOS UI suite (`ProwlMirror_iOSUITests`, 19 tests) | 18 passed in the full run while a Mac build ran in parallel; the one timeout (`testLaunchSheetKeepsTheRosterUntilDismissal`) passed when rerun alone |
| End to end against an isolated Debug Host (127.0.0.1:7881, Claude Code in a pane) | pairing by code, Forget + re-pair, roster with "Idle · Claude Code", pane opens on the Screen while the transcript is pending, a message sent from the phone reached Claude, the pane switched to Chat by itself and showed the user bubble and the reply |

The E2E found two defects fixed on the way: the Host's `.list` reply dropped the agent fields
(#1040), and a wrong pairing code left the Add Host sheet on "Connecting…" (the Host session now
gives up after ten seconds).

## Deviations from plan

- iPad uses the same stack navigation as iPhone for now; the planned sidebar layout is deferred.
- Tool cards are `DisclosureGroup`s rather than a custom card; code blocks and diffs are monospaced
  text, not syntax-highlighted.
- Reading positions survive Chat ↔ Screen switches on one connection, but leaving a pane closes its
  connection, so they do not survive leaving the pane (the old sidebar kept sessions alive).

## Open questions

- Chat performance with very long sessions: items are laid out eagerly in pages of 120; a
  windowed layout may be needed for sessions with thousands of events.
- The `promptRespond` path (087 S3) is still missing; prompt cards only point to the Mac.
