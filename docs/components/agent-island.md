# Agent Island

> An opt-in, notch-aware projection of Active Agents at the top of one display.

**Keywords:** agent island, dynamic island, notch, floating pill, active agents, working, blocked, done, idle, display

**Related:** [active-agents](active-agents.md) · [agent-detection](agent-detection.md) · [notifications](notifications.md) · [settings](settings.md)

## What it is

Agent Island shows Prowl's Active Agents roster at the top of one display, so a blocked or
finished agent is visible while another application is in front. It does not detect agents or
track acknowledgement on its own: every label and transition comes from the same `Working`,
`Blocked`, `Done`, and `Idle` entries the sidebar panel shows.

The island is off by default. When enabled it appears whenever the roster has at least one
entry. On a notched display it merges with the top edge, exactly as tall as the menu bar, with
content in two wings on either side of the camera cutout; on other displays it is a centered
floating bar overlaid directly on the menu bar at the same height. It
stays visible across Spaces and over fullscreen applications and never becomes the active window.

## Exposure principle

Agent Island reveals capabilities contextually instead of presenting every control at once. A
control, hint, or callout appears only when the current state makes it useful and immediately
actionable: paging requires multiple pages, display switching requires multiple connected
displays, and opacity requires floating mode.
Secondary capabilities stay in the expanded roster or Settings. New island affordances should
define their exposure condition explicitly; permanent visibility requires a clear reason.

The intended experience is a restrained surface whose next action feels timely and obvious—not a
feature inventory the user has to decode.

## Presentation

| Active Agents state | Island behavior |
|---|---|
| **Working** | Counted in the compact bar like every other state; no callout of its own. |
| **Blocked** | A **Blocked** cell below the bar. Blocked cells sort before Done. |
| **Done** | A **Done** cell while the entry is still unviewed in Active Agents. |
| **Idle** | Listed in the expanded roster; may also appear as a quiet icon in the compact cluster. |

The leading part of the bar lists how many agents are in each state, in attention order
(blocked, done, working, idle), each as a state-colored symbol and a number; states with no agents
are left out. The floating pill uses the same summary at a slightly larger size. The trailing edge
of the bar shows up to three runtime icons: non-Idle agents first by recency,
Idle agents last, and a small `+N` for the rest. Idle icons have a static outline; Working,
Blocked, and Done icons use a static orange, red, or blue outline in the compact bar. When the same
icons appear in Blocked or Done attention cards, they retain the original state-paced gradient
rotation. The floating bar reserves its center control area; when all four states are present, the
summary switches to compact metrics. The bar keeps a stable 340pt width in every state, avoiding
both content compression and width jumps as the state mix changes.

Blocked and Done cells form a small grid under the bar: one column for a single entry, two
columns otherwise, with at most three rows. When more than six reminders exist, a `+N` badge at
the collection's bottom-right reports how many lower-priority reminders are folded away. The
collection does not scroll or page. Each cell shows the agent name and state on the left and the
repository plus the same branch/tab subtitle as Active Agents on the right; a live Workflow role
badge takes the subtitle position, as in the sidebar. The displayed priority order is Blocked
first, then unviewed Done, newest first within each state. Cells
cannot be dismissed from the island. A
Blocked cell clears when the agent leaves that state, a Done cell clears once the entry is viewed,
and a removed entry disappears with the roster.

## Interactions

- Agent Island does not show hover tooltips. Actions stay discoverable through their visible
  labels, icons, accessibility labels, and the expanded roster's keyboard legend.
- **Click the bar** to open or close the full roster. This does not bring Prowl forward.
- **Drag the small grip at the top center** of a floating island to reposition it horizontally.
  The pointer becomes an open hand over the grip and a closed hand while dragging.
  Prowl remembers the position independently for each display and keeps the full island inside
  the visible screen bounds. The bar stays inside the menu bar band while moving; notched displays
  remain anchored to the physical cutout.
- **Use the half-filled circle at the center** of a floating island to set its silent opacity.
  The island returns to full opacity on hover and fades to the chosen level three seconds after
  the pointer leaves. Any Blocked or unviewed Done reminder keeps the full island at 100% opacity
  until all strong reminders clear. Opening the roster by click or its assigned shortcut also
  keeps it fully opaque; after the roster closes, a new three-second delay begins. Slider changes
  remain local while dragging and persist once the adjustment ends. This control is not shown on
  notched displays.
- **Press the Agent Island shortcut** to open or close the roster like a hot window. It ships
  unassigned to avoid taking an established shortcut from the frontmost application; assign it
  under Settings → Shortcuts if desired. Prowl registers that shortcut globally only while the
  island has entries and Prowl is in the background. In Prowl it uses the normal menu shortcut.
  While globally registered, Prowl receives the chord ahead of the frontmost application, so that
  application cannot use the same shortcut until the island becomes inactive or Prowl returns to
  the foreground.
  Active Custom Command collisions are rejected or marked Unavailable because Custom Commands
  take precedence. A failed macOS global registration is also marked Unavailable until corrected.
- **Click a Blocked or Done cell** to bring Prowl forward and focus that agent's exact worktree,
  tab, and pane.
- **The roster** lists every entry with the same rows, ordering, Workflow badges, and context menu
  as the [Active Agents panel](active-agents.md), including **Hand Off…** and **Run Workflow**.
  Each row's subtitle shows both the pane title and the branch, separated by a middle dot,
  regardless of the sidebar's title-or-branch setting; a live Workflow role badge replaces it.
  Clicking a row, or choosing one of those actions, brings Prowl forward first and then behaves
  exactly as it does in the sidebar. On a notched display the roster is as wide as the bar above
  it; under the floating pill it is wider than the pill. The roster shows up to nine agents per
  page. With multiple displays connected, its centered display button switches Agent Island
  between Automatic and any connected display without opening Settings; the button stays hidden
  on a single-display setup.
- **Keyboard navigation stays available while the roster is open.** Arrow Up or `k` and Arrow
  Down or `j` move the highlight without focusing a terminal; Arrow Left or `h` and Arrow Right
  or `l` move one page; Return opens the highlighted agent (Space is an alias); and `1`…`9` opens
  the corresponding agent on the current page.
  These are visible-slot shortcuts, not permanent agent numbers: every page labels its visible
  rows from `1` again. Digits remain local even if shortcut modifiers are still held. The row
  labels use the tab bar's caption scale, and a compact legend for
  movement, paging, and confirmation stays visible; the paging hint appears only when the roster
  has more than one page.
- **Open Prowl** in the roster header brings the main window forward without changing the
  selected agent.
- **Click outside or press `Esc`** to collapse the roster. The expanded island is a temporary
  keyboard context: recognized navigation keys act on the roster and other keys are ignored, so
  they do not leak into the previously frontmost application. Collapsing never marks an entry as
  handled.

## Settings

Settings → Notifications → **Agent Island**:

- **Show Agent Island** (`agentIslandEnabled`, default `false`).
- **Display** (`agentIslandDisplayPreference`, default Automatic). Automatic follows the display
  that contains Prowl's main window, then a built-in notched display, then the macOS main display.
  A specific display is remembered by its hardware identifier, so it survives renames and system
  language changes; while it is disconnected the island temporarily follows Automatic and the
  picker keeps the choice under its last-known name.
- **Floating Positions** resets saved horizontal positions for displays without a notch. The
  default position is centered.

The section footer provides a link that opens Settings → Shortcuts already filtered to
**Toggle Agent Island**. If macOS rejects the current global registration, the footer also
identifies the unavailable binding and keeps the same direct link for choosing another shortcut.

With Reduce Motion enabled, icon changes fade instead of sliding and the state rings keep their
color without rotating.

## Boundaries

Agent Island offers no inline permission approval or terminal input; it navigates to the pane
instead. It adds no failure state of its own: an interrupted agent shows up only as whatever
Active Agents already reports.

On a notched display the bar sits on top of the menu bar, so while the roster is non-empty the
wing on each side of the cutout (about 120pt) covers that part of the menu bar band. A menu title
or status item that lands under a wing is not clickable until the island disappears; apps with
very long menu bars are the ones affected.
