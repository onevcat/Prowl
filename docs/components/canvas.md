# Canvas View

> A zoomable board where every agent is a live, interactive terminal card —
> watch them all at once, and broadcast one command to every selected agent.

**Keywords:** canvas, board, cards, grid, zoom, pan, broadcast, multi-select, select all, arrange, organize, expand card, bird's-eye, overview of agents

**Related:** [view-modes](view-modes.md) · [shelf](shelf.md) · [terminal](terminal.md) · [active-agents](active-agents.md) · [keyboard-shortcuts](../reference/keyboard-shortcuts.md)

## What it is

Canvas turns every open terminal tab into a **card** floating on an infinite,
zoomable board. Each card is a **live, fully interactive terminal** — not a
screenshot — so you can watch several agents work simultaneously, then click into
any card to type. A card whose task just finished **lights up** so you can see at
a glance who's done.

**Toggle Canvas:** `⌘⌥↩` (`toggle_canvas`). Toggling has no effect if no worktrees
are open.

## The signature feature: broadcast to every agent

Canvas lets you **type a command once and send it to many agents at once**:

1. **Select multiple cards.** `⌘`-click cards to add them to the selection, or
   press **`⌘⌥A` (Select All Cards)**. With two or more selected, Canvas enters
   **broadcasting** mode (the toolbar shows "Broadcasting to N cards").
2. **Type into the primary (focused) card.** What you type — text and submitted
   commands — is **mirrored to every selected card**.
3. Great for "run the tests", "commit", "`/clear`", "continue", etc. across a
   whole fleet of agents in one keystroke.

Selection controls:
- `⌘`-click a card body → toggle it in/out of the selection.
- **Click (without `⌘`)** an already-selected card → make it the **primary** (the
  one you type into) without deselecting the rest. (`⌘`-clicking a selected card
  instead *removes* it from the selection.)
- Click empty canvas → clear the selection. **Esc** also clears it while
  broadcasting (two or more cards selected).

## Working with cards

| Operation | How |
|-----------|-----|
| Focus (enter) a card | Single-click its body |
| Move a card | Drag its title bar |
| Resize a card | Drag its edges/corners |
| Expand / restore a card | `⌘⌥E`, double-click the title bar, or the title-bar expand button — fills the viewport with that card; click the dimmed background or `⌘⌥E` again to restore |
| Close a card (its tab) | The **×** in the card title bar |
| Pan the board | Drag empty space (or middle-drag) |
| Zoom | `⌘` + scroll, or pinch (≈0.25×–2×) |

## Arranging the board

- **`⌘⌥A` Select All Cards** — select every card (entering broadcast).
- **`⌘⌥R` Arrange Cards** — bin-pack the existing cards to fit the viewport's
  aspect ratio, preserving each card's size, then fit-to-view.
- **`⌘⌥G` Organize Cards** — reset every card to a uniform grid (≈√N columns) at a
  default size and center them.

These also appear as toolbar buttons. There's a `?` help popover (bottom-left)
explaining pan/zoom/expand.

## Visual cues

- **Focused card:** bright accent border. **Selected (multi-select):** medium
  accent border. **Unselected:** faint border.
- **Finished/unread task:** the card title bar turns orange.
- During selection/broadcast, non-focused cards get a subtle shield overlay so you
  don't accidentally type into the wrong one.
- The left nav band is tinted with the focused card's repository color
  (`windowTintMode`).

## Layout & sizing

- Default card size adapts to screen width (roughly 800×550 on a 14", larger on a
  27") unless `useAdaptiveCanvasCardSize` is disabled. With adaptive sizing off,
  new and organized cards use the fixed custom size: 800×710 including the title
  bar.
- On first entry, cards auto-arrange into a balanced grid. Positions, sizes, and
  z-order are persisted across launches (in `UserDefaults`) and restored when you
  return to Canvas.
- Closing a card's last tab prunes it; focus advances to a neighbor.

## Many agents at once

Canvas is built for scale: the grid grows with the number of cards, Arrange packs
them to your viewport, and you can zoom out to see everything then zoom into a
region. Cards are real terminals, so the ones off-screen are occlusion-managed for
performance.

## Settings that affect Canvas

- `defaultViewMode` — launch directly into Canvas.
- `useAdaptiveCanvasCardSize` — adapt new and organized card sizes to the current
  display, or use the fixed custom card size when disabled.
- `windowTintMode` / repository colors — card and nav tinting.
- `showRunButtonInToolbar` — whether the Run button appears in the Canvas toolbar.

## When to recommend Canvas vs Shelf

- **Canvas** = spatial, see-everything, broadcast to many. Best when you're
  supervising a fleet or fanning the same command out.
- **Shelf** = linear, keyboard-fast triage of many worktrees one at a time.

See [view-modes](view-modes.md) for the comparison.

## Gotchas for agents

- Broadcasting requires **≥2 selected cards**; it mirrors what's typed into the
  **primary** card.
- Toggling Canvas with nothing open is a no-op.
- A "card" maps to a **tab**, identified by `tab.id` — the same ID the
  [`prowl` CLI](cli.md) uses.
