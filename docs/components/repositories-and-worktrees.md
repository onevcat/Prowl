# Repositories & Git Worktrees

> The sidebar and everything in it: adding projects, and creating, opening,
> archiving, and deleting git worktrees — the unit of work you hand to an agent.

**Keywords:** repository, repo, worktree, branch, sidebar, add repository, new worktree, archive, delete, pin, plain folder, non-git, base branch, git-wt, wt

**Related:** [concepts](../concepts.md) · [terminal](terminal.md) · [custom-actions](custom-actions.md) · [github-pull-requests](github-pull-requests.md) · [settings-fields](../reference/settings-fields.md)

## What it is

The left **sidebar** lists your **repositories**, each expandable into its
**worktrees**. A repository is a git project (or a plain non-git folder) you've
added. A worktree is one branch checked out into its own directory, so multiple
branches are live on disk at once — ideal for giving each agent its own branch.

Within a repository, worktrees are grouped: **Main** (the repo root), **Pinned**,
**Pending** (being created), and the rest. Each row shows the name, branch detail,
an unread-notification bell, and run/agent status.

## Repository kinds

| Kind | Worktrees | Branches | Diff | PRs | Run scripts |
|------|-----------|----------|------|-----|-------------|
| **git** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **plain** (non-git folder) | ❌ | ❌ | ❌ | ❌ | ✅ |

A plain folder can't expand; clicking it just opens a terminal there. Prowl
auto-detects which kind a path is when you add it (it runs `git` to find the repo
root; a confirmed non-repository result becomes a plain folder). This also works
on external disks and separate volumes where Git stops at a filesystem boundary.
If you later run `git init` in an open plain folder, Prowl automatically upgrades
it to a git repository and refreshes the sidebar.

## Git availability and load errors

Prowl uses the first working Git on your login shell PATH. If there is none, it tries
the app PATH, then common installation locations. Apple Git requires working Command
Line Tools; a full Xcode installation is not required. Independent Git installations
can also be used. Git and the bundled `wt` run with your login shell PATH, so Git hooks
and helpers (`git-lfs`, credential helpers, `ssh`) find the same tools as in a terminal.
If an earlier Git on that PATH does not work, the selected Git's folder goes first.
Without a login shell PATH, they use the app PATH.
Each executable or login-shell probe has a five-second timeout. A stalled probe
is stopped, including its child processes, before discovery tries the next source.
Cancelling one request does not interrupt discovery for other active requests.

A Git or repository access failure does not change a saved Git project into a
plain folder. The sidebar shows **Git is unavailable** or **Unable to read
repository**. Click the warning icon for guidance and **Copy Details**. After
fixing Git, permissions, or repository configuration, click **Retry** or use
**Refresh Worktrees** (`⌘⇧R`). Failed loads use the error row rather than retaining
an old worktree list. Existing terminal sessions for failed projects stay running.
Removing a failed project from Prowl closes its retained terminals; other projects'
terminals stay open. Background refreshes do not repeatedly open error dialogs.

## Adding a repository

- **Shortcut:** `⌘⇧O` (`open_repository`)
- **Toolbar:** the **Add...** button (folder-with-plus icon) at the top of the
  sidebar. Use the popover to browse for a local folder, drag a folder onto the
  drop zone, clone a remote git URL into a chosen directory, start workspace
  creation, or add a project group.
- **Sidebar context menu:** right-click an empty part of the sidebar list. The menu
  goes straight to **New Group…**, **Add Repository…**, **Clone Repository…**,
  **Add Remote Project…**, and **Add Workspace…**. It also has **Expand All**,
  **Collapse All**, **Show Active Agents** or **Hide Active Agents**,
  **Refresh Worktrees**, and **Archived Worktrees**.
- **Command Palette:** "Open Repository".

Pick one or more directories. Prowl detects git vs plain, de-duplicates, and
persists the list. Paths that don't exist or can't be read are reported in an
alert after the load. Repositories added after the initial app load are selected
automatically. If a repository was added through a symbolic link, Prowl resolves
and stores its actual git root so branches and worktrees continue to load.

To add a project on another machine over SSH, use **Add Remote Project...** (or **Add Remote
Project** in the Add popover). See [remote projects](remote-folders.md).

## Creating a worktree

- **Shortcut:** `⌘N` (`new_worktree`)
- **Button:** the **+** on a repository's header (only for git repos that support
  worktrees).
- **Context menu:** right-click a repository header → "New Worktree".
- **Command Palette:** "New Worktree".

By default a **creation prompt** appears (controlled by
`promptForWorktreeCreation`) where you:
- enter a **branch name** (leave blank to auto-generate, e.g. `bold-cat-523`).
  On devices with Apple Intelligence, an on-device AI suggestion may appear below
  the field based on your repository context and recent terminal activity — click
  **Use** to adopt it,
- choose the **base ref** (branch/tag) to branch from,
- optionally **fetch the remote first**.

An optional, default-collapsed **Advanced** section lets you override where the
worktree lands:
- **Worktree name** — the leaf folder name (defaults to the branch name).
- **Parent folder** — the directory it's created in (defaults to the repo's
  resolved base directory).

Leave both blank to keep the default `base/<branch>` placement. The footer shows
the full destination path as you type, or an inline error (the worktree name is a
single folder, so slashes, `.`/`..`, and `.git` are rejected).

Press **↩** to create, **Esc** to cancel. Branch names are validated live
(`git check-ref-format`).

**Creation runs through the bundled `wt` CLI** (`ThirdParty/git-wt`) and streams
progress through stages: reading local branches → choosing a name → checking repo
mode → resolving the base ref → fetching → creating. A **Pending** row shows the
live status until it's ready.

If creation fails, the error shows the end of Git's output, where Git and hooks
report the cause. Prowl removes the worktree folder only if this attempt created it
on the new branch, and keeps the branch. A Git hook that exits with an error fails
the creation, even when the checkout itself succeeded.

**Copying uncommitted files:** new worktrees can optionally copy `.gitignore`'d
files (`copyIgnoredOnWorktreeCreate`) and/or untracked files
(`copyUntrackedOnWorktreeCreate`) from the source — set globally or per repo.

**Setup script:** if the repo defines a setup script, it runs automatically in the
new worktree (see [custom-actions](custom-actions.md)).

## External worktree changes

Prowl watches Git's worktree registry for worktrees added, removed, or moved by
external commands such as `git worktree move`. Changes trigger a sidebar refresh
after a two-second debounce, including while Prowl is in the background. When
Prowl becomes the active app, it also reloads every repository once, to catch a
change that a watcher missed.

## Selecting & switching worktrees

- **Click** a row to select it (focuses its terminal).
- **`⌃1`–`⌃9`** jump to worktree 1–9.
- **`⌘⌃↓` / `⌘⌃↑`** select next / previous worktree.
- **`⌘⌥[` / `⌘⌥]`** go back / forward through worktree selection history.
- **`⌘⇧L`** reveals the currently focused worktree (or selected folder) in the
  sidebar. It opens a collapsed repository and a collapsed group to show it.
  Selecting a worktree any other way does not open a collapsed group.

## Pinning & ordering

- **Pin / Unpin:** hover a worktree → pin button, or right-click → "Pin to top" /
  "Unpin". Pinned worktrees sit in a section above the rest. (Not available for
  the main worktree.)
- **Reorder:** drag repositories or worktrees to rearrange; a thin accent line
  shows the drop target. Order is persisted. You can repeat the drag or cancel
  with Escape and start another drag without reopening the app. Repositories
  and groups drag the same way; see [Repository groups](#repository-groups).
- **Expand / Collapse:** click the chevron on a repo header, or cycle the
  sidebar's header button: from all-collapsed it offers **Expand Active**
  (double chevron `»` — expands only repos/workspaces that have open terminal
  tabs, and the groups that contain a repo or folder with open tabs), then
  **Expand All** (single chevron `›`), then **Collapse All** (chevron rotated
  down). The button acts on groups and repositories together. Expand Active is
  skipped when no repo (or every repo) has open tabs. Collapsed state is
  remembered.
- **Tab count badges:** a collapsed repo header shows its total open-tab count;
  expanding a git repo moves the count onto the individual worktree rows
  (hidden at zero). Workspaces and plain folders always show the count on the
  header.

## Repository groups

Groups put related repositories under one collapsible header in the sidebar.
Groups and ungrouped repositories mix at the top level. A group holds
repositories only; groups do not nest.

- **Create:** right-click an empty part of the sidebar list → **New Group…**, or
  choose **Add Project Group** in the **Add...** panel, then type a name. The empty
  group goes to the end of the list; drag projects into it. To start a group from
  a repository, right-click it → **New Group…**. That group takes the repository's
  place.
- **Move:** right-click a repository → **Move to Group** → a group. The
  repository goes to the end of that group. **Remove from Group** puts it right
  after the group.
- **Drag:** drag a repository between the rows of a group to put it there, or
  onto a group header to put it at the end of that group (the header
  highlights). Drag it above a group header or between top-level rows to take it
  out of its group. Drag a group by its header to move the whole group; a group
  drops only between top-level rows, never into another group. To drop after
  the last entry, drop below it. A repository dropped into a collapsed group
  stays hidden until you open the group.
- **Edit:** right-click a group header (or hover it → `…`) → **Rename Group…**,
  **Group Color** (a quiet background behind the group, or None), **Group Icon**,
  or **Ungroup**. Ungroup keeps the repositories in the group's place and removes
  no repository.
- **Icon:** a group shows a folder before its name: a filled folder when the
  group is collapsed and an empty folder when it is open. **Group Icon** →
  **Choose Symbol…** picks an SF Symbol, **Choose Image…** imports an image file,
  and **Use Default Icon** brings the folder back. A chosen icon stays the same
  when the group opens or closes. Symbols and SVG images take the group color;
  other images keep their own colors. Imported images are copied to
  `~/.prowl/group-icons/` and deleted when the icon changes or the group is
  ungrouped.
- **Layout:** the members of a group sit a small step in from the top-level rows,
  and their worktrees move with them.
- **Collapse:** click a group header or its chevron. A collapsed group keeps the
  expansion of each repository in it, and its worktrees are skipped by `⌃1`–`⌃9`
  and `⌘⌃↓` / `⌘⌃↑`.
- **Order:** the sidebar order, groups included, is the order of worktree
  hotkeys, `prowl list`, Shelf, and toolbar notifications.
- **Storage:** the layout is saved in `~/.prowl/sidebar-layout.json` at the
  first change. Before that file exists, the existing repository order is used.

## Archiving a worktree

Archiving hides a worktree from the main list without deleting it.

- **Right-click** the row → "Archive Worktree" (or "Archive Selected Worktrees"
  with a multi-selection). No default keyboard shortcut.
- If the branch is already **merged**, Prowl archives immediately without asking.
- If the repo defines an **archive script**, it runs first (live progress); if it
  fails, archiving stops and the worktree stays active.
- **View archived:** `⌘⌃A` toggles the Archived Worktrees panel (press again to
  return to the previous worktree or folder and view mode — Default, Canvas, or Shelf),
  grouped by repo, with **Unarchive** and **Delete Selected** (`⌘⇧⌫`) buttons.
  When the panel was opened from Shelf, picking a worktree in the sidebar also
  returns to Shelf and opens it as a book. Returning to Canvas restores keyboard
  focus to the previously focused tab and its active pane.
- **Auto-delete:** if `archivedAutoDeletePeriod` is set, archived worktrees older
  than the period are deleted automatically. When you pick a period in Settings →
  Worktree that would delete existing archived worktrees right away, Prowl lists
  them and asks first; Cancel keeps the previous period and the worktrees.

The **main worktree cannot be archived.**

## Deleting a worktree

Deleting removes the worktree directory (and optionally its branch).

- **Right-click** the row → "Delete Worktree", or **`⌘⇧⌫`**.
- A confirmation dialog offers an **"Also delete local branch"** toggle (its
  tooltip notes `git branch -d`). The toggle remembers the last confirmed choice
  (`deleteBranchOnManualWorktreeDelete` in UserDefaults; defaults to off).
- Prowl removes the worktree (relocating + `git worktree prune` if needed), then
  verifies that Git no longer registers it. Cleanup failures keep the worktree
  visible and show Git's error. If branch deletion is rejected because the branch
  isn't merged, Prowl offers a **force delete** (`git branch -D`).
- Protected branches (`main`, `master`, and the detected default) are guarded.

The **main worktree cannot be deleted.**

## Removing a repository

Right-click a repo header → "Remove Repository" (or the **⋯** menu). This removes
it from Prowl (closing its open terminals); it does **not** delete files on disk.

## Opening a worktree in another app

`⌘O` opens the worktree with the selected open action. When the action is
**Automatic** (the default), Prowl inspects the worktree's top-level files and
prefers an app matching the project type: Flutter (`pubspec.yaml` with a
`flutter:` key) → Android Studio (then IntelliJ, then the VS Code family),
React Native (`package.json` depending on `react-native` plus an `ios/` or
`android/` folder) → VS Code family (then WebStorm, then Android Studio),
Unity (`ProjectSettings/ProjectVersion.txt` at the root or one folder down,
covering SDK repos that keep the Unity project beside tooling manifests) →
Rider (then the VS Code family),
`.xcodeproj`/`.xcworkspace`/
`Package.swift`/`Project.swift` → Xcode, Gradle files → Android Studio (then
IntelliJ IDEA, then IDEA EAP), `*.sln`/`*.csproj` → Rider, `pom.xml` →
IntelliJ IDEA (then IDEA EAP), `go.mod` → GoLand, `Cargo.toml` → RustRover,
`CMakeLists.txt` → CLion, `composer.json` → PhpStorm, `Gemfile` → RubyMine,
Python manifests → PyCharm, `package.json` → WebStorm. If the matching app
isn't installed (or no project type is detected), it falls back to the generic
priority — your first installed editor (Cursor → Zed → Zed Preview →
VS Code → Windsurf → …), falling through to Xcode and then **Finder only when
no preferred app is found**. Use the **Open** dropdown in the worktree's
detail toolbar to pick a different app (this pins it for the repo), or pick
**Automatic** at the top of that dropdown to clear the pin and return to
project-aware selection. You can also set a per-repo default (`openActionID`)
/ global default (`defaultEditorID`). Prowl detects: Finder, Terminal,
`$EDITOR`, VS Code (+ Insiders), VSCodium, Cursor, Zed (+ Preview), Windsurf,
Antigravity, Sublime Text, Nova, Xcode, Android Studio, JetBrains IDEs
(IntelliJ IDEA and IDEA EAP, WebStorm, PyCharm, RustRover, Rider, GoLand,
CLion, PhpStorm, RubyMine), GitHub Desktop
/ Fork / Tower / GitKraken / Sourcetree / Sublime Merge / SmartGit / GitUp,
and terminals (Alacritty, Ghostty, iTerm2, Kitty, Warp, WezTerm). If the
chosen app isn't installed, Prowl shows an alert.

Other per-row context-menu items: **Rename Branch…** (`⌘⇧M`; the context menu
targets that row, while the shortcut targets the selected worktree or focused
Canvas card and is unavailable during bulk selection, worktree creation, or
another modal prompt), **New Terminal Tab** (selects the worktree and opens a
tab at the worktree **root** — unlike a plain
new tab, it never inherits the focused tab's current directory), **Stop Running
Script** (only while a Prowl-tracked run script is running), **Copy Path**,
**Copy Branch Name**,
**Reveal in Finder**, **Open Pull Request** (only when the worktree has a PR),
and **Close All Tabs** (disabled when the worktree has no tabs; uses the same
active-agent / long-running-command confirmation as the tab bar's "Close All",
and the confirmation names the target worktree).

The repository **header** menu (right-click, or the **⋯** button) offers
**New Worktree** (git repos only), **Repo Settings…**, and
**Remove Repository**. Plain folders and workspaces get **Copy Path** /
**Reveal in Finder** instead of New Worktree, and workspaces additionally get
**Edit Workspace…** (see [workspaces](workspaces.md)); git repo headers
deliberately have no path actions because a repository's root can be a bare
directory — use the worktree rows for paths.

## Repository appearance (icon & color)

In **Repo Settings** you can give each repository an **icon** (any SF Symbol from
a curated set, a bundled asset, or your own image) and a **color** (10 presets or
a custom color). The color tints the icon, the name, the Shelf spine (if
`shelfSpineTintFollowsRepositoryColor`), and the window chrome (if
`windowTintMode = repositoryColor`). You can also set a **custom display title**
(`customTitle`) that overrides the folder name.

**Automatic icon detection** (`detectRepositoryIconsAutomatically`, default on):
when a repository or folder is newly added, Prowl scans it locally in the
background for a high-confidence product icon — an Icon Composer `.icon`
bundle (flattened via QuickLook) or `AppIcon.appiconset` raster for Apple
projects, an Android launcher raster, the iOS/Android assets of a Flutter or
React Native project, Tauri bundle icons from `src-tauri/tauri.conf.json`, a
`package.json` `"icon"` declaration, or a web manifest icon / `rel=icon`
favicon / root logo for web projects — and silently sets it as the repo icon.
For any other repository, a last generic tier accepts a near-square
`icon`/`logo`/`appicon` image (`svg`/`png`/`webp`) at the root, `assets/`, or
`.github/`; wide wordmark logos and banners are rejected by an aspect-ratio
gate. Detection never runs for existing repositories, workspaces, or repos
that already have an icon, and it never replaces a manual choice. **Clear Icon** removes a
detected icon and suppresses re-detection; only removing and re-adding the
repository triggers a fresh scan. Detected icons keep their original colors
(they are never tinted, unlike user-picked SVGs/symbols).

**Suggest an Icon…** (Repository Icon menu): generates SF Symbol suggestions
for the repository on-device from its README (falling back to the package
manifest description, then the repo name). The picker sheet opens immediately
with an inline loading state; results show the best pick plus four
alternates, a reasoning line, and the input source. When Apple Intelligence
is unavailable the results are labeled **Keyword suggestions**. Nothing is
applied until you pick a symbol and confirm. Results are cached in memory for
the session; **Regenerate** runs a fresh pass.

## Lifecycle states (what the row can show)

- **Pending** — worktree is being created (grey row, live stage text).
- **Creating / Archiving / Removing** — transient loading states with progress.
- **Running** — a Run Script or agent task is active in that worktree.
- **Unread bell** — the worktree has unseen notifications.

## Settings that affect this area

Global (Settings → Worktree / General) and per-repository (Repo Settings) — see
[`reference/settings-fields.md`](../reference/settings-fields.md) for the full
list. Highlights:

- `promptForWorktreeCreation`, `fetchOriginBeforeWorktreeCreation`
- `defaultWorktreeBaseDirectoryPath` / per-repo `worktreeBaseDirectoryPath`
- per-repo `worktreeBaseRef` (default base branch)
- `copyIgnoredOnWorktreeCreate`, `copyUntrackedOnWorktreeCreate`
- `deleteBranchOnAutomaticCleanup`, `mergedWorktreeAction`, `archivedAutoDeletePeriod`
- per-repo `setupScript`, `archiveScript`, `openActionID`, `customTitle`

## Gotchas for agents

- The **main worktree** (`isMain`) is special: no archive/delete/rename.
- Worktree **names are auto-generated** (`adjective-animal-number`) unless the user
  named them — don't assume the name reflects the branch's purpose.
- Removing a repository does **not** delete files; deleting a worktree **does**
  remove its directory (and optionally its branch).
- A worktree's `id` is its **path** (with trailing-slash normalization) — the same
  identifier the [`prowl` CLI](cli.md) uses.
