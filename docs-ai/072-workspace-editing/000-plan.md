# 072 — Workspace Editing: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-09-25 |
| **Primary PRs** | #830 |
| **Related** | [042-project-workspaces](../042-project-workspaces/000-plan.md), [062-workspace-child-diff](../062-workspace-child-diff/000-plan.md), `docs/components/workspaces.md`, PR #602 (superseded reference) |

## Background

Entry 042 shipped workspaces as a create-once artifact. The creation sheet
(`WorkspaceCreationPromptFeature` / `WorkspaceCreationPromptView`) builds the folder,
materializes the member repositories and writes `.prowl/workspace.json`, but after that
nothing in the app can change the workspace: the detail view and the Settings page render
the metadata read-only and tell the user to "edit that file". A workspace therefore cannot
be renamed, described, linked to a task, extended with another repository, or trimmed
without hand-editing JSON and materializing folders manually.

PR #602 (MikotoZero, draft, conflicting since 2026-07) proposed the right direction:
editable metadata, adding and removing child repositories after creation, per-repository
roles. It bundled that with a much larger Script Profiles / bootstrap subsystem and a
duplicated editor inside Settings, and it is far behind `main`. This entry takes the
workspace-lifecycle half of that proposal and rebuilds it on the current code base, with
one editor surface instead of two. Bootstrap scripts stay out of scope.

## Goals

- **One editor, two modes.** The creation sheet becomes `WorkspaceEditorFeature` with
  `mode == .create | .edit`. Edit mode opens on an existing workspace, pre-filled from
  `.prowl/workspace.json`, and saves through a single domain operation.
- **Editable metadata:** title, description, task links, and per-repository name and role.
  Title is display-only; the workspace folder never moves.
- **Add repositories after creation** with the same sources and checkout semantics as
  creation (opened repository, local folder, remote URL; Link / Create Branch / Use
  Existing). New members are materialized on Save.
- **Remove repositories after creation** with the same safety model as workspace removal:
  the default only drops the metadata entry; an opt-in deletes the materialized folder
  (symlink for Link, `git worktree remove --force` for worktrees, folder delete for
  clones), with a further opt-in to delete the recorded branch through the guarded
  branch-deletion path.
- **Reorder** members (move up / down) so the sidebar and metadata list follow the user's
  mental order.
- **Discoverable entry points:** sidebar workspace header menu and child row context menu,
  a button on the workspace detail view (see the action log: not reachable today), a
  button in Settings → the workspace's page,
  the Command Palette, and the File menu next to "New Workspace…".
- **Creation parity:** the create sheet gains the same optional Description, Task Links
  and per-repository Role fields so a workspace can be fully described up front.
- Keep `.prowl/workspace.json` the single source of truth; unknown keys written by other
  tools or a future schema are preserved on save.

### Non-goals

- Bootstrap / Script Profiles (the other half of #602). If revisited, it is a new entry.
- Changing an existing member's source, path, or checkout mode. Those require remove +
  re-add; the editor shows them as read-only provenance.
- Renaming the workspace folder on disk when the title changes.
- Editing from the `prowl` CLI.

## Design / Approach

### Domain (`supacode/Domain/ProjectWorkspace.swift`)

- `ProjectWorkspaceCreationDraft` gains `description`, `taskLinks`; `ProjectWorkspaceRepositoryPlan`
  and `ProjectWorkspaceCreationRepository` gain `role`. `create` writes them.
- New `ProjectWorkspaceUpdateRequest` = root URL + edited metadata + ordered member list,
  where each member is either an existing `RepositoryEntry` (name/role possibly edited)
  or a new `ProjectWorkspaceRepositoryPlan`, plus a list of `ProjectWorkspaceRepositoryRemoval`
  (entry, `deleteFiles`, `deleteBranch`).
- New `ProjectWorkspace.update(_:fileManager:gitRunner:) async throws -> ProjectWorkspaceUpdateResult`.
  Order of operations is chosen so nothing already on disk is lost when the risky step
  fails:
  1. validate (title, ≥1 member after the edit, new-member checkouts);
  2. materialize new members through the existing `materialize` + `MaterializationLedger`
     (occupied names seeded with every current entry path, including entries being
     removed, so a re-added repository never collides with a folder that still exists);
  3. write the new metadata atomically, patching the existing JSON so unknown top-level
     and per-entry keys survive, with `updated_at` refreshed and `created_at` kept;
  4. clean up removed members best-effort (symlink → unlink; worktree → `git worktree
     remove --force` against the recorded source; clone → delete folder; then optional
     branch deletion is returned to the caller for the guarded `GitClient` path, like
     workspace removal does today).
  Failure in 1–3 rolls back the ledger and leaves the old metadata untouched. Failures in
  step 4 are collected and reported (`ProjectWorkspaceUpdateResult.cleanupFailures`), the
  metadata is already committed.
- Minimum member count drops from two to one. With editing available a workspace is a
  growable container, and forcing two repositories up front only blocks the natural
  "start with the app, add the API later" flow. Removal in the editor refuses to drop the
  last member.

### Reducer (`supacode/Features/Repositories/Reducer/`)

- `WorkspaceCreationPromptFeature.swift` → `WorkspaceEditorFeature.swift`. `State` gains
  `mode`, `description`, `taskLinks`, `existingRepositories`
  (`IdentifiedArrayOf<WorkspaceEditorExistingRepository>`: entry, editable name/role,
  `pendingRemoval: RemovalChoice?`), and reordering. `repositories` keeps holding the
  new rows exactly as today, so the remote prompt, base-ref loading and per-row validation
  are reused verbatim. `Delegate.submit` carries an enum: `.create(draft)` or
  `.update(request)`.
- `RepositoriesFeature+WorkspaceCreation.swift` keeps the creation flow; a new
  `RepositoriesFeature+WorkspaceEditing.swift` handles `editPromptRequested(id, removingChild:)`
  (re-reads the metadata from disk in an effect, falls back to the loaded snapshot),
  `saveWorkspace(request)`, `workspaceSaved`, `workspaceSaveFailed`. On success:
  reload repositories, toast, and an alert listing cleanup failures if any. The presented
  state is renamed `workspaceEditor`.
- Entry points: `RepositorySectionView` header menu + `WorkspaceChildRowsView` context
  menu ("Edit Workspace…", "Remove from Workspace…" pre-marks that child), `WorkspaceDetailView`
  header button, `RepositorySettingsView` workspace section button → `RepositorySettingsFeature.Delegate.editWorkspace`
  → `SettingsFeature` → `AppFeature` surfaces the main window and sends the request,
  `CommandPaletteItem.editWorkspace` (gated on the selected repository being a workspace),
  `WorktreeCommands` "Edit Workspace…" (same gate).

### Views (`supacode/Features/Repositories/Views/`)

- `WorkspaceCreationPromptView.swift` → `WorkspaceEditorView.swift`. Sections: header
  (mode-specific title, root path in edit mode), Title, Folder (create only), Description,
  Task Links (list with add/remove), Repositories (existing rows first: name, role, source
  badge, checkout/branch and path read-only, Move Up/Down, Remove with inline cleanup
  options and Undo; then new rows as today plus Role), footer with Cancel / Create|Save.
- `WorkspaceDetailView` shows roles, opens task links that parse as URLs, and gets an
  "Edit Workspace…" button. `WorkspaceRepositoriesGridView` unchanged apart from copy.
- Settings workspace section: keep the read-only grid, replace the "edit that file" footer
  with an "Edit Workspace…" button and a hint that the file remains the source of truth.

### Docs & tests

- `docs/components/workspaces.md`: new "Editing a workspace" section; metadata section no
  longer says read-only; minimum count updated. `docs/components/sidebar.md` /
  `command-palette.md` only if they enumerate the affected menus.
- Tests: domain (`ProjectWorkspaceTests`): update writes/patches metadata, materializes
  new members and rolls back on failure without touching existing ones, cleanup by
  kind, keep-files path, occupied-name seeding. Editor reducer: edit-mode population,
  field edits, removal mark/unmark and last-member guard, reorder, submit payloads for
  both modes. `RepositoriesFeature`: edit prompt request, save success/failure,
  settings-originated request through `AppFeature`.

## Alternatives & decisions

- **Second editor inside Settings (as #602 did)** — rejected. Two surfaces for the same
  mutations drift; Settings gets a button that opens the one editor on the main window.
- **Immediate per-action writes (Add Repository saves at once, as #602 did)** — rejected in
  favor of a transactional Save. Users can stage several changes, cancel cleanly, and the
  rollback story stays the same as creation.
- **Removals before additions** — rejected. Removal is irreversible; if the subsequent
  clone or worktree add failed, the user would have lost a member while the metadata still
  listed it. Additions run first and can be rolled back; removals run last after the
  metadata is committed.
- **Default to deleting a removed member's folder** — rejected; matches workspace removal
  where "remove from Prowl" never touches disk unless opted in. `git worktree remove
  --force` discards uncommitted work, so it must be explicit.
- **Keep the two-repository minimum** — rejected once editing exists; see Domain.
- **Whole-file rewrite that drops unknown JSON keys** — rejected; a JSON patch that keeps
  unknown top-level and per-entry keys costs little and protects forward compatibility.

## Amendments

(none yet)
