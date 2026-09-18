# 069 — Undo Close Terminal: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-09-16 |
| **Primary PRs** | #814, #816 |
| **Related** | [035-protected-terminal-close](../035-protected-terminal-close/000-plan.md), [009-terminal-surface-lifecycle](../009-terminal-surface-lifecycle/000-plan.md), [012-keybinding-system](../012-keybinding-system/000-plan.md), [014-terminal-layout-persistence](../014-terminal-layout-persistence/000-plan.md), [027-split-pane-ux](../027-split-pane-ux/000-plan.md), `docs/reference/keyboard-shortcuts.md`, `docs/components/terminal.md`, `docs/components/cli.md` |

## Background

Closing a pane or tab is irreversible today. `WorktreeTerminalState+Surfaces.swift`
`closeSurface(_:confirmation:)` calls `view.closeSurface()`, which frees the
`ghostty_surface_t` synchronously; the pty and its child process are gone before the
view leaves the hierarchy. The only safety net is the confirmation gate from
[035](../035-protected-terminal-close/000-plan.md) (agent active, unseen result,
long-running command) and #766 (recent input). A gate helps when the pane is
protected, but the common accident is different: ⌘W on an idle pane, or Enter on the
alert by muscle memory, followed by immediate regret. The macOS reflex for regret is
⌘Z, and in Prowl it does nothing.

Ghostty.app has had this feature since 1.2: `undo` / `redo` keybind actions (default
`super+z`, `super+shift+z`, and `super+shift+t` for undo, all `performable`) and an
`undo-timeout` setting (default 5 s). Its implementation lives in the macOS Swift layer
(`macos/Sources/Helpers/ExpiringUndoManager.swift`, `BaseTerminalController.replaceSurfaceTree`,
`TerminalController.closeTabImmediately`), not in libghostty, so Prowl only receives
the action tags. What libghostty does give Prowl for free: the default bindings and
any user rebinding, the `GHOSTTY_ACTION_UNDO` / `GHOSTTY_ACTION_REDO` callbacks, and
the parsed `undo-timeout` value.

Today `GhosttySurfaceBridge.handleAppAction` answers both actions with
`NSApp.sendAction(#selector(UndoManager.undo), to: nil, from: nil)` and returns
`true`. Nothing in the responder chain handles it, so ⌘Z is swallowed: it neither
undoes anything nor reaches the terminal program.

## Goals

- Closing a pane or a tab keeps its surface alive, off-tree and not rendering, for a
  grace window. ⌘Z restores it into its original tab and split position with the
  process, scrollback, and focus intact, as if the close never happened.
- ⌘⇧Z re-closes the restored terminal without a confirmation prompt (Ghostty parity).
- Batch closes (Close Other Tabs / Tabs to the Right / All Tabs) form one undo group.
- The grace window is Ghostty's `undo-timeout` (default 5 s; `0` disables the feature).
  Each close has its own timer; a later close does not extend an earlier one.
- When there is nothing to undo, ⌘Z falls through to the terminal program (fixes the
  current swallow).
- Observers keep a simple contract: CLI, workflows, and Active Agents see the close when
  it happens; a restore looks like a newly adopted pane with a fresh short handle.

**Non-goals**

- Undo for creating tabs or splits (Ghostty does this; see decisions below).
- Undo for closes driven by worktree removal (`prune`), layout restore
  (`closeAllSurfaces`), auto-close on success, run-script replacement, agent-profile
  rollback, remote-mirror replicas, or a surface whose process already exited.
- Surviving app restart, or any Prowl-side setting for the timeout.
- ~~Undo while no terminal surface has keyboard focus.~~ Delivered as a follow-up
  through a window-level key monitor; see [002-empty-worktree-undo.md](002-empty-worktree-undo.md).

## Design / Approach

Port Ghostty's mechanism, not its classes: retain the closed view in an expiring entry,
restore by putting the captured tree back, free on expiry.

**1. `TerminalCloseUndoStack`** (new, `supacode/Features/Terminal/Models/`), one
instance owned by `WorktreeTerminalManager` (app-wide, temporal LIFO). Entry kinds:

| Entry | Captured before removal |
| --- | --- |
| `pane` | worktree id, tab id, the `GhosttySurfaceView`, the pre-close `SplitTree<GhosttySurfaceView>`, whether it was focused |
| `tab` | worktree id, `TerminalTabItem`, array index, whether selected, the tree, `focusedSurfaceIdByTab` entry, run-script flag, bound-directory key |
| `group` | ordered `tab` entries from one batch close |

Expiry uses an injected `any Clock<Duration>` (same pattern as
`TerminalTabManager.titleFlushClock`) with one `Task` per entry, so tests drive it with
`TestClock`. This is Ghostty's `ExpiringUndoManager` shape with its `Timer` replaced;
`UndoManager` itself is not used (see decisions).

**2. Detach instead of free.** In `WorktreeTerminalState+Surfaces.swift`
`closeSurface(_:confirmation:)` and `removeTree(for:)`, and in
`WorktreeTerminalState.closeTab(_:confirmation:)`, `view.closeSurface()` is replaced by a
detach step when the timeout is positive and the process is alive:

- `forgetSurface` still runs, so `onSurfaceClosed`, `AgentObservationStore`,
  `AgentDispatchStore`, notification pruning, and handle unregistration behave as today.
- The view is marked not visible through `setOcclusion(_:)` (the pause path applies
  immediately without a hierarchy, #198), loses surface focus, and gets its bridge
  callbacks replaced by a pending handler whose only job is `onCloseRequest`.
- The SwiftUI diff on `.id(node.structuralIdentity)` drops the host; the view survives
  because the entry retains it. `GhosttySurfaceView.handleAttachmentChange` asks the
  old scroll wrapper to re-adopt an orphaned view, so detach must clear that wrapper
  link (or gate `ensureSurfaceAttached` on a pending flag) to avoid re-hosting into a
  dying wrapper.
- Every other close path keeps calling `view.closeSurface()` unchanged.

**3. Restore** (`WorktreeTerminalState`, new `restore(_ entry:)`), mirroring the
adoption steps of the private `createTab(_ creation: TabCreation)`:

- Tab: `tabManager.insertTab(_:at:)` (new API; index clamped), `trees[tabID] = tree`,
  then per leaf `configureBridgeCallbacks`, `configureSurfaceCallbacks`,
  `surfaces[id] = view`, `registerTargetHandle`, `wakeAgentDetection`;
  `tabIsRunningById`, `updateRunningState`, `focusSurface`, and `onTabCreated?()`.
  `tabCreated` already maps to `markWorktreeOpened`, so restoring the last tab of a
  worktree re-opens it without new reducer work. The manager re-selects the worktree
  first when the entry belongs to a different one.
- Pane: `trees[tabID] = previousTree` (Ghostty's `oldTree` approach: direction and ratio
  come back for free), the same per-leaf adoption for the restored view, focus if it
  was focused.
- Handles are re-registered, so the restored pane gets a new short handle; the CLI
  contract "handles are never reused after a close" stays true.

**4. Entry points.** `GhosttySurfaceBridge.handleAppAction` routes `GHOSTTY_ACTION_UNDO`
/ `REDO` to new `onUndo` / `onRedo` closures wired to the manager's stack and returns
the stack's answer. `false` lets Ghostty's `performable` binding fall through to the
pty. Redo re-runs the close with `.skip` confirmation and registers a fresh undo entry.

**5. Timeout.** `GhosttyRuntime.undoTimeout()` reads `undo-timeout` with
`ghostty_config_get` (UInt milliseconds, as `Ghostty.Config.undoTimeout` does upstream),
following the `focusFollowsMouse()` accessor pattern.

**6. Invalidation.** A pane entry for tab T is dropped (surfaces freed) when T's tree
changes structurally through a non-undo operation (new split, drag-move) or T is
closed by an excluded path. Tab and pane entries for a worktree are dropped when
`WorktreeTerminalManager.prune` removes its state. A process exit during the grace
window arrives on the pending `onCloseRequest`, frees that surface, and removes it
from its entry (a group keeps its remaining tabs).

**7. Confirmation.** The [035](../035-protected-terminal-close/000-plan.md) / #766
gate is unchanged. It protects work the user cannot see; undo covers the five seconds
after a close they did see. Revisit relaxing #766 after dogfooding.

## Alternatives & decisions

- **Reopen with the same cwd** (layout-restore style) — rejected. Loses the process
  and scrollback; the requirement is "as if nothing happened".
- **Freeze observers until the surface is freed** — rejected. `prowl agents wait` and
  workflow observers would hang for the grace window, and Active Agents / `prowl list`
  would show ghosts. Ghostty also treats a close as a close for everything but the view.
- **One stack per worktree** — rejected. Closing the last tab moves focus to a
  neighbouring worktree, so ⌘Z would hit the wrong stack. A single temporal LIFO
  matches "undo what I just did".
- **Use `ExpiringUndoManager` verbatim** — rejected. Its `Timer` conflicts with the
  project rule that tests drive time with `TestClock`, and v1 has no responder-chain
  consumer (Prowl replaces no `.undoRedo` command group). The structure is ported.
- **Register undo for new tab / new split** (Ghostty parity, keeps the stack
  consistent) — rejected. Agents and the CLI create panes constantly; ⌘Z closing a
  freshly created pane would be a worse surprise than the invalidation rule.
- **A Prowl setting for the timeout** — deferred. libghostty already parses
  `undo-timeout`; docs point users there. A settings row can come later without
  changing the model.

## Verification plan

- Unit: new `TerminalCloseUndoStackTests` (expiry per entry, LIFO, group, invalidation)
  with `TestClock`; `WorktreeTerminalManagerTests` cases for pane restore position and
  ratio, tab restore index and selection, last-tab restore emitting `tabCreated`, new
  handle after restore, process exit during grace, timeout `0`; `GhosttySurfaceBridgeTests`
  for the `false` fall-through when the stack is empty.
- Debug run: ⌘W then ⌘Z on a split, a tab, a batch close, and the last tab of a
  worktree; ⌘⇧Z; wait past the timeout; exit the shell during the grace window;
  confirm the restored pane keeps scrollback and a running agent.
- `make check`, `make build-app`, `make test`.

## Amendments

- Updated 2026-09-17: ⌘Z reaches the close stack when no terminal has focus, so the last tab of a worktree is undoable — see [002-empty-worktree-undo.md](002-empty-worktree-undo.md)
