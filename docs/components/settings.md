# Settings

> The Settings window (`⌘,`): what each tab controls. For the exhaustive
> field-by-field list, see [`reference/settings-fields.md`](../reference/settings-fields.md).

**Keywords:** settings, preferences, ⌘comma, general, notifications, shortcuts, worktree, updates, advanced, github, telegram, repo settings, appearance

**Related:** [reference/settings-fields](../reference/settings-fields.md) · [custom-actions](custom-actions.md) · [updates](updates.md) · [notifications](notifications.md)

## Opening

`⌘,` (`open_settings`), the app menu, or Command Palette → "Open Settings". The
window is a sidebar of tabs plus a detail pane.

## Tabs

| Tab | Controls |
|-----|----------|
| **General** | Appearance (system/light/dark), default app for opening worktrees, diff tool, confirm-before-quit, default view mode, window chrome tint, toolbar buttons (Run / Open-in-editor), dim unfocused splits, Active Agents panel auto-show & tab titles. |
| **Notifications** | In-app alerts, sound, macOS system notifications, move-notified-to-top, command-finished notification + threshold, Dock badge & bounce. → [notifications](notifications.md) |
| **Shortcuts** | Remap app keyboard shortcuts; view defaults; resolve conflicts. → [keyboard-shortcuts](../reference/keyboard-shortcuts.md) |
| **Worktree** | Worktree creation/deletion defaults: prompt on create, fetch before create, base directory, copy ignored/untracked files, delete-branch-on-delete, merged-worktree action, archived auto-delete period. |
| **Updates** | Update channel (Stable/Tip), auto-check toggle, "Check for Updates Now". → [updates](updates.md) |
| **Advanced** | Analytics, crash reports, restore terminal layout on launch (experimental) + clear saved layout, and the **Install Command Line Tool** (`prowl` CLI) action. |
| **GitHub** | Enable GitHub integration (uses the `gh` CLI). → [github-pull-requests](github-pull-requests.md) |
| **Telegram** | Enable the built-in Telegram bot, store the Bot API token, allowlist Telegram user IDs, test `getMe`, and tune default `/read` output. The bot routes to the same command handlers as the [`prowl` CLI](cli.md). |
| **Repositories / Repo Settings** | Per-repository: setup/archive/run scripts, **Custom Commands**, default base ref & directory, copy-files overrides, open-with app, custom title, icon & color, PR merge strategy, line-diff & PR-state fetching. Reached from the sidebar context menu → "Repo Settings". → [custom-actions](custom-actions.md), [repositories-and-worktrees](repositories-and-worktrees.md) |

## Where settings live on disk

- **Global:** `~/.prowl/settings.json`
- **Per-repo:** `~/.prowl/repo/<repo-name>/prowl.json`
- **Per-repo custom commands:** `~/.prowl/repo/<repo-name>/prowl.onevcat.json`

Legacy `~/.supacode` is migrated to `~/.prowl` on first launch.

## Telegram bot

Settings → Telegram controls the optional Bot API integration:

- Enable/disable starts or stops the long-polling runtime.
- Bot token is stored in `~/.prowl/settings.json`; logs never include it.
- Allowed user IDs are a comma/space/newline-separated allowlist. Messages from
  any other Telegram user are ignored.
- Default read lines controls `/read <pane-id>` when the message omits a count.
- `/send` and `/key` use explicit pane IDs by default; disabling the explicit
  target toggle lets them use the current Prowl focus. `/pane_close` and
  `/tab_close` always require explicit IDs.

The Test Connection button calls Telegram `getMe` with the configured token and
shows the bot identity or a short error.

## Install the CLI from here

**Advanced → Install Command Line Tool** symlinks `prowl` into `/usr/local/bin`
(prompting for admin rights if needed). Also available via Command Palette →
"Install Command Line Tool". See [cli](cli.md).

## Gotchas for agents

- Many behaviors are **global with a per-repo override** (copy-files, base
  directory, PR merge strategy, open-with app). A per-repo value of "default"/nil
  means "use the global setting."
- For exact field names, types, and defaults (useful when reading/writing the JSON
  directly), use [`reference/settings-fields.md`](../reference/settings-fields.md).
