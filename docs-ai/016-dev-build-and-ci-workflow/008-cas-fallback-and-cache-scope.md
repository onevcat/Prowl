# 016.008 — CAS Fallback, Cache Save Scope and Mirror Jobs

## Context

In #851, a pull request that changed the Makefile and the test workflow spent about 10 minutes
compiling the App (2,000+ compile steps) in the `build` job; the same job with a restored App
incremental cache compiles in under 2 minutes. Three problems caused this or made it likely:

- **The CAS cache was never used.** The `xcode-compilation-cache` step from
  [005](005-build-test-time-optimization.md) cached
  `~/Library/Developer/Xcode/DerivedData/CompilationCache.noindex`. Since
  [007](007-app-incremental-and-module-boundaries.md) the App builds with
  `-derivedDataPath build/ci-derived-data`, and Xcode then keeps the CAS at
  `<derivedDataPath>/CompilationCache.noindex` (`COMPILATION_CACHE_CAS_PATH`). The cached
  path never existed: every run logged "Cache not found", and no run saved an entry. A miss of
  the strict App incremental key (changed build configuration, Makefile, workflow or tracked
  file roster) therefore built without any compiler cache.
- **Pull requests evicted the entries of main.** Every pull request run that changed sources
  saved a new App incremental entry (about 930 MB) and CLI entry (about 670 MB). The repository
  used 10.7 GB of its 10 GB quota, and least-recently-used eviction removes the main entries
  that every pull request restores. Saving also added up to 53 s to pull request runs.
- **Mirror client jobs ran for every change.** The iOS mirror UI suite took 11–20 minutes on
  hosted runners for each pull request, including pull requests that changed only the Mac app.

## Change

- `.github/actions/setup-macos/action.yml` restores caches with `actions/cache/restore`.
  The dead CAS step is removed. When the strict App incremental key finds nothing, the action
  restores the newest App incremental entry for the same Xcode build and workspace, and keeps
  only its `CompilationCache.noindex`. The build is clean (no stale products from a changed
  file roster or configuration) but replays compiler outputs from the content-addressed cache.
  This reuses existing entries and needs no more cache space.
- `.github/actions/save-macos-caches/action.yml` saves the caches at the end of the job, after
  the build input times. Only `main` saves the SwiftPM, CLI and App entries. Pull requests
  still save the Mise and GhosttyKit entries, which are small and change rarely, because a
  GhosttyKit miss is slow to rebuild.
- The mirror clients have their own workflows, `.github/workflows/mirror-ios.yml` and
  `.github/workflows/mirror-android.yml`. They run for changes to their client (and
  `Mirror/Shared/` for iOS) and for each published release. They use the `release` event,
  not a `v*` tag push: `scripts/release.sh` makes lightweight tags, which
  `git push --follow-tags` does not push, and `gh release create` then makes the tag on
  GitHub. The v2026.9.29 release recorded no tag push event. The release check runs after
  publication, so it reports problems but does not block the Mac app release. CI runs only the iOS mirror unit tests (`make test-mirror-ios-unit`); the UI suite runs
  locally with `make test-mirror-ios`. The Mac app workflow ignores changes to only the
  mirror clients.
- `make test-app` exports each pass's test action log (`*.action.json`), and the CI summary
  shows when the test runner launch and the first test suite start.
- `make lint` and `make check-localization` run in the parallel step beside the build, in the
  `checks` task with the script tests, not as steps before it.

## Test start time

The test-progress heartbeat suggested that the first `xcodebuild test` pass waited 1.5–2
minutes after the build before its first suite. The test action log shows that this is
output buffering: xcodebuild writes test results to the pipe in bursts. In the measured run
the build ended at 96 s, the test runner launched at 98.8 s and the first suite started at
105.3 s; the tests then ran for about 85 s. Read test timing from the action-log summary, not
from heartbeat timestamps.

## Measurements (#851, hosted `macos-26` runner)

Both runs missed the strict App incremental key because the pull request changes the
Makefile and the workflows.

| Run | Compile | "Build app and run tests" step | `build` job |
| --- | ---: | ---: | ---: |
| Before (no CAS) | about 10 min | 782 s | 16 min 28 s |
| After (CAS from the newest main entry, 1.3 GB) | about 2 min 20 s | 322 s | 8 min 46 s |
| After, second run (516 Swift cache hits, 30 misses) | 96 s build | 267 s | 7 min 33 s |

Hosted runner speed varies about 2x between runs, so these are single samples, not medians.
In the second run, restoring caches took 98 s (SwiftPM 34 s, App state 25 s, CLI 15 s), the
main test pass about 90 s, and the three isolated `test-without-building` passes about 60 s.

## Open questions

- The SwiftPM cache (1.46 GB, mostly repository clones and the Sentry binary artifact) is the
  slowest restore. Removing the clones may make SwiftPM fetch them again; not measured.

## Refs

PR #851.
