# 009 — Terminal Surface Lifecycle: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-03-23 | Fix blank surface when exiting Canvas via toggle shortcut: stop occluding in `deactivateCanvas()` (onAppear/onDisappear ordering race); occlude non-selected worktrees from `setSelectedWorktreeID` on canvas exit instead | PR #42 |
| 2026-03-24 | General occlusion cache (`OcclusionState`, desired vs applied); re-send current occlusion on `GhosttySurfaceView` reattachment, tied to real NSView lifecycle events; unit coverage | PR #50 |
| 2026-04-03 | Blank terminal still reproducible: force-refresh surface activity on canvas exit, invalidate per-surface occlusion caches before reapplying visibility/focus, add `[CanvasExit]` diagnostics | PR #132 |
| 2026-04-05 | Defer occlusion apply until the surface has both a superview and a window; keep desired value across canvas-exit reparenting so the real reattach triggers a fresh apply | PR #156 |
| 2026-04-11 | Stop restored, non-displayed surfaces from spinning CPU/GPU: occluding applies immediately even without a view hierarchy — see [002-surface-resource-waste.md](002-surface-resource-waste.md) | PR #198 |
| 2026-04-14 | Host ownership fix (accepted root cause): terminal wrapper reattaches only orphaned surfaces, never steals from a live host (e.g. Canvas); detach-intent diagnostics; host-ownership unit tests | PR #201 |
| 2026-04-16 | Fix Canvas split-pane rendering freeze: `isCanvasManaged` flag skips `applySurfaceActivity` while Canvas owns occlusion; new split panes explicitly un-occluded in Canvas | PR #203 |
| 2026-04-29 | Investigation closed in the tracking doc: no recurrence after #201/#203; most investigation logs removed, low-frequency `[CanvasExit]` / `[TerminalWake]` logs retained | `doc-onevcat/canvas-exit-terminal-blank-tracking.md` |
| 2026-05-29 | Fix terminal surface leak on tab close (fixes #370): stale SwiftUI renders no longer recreate surfaces for closed tabs; first tab uses Ghostty tab context — see [002-surface-resource-waste.md](002-surface-resource-waste.md) | PR #372 |
| 2026-10-24 | Fix blank Canvas card for the tab selected on entry (regression from #931's `RemotePaneBadge` overlay, first shipped in 2026.10.21): the leaving normal view's split host built one more terminal wrapper whose `init` took the surface from the Canvas card and never joined a window. A host in a window now takes back a surface that sits outside every window, and the surface asks its live hosts to do so when it leaves the window. `TerminalSplitTreeAXContainer` also detaches its inner `NSHostingView` when SwiftUI dismantles it, so the leaving tree cannot build that wrapper | PR #987 |

## Outcome & current state (as of 2026-10-24)

- `supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift` — `OcclusionState` struct
  (`desired`/`applied`, `setDesired`, `prepareToApply`, `invalidateForAttachmentChange`).
  `setOcclusion(_:)` pauses immediately (even with no surface/view hierarchy) but defers
  resume until `isReadyToApplyOcclusion` (superview + window), logging
  `[CanvasExit] deferOcclusion` when deferring. `viewDidMoveToWindow` /
  `viewDidMoveToSuperview` call `handleAttachmentChange()`, which invalidates the applied
  cache, asks its hosts to take it back when it is outside every window (2026-10-24: the
  last scroll wrapper when orphaned, then every registered host that is in a window), and
  reapplies the desired value once attached. Each scroll wrapper registers itself in the
  surface's weak `hosts` table from `init`.
- `supacode/Infrastructure/Ghostty/GhosttySurfaceScrollView.swift` —
  `ensureSurfaceAttached(requiresLiveHost:)`: never steals the surface from a host in a
  window and never adopts a surface pending close. A terminal host adopts an orphaned
  surface (`superview == nil`); since 2026-10-24 any host in a window (Canvas included)
  also takes back a surface that is outside every window. `init` still takes the surface
  unconditionally, so a wrapper that SwiftUI builds in a leaving view tree can strand it;
  the in-window rule repairs that. `[CanvasExit] hostReattach` / `hostReattachComplete`
  logs.
- `App/Sources/Features/Terminal/Views/TerminalSplitTreeView.swift` —
  `TerminalSplitTreeAXContainer.dismantleNSView` calls
  `TerminalSplitAXContainerView.detachHostingView()` (2026-10-24). SwiftUI dismantles the
  representable before AppKit takes the container out of the window; in that interval the
  inner `NSHostingView` can build its saved `rootView` again and call `makeNSView` on the
  leaving tree. Removing the hosting view at dismantle stops it.
- `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift` —
  `setSelectedWorktreeID` handles the leaving-canvas transition (previous selection nil):
  occludes all worktrees except the newly selected one; `[CanvasExit] enteringCanvas` /
  `setSelectedWorktreeID` logs retained.
- `supacode/Features/Terminal/Models/WorktreeTerminalState.swift` — `isCanvasManaged`
  flag; `supacode/Features/Terminal/Models/WorktreeTerminalState+Surfaces.swift` —
  `syncFocusIfNeeded()` guards on `!isCanvasManaged`; `createSplitOnFocusedSurface`
  un-occludes new panes when canvas-managed; `setAllSurfacesOccluded()` helper.
- `supacode/Features/Canvas/Views/CanvasView+Focus.swift` — `activateCanvas()` sets
  `isCanvasManaged` and manages occlusion for card surfaces; `deactivateCanvas()` clears
  the flag and deliberately does *not* occlude (comment documents the
  onAppear-before-onDisappear rationale from #42).
- `supacode/Infrastructure/Ghostty/GhosttyRuntime.swift` — `[TerminalWake]` sleep/wake
  summary log retained.
- Tests in `supacodeTests/GhosttySurfaceViewTests.swift`: the `OcclusionState` suite
  (resend-after-attachment-change, deferred desired values,
  `occlusionFalseAppliesImmediatelyWithoutViewAttachment`,
  `occlusionCanRecoverWhenAttachmentCallbackIsMissedAfterReattachment`) and the host
  ownership trio (`terminalHostReattachesSurfaceOnlyAfterItLeavesTheViewTree`,
  `terminalHostDoesNotStealSurfaceFromCanvasHost`,
  `canvasHostDoesNotStealDetachedSurfaceBack`) — all named in the tracking doc and present —
  plus the 2026-10-24 window-ownership tests
  (`canvasHostInWindowReclaimsSurfaceFromHostOutsideWindow`,
  `surfaceReturnsToLiveHostAfterHostOutsideWindowTakesIt`,
  `hostInWindowDoesNotStealSurfaceFromAnotherHostInWindow`,
  `hostInWindowDoesNotReclaimSurfacePendingClose`).

## Deviations from plan

- #132's "force-refresh terminal surface activity when exiting Canvas"
  (`refreshSurfaceActivity`) no longer exists in the tree; the mechanism was superseded by
  #156's deferred-apply and #203's `isCanvasManaged` ownership of visibility. Its
  surviving contribution is the `[CanvasExit]` diagnostic trail.
- Most per-step investigation logging added during #132/#201 was removed at closure
  (2026-04-29); only the low-frequency log set listed in the tracking doc remains.

## Open questions

- The root cause is the tracking doc's "most likely failure mode", established by
  elimination and non-reproduction rather than a captured repro of the stale-wrapper
  deinit; the entry reflects that confidence level.
- 2026-10-24: the Canvas-entry blank card was captured with wrapper-level logs. Entering
  through the sidebar segment or `prowl canvas show` reproduced it every time; `⌘⌥↩` did
  not, so the trigger depends on SwiftUI update order. Mechanism, confirmed with stacks and
  a standalone repro: an `NSHostingView` nested in an `NSViewRepresentable` stays in the
  window after SwiftUI dismantles the representable. Its content subgraph is invalidated,
  and its own graph host then builds the saved `rootView` again on the next transaction
  flush, which calls `makeNSView` on the leaving tree. In Prowl a `.task` modifier (even an
  empty one; `.onAppear` and `.onDisappear` do not) makes that flush lay out the leaf, so
  `RemotePaneBadge` exposed it. The standalone repro hits it without `.task`. The detach at
  dismantle removes the trigger; the ownership rule stays as the safety net for other
  SwiftUI paths.
