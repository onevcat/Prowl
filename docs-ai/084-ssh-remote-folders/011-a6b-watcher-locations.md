# 084.011 — The worktree info watcher by location (A6b)

## Context

The host boundary of [000-plan.md](000-plan.md) says: "`observeChanges` wraps the five
local monitor roles (four classes in `WorktreeInfoMonitors.swift`) into one host stream
that keeps today's six watcher events; cadence logic stays in
`WorktreeInfoWatcherManager`."

Two facts from the code changed this design:

- **No second implementation of the monitors.** A remote repository gets its changes from
  the batched refresh of its host (D4, B3): one command per poll returns HEAD, line counts,
  the worktree list and a hash of the remote URLs. The local monitors (FSEvents, HEAD
  vnode, worktree registry, remote config) have no remote counterpart. A stream wrapper
  around them would have one implementation only.
- **The cadence is per repository, not per host.** The manager starts and stops the HEAD
  and file monitors when the worktree list, the selection and the open tabs change. It
  also runs the pull request timers per repository. Remote repositories will need those
  timers, because `gh` runs locally against the explicit repository target (A5a). They
  start once the pull request path takes locations (A6c).

## Change

The manager reads repositories from `Worktree.repositoryLocation`:

- **Pull request state** is keyed by `RepositoryLocation`: the timers, the selection
  cooldowns and the last selected worktree. The cadence runs only for local repositories
  (`tracksPullRequests(of:)`). A6c turns it on for remote ones. The background interval
  counts only the worktrees of tracked repositories, so remote worktrees do not slow the
  refresh of local ones.
- **Local monitors watch only local repositories.** The HEAD monitor, the worktree file
  monitor, the registry monitor, the remote-config monitor and the index-size probe run
  only for a location with a `localURL`. Their maps stay keyed by the standardized local
  root, as before.
- **Line counts are read only for local worktrees.** A remote worktree is never
  line-change active and gets no `.filesChanged` event or safety timer. Its counts come
  from its host's refresh (B3).

**Events carry the location:**

- `repositoryWorktreesChanged(repository:)`
- `repositoryRemoteConfigurationChanged(repository:)`
- `repositoryPullRequestRefresh(repository:worktreeIDs:)`

The reducer handlers changed as follows:

- The remote configuration handler looks the repository up by its standardized local root.
- The pull request handler passes the local root to `repositoryPullRequestRefreshRequested`
  and drops remote locations. A6c re-keys the pull request path, so remote repositories
  get pull request status there.
- The plain-folder roots come from `location.localURL`.

The five monitor factories and `indexEntryCountProvider` stay as they are. They are the
local change observation. B3 adds the remote host's refresh next to them and does not wrap
them.

## Behaviour

No change for local repositories:

- The monitor keys are the same standardized URLs.
- The pull request keys are the same unstandardized URLs.
- The events carry the same URLs inside `.local`.

The manager no longer reads `Worktree.workingDirectory` or `Worktree.repositoryRootURL`.

A rate-limit retry or a pull request action on a remote worktree still marks the worktree
as forced. The follow-up event is dropped, so the mark stays until A6c makes the remote
refresh real. The leftover mark then causes one normal refresh.

## Tests

- `WorktreeInfoWatcherManagerTests.remoteWorktreesGetNoLocalMonitorsTimersOrEvents`: a
  selected and opened remote worktree creates no monitor and no index probe. Over 400 s,
  it emits no pull request refresh and no `.filesChanged`.
- `WorktreeInfoWatcherManagerTests.remoteWorktreesDoNotSlowTheLocalPullRequestCadence`: a
  remote worktree does not lengthen the background interval of a local repository. Red
  when the interval counts every worktree.
- `RepositoryHostTests.remotePullRequestRefreshEventsWaitForTheHostPath`: a pull request
  event for a remote repository does nothing yet.
- The existing manager, batched-refresh and repositories suites now use location
  payloads, with no change in their assertions.
