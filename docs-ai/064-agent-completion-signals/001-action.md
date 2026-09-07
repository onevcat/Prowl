# 064 — Agent Completion Signals: S1 Action

## Status

Complete and merged in PR #715.

## Slice objective

Ship the terminal-owned signal foundation as one vertical slice:

- a per-surface canonical observation record;
- an independent typed multicast observer for agent entry, signal, and surface lifecycle changes;
- cooperative `prowl agents signal` ingress attributed to the caller pane;
- the governed CLI parser, wire contract, router/handler, schema, renderer, tests, manuals, and skill updates.

S1 does not add `agents wait`, launch-scoped runtime hooks, workflow completion, or dispatch receipts.

## Owner decisions fixed before implementation

- Continue the 064 path before the 063 workflow runner. `prowl workflow deliver` remains the only command that completes a workflow step; agent signals are observation/control-plane evidence.
- Rename the runtime edge from ambiguous `turn-complete` to `turn-ended`. A runtime hook can prove that a turn ended, not that an assigned task completed.
- Reserve `dispatch-complete` for S2's paired dispatch protocol. S1 recorded the provisional
  shape; the final owner-reviewed command and receipt contract is in
  [003-s2-dispatch-wait-design.md](003-s2-dispatch-wait-design.md).
- Keep bounded `--detail` in S1 so a cooperative producer can attach a short result/reason without forcing another CLI command. The owner raised its limit from 4 KiB to 32 KiB before merge: this remains small relative to the 32 MiB socket frame and 1 MiB macOS argument budget while accommodating useful completion summaries. Detail is caller-authored metadata, never logged, never raises confidence, and is not a replacement for large transcript/workflow output channels.
- Public `--origin` is only a claimed origin. It cannot mark a channel as verified, raise confidence, or satisfy future hook self-checks. S3 may upgrade provenance only through a Prowl-configured launch-scoped capability; this is a correctness boundary, not a heavyweight security boundary.
- Each observer has bounded buffering. State churn may be recovered by a newer snapshot. Signal/lifecycle loss is never silent: overflow terminates with an explicit internal error, and S2's waiter must re-subscribe/resnapshot before exposing a failure.
- S1 signal state is in-memory and surface-scoped. S2 owns the separate bounded dispatch-receipt retention needed to survive surface closure.

## Implementation plan

1. Add `AgentSignal`, `AgentObservationSnapshot`, `ObservedAgentState`, and an explicit observer overflow error.
2. Add terminal-manager-owned per-surface observation records and multicast subscription APIs without reusing the single-consumer `TerminalClient.events()` stream.
3. Wire published agent entry changes/removals and every surface teardown path into the observer. Remove false/duplicate agent-removal emissions while preserving the existing reducer event stream.
4. Add context-aware `agents.signal` handling using kernel peer PID → process ancestry → live shell-PID ownership. Never fall back to focus or `PROWL_PANE_ID`.
5. Add the CLI four layers and strict text/JSON/schema contracts for `turn-ended`, `needs-input`, `session-start`, `session-end`, and `progress`.
6. Update current manuals, 063/064 living plans, and the bundled `prowl-cli` skill.
7. Run focused RED/GREEN tests, complete app/CLI validation, live Debug socket checks, then adversarial review for at least three rounds.

## Delivered implementation

- Added terminal-owned `AgentObservationStore` records with atomic replay snapshots,
  independent bounded subscribers, explicit overflow, latest-signal replay, cancellation
  cleanup, and `removed` / `surfaceClosed` separation.
- Routed the existing detector's published entries into the store while correcting cleanup
  so a warmed shell that never published an agent no longer emits a false removal.
  Pane/tab/prune/close-all and split rollback converge on exactly-once surface cleanup.
- Added `AgentSignalCommandHandler` and the complete `agents.signal` CLI surface. The app
  resolves only the socket peer's process ancestry; normal shell panes can signal without a
  detected agent, while outside callers fail with `SOURCE_REQUIRED`.
- Added shared parser/handler validation, fractional ISO-8601 timestamps, strict wire payload,
  text receipt, executable schema, raw socket fixtures, manuals, 063/064 plan amendments, and
  `prowl-cli` skill guidance.

## Verification record

Observed passing before the first commit:

```bash
make build-cli
make test-cli-smoke
make test-cli-integration   # 87 tests
make check                  # format, strict swift-format lint, SwiftLint, 27 script tests
make test-app               # xcresult verified: 2423 tests, zero failures
make build-app
```

Focused RED/GREEN coverage includes 9 observer/lifecycle tests, 5 handler validation tests,
parser/envelope/router/renderer/schema tests, caller ancestry, kernel `LOCAL_PEERPID`, app
composition, and an actual Unix socket request through `CLISocketServer` into the signal
handler. The full test run initially hung because that new socket test used blocking file-I/O
inside a detached Swift task that the generic executor scheduled on the OS main thread; a
sample identified the stack, the test client moved to a dedicated dispatch queue, and the
2423-test run then completed.

An isolated Debug app was also launched on a custom socket. The bundled CLI successfully
exercised `list`, `agents`, `create`, and outside-caller rejection (`SOURCE_REQUIRED`). A
second app instance did not materialize Ghostty child surfaces (blank pane, no command/read),
so an inside-pane GUI signal could not be attested in that environment; the real Unix-socket
context test and app-composition observer test cover that path automatically.

After round 3, final validation repeated `make check`, CLI smoke/integration (87 tests), the
app xcresult (2423 tests), and `make build-app`. An isolated custom-socket Debug launch again
passed `list`/`agents` and returned `SOURCE_REQUIRED` for an outside `agents signal`; 11
focused tests re-verified real kernel peer-PID framing, app signal recording, and observer
delivery. All final commands passed; only the documented concurrent-instance Ghostty UI
limitation remains. A pre-merge owner follow-up then raised `--detail` to 32768 UTF-8
bytes; exact ASCII and multibyte boundary tests, CLI integration, app tests, lint, and the
Debug build were repeated for that amendment.

## Review record

### Round 1 — `99f0baa9`

Independent adversarial review found no P0/P1 defects after reading the full diff and running
60 focused tests. It confirmed snapshot atomicity, overflow signaling, teardown ordering,
MainActor discipline, caller attribution, four-layer CLI parity, and S2 decision consistency.
Four credible P3 hardening/docs findings were accepted before the next round:

- document the manager-owned live-surface invariant at lazy publication sites;
- remove whole-record copy/write-back from subscriber publication so future synchronous
  termination reentrancy cannot clobber subscriber-map mutations;
- reconcile the pre-existing S2 exit contract to `--until exit`;
- document the defensive `AGENTS_FAILED` receipt-encoding failure.

Format-category filtering was deferred as optional S2 hardening; the pre-existing blocking
socket-framing architecture remains outside S1 and should be revisited before high-volume
hook fan-in.

### Round 2 — `a63ba4a4`

A fresh pass re-verified the full diff and all round-1 fixes, then ran 60 focused tests and
lint. It found no P0/P1. Two credible P3 hardening items were accepted: close-all/prune tests
now pin `changed → removed → surfaceClosed → finish` with a published agent, and synthetic
dead-surface snapshots explicitly document that `surfaceClosed` is authoritative after the
revision resets. Already-terminated continuations are no longer mislabeled as overflow.
The internal subscriber-count seam remains deliberately available for diagnostics/S2 health.

### Round 3 — `f26eb780`

The final merge-gate pass re-derived the full design from HEAD and ran `make test-app`
(2423 tests), CLI integration (87 tests), and `make check`. It found no P0/P1/P2 and declared
the PR merge-ready. No code changes were requested. The known second-instance Debug Ghostty
limitation remains non-blocking because kernel peer-PID framing, ancestry resolution, app
composition, signal recording, and observer delivery are covered by executable tests; a
single-app live pane check remains a cheap follow-up after the next normal Debug install.

### Post-gate 32 KiB amendment — `8a594d11`

A focused independent review of the owner-requested limit increase found no P0/P1/P2. It
verified UTF-8 byte semantics, the 32 MiB frame and 1 MiB argv headroom, and an approximately
2 MiB worst-case payload per surface when a slow subscriber fills all 64 buffered events.
One optional P3 was accepted: CLI help now derives the number from the shared constant, and a
contract test pins the executable schema's `maxLength` to that constant.
