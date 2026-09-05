# 023 — Shelf Mode: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-04-21 | Shelf shipped: books/spines/open-book layout, spine-flow animation, ⌘-held hotkey glyphs, notification tint + header dot, new configurable shortcuts (⌘⇧↩, ⌘⌃→/←, ⌃⌥1..9). Late in the branch, close-last-tab was reversed to retire the book (`795776e9`) | PR #230 |
| 2026-04-22 | Spine context menu "Remove Book" replaced by kind-aware "Close Worktree" / "Close Folder" reusing the close-last-tab pipeline; plain-folder close paths covered by tests (`662e6b4d`) | PR #232 |
| 2026-04-28 | Per-button tooltips on spine bottom controls (`New Tab (⌘T)` style via `GhosttyShortcutManager`); book-level `.help` moved to the header so it stopped masking every control below | PR #244 |
| 2026-04-29 | Book-switch performance wave: bare-⌘/⌃ shortcut-hint mode, sidebar key forwarding disabled in Shelf, single-`ForEach` spine layout (drops `matchedGeometryEffect`), open-book opacity transition removed, permanent signposts. See [002-book-switch-jank.md](002-book-switch-jank.md) | PR #246 |
| 2026-04-29 | Sidebar type-through key forwarding removed entirely (replaced by refocusing the terminal on selection), superseding #246's Shelf-only gate | commit `9030147d` |
| 2026-05-09 | Cmd-W ownership held on the terminal layer through a book switch: new `shelfHasOpenBooks` signal into `WindowCloseShortcutPolicy` so auto-repeated ⌘W chewing through tabs across book boundaries no longer closes the window in the one-frame gap where no close target exists | PR #272 |
| 2026-05-09 | ⌘-held `⌘N` glyphs, dim-on-⌘ for slots 10+, and the glyph/close-button trade-off scoped to the **open** book's spine only — closed books stop advertising hotkeys they can't service | PR #273 |
| 2026-05-27 | Shelf spine tint preferences: Neutral / System Tint fallback + "Follow Repo Color" toggle (default preserves prior behavior: neutral fallback, follow enabled) | PR #356 |
| 2026-06-10 | Agent status badges on spines + two-finger trackpad book switching (community `[codex]` PR); review pass restored wrap-around navigation and resynced detection on repository-list changes. See [003-agent-status-and-trackpad.md](003-agent-status-and-trackpad.md) | PRs #432, #434 |

## Outcome & current state (as of 2026-07-12)

Verified against the working tree:

- **Views/model**: `supacode/Features/Shelf/` — `Models/ShelfBook.swift`,
  `Views/ShelfView.swift` (also hosts `ShelfSwipeEventMonitor` for trackpad switching),
  `Views/ShelfSpineView.swift` (contains `ShelfSpineTabSlot`, `ShelfMetrics`, and the
  agent-status marker), `Views/ShelfOpenBookView.swift`, `Views/ShelfSidebarButton.swift`.
- **State/reducer**: `isShelfActive` and `openedWorktreeIDs` on
  `supacode/Features/Repositories/Reducer/RepositoriesFeature.swift`; `toggleShelf`,
  `selectNext/PreviousShelfBook`, `selectShelfBook(Int)`, `markWorktreeOpened/Closed` in
  `RepositoriesFeature+CoreReducer.swift`; `orderedShelfBooks()`, `shelfBook(atOffset:)`,
  and `replacementBookAfterClosing` in `RepositoriesFeature+Selection.swift`.
- **Close pipeline**: `tabClosed(worktreeID:remainingTabs:)` handled in
  `supacode/Features/App/Reducer/AppFeature+TerminalEvents.swift`, dispatching
  `markWorktreeClosed` at `remainingTabs == 0`. Auto-advance picks the neighbor *after*
  the closed book, else the one before (a refinement over the plan's "next remaining
  book").
- **Shortcuts**: command IDs (`toggle_shelf`, `select_next_shelf_book`, …,
  `select_shelf_book_1..9`) in `supacode/App/AppShortcuts.swift`; menu plumbing in
  `supacode/Commands/SidebarCommands.swift`; `⌘⌃→/←` are now dual-purpose — when Canvas is
  showing, `selectNext/PreviousShelfBook` reroutes to Canvas spatial navigation
  (`requestCanvasCommand(.navigate(...))`, from entry 024's spatial-navigation work).
- **Cmd-W policy**: `shelfHasOpenBooks` threaded through `WindowCloseShortcutPolicy` in
  `supacode/Commands/WindowCommands.swift`.
- **Tint settings**: `shelfSpineTintFallback` / `shelfSpineTintFollowsRepositoryColor` in
  `supacode/Features/Settings/Models/GlobalSettings.swift`, backed by
  `supacode/Features/Settings/Models/ShelfSpineTintFallback.swift`.
- **Agent status**: `showActiveAgentStatusInShelf` setting; the status values come from
  the detection subsystem (entry 030). Its former 3-second Working hold was retired by
  [030.015](../030-agent-status-detection/015-deterministic-live-footer-coverage.md).
- **Jank-fix survivors**: `CommandKeyObserver.shouldShowShortcuts(for:)` in
  `supacode/App/CommandKeyObserver.swift` still gates hint mode to bare ⌘/⌃; the
  single-`ForEach` layout is current. The "sidebar `.onKeyPress` disabled while Shelf is
  active" fix from #246 no longer exists as such — the type-through forwarding was removed
  wholesale by `9030147d`, so there is nothing left to gate.
- **Tests**: `supacodeTests/ShelfFeatureTests.swift`,
  `supacodeTests/ShelfBookOrderingTests.swift`, plus `WindowCloseShortcutPolicyTests`
  coverage for the ⌘W hold.
- **Behavior docs**: `docs/components/shelf.md`, `docs/components/view-modes.md`.

## Deviations from plan

- Multi-binding aliasing for ⌘⌃→/← was dropped in favor of dedicated Shelf-book commands
  (recorded as a decision in [000-plan.md](000-plan.md)).
- Close-last-tab keeps-empty-book behavior was reversed to retire-the-book before #230
  merged; the PR's own test-plan text still describes the older behavior.
- The `matchedGeometryEffect` left/right spine-stack layout shipped in #230 was replaced
  a week later by a single-`ForEach` layout for performance (#246).
- #432 accidentally replaced the long-standing keyboard wrap-around for book navigation
  with bounded edges; #434 restored the wrap for both keyboard and the new swipe gesture.

## Open questions

- PR #230's merged description advertises `.transition(.opacity)` for the open-book
  crossfade and the two-stack `matchedGeometryEffect` layout; both were removed in #246.
  Anyone reading the PR as a design reference should prefer this entry +
  [jank-investigation.md](jank-investigation.md).
