# 079.003 — Generic program status provider (slice 2)

## Context

Slice 2 of [000-plan.md](000-plan.md): consume the OSC 7501 reports that slice 1 (#887)
copies out of GhosttyKit. The plan's *Slice 2* section is the normative spec; this record
lists what landed, where, and what the gate runs showed. Every agent ships `.unverified`,
so no published state comes from OSC yet. The one user-visible change is the release on
`COMMAND_FINISHED`, which applies to every agent.

## Change

### Code

| Layer | Files | What |
| --- | --- | --- |
| Record store | `App/Sources/Domain/AgentDetection/ProgramStatusRecordStore.swift` | One tree per surface: whole-record replacement, subtree `clear` (empty id clears all), `app` inheritance through missing parents (the root is every record's ancestor), 256-record least-recently-updated eviction (a single record, children stay as orphans), monotonic `revision`, `arrivedAt`, `commandFinished(upTo:)` scoped to the revision captured at the 133 D |
| Evidence, support, reasons | `App/Sources/Domain/AgentDetection/ProgramStatusEvidence.swift` | `ProgramStatusSupport.level(for:)` (static table, all `.unverified`), `DetectedAgent.programStatusApp` (`claude` → `claude-code`, `pi` → `pi`), the per-record attribution fence (`app` after inheritance equals the agent's, `arrivedAt >= process.startedAt`), `ProgramStatusEvidence.decision` (the pure mapping shared with the shadow comparison), `ProgramStatusReason` (`osc.*` identifiers, `earnsDoneBadge`) |
| State machine | `App/Sources/Domain/AgentDetection/AgentStateMachine.swift`, `AgentScreenDetection.swift` | `.programStatus(evidence?, revision:)` event, resolved ahead of native, log, and screen; an older or equal revision is ignored; taking authority retires the native snapshot, the completed-frame fence, and the log roots' recency while `hasLogProvider` and open work stay; `screenReason` is `.delegated` (`screen.delegated`) under authority |
| Coordinator | `App/Sources/Features/Terminal/BusinessLogic/AgentDetectionCoordinator.swift` | Rebinds on a process change for every agent with a `programStatusApp`; `observe(…, programStatus:, delegated:)` pulls the store snapshot each poll and skips the screen event and provider sample when delegated; `receive(programStatus:)` is the push path (`.decision` / `.withdrawn` / `.none`); an authority epoch discards a provider sample that was in flight when OSC took over; `decision`, `isDelegated`, `lastProgramStatusWithdrawalAt`; shadow lines for unverified producers (`[ProgramStatus] shadow …`, on transition, 30 s per pair, no record text) |
| Terminal owner | `App/Sources/Features/Terminal/Models/WorktreeTerminalState+ProgramStatus.swift`, `+AgentDetection.swift`, `+Surfaces.swift`, `+Notifications.swift`, `+UndoClose.swift`, `WorktreeTerminalState.swift`, `AgentDetectionSchedule.swift`, `PaneAgentState.swift`, `ProcessDetection.swift` | Store owned per surface (kept while retained for undo, dropped on close or free); `handleProgramStatus` pushes through the coordinator and `publishDecision` in the same main-thread turn, or wakes the probe when no agent is bound; `wakeAgentDetection` interrupts the loop's sleep; `.delegated` schedule (2 s, probe and session resolution with the last scan's text, no screen read); `COMMAND_FINISHED` → cache-bypassing fresh probe whose single miss releases the entry (`AgentDetectionPresence.update(…, releaseOnMiss:)`), with the three outcomes `sameOwner` / `released` / `successor` (`commandFinishedOutcome`); an OSC withdrawal publishes nothing until an observe that captured after it; Done badge only for `osc.done`/`osc.error` (`resolvedSeen`); unmapped `app` logged once per surface and app |
| Readiness and CLI | `App/Sources/CLIService/AgentConditionEvidence.swift`, `AgentsCommandHandler.swift`, `App/Sources/App/ProwlApp.swift`, `WorkflowRuntimeComposition.swift`, `WorktreeTerminalManager.swift` | `AgentConditionSnapshot.decision` carries the coordinator's current decision (`agentCurrentDecision`); `hasOutstandingWork` and the idle exemption (`log.turnEnded`, `native.idle`, `osc.idle`/`osc.done`/`osc.error`) read it; `prowl agents` reports `screen.delegated` from an OSC-driven decision ahead of the cached scan; `agents read` keeps its fresh screen read and returns a null blocker for an OSC-only Blocked |

### Tests

`ProgramStatusRecordStoreTests`, `AgentStateMachineProgramStatusTests`,
`AgentDetectionCoordinatorProgramStatusTests`, `WorktreeTerminalStateProgramStatusTests`
(fake foreground job built around the test process so the generation fence sees a real
start time; placeholder loop task so wakes do not start the real loop),
`AgentConditionEvidenceProgramStatusTests`, plus cases added to
`AgentDetectionScheduleTests`, `PaneAgentStateTests`, `CLIAgentsCommandHandlerTests`, and
`AgentReadCommandHandlerTests`. Swift Testing, injected clocks and closures, no sleeps.

### Docs

`docs/components/terminal.md`, `docs/components/agent-detection.md` (new "Program status
(OSC 7501)" section, cadence), `docs/components/cli.md`,
`docs-ai/013-prowl-cli/contracts/agents.md` and `agents-read.md`,
`docs-ai/068-agent-state-providers/architecture.md`.

## Deviations from the plan

- The shadow diagnostic logs every OSC/live transition with an `agree=` flag, not only
  disagreements: with agreement-only logging the slice 2 gate ("shadow logs appear for
  both producers") could not be observed when the two paths agree.
- The unmapped-`app` line is written from the poll (after the probe binds or fails to
  bind an agent), not from the report callback, so Pi's `idle` that lands before the
  first probe does not log a spurious "unmapped" against no agent.
- `commandFinished(upTo:)` bumps the store revision when it removed a record, so a
  verified push after the drop is applied by the machine's revision check.
- The delegated tick hands the session resolver the last scan's text instead of an
  empty string, so transcript matching keeps the frame read before delegation.
- The owner generation in the post-D table is the retained `launchProcessID` alone;
  PID reuse of the launcher within one probe gap is not distinguished (no launch start
  time is stored). Deliberate limit.

## Review

A read-only Pi Reviewer loop against the branch (brief: plan, this record, 068 and 064.024
invariants, full diff). Round 1 returned eight findings; every one was checked against the
source and accepted:

| # | Finding | Fix |
| --- | --- | --- |
| 1 | The `COMMAND_FINISHED` mark was removed after the probe suspended, so a second D during the sample lost its own fast release | the mark is taken with the fresh flag before the probe |
| 2 | The tick that took authority still sampled the provider in the same epoch, so a native idle could recreate the retired fence | no provider sample while the machine holds authority |
| 3 | A key press and a probe miss never left delegation (the owner only consulted `isDelegated`) | a tick is delegated only when the schedule says so and the probe confirmed the bound generation; a miss returns the loop to the active cadence |
| 4 | An engine change on a delegated tick reset the machine without any acquisition and published Unknown, which revokes the managed hook | same predicate: the bound generation must be confirmed |
| 5 | A cancelled loop's late sleeper continuation could unregister a restored loop's sleeper | per-loop tokens own the schedule and the sleeper |
| 6 | No composed test for the successor outcome or for an agent that never reports | added; the cached-hit/miss probe test and the wait/dispatch-across-release test were not (see record) |
| 7 | Readiness tests bypassed the production snapshot builders | both builders share `WorktreeTerminalManager.agentConditionSnapshot`, tested with a real coordinator |
| 8 | The manual presented the attribution fence as protection against forged reports | reworded: attribution, not authentication |

Round 2: see the gate table.

## Verification

Filled in from the gate runs; see [000-plan.md](000-plan.md) *Slices and gates*.

| Gate | Result |
| --- | --- |
| CPU baseline on `main` (gate 2) | `make measure-cpu` on the `main` Debug build in an isolated instance with one Claude Code 2.1.296 pane and one Pi 1.1.0 pane: idle run `~/Library/Logs/Prowl/measurements/20261010-214229-57604` (mean 1.0 %, `detectAgentState` 0.49 % of a core), working run `20261010-214500-60944` (both agents writing an essay: mean 26.1 %, `detectAgentState` 0.52 %, SwiftUI `stepTransactionFlush` 7.8 %). Load 2.6 on 12 cores. Slices 3/4 compare against these. |
| `make check`, `make test`, `make build-app` | pending |
| Isolated Debug run (gate 6) | pending |
| Review loop (gate 7) | pending |

## Refs

PR: pending. Builds on #887 (slice 1) and #892 (plan). #891 (legacy background-work
semantics) stays open.
