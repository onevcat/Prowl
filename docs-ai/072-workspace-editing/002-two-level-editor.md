# 072.002 — Two-level workspace editor

## Context

The first editor (001) put everything on one scrolling sheet: title, folder, description,
task-link rows, and one full configuration block per repository (name, role, folder,
source path, checkout mode, branch, base ref). onevcat's verdict after the Debug pass: it is
the most complex panel in the app, has no guidance, and the decision that matters most
(how each repository is materialized) sits at the bottom of a long form. Agreed direction:
no panel may have more than about five interactive spots; metadata and per-repository
configuration live on separate panels.

## Decision

- **Noun:** *Repository* (`Add Repository…`). The metadata key is `repositories`, the
  sidebar and CLI say repository; "worktree" is only one of three checkout kinds and
  "project" has no meaning in Prowl.
- **Panel A — Workspace** (create and edit): one guidance sentence, then Title,
  Description (one multi-line field), Task Links (one multi-line field, one link per
  line; no dynamic rows), Folder shown as the derived path with a quiet **Change…**, the
  repository list, and **Add Repository…**. The list explains what Create / Save will do
  per row ("Link → shares the live checkout at …", "New branch X from Y → worktree",
  "Clone … @ ref"), with hover Edit / Remove, Undo for staged removals, and Move Up / Down
  in the row's context menu. A footer line summarizes the outcome; Create is disabled
  with no repository.
- **Panel B — Add / Edit Repository**, one repository at a time, replacing Panel A inside
  the same sheet (Back returns; no stacked sheets). Step 1 picks the source: Opened in
  Prowl, Local folder (open panel), Remote URL (branches load automatically on Return or
  after a short pause; no Load button). Step 2: Name, Role, Checkout as a segmented
  **Link / New branch / Existing branch** control, the one field that mode needs
  (branch + base, or existing ref), and an **Advanced** disclosure for the folder inside
  the workspace. Editing an existing member shows Name / Role, a read-only source and
  checkout summary, and a destructive **Remove from Workspace…** that reveals the file /
  branch deletion opt-ins.
- Description and Task Links are not folded behind a disclosure (three fields is fine).

## Change

- `WorkspaceEditorFeature` keeps the workspace-level state (title, description,
  `taskLinksText`, root path, existing / added members, `memberOrder`) and presents
  `WorkspaceMemberEditorFeature` for one row. Per-row actions, the remote prompt, and
  base-ref loading move into the member editor, which loads refs itself through
  `GitClientDependency`; `RepositoriesFeature` no longer relays `refreshBaseRefs`.
- `WorkspaceEditorView` renders Panel A and swaps in `WorkspaceMemberEditorView`
  (Panel B) while a member is being edited.
- Tests: the row-level creation tests move from `RepositoriesFeatureTests` to
  `WorkspaceMemberEditorFeatureTests`; `WorkspaceEditorFeatureTests` covers the
  workspace-level flow and the member commit / remove / reorder wiring.
- `docs/components/workspaces.md` describes the two panels.

## Refs

- PR #830 (same PR as the first editor; the redesign supersedes its sheet before merge).
