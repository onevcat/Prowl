# 066 — Agent Island: Plan

| | |
| --- | --- |
| **Status** | Implemented — see [001-action.md](001-action.md) |
| **Anchor date** | 2026-09-01 |
| **Primary PRs** | #753 (original implementation, contributed by @SunChJ); #756 (fork-owned continuation); #758 (interaction and shortcut refinement) |
| **Related** | [029-active-agents-panel](../029-active-agents-panel/000-plan.md), [036-window-management-hardening](../036-window-management-hardening/000-plan.md), [064-agent-completion-signals](../064-agent-completion-signals/000-plan.md), `docs/components/agent-island.md` |

## Background

Active Agents lives in Prowl's sidebar. It already owns the canonical per-pane roster and the
Working, Blocked, Done, and Idle presentation states, but it cannot surface that state while
another application is in front. A blocked or finished agent waiting for the user is easy to miss.
The requested extension is a Notchy-style top-of-screen island that is useful on both notched and
external displays without introducing a second agent lifecycle model. It is deliberately a more
intrusive surface than the sidebar, so it ships opt-in and off by default.

## Goals

- Present the roster's state mix at a glance: per-state counts in the compact bar.
- Present Blocked and unviewed Done entries as stronger callouts whose lifetime is governed by the
  existing Active Agents state transitions.
- Open a secondary roster with the same rows and actions as the sidebar panel, including Idle
  entries and a persistent Open Prowl action.
- Focus the exact worktree, tab, and pane after surfacing Prowl when an island row is selected.
- Support automatic or user-selected display placement with notch-aware and floating-pill
  geometry, Spaces, fullscreen applications, Stage Manager, and display hot-plugging.

### Non-goals

- A fifth agent state, a parallel acknowledgement model, or a second roster.
- Inline permission approval or arbitrary terminal input from the island.
- Treating an ambiguous agent disappearance as a failure.
- Multiple synchronized islands, per-display instances, or configurable island metrics.

## Design / Approach

### Contextual exposure principle

Agent Island uses contextual progressive disclosure. It must not present every available feature
at once. Each control, hint, or callout appears only when the current state makes it relevant and
immediately actionable—for example, paging only with multiple pages, display switching only with
multiple connected displays, and opacity only in floating mode. If a capability has no distinct
situational value, it belongs in the expanded roster or Settings rather than the compact surface.

The product goal is not maximum feature discoverability in every state. It is a restrained surface
whose next action feels obvious and timely, giving users the sense that Prowl anticipated their
need without asking them to parse unrelated controls. New Agent Island affordances must identify
their exposure condition as part of their design; “always visible” requires explicit justification.

`ActiveAgentsFeature` (`supacode/Features/ActiveAgents/Reducer/ActiveAgentsFeature.swift`) stays
the single source of truth. Its island-owned state is limited to presentation/navigation plus a
transient global-hot-key registration failure used by Settings. `islandAttentionEntries` is a
derived projection of `displayState`; nothing island-specific mutates or masks an entry.

Actions raised from the island wrap the sidebar action they stand for: `island(Action)`. The
reducer forwards the wrapped action unchanged and collapses the roster only when it presents
Prowl UI (`Action.surfacesProwl`: pane focus, handoff HUD, workflow start); `AppFeature`
(`supacode/Features/App/Reducer/AppFeature.swift`) intercepts the same case to surface the main
window through `AppLifecycleClient` before the forwarded action runs, so focus and the HUD/sheet
paths stay single-sourced. `islandOpenProwlTapped` only surfaces the window. `agentIslandEnabled`
is mirrored into the reducer from settings the same way `showActiveAgentTabTitles` already is.

`AgentIslandWindowController`
(`supacode/Features/ActiveAgents/BusinessLogic/AgentIslandWindowController.swift`) owns one
borderless, nonactivating `NSPanel` that cannot become main, sits one level above the menu bar,
joins all Spaces and fullscreen applications, and hosts `AgentIslandView` scoped to the app store.
The compact panel cannot become key; the expanded roster temporarily becomes key without
activating Prowl so it can own local keyboard navigation. The controller observes the enabled
setting and creates or tears down the panel accordingly. Its user-assigned toggle is registered
globally only while entries exist and Prowl is in the background; in Prowl, normal menu routing
handles the shortcut. While disabled, nothing beyond the controller object and that observation
exists (the display catalog is resolved on first use). Outside-click and local key monitors exist
only while the roster is expanded.
`supacode/Features/ActiveAgents/Models/AgentIslandScreen.swift` holds the pure geometry
(`AgentIslandScreenLayout`: cutout rectangle from the screen's auxiliary menu-bar areas, display
resolution order, panel frame); `AgentIslandDisplayCatalog` (`BusinessLogic/`) keys screens by
CoreGraphics display UUID and refreshes on screen-parameter changes.

The views under `supacode/Features/ActiveAgents/Views/` are island-owned: `AgentIslandView`
(compact bar with equal wings around the physical cutout, attention collection, roster
container), `AgentIslandStateSummary` (per-state counts as state-colored symbols in attention
order; compact in the notch wing, one size up in the floating pill), `AgentIslandIconCluster` (up to three runtime icons, recent non-Idle first and Idle
last, `+N` overflow, Core Animation state rings), `AgentIslandAttentionCollection` (one or two
columns, up to three rows, with a bottom-right `+N` overflow badge), and `AgentIslandRosterContent` (composes the sidebar's
`ActiveAgentRow` with a "pane title · branch" subtitle, content-sized up to a 360pt cap). Sharing with the sidebar is deliberately
narrow: `ActiveAgentRowSupport.swift` extracts `ActiveAgentRowPresentation` (subtitle, help, pane
title, Workflow badge) and `ActiveAgentRowContextMenu` for both `ActiveAgentsPanel` and the island
roster; the sidebar's row and panel layout are otherwise untouched.

Settings add `agentIslandEnabled` (default `false`) and `agentIslandDisplayPreference`
(`AgentIslandDisplayPreference`: `.automatic` or `.display(id:name:)`) to `GlobalSettings`, with a
section on Settings › Agents › Display (`AgentIslandSettingsSection`). Automatic follows the Prowl
window's display, then a built-in notched display, the macOS main display, then the first screen.
A fixed display stores its UUID plus last-known name; when absent, placement follows Automatic
until it reconnects. The picker matches by UUID only (`AgentIslandDisplaySelection`).

## Alternatives & decisions

- **Separate island reducer with a mirrored roster** — rejected: it would diverge from Active
  Agents and duplicate handled/unhandled semantics.
- **Inline Allow/Deny controls** — rejected: agent runtimes share no safe reply protocol; the
  island navigates to the source pane instead.
- **One panel per screen** — rejected in favor of one selectable target.
- **SwiftUI scene** — rejected: level, collection behavior, screen anchoring, and outside-click
  handling need AppKit ownership.
- **Notch as a boolean** — replaced by the measured cutout from `auxiliaryTopLeftArea` /
  `auxiliaryTopRightArea` after labels landed behind the camera housing on a built-in display.
- **A cat mascot as the island identity** — three iterations were built and removed inside #753:
  a "Heixiu" black-cat silhouette whose tail detached into a drifting ball as the Working loop, a
  tail that projected agent icons with state lamps and a pose following the top state, and an
  AppIcon-derived mint silhouette. Each competed with the status information the compact bar
  exists to convey. Final: runtime icons with static state-colored outlines in the compact bar;
  attention cards retain state-paced gradient rings, with nothing decorative.
- **Single attention card plus `+N`** — rejected for a per-entry collection so every Blocked or
  Done agent stays individually actionable.
- **SwiftUI `TimelineView` at 30 FPS for the rings** — replaced by island-owned Core Animation
  layers so continuous invalidation stays off the main thread shared with Ghostty.
- **Always-key panel** — rejected: the compact island stays non-key. The expanded roster becomes
  key only for its temporary keyboard context and never becomes main or activates Prowl.
- **Global keyDown monitor for roster navigation** — rejected because it needs Accessibility or
  Input Monitoring. The expanded key panel handles navigation locally instead.
- **Toolbar button** — rejected. Agent presentation preferences live under Agents → Display,
  reachable from the roster footer.
- **Custom expansion transition** — removed; the roster appears directly while the panel resizes.
- **Directly clickable carousel icons** — considered on 2026-09-02 and declined: the compact bar
  stays a single toggle, and per-agent focus lives in the attention cells and the roster.
- **Working-name carousel** — the original compact bar rotated through Working agent names every
  four seconds with a hover pause. Replaced on 2026-09-03 by per-state counts on both placements:
  a name says little about what needs attention, and the counts made the carousel state, clock
  effect, and hover tracking dead weight, so they were removed rather than kept idle.

## Amendments

- Updated 2026-09-02: continuation on #756 — hover flag reset when the roster empties, display
  picker matched by UUID, unrelated formatting churn reverted, and the former working-note
  amendments (002–010) folded into this plan and [001-action.md](001-action.md).
- Updated 2026-09-03: keyboard-first hot-window entry, selection, and paging — see
  [002-keyboard-navigation.md](002-keyboard-navigation.md).
- Updated 2026-09-03: established contextual exposure as a product rule: controls and hints appear
  only when their supporting state makes them relevant and actionable.
- Updated 2026-09-04: replaced state-dependent global number grabs with one opt-in global entry
  and a priority-anchored local handling loop — see
  [003-prowl-shortcut-loop.md](003-prowl-shortcut-loop.md).

- Updated 2026-09-05: consolidated agent presentation settings and refined the floating grip — see
  [004-agent-display-settings.md](004-agent-display-settings.md).
