# 069 — Undo Close Terminal: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-09-16 | Plan written after reading Ghostty's macOS undo implementation and mapping Prowl's close paths | `5c381151` |
| 2026-09-16 | Undo stack, detach-instead-of-free close paths, restore, Ghostty `undo`/`redo` routing, `tabRestored` event, docs | #814 |
| 2026-09-17 | Dogfooding fix: ⌘W on an idle shell was not undoable. Ghostty's close callback carries `needsConfirmQuit()`, which is false for a shell at its prompt, and the first cut used it as "process alive". Retention now follows `childProcessHasExited` (`ghostty_surface_process_exited` or the `show_child_exited` report, which Ghostty sends before the close request of an exited child); close-on-success passes `retainForUndo: false` explicitly | #814 |
| 2026-09-16 | Review round 4 (Pi reviewer, 1 P2, accepted): Ghostty's `show_child_exited` (sent without a close request under `wait-after-command`) now reaches retained surfaces through `GhosttySurfaceBridge.onChildExited`, a close skips retention for a surface whose child already exited, and a tab record keeps only its living panes | #814 |
| 2026-09-16 | Review round 3 (Pi reviewer, 1 P2, accepted): the Canvas card-focus action `newTerminalTabCreatedInCanvas` resolves its target with `terminalWorktree(for:)`, so an undo in a plain-folder repository reveals the restored card too | #814 |
| 2026-09-16 | Review round 2 (Pi reviewer, 2 P1 + 1 P2, all accepted): a retained close defers the Codex forwarding record's retirement until the surface is freed (`deferredForwardingRecords`; the 2 s cleanup would have deleted the file inside the 5 s window); Canvas adoption asks for visible occlusion like `createSplit`; `tabRestored` now carries the tab and the reducer routes Canvas through `newTerminalTabCreatedInCanvas` (card focus) and normal mode through worktree selection only when another worktree is showing | #814 |
| 2026-09-16 | Review round 1 (Pi reviewer, 2 P1 + 2 P2, all accepted): pane restore selects its tab; Profile launch identity and managed-hook registration survive a restore (`TerminalRetainedSurfaceContext`, `onManagedHookReadopted`, `CodexForwardingRecordStore.reinstate`); pane-record validity compares split structure, not just the leaf set; `closeAllSurfaces` voids the worktree's retained closes (`onSurfacesReset`) | #814 |

## Outcome & current state (as of 2026-09-16)

- `supacode/Features/Terminal/Models/TerminalCloseUndoStack.swift` —
  `TerminalClosedTabRecord`, `TerminalClosedPaneRecord`, `TerminalCloseRecord`
  (`.pane` / `.tabs`, the latter carrying a whole batch), `TerminalReopenRecord`
  (redo), and `TerminalCloseUndoStack`: LIFO undo + redo slots, one expiry `Task`
  per entry on an injected `Clock<Duration>`, `onExpire` handing surfaces back for
  freeing, `discardSurface(id:)` for a process exit during the grace window, and
  `discard(where:)` for pruned worktrees. `timeout == .zero` expires at once.
- `supacode/Features/Terminal/Models/WorktreeTerminalState+UndoClose.swift` —
  `makeClosedTabRecord(for:)` (index, selection, tree, focused pane, run-script
  flag, bound-directory key), `detachTree(for:)`, `detachSurface(_:)`
  (suspends the view and nils every bridge callback except a pending
  `onCloseRequest` that reports the exit), `recordClosedTab(_:)` (group-aware),
  `restore(tab:)` and `restore(pane:)`, and the private `adoptRetainedSurface`
  that re-runs the surface half of tab creation (bridge/surface callbacks,
  `surfaces`, a fresh target handle, agent-detection wake).
- `supacode/Features/Terminal/Models/WorktreeTerminalState+Surfaces.swift` —
  the private `closeSurface(_:confirmation:retainForUndo:)` detaches when
  `undoCloseTimeout > .zero` and the caller allows retention; the last pane of a
  tab produces a tab record. `handleCloseRequest` passes
  `retainForUndo: processAlive`. `configureBridgeCallbacks` wires
  `bridge.onUndo` / `onRedo` to the state's `onUndoRequested` / `onRedoRequested`.
- `supacode/Features/Terminal/Models/WorktreeTerminalState.swift` —
  `undoCloseTimeout`, `pendingCloseGroup`, the four new callbacks,
  `closeTab(_:confirmation:retainForUndo:)`, and `closeTabs(_:)` which the three
  batch closes use so one ⌘Z restores the batch. Run Script replacement, stop, and
  agent-profile rollback pass `retainForUndo: false`.
- `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift` —
  owns `closeUndoStack` (timeout from `GhosttyRuntime.undoTimeout()`, clock
  injectable as `undoCloseClock`), wires each state's callbacks, `undoClose()`
  (pops until a restorable entry; batches replay in reverse because each index
  was taken from the shrinking array), `redoClose()` (re-closes with `.skip`,
  keeping the redo history while it runs), and `prune` discarding the removed
  worktrees' entries. A restore into a non-selected worktree emits
  `.tabRestored`.
- `supacode/Infrastructure/Ghostty/GhosttySurfaceBridge.swift` —
  `GHOSTTY_ACTION_UNDO` / `REDO` return the handler result; `false` lets the
  `performable` binding fall through to the pty (previously always swallowed).
- `supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift` — `isPendingClose`,
  `suspendForPendingClose()` (focus off, occlusion paused, wrapper link cleared,
  removed from its superview), `resumeFromPendingClose()`; the attachment-change
  reattach request skips pending views.
- `supacode/Infrastructure/Ghostty/GhosttyRuntime.swift` — `undoTimeout()` reads
  `undo-timeout` (milliseconds via `ghostty_config_get`, 5 s fallback).
- `supacode/Features/Terminal/Models/TerminalTabManager.swift` —
  `insertTab(_:at:select:)`.
- `supacode/Clients/Terminal/TerminalClient.swift`,
  `supacode/Features/App/Reducer/AppFeature+TerminalEvents.swift` —
  `Event.tabRestored(worktreeID:)` → `tabRestoredEffect` selects the worktree
  (or plain-folder repository). The coalescer never coalesces it.
- Docs: `docs/reference/keyboard-shortcuts.md` (engine table rows + "Undo close"
  section), `docs/components/terminal.md`, `docs/components/cli.md`.
- Tests: `supacodeTests/TerminalCloseUndoStackTests.swift` (7),
  `supacodeTests/WorktreeTerminalUndoCloseTests.swift` (13: tab index/selection/
  same surface/new handle, split position, expiry, process exit, dead-process
  close, zero timeout, batch, redo, stale pane, prune, reveal event),
  `GhosttySurfaceBridgeTests` (fall-through, handler result),
  `AppFeatureTerminalSetupScriptTests` (`tabRestored`).

Verification on 2026-09-16: `make build-app` 0 warnings; `make test` green
(3291 app tests + mirror and shell-cancellation bundles, zero failures);
`make check` passed. Live check against an isolated Debug instance
(`PROWL_CLI_SOCKET`, bundled debug CLI): a tab closed with `prowl close --force`
came back on `prowl key cmd-z` with the same tab and pane UUIDs, selection,
focus, and a marker echoed before the close still in scrollback; a split pane
closed and restored the same way; `cmd-shift-z` re-closed it and `cmd-z` restored
it again; six seconds after a close, `cmd-z` restored nothing.

## Deviations from plan

- `TerminalClosedPaneRecord` carries no worktree id; the id lives on the
  `TerminalCloseRecord` case, which is what the stack and manager key on.
- Batch restores replay records in reverse order (not mentioned in the plan);
  the first attempt restored in close order and misplaced the later tabs.
- The pane-record invalidation is lazy (checked at undo time by comparing the
  tab's current split structure with the captured tree minus the closed pane,
  ignoring ratios and zoom) rather than eager on every structural mutation; a
  stale entry is freed when ⌘Z reaches it or when it expires, whichever comes
  first.
- Restore carries launch bookkeeping the plan did not list: `forgetSurface`
  drops the Profile record and the manager revokes the managed hook at close
  time (observers see a real close), so the close record keeps both and the
  restore registers the same hook token again under a fresh evidence epoch.
  The Codex forwarding record is never retired while the close is retained
  (`WorktreeTerminalState.isRetainedForUndo` during the observer callbacks,
  `WorktreeTerminalManager.deferredForwardingRecords` afterwards); final
  disposal retires it, a restore drops the deferral.
- Every successful undo emits `tabRestored(worktreeID:tabID:)`; the reducer,
  not the manager, decides how to reveal it (Canvas card focus request, or
  worktree selection when another worktree is showing).
- Undoing a pane close selects the pane's tab (the plan only covered a
  different worktree); a single restored tab is selected, a batch keeps each
  tab's original selection.

## Review loop summary

Four rounds with a Pi reviewer (read-only, static inspection) on 2026-09-16:
2 P1 + 2 P2, then 2 P1 + 1 P2, then 1 P2, then 1 P2. Every finding was
accepted and pinned by a failing test before the fix. Round 4 reported no
P0/P1 and nothing further on the ordinary close → ⌘Z → redo path.

- The plan gated retention on the close callback's `processAlive`; that flag is
  Ghostty's `needsConfirmQuit()` and is false for an idle shell, so only panes
  with a foreground child (agents, long commands) were undoable at first. The
  gate is the child's exit state instead; the confirmation prompt still keys
  off the callback flag.

## Open questions

- ~~Ghostty itself does not fire `undo` when no terminal surface has focus.~~
  Closed by [002-empty-worktree-undo.md](002-empty-worktree-undo.md).
- `undoCloseTimeout` is read once at manager creation. A Ghostty config reload
  that changes `undo-timeout` takes effect on the next launch.
