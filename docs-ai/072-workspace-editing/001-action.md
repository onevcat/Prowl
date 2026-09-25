# 072 — Workspace Editing: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-09-25 | Plan written after reading PR #602 and the entry-042 code; branch `feature/workspace-editing` from `main` (`869b5d9f`) | this entry |
| 2026-09-25 | Domain: `ProjectWorkspace.update`, `ProjectWorkspaceUpdateRequest` / `Member` / `Removal` / `Result`, description, task links, and role on creation, unknown-key-preserving `encodeMetadata`, minimum member count 1 | PR #TBD |
| 2026-09-25 | `WorkspaceCreationPromptFeature` → `WorkspaceEditorFeature` with `mode`, existing-member rows, staged removal, reorder, task links, description; `WorkspaceCreationPromptView` → `WorkspaceEditorView` | PR #TBD |
| 2026-09-25 | `RepositoriesFeature+WorkspaceEditing.swift` (`workspaceEditing` action family), entry points in sidebar, detail view, Settings, Command Palette, Worktrees menu | PR #TBD |
| 2026-09-25 | Tests, `docs/` manual updates, this record | PR #TBD |

## Outcome & current state (as of 2026-09-25)

- **Domain** — `supacode/Domain/ProjectWorkspace.swift`
  - `ProjectWorkspaceCreationDraft` carries `description` and `taskLinks`;
    `ProjectWorkspaceRepositoryPlan` / `ProjectWorkspaceCreationRepository` carry `role`.
    `create` writes them and now accepts one repository (`notEnoughRepositories` reads
    "Add at least one repository.").
  - `ProjectWorkspace.update(_:fileManager:gitRunner:)` takes a
    `ProjectWorkspaceUpdateRequest` (root, title, description, task links, ordered
    `members` of `.existing(entry)` / `.added(plan)`, `removals`, `updatedAt`) and returns a
    `ProjectWorkspaceUpdateResult` (saved workspace, `cleanupFailures`,
    `completedRemovals`). Order: validate → materialize additions (ledger rollback on
    failure, occupied names seeded with every current entry path) → write metadata →
    best-effort cleanup of removals with `deleteFiles`. Cleanup deletes a symlink, a
    remote clone folder, or runs `git worktree remove --force` against the recorded source;
    paths outside the root and entries without a source are reported, never deleted.
    Branch deletion is left to the caller through `completedRemovals`.
  - `encodeMetadata(_:preservingUnknownKeysIn:)` merges the encoded model over the
    existing JSON so unknown top-level and per-entry keys (matched by `id`, falling back
    to `path` / `name`) survive; known keys always follow the model.
- **Editor reducer** — `supacode/Features/Repositories/Reducer/WorkspaceEditorFeature.swift`
  - `State.mode` (`.create` / `.edit(repositoryID:)`), `existingRepositories`
    (`WorkspaceEditorExistingRepository`: entry, editable name/role, `removal` with
    `deleteFiles` / `deleteBranch`), `repositories` (new rows, unchanged), `description`,
    `taskLinks` (`WorkspaceTaskLinkDraft`), `isSaving`. `init(editing:rootURL:repositoryID:...)`
    pre-fills from a `ProjectWorkspace`.
  - `submitButtonTapped` validates (title, ≥1 remaining member, new-row plans) and emits
    `Delegate.submit(.create(draft))` or `.submit(.update(request))`; `updatedAt` comes
    from `@Dependency(\.date.now)`.
- **Repositories wiring** —
  `supacode/Features/Repositories/Reducer/RepositoriesFeature+WorkspaceEditing.swift`
  - `WorkspaceEditingAction`: `promptRequested(id, removingChildID:)` re-reads the metadata
    from disk in an effect and presents the editor (`promptLoaded`), optionally pre-marking
    a child (sidebar row id = working-directory path); `saveWorkspace` runs
    `ProjectWorkspace.update`, deletes opted-in branches through
    `gitClient.deleteLocalBranch` (protected branches skipped), then `workspaceSaved`
    reloads repositories, toasts "Workspace saved", and alerts on cleanup failures;
    `workspaceSaveFailed` keeps the sheet open with the message (or alerts when the sheet
    is already gone). Save is deliberately not cancellable.
  - `RepositoriesFeature.State.workspaceEditor` replaces `workspaceCreationPrompt`;
    `RepositoriesFeature+CoreReducer.swift` routes the editor delegate by mode.
- **Views** — `supacode/Features/Repositories/Views/WorkspaceEditorView.swift` (shared form;
  existing rows with Name/Role, provenance line, Move Up/Down, trash → inline removal
  options + Undo; new rows gain Role; Description and Task Links sections; Cancel disabled
  while saving in edit mode), `WorkspaceDetailView.swift` (Edit Workspace… button,
  clickable http(s) task links), `WorkspaceChildRowsView.swift` (Edit Workspace… /
  Remove from Workspace…), `RepositorySectionView.swift` (header menu item),
  `supacode/Features/Settings/Views/RepositorySettingsView.swift` (Edit Workspace… button
  replacing the read-only note).
- **Other entry points** — `RepositorySettingsFeature.Delegate.editWorkspace` →
  `SettingsFeature.Delegate.editWorkspace` → `AppFeature` surfaces the main window and
  sends `promptRequested`; `CommandPaletteItem.Kind.editWorkspace` (offered when the active
  repository is a workspace); `supacode/Commands/WorktreeCommands.swift` "Edit Workspace...".
- **Tests** — `supacodeTests/ProjectWorkspaceUpdateTests.swift`,
  `supacodeTests/WorkspaceEditorFeatureTests.swift`,
  `supacodeTests/RepositoriesFeatureWorkspaceEditingTests.swift`,
  `supacodeTests/AppFeatureWorkspaceEditingTests.swift`; existing creation tests updated
  for the rename and the new submission enum.
- **Docs** — `docs/components/workspaces.md` (Editing a workspace, metadata no longer
  read-only, minimum count), `docs/components/command-palette.md`,
  `docs/components/repositories-and-worktrees.md`, `docs/components/settings.md`.

## Deviations from plan

- The plan listed "settings-originated request through `AppFeature`" as a test; it exists,
  and `AppFeature` uses `appLifecycleClient.surfaceMainWindow` rather than a new client.
- `.dismiss` on the sheet cannot be blocked while saving: TCA's `ifLet` clears the child
  state before the reducer sees the action. The Cancel button is disabled instead, and a
  failure arriving after the sheet is gone is shown as an alert. Not a behavior gap, but
  the plan implied the reducer could refuse a dismissal.
- Unknown-key preservation also matches entries without an `id` (by `path`, then `name`),
  which the plan did not spell out.

## Open questions

- Reordering is Move Up / Move Down buttons; drag reordering inside the sheet was not
  attempted. Revisit if the list grows beyond a handful of members.
