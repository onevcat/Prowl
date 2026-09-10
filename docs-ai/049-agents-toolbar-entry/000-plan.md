# 049 — Agents Toolbar Entry: Plan

| | |
| --- | --- |
| **Status** | Implemented; the staged handoff HUD and the popover's Hand Off row were retired 2026-09-10 (see [063.020](../063-agent-workflows/020-handoff-workflow.md)); the Agents capsule, popover launcher, and workflow rows remain |
| **Anchor date** | 2026-07-20 |
| **Primary PRs** | #603 |
| **Related** | [047 cross-agent-handoff](../047-cross-agent-handoff/000-plan.md), [047.003 plan calibration](../047-cross-agent-handoff/003-plan-calibration.md), [048 agent-runtime-adapters](../048-agent-runtime-adapters/000-plan.md), [031 command-palette-architecture](../031-command-palette-architecture/000-plan.md), [058 unified-toolbar-layout](../058-unified-toolbar-layout/000-plan.md) |

## Background

047.003 identified discoverability as handoff's largest gap: the feature existed
only as `prowl handoff` and two palette rows. Three interaction proposals were
prototyped (native pull-down menu; popover control panel; status capsule with a
staged HUD). The **status capsule + two-stage HUD** direction was chosen: the
button carries passive information value even when never clicked, and the
capsule is a durable home for future agent-scoped actions (quick launcher,
cross review) without redesign.

The design below was settled in a full decision-tree interview on 2026-07-20.
Every entry point drives the already-converged `HandoffCoordinator` /
`TerminalClient.handoffSourceContext` / `AgentRuntimeAdapterRegistry.launchableAgents`
plumbing from 047.003; no new pipeline work is expected.

## Goals

- A toolbar "Agents" capsule left of the branch title: detected agent badge +
  agent name + display-state dot for the **selected pane**.
- A light menu (one info line + one action) opening a command-palette-style
  HUD: choose target → staged execution with Skip/Cancel → done.
- Replace the palette's direct-execution handoff rows with a single `Hand Off…`
  row that opens the same HUD.
- Background continuation (PR2): the HUD can be dismissed mid-run; the capsule
  becomes the progress indicator.

### Non-goals

- Model or execution-mode selection in the HUD. Launch configuration stays
  observation-inherited (048); user-defined configuration belongs to the future
  quick-launcher presets.
- Cross Review or any disabled placeholder menu items.
- A palette submenu architecture (см. open questions).
- Changing CLI behavior.

## Decisions (interview record, in dependency order)

1. **Capsule identity = selected pane.** The badge/name/state show exactly what
   `handoffSourceContext` resolves — the session a hand-off would move. Display
   and action can never diverge. Worktree-level aggregation stays with the
   sidebar dots and the Active Agents panel.
2. **No detected agent → disabled capsule** (generic icon, not hidden — no
   toolbar layout jumps). This surface is reserved: it later becomes the agent
   quick launcher (user-defined agent + initial prompt presets, one-click
   start). The mechanical no-source handoff path remains CLI-only for now.
3. **Menu = one info line + `Hand Off…`.** No Cross Review placeholder, no
   Save-notes item. The info line previews behavior in user language (the
   "brief" vocabulary; implementation terms like notes/prepare never surface):
   - resumable source (`exact`/`high` + adapter): `codex will brief the incoming agent first`
   - otherwise: `Hands this task to another agent in a new tab`
4. **HUD choose step = target list + one secondary row, zero options.**
   Targets from `AgentRuntimeAdapterRegistry.launchableAgents` (same-agent row
   stays, labeled as a fresh-session restart). Last row: "Only save progress,
   don't hand off" (the former save action; its only UI home). The prepare
   checkbox from the prototype is dropped — timing decisions move to the
   execution step's Skip. Config transparency: target rows state launch facts
   (`Launches with its default setup` / `Will bypass permissions (carried over
   from codex)`), read-only.
5. **Execution step semantics.** Four stages; only briefing is long (≤2 min).
   | Control | Available | Meaning |
   | --- | --- | --- |
   | Skip | briefing stage only | kill resume child → `preparation=skipped` → continue save/archive/launch |
   | Cancel | briefing stage only | kill resume child → abort everything; artifact untouched, no log line (Ctrl-C parity) |
   | (after briefing) | neither | remaining stages are sub-second and atomic; no fake cancellability |
   Skip's consequence lives in its tooltip only; no post-hoc warnings. A
   skipped brief degrades startup quality, never feasibility: `context.md`,
   the session excerpt, and the kickoff prompt are always fresh (047.002
   fail-safe path).
6. **HUD is dismissible during execution (PR2).** Esc/outside-click hides the
   HUD; the run continues. The capsule shows progress (spinner + tooltip;
   click reopens the HUD). Completion focuses the new tab, or toasts without
   stealing focus when the user moved to another worktree. Hard constraint
   from PR1 on: execution state is reducer-owned; the HUD is a projection.
   Concurrency: one in-flight handoff per worktree (menu action disabled
   meanwhile); different worktrees run independently.
7. **Palette converges to one row.** `Hand Off…` opens the HUD choose step.
   The two direct-execution rows are removed — one execution path, one
   behavior. No model/mode/notes vocabulary anywhere in the palette.

## Delivery slicing

- **PR1**: capsule (identity, state dot, disabled form, tooltip) + menu + HUD
  (choose / execute with Skip·Cancel / done) + palette convergence + docs.
  HUD stays open during execution. Execution state modeled in the reducer.
- **PR2**: dismiss-while-running, capsule progress form, reopen, cross-worktree
  parallelism verification.

## Verification

- Reducer tests: state machine (choose → run → done/cancelled), Skip vs Cancel
  outcomes, per-worktree serialization, palette delegate path, disabled-state
  gating. Coordinator behavior is already covered by 047.003's suites.
- Manual smoke: live codex session → capsule states → hand off to Claude Code
  with briefing; Skip mid-brief; Cancel mid-brief; no-agent disabled capsule.
- `make check`, `make build-app`, full `make test`.

## Open questions

- **Quick launcher** (capsule's no-agent form): preset model — agent + initial
  prompt + launch configuration; supersedes the HUD's zero-option stance for
  *starts* (not handoffs). Unscheduled.
- **Palette hierarchy**: a real second level (e.g. `Hand Off ▸` expanding
  registry agents inline) needs a palette navigation-stack architecture (031
  has none today — flat items + fuzzy query only). Revisit if more features
  want nesting; the HUD covers the need for now.
- Retention for `archive/` and `sessions/` remains open (047.003).

## Amendments

- 2026-07-20 (PR1 review): the capsule's pull-down is a **popover**, not a
  system `Menu`. macOS toolbars flatten custom `Menu` labels to their text,
  which dropped the agent badge and status dot (the capsule's core value);
  toolbar `Button` labels render rich views correctly. The popover also fits
  the roadmap better — future agent actions (quick launcher entries, cross
  review) land in the same panel as additional rows. Structure is unchanged:
  info line + `Hand Off…`. Two review fixes in the same pass: the badge
  resolves with the Active Agents panel's two-step token fallback
  (`iconForFirstToken(paneToken) ?? iconForFirstToken(canonicalToken)`), and
  the capsule opts out of the navigation group's shared glass background via
  `sharedBackgroundVisibility(.hidden)` (a fixed `ToolbarSpacer` does not
  split the navigation group). Known issue for verification: the capsule may
  be missing from the accessibility tree; audit before PR2.
- 2026-07-20 (PR1 review): the display-state dot is **removed, permanently**.
  It only ever described the selected pane — whose terminal is right in front
  of the user — duplicating the Active Agents panel and the sidebar dots at a
  6px size with no legend. This narrows decision 1: the capsule identifies
  the hand-off source (badge + name); it is not a status indicator. Decision
  6 changes with it: PR2's background-run progress uses the central toolbar
  status toast (existing `StatusToast` infrastructure), not a capsule
  progress form.
- 2026-07-20 (PR1 review, resolved): the accessibility-tree concern is
  **closed as not a bug**. An `AXUIElementCreateApplication` dump shows the
  capsule as a proper `AXButton` with its accessibility label and disabled
  state exposed; the earlier "missing" observation was an artifact of
  System Events enumeration against ambiguous same-named processes.
- 2026-07-20 (PR1 review): the popover action row explains itself in plain
  language under its title ("Pass this task to another agent in a new tab",
  plus "codex will summarize its progress first" when resumable); the
  "brief" vocabulary was replaced by "progress summary" throughout the HUD.
- 2026-07-20 (PR1 review): preparation-prompt hardening. The prompt now
  frames the reader ("another agent with none of your context") and gives
  per-section guidance; the kickoff prompt tells the receiver not to redo
  work listed under What Has Been Done and points at `archive/` for deeper
  history. The reply normalizer additionally discards chatter after a
  wrapping fence's closer. Guarded by a prompt/template/validator
  section-contract test and fence-handling fixtures.
- 2026-07-20 (PR1 review, superseding the embedding attempt from the same
  day): **`current.md` uses snapshot semantics — every preparation rewrites
  it fresh from the source session's own knowledge.** The 047 rolling
  carry-forward instruction had a structural flaw: the source has no real
  memory of earlier rounds' text, so "carrying forward" degrades into
  unverified copying and stale sections (finished Next Steps, outdated
  Current State) mislead the receiver. Embedding the previous artifact into
  the prompt (briefly implemented) only fed that copying. History instead
  flows through the reading chain — each receiver reads the previous
  snapshot at takeover, digests it, and its own summary reflects verified
  history — and through full copies in `archive/` (the `to` archive plus
  the preparation backup), which the kickoff prompt now references.
- 2026-07-20: **PR2 is deferred indefinitely.** Skip already covers the
  waiting pain (an impatient user hands off immediately with existing
  notes), hand-off is a low-frequency action, and the modal wait is bounded
  by the 2-minute resume timeout. The hard prerequisite — reducer-owned
  execution state with the HUD as a projection — shipped in PR1, so a future
  wave starts with zero rework if real usage surfaces the pain.
- Updated 2026-07-20: cancel/Skip now make reducer acceptance the boundary for transcribing a preparation reply, and Skip gains a keyboard path — see [002-briefing-cancellation.md](002-briefing-cancellation.md).
- Updated 2026-08-07: the redundant branch title was removed; Agents + Quick Launch now leads, followed by a separately surfaced Bell, across Normal, Shelf, and Canvas — see [058-unified-toolbar-layout](../058-unified-toolbar-layout/000-plan.md).
- Updated 2026-08-22: the indefinitely deferred PR2 (dismiss-while-running, background progress) is subsumed by the toolbar status center planned in [063-agent-workflows](../063-agent-workflows/000-plan.md); the HUD choose stage is replaced there by a generic workflow start sheet and the staged HUD is scheduled for removal once `prowl.handoff` ships.
