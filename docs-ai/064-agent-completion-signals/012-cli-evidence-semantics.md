# 064.012 — CLI Evidence Semantics Follow-up: Plan and Action

## Status

Implemented in [#732](https://github.com/onevcat/Prowl/pull/732) from `feat/cli-wait-signal-read-semantics`. Follow-up to S1/S2
(`prowl agents signal`, `agents wait`, `agents read`) after an end-to-end exercise of the
bundled `prowl-cli` skill on 2026-08-28 against the app built from `main` at `199fceb5`.

## Trigger

Driving Prowl strictly by the `prowl-cli` skill worked end to end — identity guard, prompted
Profile launches for Claude Code and Codex, `hook_claude` / `hook_codex` `verified_live`
channels, succeeded receipts, `DISPATCH_NEEDS_INPUT` → intervention → succeeded,
`DISPATCH_INCOMPLETE` → follow-up → succeeded, `DISPATCH_ABANDONED`, and both `AGENT_GONE`
modes. Four behaviors, however, made the documented flows unreliable in practice:

1. `agents read` returned `result.state == "complete"` with the *previous* turn's text while
   the agent was blocked on a new turn (`AgentReadCommandHandler.makeResult` consulted only the
   transcript).
2. `agents wait --until blocked` returned immediately on a cooperative `needs-input` sent two
   minutes earlier while the agent was already idle again: `activeTerminalSignal` is a level
   that `publishAgentChanged` clears only on the *next* transition into `working`, and
   `exactMatch` compared nothing against the arm-time state.
3. `agents wait` on a pane whose agent was still starting failed instantly with
   `AGENT_NOT_FOUND` (arm-time-only check), and prompts sent during that window merged into one
   message.
4. `agents signal` returned `ok`, `confidence: exact` even when `bindingForSignal` had classified
   the signal `unbound` (plain shell pane; caller outside the agent's process tree), so the
   caller could not tell that the signal would never count as evidence.

Documentation also referenced a `prowl workflow deliver` command that does not exist yet (063
R2), and omitted `AGENT_NOT_FOUND` (wait), `DISPATCH_NOT_FOUND`, `DISPATCH_CONTEXT_REQUIRED`,
and `DISPATCH_ALREADY_TERMINAL`.

## Decisions (grilled with onevcat, 2026-08-28)

| # | Decision | Alternatives rejected |
| --- | --- | --- |
| A1 | `agents read` returns `pending` whenever the live status is `working` or `blocked`, without reading the transcript; `complete` only for idle/done. | Comparing transcript timestamps with `last_changed_at` (two clocks); doc-only. |
| A2 | Condition waits keep level semantics, but a terminal signal that already existed at arm time satisfies `idle`/`blocked` only when the screen detector corroborates it; a signal arriving after arming counts on its own. `changed` stays the edge wait. | Pure edge semantics (hangs when the turn ended between `send` and arming, especially with heuristics suppressed by a `verified_live` channel); doc-only. |
| A3 | No detected agent at arm time is not an immediate failure: poll for up to `agentAppearanceGraceMilliseconds` (10 s), bounded by `--timeout`, then fail with `AGENT_NOT_FOUND` carrying condition-mode details. | Waiting the full `--timeout` (a mistargeted shell pane would hang 600 s); fail-fast plus a skill-side polling recipe. |
| A4 | `agents signal` reports `data.signal.binding` (`current` \| `unbound`) and adds `data.warnings[{code: "signal_unbound"}]` for unbound receipts; `ok` stays true because the signal is retained as diagnostics. Text mode prints the warning once on stderr. | Failing with a new `SIGNAL_UNBOUND` code (contradicts "recorded"); binding field without a warning. |
| B1 | Docs describe only shipped commands: `turn-ended` is a runtime turn edge and only an `agents dispatch-complete` receipt proves an assigned task finished. | "Planned" wording; deleting the sentence. |
| — | One PR, commits per item, with this record amending 064. | Docs-first PR followed by a code PR (would document the level semantics twice). |

## Delivered behavior

- `AgentWaitCommandHandler`: `ConditionBaseline` captures the arm-time revision, changed
  signal, terminal signal, and detector state; `exactMatch` demands detector corroboration for
  a baseline-identical terminal signal (`detectorReports`). The appearance grace loop precedes
  baseline capture, counts toward `waited_ms`, and returns `AGENT_NOT_FOUND` with
  `.error.details` (`mode: condition`, `waited_ms`, `target`, `signals`, optional `screen`).
  `--until exit` keeps its previous behavior.
- `AgentReadCommandHandler.makeResult`: live `working`/`blocked` short-circuits to `pending`
  before any transcript read; `--result-only` therefore fails with `RESULT_NOT_FOUND` during a
  turn.
- `WorktreeTerminalManager.recordAgentSignal(_:caller:)` returns
  `AgentSignalRecordOutcome` (`recorded(binding:)` | `paneGone`); the handler maps it to the
  receipt's `binding` and `warnings`. `AgentSignalPayload.binding` and
  `AgentSignalCommandPayload.warnings` are additive on `prowl.cli.agents.signal.v1`; the schema
  restricts `binding` to `current`/`unbound` and `warnings` to exactly one `signal_unbound`
  item. `OutputRenderer.agentSignalWarningLines` renders the stderr line.
- Docs: `docs/components/cli.md` (read/signal/wait semantics, dispatch caveats, error table,
  gotchas), `docs/components/agent-detection.md`, `skills/prowl-cli/SKILL.md`, and the
  contract pages under `docs-ai/013-prowl-cli/contracts/`.

## Verification

- Red first: 7 new app-side tests failed for the right reasons (2 read, 2 wait corroboration,
  3 appearance grace) plus the handler's unbound-warning test; CLI schema and renderer tests
  failed before the schema/renderer change. All green after implementation, with the existing
  wait/read/signal/observation/socket suites unchanged.
- `make check`, targeted `xcodebuild test` suites, `make build-cli`, `make test-cli-unit`,
  `make test-cli-smoke`, `make test-cli-integration`, `make build-app` (see the PR).

## Review

Three adversarial rounds with the `Pi Reviewer` Profile launched beside the coordinator via
`prowl create pane --profile … --prompt -` and awaited with `agents wait --dispatch`; briefs and
findings stayed outside the repository. Each accepted finding was fixed test-first.

- Round 1 — P1: `makeResult` checked the transcript session before the live status, so a live
  agent without a resolved session reported `unavailable` instead of `pending`; P2: the schema
  neither required `signal.binding` nor paired `unbound` with its warning. Fixed in 4965fc00.
- Round 2 — P1: the tightened schema rejected the two `agents.signal` integration fixtures
  (`make test-cli-integration` red); P3: the skill named only one `unbound` cause. Fixed in
  7f457b5b.
- Round 3 — P3 only: the skill overstated when an already-idle agent returns immediately.
  Fixed in the closing docs commit; loop closed with no P0–P2 open.

Two operational lessons from the loop: a second concurrent `xcodebuild test` in the same
checkout hangs the build service (the reviewer's run sat 27 min at 0 % CPU), and a Profile
launch fails with `CREATE_FAILED` while the display is asleep (see the 064 S3c notes) — both
handled by serializing app test runs and keeping the display awake during unattended rounds.

## Observed but not changed

- Cooperative signals are still coalesced by state at a 200 ms poll: `needs-input` followed
  within one interval by `turn-ended` leaves only the `turn-ended` observable (1 miss in 2
  live trials). Documented as a producer rule rather than changed.
- One live trial saw a lone cooperative `needs-input` from a manually launched Claude Code
  session fail to bind (`unbound`), not reproduced in three later trials. A4 makes such a drop
  visible on the receipt; the root cause (detector process/session evidence at the moment of
  attribution) is left for the drift-guard work in #726.
- A closed worker's pending dispatch turns `gone` ~300 ms after `close`; documented.
