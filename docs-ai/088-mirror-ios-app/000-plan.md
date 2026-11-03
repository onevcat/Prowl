# 088 — Mirror iOS App: Plan

| | |
| --- | --- |
| **Status** | Planned |
| **Anchor date** | 2026-11-04 |
| **Primary PRs** | (fill in as they merge) |
| **Related** | [087-mirror-conversation-events](../087-mirror-conversation-events/000-plan.md), [067-remote-mirror](../067-remote-mirror/000-plan.md), `Mirror/iOS/README.md`, `docs/remote-mirror.md`, issue #989 |

## Background

The iOS client under `Mirror/iOS` was imported as an experiment (067.004–005) and grew
feature by feature: one `MirrorSession` per mirrored pane with its own connection, a
sessions list, a connection sheet with IP / port / code, a text reader with remote scroll
buttons, a composer whose Send goes through `list` → `agents.input` → receipt. On a phone
it is close to unusable: the text view reflows an 80-column TUI, there is no notion of
Hosts or of what an agent is doing, the pane list is flat, and sending fails in ways the
user cannot read (agent working → refused; receipt unknown → composer locked).

087 gives the Host a `conversation-v1` representation. This entry rebuilds the client
around it: Hosts → panes with state → a pane that is a chat when the agent is known and a
screen otherwise, with one composer that tells the truth about delivery. onevcat asked for
a redesign that may discard the current structure (2026-11-04).

## Goals

- A clear three-level flow: **Hosts** (paired Macs, reachable or not) → **Panes** of a
  Host, grouped by project, each with agent badge and live state → **Pane**.
- A pane opens in **Chat** when `conversation` is `available`, in **Screen** otherwise;
  a segmented control switches between them on the same connection; a Screen pane whose
  agent appears switches to Chat by itself, and a Chat pane whose agent leaves falls back.
- Chat renders the 087 event stream: turn separators, user and assistant messages
  (Markdown), tool cards (collapsed, expandable output and diff), prompt cards, status
  rows, session dividers, queued-message pills. Resume by sequence after a reconnect.
- Screen keeps the existing text reader, remote scroll and History with less chrome.
- One composer for both modes: send through `agents.input`; state and hint derived from
  the agent status (`working` → the message is queued on Claude, otherwise disabled with
  a reason); receipts shown inline, never a locked composer without a way out.
- Pairing by QR or manual code from the Hosts screen; saved Hosts reconnect with their
  credential; a Host's panes refresh while the list is visible.
- iPhone first, iPad keeps a sidebar layout. iOS 18+, no third-party dependencies.

### Non-goals

- Answering prompts from the phone (087 S3, `promptRespond`) — the prompt card shows the
  question and choices and tells the user to answer on the Mac until the Host supports it.
- Push notifications, an internet relay, Android (follows once iOS settles).
- Shell input from the phone (Host still refuses it).

## Design / Approach

- **Model**: `MirrorHostStore` (persisted hosts: id, alias, address, port, last seen;
  credential in Keychain through the existing `MirrorCredentialVault`),
  `MirrorHostSession` (one connection per Host for `list`, `profiles`, `create`; refreshes
  the pane roster with `agent`, `agentState`, `conversation`), `MirrorPaneSession` (one
  connection per opened pane; subscribes `conversation-v1` or `text-v1`, keeps a
  `MirrorConversationStore` of events keyed by sequence, or the text state), the shared
  `MirrorConversationEvent` from `Mirror/Shared`.
- **Conversation store**: appends snapshot and batches, acknowledges each, derives view
  items (tool start+end merged into one card, consecutive status events collapsed, the
  latest `agent.status` as the pane state), remembers `latestSequence` for `since`.
- **Views**: `HostsView` (list + Add Host sheet with scanner / manual), `PanesView`
  (sections by project, rows with badge / state dot / "mirrored elsewhere"), `PaneView`
  (status pill, Chat | Screen picker, `ConversationView` or `ScreenView`, `Composer`).
  Native SwiftUI, system colors, Dynamic Type; no custom chrome.
- **Fixtures**: DEBUG launch arguments feed `ConversationView` from
  `Mirror/Fixtures/conversation/*.events.jsonl` so screenshots and UI tests need no Host.

## Alternatives & decisions

| Option | Decision |
| --- | --- |
| Keep `MirrorSession` and bolt Chat onto `MirrorReadingView` | Rejected: the session mixes connection, roster, text, history, scroll and submission state; the new flow needs Host and pane as separate objects. |
| One connection per Host multiplexing panes | Rejected: the wire allows one subscription per connection; a pane keeps its own connection, the Host session only lists and launches. |
| Markdown via a third-party package | Rejected: SwiftUI `Text(markdown:)` / `AttributedString` covers inline Markdown; code blocks and tables get a monospaced block, no dependency. |

## Slices

| Slice | Content |
| --- | --- |
| A | Model: host store, host session, pane session with conversation store; unit tests on fixture events |
| B | Hosts and Panes screens; pairing; pane rows with state |
| C | Pane screen: Chat view, Screen view, composer, mode switch and auto-switch |
| D | Fixture launch mode, screenshots on the simulator, UI tests for Chat rendering |

## Amendments

(none yet)
