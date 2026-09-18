# 068 — Agent State Providers: Plan

| | |
| --- | --- |
| **Status** | Implemented — acceptance complete; awaiting merge and release |
| **Anchor date** | 2026-09-14 |
| **Baseline** | `e54b1e19`; #800 shipped in v2026.9.12 |
| **Related** | [030 detection history](../030-agent-status-detection/000-plan.md), [064 completion signals](../064-agent-completion-signals/000-plan.md) |

## Background

Terminal screens describe what is displayed, which can differ from current work.
Runtime scroll viewers, retained output, and background children expose this gap.
#800 introduced shared decisions and optional lifecycle evidence. Its implementation
history remains in 064; this chapter is the current reference for state providers
and the plan for extending them to other runtimes.

## Goals

- Preserve one decision policy with runtime-specific evidence acquisition.
- Prefer scoped lifecycle or native state evidence where its contract is verified.
- Keep screen fallback for unsupported versions, missing evidence, and ambiguity.
- Preserve per-pane identity, outstanding work, and existing readiness contracts.
- Maintain one living document per agent, with explicit implementation status,
  evidence boundaries, failure behavior, and remaining acceptance gates.

## Document map

| Document | Role |
| --- | --- |
| [architecture.md](architecture.md) | Released shared architecture, arbitration, and extension invariants |
| [codex.md](codex.md) | Released provider, acquisition/decoding contract, and known limits |
| [claude.md](claude.md) | Implemented native adapter, spike findings, and original proposal |

Add future agents as sibling living documents. Each must distinguish observed
runtime behavior from implemented Prowl behavior. Update these references with
accepted contract changes; retain numbered amendments for implementation decisions.
This chapter does not supersede 030's screen history or 064's trusted completion
and delivery contracts.

## Approach and review gate

The initial proposal combined Claude's process-scoped native status file with
selected-session JSONL evidence. The spike found cancellation without a closing
transcript record and two processes with different states sharing one transcript.
These cases rule out copying a JSONL-only turn model unchanged.

Implementation was authorized after #806 merged. The original stages in
[claude.md](claude.md) guided the work:

1. Close process-identity, compatibility, and assigned-child contract gaps.
2. Implement bounded native acquisition and selected JSONL decoding.
3. Extend the shared decision model and coordinator with explicit native facts.
4. Verify native pane behavior, fallback, and readiness before release.

#806 was the documentation review checkpoint. The extended spike and implementation
are recorded in [002](002-native-runtime-implementation.md). Native state already
aggregates assigned children and shell work, so production JSONL reconstruction was
removed from scope. The adapter and native terminal/CLI acceptance are complete;
standard terminal mouse-wheel acceptance passed. On 2026-09-15, onevcat removed
the separate fullscreen overlay case from required acceptance. It remains unverified,
not a passing test. See [001 action log](001-action.md).

## Alternatives and decisions

- **Screen only:** remains the fallback, but cannot resolve completion while a
  runtime displays an unchanged history view.
- **JSONL only for every runtime:** rejected as the proposed Claude approach by
  the cancellation and concurrent-resume evidence. Runtime contracts differ.
- **Native aggregate status:** selected after the extended child-work spike. JSONL
  corroborates the contract; a duplicate production work ledger would lose per-PID
  ownership and can count work twice. See [002](002-native-runtime-implementation.md).
- **Mandatory hooks:** outside this migration's setup-free detection scope.
  Existing trusted hooks and delivery receipts retain their separate contracts.

## Amendments

- Updated 2026-09-15: Implementation authorized after #806 merged; staged acceptance is tracked in [002](002-native-runtime-implementation.md).

- Updated 2026-09-15: Acceptance completed with the fullscreen case excluded by onevcat — see [001 action log](001-action.md).
