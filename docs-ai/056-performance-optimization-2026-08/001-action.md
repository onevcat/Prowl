# 056 — Performance Optimization 2026-08: Action Log

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-08-01 |
| **Primary PRs** | #644, #652 |

## Outcome

The follow-up preserves both commits from #644 and keeps its `memchr` speedup,
but removes the silent 2 MiB per-file cutoff. Untracked-file line counts now use
a metadata-validated cache plus one 32 MiB budget across uncached files for a
refresh. Cached files cost no scan budget, while files that do not fit are
reported explicitly instead of being folded into an exact zero.

The sidebar and workspace-child paths carry that incomplete state through the
same `GitLineChanges` value. An incomplete additions badge remains visible and
clickable, renders `+N…` (or `+…` when no additions have been counted yet), and
explains the omission count in its tooltip and accessibility label. Tracked
additions and removals remain exact, and Show Diff continues to list all changed
files.

## Implementation map

- `GitClient.swift` — removes the per-file cutoff, applies one deterministic
  cache-miss byte budget, orders misses small-first, and returns counted lines
  plus the number of omitted files. Its sparse `memchr` scan switches to a raw
  pointer loop after 2,048 matches in one 64 KiB chunk to bound newline-dense
  input.
- `UntrackedLineCountCache.swift` — stores counted text values and binary results
  by worktree/path and file identity, size, and modification date. It prunes
  disappeared paths, retains at most 128 worktree roots, and caps both cache
  entries and retained relative-path bytes with LRU eviction. File I/O stays
  outside the short cache lock.
- `GitClientTypes.swift` and the repository reducer/state files — carry one
  structured `GitLineChanges` value through regular worktrees and project
  workspace children, including the omitted-untracked-file count.
- `LineChangeBadgePresentation.swift` and `WorktreeRow.swift` — keep incomplete
  counts visible without presenting a lower bound as exact, including truthful
  tooltip and VoiceOver text.
- `docs/components/diff-view.md` — documents the cache, refresh-wide budget,
  incomplete label, and unchanged Show Diff behavior.
- `docs-ai/056-performance-optimization-2026-08/000-plan.md` — records the
  review standard and placeholders for #645–#650 so each remaining performance
  PR can be reviewed independently.

## Measurements

An Apple M2 Pro Release build using the production 64 KiB reader showed that
#644's byte scan already removes most of the motivating CPU cost: a normal 2 MiB
text file fell from about 8.5 ms with `Data.reduce` to 0.36–0.54 ms with
`memchr`. Skipping that file saves only the remaining sub-millisecond scan on a
warm cache. Larger sample-like files showed a more material incremental saving:
roughly 9 ms at 35 MiB and 23 ms at 66 MiB.

A second in-memory benchmark verified the hybrid scanner after implementation:

| Input | `Data.reduce` | Pure `memchr` | Hybrid |
| --- | ---: | ---: | ---: |
| 2 MiB sample-like text | 7.900 ms | 0.113 ms | 0.118 ms |
| 2 MiB source-like text | 7.845 ms | 0.294 ms | 0.294 ms |
| 2 MiB all-newline text | 7.832 ms | 16.411 ms | 0.507 ms |
| 35 MiB sample-like text | 137.342 ms | 1.974 ms | 2.071 ms |

The fallback therefore removes the dense-match regression without materially
changing the normal-text result. The 32 MiB aggregate budget is a deterministic
safety bound rather than a claimed performance cliff; the cache is what removes
repeated scans from the steady-state refresh path.

## Verification

- The legacy-cutoff test was changed first to require an exact count at 2 MiB;
  it failed against #644's guard before implementation.
- Cache reuse, invalidation, aggregate-budget, bounded-lifetime, concurrent
  refresh, incomplete reducer state, workspace propagation, and presentation
  tests were added. The focused set passed 32 tests with no failures.
- `make check` passed.
- `make build-app` completed with no errors or warnings.
- A same-machine standard-suite comparison passed on both sides:
  - exact #644 head `978b7b59`: `make test-app`, 2,160 tests, 0 failures;
  - follow-up working tree: `make test-app`, 2,170 tests, 0 failures.

Non-standard isolated test selections exposed three existing
`RepositoriesFeatureTests` timing/isolation failures on both the follow-up and a
clean clone of exact #644. Two tests consumed their expected delegate actions
but did not finish the remaining persistence/detection effects. They now call
`store.finish()`. The concurrency test polled startup with 100 `Task.yield()`
calls; it now waits for the first real fetch through an `AsyncGate`, uses a
`TestClock` to hold one fetch while the other starts, and then advances the
clock to complete both. The three tests passed independently on both trees and
passed all 15 runs in a five-iteration repetition.

## Deviation from the initial implementation

The first cache implementation used an actor. Running the cache tests in
parallel exposed a Swift runtime `EXC_BAD_ACCESS` while destroying the array of
cache updates after an actor call, even though each test passed in isolation.
The final cache uses `Synchronization.Mutex` for short in-memory lookups and
writes and performs all metadata and file I/O outside the lock. A 16-task
concurrent-refresh regression test covers the final boundary.

The requested folder number 054 was already occupied by
`054-native-settings-navigation`, and 055 belongs to the open Agent Profile
runtime work. This topic therefore uses the next collision-free number, 056,
plus the requested date-qualified slug.
