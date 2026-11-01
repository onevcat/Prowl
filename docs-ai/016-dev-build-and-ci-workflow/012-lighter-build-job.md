# 016.012 — Lighter Build Job

## Context

After [011](011-test-shards.md), a change to a declaration in the App still took about 12
minutes in the `build` job. The goal is a job under 10 minutes on the hosted runner.

Three costs did not depend on the App:

- The CLI tests ran next to the App build and its tests on a runner with about 3 cores, and
  took 100 to 183 s.
- The SwiftPM cache entry was 1467 MB. Five Sentry frameworks were 2.1 GB on disk and the App
  uses one. The repository clones were 764 MB.
- Each change to `App/Config/Version.xcconfig` missed the App cache and started a cold build.
  It changed 10 times in 60 days, of the 17 commits in that time that changed a configuration
  input of the key.

## Change

- The `checks` job runs the CLI tests. It has the only save of the CLI cache, because it has the
  test products. `restore-cli-cache` is the shared restore action, and the `build` job restores
  this entry to stage the CLI binary.
- `scripts/ci-prune-spm-cache.sh` removes the repository clones and the unused Sentry frameworks
  before main saves the entry. The entry is 310 MB.
- The App cache key does not use `App/Config/Version.xcconfig`. In a local test, a version change
  compiled no file, and the build took 8 s.

## Rejected

| Idea | Result |
| --- | --- |
| Keep only the macOS slice of `Sentry.xcframework` | The hosted build fails: "The signature of Sentry.xcframework cannot be verified". The local build passed, so test this kind of change on the runner. |
| `ENABLE_PREVIEWS=NO` | 239 s against 236 and 245 s, cold with `-jobs 3`: no difference |
| No location strings or generated symbols | 241 s: no difference |
| No code coverage settings | 243 s: no difference |
| Implicit modules | 242 s: no difference |

## Measurements

The hosted runner varies a lot. Compare several samples, not two runs.

| Case | `build` job samples |
| --- | --- |
| Interface change, before this work | 11:50 (one sample) |
| Body change, before this work | 8:44 (one sample) |
| Body change, with main's new caches | 5:36, 6:47 |
| Interface change, with main's new caches | 9:20, 8:41 |
| Interface change, trial with the package and CLI caches of the pull request | 8:49, 10:41, 9:52, 9:08 |
| Version change, with main's new caches | 8:55 (one sample) |
| Cold App build | 10:36, 17:04, 21:40 |

The 21:40 sample also had no CLI cache and restored the 1467 MB package entry.

## Open questions

- A change to the App interface recompiles all of `ProwlTests`. A split of the App into modules
  is the remaining way to avoid this. In the last 30 days, most changed App files were in
  `App/Sources/Features`, so the split helps only if each feature has its own test target. It has
  not been measured.
- A larger hosted runner may reduce the runner's variation. It costs money per minute and has not
  been measured.

## Refs

PR #1026; trials #1024 and #1027 (not merged).
