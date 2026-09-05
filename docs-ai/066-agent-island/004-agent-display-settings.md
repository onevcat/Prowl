# 066.004 — Agent Display Settings

## Context

Agent presentation preferences were split between General, Notifications, Shortcuts, and the
floating island. They belong together under Agents → Display, with a direct entry from the roster.

## Change

- Move existing Active Agents and Agent Island settings into Agents → Display before Profiles.
- Rename the island's screen picker to Monitor and explain automatic and pinned multi-monitor behavior.
- Reuse the shortcut editor, including recording, reset, conflict handling, and availability feedback,
  for the global toggle in both Display and Shortcuts. Mark its system-wide scope with a globe.
- Move silent opacity into Settings. Keep floating dimensions fixed while a leading drag grip fades
  in and shifts status counts on hover. Respect Reduce Motion; notched islands remain fixed.
- Open Agents → Display from the expanded roster footer, collapsing the roster without changing panes.

## Verification

Cover settings navigation and roster collapse with reducer tests; retain shortcut conflict and
monitor geometry coverage. Build the Debug app and inspect Display, both shortcut entry points,
the floating hover layout, and the roster settings link.

## Result

Implemented on main. The recorder and its existing conflict/reset workflow are shared by
`ShortcutSettingsEditor`; `ShortcutsSettingsView` remains the full-table entry point.
The footer activates Prowl before opening Display, without issuing terminal focus commands.

- 147 focused settings, agent navigation, shortcut conflict, and monitor/isolation tests passed.
- The background settings-entry regression was observed failing before adding window surfacing,
  then passed with the rest of the focused suites.
- `make check` and `make build-app` passed.
- An isolated Debug instance confirmed sidebar ordering and removal of Active Agents from General.
  Computer Use then lost its native connection before Display-page interaction checks could finish.
  Live recorder, floating-hover animation, and footer-click verification remain manual; multi-monitor
  behavior is supported by code inspection and geometry tests, not a physical two-monitor check.

Manual follow-up: inspect Display at the minimum settings window width; record/clear a shortcut
from each entry point; hover and drag a floating bar, then open its footer gear while Prowl is
in the background. The bar must not resize, and Settings must open on Agents → Display.
