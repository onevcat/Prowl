---
name: sync-docs
description: Keep the agent-facing manual under docs/ in sync with the implementation. Diff-driven from a committed commit baseline; makes conservative, minimal edits only where the code has actually changed user-facing behavior. Run on demand or as part of release prep.
---

# Sync Docs

Keep the agent-facing documentation under `docs/` accurate as the implementation
evolves. This skill is **diff-driven** (it only looks at source that changed since
a committed baseline) and **deliberately conservative** (it makes the smallest
edits needed to restore accuracy — it does not rewrite, restyle, or expand the
docs).

Read `docs/README.md` first for the doc set's structure and intent. The docs are
written **for AI agents to read**, are plain Markdown, and are designed to be
verifiable: each file lists `Keywords`/`Related`, and the `reference/` files name
their source-of-truth.

## Guiding principle: be conservative

The goal is to keep facts correct with **low churn**, not to perfect the prose.

- **Default to leaving a doc unchanged.** Only edit when a documented fact is now
  demonstrably **wrong**, a documented feature was **removed**, or a clearly
  significant new user-facing feature/shortcut/setting was **added**.
- **Make the smallest possible edit.** Fix the wrong cell/line; don't reflow
  tables, reorder sections, or reword surrounding prose.
- **Tolerate a wide range.** Ignore internal refactors, renames, and code
  reshuffles that don't change user-facing behavior. Ignore stylistic/wording
  differences. Approximate phrasings ("roughly", "typically", "best-effort") are
  fine — don't tighten them just because you can.
- **Don't grow the doc set casually.** Do not add new sections or new files unless
  a genuinely new top-level feature appeared. If a change is large (a new feature
  that needs a whole new component manual, or a structural overhaul), **do not do
  it silently** — describe it in the report and let the human decide.
- **Keep "source of truth" pointers correct** if files move or are renamed.
- Prefer touching **few files per run**. If you find yourself about to edit many
  files, stop and re-read this section — most of those are probably tolerable.

## Steps

1. **Read the baseline.** Open `docs/.sync-meta.json` and read the
   `last_synced_commit` field (the **last-synced commit** hash).

2. **Diff the implementation since the baseline.** List source files that changed:
   ```bash
   git diff --name-only <baseline_commit>..HEAD -- \
     App/Sources/ CLI/ Shared/ ThirdParty/git-wt
   ```
   If nothing relevant changed, report "Docs up to date as of `<HEAD>`." then go
   to step 6 (bump the baseline) and stop.

3. **Map changed source → docs to re-check.** Use this table; only open the docs
   whose source actually changed. (Most changes touch zero or one doc.)

   | Source that changed | Docs to re-check |
   |---------------------|------------------|
   | `App/Sources/App/AppShortcuts.swift`, `App/Sources/Commands/**` | `reference/keyboard-shortcuts.md` (+ shortcut mentions in the relevant `components/*.md`) |
   | `App/Sources/Features/Settings/Models/GlobalSettings.swift`, `RepositorySettings.swift`, `UserRepositorySettings.swift` | `reference/settings-fields.md`, `components/settings.md`, `components/custom-actions.md` |
   | `CLI/Sources/prowl/**`, `App/Sources/CLIService/**` | `components/cli.md` |
   | `App/Sources/Clients/CLIInstall/**` | `components/cli.md`, `components/settings.md` |
   | `App/Sources/Features/Repositories/**`, `App/Sources/Domain/Worktree*.swift`, `App/Sources/Domain/Repository*.swift`, `App/Sources/Clients/Git/**`, `ThirdParty/git-wt` | `components/repositories-and-worktrees.md` |
   | `App/Sources/Features/Terminal/**`, `App/Sources/Infrastructure/Ghostty/**` | `components/terminal.md` |
   | `App/Sources/Features/Canvas/**` | `components/canvas.md` |
   | `App/Sources/Features/Shelf/**` | `components/shelf.md` |
   | `App/Sources/Features/CommandPalette/**` | `components/command-palette.md` |
   | `App/Sources/Features/ActiveAgents/**` | `components/active-agents.md` |
   | `App/Sources/Domain/AgentDetection/**`, `App/Sources/Infrastructure/AgentDetection/**` | `components/agent-detection.md` |
   | `App/Sources/Clients/Notifications/**`, `WorktreeTerminalState+Notifications.swift`, `App/Sources/Clients/Dock/**` | `components/notifications.md` |
   | `App/Sources/Features/DiffView/**` | `components/diff-view.md` |
   | `App/Sources/Clients/Github/**` | `components/github-pull-requests.md` |
   | `App/Sources/Clients/Updates/**`, `App/Sources/Features/Updates/**` | `components/updates.md` |
   | view-mode switching (`App/Sources/Features/App/**`, `ContentView.swift`) | `components/view-modes.md` |

   `overview.md`, `concepts.md`, and `README.md` only need touch-ups for the
   addition/removal of a **major** feature — leave them alone otherwise.

4. **Verify against the source of truth.** For each doc identified, check its
   falsifiable claims against the authoritative source — not against the diff
   summary — and apply minimal edits per the conservative rules above:

   | Claim type | Source of truth |
   |------------|-----------------|
   | Keyboard shortcuts (key + modifiers + command ID, remappability) | `App/Sources/App/AppShortcuts.swift`; menu wiring in `App/Sources/Commands/*.swift` |
   | Settings field names / types / defaults | `App/Sources/Features/Settings/Models/GlobalSettings.swift`, `RepositorySettings.swift` |
   | CLI commands / flags / ranges / error codes / JSON fields | `CLI/Sources/prowl/**` and `App/Sources/CLIService/**` (and, if the CLI is installed, `prowl <cmd> --help` for confirmation) |
   | Feature behavior / entry points | the corresponding `App/Sources/Features/**` or `App/Sources/Clients/**` |

   When in doubt whether something is a real, user-facing change, **leave the doc
   as-is and flag it** in the report rather than editing.

5. **Check internal links if files moved.** If you renamed/added/removed any doc
   file, re-run a quick relative-link check so nothing in `docs/` is broken.

6. **Bump the baseline.** Set `last_synced_commit` (and `last_synced_date`, `note`)
   in `docs/.sync-meta.json` to the current `HEAD`. This file is **committed to
   git** so the baseline persists across sessions and machines — never leave it
   uncommitted.

7. **Report.** Output a short summary:
   ```
   ## Docs Sync
   Baseline: <old_hash> → <new_hash>
   Source files changed in range: <count>

   ### Updated
   - docs/<file> — <one-line what & why>

   ### Checked, left unchanged (tolerated)
   - <area> — <why it didn't need a doc change>

   ### Needs human decision (not applied)
   - <large/ambiguous change> — <what & suggested doc action>
   ```

## Committing

- **Standalone run:** stage and commit only `docs/**` (which includes
  `docs/.sync-meta.json`); never `git add .`. If anything in `docs/` changed and
  you're not on `main`, open a PR targeting `onevcat/Prowl`.
- **As part of release prep** (the `release` skill, on `main`): commit the doc +
  `docs/.sync-meta.json` changes as **their own commit before the version bump and
  tag** — e.g. `git commit -m "Sync docs for <VERSION>"`. Do **not** leave them
  staged/uncommitted: `release.sh` aborts on a dirty working tree, and the doc
  commit must already be on `main` so it becomes an ancestor of the tag and ships
  inside the release. Bump/tag happen after, never before.
- Always bump and commit `docs/.sync-meta.json` even when no doc edits were
  needed, so the next run starts from a tight diff range. The baseline records the
  commit the docs were verified against (the current HEAD at run time) — for a
  release that is the code being shipped, captured before the later doc/bump/tag
  commits, which is correct (those commits touch no implementation files).
