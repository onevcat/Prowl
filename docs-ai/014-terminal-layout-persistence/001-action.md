# 014 — Terminal Layout Persistence: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-03-27 | Font-size override persisted as `GlobalSettings.terminalFontSize`; synced from cell-size callbacks, normalized against the Ghostty default, injected at boot | PR #77 |
| 2026-03-27 | Cmd+0 reset propagated via `GHOSTTY_ACTION_CONFIG_CHANGE` → `onConfigChange` bridge callback so new tabs pick up the cleared override | PR #81 |
| 2026-03-31 | Phase A: cache moved to App Support (+ legacy migration), `PathPolicy`, `snapshotPersistencePhase` write guard, snapshot fuses, `restoreTerminalLayoutOnLaunch` toggle + clear action | PR #112 |
| 2026-04-01 | Phase B: `TerminalLayoutSnapshotPayload`, persistence client I/O, `WorktreeTerminalManager` save/restore orchestration, tab/split tree reconstruction, `AppFeature` lifecycle hooks | PR #113 |
| 2026-04-01 | Umbrella merge to main: both phases + `LaunchRestoreMode`, terminate-time save, Advanced Settings toggle (~700 lines of tests) | PR #116 (closes #76) |
| 2026-04-01 | Plain folders restore via `selectRepository`; "Clear saved terminal layout" gates re-saving through `suppressLayoutSaveUntilRelaunch` | PR #120 → [010-plain-folder-support](../010-plain-folder-support/000-plan.md) |
| 2026-04-01 | Font-size stability across worktree switches: surfaces marked `font_size_adjusted` (via `increase_font_size:0`) so keybind-config reloads don't reset fonts; Cmd+0 freed for `reset_font_size` by dropping tab-0/worktree-0 shortcuts | PR #121 |
| 2026-04-01 | Restore no longer skipped when the boot snapshot matches disk state: `repositoriesLoaded` always emits `repositoriesChanged` on the `.restoring` → `.active` transition | PR #122 |
| 2026-04-02 | Safeguards from #123: restored split ratio clamped to `[0.1, 0.9]`; `layoutRestoreFailed` event → warning toast when a snapshot is reset | PR #125 |
| 2026-04-08 | Tab title and icon persisted in the snapshot (optional fields, backward-compatible decode) | PR #186 → [022-tab-title-and-icon](../022-tab-title-and-icon/000-plan.md) |
| 2026-06-01 | Default View launch race + restoration hang fix | PR #380 — see [002-launch-restore-races.md](002-launch-restore-races.md) |
| 2026-06-16 | scenePhase-save-clears-snapshot launch race fix | PR #459 — see [002-launch-restore-races.md](002-launch-restore-races.md) |
| 2026-11-01 | Promoted: default on, also once for existing settings files, no "experimental" label, toggle moved to General. A missing worktree no longer resets the layout; a restore without a selection falls back to the last focused worktree | #573 |

## Outcome & current state (as of 2026-07-12)

- `supacode/Features/Terminal/Models/TerminalLayoutSnapshotPayload.swift` —
  `currentVersion = 2`; fuses `maxWorktrees = 128`, `maxSplitNodesPerTab = 1024`,
  `maxSplitDepth = 24`; `SnapshotWorktree` → `SnapshotTab` (`title`, `customTitle`,
  `icon`) → recursive `SnapshotSplitNode`. The v1→v2 migration promotes a v1 `title` to
  `customTitle` — v2 arrived with persistent custom tab titles
  ([022-tab-title-and-icon](../022-tab-title-and-icon/000-plan.md)), which split the live
  shell title from the user override that #186 had stored in one field.
- `supacode/Clients/Terminal/TerminalLayoutPersistenceClient.swift` — load/save/clear
  with `maxSnapshotFileBytes` and validity checks; invalid snapshots are deleted.
- `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift` —
  `persistLayoutSnapshot()` (async, from the `.saveLayoutSnapshot` command) and
  `persistLayoutSnapshotSync()` (from `applicationWillTerminate` in
  `supacode/App/supacodeApp.swift`); `restoreLayoutSnapshot` emits `.layoutRestored` /
  `.layoutRestoreFailed` terminal events and clears the snapshot on failure.
- `supacode/Features/Terminal/Models/WorktreeTerminalState+LayoutSnapshot.swift` —
  per-worktree serialization and tab/split-tree reconstruction; restored split ratios
  are clamped to `[0.1, 0.9]` (#125).
- `supacode/Features/App/Models/LaunchRestoreMode.swift` — gained a third case,
  `cliOpenPath(String)`, for `prowl open` cold launches
  ([013-prowl-cli](../013-prowl-cli/000-plan.md)), beyond the two planned modes.
- `supacode/Features/App/Reducer/AppFeature.swift` — `launchRestoreMode` is derived from
  the setting at init and consumed once on `repositoriesChanged`; the
  inactive/background save is gated on the setting, `suppressLayoutSaveUntilRelaunch`,
  and `launchRestoreMode != .restoreLayout` (#459).
- `supacode/Support/PathPolicy.swift`, `supacode/Support/SupacodePaths.swift` — path
  policy and the App Support cache location
  (`…/com.onevcat.prowl/cache/terminal-layout-snapshot.json`) with legacy `~/.prowl`
  migration.
- `supacode/Features/Settings/Models/GlobalSettings.swift` —
  `restoreTerminalLayoutOnLaunch` (still default `false`) and `terminalFontSize`;
  the toggle + clear button live in
  `supacode/Features/Settings/Views/AdvancedSettingsView.swift`, still labeled
  "(experimental)".
- Font size: `WorktreeTerminalManager.preferredFontSize` feeds new surfaces;
  `supacode/Features/Terminal/Models/WorktreeTerminalState+Surfaces.swift` still sends
  `increase_font_size:0` after creating an overridden surface so config reloads keep it
  (#121).

User-facing behavior is documented in `docs/components/terminal.md` ("Layout
persistence"), `docs/components/settings.md` (Advanced pane), and
`docs/reference/settings-fields.md`.

## Deviations from plan

- Phase A's repository-snapshot fuses and `PathPolicy` outgrew this feature: they now
  guard the startup cache and worktree cleanup generally, not just layout restore.
- `LaunchRestoreMode` acquired the unplanned `cliOpenPath` case when the `prowl` CLI
  needed to suppress worktree restoration on cold `prowl open` launches.
- The snapshot format needed a version bump (v2) once tab identity work separated live
  titles from user overrides — #186's single-`title` design turned out to be lossy.
- The launch sequencing around restore proved fragile well after the feature stabilized;
  two races surfaced months later (see
  [002-launch-restore-races.md](002-launch-restore-races.md)).

## Promotion decision (2026-11-01, #573)

Live checks found two blockers for default-on, both fixed in the promotion change:

- One saved worktree that was removed outside Prowl dropped the whole layout, with an
  "invalid" warning. The snapshot itself is valid, so missing worktrees are now always skipped.
  Only a structurally invalid snapshot fails closed.
- `repositoriesChanged` clears the selection before restore, and `.layoutRestored(nil)` selected
  nothing. A launch with no saved tabs opened with an empty detail view. It now uses the same
  fallback as the default view.

Existing settings files store `false` for anyone who kept the old default, because every field
is encoded on save. onevcat chose to turn the feature on for them too, and accepted that this
also overrides an explicit off once. The stored key changed from `restoreTerminalLayoutOnLaunch`
to `restoreTerminalLayout`, so no migration state is needed: the old key is ignored, and a later
off stays off. The property keeps its name.
