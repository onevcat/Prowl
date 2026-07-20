# 042.003 — Workspace Bootstrap Runtime Controls

## Context

Workspace bootstrap has two distinct ownership layers:

- User-level Script Profiles define executable content in `~/.prowl/script-profiles.json`.
- `.prowl/workspace.json` binds ordered profile IDs to child repositories and records the
  creation-time policy (`run_on` and `required`).

The workspace creation sheet already owns that binding decision. The repository settings
page later duplicated it with Add, remove, and reorder controls beside manual Run buttons.
That made a mostly one-time initialization policy look like ongoing repository settings,
and allowed an operational screen to rewrite the workspace manifest without a material
post-creation use case.

The executor already writes one log per invocation under `.prowl/bootstrap-runs/` and the
latest result for each child repository to `.prowl/bootstrap-state.json`. The settings UI
does not currently read or expose that runtime state.

## Decision

Workspace bootstrap binding is a creation-time decision. After creation, repository
settings treats bootstrap as runtime state and does not edit the binding.

- Keep profile selection, ordering, create-time execution, and Required in
  `WorkspaceCreationPromptView`.
- Remove Add Script, remove, and reorder controls from existing child repository cards in
  `RepositorySettingsView`.
- Render the profile IDs already bound in `.prowl/workspace.json` as read-only rows.
- Keep a Run action for each bound profile. A manual invocation is transient and must not
  patch `.prowl/workspace.json`.
- Show the latest repository-level bootstrap result: succeeded or failed, completion time,
  profiles included in that invocation, and an action to open its log.
- Show `Never run` when no runtime state exists for that child repository.
- If a referenced local profile is missing, preserve and display its ID, disable Run, and
  explain that the profile must be restored in Settings > Scripts.
- Linked children remain non-runnable because bootstrap would mutate the shared source
  checkout.

The first version intentionally shows only the latest result per child repository. Log
files remain independent per invocation, but the product does not add history retention,
indexing, or cleanup policy until repeated-run history has a demonstrated use case.

## Data Flow

`ProjectWorkspaceBootstrapExecutor` remains the only writer of bootstrap runtime state.
Repository settings loads `.prowl/bootstrap-state.json` when a workspace settings screen
appears and refreshes the affected child entry after a manual run completes.

The UI reads the saved `ProjectWorkspaceBootstrapRepositoryState` keyed by the stable child
repository ID. The stored `last_script_ids` identifies which bound profiles participated;
`last_log_path` resolves relative to the workspace root. Missing, malformed, or stale state
must not prevent the rest of workspace settings from loading.

Manual Run continues to construct a one-profile bootstrap request from the saved workspace
entry and the selected profile ID. It runs with the child repository as the working
directory, uses the executor's existing timeout and environment behavior, writes a new log,
then reloads runtime state. The operation does not pass through workspace metadata save.

## UX

Each existing child repository card contains a compact Bootstrap section only when the
workspace manifest binds at least one profile. The section contains:

- a latest-result summary (`Never run`, `Succeeded`, or `Failed`) with completion time;
- a View Log action when the latest record has a resolvable log;
- one read-only row per bound profile, preserving manifest order, with a Run action;
- running feedback and disabled duplicate execution for the active repository/profile.

A child with no binding shows no bootstrap section. The page therefore avoids repeating
an empty configuration block for repositories where bootstrap is irrelevant.

## Error Handling

- State-file absence or decoding failure degrades to `Never run` and is logged; it does not
  block workspace metadata editing.
- A missing profile disables only that row and does not hide the manifest reference.
- A missing log leaves the saved status visible but disables View Log.
- Manual execution failure updates the latest state and leaves the generated log available.
- Running one profile does not disable Run for unrelated child repositories.

## Verification

- Reducer tests cover state loading, malformed or missing state, refresh after manual run,
  and no workspace metadata mutation from Run.
- View/state tests cover hidden empty sections, read-only bound rows, missing-profile
  presentation, latest success/failure, log availability, and linked-child disabling.
- Existing bootstrap executor tests continue to cover success, failure, log creation, and
  latest-state persistence.
- Run `make build-app` after implementation.

## Alternatives

- **Keep full binding management in repository settings.** Rejected because it duplicates
  the creation flow and promotes an initialization declaration to routine mutable state.
- **Move workspace assignment into Settings > Scripts.** Rejected because Script Profiles
  are user-level executable definitions; making them mutate workspace manifests reverses
  the ownership direction and couples global settings to individual workspaces.
- **Add complete run history now.** Deferred because the current executor and user need are
  satisfied by latest status plus its log; history requires retention and cleanup policy.
- **Remove `.prowl/workspace.json` bootstrap metadata after creation.** Rejected because the
  manifest remains the durable mapping from child repositories to local profile IDs and is
  required to render the manual Run entry points.

## Refs

- Planned on 2026-07-20; implementation ref to be added after completion.
