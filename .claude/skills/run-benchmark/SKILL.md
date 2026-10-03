---
name: run-benchmark
description: Run Prowl's performance benchmark layers for the current branch or a release, compare against recorded baselines, and write a persistent local report. Use only when the user explicitly invokes run-benchmark or explicitly asks to run performance benchmarks / verify performance impact. Do not invoke automatically after implementation work. Classify the user's intent first (hot-path change, new optimization, or release-level sweep), confirm it with the user, then run the matching layers.
---

# Run Benchmark

## Invocation contract

Run this skill only after an explicit user request. Implementing, fixing, or reviewing
performance-adjacent code does not by itself authorize a benchmark run.

All timing in this workflow assumes **one dedicated, quiet local machine** accumulating a
series over time. Numbers from CI runners, other machines, or a loaded host are not
comparable and must not enter the baseline series. Never run other builds, tests, or
heavy agents concurrently with a timed run.

Background and design decisions live in `docs-ai/057-performance-benchmark-suite/`; the
measurement methodology (why workload context matters, why load kills comparability) in
`docs-ai/032-performance-hardening/004-agent-detection-steady-state.md`.

## Step 0 — Preflight

1. `git status --short` — an A/B run switches the checkout to the baseline commit, so the
   tree must be clean and HEAD committed. If dirty, tell the user what is blocked and ask
   whether to commit/stash or fall back to a branch-only run.
2. Quiet-host check: compare `uptime` load1 against `sysctl -n hw.ncpu`. Above roughly
   half the cores, warn that starvation inflates numbers unevenly and ask whether to wait
   or proceed; above one runnable process per core, refuse the timed run and say why.
3. Note what is available for the live layer: is a Prowl instance running
   (`prowl list --json`), and are any agents working (animating titles)?

## Step 1 — Classify intent, then always confirm

Gather evidence before guessing:

- The user's own words in the invocation — these override everything below.
- `git branch --show-current`; `BASE=$(git merge-base HEAD origin/main)`;
  `git diff --name-only $BASE` and `git log --oneline $BASE..HEAD`.
- Map changed files through the table in **Reference** to see which benchmark suites the
  branch can plausibly affect.

Classify into one of three modes:

| Mode | Signal | What runs |
| --- | --- | --- |
| **hot-path** | Branch touches files mapped to existing suites; user wants to know whether the change regressed them | A/B `make bench`: merge-base baseline vs branch |
| **new-optimization** | Branch introduces a performance improvement no suite pins yet | Add a benchmark first (057 pattern), then the hot-path A/B |
| **release** | Pre-release or "how is performance overall" with no specific change in question | `make test` + `make bench` vs trailing series + live layer |

Then **confirm with the user before running anything**, even when the evidence is clear:
present the guessed mode with its one-line evidence and the alternatives (AskUserQuestion
with the recommended option first). If the evidence is contradictory or absent, do not
guess — ask. Benchmark runs take minutes and switch the checkout; a wrong mode wastes
both.

## Step 2 — Run the confirmed mode

Every `make bench` appends records to `~/Library/Logs/Prowl/measurements/bench/bench.jsonl`
keyed by `git rev-parse --short HEAD`. Record the exact SHA before each run so the
comparison step can find its rows.

### hot-path — A/B against the merge-base

1. Check whether the baseline already exists on this machine:
   `jq -c "select(.gitSHA == \"<base-short-sha>\")" bench.jsonl`. Reuse it if present.
2. If absent: `git switch --detach $BASE` → `make bench` → `git switch -`. The first
   optimized build after a switch takes minutes; later ones are incremental.
3. `make bench` on the branch HEAD.
4. Compare per Step 3.

### new-optimization — pin the claim before measuring it

1. Check the **Reference** inventory: does any suite already cover the optimized path?
2. If not, the primary deliverable is a new benchmark following the 057 pattern, in the
   same PR as the optimization:
   - dig the replaced implementation out of git history and keep it **verbatim** as the
     reference;
   - assert output equivalence before timing;
   - assert a floor ratio 2–4x below the measured Release ratio;
   - gate Swift-vs-Swift ratios on optimized builds
     (`BenchmarkMeasurement.isOptimizedBuild`); C-call/filesystem ratios assert everywhere.
3. Then run the hot-path A/B: the new suite quantifies the win, the existing suites catch
   collateral damage.
4. The measured ratio goes into the report as the claim's durable evidence — this is
   exactly what the #644–#665 wave lacked.

### release — full sweep plus series

1. `make test` — the behavioral + ratio layer (Debug).
2. `make bench` — compare against the trailing series (last ~5 records per case across
   recent SHAs), not a single baseline.
3. Live layer, best-effort, report each as run/inconclusive/skipped:
   - `make measure-titles` — needs a running app with at least one animating agent tab;
     exit 3 means nothing was animating (inconclusive, not a pass).
   - `make measure-cpu` — needs a running Prowl Debug instance; set `PROWL_PID` when
     several run. Records agent mix and load next to the attribution, so quote them
     together.
4. `make capture-spike` is a standing watch for long-running instances, not a step here;
   mention it if the user is chasing an intermittent spike.

## Step 3 — Compare and judge

Extract both sides:

```bash
jq -r 'select(.gitSHA == "SHA") | [.suite, .name, .referenceMilliseconds, .shippedMilliseconds, .ratio] | @tsv' \
  ~/Library/Logs/Prowl/measurements/bench/bench.jsonl
```

Judgment rubric (single machine, warm cache, medians of 15):

- A ratio below its asserted floor already failed the test — confirmed regression, no
  further interpretation needed.
- `shippedMilliseconds` against baseline: within ±20% is noise; 1.2–1.5x growth is a
  **watch** — rerun `make bench` once to confirm before claiming anything; above 1.5x
  sustained is a **regression**; above 2x is **major**. Name suspect commits via the
  file→suite map.
- Use `referenceMilliseconds` as the built-in host canary: the reference workload never
  changes, so if it moved by a similar factor the *host* moved, not the code; if shipped
  moved alone, the code moved.
- Never average across load regimes. If load was elevated during a run, discard the run
  and redo it — do not "correct" the numbers.

## Step 4 — Persistent report

Write a markdown report to
`~/Library/Logs/Prowl/measurements/reports/$(date +%Y%m%d-%H%M)-<branch-or-tag>.md`
(`mkdir -p` the directory; it lives with the rest of the measurement home, survives
reboots, and is never cleaned by the system). Reports are append-only history — never
overwrite or delete earlier ones.

Required sections:

- **Intent** — the mode the user confirmed, in one line.
- **Context** — date, branch, baseline and branch SHAs, load average and core count at
  run time, app/agent state if the live layer ran.
- **Results** — one table per layer: case, baseline shipped ms, branch shipped ms, delta,
  ratio vs floor.
- **Verdict** — `no-regression` / `watch` / `regression` / `major`, with suspect commits
  for anything above noise, and the host-canary observation.
- **Not run** — layers skipped or inconclusive, and why.
- **Raw refs** — the bench.jsonl SHAs and any script run directories.

Reply to the user with the verdict and the report path. The report, not the chat, is the
durable record.

## Reference

Benchmark inventory (all under `App/Tests/`, suite root `PerformanceBenchmarks`):

| Suite / check | Pins | Floor | Asserts in |
| --- | --- | --- | --- |
| `LineCountScanBenchmarks` sparse | #644/#652 memchr scan vs `Data.reduce` | 3x | all builds |
| `LineCountScanBenchmarks` all-newline | #652 hybrid dense fallback | 2x | optimized only |
| `FingerprintNormalizeBenchmarks` | #650/#657 escape-absence guard | 1.3x | optimized only |
| `WorktreeDirectoryIndexBenchmarks` | #648/#655 index vs per-row scan | 2x | all builds |
| `SessionScoringBenchmarks` | #650/#657 warm fragment cache | 3x | all builds |
| `make measure-titles` (live) | #649/#656 title coalescing ≤ ~1/s | 1.25/s | running app |

File → suite map for intent classification and suspect naming:

| Changed path | Affected check |
| --- | --- |
| `App/Sources/Clients/Git/GitClient.swift`, `UntrackedLineCountCache.swift` | LineCountScan |
| `App/Sources/Infrastructure/AgentDetection/AgentSessionResolver.swift` | FingerprintNormalize, SessionScoring |
| `App/Sources/Domain/WorktreeDirectoryIndex.swift`, `App/Sources/Support/PathPolicy.swift` | WorktreeDirectoryIndex |
| `App/Sources/Features/Terminal/Models/TerminalTabManager.swift`, `WorktreeTerminalState+AgentDetection.swift` | measure-titles, coalescing/dedup unit tests |
| Sidebar / Active Agents views and reducers | counting tests only (no timing suite) |

Caveats:

- `referenceMilliseconds` values measured inside the Release test bundle are not
  comparable to standalone `-O` binaries (~10x apart for `Data.reduce`); ratios are
  unaffected. Compare bench.jsonl rows only with other bench.jsonl rows.
- The suite is `.serialized` and `make bench` disables parallel testing and pins the
  destination arch deliberately — do not "speed it up" by removing either.
- `bench.jsonl` is append-only; the same SHA can have several rows (reruns). Prefer the
  newest row per (suite, name, SHA) and note reruns in the report.
