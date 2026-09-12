# 064.023 — Provider Continuity and Decision Diagnostics

Follow-up: [024](024-observation-order-and-emission.md) corrects residual capture-order,
suspended-fallback, emission, and diagnostic gaps in this implementation.

## Context

Review of #800 found that provider cursors could advance before the coordinator
accepted their events. Temporary process-probe gaps and incomplete inventories
also removed state that was needed after recovery.

## Decisions and changes

- Serialize observations per coordinator. Only lifecycle invalidation changes the
  generation revision; concurrent readers cannot discard a consumed event batch.
- Retain the last process generation through presence holds. The provider still
  validates that generation before and after process-bound reads. Confirmed
  replacement and close invalidate the state as before.
- Keep completion suppression through suspended authority. Bind it to its root;
  the sole known root's unchanged completed frame stays fenced after activity
  expiry. Ambiguous inventories do not inherit that authority, and a different
  root's blocker remains visible.
- Accept original main sources `cli`, `exec`, `vscode`, and `mcp` on resumed logs.
  Unknown sources and unresolved child lineage suspend acquisition, cache known
  headers, and preserve cursors. They are not silently excluded from selection.
  Corrupt data, replacement, and truncation still require a new baseline.
- Scan appended lines by index and compact the buffer once per read. Existing
  bounds and partial-line behavior remain unchanged.
- Use typed decision reasons. Both CLI snapshots expose the final
  `detection_reason` and the separate `screen_reason`; screen-only runtimes retain
  their existing rule identifiers. Remove the unused `stabilizeAgentState` helper
  and test its policy through the live coordinator.
- Report acquisition failure categories, PID, and cursor count with `SupaLogger`.
  Warning output is limited to once per provider per 30 seconds. A successful
  read reports recovery once after a reported failure. No screen or transcript
  content enters these logs.

## Deliberate limits

The process/session resolver's duplicate generation reads are left unchanged;
removing validation or parallelizing independent consumers is not required for
correctness. Incomplete FD inventories still suspend authority, including
`ENOENT` and `EBADF`: these errors do not prove that a missing descriptor cannot
be relevant. A forced-unmount scenario has not been reproduced in this work.

This change adds bounded acquisition diagnostics, not the proposed opt-in flight
recorder or debug dump command. It does not provide a replay of past decisions.

## Verification

Each behavioral fix started with a failing test: overlapping observations,
presence gaps, suspended and expired completion fences, cross-root blockers,
original sources, unresolved lineage, CLI reasons, and diagnostic rate limits.
A local optimized probe against the actual provider read the same 2 MiB fixture
in 5.30 seconds before the buffer fix and 0.106 seconds after it, with the same
lifecycle events. This machine-specific timing gate is not a CI test.

Final verification passed: 112 selected Swift tests, 105 CLI unit/integration tests,
CLI build and smoke checks, `make check` (including 153 script tests), and
`make build-app`. Swift test and app build output reported no errors or warnings.

Native Debug-app E2E used the isolated test socket and disposable panes. During a
command-approval turn, 484 `agents read` requests and 532 list requests both observed
`codex.confirmationFooter` → `log.openWork` → `log.turnEnded`, with no request errors
or return to Working after completion. Both Blocked and Idle condition waits
returned successfully. The two reason fields agreed on the blocker while retaining
separate log and screen reasons during work.

Claude completed with `claude.spinner` → `claude.idleComposer` across 139 samples;
Pi completed with `legacy.detector` across 138 samples. Both returned the expected
terminal response. These are terminal/state integration checks, not desktop visual
acceptance. The test panes, Debug instance, and temporary authentication link were
removed. Local receipts are under `.local/agent-screen-captures/provider-e2e/`
(`review-concurrent-verified.json` and `review-screen-paths-verified.json`).
