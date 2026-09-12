# 064.021 — Optional Providers and One Agent State Machine

| | |
| --- | --- |
| **Status** | Architecture proposal; implementation not started |
| **Date** | 2026-09-12 |
| **Related** | [017 initial design](017-agent-state-decision.md), [018 child lifecycle](018-foreground-and-subagent-findings.md), [020 selection research](020-selection-channel-research.md) |

## Agreed scope and revised identity policy

The user ended selection research and accepted heuristic log attribution. This
supersedes 020's proposed requirement for independent foreground identity before
every log-based decision. No title/footer configuration, hook installation, or
exact resume detection is required for this migration.

- All supported agents enter the new architecture on its first release.
- Existing screen heuristics remain unchanged and become one provider.
- Codex alone gains an optional log provider. Other agents remain screen-only.
- Multiple unrelated main sessions trigger screen fallback unless the activity
  window identifies one candidate. Verified subagent files do not count as extra mains.
- Candidate recency uses **main turn lifecycle events**, not file mtime, child
  notifications, token updates, tool output, or metadata writes.
- An observed open turn never expires because it is quiet. The window ages out
  completed activity; provider failure and process exit are separate invalidations.
- Attribution remains heuristic. Returning to a quiet old chat before new input
  can temporarily retain the prior candidate; the user accepts this limitation.

## Current implementation and extraction points

| Existing code | Current responsibility | Proposed treatment |
| --- | --- | --- |
| `WorktreeTerminalState+AgentDetection.swift` | Process polling, presence retention, screen caching, session lookup, state stabilization, acknowledgement and publication | Extract acquisition/lifecycle into a per-pane coordinator and decisions into a pure state machine. Keep terminal/UI projection here. |
| `ScreenHeuristics.swift`, `ClaudeScreenProfile.swift`, `CodexScreenProfile.swift` | Pure agent-specific screen classification | Reuse unchanged through the screen provider. |
| `AgentScreenDetection.swift` | Raw screen state and rule provenance | Reuse as the screen observation payload. |
| `AgentDetectionSchedule.swift` | Cold/warm/active polling schedule | Preserve existing cadence and wake behavior initially. |
| `PaneAgentState.swift` | Detected identity, final state, screen fallback, session metadata, seen/done presentation | Remain the published projection. Move `unknown` stabilization into the new decision logic; keep acknowledgement/display mapping outside it. |
| `AgentSessionResolver.swift`, `AgentSessionProfile.swift`, `ProcessDetection.swift` | Session candidates, paths, process generations and writable descriptors | Reuse bounded discovery primitives. Add a candidate-inventory seam; do not use the sticky single-session result as log-binding authority. |
| `AgentObservationStore.swift` | Existing multicast output and trusted hook/cooperative evidence | Preserve publication and current hook contracts; do not add another public observation store. |
| `AgentTranscriptResultReader.swift` | On-demand semantic result extraction | Keep separate from streaming state detection. |

The infrastructure files are under `supacode/Infrastructure/AgentDetection/`;
domain types are under `supacode/Domain/AgentDetection/`; terminal integration is
under `supacode/Features/Terminal/`. These are existing components, not a proposal
to move every file or reorganize unrelated runtime adapters.

## Minimal structure

```text
Existing process probe and detection schedule
                       |
             AgentDetectionCoordinator (one per pane)
                 /                         \
    ScreenStateProvider              CodexLogProvider (optional)
    existing pure rules              file reader + runtime decoder
                 \                         /
                   AgentDetectionEvent
                            |
                 AgentStateMachine.reduce
                            |
              AgentStateDecision + next deadline
                            |
       PaneAgentState projection -> existing AgentObservationStore
```

Names above are proposed types, not implemented APIs.

**Providers report facts.** The screen provider reports raw state, rule reason,
and observation revision. The log provider reports candidate inventory, lineage,
live turn/child edges, and availability. Neither picks the final pane state. A
small runtime factory selects no log provider for other agents; adding another
runtime requires a decoder/discovery adapter, not another decision implementation.

**The coordinator owns effects.** Use a plain `@MainActor` reference type, not a
second observable store or a TCA feature. It owns subscriptions/tasks, injected
clock, process context, screen samples, and provider cancellation. File I/O runs
off the main actor. Providers emit through one typed sink; the coordinator assigns
delivery order and synchronously reduces each event before publication. A common
event contract is enough initially: no plugin registry, configurable priority graph,
or requirement that a pure screen scanner implement an async watcher protocol.

**The state machine owns policy.** A `Sendable` value type accepts an event and
monotonic time, updates its state, and returns a decision plus an optional next
deadline. It imports no Ghostty, filesystem, UI, or live clock. Runtime-specific
JSON keys stay in decoders. Policy differences must be explicit capabilities,
not `if agent == ...` branches throughout transition logic.

**Publication remains one-way.** The coordinator sends the decision to the
existing terminal owner. That owner derives `seen`, `done`, tab busy/blocked and
`lastChangedAt`, then publishes the existing agent entry. `done` remains an unseen
Idle presentation, not successful task completion. Acknowledgement changes during
awaits must be preserved, and delayed observations must not resurrect closed panes.

## Internal event and state contract

Use a dedicated internal `AgentDetectionEvent`; do not overload the existing
public-facing `AgentSignal.Kind`. It lacks turn IDs, provider failure, and replay
boundaries and already carries hook/CLI/workflow semantics. Reuse process-generation
and provenance types where their meanings match. No public wire-schema migration
is required to introduce the internal contract.

| Event family | Required information |
| --- | --- |
| Runtime observed / gone | Agent, process PID and start time, pane generation; distinguish a probe miss from confirmed exit |
| Screen observed | Raw detection, rule reason, capture revision/time, screen-content revision |
| Candidate inventory | Full session IDs, verified root/child links, descriptor ownership, completeness, provider generation |
| Provider availability | Available / unavailable / resynchronizing, bounded reason, provider generation |
| Main turn started / ended | Root session ID, turn ID, outcome, live cursor and generation |
| Child work started / ended | Root and child IDs, child work generation, live cursor; normalized from runtime evidence |
| Timer fired | Monotonic deadline; no status inference from the timer alone |

State contains the latest screen evidence and separately stabilized screen state,
candidate activity records, selected log root, per-root open work, provider health,
and binding generation. The decision contains final `AgentRawState`, source/reason,
selected log root if any, and attribution confidence. A precise log event does not
make a heuristically selected root `exact`. Keep event reliability and attribution
confidence separate; diagnostic output must make fallback reasons visible.

Do not overwrite the existing public `AgentSession` with this weaker state-source
choice. Handoff, semantic reads and trusted hook identity must retain their own
current attribution requirements. Log-root selection is private to state detection.

## Candidate selection and recovery window

Proposed initial internal constant: **X = 2 minutes**, injected into the machine
for tests and future tuning. This value is a design default, not a measured
optimum or a user-facing setting.

For each root, retain live main-turn start/end activity and outstanding verified
work. An open main turn pins the root as active. Verified outstanding child work
also prevents discarding that root's ongoing work merely because the parent ended;
child notifications never refresh the root's main-activity timestamp. If a new
root competes while old child work is still active, use conservative screen fallback.

Candidate eligibility is outstanding observed work, or main lifecycle activity
within X. With complete discovery and healthy providers:

- One eligible root: bind its log state. Known children stay scoped to this root.
- More than one eligible root: unbind and use screen state.
- No eligible root: use screen state; a writable file alone is not a live turn.
- Incomplete inventory, unknown lineage, or unreadable competing candidate:
  use screen state rather than declaring a unique candidate from partial evidence.

At the exact expiry deadline, completed activity stops competing. Evaluate recovery
even without further file writes by using the machine's next deadline. Recovery
needs an up-to-date complete inventory, not an expired cached scan. Once one root
remains eligible, rebind from its tracked state. If all work is quiet and completed,
both candidates can expire and screen fallback continues; never select newest mtime.

Example: A ends, B starts 10 seconds later. Both are eligible and the pane uses
screen state. After A's two-minute window expires, an open B turn remains eligible
even with no new bytes, so log state can resume. A delayed child-completion record
does not refresh A's main activity. An old completion cannot end B's turn.

## State precedence and ordering

1. Confirmed process exit, replacement, or pane close invalidates affected evidence
   and stops providers. Existing presence hysteresis still handles transient misses.
2. If no log root qualifies or its provider is unhealthy, use the separately
   stabilized screen state. Never carry log-derived Working into screen fallback
   merely because the current screen sample is Unknown.
3. With usable log state, current screen Blocked takes precedence over open work.
   Otherwise an open parent or verified child means Working, even if screen says Idle.
4. Matching completion/abort closes only its work generation. With no open work,
   permit Idle. Do not call an abort successful completion.
5. A completion is a turn edge, not a permanent Idle override. Request a fresh
   screen sample after it. Ignore pre-edge samples and recognize post-edge samples
   with the same previously observed busy/blocker content as retained UI. Retain
   the completion result through that unchanged UI; a changed active screen or
   subsequent interaction invalidates that suppression and permits screen evidence
   until a new live turn is established. This is bounded heuristic reconciliation,
   not an assertion that wall-clock arrival proves causality.

Reuse existing input/wake callbacks as conservative interaction hints, without
parsing `/new` or implementing a command interpreter. Typing alone is not Working;
it only invalidates a completed-turn screen suppression. All screen samples still
go through unchanged runtime rules. In screen-only mode, Unknown retains the last
screen state exactly as today; it is never interpreted as Idle due to log silence.

Use monotonic observation time for X and timers, with source cursors for ordering
within a file. Wall-clock record timestamps are diagnostics, not cross-provider
ordering authority. Deduplicate inode/cursor events and scope late deliveries by
process/provider generation. A changed selected root increments its binding
generation. Continue tracking ambiguous roots without publishing their decisions,
so recovery does not require fabricating starts from history.

## Log reader lifecycle

Initial attachment reads metadata/lineage and establishes a cursor barrier before
publishing live events. Initial history does not create active work or fresh
candidate recency. Attaching mid-turn therefore uses screen state until live
evidence establishes a new trackable work generation. This prevents a crashed
historical open turn, or copied child history, from becoming permanent Working.

Install the watcher before completing the baseline read, drain writes that race
the read, and do not split or double-deliver JSONL records. Partial final lines
wait for completion. Bounded reads that cannot establish continuity, malformed
lifecycle records, truncation, replacement, queue overflow or read failure revoke
log authority and rebaseline. Unknown non-lifecycle record types may be ignored;
unsupported lifecycle schemas must report unavailability. Quiet healthy files stay
healthy. Retry/reconciliation belongs to the coordinator, not a sleep in the machine.

Reuse process-owned writable paths and relocated config roots. Avoid whole-history
walks on each screen poll. A configurable bounded discovery/read budget falls back
explicitly when exceeded; never make uniqueness claims from a truncated inventory.
Known child lineage uses `source.subagent.thread_spawn`, not fork ancestry. Decoder
tests must cover `interacted`: a message to an idle child is not a work start.

## Existing hooks and workflow contracts

First migration improves the state used by UI, `agents wait`, dispatch admission
and workflow readiness. Existing managed-hook authentication, session retirement,
signal meanings and dispatch receipts stay in place. Do not emit synthetic public
`turnEnded` signals from each parsed completion or promote log attribution to
trusted hook evidence. A turn boundary never proves an assigned task was delivered.

Consumer arbitration does require adjustment. Today `AgentConditionEvidence.exactMatch`
can accept a post-baseline `turnEnded` as Idle even while the detected state is
Working. This compensates for stale screens, but a parent's hook completion must
not bypass verified outstanding child work in the new decision. Supply the current
decision provenance and scoped outstanding-work evidence to `AgentConditionSnapshot`.
Use it as a common veto in wait, dispatch and workflow readiness. Preserve the
existing ability of a trusted completion to beat a merely stale screen Working
sample; do not replace the old rule with an unconditional Working veto.

The state machine remains the single owner of aggregate detected activity.
Consumers apply their arm-time, confidence and receipt requirements to that result;
they do not rebuild parent/child or candidate state. Heuristic root attribution
does not meet an `exact` wait requirement. Existing two-second heuristic settling
remains unless a separately eligible signal satisfies the condition. Hook events
themselves do not become more accurate; their use benefits from richer current
state and rejection of contradictory/stale evidence.

Other agents keep their current screen-only detected state and existing hook-based
automation behavior. Adapting hooks as additional display-state providers is a
later, separately scoped migration. Preserve the adapter seam without enabling
new hook-dependent state behavior for those agents in this first cut.

## Migration and test gates

| Slice | Change | Required evidence before proceeding |
| --- | --- | --- |
| A — Common screen path | Introduce event/decision contract, pure machine and coordinator; route all 15 current agents through screen provider only | Existing screen corpus/rule/cache tests pass unchanged. Sequence equivalence covers Working, Blocked, Idle and Unknown for every agent. Seen/done, presence gaps, close and UI publication retain behavior. |
| B — Log primitives | Add Codex discovery/decoder/reader behind an internal disabled capability | Fixture tests cover main/child lineage, replay, partial lines, duplicate delivery, inode replacement, truncation, failures and unsupported lifecycle data. No displayed-state changes yet. |
| C — Codex composition | Enable Codex log provider, root selection window, precedence and fallback | Deterministic machine scenarios below; coordinator concurrency/cancellation tests; other agents still have no log provider or log-file work. |
| D — Consumer integration | Propagate decision evidence and reconcile wait/dispatch/workflow readiness | Parent hook completion cannot bypass active child work; trusted completion still beats stale heuristic Working; confidence filters and delivery receipts keep their meaning. Existing observer/wait/dispatch tests pass. |
| E — Acceptance | Validate the composed behavior | Native Prowl UI exercise, bounded live Codex run, `make check` and `make build-app`. Update affected current manuals with implementation. |

State-machine tests use synchronous event traces with supplied monotonic time.
Check every intermediate decision, root binding, provenance, and next deadline,
not only the final state. No sleeps or filesystem are needed. Cover:

- Quiet open turns far beyond X; expiry just before, at, and after X.
- A ended then B started; two open roots; no recent roots; unknown competing root.
- Child continues after parent end; old child's completion does not refresh recency;
  follow-up reuse, idle-child message, interruption and duplicate completion.
- Blocked over log Working; unblock; completion before/after stale screen delivery;
  changed blocker after completion; interaction before the next logged start.
- Fallback from log Working with screen Idle, Blocked and Unknown; recovery without
  new writes; provider failure during silent work; no old-log resurrection.
- Late end for an older turn, duplicate starts, old process/provider events, PID
  reuse, restart with historical unmatched start, and attach during an active turn.
- Invariants under permutations of independent events: at most one selected root;
  ambiguous/unhealthy logs never drive state; unrelated completion never closes
  active work; metadata/mtime do not select a root; no cross-pane leakage.

Coordinator tests use fake providers and `TestClock` for subscriptions, deadlines,
retries, screen refresh and cancellation. File-reader integration tests use temporary
files and explicit synchronization; a small real vnode test verifies the OS adapter.
Sanitized JSONL and screen traces from the local spikes provide regression fixtures.
Keep native GUI checks separate from parser and PTY evidence. A later runtime is
accepted only after its adapter passes the same shared transition contract suite.

## Remaining implementation details

X = 2 minutes, bounded read budgets, and retry intervals are internal proposed
defaults. Implementers may tune them with evidence without changing the agreed
semantics. No further foreground-switch research is required. Screen heuristics,
completion receipts, title configuration and runtime launch UX remain outside this
architecture change. This document authorizes no implementation by itself.

Design validation: existing extraction targets and document links were checked;
`git diff --check` and `make build-app` passed, with zero build errors or warnings.
The proposed state-machine and provider tests have not been implemented or run.
