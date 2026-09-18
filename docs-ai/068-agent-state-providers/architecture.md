# Agent state providers — shared architecture

Shared baseline: implemented by [#800](https://github.com/onevcat/Prowl/pull/800), released in
[v2026.9.12](https://github.com/onevcat/Prowl/releases/tag/v2026.9.12).
Baseline verified against `e54b1e19` on 2026-09-14. The native adapter extension is
recorded in [068.002](002-native-runtime-implementation.md) and awaits release;
#800's log policy is unchanged.

## Acquisition, policy, and consumers

```text
Process generation + terminal screen + optional runtime evidence
  -> AgentDetectionCoordinator (serialized acquisition, capture ordering)
  -> AgentStateMachine (pure facts + supplied monotonic time)
  -> AgentStateDecision (state, reasons, selected root, outstanding work)
  -> terminal state / Active Agents / wait and readiness policy
```

Every runtime uses the coordinator and machine. Codex has a log provider; Claude
has a process-scoped native snapshot provider; other runtimes use screen observations.
This is a shared decision path, not a general plugin interface for arbitrary providers.

| Responsibility | Current source |
| --- | --- |
| Process identity and generation | `supacode/Infrastructure/AgentDetection/ProcessDetection.swift` |
| Observation acquisition and ordering | `supacode/Features/Terminal/BusinessLogic/AgentDetectionCoordinator.swift` |
| Pure arbitration | `supacode/Domain/AgentDetection/AgentStateMachine.swift` |
| Runtime acquisition/decoding | [Codex provider](codex.md) |
| Terminal publication | `supacode/Features/Terminal/Models/WorktreeTerminalState+AgentDetection.swift` |
| Wait/readiness evidence | `supacode/CLIService/AgentConditionEvidence.swift` |

The existing adaptive polling clock drives acquisition and ticks. No additional
watcher or timer was introduced. Captures receive monotonic timestamps before
asynchronous resolution. The coordinator serializes observations and rejects older
captures before rebinding the process or consuming another log batch. Lifecycle
invalidation rejects queued/in-flight results; internal process rebinding is separate.

## Evidence and current arbitration

Private events describe screen observations, complete root inventory, main turn
start/end, child scheduling/start/end, suspension, lost availability, interaction,
and ticks. They are not public hook signals. Main and child ends require matching
work identity; an old completion must not close reused work.

Each root retains an open main turn, open children, and last main activity. Open
work never expires from silence. The 120-second window only retains eligibility
for completed main activity; file mtime and child chatter do not refresh it.

| Evidence | Decision |
| --- | --- |
| One eligible root, current unsuppressed screen Blocked | Blocked, retaining that root's outstanding-work flag |
| One eligible root with open main or child work | Working |
| Matching completion, no remaining work, retained screen | Idle; retain a scoped completion fence |
| Completed root and a new unsuppressed Working screen | Working via screen fallback |
| Unavailable evidence, no eligible root, or multiple eligible roots | Last explicit screen state, subject to the sole-root completion fence |
| Screen Unknown | Preserve last explicit screen state for fallback |

A completion fence records the selected session and screen classification/reason.
Blocked observations also carry content identity so a changed blocker can win;
spinner animation alone must not revive completed work. Interaction or a new turn
clears suppression. During suspension or expiry, an unchanged completed frame stays
Idle only when it belongs to the sole known root. Multiple-root fallback has no
such completion guarantee.

`screen_reason` reports the classifier; `detection_reason` reports the final decision.
They can differ. Diagnostic-only changes do not trigger sidebar/title emission,
but live CLI reads retain current reasons and normal decision equality.

## Continuity and authority boundaries

- **Suspended:** temporary incomplete acquisition removes log authority but retains
  cursors, work, and applicable completion fences for recovery.
- **Unavailable / continuity lost:** discard log state and fence; establish a fresh
  baseline before later live events can acquire authority.
- A private selected root is not the public session resolver's identity. Do not use
  a weak recent-file/public-cache result to select authoritative state evidence.
- Outstanding work participates in wait, dispatch, and workflow readiness. A parent
  completion cannot release readiness while its selected root has verified children.
- Detection does not manufacture trusted completion hooks, task-delivery receipts,
  or a stronger public confidence level. Those remain governed by
  [064](../064-agent-completion-signals/000-plan.md).

## Native snapshot decisions

The native event reports current session, aggregate state, and runtime state revision.
It does not synthesize log turn identities. Current native work remains Working
through screen Idle/Unknown; native Waiting establishes Blocked. A fresh native
revision fences its captured screen; first attachment preserves an existing blocker.
A subsequently changed screen blocker can win.
Native Idle supports heuristic wait/readiness even with an unmatched screen, while
native outstanding work vetoes Idle admission. Suspension retains the completed-frame
fence; revocation removes it. Native snapshots do not share the log recency window.

## Extension contract

Each adapter must define process/session attribution, baseline rules, supported
schema, bounded acquisition, failure recovery, and exact work ownership. Reuse the
poll clock and shared policy; extract common readers only where responsibilities
actually match. Native snapshots use an explicit private fact, not a fabricated
log turn end. The implemented native adapter is in [claude.md](claude.md).

Coordinator generation replacement and config-root rebinding cover both providers
and preserve capture ordering.
A new adapter must also prove that same-session processes cannot borrow each
other's work and that failures cannot become successful completion.

## Historical design and corrections

[030](../030-agent-status-detection/000-plan.md) records screen detection and
scheduling. [064.021](../064-agent-completion-signals/021-provider-state-machine-design.md)
is the original proposal; implementation differences and continuity/order fixes are
in [064.022](../064-agent-completion-signals/022-provider-implementation.md),
[064.023](../064-agent-completion-signals/023-provider-continuity-hardening.md), and
[064.024](../064-agent-completion-signals/024-observation-order-and-emission.md).
Use the implemented references rather than treating the original proposal as code.
