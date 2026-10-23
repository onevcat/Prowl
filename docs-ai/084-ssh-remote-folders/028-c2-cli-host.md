# 084.028 — Remote folders in the CLI (C2)

## Context

A3b and A6e ([006](006-a3b-cwd-matching-cli.md), [014](014-a6e-delete-forwards.md)) skip remote
repositories in the CLI worktree contexts. Without a host field, a local path could match
a worktree on another host. A4a ([007](007-a4a-capability-enforcement.md)) added the CLI and
workflow refusals for remote targets, which those contexts made unreachable. The plan's
"CLI and Mirror" section and the ID rules (D1) give C2:

- the `host` field;
- a local-only `prowl open`;
- the `alias:/path` selector;
- the workflow `rootKey`;
- router-level regressions for these refusals.

## Change

### `host` in the payload

- `ListCommandWorktree` gains an optional `host` (`ListCommandHost`: `profile_id`, the
  lowercase UUID, and `label`, the profile's alias). It is encoded only for a remote
  folder, so local output is byte for byte the same (additive).
- `displayPath` is `label:path` for a remote folder. Text output shows it.
  `ListCommandHost.displayPath(_:host:)` is the one spelling, used by the payload and by
  both selector matchers.
- `ListRuntimeSnapshotBuilder.orderedWorktreeContexts` now includes remote repositories,
  with `host`. The contexts feed `prowl list`, target resolution, `prowl agents`, tab
  creation and workflows. A label falls back to the UUID when the profile is missing.
- The Mirror worktree catalog leaves remote folders out until C3. Its launch picker shows
  a name and a path, and a remote folder cannot launch yet.

### Selector

`WorktreeContext.matches` and `TargetResolutionSnapshot.Worktree.matches` give one rule for
`--worktree` and the tab creation target:

- the encoded ID;
- the name;
- the path, for a local worktree only;
- `label:path`, for a remote folder.

A bare path therefore never matches a worktree on another host. The CLI process has no
host profiles, so the label is resolved in the app. For tab creation, a name that a local
worktree shares with a remote folder means the local one, which can open a tab; before C2,
the remote folder was not listed at all.

### Refusals that are now reachable

A remote folder has no terminal until C3, so it has no tab or pane and target resolution
does not list it. `TargetResolutionSnapshot.remoteFolders` keeps the remote contexts.

- A selector that names a remote folder by its ID or `label:path` (`matchesExactly`) gets
  "Worktree '…' is a remote folder: terminals cannot open in remote folders yet." instead
  of "not found". A name gets "not found", because it could mean a local worktree that has
  no tab.
- `workflow run` with `--worktree` or `-t` naming a remote folder returns
  `REMOTE_AGENT_UNSUPPORTED`, "Workflows cannot run in a remote folder yet."
  (`WorkflowCommandHandler.resolveSource`, only after the resolver found nothing, so a
  local worktree with the same name still runs). `WorkflowRunAdmission` now refuses a
  remote source before its path reaches the local catalog or the preference key.
- `create tab` in a remote folder returns `CREATE_FAILED`, "Terminals cannot open in
  remote folders yet.", before the `--path` check (a host path this Mac cannot check) and
  before any creation; the C1c backstop in `createTab` stays behind it. `tab create`
  resolves only worktrees with a pane, so it reports the remote reason as not found.
- `create tab --profile` keeps the A4a refusal: the tab target now resolves, the Profile
  preparation refuses before a terminal state exists, and the CLI maps it to
  `CREATE_FAILED` "Agent Profile “…” cannot launch in a remote folder yet." Each step has
  its own test: target resolution here, `profileLaunchInARemoteWorktreeIsRefusedBeforeAStateExists`,
  and the CLI message test.

### `prowl open`

`ProwlApp.resolveOpenPath` already matches local repositories and worktrees only (A3b), and
the new root path uses a local URL. A path never resolves to a remote folder. No change.

### Workflow history `rootKey` (deferred)

Admission refuses every remote source before a run directory exists, so no remote root
reaches `WorkflowHistoryStorage.rootKey`. A host-aware key has no caller until remote
workflows exist. It must then go through one helper for every key site (the run
directories, the run store and its cleanup), so that runs are never written and pruned
under different keys. Deferred to the slice that runs workflows in remote folders.

### Mirror

No protocol change. The worktree catalog lists local worktrees only until C3, and the pane
directory stays the host path: remote panes exist only after C3.

## Tests

`CLIRemoteFolderTests`:

- remote folders join the contexts with their host;
- the `host` field is additive and round-trips;
- a bare path matches the local worktree only, `label:path` matches the remote one, and a
  shared name means the local worktree (checked red);
- a remote folder selector gets its reason by ID or `label:path`, and a name gets "not
  found" (checked red);
- `create tab` in a remote folder fails with the reason before the path check and creates
  nothing (checked red).

`WorkflowCommandHandlerTests/aRemoteFolderSourceIsRefusedWithTheRemoteCode`: `--worktree`
and `-t` are refused, and a shared name resolves the local worktree (checked red).

## Not in this slice

- The target payloads of `send`, `read` and the other commands carry no `host`. They need
  a remote pane, which comes with C3.
- `prowl agents` project paths for remote panes come with C3.
