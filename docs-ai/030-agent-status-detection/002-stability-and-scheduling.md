# 030 — Amendment: Status Stability & Lazy Scheduling (2026-06-13)

## Context

A month of live use surfaced two distinct false-idle classes and one cost problem:

1. **Working → Done → Working flapping.** Agents blank their on-screen working cues
   (spinner, "esc to interrupt") between steps, so the raw heuristic flips to idle and
   back. The v1 hold was Claude-only and 1.2 s — too short for real inter-step gaps, and
   Codex/Gemini/etc. had no hold at all.
2. **Viewer hints quoted in conversation pinned a working agent to Idle.**
   `detectClaude` treated `ctrl+r to toggle` / `⌕ Search…` as transcript-viewer chrome
   *anywhere* on screen and short-circuited to forced idle. A chat merely quoting those
   strings (observed live: a conversation about these very heuristics) kept the pane
   Idle for minutes — no hold duration can absorb a raw state that stays wrong.
3. **Polling cost.** Detection ran for every pane whenever the panel UI wanted it,
   regardless of whether the pane had ever seen input.

## Change

- **#438 — stabilize status:**
  - Generalized the working → idle hold to **all** detected agents
    (`claudeWorkingHold` → `workingStateHold`) and widened it **1.2 s → 3.0 s**.
    `blocked` bypasses the hold so permission prompts surface immediately. Accepted
    trade-off: a genuine finish reports Done up to ~3 s late in exchange for no flapping.
  - Viewer-chrome hint strings are trusted only on the bottom chrome lines (last 3
    non-blank); a frame showing viewer chrome now yields `.unknown` ("no signal") instead
    of forced idle, and the stabilizer keeps the last trusted state + refreshes the hold
    while the overlay stays open. Also fixes the flash-to-Done when opening ctrl+r/ctrl+o
    during work.
- **#441 — lazy scheduling:** per-pane `AgentDetectionSchedule` replaces UI-driven
  enable/disable: panes start `cold` (no polling), any input/paste/CLI write warms them
  for a 30 s window at the 2 s cadence, and only a detected runtime promotes to `active`
  (300 ms). Losing the agent demotes back through warm to cold, tearing the task down.

The 3 s hold was a deliberate decision at the time: the 2026-06-12 herdr upstream
review explicitly chose not to adopt herdr's later detection refactor. It was retired
on 2026-09-05 after generic time and screen-motion inference proved too aggressive;
see [015](015-deterministic-live-footer-coverage.md).

## Refs

- PR #438 (merged 2026-06-13) — `stabilizeAgentState`, `ScreenHeuristics` viewer-chrome
  handling, `docs/components/agent-detection.md` update.
- PR #441 (merged 2026-06-13) — `supacode/Domain/AgentDetection/AgentDetectionSchedule.swift`,
  wake/teardown paths in `WorktreeTerminalState+AgentDetection.swift`.

## Current state

Verified 2026-09-05: the time-based Working hold has been removed; explicit
working/blocked/idle observations apply immediately, while `.unknown` keeps the previous
state in `supacode/Domain/AgentDetection/PaneAgentState.swift`.
`AgentDetectionSchedule.warmWindow = 30`, `activeAgentDetectionInterval = 300 ms`, and
`idleAgentDetectionInterval = 2 s`. Covered by `PaneAgentStateTests` and
`AgentDetectionScheduleTests`.
