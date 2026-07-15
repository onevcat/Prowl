# Reference: Settings Fields

> Every settings field with its exact name, type, default, and effect — useful for
> reading or writing the JSON directly. Source of truth:
> `supacode/Features/Settings/Models/GlobalSettings.swift` and `RepositorySettings.swift`.

**Keywords:** settings fields, global settings, repository settings, defaults, settings.json, prowl.json, config, json schema

For the UI grouping of these into tabs, see [`components/settings.md`](../components/settings.md).

## On-disk locations

| Scope | Path |
|-------|------|
| Global settings | `~/.prowl/settings.json` |
| Per-repository settings | `~/.prowl/repo/<repo-name>/prowl.json` |
| Per-repository custom commands | `~/.prowl/repo/<repo-name>/prowl.onevcat.json` |

JSON is pretty-printed with sorted keys. Legacy `~/.supacode` is migrated to
`~/.prowl` on first launch.

## Global settings (`GlobalSettings`)

| Field | Type | Default | Effect |
|-------|------|---------|--------|
| `appearanceMode` | enum (`system`/`light`/`dark`) | `dark` | App appearance. |
| `defaultEditorID` | String | `auto` | Default app to open worktrees (overridable per repo); `auto` prefers an app matching the detected project type. |
| `confirmBeforeQuit` | Bool | `true` | Confirm before quitting Prowl. |
| `updatesAutomaticallyCheckForUpdates` | Bool | `true` | Background update checks. |
| `updatesAutomaticallyDownloadUpdates` | Bool | `false` | Auto-download updates. |
| `inAppNotificationsEnabled` | Bool | `true` | In-app alerts / bell indicators. |
| `notificationSound` | enum (`never` / system sound raw values like `hero` / `supacodeClassic`) | `supacodeClassic` | Sound played for notifications when system banners are off; `never` disables it. Migrates the legacy `notificationSoundEnabled` Bool (`true` → `supacodeClassic`, `false` → `never`); unknown raw values fall back to the default. |
| `systemNotificationsEnabled` | Bool | `false` | macOS system banners. |
| `muteNotificationsForActiveSurface` | Bool | `true` | Suppress the banner, sound, and dock bounce when the notification's pane is the one you're actively viewing (selected worktree, focused pane, key + visible window). |
| `moveNotifiedWorktreeToTop` | Bool | `true` | Float a notified worktree to top. |
| `commandFinishedNotificationEnabled` | Bool | `true` | Notify when a long command finishes. |
| `commandFinishedNotificationThreshold` | Int (seconds) | `10` | Minimum duration before that notification fires. |
| `analyticsEnabled` | Bool | `true` | Send usage analytics (PostHog; off in Debug). |
| `crashReportsEnabled` | Bool | `true` | Send crash reports (Sentry). |
| `githubIntegrationEnabled` | Bool | `true` | Enable GitHub/PR features (via `gh`). |
| `deleteBranchOnAutomaticWorktreeCleanup` | Bool | `false` | Delete local branches when Prowl automatically cleans up its merged or expired worktrees. |
| `mergedWorktreeAction` | enum? | `nil` | What to do with a merged worktree (e.g. auto-archive); `nil` = ask. |
| `promptForWorktreeCreation` | Bool | `true` | Show the creation dialog vs. auto-create. |
| `fetchOriginBeforeWorktreeCreation` | Bool | `true` | `git fetch` before creating a worktree. |
| `defaultWorktreeBaseDirectoryPath` | String? | `nil` | Default parent directory for new worktrees. |
| `copyIgnoredOnWorktreeCreate` | Bool | `false` | Copy `.gitignore`'d files into new worktrees. |
| `copyUntrackedOnWorktreeCreate` | Bool | `false` | Copy untracked files into new worktrees. |
| `pullRequestMergeStrategy` | enum (`merge`/`squash`/`rebase`) | `merge` | Default PR merge strategy. |
| `restoreTerminalLayoutOnLaunch` | Bool | `false` | Restore tabs/splits on launch. |
| `terminalFontSize` | Float32? | `nil` | Remembered terminal font size. |
| `archivedAutoDeletePeriod` | enum? (days) | `nil` | Auto-delete archived worktrees after N days; `nil` = never. |
| `keybindingUserOverrides` | object | empty | User keyboard-shortcut remappings. |
| `defaultViewMode` | enum (`normal`/`shelf`/`canvas`) | `normal` | View mode on launch. |
| `canvasDefaultLayout` | enum (`uniform`/`tile`) | `tile` | Initial Canvas layout: `uniform` packs same-size cards, `tile` resizes cards to fill the screen. |
| `dimUnfocusedSplits` | Bool | `true` | Dim panes that aren't focused. |
| `autoShowActiveAgentsPanel` | Bool | `false` | Auto-open the Active Agents panel on a new agent. |
| `showActiveAgentTabTitles` | Bool | `false` | Show pane titles (surface title, falling back to the tab title; vs. branch) in the agents panel. |
| `showActiveAgentStatusInShelf` | Bool | `true` | Show agent status markers on Shelf tab icons. |
| `windowTintMode` | enum (`none`/`repositoryColor`/`custom`) | `repositoryColor` | How the window chrome is tinted. |
| `windowTintCustomColor` | color | default | The custom tint color (when `windowTintMode = custom`). |
| `showRunButtonInToolbar` | Bool | `true` | Show the Run Script button in the toolbar. |
| `showDefaultEditorInToolbar` | Bool | `true` | Show the open-in-editor button in the toolbar. |
| `dockBounceMode` | enum (`off`/`once`/`continuous`) | `off` | Dock bounce on notification. |
| `showNotificationDotOnDock` | Bool | `false` | Numeric unread badge on the Dock icon. |
| `shelfSpineTintFallback` | enum (`neutral`/`systemTint`) | `neutral` | Shelf spine color when a repo has no color. |
| `shelfSpineTintFollowsRepositoryColor` | Bool | `true` | Tint shelf spines by repo color. |
| `externalDiffToolID` | String | `built-in` | Tool used by diff badges and Show Diff: `built-in`, `hunk`, `filemerge`, `kaleidoscope`, or `custom`. |
| `externalDiffCustomCommand` | String | `""` | Command template for `externalDiffToolID = custom`; supports `{leftPath}`, `{rightPath}`, `{worktreePath}`, `{repoPath}`, and `{branch}`. |

## Per-repository settings (`RepositorySettings`)

Stored at `~/.prowl/repo/<repo-name>/prowl.json` (schema v2). For the tri-state
`Bool?` fields, `nil` means "inherit the global setting."

| Field | Type | Default | Effect |
|-------|------|---------|--------|
| `setupScript` | String | `""` | Script run automatically after a worktree is created. |
| `archiveScript` | String | `""` | Script run automatically before a worktree is archived. |
| `runScript` | String | `""` | The on-demand Run Script (`⌘R`). |
| `openActionID` | String | `auto` | App to open this repo's worktrees (overrides `defaultEditorID`); `auto` prefers an app matching the detected project type. |
| `worktreeBaseRef` | String? | `nil` | Default base branch/ref for new worktrees. |
| `worktreeBaseDirectoryPath` | String? | `nil` | Parent directory for new worktrees (overrides global). |
| `copyIgnoredOnWorktreeCreate` | Bool? | `nil` | Copy ignored files; `nil` = use global. |
| `copyUntrackedOnWorktreeCreate` | Bool? | `nil` | Copy untracked files; `nil` = use global. |
| `pullRequestMergeStrategy` | enum? | `nil` | PR merge strategy; `nil` = use global. |
| `githubAccountOverride` | object? | `nil` | Optional `{ "host": "...", "login": "..." }`; Prowl temporarily switches `gh` to this account for GitHub operations in this repo. |
| `customTitle` | String? | `nil` | Display name override for the repository. |
| `observeLineDiffsAutomatically` | Bool? | `nil` (= on) | Keep worktree line-change badges updated; set `false` for large repos. |
| `fetchPullRequestState` | Bool? | `nil` (= on) | Background-fetch PR state; set `false` to save GitHub rate limit. |

**Custom Commands** (per-repo buttons/hotkeys) live separately in
`prowl.onevcat.json`. See [`components/custom-actions.md`](../components/custom-actions.md)
for their structure (title, icon, command, execution mode, close-on-success,
shortcut).

## Notes for agents

- Defaults here are the **factory** values; a human's file may differ.
- Tri-state `Bool?` per-repo fields: `nil`/absent = inherit global; `true`/`false`
  = explicit override.
- Editing the JSON while Prowl is running may be overwritten on save — prefer the
  Settings UI, or change settings while the app is closed.
