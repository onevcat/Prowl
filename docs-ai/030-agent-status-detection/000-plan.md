# 030 — Agent Status Detection: Plan

| | |
| --- | --- |
| **Status** | Implemented (retrospective) |
| **Anchor date** | 2026-05-09 |
| **Documented** | 2026-07-12 (backfilled) |
| **Primary PRs** | #274 (detection layer, shared with 029), #277, #283, #285, #354, #355, #438, #440, #441, #483, #484 (reverted), #515 |
| **Sources** | `doc-onevcat/plans/2026-05-09-active-agents-panel-plan.md` (detection design absorbed here, panel/UI design in [029](../029-active-agents-panel/000-plan.md); original removed in the docs-ai migration), change-list 2026-05-09 Ghostty fork-patch entry (ledger: [upstream-ledger.md](../017-upstream-sync-process/upstream-ledger.md)), PR descriptions |
| **Related** | [029-active-agents-panel](../029-active-agents-panel/000-plan.md), [045-native-agent-session-detection](../045-native-agent-session-detection/000-plan.md) (successor wave), [013-prowl-cli](../013-prowl-cli/000-plan.md) (`prowl agents`), [035-protected-terminal-close](../035-protected-terminal-close/000-plan.md), [ghostty-fork-sync.md](../007-ghostty-embedding-integration/ghostty-fork-sync.md), `docs/components/agent-detection.md` |

## Background

The Active Agents panel ([029](../029-active-agents-panel/000-plan.md)) needs to know, per
terminal pane, *which* coding agent is running and whether it is **working**, **blocked**
(waiting for user input, e.g. a permission prompt), or **idle**. Nothing in the app had
that signal: Ghostty's embedded C API did not even expose a surface's child PID, and the
agents themselves report nothing to the host (Claude Code does not emit OSC 9;4 progress
while it works).

The reference implementation was [herdr](https://github.com/ogulcancelik/herdr)
(Rust/ratatui), whose hybrid process-detection + screen-heuristics model was adapted to
Swift/GhosttyKit. Detection was Phase 0–1 of the Active Agents plan; this entry tracks the
detection layer itself and its long tail of hardening.

## Goals

- Identify the agent in each pane (Claude, Codex, Gemini, Cursor, Cline, OpenCode,
  Copilot, Kimi, Droid, Amp, Pi at v1) with **zero agent-side setup** — no hooks, no
  wrappers, no config in the agent.
- Classify per-pane status into `working` / `blocked` / `idle` from what is already
  observable (process table + rendered screen).
- Keep the classification logic pure functions, fully unit-testable without Ghostty, a
  pty, or async (herdr's `detect.rs` fixtures ported as the test base).
- Bound the cost: detection runs continuously across every open pane.

### Non-goals

- **Hook/socket self-reporting** (agents pushing authoritative semantic state) — called
  out in the plan as the root fix for UI-text fragility, deliberately deferred.
- Localization-proof detection: heuristics match agent CLI UI chrome (English constants);
  breakage on agent UI changes was accepted as a known maintenance cost, same trade as
  herdr.

## Design / Approach

- **Fork C API (hard prerequisite).** Ghostty exposes no surface child PID, so the
  submodule moved to `onevcat/ghostty` branch `release/v1.3.1-patched` carrying
  `ghostty_surface_pid(ghostty_surface_t)` and
  `ghostty_surface_foreground_process_group(ghostty_surface_t)` (the latter switched to
  `tcgetpgrp` on the pty fd for reliability). Recorded in the upstream ledger
  (2026-05-09 entry); the cherry-pick-forward upgrade procedure is the
  [ghostty-fork-sync runbook](../007-ghostty-embedding-integration/ghostty-fork-sync.md).
- **Two-stage detection with split authority** (herdr's model):
  1. **Process probe** owns *identity and liveness*: enumerate the pane's foreground
     process group (`proc_listallpids` / `proc_pidinfo` / `KERN_PROCARGS2`), then
     `AgentClassifier` scores candidates — argv[0] highest, then process name, then
     command-line tokens — so agents launched through wrappers (node, bun, python, bash)
     are still found.
  2. **Screen heuristics** own *state*: per-agent pure functions
     `(String) -> AgentRawState` scan the last ~24 non-blank lines for the agent's own UI
     chrome ("esc to interrupt", permission prompts, spinner glyphs), checked in priority
     order blocked → working → default idle. Glyph-class signals (braille/spinner frames)
     are ranked above text phrases as a layered defense against localized UIs.
- **Stabilization**, because both stages flicker:
  - presence: release a detected agent only after 6 consecutive probe misses (tool
    subprocesses briefly replace the agent in the foreground group);
  - state: a short hold before trusting a raw working → idle flip (v1: 1.2 s,
    Claude-only; agents blank their working cues between steps).
- **Polling loop** per surface on the MainActor: ~300 ms while an agent is detected, a
  slower cadence otherwise, reading the screen via the surface bridge.
- **Extensibility contract**: supporting a new agent = add an enum case, a classifier
  mapping, and a detector + fixtures.

### Status signals in context

Prowl ends up with two independent per-pane status sources, and the distinction matters:

- **Command/task progress** (`WorktreeTaskStatus` running/idle) comes from Ghostty's
  OSC 9;4 progress reports — i.e. *agent-self-reported*, fully decoupled from terminal
  rendering, which is why a tab can flip to idle before the pane finishes painting.
- **Agent status** (this entry) is *observed* from the process table and the rendered
  screen, and exists precisely because major agents (Claude Code) never emit OSC 9;4.

The two were later OR-ed together for the worktree running indicator (#475, entry 029);
the failed attempt to extend the first signal to plain commands is
[003-plain-command-running-indicator.md](003-plain-command-running-indicator.md).

## Alternatives & decisions

- **Hook-driven presence rejected.** Upstream supacode went the hook route: Kiro/Pi
  agent hooks were reviewed and skipped in the 2026-05-08 ledger batch, and the whole
  hook-driven coding-agent integration track (upstream #307/#311/#317/#330/#374) was
  skipped in the 2026-06-09 batch — it relies on upstream settings/hook modules the fork
  does not carry, and hooks require per-agent setup. The fork's process+screen scan
  needs none.
- **Fork patch over heuristic PID discovery.** An authoritative surface child PID was a
  ≤30-line Zig patch; guessing from the shell PID's descendants was rejected. Cost: the
  patch must be cherry-picked on every Ghostty submodule upgrade (runbook above).
- **Screen-text fragility accepted.** Detector strings are agent-rendered UI constants;
  each agent CLI UI revision may require a detector update. Accepted explicitly, with the
  fixture-heavy test suite as the safety net.
- **Keep the fork's own state projection.** The 2026-06-12 herdr upstream review
  (v0.6.10) decided against porting herdr's later detection refactor. The fork originally
  kept a 3 s Working hold ([002](002-stability-and-scheduling.md)); that hold was later
  retired in favor of immediate explicit screen states
  ([015](015-deterministic-live-footer-coverage.md)).

## Amendments

- Updated 2026-06-13: working hold generalized to all agents and widened to 3 s, viewer
  overlays reclassified as no-signal frames, and polling made lazily scheduled — see
  [002-stability-and-scheduling.md](002-stability-and-scheduling.md)
- Updated 2026-06-23: plain-command running-indicator fallback (#484) merged, then
  reverted; successor design tracked in issue #495 — see
  [003-plain-command-running-indicator.md](003-plain-command-running-indicator.md)
- Updated 2026-08-03: Codex and Claude screen evidence was bounded to live UI regions
  so transcript prose no longer impersonates confirmation or working chrome — see
  [004-live-region-evidence.md](004-live-region-evidence.md)
- Updated 2026-08-04: confirmation live regions were anchored to numbered selections so
  ordinary prompts and short completed responses cannot impersonate blocked UI — see
  [005-confirmation-live-structure.md](005-confirmation-live-structure.md)
- Updated 2026-08-06: current Codex pre-session directory trust, hook review, and sign-in
  dialogs are covered with screen-only rules — see
  [006-current-cli-pre-session-blockers.md](006-current-cli-pre-session-blockers.md)
- Updated 2026-08-06: a staged migration to typed Claude/Codex profiles, detector-faithful
  captures, versioned fixtures, and explainable reasons is proposed — see
  [007-screen-profile-migration-plan.md](007-screen-profile-migration-plan.md)
- Updated 2026-08-06: `prowl read --source detection` now captures the exact active-screen
  buffer used by production state detection — see
  [008-detector-faithful-cli-capture.md](008-detector-faithful-cli-capture.md)
- Updated 2026-08-07: a 15-screen Claude/Codex captured corpus, executable quarantine,
  provenance validation, and Release classifier baseline are in place — see
  [009-captured-screen-fixture-corpus.md](009-captured-screen-fixture-corpus.md)
- Updated 2026-08-07: screen classification now returns a typed state/reason result,
  caches the complete result, records stable transition reasons, and exposes an optional
  JSON-only `detection_reason` — see
  [010-explainable-screen-detection-results.md](010-explainable-screen-detection-results.md)
- Updated 2026-08-07: Codex state detection moved to a runtime-owned typed profile with
  explicit regions, ordered rules, stable reason IDs, and legacy-parity proof — see
  [011-codex-screen-profile.md](011-codex-screen-profile.md)
- Updated 2026-08-07: Claude state detection moved to its typed profile, current
  history-search viewer chrome was fixed from captured evidence, and the third-runtime
  adoption gate stopped further migration — see
  [012-claude-screen-profile.md](012-claude-screen-profile.md)
- Updated 2026-08-08: a captured failing screen supports the subagent-wait rule that
  012 deferred; adding it exposed that every row rule read one physical line, which
  misses Claude's wrapped rows on narrow panes — see
  [013-background-agent-wait-and-wrapped-rows.md](013-background-agent-wait-and-wrapped-rows.md)
- Updated 2026-09-05: captured Pi and Codex live footers gained explicit rules, while
  the time-based Working hold was retired in favor of deterministic screen state — see
  [015-deterministic-live-footer-coverage.md](015-deterministic-live-footer-coverage.md)
