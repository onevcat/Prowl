# 019.007 — Manual Branch Choice & Automatic Cleanup

## Context

The worktree deletion safety change introduced one global setting that served two
different behaviors: the initial value of the manual deletion checkbox and branch
deletion during merged/expired automatic cleanup. The shared meaning made the
Settings label difficult to explain and made manual deletion depend on whether Prowl
had created the worktree.

## Change

- Manual deletion now reads `lastDeleteBranchOnManualWorktreeDeletion` from
  `@Shared(.appStorage(...))`. It defaults to `false`, is written only after the user
  confirms a manual deletion, and is reused for later manual confirmations regardless
  of worktree provenance. Dismissing the confirmation does not update it.
- Automatic cleanup now uses the global setting
  `deleteBranchOnAutomaticWorktreeCleanup`, defaulting to `false`. It controls branch
  deletion for merged-worktree deletion and expired archived-worktree cleanup, while
  the existing `prowlCreatedWorktreeIDs` guard remains in place.
- `GlobalSettings` decodes the former `deleteBranchOnDeleteWorktree` key as a legacy
  fallback. The old value migrates to the automatic-cleanup setting; the new manual
  choice starts unchecked instead of inferring a previous manual selection.
- Settings and agent-facing worktree documentation now describe the two behaviors
  separately.

## Refs

PR pending.

## Current state

- Settings model and persistence: `supacode/Features/Settings/Models/GlobalSettings.swift`.
- Settings UI: `supacode/Features/Settings/Views/WorktreeSettingsView.swift`.
- Manual and automatic lifecycle paths:
  `supacode/Features/Repositories/Reducer/RepositoriesFeature+WorktreeLifecycle.swift`,
  `supacode/Features/Repositories/Reducer/RepositoriesFeature+GithubIntegration.swift`,
  and `supacode/Features/Repositories/Reducer/RepositoriesFeature+CoreReducer.swift`.
- Behavior coverage is in `supacodeTests/RepositoriesFeatureTests.swift`,
  `SettingsFeatureTests.swift`, and `SettingsFilePersistenceTests.swift`.
