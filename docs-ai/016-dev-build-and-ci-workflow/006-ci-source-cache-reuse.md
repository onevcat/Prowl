# 016.006 — CI Source Cache Reuse

Follow-up: [007](007-app-incremental-and-module-boundaries.md) records the later App
incremental-state and Shared module experiments, which extend this CLI-only change.

## Context

An exact CLI build-cache hit still recompiles checked-out sources. SwiftPM uses source
modification times for incremental builds, and checkout gives unchanged files new times.
The source-state key also omits CLI contract resources and build configuration inputs.

## Change

Store source hashes and nanosecond modification times inside the CLI build cache after a
successful test step. Restore times only for current tracked, regular input files whose
SHA-256 matches the saved content. Require the same absolute workspace path. Missing or
invalid manifests are cache misses. Never restore times based only on Git commit dates.
Changed, new, deleted, and symlink inputs retain normal build-system invalidation.

Include package, contract, project, and workflow inputs in immutable cache keys. Use exact
lockfile paths rather than searching restored dependency trees. Run CLI smoke/unit/integration
checks sequentially within one parallel branch, because they share SwiftPM's build lock.

Keep Xcode CAS caching. Do not add full DerivedData caching in this change: the measured
Build directory adds 1.4 GB before compression (291 MB with zstd), and existing repository
caches already total 10.4 GB. A local same-path experiment reduced build time from 43.7 s
to 25.6 s by retaining incremental state, but archive transfer and fresh-checkout
invalidation need separate trials.

The App compiles 532 Swift files as one module. With clean DerivedData and a warm CAS, a
single comment change caused 22 Swift compilation misses plus one module-emission miss.
The previous amendment's claim that ordinary changed CI runs compile only affected files
was too broad: dependency modules can remain cached while every App batch recompiles.

## Verification plan

Test identical, changed, new, deleted, symlink, invalid-manifest, and relocated-workspace
inputs. Compare SwiftPM logs before and after a content-identical timestamp change. Run the
normal build and checks, then inspect CI cache hits and compilation logs. Module extraction
remains a separate experiment; `ProwlCLIShared` is an existing dependency boundary to assess.

## Local verification

Six source-time regression tests pass. After updating modification times for all CLI
inputs and restoring 106 content-matched files, `swift build --product prowl` completed in
0.57 s without source compilation. Touching one file without restoration compiled that
file and emitted its module. `make check`, CLI build/smoke/unit/integration checks, and all 143 script tests pass.
The App build, actionlint, and diff checks also pass. GitHub cache-population and reuse
runs are linked in PR #773; source-time correctness tests remain part of every CI run.

Performance decisions use repeated local comparisons with fixed paths and toolchains.
Hosted CI validates cross-run cache restoration and test correctness; its wall times are
not a controlled performance comparison because runner capacity varies.
