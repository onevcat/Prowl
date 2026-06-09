# Core Concepts & Glossary

> The mental model behind Prowl. Read this before answering any structural
> question ("what's the difference between a tab and a pane?", "what's a book?").

**Keywords:** concepts, mental model, hierarchy, glossary, worktree, tab, pane, surface, split, book, spine, view mode, terminology

## The object hierarchy

Prowl nests four levels. Everything in the app refers back to these.

```
Repository            a git repo, workspace, or plain folder added to Prowl
└─ Worktree           a git worktree = one branch checked out in its own directory
   └─ Tab             a terminal tab inside that worktree
      └─ Pane         one terminal surface; a tab can be split into several panes
```

- **Repository** — a project you added to the sidebar. Two persisted kinds, plus
  a workspace overlay:
  - **`git`** — a real git repository; supports worktrees, branches, diff, PRs.
  - **`plain`** — a non-git folder; you can open a terminal and run scripts in it,
    but there are no worktrees, branches, diff, or PR features.
  - **Workspace** — a plain runnable folder with `.prowl/workspace.json`
    metadata. One agent starts in the workspace root and can work across several
    repositories listed in that file. The `prowl` CLI reports this runnable
    target's `worktree.kind` as `workspace`.
- **Worktree** — a git *worktree*: a branch checked out into its own working
  directory, so several branches are live on disk at once. This is the unit you
  hand to an agent. The repository's root directory is the **main worktree**
  (`isMain`); it can't be archived, deleted, or renamed. Worktrees you create get
  an auto-generated name like `bold-cat-523` unless you name them.
- **Tab** — a terminal tab within a worktree. A worktree can hold many tabs.
- **Pane / surface** — a single terminal session rendered by Ghostty. A tab
  starts with one pane and can be **split** horizontally/vertically into more.
  "Pane" and "surface" mean the same thing; the CLI and UI both use "pane".

> **For the `prowl` CLI:** every pane has a stable **UUID** (`pane.id`), every tab
> has a `tab.id`, and every worktree has a `worktree.id` (its path). Target work
> by these IDs — never by tab title, which is free-form and can lie. See
> [`components/cli.md`](components/cli.md).

## View modes — three ways to see the same worktrees

The same set of open worktrees/tabs can be displayed three ways. Switching modes
doesn't change your sessions, only how they're laid out.

| Mode | What it looks like | Best for | Toggle |
|------|--------------------|----------|--------|
| **Normal** | Sidebar of worktrees + one focused worktree's tabs/panes | Focused work on one branch | (default; exit Canvas/Shelf) |
| **Canvas** | A zoomable board of live terminal cards | Watching many agents; broadcasting | `⌘⌥↩` |
| **Shelf** | Vertical "book spines" you flip through | Fast keyboard triage of many worktrees | `⌘⇧↩` |

See [`components/view-modes.md`](components/view-modes.md), and the deep dives in
[`components/canvas.md`](components/canvas.md) and
[`components/shelf.md`](components/shelf.md).

## Agent status

Prowl watches each pane and infers what the agent in it is doing. Four
user-visible states:

- **Working** — actively processing (animated indicator).
- **Blocked** — waiting for you (a confirmation/permission prompt). This is the
  one that needs your attention.
- **Done** — finished and you haven't looked yet (an unseen completion). Becomes
  **Idle** once you focus it.
- **Idle** — nothing running / seen.

How this is detected (process inspection + on-screen heuristics) and the full
list of recognized agents are in
[`components/agent-detection.md`](components/agent-detection.md). The live list of
all agents and their statuses is the
[Active Agents panel](components/active-agents.md).

## Where Prowl stores things

- **Global settings:** `~/.prowl/settings.json`
- **Per-repository settings:** `~/.prowl/repo/<repo-name>/prowl.json`
- **Per-repository user custom commands:** `~/.prowl/repo/<repo-name>/prowl.onevcat.json`
- **Per-workspace metadata:** `<workspace>/.prowl/workspace.json`
- **CLI socket:** `~/Library/Application Support/com.onevcat.prowl/cli.sock`
  (overridable with `PROWL_CLI_SOCKET`)
- Legacy `~/.supacode` is migrated to `~/.prowl` on first launch. (Prowl is a fork
  of Supacode; some internal identifiers still read `supacode`.)

Full field-by-field detail: [`reference/settings-fields.md`](reference/settings-fields.md).

## The terminal engine

Prowl embeds **GhosttyKit / libghostty** (built from the Ghostty terminal
emulator). A single Ghostty app instance hosts every pane as an independent
surface. This is why Prowl is fully native (no web views), fast, and
correct with CJK/wide characters. Terminal-level features — splits, font size,
in-terminal search, copy/paste — are handled by Ghostty; app-level features —
tabs, worktrees, views — are Prowl's. See
[`components/terminal.md`](components/terminal.md) for where that line sits.

## Glossary (quick definitions)

- **Worktree** — a git branch checked out in its own directory; the unit you give
  an agent.
- **Workspace** — a folder whose terminal root contains several repositories for
  one agent to handle together, described by `.prowl/workspace.json`.
- **Book / spine** — Shelf-view name for a worktree shown as a vertical strip.
- **Card** — Canvas-view name for one terminal tab shown as a floating tile.
- **Broadcast** — typing into one Canvas card and mirroring it to all selected
  cards at once.
- **Pane / surface** — one terminal session; tabs split into panes.
- **Main worktree** — the repository root; cannot be archived/deleted/renamed.
- **Pinned worktree** — a worktree floated to the top of its repository section.
- **Archived worktree** — hidden from the main list but not deleted; restorable.
- **Run Script** — a per-repo on-demand command (`⌘R` to run, `⌘.` to stop).
- **Setup / Archive script** — per-repo scripts that run automatically on worktree
  create / archive.
- **Custom Command** — a per-repo user-defined action with its own button, icon,
  and hotkey.
- **Agent Reminder** — a notification fired when an agent finishes or needs you.
- **Command Palette** — the `⌘P` searchable launcher for every action.
