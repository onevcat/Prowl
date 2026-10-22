# 084.007 — Location-based availability and its enforcement (A4a); A4 split

## Context

Slice A4 of [000-plan.md](000-plan.md), decision D3: capabilities gain a location
dimension and reasons, and the check runs in the views, the command palette, the reducer
and the admission boundary. A sweep of the entry points found too much for one PR:

- Profile launch has three admission paths (UI, CLI, workflows). They meet only in
  `WorktreeTerminalManager.prepareAgentProfileLaunch`.
- Finder and Copy Path run `NSWorkspace` directly in views (sidebar rows, workspace
  children, Active Agents rows). No reducer sees them.
- The command palette can only leave items out. It has no disabled row with a reason.

A4 is split. A4a (this PR) adds the model and enforces it at the reducer and the
launch boundary. A4b adds the disabled controls with tooltips and the palette
filtering, and routes the view-level actions through the reducer. Decided 2026-10-23
in unattended mode.

## Change

### Model (`App/Sources/Domain/RepositoryFeature.swift`)

- `RepositoryFeature` lists the features of D3 that have a call site:
  - `diff`: the diff window, external diff tools and outgoing changes, which all open a
    `DiffTarget`;
  - line counts;
  - icon detection;
  - open in an app;
  - Finder;
  - workspace;
  - archive script;
  - Profile launch.

  Clone is not a case. "Clone to a remote folder" concerns the destination, not an
  existing repository, and no call site is scoped to a repository. It comes with the
  remote add flow (C1).
- `RepositoryLocation.availability(of:)` returns `FeatureAvailability`, either
  `.available` or `.unavailable(FeatureUnavailableReason)`.
  - Every feature is available locally.
  - Remote, every feature is unavailable, with a per-feature localized message for
    tooltips and toasts. CLI and workflow errors use fixed English, like the other CLI
    errors.
- `Repository.availability(of:)` and `Worktree.availability(of:)` read the
  repository location.
- The kind-based flags stay in `Repository.Capabilities`.

### Enforcement

| Feature | Where | Effect for a remote target |
| --- | --- | --- |
| Profile launch | `AppFeature.launchAgentProfile` (Agents menu, palette) | Warning toast with the reason; nothing is sent |
| Profile launch (backstop) | `WorktreeTerminalManager.prepareAgentProfileLaunch` and `launchAgentProfile`, before a terminal state exists | `AgentProfileLaunchError.unavailable(reason)` |
| Profile launch, CLI | `CLIProfileLaunchFailure.creation` | `CREATE_FAILED`, "Agent Profile “…” cannot launch in a remote folder yet." |
| Workflows | `WorkflowRunAdmission`, right after the source worktree resolves, before the run scope reads it | `REMOTE_AGENT_UNSUPPORTED`, "Workflows cannot run in a remote folder yet." The run history and role launches are rooted in the local worktree directory (C2) |
| Profile launch, workflow role | `WorkflowRuntimeComposition`, before the cwd is read (a second line behind admission) | The role fails |
| Diff window, external diff, outgoing changes | `selectedDiffTargetID` is nil; `diffTarget(for:)` returns nil | The menu item is disabled (existing `selectedDiffTargetID == nil` rule) and the palette item is hidden; every diff path is a no-op |
| Open in an app, Finder | `AppFeature` `.openWorktree`, `.openActionSelectionChanged`, `.openActionResetToAutomatic` | Toast with the reason. The open-action selection and pin stay unchanged |
| Copy Path (palette) | `.copyPath` | Copies `location.path`; local copies are unchanged |
| Line counts | `.filesChanged` | No `git diff` |
| Icon detection | `iconDetectionEffects` | Skipped. Remote repositories are filtered out before the 8-per-add limit |
| Archive script | `.archiveWorktreeConfirmed` | The archive proceeds without the script, with a warning toast. The script would run as a local process in the remote path |
| Workspace | `workspaceCreationCandidates` (creation and editing) | Remote folders are not offered |

Each check runs before the first read of a local forward (`rootURL`,
`workingDirectory`, `repositoryRootURL`) inside the function that owns it. For the
reducer paths and the Agents menu and palette, that is the whole path.

The CLI and workflow refusals are not reachable from their production entry points
yet. Before a CLI command or a workflow admission reaches them, the router builds the
worktree contexts (`ListRuntimeSnapshotBuilder.orderedWorktreeContexts`, also used by
`TargetResolutionSnapshotBuilder`). That builder reads forwards, and A3b left it to C2
together with the `host` field. Once C2 makes the contexts safe for remote worktrees,
these refusals take effect. C2's acceptance includes router-level regressions:
`create tab --profile` in a remote worktree returns the fixed-English `CREATE_FAILED`
without a surface, and `workflow run` from a remote worktree returns
`REMOTE_AGENT_UNSUPPORTED`.

### Tests

- `RepositoryFeatureAvailabilityTests`:
  - local and remote availability, and the reason text;
  - no diff target for a remote worktree, while a local worktree keeps one;
  - workspace candidates;
  - no line counts on `.filesChanged`;
  - no icon detection.
- `AppFeatureAgentProfileTests`:
  - a remote Profile launch shows the reason and sends nothing;
  - a remote `.openWorktree(.finder)` shows the reason;
  - `.openActionResetToAutomatic` does not trap.
- `WorktreeTerminalManagerTests.profileLaunchInARemoteWorktreeIsRefusedBeforeAStateExists`.
- `CLILifecycleCommandHandlerTests`: the CLI message for `.unavailable`.

The remote repositories come from the shared `RemoteRepositoryFixtures`. Both kinds are
covered: a git repository selected through its worktree, and a plain folder selected
through `terminalWorktree`. The reducer tests run a `TestStore` with them in state, which
also shows that these paths reach no forward. The archive branch has no test: after it,
`.archiveWorktreeApply` removes the worktree through git with a forward, which A5 moves
to the host.

## Not in scope: selecting a remote folder

Selecting a remote folder and changing settings still read local forwards for
repository settings (`selectedWorktreeChanged`, `settingsChanged`). Those are settings
reads, not feature entry points. They can only be reached once remote folders exist
(C1), and A6 deletes the forwards, so the compiler lists every remaining read before
then.

## Deviations from the plan

- The plan's signature was `availability(_:kind:location:)`. The kind rules stay in
  `Capabilities`, so the new function takes only the location. No new feature depends
  on the kind.
- The plan keeps cached facts (remote tools, local `gh`) apart from runtime
  reachability. No fact changes availability yet, so they come with B1–B3.
- Archive script: the archive is not refused; it skips the script. The non-goals list
  the script as unavailable, not archiving.

## Left for A4b

- Disabled controls with the reason as tooltip: the Open split button, the Agents
  popover rows (dimmed today), the diff row button and context menu, the workspace
  actions.
- Palette filtering for the remaining items.
- `NSWorkspace` calls in views, routed through the reducer: Finder in `WorktreeRowsView`,
  `RepositorySectionView`, `WorkspaceChildRowsView` and `ActiveAgentRowSupport`, and
  Copy Path.
- `RepositorySettingsFeature` has its own `Capabilities` switch built from the kind,
  without a location.
