# 042 — Project Workspaces: Plan

| | |
| --- | --- |
| **Status** | Implemented (retrospective) |
| **Anchor date** | 2026-06-17 |
| **Documented** | 2026-07-12 (backfilled) |
| **Primary PRs** | #455, #472, #481, #485 |
| **Sources** | PR #455/#472/#481/#485 descriptions, `codex/workspace-mode` / `fix/workspace-mode-review` branch commit history |
| **Related** | [010-plain-folder-support](../010-plain-folder-support/000-plan.md), [013-prowl-cli](../013-prowl-cli/000-plan.md), [019-worktree-creation-and-lifecycle](../019-worktree-creation-and-lifecycle/000-plan.md), `docs/components/workspaces.md` |

## Background

Agents increasingly needed to work on tasks that span several repositories (an app, its
API, a shared package). Prowl's runnable targets were either a single git repository (with
worktrees) or a single plain folder (010-plain-folder-support); there was no entry that
gives one agent a shared working directory covering multiple repositories at once. The
feature was contributed by MikotoZero (#455, 22 commits) and landed through an onevcat
review pass (#472).

## Goals

- One runnable target that covers multiple repositories: the terminal starts in a shared
  workspace root containing a materialized copy/checkout of each member repository.
- Metadata-driven and inspectable: `.prowl/workspace.json` records the member
  repositories, their source, relative path, branch, and base ref.
- Create workspaces from mixed sources: already-opened repositories, local repository
  folders, bare repositories, and remote URLs.
- Explicit per-repository checkout semantics: **Link** (symlink-style reuse of an existing
  folder), **Create Branch** (new worktree/branch), **Use Existing** (check out an
  existing ref), including converting remote refs into local tracking branches.
- Roll back all intermediate products (clones, worktrees, the workspace folder) when
  creation fails or is canceled.
- Sidebar/detail integration: the workspace is a selectable runnable folder; its child
  repositories appear as read-only rows with live branch, diff, and PR status.
- A dedicated removal flow: remove from Prowl only, or additionally clean up the workspace
  folder and worktrees, with per-repository branch deletion as an opt-in.
- Safety on cleanup: never delete files by default, never delete protected branches,
  re-confirm when `git worktree remove`/unregister fails rather than leaving dangling
  registrations.
- CLI visibility: `prowl list` distinguishes `workspace` from `git`/`plain` targets.

### Non-goals

- A workspace is deliberately **not** a git repository. Worktree, branch, diff, and PR
  controls stay per-repository features; child repositories are metadata entries, not
  tracked worktrees.

## Design / Approach

Reconstructed from the PR descriptions and the landed code.

**Domain model.** `ProjectWorkspace` (`supacode/Domain/ProjectWorkspace.swift`) owns the
whole lifecycle: the `prowl.workspace.v1` snake_case JSON schema at
`.prowl/workspace.json` (`title`, `description`, `task_links`, `repositories` with
`source_kind` / `checkout` info), path normalization (`normalized(relativeTo:)`), source
kinds (`remote`, `local_repository`, `bare_repository`, `existing_path`), checkout modes
(`link`, `create_branch`, `use_existing_ref` plus remote-ref→tracking-branch), and
`create(...)` with a `MaterializationLedger` that records every produced artifact so
failure/cancel can roll back. New workspace folders default to
`~/.prowl/workspaces/<name>` (`SupacodePaths.workspacesDirectory`).

**Reuse of plain-folder support.** Rather than a third `Repository.Kind`, `Repository`
gains a `workspace: ProjectWorkspace?` payload and its initializer forces `kind = .plain`
whenever it is present — a workspace is a plain runnable folder with metadata, and 010's
capability gating (repository-level selection, no git capabilities) applies unchanged.

**Creation flow.** `WorkspaceCreationPromptFeature` + `WorkspaceCreationPromptView` drive
a multi-row prompt (Add Opened / Add Remote / Add Local), remote-head loading for URL
sources, and per-row branch/base-ref pickers; `RepositoriesFeature+WorkspaceCreation.swift`
executes creation off the reducer.

**Child status.** `RepositoriesFeature+WorkspaceChildren.swift` refreshes each child's
branch, line changes, and (when GitHub integration is available) PR status on the
`repositoriesLoaded` cadence. Children are deliberately not fed through the worktree info
watcher, which only handles tracked worktrees.

**CLI.** `ListCommandPayload` gains a `workspace` kind, mapped in
`ListRuntimeSnapshotBuilder`, so agents can tell workspaces apart in `prowl list`.

## Alternatives & decisions

- **Standalone "New Workspace" toolbar button (later superseded).** During #455 the button
  was folded into the Add Repository menu to reduce toolbar overflow, then reverted to a
  standalone button once the sidebar-toolbar disappearance glitch was identified as a
  macOS `NavigationSplitView` sidebar `.toolbar` lifecycle bug unrelated to button count.
  The PR explicitly refused to "hide the button" as a fake fix and noted the real escape
  is moving actions out of the sidebar toolbar. Two weeks later #520 (entry 019) replaced
  both buttons with a single "Add..." popover, which is the current UI.
- **Plain-kind piggyback over a new repository kind.** Chosen so all existing plain-folder
  behavior (selection, terminal keying, capability gating) applies for free; git
  capabilities stay per-repository by construction.
- **Children as metadata, not worktrees.** Rejecting synthetic worktrees keeps the
  worktree pipeline honest; the cost is a separate, coarser refresh path for child rows.
- **Bare repositories: domain yes, UI no.** The metadata/materialization layer supports
  `bare_repository`, but the creation menu only exposes Opened/Remote/Local sources.
- **Review-wave corrections (#472)** rather than post-merge fixes: workspace removal now
  participates in next-repository auto-selection; local branches named `*/HEAD` are no
  longer filtered out of ref options; the persistence normalizer uses a lightweight
  `hasMetadata` file check instead of decoding the full workspace JSON per entry;
  independent git lookups during base-ref fetch run concurrently (`async let`); workspace
  root-path logic is deduplicated into `ProjectWorkspace`.

## Amendments

- Updated 2026-06-20: sidebar/toolbar follow-up fixes — toolbar title width for
  folder/workspace (#481), full-row click area and collapse/expand-all for workspaces
  (#485) — see [002-sidebar-and-toolbar-follow-ups.md](002-sidebar-and-toolbar-follow-ups.md)
- Updated 2026-07-20: workspace bootstrap settings become runtime-only controls after
  creation — see [003-bootstrap-runtime-controls.md](003-bootstrap-runtime-controls.md)
