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
root; "not a git repository" → plain folder). If you later run `git init` in an
open plain folder, Prowl automatically upgrades it to a git repository and
refreshes the sidebar.

## Adding a repository

- **Shortcut:** `⌘⇧O` (`open_repository`)
- **Toolbar:** the **Add...** button (folder-with-plus icon) at the top of the
  sidebar. Use the popover to browse for a local folder, drag a folder onto the
  drop zone, clone a remote git URL into a chosen directory, or start workspace
  creation.
- **Command Palette:** "Open Repository".

Pick one or more directories. Prowl detects git vs plain, de-duplicates, and
persists the list. Paths that don't exist or can't be read are reported in an
alert after the load. Repositories added after the initial app load are selected
automatically. If a repository was added through a symbolic link, Prowl resolves
and stores its actual git root so branches and worktrees continue to load.

## Creating a worktree

- **Shortcut:** `⌘N` (`new_worktree`)
- **Button:** the **+** on a repository's header (only for git repos that support
  worktrees).
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

**Creation runs through the bundled `wt` CLI** (`Resources/git-wt`) and streams
progress through stages: reading local branches → choosing a name → checking repo
mode → resolving the base ref → fetching → creating. A **Pending** row shows the
live status until it's ready.

**Copying uncommitted files:** new worktrees can optionally copy `.gitignore`'d
files (`copyIgnoredOnWorktreeCreate`) and/or untracked files
(`copyUntrackedOnWorktreeCreate`) from the source — set globally or per repo.

**Setup script:** if the repo defines a setup script, it runs automatically in the
new worktree (see [custom-actions](custom-actions.md)).

## Selecting & switching worktrees

- **Click** a row to select it (focuses its terminal).
- **`⌃1`–`⌃9`** jump to worktree 1–9.
- **`⌘⌃↓` / `⌘⌃↑`** select next / previous worktree.
- **`⌘⌥[` / `⌘⌥]`** go back / forward through worktree selection history.
- **`⌘⇧L`** reveals the currently focused worktree in the sidebar.

## Pinning & ordering

- **Pin / Unpin:** hover a worktree → pin button, or right-click → "Pin to top" /
  "Unpin". Pinned worktrees sit in a section above the rest. (Not available for
  the main worktree.)
- **Reorder:** drag repositories or worktrees to rearrange; a thin accent line
  shows the drop target. Order is persisted.
- **Expand / Collapse:** click the chevron on a repo header, or use the sidebar's
  **Expand All / Collapse All** buttons. Collapsed state is remembered.

## Archiving a worktree

Archiving hides a worktree from the main list without deleting it.

- **Right-click** the row → "Archive Worktree" (or "Archive Selected Worktrees"
  with a multi-selection). No default keyboard shortcut.
- If the branch is already **merged**, Prowl archives immediately without asking.
- If the repo defines an **archive script**, it runs first (live progress); if it
  fails, archiving stops and the worktree stays active.
- **View archived:** `⌘⌃A` toggles the Archived Worktrees panel (press again to
  return to the previous worktree), grouped by repo, with **Unarchive** and
  **Delete Selected** (`⌘⇧⌫`) buttons.
- **Auto-delete:** if `archivedAutoDeletePeriod` is set, archived worktrees older
  than the period are deleted automatically.

The **main worktree cannot be archived.**

## Deleting a worktree

Deleting removes the worktree directory (and optionally its branch).

- **Right-click** the row → "Delete Worktree", or **`⌘⇧⌫`**.
- A confirmation dialog offers an **"Also delete local branch"** toggle (its
  tooltip notes `git branch -d`). It starts unchecked and remembers the last
  choice made when a manual deletion is confirmed.
- Automatic cleanup has a separate **"Delete local branches during automatic
  cleanup"** setting. It is off by default and applies only to worktrees created
  by Prowl when merged or expired worktrees are removed automatically.
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
prefers an app matching the project type: `.xcodeproj`/`.xcworkspace`/
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

Other per-row context-menu items: **Copy Path**, **Reveal in Finder**. (Repo
Settings lives on the repository **header** menu, not the worktree row.)

## Repository appearance (icon & color)

In **Repo Settings** you can give each repository an **icon** (any SF Symbol from
a curated set, a bundled asset, or your own image) and a **color** (10 presets or
a custom color). The color tints the icon, the name, the Shelf spine (if
`shelfSpineTintFollowsRepositoryColor`), and the window chrome (if
`windowTintMode = repositoryColor`). You can also set a **custom display title**
(`customTitle`) that overrides the folder name.

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
- `deleteBranchOnAutomaticWorktreeCleanup`, `mergedWorktreeAction`, `archivedAutoDeletePeriod`
- per-repo `setupScript`, `archiveScript`, `openActionID`, `customTitle`

## Gotchas for agents

- The **main worktree** (`isMain`) is special: no archive/delete/rename.
- Worktree **names are auto-generated** (`adjective-animal-number`) unless the user
  named them — don't assume the name reflects the branch's purpose.
- Removing a repository does **not** delete files; deleting a worktree **does**
  remove its directory (and optionally its branch).
- A worktree's `id` is its **path** (with trailing-slash normalization) — the same
  identifier the [`prowl` CLI](cli.md) uses.
