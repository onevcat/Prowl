# Command Palette

> Workflow UI is enabled by default. Start Prowl with `PROWL_WORKFLOW_UI=0` to hide its UI and skill row; CLI workflow and skill commands remain available. The switch is read at process startup.

> The `⌘P` searchable launcher for (almost) every action in Prowl. Type a name,
> hit Return.

**Keywords:** command palette, ⌘P, cmd+p, search actions, launcher, fuzzy search, run command, quick action

**Related:** [keyboard-shortcuts](../reference/keyboard-shortcuts.md) · [github-pull-requests](github-pull-requests.md) · [custom-actions](custom-actions.md) · [active-agents](active-agents.md)

## What it is

A fuzzy-searchable overlay that surfaces dozens of actions — view toggles,
worktree operations, pull-request actions, terminal commands, app commands, and
your custom commands. It's the fastest way to reach anything whose shortcut you
don't remember, and it shows each action's **live keyboard binding** next to it.

**Open:** `⌘P` (`command_palette`), or the toolbar button. **Close:** `Esc`.

## Using it

- **Type** to fuzzy-match against action titles and hidden keyword aliases.
- **↑ / ↓** (or `⌃P` / `⌃N`) move the selection; **Return** runs it; **Esc** closes.
- **Empty query** shows a **Recent** section (your recently used actions, by
  recency) above a **Suggested** section (curated defaults) — up to 8 rows.
- **With a query** it's a flat list ranked by match quality and recency.

## What it can do (categories)

The available actions depend on context (e.g. PR actions appear only when the
selected worktree has a pull request).

- **View / layout:** Toggle Sidebar, Toggle Active Agents Panel, Toggle Canvas,
  Toggle Shelf, Show Diff, Show Outgoing Changes, and Canvas actions
  (Expand/Arrange/Organize/Select-All cards).
- **Navigation:** Reveal in Finder, Copy Path, Reveal in Sidebar, Jump to Latest
  Unread, and select-a-specific-worktree entries.
- **Worktree:** New Worktree, Refresh Worktrees, View Archived Worktrees, Run
  Script, Stop Script, Rename Branch, Pin/Unpin, Delete Worktree, Change Tab Icon.
- **Pull request** (when a PR exists): Open PR, Mark Ready for Review, Copy failing
  job URL, Copy CI Failure Logs, Re-run Failed Jobs, Open Failing Check Details,
  Merge PR, Close PR. See [github-pull-requests](github-pull-requests.md).
- **Terminal:** font size, find, tab/pane selection, new/close terminal (mirrors
  the Ghostty-bridged commands; search-only).
- **App:** Check for Updates, Open Settings, Open Repository, **Install Command
  Line Tool**, Repo Settings.
- **Custom commands:** enabled local and Global Custom Commands appear here with their
  source. Same-titled commands can coexist; disabled commands do not appear.
- **Handoff** (every runnable workspace, repository/worktree, or plain folder):
  a single **Hand Off…** row opens the Hand Off HUD, where you choose the
  receiving agent (or save progress only); Prowl then asks the live source
  agent to write its briefing and run the hand-off itself, with fork and
  context-only fallbacks available while you wait. Same flow as the toolbar
  Agents capsule. See [handoff](handoff.md).
- **Agent profiles** (when a terminal worktree is selected): a
  **Launch Agent: <name>** row per enabled profile, the current worktree's
  Recommended profile first — the same launch action as the toolbar Agents
  menu. See [agent-profiles](agent-profiles.md).
- **Workflows** (when a terminal worktree is selected): a
  **Run Workflow: <name>** row per runnable workflow visible to the
  action-target worktree (refreshed when the palette opens). Activation goes
  through the workflow start sheet — or starts immediately when the workflow's
  bindings resolve without a decision. Validation-failing files are not listed
  here; the toolbar Agents popover names them with their reason. See
  [workflows](workflows.md).
- **Debug** (Debug builds only): toast/update/dock simulations.

## Behavior notes

- Recency is remembered, so frequently used actions float up in the empty-query
  suggestions.
- PR and Canvas entries appear/disappear as state changes (PR present, Canvas
  active, etc.).
- Outgoing Changes compares committed work against a labeled base (pull
  request base → worktree base setting → default branch); a base that exists
  but cannot be resolved reports a specific error rather than cascading to a
  guess. See [diff-view](diff-view.md).
- In Canvas, worktree-scoped actions use the focused card as their context.
- There are no user settings for the palette; ranking is automatic.

## Gotchas for agents

- If a human can't find an action, the palette is the universal answer: "press
  `⌘P` and type its name."
- The palette shows the **live** (possibly remapped) binding for each action — a
  reliable way to discover a human's actual keys.
