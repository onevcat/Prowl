# Diff View

> A dedicated window showing what changed in a worktree vs HEAD — review an
> agent's work before you commit.

**Keywords:** diff, diff view, outgoing changes, changes, review, working tree, HEAD, split, unified, line changes, ⌘⇧Y, ⌘⌥⇧Y, show diff, uncommitted, base branch

**Related:** [repositories-and-worktrees](repositories-and-worktrees.md) · [github-pull-requests](github-pull-requests.md) · [command-palette](command-palette.md)

## What it is

The default Diff window shows all changes in the selected worktree's working
directory compared against **HEAD** — exactly what an agent has modified. It's a
fast way to review before committing or merging.

**Open:** click a worktree's diff badge, press `⌘⇧Y` (`show_diff`), use
Command Palette → "Show Diff", or right-click a worktree row → "Show Diff".

## Outgoing Changes

**Outgoing Changes** is the second mode of the same window: the committed
changes the worktree's branch would contribute to a pull request
(`git diff <base>...HEAD`). It does not change the working-tree semantics of
Show Diff or its line-change badge.

**Open:** View → Show Outgoing Changes, press `⌘⌥⇧Y` (`outgoing_changes`),
use Command Palette → "Show Outgoing Changes", right-click a worktree row →
"Show Outgoing Changes", or flip the window's **Uncommitted | Outgoing**
toolbar switcher. The View menu groups it with Show Diff behind a separator.

The comparison base is resolved by a strict ladder and always shown in the
window title and file-list header (e.g. `vs origin/main · pull request base`):

1. **Pull request base** — the PR's target repository is matched to exactly
   one local remote; the comparison uses `refs/remotes/<remote>/<base>`.
2. **Worktree base setting** — the repository's configured
   `worktreeBaseRef` (Settings → repository → Base Branch), when no PR exists.
3. **Default branch** — the automatic base (`origin/HEAD`, falling back to
   the local default branch), when nothing is configured.

A source that is present but unresolvable (e.g. an unfetched PR base, or a
configured base branch that no longer exists) produces a specific error with
guidance instead of silently falling through to the next source. Multiple
remotes matching the PR repository is reported as its own error, listing the
conflicting remote names.

Prowl reads merge-base and `HEAD` snapshots, so staged, unstaged, and
untracked files are excluded. Every focus refresh re-runs the full base
resolution, so a pull request created, retargeted, or closed while the window
is open moves the base (visibly) on the next refresh. Outgoing Changes always
uses the built-in window; the external Diff Tool setting applies only to Show
Diff.

For **Show Diff**, Prowl opens its built-in YiTong-based diff window by default.
In Settings → General → Diff Tool, you can choose an external tool instead:

- **Built-in** — opens Prowl's diff window. The window is a persistent singleton
  (remembers size/position) and auto-refreshes when it regains focus. `⌘W`
  closes it.
- **Hunk** — opens a new Prowl terminal tab and runs `hunk diff` in the worktree.
- **FileMerge** — creates HEAD/worktree snapshot folders and runs `opendiff`.
- **Kaleidoscope** — creates HEAD/worktree snapshot folders and runs
  `ksdiff --diff`.
- **Custom Command** — creates HEAD/worktree snapshot folders and runs your
  command in the worktree directory. Supported placeholders:
  `{leftPath}`, `{rightPath}`, `{worktreePath}`, `{repoPath}`, and `{branch}`.

Tools that are not installed on the Mac are shown disabled in the Diff Tool menu.

## What Show Diff shows

- A **file list** sidebar of changed files, each with a colored status badge:
  - **M** Modified (orange) · **A** Added/untracked (green) · **D** Deleted (red) ·
    **R** Renamed / **C** Copied (blue) · **?** Unknown (grey).
- The selected file's diff, comparing the **HEAD** version (`git show HEAD:path`)
  against the **on-disk** version.
- Both tracked changes and **untracked new files** are included.
- A small **spinner** overlays the diff while a large file is still rendering,
  and an **error overlay** appears if rendering fails.

## Modes & interactions

- **Split** (side-by-side, default) or **Unified** view — toggle via the toolbar
  picker.
- Click a file in the list to view its diff. Rapid switching is debounced: the
  first selection renders immediately, files flicked through are skipped.
- Auto-refresh on focus keeps the active comparison current as the agent keeps
  working or commits.
- If a render fails, **re-selecting the file** (or any refresh) retries it.

## Line-change badges elsewhere

Repositories can show **line-change badges** (additions/deletions) on worktree
rows, controlled per repo by `observeLineDiffsAutomatically` (on by default).
Disable it for very large repos if it's expensive.

Prowl caches line counts for untracked files whose metadata has not changed.
The cache has bounded entry and path-key storage. On a cold refresh it scans at
most 32 MiB of uncached untracked content across the worktree. If more content
remains, the additions label ends in an ellipsis (`+N…`, or `+…` when no
additions were counted yet), and its tooltip identifies how many untracked files
were omitted. The badge stays available to open Show Diff, which still lists
every changed file. Tracked additions and deletions remain exact.

## Availability

Diff is a **git-only** feature — it's unavailable for plain (non-git) folders.

## Gotchas for agents

- The diff is **working-tree vs HEAD**, not vs the base branch — it reflects
  uncommitted changes in that worktree.
- Outgoing Changes is **merge-base vs HEAD** against a labeled base
  (PR base → worktree base setting → default branch); it excludes all
  uncommitted files. A present-but-unresolvable base errors out rather than
  cascading to a guess.
- External GUI tools receive snapshot folders so untracked files are included
  without changing the git index.
- The Hunk integration runs in a terminal tab because Hunk is terminal-native.
