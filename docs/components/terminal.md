# Terminal — Tabs, Splits & Panes

> The terminal layer: tabs within a worktree, splitting a tab into panes, the
> Ghostty engine underneath, tab titles & icons, shell integration, and fonts.

**Keywords:** terminal, tab, split, pane, surface, ghostty, font size, shell integration, OSC 133, scrollback, find, search, close tab, new tab, tab title, tab icon, CJK

**Related:** [concepts](../concepts.md) · [canvas](canvas.md) · [shelf](shelf.md) · [agent-detection](agent-detection.md) · [cli](cli.md) · [keyboard-shortcuts](../reference/keyboard-shortcuts.md)

## What it is

Inside each worktree you get terminal **tabs**. Each tab is a layout of one or
more **panes** (a.k.a. surfaces) — split horizontally/vertically — rendered by the
embedded **Ghostty** engine. One worktree → many tabs → each tab → one or more
panes.

```
Worktree
└─ Tab  (has a title + icon)
   └─ Pane / surface  (a live Ghostty terminal; tabs can hold several, split)
```

A single Ghostty app instance hosts every pane as an independent surface, which is
why Prowl is fully native and CJK-correct.

## Tabs

| Operation | How |
|-----------|-----|
| New tab | Terminal menu → **New Terminal** (Ghostty `new_tab`, typically `⌘T`); the **+** on a Shelf spine; the [`prowl create tab`](cli.md) CLI |
| Select tab 1–9 | `⌘1`–`⌘9` |
| Previous / Next tab | `⌘⇧[` / `⌘⇧]` |
| Close focused tab | Terminal menu → **Close Terminal Tab** (Ghostty `close_tab`) |
| Close (right-click a tab) | Close Tab · Close Other Tabs · Close Tabs to the Right · Close All |
| Rename tab | Right-click → **Rename Tab** (sets a custom title) |
| Change tab icon | Right-click → **Change Tab Icon** (pick an SF Symbol) |
| Reorder tabs | Drag tabs in the tab bar |

In **Shelf** view, tabs of the open book are also cycled with `⌘⌃↑` / `⌘⌃↓`.

## Splits (panes)

Splitting is handled by Ghostty actions (bind/keys in your Ghostty config):

| Operation | Ghostty action |
|-----------|----------------|
| New split (vertical / right) | `new_split:right` |
| New split (horizontal / down) | `new_split:down` |
| Focus adjacent pane | `goto_split:left/right/up/down`, or the app shortcuts below |
| Resize split | `resize_split:<dir>:<px>` |
| Equalize splits | `equalize_splits` |
| Zoom / maximize a pane | `toggle_split_zoom` (app default `⌘⌥⇧F`) |
| Close a pane | `close_surface` (Terminal menu → **Close Terminal**) |

App-level pane navigation (works inside the terminal too): `⌘[` / `⌘]` previous /
next pane, `⌘⌥↑/↓/←/→` for directional pane focus, `⌘⌥⇧F` to zoom / unzoom the
focused pane. Shelf spines also expose **split vertical / split horizontal**
buttons on the open book.

Zoom also has a mouse affordance: hovering a pane's top drag handle reveals a
zoom button in the pane's top-right corner, and a zoomed pane keeps a persistent
exit-zoom button in the same spot so it's always clear how to leave zoom.

## Tab titles — important caveat

A tab's displayed title is, in order of precedence:
1. a **custom title** you set via Rename Tab, else
2. the **live shell title** the running program emits (OSC 2), else
3. an auto-generated default like `project 1`, `project 2`.

Rapid live-title animation is coalesced per tab to at most one visible update
per second so one spinner frame does not rebuild the entire tab bar. The newest
withheld title is applied at the end of that interval even when no agent is
running, so a live title may visibly lag by up to one second but its final value
is not left behind.

The Run Script tab is labeled **RUN SCRIPT** and is **title-locked** for its
lifetime. Prowl also "learns" your shell's idle prompt so it doesn't mistake it
for a meaningful title.

> **Titles are free-form and can lie or lag.** Any program can set any title.
> When automating, never target a pane by its title — use the JSON `pane.id` or,
> for a same-session handoff, the text `pN` handle from
> [`prowl list`](cli.md). The bundled [`prowl-cli` skill](cli.md) repeats this
> for good reason.

## Tab icons

Tabs get an auto-detected icon based on what's running (e.g. an agent's icon),
which you can override (Change Tab Icon) or which a script can set. Icon
precedence is `auto < script < user`.

An Agent Profile launch applies that runtime's brand icon itself instead of
waiting for detection — to the new tab, or to the containing tab when the
profile opens in a split. Auto-detection reads the first token of the command,
and a profile that sets launch-scoped environment variables runs as
`env VAR=… claude`, whose first token is `env`. The slot stays claimable, so a
later recognised command in the same tab still takes it over.

## Shell integration & status (OSC sequences)

Ghostty's shell integration drives several Prowl features via terminal escape
sequences:

- **OSC 133** (prompt/command marks) — lets Prowl know when a command **starts and
  finishes** and its **exit code**. This powers command-finished notifications,
  auto-close-on-success, and the `prowl send --capture` output capture.
- **OSC 2** (title) — feeds tab titles and agent/icon detection.
- **Progress reports (OSC 9;4)** — long commands report busy/idle, feeding the
  tab's activity indicator and task status. Task status *also* folds in detected
  agent activity (Working/Blocked, incl. background workflows) — see
  [agent-detection](agent-detection.md#worktree-running-indicator).
- **Bell / desktop notification** — increments unread indicators.

`--capture` in the CLI **requires OSC 133** on the target pane; without it you get
`CAPTURE_UNSUPPORTED` (read the screen with `read --wait-stable` instead).

Every pane's environment reports **`TERM_PROGRAM=prowl`** (with
`TERM_PROGRAM_VERSION` set to the app version), so scripts and agents can detect
they're running inside Prowl rather than standalone Ghostty. `TERM` itself stays
`xterm-ghostty` — terminfo-based feature detection is unaffected.

## Command-finished behavior

When a command finishes (via OSC 133), Prowl can:
- fire a **notification** if it ran longer than the threshold (default 10s) — see
  [notifications](notifications.md);
- **auto-close** the tab/pane if it was launched with "close on success" and the
  exit code is 0;
- skip the notification for user-initiated exits (Ctrl-C → 130, SIGTERM → 143) or
  if you typed in that pane within the last ~3 seconds.

## Font size

- **Reset / Increase / Decrease** via the Terminal menu (Ghostty
  `reset_font_size` / `increase_font_size:1` / `decrease_font_size:1`; usually
  `⌘0` / `⌘+` / `⌘-`).
- The chosen size is remembered (`terminalFontSize`) and applied across worktrees;
  new tabs and splits inherit the focused pane's size.

## In-terminal search

Terminal menu: **Find…** (`start_search`), **Find Next/Previous**
(`search:next`/`search:previous`), **Hide Find Bar** (`end_search`), **Use
Selection for Find** (`search_selection`). These are Ghostty-managed.

## Scrollback, CJK, copy/paste

Scrollback, wide/CJK character rendering, and copy/paste are handled by Ghostty
with its defaults. Prowl's native mouse bridge preserves drag-selection anchors
across long scrollback, split-focus changes, and releases outside the original
pane. Customize terminal behavior in your Ghostty config at
`~/.config/ghostty/config`.

## Color scheme

The terminal theme automatically follows the macOS light/dark appearance. There's
no in-app Ghostty theme picker; change Ghostty colors via its config file.

## Layout persistence

If `restoreTerminalLayoutOnLaunch` is enabled, Prowl saves the tab/split layout
(which worktrees, tabs, split trees, titles, icons) and restores it on next
launch. Notification bodies are not persisted.

## Gotchas for agents

- **Tab selection ≠ pane focus.** A tab can have several panes; selecting a tab
  doesn't pin which split has keyboard focus. The CLI's `pane.focused` is the
  truth.
- Clicking an unfocused split in an already active window first transfers focus;
  start a drag selection with the next press so the focus click is not treated as
  a terminal press.
- Closing the **last** tab leaves the worktree with no visible terminal (Shelf
  removes the book; Canvas drops the card).
- `--capture` and stable reads depend on the pane's shell integration; agents
  running full-screen TUIs may need `read --wait-stable` rather than `--capture`.
