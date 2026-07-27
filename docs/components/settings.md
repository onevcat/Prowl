# Settings

> The Settings window (`⌘,`): what each tab controls. For the exhaustive
> field-by-field list, see [`reference/settings-fields.md`](../reference/settings-fields.md).

**Keywords:** settings, preferences, ⌘comma, general, notifications, shortcuts, worktree, updates, advanced, github, repo settings, appearance

**Related:** [reference/settings-fields](../reference/settings-fields.md) · [custom-actions](custom-actions.md) · [updates](updates.md) · [notifications](notifications.md)

## Opening

`⌘,` (`open_settings`), the app menu, or Command Palette → "Open Settings". The
window is a sidebar of tabs plus a detail pane.

## Tabs

| Tab | Controls |
|-----|----------|
| **General** | Appearance (system/light/dark), default app for opening worktrees, diff tool, confirm-before-quit, default view mode, window chrome tint, automatic repository icon detection, toolbar buttons (Run / Open-in-editor), dim unfocused splits, Active Agents panel auto-show & terminal titles. |
| **Notifications** | In-app alerts, notification sound picker (Never / system sounds / Prowl Classic), macOS system notifications, move-notified-to-top, command-finished notification + threshold, Dock badge & bounce. → [notifications](notifications.md) |
| **Shortcuts** | Remap app keyboard shortcuts; view defaults; resolve conflicts. → [keyboard-shortcuts](../reference/keyboard-shortcuts.md) |
| **Worktree** | Worktree creation/deletion defaults: prompt on create, fetch before create, base directory, copy ignored/untracked files, automatic local-branch cleanup, merged-worktree action, archived auto-delete period. |
| **Updates** | Auto-check toggle, "Check for Updates Now". → [updates](updates.md) |
| **Advanced** | **Agent accounts** (default account, path rules, per-account login status + Sign In), analytics, crash reports, restore terminal layout on launch (experimental) + clear saved layout, and the **Install Command Line Tool** (`prowl` CLI) action. |
| **GitHub** | Enable GitHub integration (uses the `gh` CLI). → [github-pull-requests](github-pull-requests.md) |
| **Commands** | Global Custom Commands. Enabled commands appear in the window toolbar; each repo can independently hide a Global command. → [custom-actions](custom-actions.md) |
| **Repositories / Repo Settings** | Per-repository: setup/archive/run scripts, **Custom Commands**, Global-command visibility, default base ref & directory, copy-files overrides, open-with app, custom title, icon & color, PR merge strategy, line-diff & PR-state fetching, **agent account**. Reached from the sidebar context menu → "Repo Settings". → [custom-actions](custom-actions.md), [repositories-and-worktrees](repositories-and-worktrees.md) |

## Where settings live on disk

- **Global:** `~/.prowl/settings.json`
- **Global custom commands:** `~/.prowl/global.onevcat.json`
- **Per-repo:** `~/.prowl/repo/<repo-name>/prowl.json`
- **Per-repo custom commands:** `~/.prowl/repo/<repo-name>/prowl.onevcat.json`

Legacy `~/.supacode` is migrated to `~/.prowl` on first launch.

## Agent accounts

An **agent account** is a named directory under `~/.prowl/accounts/<name>/` that
holds one Claude Code login (`claude/`) and one Codex login (`codex/`). Prowl
selects one per pane by exporting `CLAUDE_CONFIG_DIR` and `CODEX_HOME`, so a
personal and a work account can run side by side in different panes.

Resolution order for a repository:

1. **Repo Settings → Agent Account** (an explicit name wins);
2. the longest matching **path rule** from Advanced (a path/account pair, e.g. `~/work` → `work`);
3. the **default account** from Advanced;
4. otherwise the system-wide `~/.claude` and `~/.codex` logins.

Prowl never logs an account in, it only points the CLIs at a directory. Advanced
lists every configured account with what each CLI reports there — the Claude
identity (`person@example.com (pro)`), or "Not signed in", or "Command line tool
not found" — with **Refresh** to re-ask and **Sign In** per CLI. Sign In opens a
terminal tab in the current repository running the login command with that
account's directory baked in, so the login lands in the intended account even if
the repository you are standing in resolves to a different one. Only panes
launched *after* an account change pick it up; running shells keep the one they
started with.

`CLAUDE_CONFIG_DIR` and `CODEX_HOME` relocate the **whole** configuration, not
just the credentials, so an untouched account would start as an empty profile.
Prowl therefore links the parts that belong to you rather than to a login into
each account the first time it prepares it:

| CLI | Linked from your own config | Stays per-account |
|-----|------------------------------|-------------------|
| Claude Code | `settings.json`, `CLAUDE.md`, `agents/`, `commands/`, `skills/`, `plugins/` | the login, `.claude.json`, `projects/`, history |
| Codex | `config.toml`, `AGENTS.md`, `skills/`, `plugins/` | `auth.json`, history, logs |

Anything the account already owns is never replaced, so a per-account override
keeps working. Because these are symlinks, editing them from an account pane
edits your real configuration — that is the point — but a tool that rewrites a
file wholesale replaces the link with a copy. When that happens the account's row
in Advanced says which entries it now keeps its own copy of, so the divergence is
visible instead of silent; delete that file in the account to follow your
configuration again.

A name containing `/` (or `.` / `..`) cannot be a directory, so Prowl ignores it
and says so under the field; the text you typed is still saved rather than
silently dropped.

The account a pane actually runs under is named by a capsule left of the branch
title in the worktree toolbar, shown only when an account is in effect. It
reports the account that pane **launched with**, so a pane opened before you
changed the rules keeps showing its own account until you open a new one.
Clicking the capsule opens these settings.

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
