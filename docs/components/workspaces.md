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

Create or clone the repositories into a shared folder first, then add that
folder to Prowl.

```text
my-feature-workspace/
├─ .prowl/
│  └─ workspace.json
├─ app/
├─ api/
└─ shared-package/
```

Prowl currently reads the metadata and opens the workspace root. It does not yet
clone remote repositories or materialize git worktrees from the metadata by
itself, so those directories should already exist when the agent starts.

## Metadata

Example `.prowl/workspace.json`:

```json
{
  "title": "Checkout Flow",
  "description": "Update app UI, API contract, and shared package together.",
  "task_links": [
    "https://github.com/onevcat/Prowl/issues/123"
  ],
  "repositories": [
    {
      "name": "App",
      "role": "macOS app",
      "path": "app",
      "source_kind": "local_repository",
      "source_location": "/Users/mikoto/Documents/Repos/github/Prowl",
      "branch_name": "codex/checkout-flow"
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

- `id` — optional stable identifier. Defaults to the workspace root path.
- `title` — display title. Defaults to the folder name.
- `description` — optional task summary shown in the detail view.
- `task_links` — optional links or identifiers for the work item.
- `repositories` — repo entries that belong to the workspace.
- `created_at` / `updated_at` — optional ISO-8601 timestamps.

Repository entry fields:

- `id` — optional stable identifier. Defaults to `path`.
- `name` — display name. Defaults to the last path component.
- `role` — optional short role such as `app`, `backend`, or `docs`.
- `path` — relative path under the workspace root, or an absolute path.
- `source_kind` — `existing_path`, `remote`, `local_repository`, or
  `bare_repository`.
- `source_location` — optional remote URL, local repository path, or bare repo
  path.
- `branch_name` — optional branch/worktree name expected for the task.
- `base_ref` — optional base branch or ref.

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
