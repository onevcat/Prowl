# Settings

> The Settings window (`⌘,`): what each tab controls. For the exhaustive
> field-by-field list, see [`reference/settings-fields.md`](../reference/settings-fields.md).

**Keywords:** settings, preferences, ⌘comma, general, notifications, shortcuts, worktree, updates, advanced, github, repo settings, appearance

**Related:** [reference/settings-fields](../reference/settings-fields.md) · [custom-actions](custom-actions.md) · [updates](updates.md) · [notifications](notifications.md)

## Opening

`⌘,` (`open_settings`), the app menu, or Command Palette → "Open Settings". The
window is a native macOS split window: the sidebar selects top-level sections,
and its toolbar's sidebar control can hide or show that sidebar. Re-opening
Settings brings the existing Settings window forward rather than creating
another one. `⌘W` closes it.

Most sections are roots in the detail pane. A section can drill in without
losing the sidebar; for example, **Agents** → a profile pushes its editor and
macOS shows the standard Back control beside the editor title. Back returns to
the Agents list, while selecting another sidebar item leaves the drill-in and
opens that section's root.

## Sections

| Section                          | Controls                                                                                                                                                                                                                                                                                                                                                                                                                           |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **General**                      | Appearance (system/light/dark), sidebar text size (Default / Medium / Large / Extra Large — scales the repository sidebar and Active Agents panel), default app for opening worktrees, diff tool, confirm-before-quit, default view mode, window chrome tint, automatic repository icon detection, toolbar buttons (Run / Open-in-editor), dim unfocused splits, Active Agents panel auto-show & terminal titles.                  |
| **Notifications**                | In-app alerts, notification sound picker (Never / system sounds / Prowl Classic), macOS system notifications, move-notified-to-top, command-finished notification + threshold, Dock badge & bounce. → [notifications](notifications.md)                                                                                                                                                                                            |
| **Shortcuts**                    | Remap app keyboard shortcuts; view defaults; resolve conflicts. → [keyboard-shortcuts](../reference/keyboard-shortcuts.md)                                                                                                                                                                                                                                                                                                         |
| **Worktree**                     | Worktree creation/deletion defaults: prompt on create, fetch before create, base directory, copy ignored/untracked files, automatic local-branch cleanup, merged-worktree action, archived auto-delete period.                                                                                                                                                                                                                     |
| **Updates**                      | Auto-check toggle, "Check for Updates Now". → [updates](updates.md)                                                                                                                                                                                                                                                                                                                                                                |
| **Advanced**                     | Analytics, crash reports, restore terminal layout on launch (experimental) + clear saved layout, and the **Install Command Line Tool** (`prowl` CLI) action.                                                                                                                                                                                                                                                                       |
| **GitHub**                       | Enable GitHub integration (uses the `gh` CLI). → [github-pull-requests](github-pull-requests.md)                                                                                                                                                                                                                                                                                                                                   |
| **Commands**                     | Global Custom Commands. Enabled commands appear in the window toolbar; each repo can independently hide a Global command. → [custom-actions](custom-actions.md)                                                                                                                                                                                                                                                                    |
| **Agents**                       | Agent Profiles: named launch presets for Claude Code/Codex (model, effort, execution mode, tab/split placement, extra arguments, opt-in dedicated home for a separate account) with a live launch preview. List order is the recommendation fallback. → [agent-profiles](agent-profiles.md)                                                                                                                                        |
| **Repositories / Repo Settings** | Per-repository: setup/archive/run scripts, **Custom Commands**, Global-command visibility, **Default Agent Profile**, default base ref & directory, copy-files overrides, open-with app, custom title, icon & color, PR merge strategy, line-diff & PR-state fetching. Reached from the sidebar context menu → "Repo Settings". → [custom-actions](custom-actions.md), [repositories-and-worktrees](repositories-and-worktrees.md) |

## Where settings live on disk

- **Global:** `~/.prowl/settings.json`
- **Global custom commands + agent profiles:** `~/.prowl/global.onevcat.json`
- **Per-repo:** `~/.prowl/repo/<repo-name>/prowl.json`
- **Per-repo custom commands + agent profile default/memory:** `~/.prowl/repo/<repo-name>/prowl.onevcat.json`
- **Dedicated agent profile homes:** `~/.prowl/agent-profiles/<uuid>/`

Legacy `~/.supacode` is migrated to `~/.prowl` on first launch.

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
