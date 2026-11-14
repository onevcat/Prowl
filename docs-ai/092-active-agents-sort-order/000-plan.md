# 092 — Active Agents sort order: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-11-15 |
| **Primary PRs** | (fill in as they merge) |
| **Related** | [029-active-agents-panel](../029-active-agents-panel/000-plan.md), [066-agent-island](../066-agent-island/000-plan.md), [086-sidebar-repository-groups](../086-sidebar-repository-groups/000-plan.md), [089-mirror-ios-redesign](../089-mirror-ios-redesign/000-plan.md), `docs/components/active-agents.md`, `docs/components/agent-island.md`, issue #1091 |

## Background

The Active Agents panel is a flat list in the order that agents were first detected
(`ActiveAgentsFeature.State.entries`, upserted by `agentEntryChanged`). Each row title is
"agent name · repository name" (`ActiveAgentRow.swift`). With several agents in one
repository, the repository name repeats on every row. Issue #1091 (from #1089) asks for a
view that groups the agents by project.

The status sort that 029 planned was never built (`029-active-agents-panel/001-action.md`).
The iOS mirror already groups agents by project in the Mac sidebar order, from the order
that `MirrorRosterDecorations.swift` computes on the Mac.

## Goals

- A **Sort by** picker in Settings → Agents → Display → Active Agents, with three values:
  - **Start time** (default): the current order, by first detection.
  - **Project**: one section per project, in the sidebar order.
  - **Status**: Blocked, then Working, then Done, then Idle. Inside one status, by start
    time.
- In **Project** mode, each section has a single-level title (project name and project
  color). The agent rows follow below the title, indented. The rows do not repeat the
  project name.
- The keyboard navigation (next and previous active agent) and the Agent Island roster
  follow the order that the panel shows.

### Non-goals

- No collapsible sections, and no second header level for sidebar groups. Sidebar groups
  only set the order of the project sections.
- No change to `prowl agents`: its output keeps its current order (status order for text,
  start-time order for `--json`), because scripts can
  depend on it.
- No change to the Agent Island attention cells (Blocked and Done callouts). They keep their
  own priority order.
- No change to the iOS mirror, which keeps its own grouping.

## Design / Approach

1. **Setting.** Add `ActiveAgentsSortOrder` (`startTime`, `project`, `status`) to
   `GlobalSettings` as `activeAgentsSortOrder`, default `startTime`, decoded with a fallback
   to the default for unknown values. Mirror it through `SettingsFeature` and `AppFeature`
   into `RepositoriesFeature.State`, the same path as `showActiveAgentNames`. Add the picker
   to `AgentDisplaySettingsView.swift`.
2. **Project identity.** Add `repositoryID: Repository.ID?` to `ActiveAgentRowDisplay`
   (`SidebarListView.swift`). The value comes from the same resolution as the displayed
   repository name: the agent's working directory first, then the owning worktree. An
   agent that resolves only to a path component has no repository ID and goes into the
   last section, **Other**.
3. **One ordering function.** A pure function takes the entries, the row displays, the
   sort order and `materializedSidebarLayout()`. It returns the sections to show: one
   untitled section for **Start time** and **Status**, one titled section per project for
   **Project**. Project order reuses the sidebar order, the same order that
   `MirrorRosterDecorations` gives to the mirror. Inside a project, rows keep the start-time
   order. The flattened list of entry IDs is the navigation order.
4. **Panel.** `ActiveAgentsPanel.swift` renders the sections. A project title is a plain
   caption row, not a button. In **Project** mode, a row shows the agent name as its title,
   and the branch or pane title as its subtitle. When `showActiveAgentNames` is off, the
   subtitle moves up to the title line, so that the title is never empty.
5. **Navigation.** `ActiveAgentsFeature` cannot see the sidebar layout, so the parent sends
   the ordered entry IDs with the navigation request, or keeps them in the child state when
   they change. `entryID(navigatingFrom:direction:in:)` and `AgentIslandNavigation` step
   through that order in place of the `entries` indices. The island stays flat (no section
   titles), and its pages and digit slots use the same order.
6. **Docs.** Update `docs/components/active-agents.md` (settings, order rules) and
   `docs/components/agent-island.md` (roster order).

Tests: the ordering function (each mode; sidebar groups; unknown repository; an empty
project leaves no section); settings decode and the settings mirroring; navigation in each
mode.

## Alternatives & decisions

| Decision | Chosen | Why |
| --- | --- | --- |
| Toggle or picker | Picker with three orders | One general setting in place of a single-purpose toggle; it also delivers the status sort that 029 planned |
| Default | Start time | Keeps the current behavior for existing users |
| Project of an agent | The repository that the row shows (working directory first) | Keeps the user's current reading of "which project this agent belongs to"; matches the mirror's **Other** section |
| Sidebar groups | Order only, no group header | The panel is narrow; two header levels are too heavy |
| Order inside a project | Start time | Rows do not move when a state changes, so a click hits the intended row. The **Status** mode is for users who want movement |
| Collapsing | None | Agents are few; a plain list is enough |
| Island and keyboard navigation | Follow the panel order | With only the panel reordered, "next agent" jumps across sections, and the island and the panel disagree |
| `prowl agents` | Unchanged by the setting | CLI output is an interface; a display setting must not change it |

## Amendments
