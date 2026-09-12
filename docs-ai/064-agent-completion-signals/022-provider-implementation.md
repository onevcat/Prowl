# 064.022 — Shared State Decisions and Optional Log Evidence

## Outcome

All runtime screen observations now enter `AgentDetectionCoordinator` and the pure
`AgentStateMachine`. The existing screen classifiers and cache remain unchanged.
Codex adds `CodexLogProvider` and `CodexLogDecoder`; other runtimes do no log acquisition.
The private decision carries its selected root and outstanding-work evidence into
`PaneAgentState`, `ActiveAgentEntry`, and the common wait/readiness policy.

Parent completion cannot make wait, dispatch, or workflow readiness report Idle
while the selected root has observed outstanding work. Existing trusted completion
still overrides stale screen Working. No synthetic hook events or task receipts
are emitted. Public session attribution remains separate from private log selection.

## Implementation decisions

- Reuse the existing adaptive poll clock instead of adding vnode subscriptions and
  a second timer. File acquisition runs on an actor, reads only appended bytes, and
  reconciles expiry on each tick, including ticks without new log bytes.
- Bound discovery to 32 files, each metadata header to 1 MiB, each pending line to
  1 MiB, and incremental reads to 8 MiB per sample. Incomplete descriptor discovery
  or an unfinished new header suspends authority while retaining cursors and work.
  A healthy complete inventory resumes from those cursors. Replacement, truncation,
  malformed lifecycle data, or failed continuity requires a new baseline.
- Existing writable-descriptor discovery remains best effort for session lookup;
  state acquisition requires its new completeness result.
- File creation time distinguishes a newly persisted rollout from initial history.
  The session header timestamp can precede persistence by minutes. Fresh mains
  and children do not require `thread_settings_applied`; only `forked_from_id`
  establishes copied history that needs its own settings boundary. Parent lineage
  is separate. E2E exposed these distinctions and regression tests cover them.
- Main start/end receipt time drives the internal 120-second window. Open main or
  child work never expires from silence. Child activity never refreshes main recency.
- Child completion retains its turn identity. The child's own live start replaces
  the provisional spawn/follow-up identity; a later scheduling notice cannot
  overwrite an already observed turn. Unrelated old completions cannot close
  a reused child's work. An idle-child message does not create new work.
- Acquisition and reduction have a single delivery order; coordinator revisions
  reject late results after replacement or close. Existing publication guards
  preserve acknowledgement changes across awaits.

## Deviations and limits

The first implementation uses polling and explicit monotonic ticks rather than
watchers and returned deadlines. This reuses existing scheduling and avoids new
subscription races. Tests inject event time and suspended provider results rather
than waiting on a real clock. Initial attachment and recovery do not replay old
starts; attaching mid-turn can remain screen-only until the next trackable turn.

Selection is heuristic, including the accepted quiet-resume limitation. Incomplete inventories suspend log authority. Failed continuity requires a new
baseline and can leave detection screen-only until later live evidence. The public session
resolver can independently report a weaker recent-file identity when multiple
files are open; that result is not used to choose the state log.

Completion suppression compares classification and reason, plus a content identity
for Blocked frames. A different blocker can therefore win without another input.
Working animations do not invalidate suppression merely by changing spinner text;
input or a new turn edge does. Screen-only process-probe gaps retain the prior
stable screen state. These boundaries received failing tests before the fixes.

## Validation

Validation receipts and screen captures are local under
`.local/agent-screen-captures/provider-e2e/`. These contain temporary runtime data
and are not committed. The tests exercise the actual Debug app through its own
socket and bundled CLI; the user's release app and panes were not modified.

| Scenario | Observed result |
| --- | --- |
| Fresh Codex turn without hooks | `log.openWork`, including a raw screen Idle sample; matching completion produced `log.turnEnded` |
| Codex command approval | Working → `codex.confirmationFooter` Blocked; `agents wait --until blocked` returned; approval resumed the turn |
| Codex Plan-mode question | Blocked while the question was shown; submitting the answer resumed Working and then Idle |
| Parent ends before child | Raw screen Idle after `PARENT_DONE`; aggregate remained Working for about 34 seconds until the exact child completion |
| `/new` after child work | The runtime closed old rollout descriptors; a transient unavailable inventory fell back to screen for the new turn. The following turn restored `log.openWork` and `log.turnEnded` |
| Claude | Trust dialog Blocked; `claude.spinner` Working → `claude.idleComposer` Idle |
| Pi | Existing `legacy.detector` Working → Idle with extensions disabled for isolation |

A desktop screenshot returned an all-black image. It is not visual acceptance
proof. Native terminal text, state observations, and interaction receipts establish
runtime integration; a visible desktop styling check remains unverified. Runtime
versions were Codex 0.154.0, Claude Code 2.1.269, and Pi 0.85.1.

The 120-second multi-root recovery boundary is verified with deterministic machine
tests. This native `/new` run did not retain multiple main files and is not live
proof of grace-window recovery.

Final regression verification: 111 selected Swift tests passed with zero failures
and zero warnings; `make check` passed (including 153 script tests), and `make build-app`
passed with zero errors or warnings. Self-review added inventory completeness,
screen-only probe-gap retention, and changed-blocker regression coverage.

Implementation commits: `681660ea` (pure policy), `792ffdd1` (log acquisition),
`3ec1ddb8` (composition and readiness). Follow-up acceptance changes ship in the
same branch and PR.

Final E2E caught a descriptor/header creation race during subagent launch: clearing
all cursors on temporary incompleteness lost child work after parent completion.
The provider now separates suspension from continuity loss. New failing tests
cover suspended authority recovery and partial-header cursor retention. Fresh
children without inherited history also omit settings events; their metadata now
activates direct live parsing. Cross-file scheduling/start order has a separate
regression test, and idle-child messages remain distinct from follow-up requests.

The final two-child E2E explicitly used `fork_turns="none"` and `fork_turns="all"`.
Across the 21.7 seconds between parent completion and the last child completion,
all 60 sampled interior observations were Working, including raw screen Idle.
All 91 samples after the completion settling margin were Idle/Done. The local
`codex-both-children-verified.json` records these assertions and session identities.

## Continuity follow-up

[023 continuity hardening](023-provider-continuity-hardening.md) corrects concurrent
observation delivery, extends presence retention to the log provider, and scopes
completion suppression across suspension and expiry. It also documents supported
original launch sources and the shared CLI reason fields.
