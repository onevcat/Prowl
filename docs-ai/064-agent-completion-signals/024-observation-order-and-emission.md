# 064.024 — Capture Order, Emission, and Contract Continuity

## Context

A second review of #800 found gaps in 023's fixes. Serialization alone does not
order frames captured before an asynchronous session lookup. Retaining a completion
fence also does not help if fallback ignores it on the suspended observation itself.

## Changes

- Stamp screen capture with monotonic uptime before session resolution. After taking
  the observation gate, discard older observations before changing either the screen
  or process binding. Their callers receive the current decision without consuming
  another log batch. Lifecycle invalidation clears this ordering barrier.
- Separate internal process rebinding from public lifecycle invalidation. A queued
  replacement no longer cancels valid observations queued behind it. Explicit close
  or cleanup still rejects in-flight and queued results.
- Honor a completed sole root's retained frame during suspended acquisition, including
  before its activity window expires. Open work, changed frames, interaction, and
  revoked continuity do not receive this exception.
- Exclude diagnostic reasons only at entry-emission and title-coalescing boundaries.
  Preserve normal decision equality and work/session evidence. CLI list snapshots
  take live decisions from terminal state so UI deduplication cannot stale diagnostics.
- Add `screen_reason` to both closed CLI agent schemas. Validate serialized production
  payload types, including rejection of a non-string reason. Update the CLI skill,
  normative read/list contracts, and user manual with decision/screen disagreement rules.
- Throttle warnings per failure category. Track failures even when a repeat warning
  is throttled, so recovery remains visible. Continuity-loss warnings show the cleared
  cursor count and a bounded decoder/failure kind or I/O/JSON error code.

## Review dispositions

| Finding | Decision |
| --- | --- |
| 1. Diagnostic emission churn | Fix at emission boundaries; do not redefine decision equality. |
| 2. Older captured frame applied last | Fix with capture ordering, before process rebinding as well as screen application. |
| 3. Suspended observation revives a completed frame | Fix for the existing sole-root completion scope. Removing only `available` while retaining `eligible.isEmpty` would not fix recent completion. |
| 4. Schema and manual drift | Fix both schema objects and all listed contract/manual surfaces. |
| 5. Diagnostic throttle blind spot | Fix category throttling, recovery tracking, post-reset counts, and bounded continuity error details. FD errno/source-token forensic detail remains limited. |
| 6. Queued rebind invalidates following observations | Fix by separating internal reset from public invalidation. |
| 7. Multi-root expired completion fence | Retain the explicit sole-known-root policy from 023. With multiple open mains, an unchanged frame is not proof that the previously completed main is still foreground. An old frame can reappear as Working/Blocked after expiry; no completion guarantee is claimed in that fallback. |
| 8. Absent/null legacy source | Retain screen fallback. Missing/null source is not accepted lineage; old resumed headers can remain suspended. Do not assume missing-field defaults also accept explicit JSON null. No local legacy-resume compatibility proof was produced in this round. |
| 9. Repeated file attributes/root traversal | Confirmed repeated work; defer to acquisition performance work. Reusing metadata also changes when replacement/truncation is checked, so it is not part of this correctness patch. |
| 10. Unknown child lifecycle schema resets continuity | Retain the documented fail-closed policy. Ignoring an unknown lifecycle event can lose child work; resetting only a child file also affects its root's work accounting. Future protocol support needs an explicit compatibility policy. |

The previous live E2E result in 023 remains evidence for that observed run, not proof
against all interleavings. Deterministic tests now reproduce previously untested ordering
and suspension failures. Diagnostic logs are bounded acquisition evidence, not a complete
state replay. Per-category repeated failures may still be throttled within 30 seconds.

## Verification

Initial red runs reproduced all five new behavioral regressions, both schema
rejections, and the live-list stale-reason case. Final green verification passed
67 selected app tests, 291 CLI unit tests (including the production-payload schema
check), and 105 CLI integration tests. CLI build, smoke tests, and `make check`
(including 153 script tests) passed. `make build-app` passed with no errors or warnings.

No new live TUI E2E or energy benchmark was run in this round. The new timing/order
failures are covered with deterministic continuations and injected capture times;
prior live observations remain scoped to the runs recorded in 022 and 023.
