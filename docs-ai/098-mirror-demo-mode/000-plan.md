# 098 — Mirror demo mode: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-11-23 |
| **Primary PRs** | see [001-action.md](001-action.md) |
| **Related** | [088-mirror-ios-app](../088-mirror-ios-app/000-plan.md), [089-mirror-ios-redesign](../089-mirror-ios-redesign/000-plan.md), [095-mirror-push-notifications](../095-mirror-push-notifications/000-plan.md) |

## Background

The iOS app (Prowl Mirror) is useless without a paired Mac: a fresh install shows only
**Pair with a Mac**. App Review must reach the app's features (Guideline 2.1, "Before You
Submit": a demo account or a fully featured demo mode, plus any hardware a review needs)
and may reject an app that does not work on its own (4.2.3). A reviewer will not install
Prowl on a Mac and pair it. Apple asks hardware-dependent apps for a demo video, which we
will also send, but a demo inside the app removes the dependency for the first review.

The client already reads every Host through `MirrorTransport`
(`Mirror/iOS/ProwlMirror-iOS/Infrastructure/MirrorRemoteConnection.swift`), and
`MirrorHostSessions` builds the roster and pane connections through injected factories.
The DEBUG `MirrorUIFixture` uses that seam for UI tests, but it is compiled only in DEBUG,
is driven by launch arguments, and replays internal review transcripts.

## Goals

- A **Try Demo** button on the onboarding screen opens the real app — Agents, Chat,
  Terminal, prompt answers, composer, Stop, New Session — on an in-memory demo Mac.
- Only the data source differs. The demo uses the same views and sessions as a real Host;
  no demo-specific screens.
- Nothing demo-related shows to a person with a paired Mac.
- The onboarding screen also points people without Prowl to https://prowl.cat/.

### Non-goals

- Review notes, the demo video, and App Store metadata (handled at submission).
- Push notifications in the demo (they need a Mac and the gateway; the video shows them).
- Replacing the DEBUG UI-test fixture; it keeps its launch arguments.

## Design / Approach

**Data source.** `MirrorDemoHost` is an in-memory Host: one world of panes (descriptor,
terminal text, conversation events, open prompt) shared by every connection it serves.
`MirrorDemoHost.makeTransport()` returns a `MirrorTransport` that answers the wire
protocol like a Host: `list` → `panes`, `subscribe` → `subscribed` and a
`conversationSnapshot` or a `textFrame` (with `screenPrompt`), `history`, `refresh`, and
the `command` family (`list`, `profiles`, `create`, `agentsInput`, `send`,
`promptRespond`, `agentKeys`). A change in the world (an answer, a new message) is pushed
to the connections subscribed to that pane, as a Host does. Timing runs on an injected
`Clock` so tests drive it.

**Wiring.** `MirrorDemo` owns a `MirrorHostStore` on a volatile `UserDefaults` suite with
one record (the demo Mac) and a `MirrorHostSessions` whose factories return demo
transports. `ContentView` shows `MirrorRootView` with either the real pair or the demo
pair. An environment value tells the Agents title menu that it runs a demo, so it offers
**Pair with a Mac** and **Exit Demo** instead of **Add Host…** and **Manage Hosts…**.

**Isolation.** The demo Host does not list `push-v1`, so no push registration starts; no
socket, Keychain item, camera or local network prompt is touched; the store suite is
cleared on start and exit; the demo does not survive a relaunch.

**Content.** Authored English data in Swift, on our own projects (Kingfisher, FengNiao,
Prowl), covering every state:

| Pane | Agent | State | What the demo shows |
| --- | --- | --- | --- |
| Fix flaky prefetch test | Claude Code | blocked | a permission menu; answering it resumes the agent, which finishes |
| Scan unused images | Codex | working | a running tool; Stop (Esc) interrupts the turn |
| Draft 8.4 release notes | Codex | done | Markdown answer with a list |
| Review sidebar groups | Claude Code | idle | tools, a table and code in Chat |
| zsh, swift test | — | shell | terminal text and history; commands echo a demo note |

A message sent to an agent appears as the user's message, the agent works briefly, then a
scripted reply says that in the demo no agent runs and what Prowl does on a Mac. New
Session creates a pane that starts the same way.

## Alternatives & decisions

- **Ship the DEBUG fixture in Release** — rejected: it is shaped by test flags, and its
  transcripts hold internal prompts and non-English text.
- **A hidden reviewer trigger** — rejected: Guideline 2.5.19 forbids hidden features; the
  demo is an ordinary, visible onboarding choice.
- **Demo screens built for the demo** — rejected by onevcat: only the data source
  changes, so the demo shows the real app and stays correct as the app changes.
- **Persist the demo** — rejected: a relaunch returns to onboarding, so a person who
  tried the demo is never left with a fake Mac.

## Amendments
