# 089.007 — S5: Terminal Keys and Stop

## Context

The plan's S5 combined two kinds of work. The first was a real terminal view (`vt-v1` with a fixed grid and ANSI colors). The second was the keys a phone needs for a TUI, plus a way to stop a working agent. Research on Ghostty-based iOS terminals (2026-11-06) showed that the terminal view is its own project. So S5 ships the keys and Stop, and the terminal view becomes a follow-up.

## Change

| Area | Change |
| --- | --- |
| Command | `agentKeys {pane, keys}` behind the capability `agent-keys`. The keys are allow-listed (`esc`, `ctrl-c`, `tab`, `shift-tab`, `up`, `down`, `left`, `right`, `enter`), with at most 8 per command (`MirrorCommandRequest.AgentKeys.isAllowed`). `MirrorHost.pressKeys` checks the lease. `GhosttyMirrorPaneSource.pressKeys` accepts only panes with a detected agent, applies the same input protection as typed input, and sends one key every 60 ms. The refusal code is `KEYS_REFUSED`. |
| Key bar | `MirrorKeyBar` shows glass buttons for those keys under the Terminal view of agent panes. It hides in landscape while composing. A refusal shows in red in the composer's note. |
| Stop | While the agent works and the draft is empty, the composer's Send turns into a red Stop. It confirms, then sends `esc`, which interrupts Claude Code and Codex. |

Review round 1 fixes:

- `pressKeys` checks `isLive` (connection and lease) and `MirrorKeyGuard` before every key (S4-R2, S4-R3).
- In Terminal, `MirrorSession.agentState` reads the roster, because the conversation stream is paused there. So Stop follows the real state (S5-R1).
- The prompt panel shows in Chat only (S5-R1).
- Key and Stop refusals show in the composer's note in both modes (S5-R2).

Round 2 fix (S5-R3): `ctrl-c` must be the last key in a command, and `pressKeys` stops when the pane's agent is gone or has changed. So the rest of a batch never reaches the shell underneath.

Tests:

- `agentKeysAllowOnlyNavigationAndControlKeys` (Mac).
- `testTerminalKeyBarPressesKeysOnTheHost` and `testRefusedKeysExplainWhyInTheComposer` (iOS UI, fixture Host).
- `takeoverStopsKeysBetweenPresses` (Mac).
- `terminalModeFollowsTheRosterState` (iOS).
- E2E: Stop interrupted a real Claude turn, and Up from the key bar reached the pane.

## Decisions

- Keys only for agent panes. Shell panes stay read-only from the phone, as before, because the Host cannot verify a shell's command line.
- Stop is Escape, not Control-C. Both agents treat Escape as "interrupt this turn", while Control-C can quit Claude Code when the composer is empty.
- **The `vt-v1` terminal view is deferred.** The research summary is in [001-action.md](001-action.md), Open questions. In short: libghostty-vt with an own CoreText renderer, pinned to the Mac fork. Before building that, decide how a phone-width grid relates to the Mac pane's columns: resize, or pan.

## Refs

#1051 (S5).
