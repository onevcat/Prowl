# 016.010 — Stable Incremental State in CI

## Context

By 2026-10-31 the `build` job took 11 to 18 minutes. A typical pull request spent about 400 s in
the App build, with about 120 s more to restore a 3.5 GB App cache and 66 to 98 s to validate
the compilation cache (CAS). The test run took 133 to 190 s.

Two facts were not known before this work:

- **Incremental builds did not work in CI, and the CAS hid this.** A restored build reran the
  compile tasks of the whole App. They were CAS hits when the source was unchanged, so
  [007](007-app-incremental-and-module-boundaries.md) read them as "no compilation". Its result
  describes replayed compiler output, not narrow incremental state.
- **The strict key was stricter than necessary.** Each added or deleted file missed the App
  key. 7 of 11 sampled runs missed it.

## Root cause

The system mounts the Metal toolchain at
`/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v<version>.<random>`,
and the random suffix changed in each of 6 compared runs. The build system puts this path in
`PATH` for 71 tasks and in the arguments of 53 tasks. llbuild includes these in the task
signature, so `Ld` tasks reran on each runner (`signature-changed` in the trace). Reruns relink
the macro plugins, and modules that use a macro plugin then recompile: the packages, `Prowl`
and `ProwlTests`.

Local builds did not reproduce it after a tar round trip of DerivedData and SourcePackages, new
source inodes and a regenerated project, because the suffix stays the same until the Mac boots
again. `defaults write com.apple.dt.XCBuild EnableBuildDebugging -bool YES` writes
`buildDebugging-*/completed-build.trace` and `current-manifest.swiftbuilddata/manifest.json`
under `Build/Intermediates.noindex`. Use `rule-needs-to-run` in the trace to find why a task
reruns.

## Change

- `.github/actions/setup-macos/action.yml` force-unmounts the toolchain. `xcodebuild` then reports
  it at `~/Library/Developer/DVTDownloads/MetalToolchain/mounts/<content hash>`, which is stable.
- The App key loses the file roster, `Makefile`, the workflow and the setup action. Added and
  deleted files reuse the state. Changed build flags need no key part, because a task reruns
  when its command line changes.
- CI sets `COMPILATION_CACHE_ENABLE_CACHING=NO`, `COMPILER_INDEX_STORE_ENABLE=NO` and
  `GCC_GENERATE_DEBUGGING_SYMBOLS=NO` through `PROWL_CI_BUILD_SETTINGS`. Local builds keep their
  settings. The CAS fallback steps are gone.
- Lint, format lint, the localization check and script tests move to a `checks` job, which needs
  only the new `.github/actions/setup-mise` action.

## Verification of the removed roster

Local builds at 3 jobs, with the settings above:

| Change | Result |
| --- | --- |
| Add a source and a test | Builds; the new test runs |
| Delete a source that a test uses | Compile error; no stale output links |
| Delete that test too | Builds; the test no longer runs |
| Add, then delete a file in a bundled folder reference | The file leaves the app bundle |

A deleted Swift input makes the driver recompile that module, so a deletion costs a module
rebuild but gives a correct result.

## Measurements

Single samples from pull request #1020, on hosted runners whose speed varies about 2x.

| Scenario | App build | `build` job | App cache |
| --- | ---: | ---: | ---: |
| Before, key miss (run 41198668007) | 410 s | 846 s | 3.5 GB |
| After, no cache at all (41211095241) | 483 s | 921 s | 552 MB |
| After, one function body edited (41216947789) | 74 s | 524 s | not measured |
| After, one private declaration added (41215914870) | 195 s | 710 s | not measured |

The last row shows the remaining cost: a change to the `Prowl` module interface recompiles all
of `ProwlTests`, because each test file uses `@testable import Prowl`.

Local cold builds at 3 jobs took 284 s before and 240 s after the settings change (one sample
each). The compile cost of `ProwlTests` has no type-check outlier: a build with
`-warn-long-function-bodies=500` found 7 functions, about 4.5 s in total.

## Open questions

- Whether local Debug builds also recompile after each reboot for this reason. The mount suffix
  and the local task paths suggest it, but no reboot was tested.
- Test time is mostly main-actor blocking, not test count. In a forced serial run of 164 s, 3,799
  of 5,028 cases took 5.8 s in total. Not changed here.

## Refs

PR #1019 and trial PR #1020.
