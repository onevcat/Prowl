# Active Agents Panel

> Workflow launch menus and role labels are shown only when Prowl starts with `PROWL_WORKFLOW_UI=1`. Agent Island and ordinary agent controls remain available without the flag.

> A live list of every running agent across all worktrees, with status and
> one-click jump-to-agent. Your mission-control roster.

**Keywords:** active agents, agents panel, running agents, status list, working, blocked, done, idle, jump to agent, roster

**Related:** [agent-island](agent-island.md) · [agent-detection](agent-detection.md) · [cli](cli.md) · [notifications](notifications.md) · [command-palette](command-palette.md) · [canvas](canvas.md)

## What it is

A collapsible panel at the bottom of the left sidebar that lists **every agent
currently detected across all worktrees/tabs/panes**, in real time. Each row shows
the agent (Claude, Codex, …), its repository/branch context, and a **status pill**.
Click a row to jump straight to that agent's pane.

**Toggle:** `⌘⌥P` (`toggle_active_agents_panel`), the sidebar footer button, or
Command Palette → "Toggle Active Agents Panel".

## What each row shows

```
[icon]  AgentName · RepositoryName        [status pill]
        pane title or branch (secondary)
```

- **Icon** — the detected command/agent icon. Aliases such as `oh-my-pi` use
  their canonical runtime icon; unknown wrappers fall back to the agent icon,
  then a sparkle.
- **Title** — detected command/agent name + repository (repo color-coded);
  command aliases such as `omp` are shown directly. Panes Prowl launched from
  an [agent profile](agent-profiles.md) show the profile's display name
  instead (frozen at launch).
- **Subtitle** — the agent's pane title (if `showActiveAgentTabTitles`) or branch
  name. The pane title is the surface's own terminal title, falling back to the
  tab title, so agents in different splits of one tab keep distinct subtitles.
  Rapid title animation is coalesced to at most one visible update per second;
  status, session, directory, and other row changes still appear immediately.
- **Status pill** — one of:

| Status | Meaning | Look |
|--------|---------|------|
| **Working** | actively processing | orange, animated indicator |
| **Blocked** | waiting for you (a prompt) | red |
| **Done** | finished, not yet seen | blue |
| **Idle** | nothing running / seen | grey |

Rows appear in the order agents are first detected. (See
[agent-detection](agent-detection.md) for how these states are determined.)
A row whose pane is bound to an active workflow run replaces its subtitle with
`in <workflow> · <role>` for the life of the run.

## Interactions

- **Click a row** → focuses that worktree + tab + pane and brings Prowl forward. A
  **Done** row downgrades to **Idle** once focused.
- **Right-click a row** for the context menu:
  - **Hand Off…** — opens the Hand Off HUD for that agent's pane
    (selecting and focusing it first), regardless of which pane currently has
    focus. Same flow as the toolbar Agents capsule; see
    [handoff](handoff.md).
  - **Run Workflow ▸** — one entry per runnable workflow visible to the
    agent's worktree; starts it with this pane fixed as the `current` role's
    source (opening the start sheet when something needs a decision). Shown
    only when at least one runnable workflow exists. See
    [workflows](workflows.md).
  - **Mark as Read** — clears the pane's unread notifications without
    switching to it.
  - **Copy Path** / **Reveal in Finder** — the agent's working directory (or
    its owning worktree's directory when the agent hasn't reported one).
  - **Copy Session Path** / **Reveal Session in Finder** — the on-disk session
    log of the agent's native session (e.g. Claude Code's
    `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`). Shown only when
    Prowl has resolved the session to a file (see
    [agent-detection](agent-detection.md)); agents with server-side or
    store-only sessions (e.g. Amp threads) don't offer it.
- **Keyboard navigation:** `⌥⌃↓` next agent, `⌥⌃↑` previous agent (wraps).
- **Resize** the panel by dragging its top edge (height is remembered).
- **Auto-show:** if `autoShowActiveAgentsPanel` is on and the panel is hidden, a
  newly detected agent opens it automatically.

## Empty state

When nothing is running: "New agents will appear here".

The top-right button toggles **Show Agent Island**, using the same persisted setting as
Settings → Agents → Display. The top-inset icon uses the primary theme color when enabled and neutral gray when disabled.
Its tooltip names the next action. Holding Command replaces the button with the existing agent
navigation shortcut hint; customized bindings keep the existing hint-suppression behavior.

## Settings

Settings → Agents → Display:

- `autoShowActiveAgentsPanel` — pop the panel open when an agent appears.
- `showActiveAgentTabTitles` — show each agent's pane title (surface title,
  falling back to the tab title) instead of its branch.
- `showActiveAgentStatusInShelf` — show detected agent status markers on Shelf
  tab icons.
- Panel height and hidden/shown state are persisted automatically.
- [Agent Island](agent-island.md) projects this same roster at the top of a selected display;
  its Working carousel and Blocked/Done callouts do not introduce separate state or read logic.

## Relationship to other features

- **Agent detection** ([agent-detection](agent-detection.md)) feeds this panel.
- **CLI** ([cli](cli.md)) exposes the same roster through `prowl agents` and
  `prowl agents --json`. The command is read-only; text output shows a current
  `pN` pane handle, while JSON keeps the canonical `pane.id`. Use either with
  `prowl focus --pane`, `prowl read --pane`, or `prowl send --pane` for
  follow-up actions.
- **Notifications** ([notifications](notifications.md)) are driven by a separate
  signal — terminal bell / OSC desktop notifications and command-finished
  events — which usually coincides with, but is not the same as, a detected finish.
- **Canvas** ([canvas](canvas.md)) is the spatial counterpart — cards light up on
  that same notification/unread signal, not on the detected status itself.
- **Shelf** ([shelf](shelf.md)) mirrors detected agents as status markers on
  each owning tab icon; clicking a marked tab uses the same jump-to-agent behavior
  as clicking a panel row. This can be turned off with
  `showActiveAgentStatusInShelf`.

## Gotchas for agents

- "Blocked" is the actionable state — it means an agent is **waiting on a human**
  (a permission/confirmation prompt). Surface these first.
- This panel reflects **detected** agents; detection is best-effort (see
  [agent-detection](agent-detection.md)). For the same detected roster in
  automation, use [`prowl agents --json`](cli.md). For an all-pane inventory,
  including non-agent shells, use [`prowl list --json`](cli.md).
