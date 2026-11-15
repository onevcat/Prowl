# 057.003 — Interaction Call-Path Counts

## Context

The benchmark suite measures pure functions in the test host. #1074 was a main-thread stall in
the running app that only macOS 26 showed: every developer machine and the CI image run
macOS 27, which hides it. Times measured on hosted runners do not compare across jobs, because
runner speed varies by about 2x.

## Change

`scripts/measure-interaction-counts.py` drives a Debug app and measures interactions:

- It seeds four repositories with three linked worktrees each, launches the app with an
  isolated home (`CFFIXED_USER_HOME`), data directory (`PROWL_DEBUG_DATA_DIRECTORY`), and CLI
  socket, and opens every worktree.
- Interactions: a worktree switch in one repository and across repositories (`prowl focus`),
  deactivation (`open -b com.apple.finder`), and activation (`open -a <app>`).
- `--mode counts` (default) attaches LLDB and counts auto-continue breakpoint hits per
  interaction: CoreFoundation string-table parses (`__CFBundleCreateStringsFromPlistData`),
  `String(localized: LocalizedStringResource)` calls, `AppShortcuts.helpText`, and with
  `--count-bodies` every `body` getter in the Prowl module (per view). A step ends when no
  counter changes for 1.5 s. Counts do not depend on machine speed.
- `--mode timing` attaches no debugger. After each interaction it sends `prowl list` and
  records how long the request waits. The CLI handler runs on the main thread, so the wait
  covers the work that the interaction started, plus a constant CLI cost. Compare two apps only
  on one machine in one job.
- `--compare`, `--merge`, and `--summarize` turn reports into Markdown tables.
- The Debug app shares its `UserDefaults` domain with the developer's Debug app; the script
  exports the domain before the run and restores it after.

The `interaction-counts` workflow builds the merge base with `main` and the head, then runs
both apps on `macos-26` and on the macOS 27 image: counts for each, and timing in two
alternating blocks per app. It writes the comparison to the job summary. It runs on demand or
on pull requests with the `perf` label, because it builds the app twice.
`make measure-interaction-counts` runs the counts locally.

Counts are the gate, timing is context. A hit count that grows on a hot path is a regression on
every machine; a time is only a hint until a second machine agrees.

## Refs

- #1074, PR #1116
- [070.002](../070-app-localization/002-resource-lookup-cost.md) — the first finding
