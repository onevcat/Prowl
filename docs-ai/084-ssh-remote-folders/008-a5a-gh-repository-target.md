# 084.008 — `gh` commands name their repository (A5a); A5 split, A4b moved

## Context

The "Host boundary" section of [000-plan.md](000-plan.md) lists `gh` calls that infer
their repository from the working directory. They cannot work for a repository on
another host, because no local cwd exists for it. `gh` should run locally with an
explicit target, so a host without `gh` keeps PR features.

## Change

`GithubCLIClient` (`App/Sources/Clients/Github/GithubCLIClient.swift`):

| Call | Before | After |
| --- | --- | --- |
| `latestRun` (`gh run list`) | cwd = worktree | `--repo HOST/OWNER/REPO`, no cwd |
| `rerunFailedJobs` (`gh run rerun --failed`) | cwd = worktree | `--repo`, no cwd |
| `failedRunLogs`, `runLogs` (`gh run view --log-failed` / `--log`) | cwd = worktree | `--repo`, no cwd |
| `mergePullRequest`, `closePullRequest`, `markPullRequestReady` | `--repo` and cwd = worktree | `--repo`, no cwd |
| `defaultBranch` (`gh repo view --json defaultBranchRef`) | no caller | removed, with `GithubRepoViewResponse` and `GithubDefaultBranchRef` |
| `resolveRemoteInfo` (`gh repo view --json owner,name,url`) | cwd = repository root | unchanged (see Deviations) |

The closures take a `GithubRemoteInfo` instead of a URL. The run commands now pass
`host: remoteInfo.host` to `withExpectedGithubAccount`, as the pull request commands
already did. An account override for another host is refused with the existing "This
repository uses …" error. It no longer switches an account that the command does not
use.

Callers (`RepositoriesFeature+GithubIntegration.swift`): "Copy CI failure logs" and
"Re-run failed jobs" resolve the target the way merge, close and ready already do
(`resolveGithubRemoteInfo(for: pullRequest, …)`):

1. The pull request URL.
2. If that fails, the parsed git remote.
3. If that fails, the `gh repo view` fallback.

When none of them works, they show the same "GitHub repository not resolved" alert.
The five copies of that "resolve or alert" block are now one helper,
`resolveGithubRemoteInfoOrAlert`. The two "latest failed run" chains are one
`GithubCLIClient.latestFailedRun`.

### Behaviour

For a repository whose pull requests and CI live in the same GitHub repository, nothing
changes.

For a fork whose `origin` is the fork:
- Before, the run commands followed `gh`'s cwd inference: `gh repo set-default`, then
  the remotes in the order `upstream`, `github`, `origin`. A fork clone with an
  `upstream` remote already targeted the base repository.
- Now they target the repository of the pull request URL, which is where its CI runs.
  This matches merge, close and ready. The result differs from before only for a fork
  clone without an `upstream` remote and without `set-default`.

Known limits, unchanged by this PR:
- `gh run list --branch <head>` matches by branch name. In the base repository, a pull
  request from a fork branch named like a base branch (for example `main`) can match an
  unrelated run. The cwd inference had the same problem with an `upstream` remote.
  Filtering by the head commit needs the head SHA in the pull request query.
- `GithubRemoteInfo.host` has no port, so a GHES instance on a non-default port is not
  reachable through `--repo`. The pull request commands already had this limit.

Rate limits: `GithubRateLimitRequest` reads the host from `--repo HOST/OWNER/REPO`.
The `gh run` commands now count against their repository's host (REST) instead of the
shared "default host" group. `docs/components/github-pull-requests.md` is updated.

### Tests

- `GithubCLIClientTests`:
  - The four run commands carry `--repo github.enterprise.test/octo/repo` and run
    without a cwd.
  - The pull request mutations now run without a cwd.
- `GithubCLIClientTests.runCommandsRefuseAnAccountOverrideForAnotherHost`: no `gh run`
  is launched.
- `RepositoriesFeatureTests`:
  - `rerunFailedJobsTargetsThePullRequestURLRepository`: both `latestRun` and
    `rerunFailedJobs` receive the repository from the pull request URL, and neither
    git nor `gh` resolution runs.
  - `copyCiFailureLogsTargetsThePullRequestURLRepository`: the same holds for
    `latestRun`, `failedRunLogs` and `runLogs`.
  - `rerunFailedJobsExplainsAnUnresolvedRepository`: no lookup runs, and the alert
    shows.
- Existing mocks and the rate-limit tests are updated for the new signatures.

## Deviations from the plan

- The plan asked for a positional target for the two `gh repo view` calls. One of them
  (`defaultBranch`) had no caller and is removed. The other is the remote-info fallback.
  It runs only when the git remote regex fails, for example for an SSH host alias such
  as `github-work:owner/repo`. Its job is to let `gh` infer the repository from the cwd,
  and `gh` resolves SSH aliases there. A positional URL would lose that and break the
  users the fallback exists for. It keeps its cwd and stays a local-repository fallback.
  For a remote folder, the target comes from the remote URL that the host reads (B3).

## Plan changes in this PR

- A5 is split:
  - A5a: this PR.
  - A5b: `GitClient(executor:)`, with the ad-hoc instances and the bypasses routed.
  - A5c: git reads move off the forwards. It may join A6.
- A4b (UI gates) lands with C1. Its disabled states appear only for a remote folder,
  and changing the toolbar controls requires a Debug visual check
  (`docs-ai/061-native-toolbar-controls`), which needs a real remote folder.
