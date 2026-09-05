# 023 — Amendment: Agent Status Badges + Trackpad Navigation (2026-06-10)

## Context

By June the Active Agents panel and per-pane agent detection existed
([030-agent-status-detection](../030-agent-status-detection/000-plan.md)), but Shelf
spines showed no agent state — checking whether a book's agent was working meant opening
it or the panel. Separately, Shelf book switching had no trackpad affordance.

## Change

- **Agent status badges** at the bottom of each spine, grouped by worktree; agent
  detection stays enabled while Shelf is visible even when the Active Agents panel is
  hidden (a resync was added in review for the repository-list-emptied edge case).
  Gated by the `showActiveAgentStatusInShelf` setting.
- **Two-finger horizontal trackpad switching** between books, one switch per gesture
  (`ShelfSwipeEventMonitor` in `supacode/Features/Shelf/Views/ShelfView.swift`).
- The community PR (#432, `[codex]`) changed book navigation to bounded edges, which
  silently removed the long-standing keyboard wrap-around because `shelfBook(atOffset:)`
  is shared by ⌘⌃←/→ and the new gesture. The review pass (#434, which merged #432's
  commits unchanged) restored wrap-around for both input paths and re-added the wrap
  tests.

## Decision: keep the 3-second status hold; do not port the herdr refactor

The badge values come from the agent detection subsystem, which was originally ported
from herdr v0.5.6 (see entry 030). Shortly after the badges shipped, #438 (2026-06-13)
stabilized status flicker by widening the *working* hold to 3 seconds for all agents
(`workingStateHold` in `supacode/Domain/AgentDetection/PaneAgentState.swift`).

A 2026-06-12 review of herdr upstream (to v0.6.10/HEAD) found that herdr had meanwhile
abandoned fixed-duration holds for a heavier scheme: bare-idle vs visible-idle splitting
with confirmation rescans, OSC-only working evidence for Claude/Codex, and per-agent TOML
manifests. Deliberate fork decision (2026-06-13): the 3-second hold is satisfactory in
practice — keep the simple approach and **do not port** the herdr refactor unless false
reports recur at 3 s. The reviewed-but-not-ported material is archived with the upstream
review notes; the detection story itself belongs to entry 030.

## Refs

- PRs #432 (community), #434 (review pass; merged both), #438 (hold widening, entry 030)
- [030-agent-status-detection](../030-agent-status-detection/000-plan.md)
- [029-active-agents-panel](../029-active-agents-panel/000-plan.md)

## Current state

Badges render in `supacode/Features/Shelf/Views/ShelfSpineView.swift`
(`ShelfMetrics.agentStatusMarkerSize`); the setting lives in
`supacode/Features/Settings/Models/GlobalSettings.swift`
(`showActiveAgentStatusInShelf`). Wrap-around navigation and the swipe gesture are
covered by `supacodeTests/ShelfFeatureTests.swift`. The 3-second Working hold described
above was retired on 2026-09-05; see
[030.015](../030-agent-status-detection/015-deterministic-live-footer-coverage.md).
