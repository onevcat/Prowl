# 019 — Worktree Creation & Lifecycle: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-04-07 | Base-ref options include local branches alongside upstream refs (fork issue #166) | PR #167 |
| 2026-04-12 | Optional git fetch before worktree creation: `fetchOriginBeforeWorktreeCreation` global setting (default on), per-creation toggle in the prompt, longest-prefix remote matching, non-blocking failures; fetch progress stage (renamed `fetchingOrigin` → `fetchingRemote` on the same branch, `5f866b3f`) (fork issue #176) | PR #189 |
| 2026-04-14 | Merged worktree action picker: `MergedWorktreeAction?` (do nothing / archive / delete) replaces the auto-archive boolean, with legacy migration (fork issue #175) | PR #190 |
| 2026-04-14 | Copy flags + PR merge strategy promoted to global defaults with per-repo optional overrides shown as "Global (current value)" pickers (fork issue #178; upstream overlap `ce214902` noted in the 2026-04-08 review) | PR #192 |
| 2026-05-09 | Browser-style worktree history navigation (`⌘⌥[` / `⌘⌥]`), disabled while Shelf/Canvas is active (upstream port, 2026-05-08 batch) — see [002-worktree-history-navigation.md](002-worktree-history-navigation.md) | PR #260 |
| 2026-05-30 | Deletion made explicit and safe: confirmation sheet with branch-deletion toggle, Prowl-created worktree tracking, `-d` before confirmed `-D`, default-branch protection — see [003-safe-branch-deletion-and-cleanup.md](003-safe-branch-deletion-and-cleanup.md) | PR #375 |
| 2026-06-03 | Failed-cleanup hardening: exact porcelain path match, `.git`-metadata check before relocation, no branch deletion from failed-creation cleanup — see [003-safe-branch-deletion-and-cleanup.md](003-safe-branch-deletion-and-cleanup.md) | PR #383 |
| 2026-06-08 | Terminal focused after next/previous and history worktree navigation (port of upstream #371, reimplemented on `pendingTerminalFocusWorktreeIDs`) — see [002-worktree-history-navigation.md](002-worktree-history-navigation.md) | PR #419 |
| 2026-06-08 | Advanced section in the New Worktree dialog: per-creation worktree name + parent folder overrides, live destination preview, applied via `wt sw --path` (port of upstream #351, GUI only) — see [004-advanced-placement-overrides.md](004-advanced-placement-overrides.md) | PR #424 |
| 2026-06-09 | Visible labels + caption for the Advanced fields (TextField labels are not rendered under `.roundedBorder`) | PR #427 |
| 2026-06-27 | On-device Foundation Model branch-name suggestion added to the same dialog | PR #518 (owned by [044](../044-foundation-model-branch-names/000-plan.md)) |
| 2026-06-28 | Add to Prowl popover redesign: drop zone, Browse, Clone-from-URL form with clipboard prefill, Add Workspace; auto-select after add — see [005-add-to-prowl-clone.md](005-add-to-prowl-clone.md) | PR #520 |
| 2026-07-16 | Split manual branch-choice persistence from automatic branch cleanup; retain legacy setting migration and Prowl-created safety guard — see [007-manual-delete-choice-and-automatic-cleanup.md](007-manual-delete-choice-and-automatic-cleanup.md) | PR #591 |

## Outcome & current state (as of 2026-07-16)

- **Git plumbing** — `supacode/Clients/Git/GitClient.swift`: `branchRefs(for:)` returns
  local + upstream refs; `deleteLocalBranch(_:_:force:)` backs both `-d` and confirmed
  `-D` deletion; worktree removal requires an exact `git worktree list --porcelain` path
  match and only relocates directories containing `.git` metadata
  (`relocateWorktreeDirectory`); the create path appends `--path` for placement
  overrides. `GitRemoteMatcher` (in `supacode/Clients/Git/GitClientTypes.swift`) does the
  longest-prefix base-ref → remote match.
- **Creation flow** —
  `supacode/Features/Repositories/Reducer/RepositoriesFeature+WorktreeCreation.swift`:
  threads `fetchRemote` (prompt value, falling back to
  `settingsFile.global.fetchOriginBeforeWorktreeCreation`), sets the `.fetchingRemote`
  stage of `WorktreeCreationStage` (`supacode/Domain/WorktreeCreationProgress.swift`),
  and registers created worktrees in the `@Shared(.appStorage)`
  `prowlCreatedWorktreeIDs` list.
- **Prompt** — `supacode/Features/Repositories/Reducer/WorktreeCreationPromptFeature.swift`
  + `supacode/Features/Repositories/Views/WorktreeCreationPromptView.swift`: fetch
  toggle, default-collapsed Advanced `DisclosureGroup` with labeled name/parent-folder
  fields, live path preview, and the branch-name auto-suggestion row
  ([044](../044-foundation-model-branch-names/000-plan.md)).
- **Placement** — `supacode/Features/Repositories/Models/WorktreePlacementOverride.swift`
  (leaf-name validation) and `supacode/Support/SupacodePaths.swift`
  (`resolvedWorktreeDirectory` / `previewWorktreeDirectory`).
- **Settings** — `supacode/Features/Settings/Models/GlobalSettings.swift` holds
  `mergedWorktreeAction: MergedWorktreeAction?` (default `nil`),
  `fetchOriginBeforeWorktreeCreation` (default `true`), `copyIgnoredOnWorktreeCreate` /
  `copyUntrackedOnWorktreeCreate` (default `false`), `pullRequestMergeStrategy`
  (default `.merge`); `supacode/Features/Settings/Models/MergedWorktreeAction.swift`;
  per-repo optionals in `supacode/Features/Settings/Models/RepositorySettings.swift`.
  UI: `supacode/Features/Settings/Views/WorktreeSettingsView.swift` (merged-action
  picker, copy-flag toggles, automatic-cleanup branch toggle),
  `GithubSettingsView.swift` (merge strategy), `RepositorySettingsView.swift`
  ("Global (…)" override pickers).
- **Merged-PR automation** —
  `supacode/Features/Repositories/Reducer/RepositoriesFeature+GithubIntegration.swift`
  switches on `state.mergedWorktreeAction`; `.delete` passes
  `deleteBranch: deleteBranchOnAutomaticWorktreeCleanup &&
  prowlCreatedWorktreeIDs.contains(id)`.
- **Deletion** —
  `supacode/Features/Repositories/Reducer/RepositoriesFeature+WorktreeLifecycle.swift`
  (manual last-choice persistence, delete + `ForceDeleteBranchRequest` flow) and
  `supacode/Features/Repositories/Views/DeleteWorktreeConfirmationView.swift`.
  Manual confirmation remembers only choices that were submitted; automatic branch
  cleanup remains separately controlled and restricted to Prowl-created worktrees.
- **History navigation** — stacks and `navigateWorktreeHistory` in
  `supacode/Features/Repositories/Reducer/RepositoriesFeature.swift` /
  `RepositoriesFeature+Selection.swift` (50-entry cap); menu commands in
  `supacode/Commands/WorktreeCommands.swift`.
- **Intake** — `supacode/Features/Repositories/Views/AddToProwlView.swift` and
  `CloneRepositoryView.swift`.
- **User docs** — `docs/components/repositories-and-worktrees.md` covers the fetch
  toggle, Advanced section, history shortcuts, and the Add popover.

## Deviations from plan

- PR #189's description names the progress stage `fetchingOrigin`; it was renamed to
  `.fetchingRemote` on the same branch before merge (`5f866b3f`). The settings key kept
  the original `fetchOriginBeforeWorktreeCreation` name while the UI says "Fetch remote".
- The 2026-04-08 decision to "prefer upstream's implementation where equivalent" for
  global defaults did not visibly replace the fork's code: the current tree matches the
  #190/#192 fork model (fork enum `MergedWorktreeAction`, fork settings shape).

## Open questions

- Whether the v0.8.1-era upstream sync actually reconciled `ce214902`/`4db25220` against
  the fork's #190/#192 (as the 2026-04-08 decision instructed) is not recorded in the
  ledger; the surviving implementation is the fork's, so the overlap appears to have been
  resolved in the fork's favor without an explicit note.
