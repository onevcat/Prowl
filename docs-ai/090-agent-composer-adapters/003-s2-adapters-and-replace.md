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

## Review round 1 (2026-11-08)

- R090-001: the clearing poll adopted every observed editing stamp as its own baseline, so local
  typing during the settle wait could pass the guard. Own-key provenance (editing stamp and
  input generation) is now recorded synchronously after each press and every later observation
  is checked against it, including the one that first reads empty. Tests cover typing during the
  wait and a local key coinciding with the empty reading.
- R090-002: image attachments were advertised as replaceable. `clearPlan(for:)` returns
  `unsupported` for an `[Image #N]` draft on every adapter; a collapsed text paste stays
  replaceable (verified with ⌃S).
- R090-003: Codex continuation rows lost indentation and blank rows while the draft was marked
  complete. Rows keep their text past the two-column margin and interior blank rows, and only a
  one-row draft without a marker is complete, for Codex, Claude and Devin alike.

## After the S1 review (2026-11-08)

The S1 loop found that Codex's dim `Viewing sub-agent — direct input is disabled` notice (a
parent-owned child view) passed the dim-only rule although typed text is rejected there. The
Codex adapter reads such a box as `unrecognized` (`isDirectInputDisabled`), and a dim
`[Pasted Content …]` chip is content like an image (`showsComposerMarker`).

## Live verification (2026-11-08, separate Debug app)

`agents dispatch` against Claude Code 2.1.319 and Codex 0.167 with a typed draft: `refuse`
returns `DISPATCH_TARGET_BUSY` with `details.input` (Claude `recovery: stash`, Codex none),
`--on-draft replace` delivers and reports `replaced_draft`. Claude Code puts the stashed draft
back in the box by itself once the delivered message is sent; ⌃S toggles it. Codex shows the
placeholder again. Results on PR #1072.

## Refs

PR (S2), docs-ai 090 plan.
