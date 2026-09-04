# 030 — Agent Status Detection: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-05-09 | `onevcat/ghostty` branch `release/v1.3.1-patched` created: `ghostty_surface_pid` + `ghostty_surface_foreground_process_group` C APIs, `tcgetpgrp` foreground-group patch | ledger 2026-05-09 |
| 2026-05-10 | Detection layer ships with the Active Agents panel: `ProcessDetection`, `AgentClassifier` (11 agents), `ScreenHeuristics`, `PaneAgentState` + presence/stabilization, per-surface polling loop (300 ms active / 2 s idle; the PR text says 500 ms, tightened to 2 s in-branch, commit `9e31b6db`) | PR #274 |
| 2026-05-11 | Log volume trimmed to meaningful transitions only (agent lost, identity/state change); idle shells stay silent | PR #277 |
| 2026-05-13 | Claude blocked detection fixed for tall permission menus: interaction region extended to the end of the recent buffer (was `promptIndex + 11`) | PR #283 |
| 2026-05-13 | Memory leak fixed: per-tick `Task.detached` around the pure `detectState` call leaked task stacks + closures (~100–200 MB/h on release 2026.5.11, CLAW-97); call inlined | PR #285 |
| 2026-05-26 | `omx` / `oh-my-codex` recognized as Codex (alias classification, not a new agent) | PR #354 |
| 2026-05-26 | Heuristics read the *active screen* (`GHOSTTY_POINT_ACTIVE`) instead of the user-scrolled viewport, so scrollback browsing no longer corrupts state | PR #355 |
| 2026-06-13 | Working hold generalized to all agents and widened 1.2 s → 3.0 s; viewer-overlay chrome trusted only on bottom lines and mapped to `.unknown` (keep last state) | PR #438, [002](002-stability-and-scheduling.md) |
| 2026-06-13 | Oh My Pi (`omp` / `oh-my-pi`) detected as Pi, incl. its own working markers | PR #440 |
| 2026-06-13 | Lazy per-pane scheduling: `cold` (no polling) / `warm` (2 s, 30 s window after input) / `active` (300 ms) replaces UI-driven enable/disable | PR #441, [002](002-stability-and-scheduling.md) |
| 2026-06-14 | `prowl agents` CLI surfaces detection state (entry [013](../013-prowl-cli/000-plan.md)) | PR #442 |
| 2026-06-19 | Agent working/blocked folded into the worktree running indicator via `PaneAgentState.isBusy` (entry [029](../029-active-agents-panel/000-plan.md)) | PR #475 |
| 2026-06-20 | Qwen Code (`qwen`) detection: braille spinner, `esc to cancel` / `ctrl+c to cancel` | PR #483 |
| 2026-06-22 | Foreground process-group fallback for plain (non-OSC 9;4) commands merged | PR #484, [003](003-plain-command-running-indicator.md) |
| 2026-06-23 | #484 reverted on `main` (login-wrapper PID, preexec race, shell-list fragility) | commit `5b219791`, [003](003-plain-command-running-indicator.md) |
| 2026-06-26 | Ghostty reentry avoided: Active Agents entries built from cached pwd / launch working directory instead of calling `ghostty_surface_inherited_config` mid-callback (hang, issue #506) | PR #515 |
| 2026-07-12 | Native agent session identity layered onto detection (`session` fields on `PaneAgentState`) — entry [045](../045-native-agent-session-detection/000-plan.md) | PR #556 |

## Outcome & current state (as of 2026-07-12)

- **Domain** (`supacode/Domain/AgentDetection/`):
  - `DetectedAgent.swift` — 12 agents: pi, claude, codex, gemini, cursor (`cursor-agent`),
    cline, opencode, copilot, kimi, droid, amp, qwen.
  - `AgentRawState.swift` — raw `working`/`blocked`/`idle`/`unknown` plus display states
    (idle + unseen renders as **Done**).
  - `PaneAgentState.swift` — `stabilizeAgentState` applies explicit working/blocked/idle
    observations immediately while `.unknown` keeps the previous state,
    `AgentDetectionPresence.releaseMissThreshold = 6`, `isBusy` (working/blocked →
    worktree running indicator), and — since #556 — sticky `session` retention.
  - `AgentDetectionSchedule.swift` — `cold` / `warm(until:)` (30 s window) / `active`.
- **Infrastructure** (`supacode/Infrastructure/AgentDetection/`):
  - `ProcessDetection.swift` — `AgentProcessProbe` actor; foreground-job snapshots cached
    0.75 s per process group.
  - `AgentClassifier.swift` — argv0 / name / cmdline-token scoring, wrapper-runtime
    handling; aliases `omx`/`oh-my-codex` → codex, `omp`/`oh-my-pi` → pi.
  - `ScreenHeuristics.swift` — `nonisolated` pure per-agent detectors
    (`detectClaude`, `detectCodex`, … `detectQwen`).
  - `AgentSessionResolver.swift` / `AgentSessionProfile.swift` / `AgentPidArtifacts.swift`
    / `OpenCodeSessionStore.swift` — the 045 session-identity layer, not part of this
    entry's original scope.
- **Loop**: `supacode/Features/Terminal/Models/WorktreeTerminalState+AgentDetection.swift`
  — one `Task` per surface driven by the schedule; intervals
  `activeAgentDetectionInterval = 300 ms` / `idleAgentDetectionInterval = 2 s` in
  `supacode/Features/Terminal/Models/WorktreeTerminalState.swift`. `detectState` runs
  inline on the MainActor (post-#285); process enumeration hops to the probe actor.
- **Bridge**: `supacode/Infrastructure/Ghostty/GhosttySurfaceBridge.swift` — `childPID()`
  / `foregroundProcessGroupID()` wrap the fork C APIs (0 → nil); `readActiveText()` →
  `readActiveContentsForCLI()` (`GHOSTTY_POINT_ACTIVE`, post-#355).
- **Running indicator**: `WorktreeTaskStatus` (idle/running) =
  OSC 9;4 `progressState` per surface (`updateRunningState` /
  `isRunningProgressState` in `supacode/Features/Terminal/Models/WorktreeTerminalState+Surfaces.swift`)
  OR agent busy (`tabAgentBusyById` ← `PaneAgentState.isBusy`). **No** foreground-process
  fallback exists in the tree — #484 is reverted (`hasRunningForegroundProcess` greps
  empty).
- **User docs**: `docs/components/agent-detection.md` (agents list, state machine,
  cadence) — consistent with the code above.
- **Tests**: `supacodeTests/ScreenHeuristicsTests.swift`, `AgentClassifierTests.swift`,
  `PaneAgentStateTests.swift`, `AgentDetectionScheduleTests.swift`,
  `ProcessDetectionSmokeTests.swift`, `DetectedAgentTests.swift`.

## Deviations from plan

- **Poll cadence** evolved twice: the planned always-on 300/500 ms loop shipped as
  300 ms/2 s in #274, then became lazily scheduled (#441) — cold panes are not polled at
  all, so `idleAgentDetectionInterval` now only applies inside the 30 s warm window.
- **Hook-based authoritative status** (plan's Phase 3 endgame) was never built. The
  successor investment went instead into session *identity*
  ([045](../045-native-agent-session-detection/000-plan.md), #556) — status still comes
  from screen heuristics.
- **Plain-command running detection** (#484) was merged and reverted within a day; the
  capability gap is still open (issue #495; see
  [003](003-plain-command-running-indicator.md)).

## Open questions

- Issue #495 (add `GHOSTTY_ACTION_COMMAND_STARTED` from OSC 133;C) is still open: plain
  commands that emit no OSC 9;4 show no spinner unless an agent is detected. It would
  require another Ghostty fork patch.
- `AgentDetectionSchedule.observedAgent(now:)` ignores its `now` parameter (cosmetic;
  kept for API symmetry with `observedNoAgent`).
- `idleAgentDetectionInterval` is a slight misnomer post-#441 — it is the *warm* cadence;
  truly idle (cold) panes are not polled.
