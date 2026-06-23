# Workspaces

**Keywords:** workspace, multi-repo, many repositories, agent cwd, `.prowl/workspace.json`, workspace metadata, `prowl list`

Workspaces let one agent work on a task that spans several repositories. A
workspace is a folder added to Prowl as a runnable project, with metadata at
`.prowl/workspace.json` describing the repositories inside it.

When you open a workspace in Prowl:

- The terminal starts in the workspace root.
- The sidebar/detail view uses the workspace title and repository list from
  `.prowl/workspace.json`.
- The `prowl` CLI reports the runnable target's `worktree.kind` as `workspace`.
- Git worktree, branch, diff, and PR controls remain per-repository features; a
  workspace is intentionally a multi-repo working directory rather than a single
  git repository.

## Folder layout

Use **Add...** from the sidebar toolbar and choose **Add Workspace**, or use the
Worktrees menu or command palette to create a workspace. Prowl creates the
shared folder, materializes the selected repositories, writes
`.prowl/workspace.json`, and opens the workspace as a runnable folder. A
workspace needs at least two repositories.

While a workspace is being created the prompt shows a spinner. **Cancel** stops
the creation and rolls back everything created so far: cloned folders, created
worktrees, and the workspace folder itself when Prowl created it.

```text
my-feature-workspace/
├─ .prowl/
│  └─ workspace.json
├─ app/
├─ api/
└─ shared-package/
```

Repository sources can be mixed in one workspace:

- Already opened repositories can be inserted from the **Add Opened** menu
  (`source_kind: existing_path`).
- Local repository folders are selected from disk
  (`source_kind: local_repository`).
- Remote repositories are added through a URL prompt that loads remote heads
  before inserting the row. Loading can be canceled while the prompt is open.
  They are cloned into the workspace folder with `source_kind: remote`. The
  inserted row defaults to **Use Existing** on the detected default remote
  branch.
- Bare repositories are supported by the metadata and materialization layer as
  `source_kind: bare_repository`, but the first workspace UI keeps that
  advanced source hidden.

Opened and local repository rows show their source as read-only provenance
rather than a mode selector because both follow the same materialization rules
after they have been added.

For already opened and local repositories, the branch action decides how the
folder is materialized:

- **Link** (the default) adds a symlink to the repository as it is on disk, so
  the workspace shares the live checkout.
- **Create Branch** runs `git worktree add -b` against the source repository:
  the workspace gets an isolated checkout on a new branch created from the
  selected base ref, without touching the source repository's own checkout. The
  new worktree also appears in the source repository's worktree list.
- **Use Existing** runs `git worktree add` with the selected ref. Choosing a
  remote-tracking ref creates a local tracking branch instead of a detached
  worktree. Git rejects a branch that is already checked out elsewhere.

The creation prompt detects base-ref candidates for already opened and local
repositories by reading local git refs, preferring the detected default
branch such as `main` or `master`. Refs are grouped as local branches, remote
tracking branches, or fetched remote branches, and the picker supports simple
text search. `<remote>/HEAD` symbolic pointers are omitted from the picker
because they only alias a branch that is already listed. Base refs are selected
from detected refs so workspace creation does not try to checkout an arbitrary,
nonexistent branch.

When creation validation fails inside a repository row, the repository list
scrolls to that row and highlights the invalid field with a red border.

The **Folder** path follows the workspace **Title** while it is still generated
by Prowl. Once you edit or choose the folder directly, Prowl treats it as a
manual path and stops changing it when the title changes.

Branch behavior is explicit:

- **Create Branch** uses `branch_name` plus the selected base ref to create a
  new branch or worktree branch. A branch name is required in this mode for
  every source kind.
- **Use Existing** uses the selected ref directly. For remote clones, Prowl
  checks out the selected remote branch after clone; Git creates the normal
  local tracking branch for refs such as `origin/feature`. For bare and local
  repositories, a local branch ref produces a branch worktree, and a
  remote-tracking ref such as `origin/feature` runs
  `git worktree add --track -B feature`, which creates the local tracking
  branch — aligning a same-named local branch to the remote when one exists.
  Git refuses if that branch is already checked out in another worktree.
  - When a remote-tracking ref is selected and a same-named local branch already
    exists, the repository row shows a choice: **Use local branch** (the
    default — checks out the existing local branch as-is) or **Reset to** the
    remote ref (the `-B` behavior, which discards local-only commits on that
    branch). This prevents an unnoticed reset of a local branch that is ahead of
    the remote.

Workspace rows expand to show child repository rows. Each child row displays its
current branch, uncommitted line counts, and pull request badge when available,
including immediately after a newly created workspace is opened. Click a child
row to select it and focus its terminal tab rooted at that repository folder
inside the workspace, creating that tab the first time it is selected.

## Removing a workspace

**Remove Repository** on a workspace opens a dedicated confirmation. By default
it only removes the entry from Prowl and leaves everything on disk. Tick **Also
delete the workspace folder and its worktrees** to additionally unregister the
worktrees that were created for this workspace from their source repositories
(`git worktree remove --force`) and delete the workspace folder. Worktree
entries with a recorded branch additionally offer a per-repository **Delete
branch** checkbox that removes the branch from the source repository after the
worktree is gone. Branch deletion goes through the same protected-branch guard
as the rest of Prowl, so `main`, `master`, and the repository's default remote
branch are never deleted even if they were recorded as a workspace branch.
Linked repositories stay untouched — only the symlinks inside the workspace
folder are removed. Cleanup is best-effort: a broken source repository is logged
and skipped instead of blocking the deletion. If a worktree cannot be
unregistered, Prowl asks before deleting the workspace folder, since deleting it
anyway would leave a dangling worktree registration in the source repository.

## Metadata

The workspace's repository settings page (Settings → the workspace under
Repositories) can edit workspace title, description, task links, repository
roles, repository agent notes, manual bootstrap script references, and agent
guide controls. Prowl patches `.prowl/workspace.json` in place so unknown
metadata fields are preserved.

The same settings page can add or remove child repositories after creation.
Adding a child uses the same materialization rules as workspace creation:
local sources can be linked or turned into worktrees, and remote sources are
cloned after their branches are loaded. Removing a child removes the workspace
entry and cleans up Prowl-created materialization under the workspace root:
linked children remove only the symlink, remote children remove the cloned
folder, and local or bare worktree children run `git worktree remove --force`
against their recorded source repository. Existing child source, path, and
checkout fields are shown as read-only provenance in settings; changing those
would require removing and re-adding the child.

Bootstrap profiles can be set to run on workspace creation or manually. The
workspace creation sheet exposes the creation-time policy, including Required.
The workspace settings page treats bootstrap as current-state management: choose
scripts from `~/.prowl/bootstrap-profiles.json`, save the workspace metadata,
and run each script manually from the child repository card. Linked children do
not expose bootstrap controls because setup scripts would write into the shared
live checkout.

Bootstrap profiles can be managed in **Settings → Bootstrap** or with
`prowl bootstrap`. A profile contains a `command`, optional `environment`, a
`script`, and `timeout_seconds`. The default command is
`/bin/sh "$PROWL_BOOTSTRAP_SCRIPT"`; Prowl writes the script to a temporary
workspace-local file and injects its path as the `PROWL_BOOTSTRAP_SCRIPT`
environment variable before running the command.

Example `.prowl/workspace.json`:

```json
{
  "schema_version": "prowl.workspace.v1",
  "title": "Checkout Flow",
  "description": "Update app UI, API contract, and shared package together.",
  "task_links": [
    "https://github.com/onevcat/Prowl/issues/123"
  ],
  "agent_guide": {
    "enabled": true,
    "outputs": ["AGENTS.md"],
    "include_child_instruction_files": true,
    "extra_notes": "Coordinate shared files before editing."
  },
  "repositories": [
    {
      "name": "App",
      "role": "macOS app",
      "agent_notes": "Use Swift/TCA conventions and validate with make build-app.",
      "path": "app",
      "source_kind": "local_repository",
      "source_location": "/Users/mikoto/Documents/Repos/github/Prowl",
      "branch_name": "codex/checkout-flow",
      "bootstrap": {
        "script_kind": "user_profile",
        "script_ids": ["common-node-install", "sync-prowl-local-files"],
        "run_on": ["create"],
        "required": false
      }
    },
    {
      "name": "API",
      "role": "backend",
      "path": "api",
      "source_kind": "remote",
      "source_location": "git@github.com:onevcat/api.git",
      "base_ref": "main"
    },
    {
      "name": "Shared Package",
      "role": "library",
      "path": "shared-package",
      "source_kind": "bare_repository",
      "source_location": "/Users/mikoto/Documents/Repos/bare/shared-package.git",
      "branch_name": "codex/checkout-flow"
    }
  ]
}
```

Top-level fields:

- `schema_version` — metadata format version. Defaults to
  `prowl.workspace.v1` when omitted.
- `id` — optional stable identifier. Defaults to the workspace root path.
- `title` — display title. Defaults to the folder name.
- `description` — optional task summary shown in the detail view.
- `task_links` — optional links or identifiers for the work item.
- `agent_guide` — optional guide generation settings. When `enabled` is true,
  Prowl writes each relative file in `outputs` (default `AGENTS.md`) with a
  managed workspace block. `include_child_instruction_files` references child
  `AGENTS.md`, `CLAUDE.md`, `.cursor/rules`, and
  `.github/copilot-instructions.md` files when they exist.
- `repositories` — repo entries that belong to the workspace.
- `created_at` / `updated_at` — optional ISO-8601 timestamps.

Repository entry fields:

- `id` — optional stable identifier. Defaults to `path`.
- `name` — display name. Defaults to the last path component.
- `role` — optional short role such as `app`, `backend`, or `docs`.
- `agent_notes` — optional repository-specific guidance included in generated
  workspace agent guides.
- `path` — relative path under the workspace root, or an absolute path.
- `source_kind` — `existing_path`, `remote`, `local_repository`, or
  `bare_repository`.
- `source_location` — optional remote URL, local repository path, or bare repo
  path.
- `branch_name` — optional branch/worktree name expected for the task.
- `base_ref` — optional base branch or ref.
- `bootstrap` — optional bootstrap profile reference. `script_kind:
  user_profile` looks up local profiles from `~/.prowl/bootstrap-profiles.json`;
  `script_ids` lists profile ids to run in order; `run_on` can include
  `create`, `on_add`, and `manual`; and `required` decides whether bootstrap
  failure fails the current materialization action. Older workspaces with a
  single `script_id` still load as a one-profile list.

Bootstrap profiles run after a child repository has been materialized, with the
child repository as the working directory. Automatic bootstrap is skipped for
linked children because those paths point at the user's existing checkout.
Prowl-provided environment variables include `PROWL_WORKSPACE_ROOT`,
`PROWL_REPOSITORY_ROOT`, `PROWL_REPOSITORY_ID`, `PROWL_REPOSITORY_NAME`,
`PROWL_REPOSITORY_PATH`, `PROWL_SOURCE_KIND`, `PROWL_SOURCE_LOCATION`,
`PROWL_BRANCH_NAME`, `PROWL_BASE_REF`, and `PROWL_BOOTSTRAP_SCRIPT`; custom
profile environment values override these on conflict, except
`PROWL_BOOTSTRAP_SCRIPT`, which is always set by Prowl to the temporary script
path for the current run.
Bootstrap logs and last-run state are written under the workspace `.prowl`
runtime directory, not back into `workspace.json`.

## Agent guides

New workspaces generate a workspace-level `AGENTS.md` by default. The generated
content is bounded by:

```markdown
<!-- prowl:workspace-agent-guide:start -->
...
<!-- prowl:workspace-agent-guide:end -->
```

Prowl only replaces this managed block when regenerating the guide. Content
outside the block is preserved. If the target file already exists without a
managed block, Prowl leaves it untouched and reports the conflict.

## Agent usage

Because the terminal cwd is the workspace root, agents can inspect and modify
all listed repositories in one session:

```bash
git -C app status
git -C api status
git -C shared-package status
```

Use the metadata as the contract: it tells the agent which repos are in scope,
where they are on disk, and what role each repo plays in the task.
