# Agent Detection

> How Prowl knows there's an agent in a pane and whether it's Working, Blocked,
> Idle, or Done — and which agents it recognizes.

**Keywords:** agent detection, claude, codex, gemini, cursor, working, blocked, idle, done, status, process probe, screen heuristics, indicator, spinner

**Related:** [active-agents](active-agents.md) · [notifications](notifications.md) · [terminal](terminal.md)

## What it is

Prowl continuously inspects each terminal pane to decide whether a coding agent is
running and what state it's in. That signal drives the
[Active Agents panel](active-agents.md), the per-tab activity indicator,
[Canvas](canvas.md) cards lighting up, and [notifications](notifications.md).

## Agents it recognizes

Claude (Claude Code), Codex, Gemini, Cursor, Cline, OpenCode, GitHub Copilot,
Kimi, Droid, Amp, Pi (`pi`), Oh My Pi (`omp`, `oh-my-pi`), Qoder CLI (`qodercli`),
Qwen Code (`qwen`), and Grok Build (`grok`).
Detection covers
common wrappers (node, python, bun, bash, etc.) so agents launched indirectly are
still found. Pi and Oh My Pi are independent detected agents. Pi recognizes its
own minimal working/idle cues, including its built-in braille-prefixed `Working...`
loader; Oh My Pi owns its richer spinner and interactive
Ask-prompt heuristics, plus its own session layout and icon. Grok Build also
ships an `agent` symlink; Prowl only treats that name as Grok when the path points
at a `~/.grok/` install (so Cursor's own `agent` entrypoint stays Cursor).

## How detection works (two stages)

1. **Process probe.** Prowl reads the pane's foreground process group and matches
   process names / argv against known agent executables, scoring argv[0] highest,
   then process name, then command-line tokens.
2. **Screen heuristics.** It starts from the last ~24 non-blank lines, then selects
   agent-specific live UI regions rather than treating every transcript line as current
   state. Structured confirmation/permission chrome is **Blocked**; status rows and
   spinners are **Working**. Claude working rows are scoped to the lines immediately above
   its prompt box, while confirmation text is consulted only around a current numbered
   selection row such as `❯ 1. Yes`; a bare input prompt cuts off the preceding transcript.
   Codex uses an exact bottom-of-screen `•`/`◦ Working (... esc to interrupt)` footer
   fallback. Its confirmation detector requires a numbered selected row such as `› 1. Yes`
   paired with a live bottom footer or an explicit Yes/No choice structure. Ordinary prompt
   text and completed responses are not confirmation boundaries.
   Other agent families keep their own patterns (including Oh My Pi's
   `Working… ⟦esc⟧` loader, braille frames, symbol cycles, Cursor's
   hexagons, Kimi's moon phases, etc.).
   For Claude, a running **background workflow** keeps a status line *below* the
   input box (e.g. `3/5 agents done · 7m 29s · ↓ 288.5k tokens`) after the turn has
   ended; Prowl reads that footer as **Working**, so a churning workflow isn't
   mistaken for idle.

To avoid flicker, detection **stabilizes**: it tolerates several consecutive
misses before declaring an agent gone, and a working agent gets a short (~3s)
hold so brief pauses between thinking and output don't drop it out of
"working" (a genuine finish therefore reports up to ~3s late; "blocked"
bypasses the hold and surfaces immediately). Viewer overlays (Claude's
transcript / history-search views) cover the live status area, so frames
showing their chrome keep the last trusted state instead of forcing idle.

## The state machine

**Raw states:** `working`, `blocked`, `idle`, `unknown`.

**Display states** (what you see):

| Display     | Derived from            | Meaning                               |
| ----------- | ----------------------- | ------------------------------------- |
| **Working** | raw `working`           | actively processing                   |
| **Blocked** | raw `blocked`           | waiting for the user (a prompt)       |
| **Done**    | raw `idle` + **unseen** | just finished; you haven't looked yet |
| **Idle**    | raw `idle` + **seen**   | nothing running                       |

A **Done** pane becomes **Idle** the moment you focus it.

## How often it runs

- **No polling** for cold panes that have not received recent input.
- ~**2 s** for a short warm window after typing, paste, CLI input, or an initial
  command starts in the pane.
- ~**300 ms** once an agent is detected, so Working/Blocked/Done stays responsive.

The heavier process probe is throttled (cached ≈ 0.75 s per process group unless
something changes) so many panes don't add up to high CPU. Status indicators redraw on a
coarse tick rather than every frame for the same reason.

## The indicator

In tabs and the Active Agents panel, a **Working** agent shows an animated spinner
(the per-agent style detected on screen); **Blocked** is a distinct
attention color; **Idle/Done** are static. The "working" animation style is also
configurable in spirit — Prowl uses a bagua/trigram-style spinner in the agents
list.

## Worktree running indicator

The sidebar worktree row spinner and `prowl list`'s `task.status` report
**running** whenever any pane in the worktree is busy. A pane is busy when:

- a terminal command reports progress (OSC 9;4 / ConEmu-style, e.g. a long shell
  command), **or**
- a detected agent is **Working** or **Blocked** — including Claude running a
  background **workflow**, detected from its below-prompt `… agents done …` status
  line even while the input box looks idle.

A **Blocked** agent is the exception to the spinner. Because it has stopped and
is waiting on you, the sidebar row shows a red attention icon instead of the
spinner — a spinner there would tell you to wait, which is backwards. The row
still counts as **running** for `prowl list`'s `task.status`, so the CLI
contract is unchanged; use `prowl agents` to tell blocked from working. A
worktree that is being created, archived, or deleted keeps its own spinner,
which takes precedence over the agent indicator.

It's a single coarse running/idle bit (it can't distinguish a background workflow
from a long command). For the agent's finer state use the
[Active Agents panel](active-agents.md) or [`prowl agents`](cli.md). Expect up to
~2 s before it lights on a warm pane, and the ~3 s working-hold before it clears.

## Settings

Agent detection is on by default. Related toggles live in the Active Agents and
Notifications settings (e.g. `autoShowActiveAgentsPanel`,
`showActiveAgentTabTitles`).

## Gotchas for agents

- Detection is **heuristic and best-effort**. A short-lived command between polls
  can be missed; an unusual prompt might read as the wrong state.
- **"Blocked"** is the one that means *a human is needed* — it's typically a
  permission/confirmation prompt the agent is waiting on.
- For deterministic automation, don't rely on the visual status; use
  [`prowl list`](cli.md) (`task.status`) and confirm a screen is finished with
  `prowl read --wait-stable` — `task.status` can flip to idle before a TUI has
  painted its last frame.
