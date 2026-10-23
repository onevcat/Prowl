# 084.024 — The remote refresh cadence (B3f)

## Context

B3e ([023](023-b3e-load-through-host.md)) loads remote folders through their host. After
that load, nothing updated a remote repository:

- The local monitors of `WorktreeInfoWatcherManager` watch files on this Mac. They have no
  remote counterpart (A6b, [011](011-a6b-watcher-locations.md)).
- `RepositoryHost.branchName` and `lineChanges` return nil for a remote worktree. The plan
  leaves both to the batched refresh (B3b, [020](020-b3b-remote-repository-host.md)).
- Pull request refresh skipped remote repositories, because their GitHub remotes had no
  source until B3b (A6d, [013](013-a6d-pull-requests-by-location.md)).

The "Remote refresh (D4)" section of the plan asks for these things:
- the focused worktree polls faster than the others;
- a failed poll keeps the last state and shows the host as unreachable.

Two items in the open questions are related: the polling intervals, and the backoff while
a host is unreachable.

## Change

No remote folder exists before C1. Exposure: none.

### The cadence (`RepositoriesFeature+RemoteRefresh.swift`)

Each loaded remote git repository is polled with the batched refresh (B3a), on the
feature's clock. The schedule lives in the reducer, not in the watcher manager: a poll
returns data that the reducer applies, and `TestClock` drives it in tests.

- **Intervals.**
  - The repository of the selected worktree polls every 10 s.
  - Every other remote repository polls every 60 s.
  - Selecting a remote worktree refreshes its repository at once (`AppFeature` sends
    `remoteRepositoryRefreshDue`).
- **Backoff.** After a failed poll, the interval doubles for each failure in a row, up to
  300 s. Examples: 10 s → 20 s → 40 s for the focused repository; 60 s → 120 s → 240 s →
  300 s for the others. The first good poll resets it.
- **Schedules.** `syncRemoteRefreshSchedules` runs after every load:
  - It starts the cadence of new remote git repositories.
  - It cancels the timer, the poll and the connection hold of the repositories that left.
  - It clears their failure count, fingerprint and unreachable mark.
  - Remote plain folders have nothing to refresh.
- **One poll at a time.** A poll that is due while another one for the same repository
  runs does nothing. A due poll also cancels its timer, so a refresh on selection does not
  run twice.
- **Pause.** Polls pause while the app is inactive or in the background (`AppFeature`
  sends `setRemoteRefreshActive(false)`, next to cancelling the local periodic refresh).
  Their timers and running polls are cancelled. When the app is active again, every remote
  repository polls at once. Connection holds stay.

### Reloads keep loaded remote repositories

`AppFeature` reloads every repository every 30 s while it is active, and other actions
reload too, such as a worktree creation. Without a change, each reload would ask every
remote host again. It would also wait for a host that is down until the B3e deadline,
and drop that repository from the list, against "a failed poll keeps the last state".

So after the first live load, `reloadRepositories` passes the loaded remote repositories to
the load (`knownRemoteRepositories`), and the load keeps them as they are. The cadence
keeps them current. A remote entry that is not loaded yet still loads through its host,
for example an entry that a failed load left out, or one that was just added. The first
live load after launch, or after the snapshot restore, asks every host.

### Applying a poll

A good poll is applied as the local monitors' events are applied:

- **Worktree list.** When the worktree IDs differ from the repository's, the poll replaces
  the repository's worktrees and sends `repositoriesLoaded` with the current list, roots
  and failures (`State.currentLoadFailures`). This is what a load would bring. A reload
  would keep the repository as it was (see above).
- **Branches.** Otherwise, a worktree whose branch changed is renamed
  (`updateWorktreeName`).
- **Line counts.** When the repository observes line diffs, changed line counts update the
  row (`updateWorktreeLineChanges`). The untracked file count fills
  `skippedUntrackedFileCount` (B3a). `.lineCounts` is now available for remote folders,
  next to worktree creation.
- **Remote URLs.** A changed fingerprint runs the same path as a local remote
  configuration change: a forced pull request refresh and code host detection
  (`remoteConfigurationChanged`, now shared). The first poll only records the fingerprint.

A failed poll changes nothing else in the repository. Only its failure count changes, and
its unreachable mark (`unreachableRepositoryIDs`, as at load):
- the mark is set when the host did not answer;
- the mark is cleared when the host answered with another error, such as a missing folder;
- the mark is also cleared by the next good poll.

The poll's error goes to the log (`ProwlLogger("RemoteRefresh")`).

When a repository leaves the cadence, its failure count and fingerprint are cleared. Its
unreachable mark stays, because the load that removed it set that mark itself
(`recordLoadFailures`).

### Connection holds

Each loaded remote repository holds a lease on its host's connection, through
`RemoteRepositoryHostClient.holdConnection`, until it leaves the list.

- The live client resolves the profile with `ssh -G`, checks its authority as each leased
  command does (B3b), and acquires the registry lease.
- With a lease held, the per-command leases of the lane reuse the open connection instead
  of connecting each time.
- `RemoteConnectionHold.release` ends the lease once.
- A held owner lives long, so a failed read of the login `PATH` is no longer kept for the
  owner's whole life. It is kept for `Configuration.loginPathRetryInterval` (60 s), then
  the next command reads it again. Concurrent callers still share one read, and a good
  read is kept.
- The hold resolves the profile's connection key when the repository joins the cadence.
  When the user edits or rebinds the profile, C1's rebind flow restarts the holds of its
  repositories. Until then, the old hold stays. Commands still resolve their key for each
  command, so they reach the right target.

### Pull requests for remote folders

`RepositoryLocation.refreshesPullRequests` is gone. The pull request cadence of the watcher,
forced refreshes and the request itself now run for remote repositories too. A remote
worktree counts in the unfocused sweep's request budget as a local one does. A repository
marked unreachable gets no pull request refresh: its cadence backs off, and the request
would only wait for the host. Their GitHub
remotes come from the host (`RepositoryHost.githubRemoteInfos`, B3b), and `gh` runs on
this Mac with an explicit repository (A5a). The `gh repo view` fallback still runs only
for a local repository, because it reads a working directory on this Mac.

### Answered open questions

- **Polling intervals:** 10 s for the selected worktree's repository, 60 s for the others.
- **Backoff:** doubling up to 300 s while polls fail.

## Tests

`RemoteRepositoryHostTests` drives the reducer with `TestClock`, through a lane that runs on
this Mac with real git:

- the delays for focused and background polls, and the backoff with its cap;
- a poll applies a renamed branch and edited lines from the host. The repository holds
  one connection. When it leaves the list, the polls stop and the hold is released;
- a failed poll keeps the repository as it was and marks it unreachable. The next poll
  waits twice as long, and a good poll clears the mark and the failure count;
- a new remote URL refreshes pull requests, and a new worktree on the host updates the
  repository through `repositoriesLoaded`;
- a reload keeps a loaded remote repository without asking its host, and still loads a
  new remote entry;
- a host that answers with another error clears a stale unreachable mark;
- a repository that left the cadence through an unreachable load keeps its mark;
- polls pause while the app is inactive and run at once when it is active again; an
  unreachable repository gets no pull request refresh.

`RemoteCommandLaneTests`: a failed login `PATH` read is tried again after the retry
interval, and a good one is kept; concurrent callers still share one read.
`WorktreeInfoWatcherManagerTests`: a remote repository gets the pull request cadence and no
local monitors, and its worktree counts in the unfocused budget.
`AppFeatureTerminalSetupScriptTests`: selecting a remote worktree refreshes its repository.

`RepositoryHostTests`: a remote repository's pull request refresh now runs, and the local
`gh repo view` fallback never runs for it. `RepositoryFeatureAvailabilityTests`: line
counts and worktree creation are the remote features.
