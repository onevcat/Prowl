# 069.002 — Undo after the last tab of a worktree closes

## Context

The plan listed "undo while no terminal surface has keyboard focus" as a
non-goal because ⌘Z only entered through Ghostty's `undo` binding, which needs
a focused surface. After the last tab of a worktree closed in the sidebar view
the terminal area was empty and ⌘Z did nothing, although the tab's record was
retained and restorable. Ghostty.app covers the same case (its last window
closed) through the standard `UndoManager` chain, and onevcat asked for the
equivalent.

## What did not work

The first cut mirrored Ghostty: an `UndoManager` subclass bridged to the close
stack, returned from the main window delegate's `windowWillReturnUndoManager`.
A probe build showed the delegate method is never called: SwiftUI's default
Edit › Undo / Redo items (the `.undoRedo` command group) validate and act
through SwiftUI's own undo plumbing and do not consult `NSWindow.undoManager`,
so the item stayed disabled and ⌘Z did nothing. Replacing the command group
would have taken ⌘Z away from text fields.

## Change

- `supacode/App/TerminalCloseUndoKeyMonitor.swift` — a local `keyDown` monitor
  bound to its owning window (`shouldDispatch(_:ownerWindow:)` rejects events
  of any other window, so a Settings or Diff window never drives the main
  window's stack) that passes the key through when the first responder is a
  `GhosttySurfaceView` (Ghostty's binding handles it) or an `NSText` field
  editor (standard text undo). It swallows the event only when a close was
  undone or redone.
- `supacode/Infrastructure/Ghostty/GhosttyRuntime+AppKey.swift` — the key is
  resolved by libghostty itself: `ghostty_app_key_is_binding` then
  `ghostty_app_key`, the pair Ghostty.app uses for its windowless undo. Ghostty
  emits an app-scoped `undo` / `redo` action; the runtime's action callback
  (`handleAppScopedAction`) routes it to `WorktreeTerminalManager.undoClose()`
  / `redoClose()` and records the outcome, because `ghostty_app_key` only
  reports that a binding matched. Every other app-scoped action is refused
  while the key is being dispatched, so this route cannot fire `open_config`,
  `reload_config`, or the like. The user's real bindings apply: rebinding,
  unbinding, `performable:` prefixes, additions. (Review Loop round 1 and 2,
  R2: the first cut reconstructed triggers from `ghostty_config_trigger`, whose
  reverse map hides `performable` bindings and keeps one trigger per action.)
- `supacode/App/WindowTabbingDisabler.swift` — the main window's helper view
  owns the monitor; `ContentView` supplies the triggers and the manager
  closures. The monitor is re-created only when the triggers change.
- Tests: `supacodeTests/TerminalCloseUndoKeyMonitorTests.swift` (window and
  responder guards with real `NSWindow`s and synthesized events) and
  `supacodeTests/GhosttyRuntimeAppKeyTests.swift` (config-to-dispatch against a
  real libghostty app: defaults, `performable:` rebinding with unbinds, unbound
  keys, empty history, unrelated bindings).

## Refs

#816.
