# Prowl Documentation — Index

> **Prowl** is a native macOS command center for running multiple AI coding agents
> (Claude Code, Codex, Gemini, Cursor, and friends) in parallel — each in its own
> terminal, tab, split, and git worktree. This documentation set is the operator's
> manual for the app.

## Who this is for

**The primary reader of these docs is an AI agent, not a human.** A human will
usually point their agent at this folder and then ask questions like _"how do I
broadcast a command to every agent at once?"_ or _"what does the Shelf view do?"_.
The agent reads the relevant file(s) here and answers precisely, then the human
drills into whatever interests them.

Everything here is plain Markdown — no images required. It is written to be
**searched by filename and keyword**, read in full quickly, and quoted accurately.

## How to use this documentation (for agents)

1. **Start here.** This index maps every feature to a file.
2. **For a pitch / first impression**, read [`overview.md`](overview.md) — the
   "most exciting" features, suitable for introducing Prowl to a human.
3. **For the mental model**, read [`concepts.md`](concepts.md) — the
   repository → worktree → tab → pane hierarchy, view modes, and glossary. Read
   this before answering anything structural.
4. **For a specific feature**, open the matching file in [`components/`](components/).
   Each is a self-contained manual for one part of the app.
5. **For exact lookups** (every keyboard shortcut, every setting field), use
   [`reference/`](reference/).
6. **To actually drive the app programmatically**, read
   [`components/cli.md`](components/cli.md) — the `prowl` command-line interface.

Filenames are descriptive on purpose. A keyword search such as
`grep -ri "broadcast" docs/` or `grep -ri "worktree" docs/` will land on the
right file.

## Component manuals

Each file under `components/` documents one part: what it is, how to open it,
its keyboard shortcuts, detailed behavior, settings, and gotchas.

| File | What it covers |
|------|----------------|
| [`components/repositories-and-worktrees.md`](components/repositories-and-worktrees.md) | The sidebar: adding repositories, creating / opening / archiving / deleting git worktrees, plain (non-git) folders, pinning, ordering, repository icons & colors. |
| [`components/workspaces.md`](components/workspaces.md) | Multi-repo workspaces: one agent terminal rooted at a shared folder, with `.prowl/workspace.json` metadata describing the repositories in scope. |
| [`components/terminal.md`](components/terminal.md) | Terminal tabs, splits/panes, surfaces, the Ghostty engine, tab titles & icons, shell integration, scrollback, font size. |
| [`components/canvas.md`](components/canvas.md) | Canvas view — a zoomable board of live terminal cards, multi-select, and **broadcast a command to every agent at once**. |
| [`components/shelf.md`](components/shelf.md) | Shelf view — worktrees as vertical "book spines" you flip through from the keyboard. |
| [`components/view-modes.md`](components/view-modes.md) | Switching between Normal / Canvas / Shelf layouts and what each is good for. |
| [`components/command-palette.md`](components/command-palette.md) | `⌘P` searchable command launcher; every action category it exposes. |
| [`components/active-agents.md`](components/active-agents.md) | The Active Agents panel: a live list of every running agent and its status, with one-click jump-to-agent. |
| [`components/agent-detection.md`](components/agent-detection.md) | How Prowl knows an agent is Working / Blocked / Idle / Done, which agents it recognizes, and how the status indicator works. |
| [`components/notifications.md`](components/notifications.md) | Agent-finished reminders, command-finished notifications, the bell/unread indicators, and Dock badge/bounce. |
| [`components/diff-view.md`](components/diff-view.md) | The Diff window (`⌘⇧Y`): working-tree changes vs HEAD, split/unified modes, line-change badges. |
| [`components/github-pull-requests.md`](components/github-pull-requests.md) | GitHub PR integration via `gh`: PR status, CI checks, merge/close/re-run actions from the command palette. |
| [`components/custom-actions.md`](components/custom-actions.md) | Run Script (`⌘R`/`⌘.`), Setup & Archive scripts, and per-repo Custom Commands with their own buttons & hotkeys. Injected env vars. |
| [`components/settings.md`](components/settings.md) | The Settings window (`⌘,`): every tab and what it controls. |
| [`components/updates.md`](components/updates.md) | Sparkle auto-updates: channels, auto-check, `⌘⇧U`. |
| [`components/cli.md`](components/cli.md) | The `prowl` CLI — let an agent inspect and drive panes (`list`, `read`, `send`, `key`, `focus`, `tab`, `pane`, `open`). |

## Reference (exact lookups)

| File | What it covers |
|------|----------------|
| [`reference/keyboard-shortcuts.md`](reference/keyboard-shortcuts.md) | The complete, authoritative keyboard-shortcut table, grouped by category, with command IDs and remappability. |
| [`reference/settings-fields.md`](reference/settings-fields.md) | Every `GlobalSettings` and per-repository setting field: name, type, default, effect, and on-disk location. |

## Find by task (reverse lookup)

| I want to… | Read |
|------------|------|
| Run many agents side by side and see them all | [`components/canvas.md`](components/canvas.md), [`components/shelf.md`](components/shelf.md) |
| Give one agent a task that spans several repos | [`components/workspaces.md`](components/workspaces.md) |
| Send one command to every agent simultaneously | [`components/canvas.md`](components/canvas.md) (broadcast) |
| Spin up a new branch/worktree for a new agent | [`components/repositories-and-worktrees.md`](components/repositories-and-worktrees.md) |
| Find / run any action by name | [`components/command-palette.md`](components/command-palette.md) |
| See which agents are working vs waiting on me | [`components/active-agents.md`](components/active-agents.md), [`components/agent-detection.md`](components/agent-detection.md) |
| Get notified when an agent finishes | [`components/notifications.md`](components/notifications.md) |
| Bind `swift build` / `npm test` to a button + hotkey | [`components/custom-actions.md`](components/custom-actions.md) |
| Review what an agent changed | [`components/diff-view.md`](components/diff-view.md) |
| Open / merge / re-run CI on a pull request | [`components/github-pull-requests.md`](components/github-pull-requests.md) |
| Drive a pane from a script or another agent | [`components/cli.md`](components/cli.md) |
| Look up a keyboard shortcut | [`reference/keyboard-shortcuts.md`](reference/keyboard-shortcuts.md) |
| Change app behavior / a setting | [`components/settings.md`](components/settings.md), [`reference/settings-fields.md`](reference/settings-fields.md) |

## Conventions used in these docs

- Modifier symbols: **⌘** Command · **⇧** Shift · **⌥** Option · **⌃** Control · **↩** Return · **⌫** Delete (Backspace).
- Default shortcuts are shown. Most app shortcuts are **user-remappable** in
  Settings → Shortcuts, so a human's actual keys may differ — when in doubt,
  the [Command Palette](components/command-palette.md) shows the live binding
  next to each action, and the `prowl` CLI never depends on keybindings.
- Requirements: **macOS 26.0+**.
- Website: <https://prowl.onev.cat> · Source: <https://github.com/onevcat/Prowl>
