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

The Active Agents header also provides a persisted Island visibility toggle. Holding Command
replaces it with the existing navigation hint, keeping both controls in the same trailing space. The icon stays the same;
primary foreground means enabled and secondary gray means disabled. The automatic-panel toggle
keeps its title and explanatory text inside one form row.

Hover changes explicitly carry an animation transaction to the grip opacity and summary offset.
Roster layout updates carry no hover animation. This replaces the compact-subtree animation
disabling and implicit scoped animations, which caused missing hover motion and click-time fading.
Regression recipe: hover a floating bar, then click to expand and collapse without moving the
pointer. The grip and counts must stay in their hovered positions; leaving the bar hides the grip.

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

The PR #764 follow-up passed 102 focused app/settings/island tests, including both persisted
visibility-toggle directions and collapse of an expanded roster when disabling the island.

An isolated Debug follow-up confirmed the panel button switches from Off to On with the correct
Hide Agent Island tooltip. The UI automation connection again failed on Display navigation, so
the grouped row and floating animation remain awaiting manual visual confirmation.

The hover-transaction follow-up adds two native SwiftUI rendering tests: pointer entry and exit
must produce intermediate presentation values, roster expansion/collapse must retain the fully
revealed grip, and Reduce Motion must change immediately. These tests pass in an NSHostingView
fixture; end-to-end pointer interaction in the live island still requires visual verification.

## Stable hover during panel changes

Hover-origin animation alone does not distinguish real pointer movement from transient tracking
callbacks caused by panel resizing or ordering. The bar now retains its hover state while the
pointer remains inside the compact bar's screen rectangle. The window controller publishes that
rectangle before changing the panel frame, independently of intermediate SwiftUI layout. A real
pointer exit still animates normally; no timeout or click-duration lock is involved.

The rendering regression sends alternating exit/entry callbacks with a stationary pointer during
both roster expansion and collapse. It fails when callbacks directly drive the hover state and
must pass with screen-coordinate reconciliation, followed by a real animated exit.

The stationary-pointer regression was observed failing before reconciliation and passing after it.
All 38 focused hover, screen layout, and isolation tests passed. The intermittent live-window
behavior has not been independently reproduced through actual mouse interaction.

## Empty island

When enabled, Agent Island now remains visible without sessions by default. An optional
`agentIslandOnlyShowWithAgents` setting restores hiding the empty bar. Missing keys decode to
false. The empty compact summary shows the app icon; the roster shows “No running agents”
and retains its settings gear while omitting unavailable navigation hints. Menu and global
shortcut eligibility use the same visibility policy as the bar. Session presence includes all
Active Agents states, not only Working.

Validated with 103 focused tests, `make check`, and `make build-app`. An isolated empty-session
Debug instance displayed the app icon and opened “No running agents” through the menu command,
with the settings gear visible. UI automation disconnected when testing the gear's navigation.

The empty-bar icon uses `AgentIslandAppIcon.imageset` at its native 22pt size, with 22px and
44px PNGs downsampled from `AppIcon.appiconset/appicon-macOS-Dark-1024x1024@1x.png` using
`sips --resampleHeightWidth`. A 5pt continuous rounded clip preserves the compact icon shape.
This avoids runtime representation selection and resizing of `NSApp.applicationIconImage`.
Regenerate both PNGs from the app-icon source when that artwork changes.
