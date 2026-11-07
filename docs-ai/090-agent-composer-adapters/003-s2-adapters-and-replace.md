# 090.003 — S2: composer adapters, draft replacement, `on_draft`

## Context

With dim hints handled (S1), a real draft still only refused `agents.input` and
`agents dispatch`, and the composer code was split between the `AgentComposerProfile` enum
(Claude, Devin), a Codex branch, and the mirror's key guard.

## Change

- `App/Sources/Domain/AgentDetection/AgentComposerAdapter.swift`: `AgentComposerAdapter`
  (read the box into `AgentComposerReading`: `empty`, `draft(AgentComposerDraft)`,
  `unrecognized`; `clearPlan`; paste echo rules), `AgentComposerClearPlan` (`stash`,
  `killLines`, `unsupported`), `AgentComposerEcho`, and the `AgentComposerAdapters` registry.
  Per-agent adapters under `App/Sources/Infrastructure/AgentDetection/`: Claude (⌃S stash,
  paste marker and image are incomplete drafts), Codex (⌃U line kills, multi-row drafts, no
  echo wait), Devin (plain screen, clearing unsupported). `AgentComposerProfile` is gone.
- `App/Sources/CLIService/AgentComposerClearing.swift`: the executor. It presses the plan's
  key under `AgentKeySequenceGuard` (the former `MirrorKeyGuard`, moved next to
  `AgentDispatchInputProtection`), re-reads after every key, stops at the first empty reading,
  caps line kills at `2 × lines + 2` (at most 64), and reports a partial clear as a refusal.
- `WorktreeTerminalState.deliverAgentInput(_:surfaceID:policy:)`: protection under the
  policy, clearing, a re-read that must be empty, then the existing paste-echo delivery.
  `dispatchInputProtection` returns `AgentInputRefusal` (message plus
  `AgentInputRefusalDetails`).
- Wire and CLI (`ProwlCLIShared`): `DispatchInput.onDraft` (`on_draft`),
  `AgentDispatchErrorDetails.input`, `replaced_draft` on the dispatch payload and on
  `SendInputInfo`; `prowl agents dispatch --on-draft refuse|replace`; text rendering of the
  refusal and the replaced draft; the output schema. The mirror Host's `Dispatch` command
  carries `on_draft` through to `agents.input`.
- Tests: `AgentComposerAdapterTests`, `AgentComposerClearingTests` (TestClock sequencing:
  stash, kill-line loop and cap, local typing mid-sequence, unsupported, gone screen), updated
  delivery and dispatch handler tests, CLI wire/parsing/renderer/schema tests.

## Refs

PR (S2), docs-ai 090 plan.
