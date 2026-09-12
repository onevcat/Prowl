# 064.017 — Log and Screen Providers with a Unified State Decision

| | |
| --- | --- |
| **Status** | Planned — architecture agreed; identity and transition details remain open |
| **Anchor date** | 2026-09-12 |
| **Related** | [064 plan](000-plan.md), [045 session identity](../045-native-agent-session-detection/000-plan.md), [059 transcript results](../059-agent-transcript-snapshots/000-plan.md) |

## Context

Codex's animated composer exposed another false-Idle screen regression. A local
0.154.0 spike then verified that ordinary interactive sessions write `task_started`,
`task_complete`, and `turn_aborted` promptly without hooks. It also found gaps in
foreground session identity and in approval/input-wait coverage.

The user agreed to independent log and screen signal providers feeding one decision
component (a state machine). Providers must not independently write the displayed
Working/Idle/Blocked state. This record extends 064's signal-bus design; it does not
replace the existing hook, cooperative, or workflow completion contracts.

PR #799 was closed at the user's request. The spike scripts and raw evidence remain
local and are not part of this documentation change. Only findings that constrain
the architecture are retained here. No production state behavior has changed.

## Agreed architecture

```text
Log signal provider --------\
                            > Unified state decision -> Observed state + provenance
Screen signal provider ----/
Process/session lifecycle -/             ^
                            Existing trusted signals
```

- The log provider supplies scoped turn boundaries, identity confidence, and channel
  availability. It does not infer Blocked from a tool invocation or from silence.
- The screen provider supplies observed UI state and freshness, including approval
  and input prompts. It also supplies fallback Working/Idle evidence when log
  evidence is unavailable or cannot be safely attributed.
- The decision component owns the state transition policy, stale-evidence rejection,
  and final source/confidence. Consumers must not recreate separate precedence rules.
- Process and session lifecycle delimit the validity of both providers. Existing
  trusted hooks remain signals; this path requires no new hook installation.

## Decision constraints

| Evidence | Required interpretation |
| --- | --- |
| Fresh, trusted start for the current turn | In progress; Working unless current blocked UI applies |
| Current approval/input UI during that turn | Blocked, even though the turn is still open |
| Matching completion or cancellation | Close that turn and permit Idle; reject UI known to be retained from it |
| Missing/unreadable log or unresolved foreground identity | Fall back to screen evidence without claiming log confidence |
| No new log bytes for a while | Not a failure or completion signal; silence alone must not expire an open turn |
| Process exit/replacement or session invalidation | Revoke affected evidence; do not manufacture successful completion |
| Historical unmatched start discovered on attach/resume | Not proof of a currently active turn |
| Old completion after a newer turn starts | Must not close the newer turn |

High confidence requires valid process identity, foreground session attribution,
and the correct turn. A parseable log or writable descriptor alone is insufficient.
Signals need enough provenance to enforce this: process identity including start
time, session/binding epoch, turn ID where available, source, and observation order.
These are required semantics, not a finalized schema or new public API.

A prior completion is scoped to its turn, not a permanent Idle override. After new
interaction or a possible session transition, it must not suppress newer evidence.
How to fence such transitions and distinguish stale UI from a genuinely new blocker
is still a design question; wall-clock recency alone is not the agreed solution.

## Identity findings: `/new` and resume

In the default 0.154.0 TUI, a fresh session had no rollout before the first prompt.
After submission, the TUI PID held one writable rollout, giving a useful unique
ownership signal. Two concurrent TUIs in the same cwd/home initially held distinct
rollouts, so cwd was not needed to distinguish those cases.

After `/new`, the same PID retained writable descriptors for both old session A and
new session B. The TUI visibly switched to B. This also reproduced in a second TUI
without prior shell execution, retaining both descriptors for at least 128 seconds.
The internal reason for retaining A was not established. Descriptor ownership now
means "this process owns A and B," not "A or B is currently in the foreground."
Selecting the latest mtime is not an accepted replacement for foreground evidence.
Creation order or a newly observed writable file can nominate B for the measured
forward-only `/new` transition; this is a useful candidate rule to validate, not
evidence that timestamps are useless. Creation time and modification time have
different meanings. A universal "newest-created wins" rule would fail when the
user returns to an older saved chat. The official CLI documentation describes
in-TUI `/resume` for this purpose; its descriptor and write behavior remains untested
in this spike. See [CLI chat switching](https://learn.chatgpt.com/docs/developer-commands?surface=cli#resume-a-saved-chat-with-resume).

Explicit resume after a forced exit was different: a new PID opened the selected
existing rollout. Binding was straightforward in that sample. The difficulty was
history: the old crashed turn had a start with no completion/abort, and that record
remained after resume. The UI showed an interruption notice, then a new prompt
created a new turn. A log replay must distinguish historical open work from a new
event in the current process epoch. In-TUI resume switching was not tested.

The spike measured 13 starts, 9 completions, 3 cancellations, and one unmatched
crash turn. Enter-to-readable-start was 21–97 ms. Vnode notifications also exposed
new records promptly. This supports file visibility, not guaranteed worst-case
latency or fsync durability. Approval and input dialogs had no standalone waiting
event in the sampled logs, so turn boundaries alone cannot distinguish Blocked.

## Integration and implementation gates

Reuse the existing signal and observation infrastructure rather than adding a
parallel state store: `supacode/Domain/AgentDetection/AgentSignal.swift`,
`supacode/Domain/AgentDetection/PaneAgentState.swift`, and
`supacode/Features/Terminal/BusinessLogic/AgentObservationStore.swift`.
Session attribution belongs with
`supacode/Infrastructure/AgentDetection/AgentSessionResolver.swift`.
The current transcript result reader is not a live-state provider.

Before implementation, settle foreground attribution through `/new` and resume,
initial history baselines, provider invalidation/recovery, and cross-channel ordering.
Then test transitions with injected clocks: start/end, stale completion, current
and stale blockers, silent work, log failure, same-cwd sessions, rotation, resume,
and process death. Watcher checks must cover initial-read races, partial lines,
duplicate wakes, replacement, and truncation. A native Prowl interaction pass must
verify the integrated result; the local PTY spike does not establish GUI acceptance.

No watcher or state machine implementation is authorized by this documentation
request alone. The next discussion is foreground identity and transition semantics.
