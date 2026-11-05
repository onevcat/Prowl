# 089 — Mirror iOS Redesign: Plan

| | |
| --- | --- |
| **Status** | Planned |
| **Anchor date** | 2026-11-05 |
| **Primary PRs** | (fill in as slices merge) |
| **Related** | [088-mirror-ios-app](../088-mirror-ios-app/000-plan.md), [087-mirror-conversation-events](../087-mirror-conversation-events/000-plan.md), [086-sidebar-repository-groups](../086-sidebar-repository-groups/000-plan.md), `docs/remote-mirror.md`, issue #1043 |

## Background

088 rebuilt the iOS client as Hosts → Panes → Pane and merged with #1041. A walkthrough on
the iPhone 18 Pro simulator against a live Host (2026-11-05, `main` fd9b3830) showed that the
client works but reads as a debug tool:

- Every launch goes Hosts → Host → a flat pane list. With one paired Mac the Hosts screen is
  an extra step.
- The roster sorts projects by name. Shell panes fill most rows, their titles are
  `user@host:…` and truncate, and a blocked agent is not shown first.
- The phone cannot unblock an agent. A prompt shows "Answer on the Mac"; Screen mode has no
  keys; the Host refuses key input.
- Chat gives every tool call its own card. On an active agent, six cards fill the screen and
  push the agent messages out of view.
- Status colors differ from the Mac (working orange dot, blocked red, idle green), the
  accent is system blue, and the screens use form styling.

Defects found in the same walkthrough (fixed in slice P0):

| # | Symptom | Cause |
| --- | --- | --- |
| D1 | A pane made with New Agent Pane is treated as a Shell ("Shell panes are read-only"), Send is disabled, the title is "· master" | `MirrorLaunchModel.create()` (`Mirror/Shared/MirrorLaunchModel.swift`) builds the descriptor without `agent` and with an empty pane title |
| D2 | The user bubble shows the "Prowl dispatch completion protocol v1" text | the Profile launch appends it to the prompt (`App/Sources/Domain/AgentProfile/AgentProfileLaunchPlan.swift`); the transcript keeps it |
| D3 | "Waiting for your answer / permission decision on the Mac" rows stay in red after the prompt is resolved | `MirrorConversationStore` appends an attention item for each `blocked` status and never removes it |
| D4 | Lists, headings and tables in agent messages show as raw Markdown | `MirrorDocumentView` is the terminal text reader and renders inline Markdown only |
| D5 | The keyboard covers Create and Mirror; the form cannot dismiss it | no `scrollDismissesKeyboard` or keyboard toolbar in `MirrorLaunchView` |
| D6 | A pending Claude AskUserQuestion or permission prompt is not in Chat until it is answered | Claude Code 2.1.318 writes no assistant or `tool_use` record while the prompt waits; `ClaudeConversationAdapter` reads the transcript only |

## Goals

- **Agents first.** The app opens on the agents of the last Host. Hosts become a switcher in
  the title menu. The Hosts list shows only before the first pairing (onboarding).
- **Show what needs the user.** A "Needs You" area lists blocked panes and panes that finished
  after the user last looked. Projects follow the Mac sidebar order, groups and colors.
- **Same design language as Prowl for Mac.** Same state colors, the Bagua working indicator,
  agent icons, repository colors. Native controls, SF Symbols, Liquid Glass.
- **Agent messages stay in view.** Consecutive tool calls merge into one quiet summary row.
- **Act from the phone.** Answer prompts (087 S3 `promptRespond`), send keys in Terminal
  mode, stop a working agent.
- **Start sessions from the phone** with the Mac's projects and Agent Profiles.

### Non-goals

- Push notifications, an internet relay, Android parity (follows the iOS design).
- Arbitrary shell command input to Shell panes. Key input is for agent panes only.

## Design / Approach

### Flow

```
First launch: Onboarding (scan QR; manual address as fallback) → Agents
Later:        Agents of the last Host (connects at launch)
Agents ──tap──▶ Pane (Chat ⇄ Terminal)
   └── + ──▶ New Session sheet ──send──▶ new Pane
Title menu "<Host name> ⌄": switch Host · Add Host… · Manage Hosts
```

### Agents (replaces `HostsView` + `PanesView` as root)

- Title: Host display name with `chevron.down` and a connection mark. When the Host is not
  reachable, a banner under the title shows the reason and Retry; the last roster stays.
- Project chips: All, then the projects in Mac sidebar order. A chip shows a red dot when a
  pane in it is blocked.
- **Needs You** horizontal cards: blocked panes, then done panes. A card shows state, title,
  project and one line (the question or the last agent message).
- Sections by project, with the repository color. Rows: title; agent icon + last agent message
  in secondary text; trailing state. Sort in a section: blocked, working, done, idle.
- Shell panes fold into one "N terminals" row per project. `…` → Show Terminals lists them.
- A `+` in each section header starts a session in that project.

### Pane (replaces `PaneHeader` and the segmented picker)

- Navigation title is a menu with `chevron.down` to jump to another pane of the same project;
  subtitle "<state> · <project> / <worktree>".
- Trailing glass group: one Chat ⇄ Terminal toggle (`apple.terminal` /
  `bubble.left.and.text.bubble.right`) and `…` (History, Take Over, Disconnect).
- **Chat**
  - Agent messages render full Markdown: headings, lists, code blocks, tables.
  - **Tool steps.** Consecutive tool items between two messages merge into one row in
    `.footnote` secondary style: a small icon set, a count ("5 steps") and a failure count
    in red when a step failed. Tap expands the group to one compact line per step
    (icon, title, status glyph) in the same secondary style. Command, output and diff are
    one more tap away, in a sheet. A running group shows only its live step, with the Bagua
    indicator. Reasoning ("Thought for 2s") joins the group.
  - User bubbles use the brand color. Text that Prowl injected (D2) folds into a
    "Prowl instructions" disclosure.
  - Resolved prompts leave one line in history ("Answered · Blue", "Allowed · Bash").
- **Prompt panel** docked above the composer while a prompt is open: the question and
  numbered option buttons; permission prompts get Allow / Always Allow / Deny. Answers go
  through `promptRespond`. Attention rows go away.
- **Composer**: a floating glass capsule. Trailing button is `arrow.up` (send) when there is
  text and `stop.fill` while the agent works and the field is empty. The hint line shows only
  for queued, rejected or unknown receipts.
- **Terminal**: `vt-v1` with a fixed column grid and ANSI colors (zoom or horizontal scroll),
  a key bar (esc, ^C, ⇧⇥, ⇥, arrows, return) and a "Type a command" field.

### New Session (replaces the `MirrorLaunchView` form)

A sheet shaped like a composer: two chips above the message field, project
(`folder`, Mac sidebar groups and colors, recents first, search, worktrees as sub rows) and
Profile (agent icon, model, effort; last choice remembered). Send creates the pane and opens
it. The descriptor takes `agent` from the Profile runtime (fixes D1).

### Visual language

| State | Mac source | iOS |
| --- | --- | --- |
| Working | `.orange` + `BaguaWorkingIndicator` | same; the glyph is static when Reduce Motion is on |
| Blocked ("Needs you") | `.red` | same |
| Done (idle, not seen) | `.blue` | same |
| Idle | `.secondary` | same, no badge |
| Failed / disconnected | — | `exclamationmark.circle.fill` in red with the reason, stronger than the state dot |

State colors and the Bagua indicator come from
`App/Sources/Features/ActiveAgents/Views/ActiveAgentRow.swift`; "done" is
`PaneAgentState.displayState` (`App/Sources/Domain/AgentDetection/PaneAgentState.swift`).
The brand color is the deep green of the app icon. It is the iOS `AccentColor`
(`Mirror/iOS/ProwlMirror-iOS/Assets.xcassets/AccentColor.colorset`), with the mint
`ProwlAccent` (#5BE4C0) as the dark-mode variant. All other colors are system semantic colors.

### Host and wire additions

| Need | Change |
| --- | --- |
| Agents screen | roster: Host display name, `displayState` (adds done), repository color, sidebar group and order, tab ID, last agent message, last activity time |
| New Session | `profiles`: icon, model, effort; worktree list in sidebar order with groups |
| Prompt panel | `promptRespond` (087 S3); Claude pending prompts from the `PermissionRequest` hook, not only the transcript (D6) |
| Terminal, Stop | key input for agent panes (`agents.input` keys or a new command), limited to a key allow list |
| D2 | mark the injected launch text so clients can fold it |

## Alternatives & decisions

| Option | Decision |
| --- | --- |
| Keep Hosts as the root | Rejected: one-Mac users pay a step on every launch. Hosts move to the title menu. |
| New palette for iOS (orange for blocked) | Rejected by onevcat (2026-11-05): use the Mac state colors and the Bagua indicator. |
| One card per tool call (088) | Replaced: merged step groups with a count; details on demand in secondary style. |
| Brand color vs system colors only | onevcat allows the brand color (2026-11-05); only the accent assets are custom. |
| Minimum iOS 18 | Raised to iOS 26 for Liquid Glass; iOS 27 is acceptable when an API needs it. |
| Prompt answers and key input later | onevcat put both in scope (2026-11-05): without them the phone cannot unblock an agent. |
| Segmented Chat / Screen picker | Replaced by one toolbar toggle; the picker took a full row. |

## Slices

| Slice | Content |
| --- | --- |
| P0 | D1–D5 fixes; tests for the launch descriptor and attention removal |
| S1 | iOS 26 target, color and state tokens, Bagua indicator; Agents screen, Host title menu, onboarding; roster wire fields |
| S2 | Pane chrome, Chat restyle (Markdown, tool step groups, folded injected text), composer |
| S3 | New Session sheet; `profiles` and worktree wire fields |
| S4 | `promptRespond` on Host and client, Claude hook prompts (D6), prompt panel |
| S5 | Terminal: `vt-v1` rendering, key bar, key input on Host, Stop |

Each slice ships simulator screenshots (light and dark) against a live Host and updates
`docs/remote-mirror.md` when user-facing behavior changes.

## Amendments
- Updated 2026-11-06: P0 fixed D1–D5 on the client — see [002-p0-defect-fixes.md](002-p0-defect-fixes.md)
