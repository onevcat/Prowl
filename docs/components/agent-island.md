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
displays, and the drag grip appears on hover only in floating mode.
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
- **The Active Agents panel's top-right button** toggles Show Agent Island directly. Holding
  Command replaces it with the panel's navigation shortcut hint.
- **Click the bar** to open or close the full roster. This does not bring Prowl forward.
- **Hover over a floating bar** to reveal its leading drag grip. The grip fades in while state
  counts shift right inside the fixed-width bar; leaving reverses the animation. Opening or closing
  the roster while hovered keeps the grip visible without replaying its fade. Panel layout changes
  do not count as leaving the bar; the pointer must move outside its screen area. Reduce Motion
  makes this change immediate. Drag horizontally to reposition it; the grip stays visible during
  the drag. Prowl remembers positions per monitor. Notched displays remain fixed to the cutout
  and do not show a grip.
- **Silent Opacity** lives in Settings → Agents → Display. It affects floating monitors only.
  The island fades three seconds after the pointer leaves, returns to full opacity on hover,
  and stays fully opaque while the roster is open or Blocked/unviewed Done reminders exist.
- **Press the Agent Island shortcut** to open or close the roster like a hot window. It ships
  unassigned to avoid taking an established shortcut from the frontmost application; assign it
  under Settings → Agents → Display or Settings → Shortcuts if desired. Prowl registers that shortcut globally only while the
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
- **The footer gear** opens Settings → Agents → Display and collapses the roster without
  selecting another pane.
- **Open Prowl** in the roster header brings the main window forward without changing the
  selected agent.
- **Click outside or press `Esc`** to collapse the roster. The expanded island is a temporary
  keyboard context: recognized navigation keys act on the roster and other keys are ignored, so
  they do not leak into the previously frontmost application. Collapsing never marks an entry as
  handled.

## Settings

Settings → Agents → Display → **Agent Island**:

- **Show Agent Island** (`agentIslandEnabled`, default `false`).
- **Monitor** (`agentIslandDisplayPreference`, default Automatic). Automatic follows the display
  that contains Prowl's main window, then a built-in notched display, then the macOS main display.
  A specific display is remembered by its hardware identifier, so it survives renames and system
  language changes; while it is disconnected the island temporarily follows Automatic and the
  picker keeps the choice under its last-known name.
- **Floating Positions** resets saved horizontal positions for displays without a notch. The
  default position is centered.

- **Toggle Agent Island** records the same binding as Shortcuts, with shared conflict, clear,
  and reset behavior. The globe indicates system-wide scope; its tooltip explains the global grab.
  Failed registration appears in the shortcut row.
- **Silent Opacity** (`agentIslandSilentOpacity`, default 35%, range 20–100%) controls the quiet
  floating bar. It does not affect notched monitors. Slider changes persist when editing ends.

With an external and built-in monitor connected, there is still only one island. Automatic follows
Prowl's main window; a pinned monitor stays selected while that window moves elsewhere. Disconnecting
it temporarily uses Automatic, and reconnecting it restores the pinned choice. A pinned notched
monitor uses notch placement; a monitor without a notch uses the draggable floating bar.

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
