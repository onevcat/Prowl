# 034.005 — App activity signal

## Context

The reducer received one `scenePhaseChanged(.background)` at launch and never another phase.
Found while verifying docs-ai 084 B3f on 2026-10-25: remote polls paused at launch and never
resumed.

Root cause: `WindowTabbingView` set itself as the main window's delegate (upstream
commit `293a9a53`, 2026-02-02, to order the window out instead of closing it). That replaced
the delegate of SwiftUI's `AppKitWindow`. SwiftUI derives the scene phase from that delegate,
so the main scene stayed `.background`. The Settings window, which has no such view,
reported `.active` as usual. With the takeover disabled, the main scene reported `.active`
at once.

Everything that `AppFeature` hung on the phase had never run since then:

| Behavior | Added | Effect of the frozen phase |
| --- | --- | --- |
| Reload all repositories when Prowl becomes active | 2026-01-24 (as the launch load, a reload after 01-28) | Never ran |
| Reload every 30 s while active | `592f5cd3`, 2026-02-05 | Never ran |
| Save the terminal layout when Prowl leaves the foreground | 2026-03-31 | Ran only once at launch, from the `.background` that `ContentView`'s `.task` sent |
| One line-diff refresh on foreground ([037](../037-line-diff-tracking/000-plan.md)) | 2026-05-28 | Never ran |
| Pause and resume remote polls ([084 B3f](../084-ssh-remote-folders/024-b3f-refresh-cadence.md)) | 2026-10-23 | Paused at launch, never resumed |

The `.task` send of #373 (see the plan) was added because no phase transition ever fired. It
sent the initial `.background`, so the refresh loop still did not start, and it cleared the
saved layout at launch (fixed separately by skipping the save during a pending restore).

A second fact: on macOS, a scene stays `.active` while its window is visible, also when Prowl
is in the background. The scene phase cannot tell whether the user is using Prowl, even when
it is delivered.

## Change

- **Activity comes from AppKit.** `ProwlAppDelegate` sends `AppFeature.Action.appActivityChanged`
  from `applicationDidBecomeActive` and `applicationDidResignActive`. `ContentView` no longer
  reads the scene phase, and `scenePhaseChanged` is gone.
- **Becoming active:** resume remote polls, reload every repository once (`reloadRepositories`,
  not animated, after the first live load only), and refresh line diffs once.
- **Launch seeds the pause.** `applicationDidFinishLaunching` sets the remote poll pause from
  `NSApplication.isActive` before the first load. A launch in the background (`open -g`)
  never resigns active, so without the seed it would poll until Prowl first became active.
- **Resigning active:** pause remote polls, and save the layout under the existing guards
  (restore enabled, no pending restore, not cleared).
- **The 30 s reload is removed.** The git registry watcher of the plan above already reports
  worktrees changed outside Prowl. The reload on activation covers a missed event.
- **The window delegate is kept.** `MainWindowDelegateProxy` handles `windowShouldClose` (order
  out, as before) and forwards every other message to SwiftUI's delegate. A proxy of an
  earlier view is unwrapped, not chained. The proxy is a separate object, so the view's
  responder chain is unchanged.

Key files: `App/Sources/App/WindowTabbingDisabler.swift`, `App/Sources/App/ProwlApp.swift`,
`App/Sources/Features/App/Reducer/AppFeature.swift`, `App/Sources/App/ContentView.swift`.
Tests: `App/Tests/AppFeatureAppActivityTests.swift`, `App/Tests/WindowTabbingDisablerTests.swift`,
and the layout save cases in `App/Tests/AppFeatureTerminalLayoutRestoreTests.swift`.

`docs/components/repositories-and-worktrees.md` and `docs/components/terminal.md` describe the
new refresh and save points.

## Refs

PR #991
