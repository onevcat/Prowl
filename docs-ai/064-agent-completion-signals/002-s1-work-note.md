# 064-S1 — Implementation Work Note

This note tracks the authorized S1 execution. Durable design decisions belong in
`000-plan.md`; delivered behavior and evidence are finalized in `001-action.md`.

## Starting point

- Branch: `feat/agent-completion-signal-bus`
- Base: `origin/main` at `cc800c6f`
- PR #714: merged; A2 is available for later S3 launch-hook injection
- Worktree: clean at branch creation
- Protected ignored path: `scripts/__pycache__/` (do not touch)
- Point-Free/TCA/Observation skill: not available in the current environment

## Confirmed seams

- `WorktreeTerminalManager.eventStream()` is strictly single-consumer; `AppFeature` owns its production subscription. S1 must use a separate multicast path.
- `WorktreeTerminalState` produces consumer-visible `ActiveAgentEntry` changes. `ActiveAgentsFeature` is a reducer projection and must not become observer truth.
- Existing agent cleanup emits removal unconditionally in some paths, including warmed panes that never published an agent entry. S1 must make `removed` mean a previously published entry actually disappeared.
- Surface teardown spans pane close, tab close, worktree prune/close-all, and split insertion rollback. Every path must produce at most one `removed` followed by `surfaceClosed`, then finish subscribers.
- `CLISocketServer` supplies a same-UID kernel peer PID in `CLICommandContext`; `CallerPaneResolver` maps its ancestry to live shell PIDs without focus/env fallback.
- CLI additions must update parser, shared input/payload, command envelope, router/handler/app wiring, executable schema, socket fixtures, text renderer, manuals, and skill in one change.

## RED checklist

- [x] Domain/wire validation: event/progress combinations, bounded session/origin/detail, NUL/control rejection.
- [x] Observer: snapshot first, normal shell snapshot, two concurrent subscribers, signal multicast, cancellation, overflow, removal without close, close ordering, already-closed surface.
- [x] Lifecycle regressions: never-published agent does not emit removal; pane/tab/prune/close-all/rollback converge on guarded cleanup.
- [x] Caller attribution: missing peer PID, ancestry miss, exact pane match, no focus fallback.
- [x] CLI: parsing, envelope coding, router context, handler success/failures, renderer, raw socket/schema round trip.

## GREEN / validation checklist

- [x] Focused app tests through `xcodebuild ... | xcsift -f toon`.
- [x] `make build-cli`
- [x] `make test-cli-smoke`
- [x] `make test-cli-integration` (87 tests)
- [x] `make check`
- [x] `make test` / `make test-app` (2423 xcresult tests, zero failures)
- [x] `make build-app`
- [x] Launch isolated Debug app/socket and exercise bundled CLI `list`, `agents`, `create`, plus outside-caller `SOURCE_REQUIRED`.
- [x] Caller-attribution success covered end to end by real Unix socket peer PID, ancestry, app-composition recording, and observer-delivery tests. A live second Debug pane was attempted but its concurrent-instance Ghostty child did not materialize; recorded as a non-blocking environment limitation.
- [x] Three adversarial review rounds completed; all P0/P1/P2 clear at the final gate, accepted hardening fixed and recorded in PR comments.
- [x] Final Debug build and basic custom-socket E2E after review (`list`/`agents` success, outside caller rejected with `SOURCE_REQUIRED`, focused real-socket/app-observer tests pass).

## Deferred S2 contract (must not be lost)

This was the provisional S1 handoff. The owner-reviewed S2 command spelling, outcomes,
receipt lifecycle, and wait semantics are finalized in
[003-s2-dispatch-wait-design.md](003-s2-dispatch-wait-design.md).

S2 owns one atomic paired-dispatch slice:

```text
create --profile --prompt
  → return opaque dispatch_id
  → cooperative dispatch-complete --detail
  → bounded non-destructive in-memory receipt keyed by dispatch_id
  → agents wait --dispatch (automatic overflow resnapshot)
```

The dispatch receipt survives agent/pane closure but not app restart. A later dispatch cannot
be satisfied by an older receipt. Internal surface generations remain only an unpaired
observation fallback. Full workflow output continues through `prowl workflow deliver -`; large
ad-hoc results continue through `agents read` or a future `agents wait --include-result`.

## Progress log

- 2026-08-22 — Preflight investigation and owner grill completed; branch created and the decisions above recorded before tests/code.
- 2026-08-23 — Observer and CLI RED/GREEN phases completed; full contract/manual/skill updates landed locally. CLI integration passed 87 tests and app xcresult passed 2423 tests. A full-suite deadlock in the newly added blocking socket test was sampled and fixed by moving test-client I/O to a dispatch queue. Initial isolated Debug socket validation completed with the second-instance Ghostty limitation recorded above.
- 2026-08-23 — Adversarial review round 1 at `99f0baa9`: no P0/P1; accepted four P3 hardening/docs findings (publisher liveness invariant, reentrancy-safe subscriber mutation, S2 `--until exit` reconciliation, encode-failure contract).
- 2026-08-23 — Adversarial review round 2 at `a63ba4a4`: no P0/P1; accepted stricter published-agent close-all/prune ordering coverage plus precise dead-surface revision/terminated-continuation semantics.
- 2026-08-23 — Adversarial review round 3 at `f26eb780`: no P0/P1/P2, merge-ready. Final validation repeated `make check`, CLI smoke/integration (87), app xcresult (2423), Debug build, isolated custom-socket discovery/rejection, and 11 focused socket/app-observer tests.
- 2026-08-23 — Owner follow-up raised `--detail` from 4 KiB to 32 KiB before merge. ASCII and multibyte boundary tests went RED/GREEN; CLI smoke/integration (87), app xcresult (2423), `make check`, and Debug build passed. A 32768-byte argument crossed the real Debug Unix socket into the app, while 32769 bytes failed at CLI validation. Focused post-gate review found no P0/P1/P2; its optional P3 was accepted by deriving help from the shared constant and pinning schema `maxLength` to it in a contract test.
