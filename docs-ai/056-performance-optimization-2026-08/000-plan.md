# 056 — Performance Optimization 2026-08: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-08-01 |
| **Primary PRs** | #644, #652; review queue #645–#650 |
| **Related** | [032-performance-hardening](../032-performance-hardening/000-plan.md), [037-line-diff-tracking](../037-line-diff-tracking/000-plan.md), `docs/components/diff-view.md` |

## Background

The August 2026 performance series started with seven independently reviewable pull
requests, #644–#650. Each reports a sampled hot path from a many-pane Prowl workload and
proposes a focused optimization. The changes span untracked-line counting, Debug-only TCA
logging, agent detection and session matching, sidebar invalidation, worktree lookup, and
animated terminal titles.

This entry records the cross-cutting standard used to review and integrate that series:

- reproduce or independently measure the claimed cost where practical;
- preserve user-visible and CLI semantics unless an explicit product decision says
  otherwise;
- treat cache identity, invalidation, lifetime, concurrency, and bounded growth as part of
  correctness;
- require tests that can fail when the optimized path stops being equivalent;
- keep each PR independently reviewable instead of combining unrelated hot paths.

The first application is #644. Its `memchr` scan removes the dominant per-byte
`Data.Iterator` overhead, but its per-file 2 MiB cutoff silently maps a present, readable
untracked text file to zero added lines. If that is the only change, the worktree badge
disappears even though Show Diff still includes the file.

## Measured baseline for #644

An independent Release-optimized benchmark on an Apple M2 Pro mirrored the production
64 KiB reader and 8 KiB binary probe. Warm-cache medians were:

| Input | Original `Data.reduce` | `memchr` | Incremental gain from skipping after `memchr` |
| --- | ---: | ---: | ---: |
| 2 MiB, sample-like text | 8.50 ms | 0.36 ms | 0.36 ms |
| 2 MiB, source-like text | 8.58 ms | 0.54 ms | 0.54 ms |
| 35 MiB, sample-like text | 148–151 ms | 7–12 ms | about 9 ms |
| 66 MiB, sample-like text | 279–289 ms | 22–23 ms | about 23 ms |

The scan optimization therefore removes roughly 94–96% of the normal 2 MiB CPU cost
without changing behavior. The hard cutoff saves additional reads for much larger files,
but 2 MiB is not a meaningful performance cliff and is too low to justify silently losing
the exact badge contract.

The benchmark also found a density tail: repeated `memchr` calls are fastest for normal
text, but a 2 MiB all-newline buffer took about 16.7 ms versus 8.6 ms for `Data.reduce` and
1.1 ms for a raw-pointer loop. The shipped scanner should retain the sparse-text win while
bounding this dense-match case.

## Goals

- Preserve #644's original author commits and measurable scan improvement.
- Remove the silent per-file 2 MiB semantic cutoff.
- Cache calculated untracked-file line counts across refreshes using stable file metadata, so a
  metadata-unchanged large capture is not reread when another file triggers FSEvents.
- Bound uncached work with one deterministic byte budget for the whole refresh, not a
  per-file limit that can still scan an unbounded aggregate.
- Propagate incomplete-count state to the sidebar and workspace-child rows instead of
  coalescing omitted files to zero.
- Keep the diff badge visible and clickable when omitted untracked files are the only
  changes.
- Give VoiceOver and the tooltip a truthful explanation of incomplete addition counts.
- Retain exact tracked additions/deletions and the existing binary probe behavior.

### Non-goals

- No user-facing setting for byte budgets or cache policy in this wave.
- No replacement of `git diff HEAD --shortstat` or the FSEvents scheduling pipeline.
- No combined implementation of #645–#650; each remains an independent review and merge
  decision.
- No claim that author-reported sampling numbers are independently verified until that PR
  receives its own review.

## Design / Approach

### Metadata-validated cache

Introduce a long-lived, concurrency-safe untracked-line cache shared by live `GitClient`
instances. Entries are scoped by worktree and relative path and fingerprinted with file
identity, byte size, and modification date. A metadata-equivalent fingerprint reuses either
the previously calculated text line count or the binary-file result. Every current
`git ls-files --others` result prunes disappeared paths from that worktree's cache.

Cache misses are scanned outside cache isolation so independent worktrees are not forced
through one serialized I/O executor. Updates are committed with their fingerprint, and a
later refresh whose metadata differs will not reuse the cached result. Cache retention is
bounded by worktree, entry, and relative-path-key limits.

### Aggregate scan budget

Apply a 32 MiB budget to cache misses for one `lineChanges` refresh. Cached files consume no
budget. Sort misses by size so the budget yields exact counts for the largest useful set of
files. Files that do not fit remain omitted and increment an explicit omission count.

The scanner also enforces the remaining budget while reading, covering a file that grows
after metadata collection. A single per-file 2 MiB threshold is removed: besides hiding
legitimate generated source, it does not bound 100 files of 1.9 MiB each.

### Honest presentation

Carry a structured line-change result with exact counted additions, exact removals, and the
number of omitted untracked files. The sidebar renders exact counts as today. When additions
are incomplete, it renders `+N…`; if no additions were counted, it renders `+…`. The tooltip
and accessibility label state that the addition count is incomplete and how many untracked
files were not counted. The badge remains a Show Diff button.

### Dense-match scan

Keep `memchr` for normal sparse text. After a bounded number of matches in one chunk, scan
the remainder through contiguous raw bytes, avoiding one C call per byte for newline-dense
input while preserving exact counts.

## Performance PR review queue

The descriptions and heads below were confirmed on 2026-08-01. All claims remain pending
independent code-path and test review except #644, which is the active implementation wave.

| PR | Confirmed scope | Review focus / placeholder | Head |
| --- | --- | --- | --- |
| #644 | Replace `Data.Iterator` line scans and avoid repeated large untracked-file work | Active: preserve exact badge semantics with cache, aggregate budget, and explicit incomplete state | `978b7b59` |
| #645 | Gate Debug TCA action reflection/state-diff logging behind `PROWL_LOG_TCA_ACTIONS` | Verify flag parsing, logging contract, Debug-only scope, and pass-through reducer semantics | `616bbf4b` |
| #646 | Memoize per-surface agent screen parsing when agent and visible text are unchanged | Verify cache invalidation, stabilization timing, observation isolation, and surface teardown | `b2ac2936` |
| #647 | Deduplicate raw-state-only agent emissions and narrow sidebar invalidation | Decide whether stale CLI `raw_state` is acceptable; trace UI/CLI ownership before merge | `e77ba660` |
| #648 | Replace per-agent worktree scans/path resolution with a cached directory index | Verify deepest-match and symlink semantics, cache invalidation, render-path purity, and current CI | `08773383` |
| #649 | Coalesce animated terminal-title writes and remove quadratic tab lookup | Verify final-title delivery, close/prune lifecycle, custom/locked titles, and clock boundaries | `b77888f3` |
| #650 | Cache parsed transcript tails and fast-path fingerprint normalization | Verify append/mtime invalidation, cache pruning, Unicode equivalence, collision behavior, and current CI | `c97cbb4` |

## Alternatives & decisions

- **Hard per-file cutoff:** rejected as the primary mechanism. It creates a discontinuity at
  an arbitrary size, silently changes visible behavior, and does not bound aggregate work.
- **Only document the cutoff:** rejected. Documentation cannot make a false exact number or
  a disappeared badge truthful.
- **Scan everything with `memchr`:** acceptable CPU behavior for normal local files, but it
  repeats I/O after unrelated FSEvents and remains unbounded for pathological worktrees.
- **Cache without a safety budget:** preserves exactness in steady state but allows an
  unbounded first refresh. The aggregate budget keeps the worst case explicit and bounded.
- **Time budget:** rejected for now because it makes tests and visible results depend on
  hardware and load. A byte budget is deterministic and measurable.
- **Raw-pointer scan only:** stable across newline density but slower than `memchr` on the
  motivating sparse-text capture. A bounded hybrid keeps both properties.

## Validation

- Observe new cache, invalidation, aggregate-budget, and incomplete-result tests fail before
  implementation, then pass.
- Cover reducer/state transitions where an omitted file is the only worktree change.
- Cover visual/accessibility strings through a pure badge-presentation model.
- Run the complete `GitClientLineChangesTests` and affected repository tests.
- Run `make check` and `make build-app` before publishing.
- Re-run a Release-optimized microbenchmark for normal and newline-dense inputs after the
  hybrid scanner change.

## Amendments
