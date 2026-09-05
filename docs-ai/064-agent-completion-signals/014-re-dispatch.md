# 064.014 — Re-dispatch Into an Existing Pane: Plan and Action

## Status

Implemented from `feat/agent-redispatch` for [#733](https://github.com/onevcat/Prowl/issues/733)
(R2a in the shared [release plan](../063-agent-workflows/release-plan.md)). Amends S2
([003](003-s2-dispatch-wait-design.md)) and the evidence rules of [012](012-cli-evidence-semantics.md) /
[013](013-idle-evidence-fallback.md); the 063 workflow runner consumes the store primitive
introduced here for `message` steps ([dsl-spec §5](../063-agent-workflows/dsl-spec.md)).

## Trigger

A coordinator running several review rounds against one reviewer had to choose between a
plain `send` (context kept, no receipt — "asked a question" looks like "finished") and a fresh
Profile launch per round (exact receipt, context lost, every round re-reads the diff and is
exposed to startup failures again). The #732 loop launched three Profiles for that reason;
063's `prowl.adversarial-review` wants one interactive reviewer that is re-dispatched until
its verdict is clean.

Before this change a dispatch record existed only for a prompted Profile launch: the id rode
the child-only `PROWL_DISPATCH_ID`, `dispatch-complete` read it back from the environment, and
a pane therefore had at most one dispatch for its whole lifetime.

## Decisions

| # | Decision | Alternatives rejected |
| --- | --- | --- |
| D1 | `prowl agents dispatch <pane> --prompt -` creates a new pending record bound to the existing surface and delivers `[Prowl] ` + prompt + the same versioned completion protocol a launch appends, through the pane's input path (`insertCommittedText` + `submitLine`, the `send` path). The response has the `create` shape (`target`, `dispatch.{id,state,created_at}`). | A `--dispatch` flag on `send` (would make an ordinary send grow receipt semantics); a compact single-line protocol suffix (unnecessary once delivery was measured, and would diverge from the launch prompt agents already recognize). |
| D2 | Multi-line prompts are accepted. Measured: `ghostty_surface_text` routes through `Surface.completeClipboardPaste` → `input.paste.encode`, which wraps the text in bracketed paste (`\x1b[200~ … \x1b[201~`) whenever the TUI has mode 2004 on and otherwise rewrites `\n` as `\r`; a three-line `prowl send` reached both Claude Code 2.1.251 and Codex 0.149.1 as one message (each replied `RECEIVED 3 lines`). The CLI normalizes CRLF and drops trailing newlines; the app rejects any control character other than newline and tab (ESC and the C0 bytes the paste encoder strips to spaces) with `INVALID_ARGUMENT`. Cap 256 KiB, as for `create --prompt`. | Requiring a single line (the fallback the issue anticipated if delivery had split the text). |
| D3 | `dispatch-complete` resolves the record from the caller's process ancestry → pane → that pane's current pending record; with no pending record it addresses the pane's most recently issued record so an identical retry still replays and a conflicting one still fails. `PROWL_DISPATCH_ID` stays launch-scoped, the CLI forwards it when present, the app only logs it when it differs. `DispatchCompleteInput.dispatch_id` became optional (an old CLI still sends it; a new CLI without the variable no longer fails client-side with `DISPATCH_CONTEXT_REQUIRED`). | Requiring the id to match the current record (would break a launched worker after its first re-dispatch, contradicting the issue); a public `--dispatch` on completion (breaks the "no public id" trust model). |
| D4 | One pending record per surface, enforced in the store: `bind` throws `surfacePending` when the surface already holds a pending record (self-rebinding stays idempotent), `pendingSnapshot(surfaceID:)` answers the handler, and the manager checks before issuing so no slot is consumed. A second `dispatch` fails with `DISPATCH_PENDING` carrying the pending record; nothing is typed. | Checking only in the handler (the launch and re-dispatch paths would still be able to race for one pane); superseding the previous record (would silently abandon a running assignment). |
| D5 | The idle precondition reuses the wait handler's evidence rules instead of a new heuristic. The pure evaluation (`exactMatch`, `detectorReports`, `allowsHeuristic`, `heuristicMatches`, the two-second `HeuristicStabilizer`, `normalizedState`) moved from `AgentWaitCommandHandler` into `AgentConditionEvidence`, and `agents dispatch` evaluates the arm-time `--until idle` decision under `auto`: a `turn-ended` level counts only with detector corroboration (every level is pre-arm at dispatch time), a detector-only idle view must stay unchanged for two seconds and only where the wait would fall back to the detector. Idle by one source alone is not yet a refusal — the wait would keep polling — so the precondition polls for up to five seconds (`idleGraceMilliseconds`, covering detector sampling, poll skew, and the two-second stabilization) and only then refuses; working or blocked without such evidence, or a runtime `needs-input` the screen does not show, is `DISPATCH_TARGET_BUSY` immediately, with the observation and signals in `error.details`. `AGENT_NOT_FOUND` has no appearance grace: the command targets an agent that already exists. | Blocking until idle with a `--timeout` (the issue asks for a refusal, and a coordinator that wants to wait has `agents wait --until idle`); accepting the detector's idle view without stabilization (a transient screen would let text merge into a running turn); refusing an uncorroborated `turn-ended` immediately (the first live run did: `--until idle` resolved on the fresh hook signal while the detector still held `working`, and the dispatch issued in the same second was refused — the recipe's two commands must work back to back). |
| D6 | The record binds to the pane's *current* evidence epoch (after reconciling the detector's process generation), never to a new one: the generation that will report the receipt is the one already proven for the pane, so its managed-hook and cooperative signals keep counting. A pane without an epoch record cannot be dispatched to (`DISPATCH_FAILED`). | Calling `beginDispatchEpoch` as the launch path does (its ten-second first-generation window would reject the long-running agent and silence its `verified_live` channel). |
| D7 | Wire additions: `Command.agentsDispatch(DispatchInput{pane,prompt})` → `agents.dispatch`, response `prowl.cli.agents.dispatch.v1` (`AgentDispatchCommandPayload`), governed `AgentDispatchErrorDetails{target,record?,observation?,signals?}` behind `agentsDispatchError`, and the new codes `DISPATCH_PENDING` / `DISPATCH_TARGET_BUSY`. Text mode renders the pending id and refusal evidence. | Reusing the condition-mode wait error details (their `mode`/`condition` fields would lie). |

## Delivered behavior

- `AgentDispatchStore`: `pendingSnapshot(surfaceID:)`, `complete(surfaceID:outcome:summary:)`
  (pending → latest → `notFound`), and the `surfacePending` guard on `bind`.
- `WorktreeTerminalManager`: `issueAgentDispatch(boundTo:)` (issue + bind to the current epoch
  in one main-actor step, rolling back the issuance on a bind failure),
  `pendingAgentDispatchSnapshot(surfaceID:)`, `completeAgentDispatch(surfaceID:…)`; the four
  copies of the evidence-epoch refresh collapsed into `refreshEvidenceEpoch(surfaceID:)`.
- `AgentConditionEvidence` (new) holds the shared condition rules; `AgentWaitCommandHandler`
  keeps its behavior and tests through `typealias ConditionSnapshot = AgentConditionSnapshot`.
- `AgentDispatchCommandHandler` (new): validate → resolve pane → `DISPATCH_PENDING` →
  `AGENT_GONE` / `AGENT_NOT_FOUND` → idle verdict (`DISPATCH_TARGET_BUSY`) → issue+bind
  (`DISPATCH_CAPACITY_EXCEEDED`, `DISPATCH_PENDING` on a race, `DISPATCH_FAILED`) → deliver
  (`DISPATCH_FAILED` cancels the issuance) → `target` + pending `dispatch`.
  `AgentDispatchCompleteCommandHandler` now completes by caller surface.
- `AgentDispatchPrompt.renderInjected(userPrompt:)` = `[Prowl] ` + the launch rendering.
- CLI: `prowl agents dispatch <pN|uuid> --prompt -` (`AgentsDispatchPromptCommand.swift`),
  `dispatch-complete` without a required environment id, text renderers, the executable
  schema (`agentsDispatchResponse`, `agentsDispatchErrorDetails`), and the mock-socket
  integration fixtures.
- Docs: `docs/components/cli.md`, the contract pages (`agents-wait.md`, `input.md`,
  `schema.md`, `agents.md`), and the `prowl-cli` skill's "reuse one reviewer across rounds"
  recipe with the `--until idle` step between rounds.

## Verification

- Store, handler, evidence, lifecycle, signal, and hook-carrier suites via `xcodebuild test`;
  CLI parsing, wire-model, schema, renderer, and socket round-trip tests via SwiftPM; `make
  check`, `make build-cli`, `make test-cli-unit`, `make test-cli-smoke`,
  `make test-cli-integration`, `make build-app` (results in the PR).
- Delivery measurement (D2) against the baseline Debug build in an isolated instance
  (`CFFIXED_USER_HOME` scratch home, `PROWL_CLI_SOCKET=/tmp/redispatch.sock`): unprompted
  "Claude Code" and "Codex" Profiles, `printf '%s\n' <three lines> | prowl send --pane … --no-wait`;
  both TUIs echoed the three lines as one composer entry and answered `RECEIVED 3 lines`.
- Live end-to-end against the branch's Debug build in the same isolated instance, with the
  "Claude Code" (2.1.251) and "Codex" (0.149.1) Profiles and the branch's CLI on the
  agents' `PATH` (full transcript in the PR):
  - `create tab --profile … --prompt -` → `wait --dispatch` succeeded (Claude Code 5 s;
    Codex first returned `DISPATCH_INCOMPLETE` — see below — and the re-armed wait returned
    the receipt).
  - `wait --until idle` (exact `hook_claude` / `hook_codex`) → `agents dispatch <pane> --prompt -`
    → pending record → a second `dispatch` in the same second refused `DISPATCH_PENDING` with
    the record in `error.details` → `wait --dispatch` succeeded in 2.7 s / 4.0 s with
    summaries that reference round 1 ("previous round was ROUND 1"), i.e. the same session
    completed the new record although its process was launched with the round-1
    `PROWL_DISPATCH_ID`. The pane shows the `[Prowl] ` prefixed prompt and protocol as one
    composer entry.
  - A plain `send` that keeps the agent busy (`sleep 20`) → `dispatch` refused
    `DISPATCH_TARGET_BUSY` (`observation.status: working`) for both runtimes → `wait --until
    idle` resolved on the fresh hook `turn-ended` while the detector still held `working` →
    the dispatch issued in the same second settled within the grace (record created 3 s after
    the wait resolved) → round 3 asked for `--outcome failed` → `wait --dispatch` returned
    `DISPATCH_FAILED` with the failed receipt, for both runtimes.
  - `dispatch-complete` from the coordinator's own shell (outside any pane) →
    `DISPATCH_CONTEXT_REQUIRED`; from a plain shell pane that never held a dispatch →
    `DISPATCH_NOT_FOUND`.

## Observed but not changed

- Codex emitted a `turn-ended` before running the completion command on its first prompted
  turn (the "usage limit reset available" notice preceded the tool call), so the first
  `wait --dispatch` returned `DISPATCH_INCOMPLETE` and a re-armed wait returned the receipt
  twelve seconds after issuance — the S2 incomplete → re-arm flow, unchanged.
- A re-dispatch into a manually launched agent (no `verified_live` channel) takes the
  two-second detector stabilization every time; documented, and the exact path resolves at once
  once the agent has reported `turn-ended` cooperatively.
- `agents dispatch` types into the pane but never focuses it, so a background reviewer stays
  in the background; a person typing into that pane at the same moment would interleave, as
  with `send`.
- Build hygiene: the first incremental Debug build of this branch on top of a `main` build
  crashed (`EXC_BAD_ACCESS` in `swift_release` while a completed `send --capture` route task
  released its `CommandEnvelope`). `CLISocketServer.o` had not been recompiled after `Command`
  gained the `agentsDispatch` case, so its stale outlined destroy of `Command` released the
  new `.send` payload with the old `.key` layout. A clean build (`xcodebuild clean` +
  `make build-app`) does not reproduce it and the test bundle, compiled fresh, never did.
  Reviewers building this branch incrementally on top of an older DerivedData should clean
  first.
