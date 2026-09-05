# Settings

> Workflow Settings (global and repository-local) and the `prowl-workflow` skill row are hidden unless Prowl starts with `PROWL_WORKFLOW_UI=1`. CLI workflow and skill commands remain available.

> The Settings window (`⌘,`): what each tab controls. For the exhaustive
> field-by-field list, see [`reference/settings-fields.md`](../reference/settings-fields.md).

**Keywords:** settings, preferences, ⌘comma, general, notifications, shortcuts, worktree, updates, advanced, github, agents, agent profiles, workflows, workflow settings, enable workflow, bindings, cli & skills, command line tool, cli, socket status, agent skills, skills install, repo settings, appearance

**Related:** [reference/settings-fields](../reference/settings-fields.md) · [custom-actions](custom-actions.md) · [updates](updates.md) · [notifications](notifications.md) · [workflows](workflows.md)

## Opening

`⌘,` (`open_settings`), the app menu, or Command Palette → "Open Settings". The
window is a native macOS split window: the sidebar selects top-level sections,
and its toolbar's sidebar control can hide or show that sidebar. Re-opening
Settings brings the existing Settings window forward rather than creating
another one. `⌘W` closes it.

Most sections are roots in the detail pane. A section can drill in without
losing the sidebar; for example, **Agents → Profiles** → a profile pushes its
editor and macOS shows the standard Back control beside the editor title. Back
returns to Profiles, while selecting another sidebar item leaves the drill-in
and opens that section's root.

## Sections

| Section | Controls |
|-----|----------|
| **General** | Appearance (system/light/dark), default app for opening worktrees, diff tool, confirm-before-quit, default view mode, window chrome tint, automatic repository icon detection, toolbar buttons (Run / Open-in-editor), dim unfocused splits. |
| **Notifications** | In-app alerts, notification sound picker (Never / system sounds / Prowl Classic), macOS system notifications, move-notified-to-top, command-finished notification + threshold, Dock badge & bounce. → [notifications](notifications.md) |
| **Shortcuts** | Remap app keyboard shortcuts; view defaults; resolve conflicts. → [keyboard-shortcuts](../reference/keyboard-shortcuts.md) |
| **Worktree** | Worktree creation/deletion defaults: prompt on create, fetch before create, base directory, copy ignored/untracked files, automatic local-branch cleanup, merged-worktree action, archived auto-delete period. |
| **Updates** | Auto-check toggle, "Check for Updates Now". → [updates](updates.md) |
| **GitHub** | Enable GitHub integration (uses the `gh` CLI). → [github-pull-requests](github-pull-requests.md) |
| **Commands** | Global Custom Commands. Enabled commands appear in the window toolbar; each repo can independently hide a Global command. → [custom-actions](custom-actions.md) |
| **Advanced** | Analytics, crash reports, restore terminal layout on launch (experimental) + clear saved layout. |
| **Agents → Display** | Active Agents panel auto-show, terminal titles, Shelf status markers, and Agent Island enablement, Monitor, global shortcut, silent opacity, and floating-position reset. → [active-agents](active-agents.md), [agent-island](agent-island.md) |
| **Agents → Profiles** | Named launch presets for supported agent runtimes (model, effort, execution mode, tab/split placement, extra arguments, opt-in dedicated home for a separate account) with a live launch preview. List order is the recommendation fallback. → [agent-profiles](agent-profiles.md) |
| **Agents → CLI & Skills** | Install/status for the bundled `prowl` CLI, the local socket path it uses to reach the app and whether this app is **listening** on it, and the **Agent Skills** section that links the bundled skills into your agents' skill folders. → [cli](cli.md) |
| **Agents → Workflows** | Compact Built-in and personal workflow lists. Select a row for Enabled, explicit Run target, role profile preferences, Run Setup, validation, and source-file actions; **New Workflow…**, **Ask an Agent…**, and the CLI dependency banner remain on the index. → [workflows](workflows.md) |
| **Repositories / Repo Settings** | Per-repository: setup/archive/run scripts, **Custom Commands**, Global-command visibility, **Default Agent Profile**, a direct **Workflows** list, default base ref & directory, copy-files overrides, open-with app, custom title, icon & color, PR merge strategy, line-diff & PR-state fetching. Reached from the sidebar context menu → "Repo Settings". → [custom-actions](custom-actions.md), [repositories-and-worktrees](repositories-and-worktrees.md), [workflows](workflows.md) |

## Where settings live on disk

- **Global:** `~/.prowl/settings.json`
- **Global custom commands + agent profiles + workflow settings:** `~/.prowl/global.onevcat.json`
- **Your workflow files:** `~/.prowl/workflows/*.yaml` (per repository: `<repo root>/.prowl/workflows/`)
- **Per-repo:** `~/.prowl/repo/<repo-name>/prowl.json`
- **Per-repo custom commands + agent profile default/memory:** `~/.prowl/repo/<repo-name>/prowl.onevcat.json`
- **Dedicated agent profile homes:** `~/.prowl/agent-profiles/<uuid>/`

Legacy `~/.supacode` is migrated to `~/.prowl` on first launch.

## Install the CLI from here

**Agents → CLI & Skills → Install** symlinks `prowl` into `/usr/local/bin`
(prompting for admin rights if needed). Also available via Command Palette →
"Install Command Line Tool". See [cli](cli.md).

The page's **Connection** section shows the socket path and a **Status** row:
**Listening** (this app accepts `prowl` connections), **Not listening** with the
reason (another Prowl instance already owns the socket — quit it or give this
instance its own `PROWL_CLI_SOCKET`; a permission or path-length problem), or
**Not running**. The same reason blocks Run in the workflow start sheet and tops
the Workflows page, since workflow participants deliver through `prowl`.

## Workflows

**Agents → Workflows** lists Built-in and personal workflows; repository
workflows appear in the matching Repository Settings immediately after
**Agents**. Select any compact row for **Enabled**, **Run in <worktree>**, every
role's behavior, **Preferred Agent Profile** for launch roles, **Run Setup**
(Follow Workflow / Always Review Before Running / Run Directly When Possible),
validation, and source-file actions. **New Workflow…** opens a starter YAML in
the default app, while **Ask an Agent…** provides an authoring prompt. Rows and
open details follow file changes live. See [workflows](workflows.md#settings--agents--workflows).

## Agent Skills

**Agents → CLI & Skills → Agent Skills** lists the user-installable skills bundled in
the app (`Prowl.app/Contents/Resources/skills/`, today `prowl-cli` and `prowl-workflow`) and links them into
your agents' skill folders so every agent reads the version that matches the installed
app. It is the GUI for [`prowl skills`](cli.md#prowl-skills) in user scope and shows the
same status as `prowl skills list`.

- **Rows** — one per bundled `user` skill: name, a short summary (the skill's
  `metadata.prowl-summary`; the agent-facing `description` is shown only when a skill has no
  summary), and **Reveal** (shows the bundled skill folder in Finder). Workflow-only skills are
  not listed.
- **Target lines** — one per *detected* target under each skill: `Claude Code`
  (`~/.claude/skills`), `Codex` (`~/.codex/skills`), and `Shared agents directory`
  (`~/.agents/skills`), each showing the link's folder (`~/.claude/skills/prowl-cli`), its
  status, and one action. A target is detected when its parent folder (`~/.claude`, `~/.codex`,
  `~/.agents`) exists. With no detected target the section says so and points at
  `prowl skills install --target <claude|codex|agents>`, which creates the folder.
- **Statuses and actions** — one explicit action per skill × target link:

  | Status | Meaning | Button |
  |---|---|---|
  | Installed | Symlink → this app's bundled skill | **Remove** (deletes the link only) |
  | Not installed | Nothing in the slot | **Install** (creates the skills folder if needed) |
  | Linked elsewhere `→ path` | Symlink to another Prowl build (for example a Debug build) | **Replace** |
  | Broken link `→ path` | Dangling symlink — the app moved or was removed | **Repair** |
  | Real file or directory | Something that is not a symlink occupies the slot | none — Prowl never deletes it; remove it manually |

- **Aliased targets** — if `~/.claude/skills` and `~/.codex/skills` are symlinks to one
  synced folder, both lines describe the same link: installing or removing through one
  updates the other immediately.
- Results show as a toast; a failure (for example a real directory in the way) also shows
  an alert. Nothing is auto-linked after an update: a newly bundled skill simply appears
  as Not installed. Project-scope links are CLI-only (`prowl skills install --scope project`).
- A Debug build that was not built with `make build-app` has no staged skills; the section
  then reports that the bundled skills are unavailable.

## Gotchas for agents

- Many behaviors are **global with a per-repo override** (copy-files, base
  directory, PR merge strategy, open-with app). A per-repo value of "default"/nil
  means "use the global setting."
- For exact field names, types, and defaults (useful when reading/writing the JSON
  directly), use [`reference/settings-fields.md`](../reference/settings-fields.md).
