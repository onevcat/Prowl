# docs-ai — Curated Product and Design Records

This directory is Prowl's curated, durable record of how the onevcat fork evolved. Each
numbered folder documents a substantial feature or a non-trivial, decision-shaping fix: the
plan that preceded the work and the resulting implementation. It exists so that humans and
agents can answer "why is it built this way?" without archaeology through git history.

It is not a working-note archive. Reviews, audits, routine investigations, status reports,
test runs, and small/docs-only changes stay in their normal task or Git context unless
onevcat explicitly asks for a `docs-ai/` record.

## Structure

```
docs-ai/NNN-<slug>/
  000-plan.md      # plan before implementation (RFC-like)
  001-action.md    # what was actually done, verified against the code
  002-<topic>.md   # amendments: follow-up waves, corrections, or one record per slice of a multi-PR entry (indexed in 000-plan.md)
  <living>.md      # non-numbered = living doc (runbook/ledger/reference), updated in place
```

Rules for writing new entries live in the `write-ai-doc` skill
(`.claude/skills/write-ai-doc/SKILL.md`). In short: select only qualifying product work,
then plan first, act second, amend in place for in-frame follow-ups, and open a new numbered
entry for large pivots. An entry delivered across several PRs records each slice as an
amendment (`002+`, shipped with its PR) and writes `001-action.md` once, when the last slice
lands, summarizing them. Numbered files are immutable history; non-numbered files are living
documents.

Entries `001`–`045` were backfilled on 2026-07-12 from PRs, commits, and the former
`doc-onevcat/` directory, which was dissolved into this one (historical plans were
absorbed into the entries; operational docs became living files — see the index below;
originals remain in git history). Backfilled plans are retrospective reconstructions;
each is marked as such.

Living documents hosted here:

- `001-fork-bootstrap-and-release-pipeline/release-runbook.md` — fork sync & release runbook
- `007-ghostty-embedding-integration/ghostty-fork-sync.md` — Ghostty fork/submodule upgrade runbook
- `012-keybinding-system/architecture.md` — keybinding system reference
- `013-prowl-cli/contracts/` — normative CLI contracts
- `017-upstream-sync-process/upstream-ledger.md` — upstream review ledger (baseline + decisions)
- `020-observability/runbook.md` — observability/diagnostics runbook
- `063-agent-workflows/dsl-spec.md` — Agent Workflow DSL (`prowl.workflow/v1`) normative spec
- `063-agent-workflows/release-plan.md` — release/order plan shared by 063 and 064
- `064-agent-completion-signals/research-agent-completion-signals.md` — per-runtime completion-signal matrix
- `064-agent-completion-signals/agent-contracts-runbook.md` — runtime contract inventory, low-cost model routes, implemented inventory/preflight and eight-runtime headless checks, plus remaining interactive acceptance

Some entries also host verbatim historical attachments migrated from doc-onevcat (e.g.
`023-shelf-mode/jank-investigation.md`, `017-.../batch-2026-07-06-post-v0.10.5.md`,
`045-.../research-cli-session-identity.md`); they are frozen records, not living docs.

What is *not* here: reviews, audits, routine investigations, test reports, working notes,
small polish PRs (git history covers them), and current user-facing behavior (`docs/` is the
agent-facing manual for that).

## Index

| # | Entry | Anchor | Topic |
| --- | --- | --- | --- |
| 001 | [fork-bootstrap-and-release-pipeline](001-fork-bootstrap-and-release-pipeline/000-plan.md) | 2026-02-26 | Independent fork: sync scripts, notarized date-based releases, Sparkle appcast, Homebrew cask |
| 002 | [custom-commands](002-custom-commands/000-plan.md) | 2026-02-27 | Repo-scoped custom command buttons and their evolution |
| 003 | [diff-window](003-diff-window/000-plan.md) | 2026-03-06 | Local diff window (YiTong), external diff tools, render/cache fixes |
| 004 | [prowl-rebrand](004-prowl-rebrand/000-plan.md) | 2026-03-17 | Supacode → Prowl user-facing rebrand; settings migration; upstream-PR guard |
| 005 | [canvas-live-sessions](005-canvas-live-sessions/000-plan.md) | 2026-03-17 | Canvas v1: all tabs as draggable/zoomable cards |
| 006 | [startup-performance](006-startup-performance/000-plan.md) | 2026-03-19 | Parallel repo loading, direct `wt`, snapshot startup cache |
| 007 | [ghostty-embedding-integration](007-ghostty-embedding-integration/000-plan.md) | 2026-03-21 | Ghostty action routing, callbacks, theme handling, safety backports |
| 008 | [terminal-notifications](008-terminal-notifications/000-plan.md) | 2026-03-22 | Command-finished notifications and the notification UX line |
| 009 | [terminal-surface-lifecycle](009-terminal-surface-lifecycle/000-plan.md) | 2026-03-23 | Blank-surface/reattachment investigation; occlusion; leaks |
| 010 | [plain-folder-support](010-plain-folder-support/000-plan.md) | 2026-03-24 | Plain (non-git) folders alongside repositories |
| 011 | [canvas-multiselect-broadcast](011-canvas-multiselect-broadcast/000-plan.md) | 2026-03-25 | Multi-select cards, broadcast input |
| 012 | [keybinding-system](012-keybinding-system/000-plan.md) | 2026-03-27 | Config-driven keybindings M1–M3, recorder UI, Ghostty key ownership |
| 013 | [prowl-cli](013-prowl-cli/000-plan.md) | 2026-03-30 | Contract-first `prowl` CLI: socket service, v1 commands, hardening, agents |
| 014 | [terminal-layout-persistence](014-terminal-layout-persistence/000-plan.md) | 2026-03-31 | Layout snapshot save/restore; font-size persistence; launch races |
| 015 | [repositories-feature-refactor](015-repositories-feature-refactor/000-plan.md) | 2026-04-03 | TCA decomposition of RepositoriesFeature and later code-health splits |
| 016 | [dev-build-and-ci-workflow](016-dev-build-and-ci-workflow/000-plan.md) | 2026-04-04 | Build/test tooling, CI parallelism, Debug identity, incremental caching, Shared module boundary |
| 017 | [upstream-sync-process](017-upstream-sync-process/000-plan.md) | 2026-04-08 | Upstream review discipline, baselines, batch decisions |
| 018 | [archived-worktrees](018-archived-worktrees/000-plan.md) | 2026-04-09 | Archived worktree discoverability and auto-delete |
| 019 | [worktree-creation-and-lifecycle](019-worktree-creation-and-lifecycle/000-plan.md) | 2026-04-12 | Creation/merge flows, safe deletion, Add-to-Prowl redesign |
| 020 | [observability](020-observability/000-plan.md) | 2026-04-18 | Sentry + PostHog wiring; the App-Hang enable→tune→remove arc |
| 021 | [sparkle-update-ux](021-sparkle-update-ux/000-plan.md) | 2026-04-18 | Update badge, Sparkle 2.9.2, background downloads, confirm-install |
| 022 | [tab-title-and-icon](022-tab-title-and-icon/000-plan.md) | 2026-04-18 | Tab titles/icons: manual, auto-detected, pinned, persisted |
| 023 | [shelf-mode](023-shelf-mode/000-plan.md) | 2026-04-21 | Shelf stacked-book mode + jank investigation |
| 024 | [canvas-interaction-evolution](024-canvas-interaction-evolution/000-plan.md) | 2026-04-25 | Canvas v2 UX: zoom/pan, expand-in-place, spatial navigation |
| 025 | [repo-identity-appearance](025-repo-identity-appearance/000-plan.md) | 2026-04-27 | Per-repo icon/color/title identity |
| 026 | [sidebar-container-refactor](026-sidebar-container-refactor/000-plan.md) | 2026-05-03 | Sidebar container/presentation refactor |
| 027 | [split-pane-ux](027-split-pane-ux/000-plan.md) | 2026-05-04 | Unfocused-pane dimming, divider config, split-zoom |
| 028 | [pr-status-tracking](028-pr-status-tracking/000-plan.md) | 2026-05-08 | GitHub PR state pipeline: batching, correctness, flicker fixes |
| 029 | [active-agents-panel](029-active-agents-panel/000-plan.md) | 2026-05-09 | Active Agents panel UI |
| 030 | [agent-status-detection](030-agent-status-detection/000-plan.md) | 2026-05-09 | Per-pane agent detection: pid API, heuristics, OSC, scheduling |
| 031 | [command-palette-architecture](031-command-palette-architecture/000-plan.md) | 2026-05-16 | Palette rebuild: categories, suggestions, action factories |
| 032 | [performance-hardening](032-performance-hardening/000-plan.md) | 2026-05-21 | App-hang storm fix; event coalescing; render cost reductions |
| 033 | [ui-refresh-2026-05](033-ui-refresh-2026-05/000-plan.md) | 2026-05-24 | Community UI refresh: tab bar, sidebar, chrome tint |
| 034 | [worktree-watcher-correctness](034-worktree-watcher-correctness/000-plan.md) | 2026-05-25 | Watcher/discovery correctness incl. symlinked roots |
| 035 | [protected-terminal-close](035-protected-terminal-close/000-plan.md) | 2026-05-25 | Confirm-before-close for protected terminal work |
| 036 | [window-management-hardening](036-window-management-hardening/000-plan.md) | 2026-05-26 | Main-window surfacing, fullscreen edge cases, stall diagnostics |
| 037 | [line-diff-tracking](037-line-diff-tracking/000-plan.md) | 2026-05-28 | Sidebar line-diff badge pipeline and adaptive debounce |
| 038 | [docs-agent-manual](038-docs-agent-manual/000-plan.md) | 2026-06-07 | docs/ agent manual, sync-docs skill, in-app docs |
| 039 | [gh-cli-hardening](039-gh-cli-hardening/000-plan.md) | 2026-06-08 | gh/git robustness; per-repo GitHub identities |
| 040 | [automatic-open-in](040-automatic-open-in/000-plan.md) | 2026-06-13 | Project-aware Automatic Open In; editor/app additions |
| 041 | [ghosttykit-prebuilt-artifacts](041-ghosttykit-prebuilt-artifacts/000-plan.md) | 2026-06-14 | Prebuilt GhosttyKit downloader (no local Zig needed) |
| 042 | [project-workspaces](042-project-workspaces/000-plan.md) | 2026-06-17 | Workspace grouping of repos/folders |
| 043 | [canvas-tile-layout](043-canvas-tile-layout/000-plan.md) | 2026-06-24 | Tile layout + default-layout setting |
| 044 | [foundation-model-branch-names](044-foundation-model-branch-names/000-plan.md) | 2026-06-27 | On-device FM branch-name suggestions |
| 045 | [native-agent-session-detection](045-native-agent-session-detection/000-plan.md) | 2026-07-12 | Native agent session identity (successor to 030's heuristics) |
| 046 | [cli-short-handles](046-cli-short-handles/000-plan.md) | 2026-07-13 | Session-scoped tab and pane handles for CLI targeting |
| 047 | [cross-agent-handoff](047-cross-agent-handoff/000-plan.md) | 2026-07-17 | Durable artifact-based task handoff across coding agents |
| 048 | [agent-runtime-adapters](048-agent-runtime-adapters/000-plan.md) | 2026-07-18 | Protocol-backed agent session resume and configurable launch invocations |
| 049 | [agents-toolbar-entry](049-agents-toolbar-entry/000-plan.md) | 2026-07-20 | Agents status capsule + staged handoff HUD toolbar entry |
| 050 | [sidebar-expand-active-and-worktree-tab-badges](050-sidebar-expand-active-and-worktree-tab-badges/000-plan.md) | 2026-07-25 | Sidebar Expand Active third state + per-worktree tab count badges |
| 051 | [repository-icon-detection](051-repository-icon-detection/000-plan.md) | 2026-07-25 | High-confidence local repository icon detection on add; deferred, reviewable Foundation Model recommendations |
| 052 | [sidebar-context-menus](052-sidebar-context-menus/000-plan.md) | 2026-07-27 | Sidebar context menu overhaul: worktree terminal actions, header/workspace path actions, PR click-through |
| 053 | [agent-profiles](053-agent-profiles/000-plan.md) | 2026-07-29 | Agent Profile V1: preset-first Claude Code/Codex launch profiles, opt-in account isolation, path routing, and future handoff seam |
| 054 | [native-settings-navigation](054-native-settings-navigation/000-plan.md) | 2026-07-30 | SwiftUI-owned singleton Settings window, native sidebar/detail navigation, and Agent Profile drill-ins |
| 055 | [agent-profile-runtimes](055-agent-profile-runtimes/000-plan.md) | 2026-08-01 | Capability-based runtime adapters and Agent Profile support across Prowl's recognized agent catalog |
| 056 | [performance-optimization-2026-08](056-performance-optimization-2026-08/000-plan.md) | 2026-08-01 | August performance review series: exact cached line counts, opt-in Debug TCA logging, and agent screen-scan memoization |
| 057 | [performance-benchmark-suite](057-performance-benchmark-suite/000-plan.md) | 2026-08-02 | Ratio-assertion benchmarks pinning the #644–#665 hot paths, `make bench` absolute-number reporting, and live measurement wrappers |
| 058 | [unified-toolbar-layout](058-unified-toolbar-layout/000-plan.md) | 2026-08-07 | Remove redundant branch/title toolbar items and align the Agents + notifications cluster across Normal, Shelf, and Canvas |
| 059 | [agent-transcript-snapshots](059-agent-transcript-snapshots/000-plan.md) | 2026-08-11 | Immediate Codex/Claude agent snapshots with trustworthy transcript results and actionable blocker text |
| 060 | [prowl-cli-targeting-and-contract-governance](060-prowl-cli-targeting-and-contract-governance/000-plan.md) | 2026-08-16 | Unified target grammar, CLI contract rebaseline, and durable documentation governance |
| 061 | [native-toolbar-controls](061-native-toolbar-controls/000-plan.md) | 2026-08-17 | Native macOS toolbar grouping, Liquid Glass ownership, and review standards |
| 062 | [workspace-child-diff](062-workspace-child-diff/000-plan.md) | 2026-08-19 | Per-repository diff for workspace children via unified DiffTarget routing |
| 063 | [agent-workflows](063-agent-workflows/000-plan.md) | 2026-08-21 | Agent Workflows: YAML-declared, profile-bound multi-agent orchestration (runner, `prowl workflow` CLI, status center, built-in handoff/adversarial review); successor to 047's fixed handoff flow; [action bundles and control-flow design](063-agent-workflows/015-action-bundles-and-control-flow.md), [implementation contract](063-agent-workflows/017-action-bundle-implementation.md), [personal history and retention](063-agent-workflows/018-history-storage-plan.md), [naming contract](063-agent-workflows/019-workflow-naming.md) |
| 064 | [agent-completion-signals](064-agent-completion-signals/000-plan.md) | 2026-08-22 | Layered agent signal bus (cooperative / launch-scoped hooks / transcript+process+OSC / heuristic), `prowl agents signal` + `agents wait` with source/confidence, per-runtime hook research, and [T1 contract-test plan](064-agent-completion-signals/016-t1-contract-test-plan.md) |
| 065 | [bundled-agent-skills](065-bundled-agent-skills/000-plan.md) | 2026-08-22 | Bundle Prowl's official agent skills into the app, `prowl skills` install/uninstall via symlinks into agent skill folders, Agent Skills section on Settings › CLI & Skills, shared registry for 063 |
| 066 | [agent-island](066-agent-island/000-plan.md) | 2026-09-01 | Notch-aware Active Agents island, global keyboard entry, Agents Display settings, and hover-revealed floating placement |
