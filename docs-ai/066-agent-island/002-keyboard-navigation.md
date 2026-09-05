# 066.002 — Keyboard Navigation

> Historical implementation record. The global shortcut model described here was superseded by
> [066.003 — Prowl Shortcut Loop](003-prowl-shortcut-loop.md) before #758 merged.

## Context

Agent Island shipped as a pointer-driven projection of Active Agents. That made the compact
status useful while another application was frontmost, but opening the secondary roster and
choosing an agent still required the pointer. For an efficiency tool, the island needs a
keyboard path with a dedicated, discoverable shortcut that does not overload the in-app Active
Agents panel command.

## Change

- Add a dedicated **Toggle Agent Island** shortcut (`⌘⇧P` by default) as the global hot-window
  entry while Agent Island is enabled. It is separate from **Toggle Active Agents Panel**
  (`⌘⌥P`) and participates in the existing Settings → Shortcuts resolver, including clear,
  remap, conflict handling, and reset-to-default behavior. The toggle rejects `⌘1`…`⌘9` and
  `⌘⌥1`…`⌘⌥9`, which remain reserved for contextual roster and attention-slot activation.
- Let the expanded nonactivating panel become key without activating Prowl. The compact island
  remains non-key, and collapsing the roster releases keyboard focus.
- Give the island its own transient selection and nine-entry pages. Arrow Up pairs with `k` and
  Arrow Down with `j` for selection; Arrow Left pairs with `h` and Arrow Right with `l` for paging
  while preserving the row position when possible. Space or Return opens the selected pane in
  Prowl; Escape collapses the roster. The earlier `u`/`d` page bindings are removed.
- Use `⌘1`…`⌘9` for direct activation of the nine visible slots, not globally numbered agents.
  Every visible row keeps its current shortcut label at the tab bar's caption scale; the mapping
  restarts at `⌘1` after paging.
- Register `⌘⌥1`…`⌘⌥9` for the first nine strong-reminder slots while the roster is closed.
  Command–Option is deliberate: Command–Shift digits commonly collide with macOS and application
  shortcuts. The shortcut projection is explicitly capped at nine and follows the existing
  attention projection (Blocked before unviewed Done, newest first
  within each state), and every assigned attention cell keeps its shortcut in an inset tag centered
  along the card's top edge without competing with its metadata. Only currently
  backed slots are registered; roster expansion removes them until it collapses again.
- Limit the strong-reminder collection to a `2 × 3` grid. Additional reminders stay folded behind
  a bottom-right `+N` badge instead of adding scrolling or paging to this compact surface.
- Keep a compact legend at the bottom of the roster for the persistent interaction model. Each
  arrow is grouped with its Vim counterpart (`↑ K`, `↓ J`, `← H`, `→ L`) so the direction is
  explicit; Space and Return remain grouped for opening. The row-level shortcut labels
  communicate the direct `⌘1`…`⌘9` mapping without a redundant transient or footer hint.
  The paging hint and clickable page controls appear only when multiple pages exist.
- Keep the selection presentation-only until activation. It does not mutate Active Agents state,
  mark entries as handled, or focus a terminal while merely navigating.
- On displays without a notch, expose a small top-center drag grip instead of making the whole
  floating pill draggable. Dragging is horizontal-only, stays inside the display's visible bounds,
  stays inside the menu bar band, and persists a normalized position per hardware display ID. The
  floating compact bar overlays that band at exactly its height. Notched displays remain
  physically anchored to the cutout. Settings can reset all floating positions to center.
- Keep a compact silent-opacity control on the floating pill's center axis. After the pointer has
  remained outside the island for three seconds, the full floating surface fades to the selected
  opacity and restores immediately on hover. Blocked or unviewed Done reminders force the entire
  island to remain fully opaque. An expanded roster—whether opened by pointer or `⌘⇧P`—also stays
  fully opaque; closing it starts a fresh three-second delay. When multiple displays are connected,
  the roster header exposes an icon-only display menu for switching the island's target without
  opening Settings; single-display setups omit the redundant control. Slider movement stays in a
  local draft and persists once editing ends, avoiding full settings synchronization for every
  intermediate value.

The global entry uses Carbon hot-key registration, which consumes the configured chord without
requiring Accessibility or Input Monitoring permission. Registration is diffed by toggle binding
and attention-slot count, with an atomic refresh of both groups when the toggle changes and a
forced refresh when the keyboard layout changes. Observation callbacks carry a lifecycle
generation so disabling and re-enabling the island cannot accumulate stale tracking chains. Once
expanded, ordinary navigation keys are handled locally by the key panel, so they do not leak into
the previously frontmost app.

## Refs

- Implementation: `1f32784a`
- PR: #758

## State at 2026-09-03

Implemented on 2026-09-03. The island owns a dedicated, remappable `⌘⇧P` global shortcut and
keyboard focus only while expanded. It supports transient selection, nine-entry paging through
Arrow Left/Right or `h`/`l`, visible-slot activation, confirmation, and dismissal. Visible rows
keep their `⌘1`…`⌘9` labels; the footer permanently shows movement and confirmation, adding
paging only when a second page exists. Collapsed strong reminders expose `⌘⌥1`…`⌘⌥9` for their
first nine priority-ordered cells, using the same focus path as a pointer click.
On displays without a notch, a dedicated top-center grip moves the floating island horizontally;
the normalized position is saved per display and can be reset from Settings. The panel remains
inside the visible horizontal bounds as its content width changes, and its top edge stays flush
with the physical screen edge. Its compact height matches the target display's menu bar, so it
overlays the system band instead of hanging below it.
The floating pill also owns a persisted silent-opacity control: after three seconds without hover,
the entire floating surface fades to that level unless a strong reminder exists, in which case it
stays fully opaque. With multiple displays connected, an icon-only display menu in the roster
header provides fast placement changes without secondary explanatory copy.

Verification completed with `make check`, `make test`, and `make build-app`; all passed with zero
test or build failures. Final native screenshot capture was unavailable because the computer-use
native pipe could not start; the final layout change is covered by source inspection and the
successful Debug build.
