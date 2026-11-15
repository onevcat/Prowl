# 057 — Performance Benchmark Suite: Plan

|                 |                                                                                                                                                          |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Status**      | Implemented                                                                                                                                              |
| **Anchor date** | 2026-08-02                                                                                                                                               |
| **Primary PRs** | #668                                                                                                                                                     |
| **Related**     | [056-performance-optimization-2026-08](../056-performance-optimization-2026-08/000-plan.md), [032-performance-hardening](../032-performance-hardening/000-plan.md) |

## Background

The August 2026 performance wave (#644–#665) landed with strong behavioral test coverage
but zero timed benchmarks. Its quantitative claims — the `memchr` scan removing 94–96% of
untracked line-count CPU, the escape-absence guard cutting `normalize` by 1.58x, animated
tab titles coalescing to at most one write per second — are author measurements;
[056.011](../056-performance-optimization-2026-08/011-profiling-method-and-tools.md)
records explicitly that review "verified the structural paths and the tools, not the
original long captures". The Release microbenchmark that justified #652's scanner design
was never committed, so its numbers cannot be re-run.

An independent reproduction on 2026-08-02 confirmed the three headline claims (scan −94%
on 2 MiB sparse text with the dense-tail regression bounded by the hybrid scanner;
escape guard 1.53x on a 240-fragment 81%-non-ASCII corpus; a live Release instance's
animating tab at 0.99 title changes/second against a ~10 Hz source). This entry turns that
one-off reproduction into repo-owned infrastructure so future changes to these hot paths
are measured, not remembered.

## Goals

- Pin the optimized hot paths against naive reference implementations with **ratio
  assertions** that run in the normal test suite: machine-independent, load-tolerant
  (both sides of a ratio see the same load), and conservative enough never to flake.
- Provide `make bench` to run the same suite with `-O` and report **absolute medians**,
  appended as JSON lines to `~/Library/Logs/Prowl/measurements/bench/` so one machine
  accumulates a comparable time series keyed by git SHA.
- Add a black-box title-coalescing check (`scripts/measure-title-coalescing.sh`) — the
  only claim verifiable against a running Release build with no instrumentation.
- Wrap the existing measurement scripts in `make measure-cpu` / `make capture-spike` so
  the live-measurement layer is discoverable.

### Non-goals

- No CI timing gates. Absolute numbers are only meaningful on one quiet machine; the
  ratio assertions are the portable regression net.
- No automation of `sample(1)`-percentage claims (flush shares, spike profiles). Those
  remain the domain of the 032.004 method and the two capture scripts.
- No new benchmarks for paths whose protection is already deterministic (emission-count
  tests, budget-proxy tests) — counting beats timing where counting is possible.

## Design / Approach

Four benchmark suites in `supacodeTests/`, Swift Testing, each pitting the shipped path
against a pristine reference implementation kept inside the benchmark file:

| Suite | Shipped path | Reference | Claim pinned |
| --- | --- | --- | --- |
| `LineCountScanBenchmarks` | `GitClient.countLinesInFiles` (fresh `UntrackedLineCountCache`) | pre-#644 `Data.reduce` reader | #644/#652 scan win; dense-input bound |
| `FingerprintNormalizeBenchmarks` | `AgentSessionFingerprintMatcher.normalize` | pre-#650 regex-always formulation | #650/#657 escape-absence guard |
| `WorktreeDirectoryIndexBenchmarks` | `WorktreeDirectoryIndex` build + lookups | pre-#648 per-row `PathPolicy.normalizeURL` scan | #648/#655 index win |
| `SessionScoringBenchmarks` | `bestMatch` with warm `TranscriptFragmentCache` | same call with a cold cache per round | #650/#657 fragment reuse |

Shared plumbing in `supacodeTests/BenchmarkMeasurement.swift`: median-of-N timing via
`ContinuousClock`, input sizing (small in the default test run to keep Debug wall-clock
low, full-size when `PROWL_BENCH_REPORT=1`), and the JSONL reporter (records suite, case,
median, iterations, mode, git SHA from `PROWL_BENCH_GIT_SHA`).

Every suite asserts output equivalence between the shipped and reference paths before
timing, so a benchmark can never pass while the implementations diverge semantically.

`make bench` runs `xcodebuild test` filtered to the four suites under
`-configuration Release` with `ENABLE_TESTABILITY=YES` and a dedicated derived-data path
so optimized builds do not thrash the normal test cache. (A global
`SWIFT_OPTIMIZATION_LEVEL=-O` override was tried first and rejected: applied to every SPM
package target it broke the `PackageFrameworks` product layout with cascading linker
failures, while the Release configuration builds each target with its own verified
optimized settings.)

## Alternatives & decisions

- **package-benchmark in a separate SwiftPM package** (rejected): the hot-path sources
  live in the app target; a benchmark package would compile them by file path, which
  breaks silently on file moves. Running inside `supacodeTests` keeps `@testable` access
  and single-source truth.
- **Absolute-time assertions with committed baselines** (rejected): baselines drift per
  machine and Xcode version; ratios against an in-file reference are portable and
  self-calibrating.
- **Timing benchmarks opt-in only, outside `make test`** (rejected): an opt-in gate that
  nobody runs protects nothing. Ratio margins are set 2–4x below measured Release ratios,
  so the default-run cost is a few seconds without flake risk.
- **Which ratios run in Debug**: a ratio whose slow side is a C call or filesystem I/O
  (sparse scan vs `memchr`, per-row scan vs the index, cold vs warm fragment cache) holds
  in any build mode and asserts everywhere. A ratio between two Swift-level formulations
  does not: measured under `-Onone`, the escape-absence guard fell to 1.13x the regex it
  guards and the hybrid scanner's raw-pointer fallback ran at 0.45x the `Data.reduce`
  reader. Those two assertions gate on an optimized build, detected at runtime via an
  `assert` side effect (`assert` bodies execute only under `-Onone`), and so fire in
  `make bench` runs only.
- **Threshold source**: measured Release ratios were scan 16x (sparse), 5x (dense),
  normalize 1.53x; assertions use ≥3x, ≥2x, ≥1.3x respectively.
- **Destination pinning**: a generic `platform=macOS` destination matched two run
  destinations and executed every test twice; `make bench` pins
  `platform=macOS,arch=$(uname -m)` so the log receives one record per case per run.

## Amendments

- Updated 2026-08-02: added the explicit-invocation `run-benchmark` skill so agents can
  run the layers with the right comparison and a persistent report — see
  [002-benchmark-runbook-skill.md](002-benchmark-runbook-skill.md)
- Updated 2026-11-15: added LLDB call-path counts of worktree switches and app activation in a
  running Debug app, and a workflow that compares them between the merge base and the head on
  macOS 26 and 27 — see [003-interaction-call-path-counts.md](003-interaction-call-path-counts.md)
