# View Modes — Normal / Canvas / Shelf / Clean

> Normal, Canvas, and Shelf are three layouts for the same open worktrees. Clean
> is a separate launch runtime with one standalone shell.

**Keywords:** view mode, layout, normal, canvas, shelf, clean, switch view, toggle canvas, toggle shelf, default view

**Related:** [canvas](canvas.md) · [shelf](shelf.md) · [clean-mode](clean-mode.md) · [concepts](../concepts.md) · [repositories-and-worktrees](repositories-and-worktrees.md)

## The three modes

| Mode | Layout | Strength | Toggle |
|------|--------|----------|--------|
| **Normal** | Sidebar of worktrees + the focused worktree's tabs/panes | Deep, focused work on one branch | default (exit Canvas/Shelf) |
| **Canvas** | Zoomable board of live terminal cards | See many agents at once; **broadcast** | `⌘⌥↩` |
| **Shelf** | Vertical "book spines" you flip through | Fast keyboard triage of many worktrees | `⌘⇧↩` |

Clean is not a fourth layout in this table. It does not load the shared
repository/worktree session and cannot be toggled at runtime. See
[Clean Mode](clean-mode.md).

## How to switch

- **Canvas:** `⌘⌥↩` (`toggle_canvas`), the sidebar Canvas button, or Command
  Palette → "Toggle Canvas".
- **Shelf:** `⌘⇧↩` (`toggle_shelf`), the sidebar Shelf button, or Command Palette →
  "Toggle Shelf".
- **Back to Normal:** toggle the active mode off, or select a worktree in the
  sidebar.

Toggling Canvas or Shelf with **no open worktrees** does nothing.

## What's preserved across switches

- Your running terminals, tabs, and panes are untouched.
- Canvas persists card positions/sizes/z-order across launches.
- Entering Shelf keeps your current worktree open (or jumps to the first available
  one if you were on Canvas / archived / nothing).
- Exiting Canvas returns you to the focused card's worktree, the worktree you had
  before Canvas, your last focused worktree, or the first available — in that
  order.

## Launch behavior

`defaultViewMode` (Settings → General → Default View → Launch in) chooses which
runtime Prowl opens on the next launch: `normal`, `shelf`, `canvas`, or `clean`.
Changing it never hot-switches the current process.

## Which to recommend

- Supervising a fleet / sending the same command everywhere → **Canvas**
  ([details](canvas.md)).
- Cycling agents one-by-one with the keyboard → **Shelf** ([details](shelf.md)).
- Heads-down on a single branch → **Normal**.
- A chrome-free standalone shell or a manual Herdr container → **Clean**
  ([details](clean-mode.md)).
