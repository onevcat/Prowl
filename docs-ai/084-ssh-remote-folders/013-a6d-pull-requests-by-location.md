# 084.013 — Pull request and code host path by location (A6d)

## Context

A6d of [012-a6c-settings-by-location.md](012-a6c-settings-by-location.md) covers the
GitHub integration path. That path resolves a repository's GitHub remotes, queues and
coalesces pull request refreshes, runs the pull request actions (ready, merge, close, CI
logs, rerun, open on the code host), and keeps per-repository settings for them. Before
this change it was keyed by the repository root URL from `Worktree.repositoryRootURL` and
`Repository.rootURL`.

## Change

- **Remote resolution goes through the host.** `RepositoryHost.remoteInfo(for:)` and
  `githubRemoteInfos(for:)` read the git remotes of a local repository, as A6a planned.
  - The `gh repo view` fallback (`GithubCLIClient.resolveRemoteInfo`) needs a working
    directory on this Mac, so it runs only for a local location. One helper
    (`ghRemoteInfo`) holds that rule for both the single and the batched lookup.
  - A remote repository resolves no remotes until B3 gives the host its remote URLs.
- **The path carries `RepositoryLocation`.** These carry `repositoryLocation` instead of
  `repositoryRootURL`:
  - `GithubIntegrationAction.repositoryPullRequestRefreshRequested`;
  - `PendingPullRequestRefresh` (pending and queued);
  - `queuePullRequestRefresh`;
  - `enqueueBatchedPullRequestRefresh`;
  - the `resolveGithubRemoteInfo*` helpers.

  The coordinator's `Request` and `Outcome.refreshed` carried the root URL as metadata
  that nothing read. That field is removed. The batching is keyed by repository ID and
  host, as before.
- **The pull request actions** read the settings key, the remotes and the code host web
  URL by `worktree.repositoryLocation`.
- **The watcher event reaches the path unchanged.** `.repositoryPullRequestRefresh` from
  the watcher (A6b) goes to the path as is. The pending re-sends no longer wrap
  `.local(...)`, and pending refreshes sort by location ID.
- **One rule says which repositories refresh.** `RepositoryLocation.refreshesPullRequests`
  is true for local locations only, until B3. Both the watcher cadence (A6b) and this path
  use it:
  - `repositoryPullRequestRefreshRequested` returns before it reads settings, probes
    `gh auth status`, or records pending or in-flight state;
  - `delayedPullRequestRefresh` and the rate-limit retry probe no longer mark a remote
    worktree as forced, which removes the leftover marks that 011 noted.

  B3 changes this one property.

## Behaviour

No change for local repositories:

- the same remote resolution order (git remote, then `gh repo view`);
- the same settings keys;
- the same batching and actions.

The pending refreshes replay in location-ID order. For a local repository the ID is the
URL path, so the order is unchanged.

For a remote worktree, the pull request actions that need no pull request fail with an
alert instead of trapping on a forward. For example, "Open on code host" says that the
repository URL is not available.

## Tests

- `RepositoryHostTests.remotePullRequestRefreshIsSkippedUntilTheHostHasRemotes`
  (exhaustive): a refresh event, a delayed refresh and a rate-limit retry for a remote
  worktree change no state. They start no availability probe, mark nothing as forced, and
  run neither local git nor `gh repo view`.
- `RepositoryHostTests.openingARemoteRepositoryOnItsCodeHostExplainsTheMissingURL`.
- The direct host test covers `remoteInfo(for:)` and `githubRemoteInfos(for:)` for a remote
  location.
- The batched refresh, coordinator and repositories suites now use location payloads,
  with no change in their assertions.
