# Active Agents Panel

> A live list of every running agent across all worktrees, with status and
> one-click jump-to-agent. Your mission-control roster.

**Keywords:** active agents, agents panel, running agents, status list, working, blocked, done, idle, jump to agent, roster

**Related:** [agent-detection](agent-detection.md) · [notifications](notifications.md) · [command-palette](command-palette.md) · [canvas](canvas.md)

## What it is

A collapsible panel at the bottom of the left sidebar that lists **every agent
currently detected across all worktrees/tabs/panes**, in real time. Each row shows
the agent's current task title when one can be inferred, its repository/branch
context, and a **status pill**.
Click a row to jump straight to that agent's pane.

**Toggle:** `⌘⌥P` (`toggle_active_agents_panel`), the sidebar footer button, or
Command Palette → "Toggle Active Agents Panel".

## What each row shows

```
[icon]  task title or AgentName · RepositoryName        [status pill]
        tab title or branch (secondary)
```

- **Icon** — the detected command/agent icon (for example `omp` keeps the OMP
  icon even though it reports as the Pi agent; unknown wrappers fall back to the
  agent icon, then a sparkle).
- **Title** — inferred task title when available. Codex CLI sessions use the
  cleaned first real user request from the matching Codex session log, skipping
  injected AGENTS/environment context; otherwise the row falls back to detected
  command/agent name + repository.
- **Subtitle** — the tab title (if `showActiveAgentTabTitles`) or branch name.
- **Status pill** — one of:

| Status | Meaning | Look |
|--------|---------|------|
| **Working** | actively processing | orange, animated indicator |
| **Blocked** | waiting for you (a prompt) | red |
| **Done** | finished, not yet seen | blue |
| **Idle** | nothing running / seen | grey |

Rows appear in the order agents are first detected. (See
[agent-detection](agent-detection.md) for how these states are determined.)

## Interactions

- **Click a row** → focuses that worktree + tab + pane and brings Prowl forward. A
  **Done** row downgrades to **Idle** once focused.
- **Keyboard navigation:** `⌥⌃↓` next agent, `⌥⌃↑` previous agent (wraps).
- **Resize** the panel by dragging its top edge (height is remembered).
- **Auto-show:** if `autoShowActiveAgentsPanel` is on and the panel is hidden, a
  newly detected agent opens it automatically.

## Empty state

When nothing is running: "New agents will appear here".

## Settings

- `autoShowActiveAgentsPanel` — pop the panel open when an agent appears.
- `showActiveAgentTabTitles` — show each agent's tab title instead of its branch.
- `showActiveAgentStatusInShelf` — show detected agent status markers on Shelf
  tab icons.
- Panel height and hidden/shown state are persisted automatically.

## Relationship to other features

- **Agent detection** ([agent-detection](agent-detection.md)) feeds this panel.
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
  [agent-detection](agent-detection.md)). For programmatic certainty about a
  pane's task status, use [`prowl list`](cli.md) → `task.status`.
