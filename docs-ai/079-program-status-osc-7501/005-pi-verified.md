# 079.005 — Pi verified (slice 4)

## Context

Slice 4 of [000-plan.md](000-plan.md): flip Pi to `.verified` so that the root record Pi
1.1.0+ writes decides the pane state, the detection loop delegates while it does, and the
legacy screen detector is the fallback. Pi had no provider before this slice: OSC is its
first provider, its first Blocked (extension dialogs, OAuth waits), and its first `error`.
The plan's *Slice 4 — Pi verified* section is the normative spec; this record lists what
landed and what the gates showed. Slice 3 (Claude Code, #895) is a parallel PR from the
same base; on this branch Claude Code stays unverified.

## Change

| Layer | Files | What |
| --- | --- | --- |
| Support table | `App/Sources/Domain/AgentDetection/ProgramStatusEvidence.swift` | `ProgramStatusSupport.level(for:)` returns `.verified` for `.pi`; every other agent stays `.unverified` on this branch |
| Tests | `App/Tests/AgentCoordinatorProgramStatusTests.swift`, `App/Tests/WorktreeTerminalStateProgramStatusTests.swift` | the production table is pinned at both levels (red before the flip, green after): the coordinator built with the default table delegates a Pi root (Pi has no provider to sample) while a Claude root keeps its legacy path; the terminal owner built with the default table publishes a Pi push (`osc.working`, delegated schedule) and publishes nothing for a Claude push |
| Docs | `docs/components/agent-detection.md` (support table, Pi paragraph with the Blocked kinds and the selector gap, `legacy.detector` as Pi's fallback reason), new living doc `docs-ai/068-agent-state-providers/pi.md`, `architecture.md`, `docs-ai/013-prowl-cli/contracts/agents.md`, [producer-baseline.md](producer-baseline.md) (the Pi "Verification inside Prowl" table), `000-plan.md` (status, PR table) |

No other code changed: the push path, the delegated tick, the withdrawal fence, the
command-finished release, readiness, and the CLI surface are slice 2's (#893).

## Review

A read-only Pi Reviewer loop against the branch (brief: plan, 003, baseline, 068, 064.024,
the diff, and the code paths the flip activates). Round 1 returned one finding: the
verification record was incomplete at review time (the boundary table placeholder, the
pending baseline rows, and this file). Closed by this record and the baseline table; no
code finding. Round 2 (against the docs written after the replay) returned one finding, accepted: the Pi
provider doc's Agent Profile row had attributed the dispatch receipts to the OSC decision,
while a receipt comes only from an explicit `dispatch-complete` and OSC takes part in idle
admission alone; the row was reworded. Round 3 confirmed the fix against the code with no new finding.

## Verification

| Gate | Result |
| --- | --- |
| TDD | `defaultTableVerifiesPiOnly()` and `productionTableVerifiesPiAndNotClaude()` failed before the flip (`.unverified` for `.pi`; the pushed pane stayed `idle`) and passed after it; the five program-status test classes (63 tests) passed on the flipped tree |
| `make check` | passed on the final tree (swift-format, SwiftLint strict, script tests, naming and localization checks) |
| `make test` | passed on the final tree: ProwlTests 3799 passed / 0 failed (verified xcresult 3805 tests, one more than #893), event monitor 12, mirror 72 (1 skipped), shell cancellation 3; the 12 build warnings are the pre-existing ones on `main` |
| `make build-app` | passed with 0 warnings on the flipped tree and on the final tree |
| Isolated Debug run (gate 6) | Branch build in a second instance (`CFFIXED_USER_HOME=/tmp/prowl-079-s4-home`, own socket, `script -F` log) with Pi 1.1.0 (gpt-6-astra). Every row of the plan's acceptance list that the environment allowed was replayed and is recorded in the baseline's *Verification inside Prowl* table: launch → `osc.idle` on the first roster entry; prompt → `osc.working` (≈ 100 ms CLI-polled) → `osc.done`; Esc → `osc.idle`; `-e confirm-gate.ts` → `osc.blocked.permission` → answered → `osc.done`; `-e select-gate.ts` → `osc.blocked.question`; `/model` open → unchanged; `pi --provider anthropic --model claude` with the expired OAuth → `osc.error`, held; ctrl+d 69 ms and `kill -9` 143 ms to release (CLI-polled); relaunch → own `osc.idle`; close + undo (`prowl key <pane> cmd-z`) → restored pane carries `osc.done` from the retained store in 92 ms; `PI_PROGRAM_STATUS=0` → `legacy.detector` with zero OSC lines; `Pi Test` Profile (managed `-e prowl-hooks.ts`) → launch dispatch receipt, `agents wait --until idle`, and a re-dispatch resolved with `hook_pi` at `exact`. A Claude Code pane in the same instance stayed on its legacy path (`claude.blockedPrompt`, `claude.spinner`, `claude.idleComposer`). No case was found where OSC was wrong and the legacy decision right. Not exercised: a running `pi-subagents` card after root `done` (installed, scenario not run), `kind=auth`, and the Done → viewed → Idle step (the isolated window never reported itself visible on the locked screen; it is the unchanged `markAgentSeen` path, reproduced in slice 3) |
| CPU (gate 2) | `make measure-cpu` on the slice build against the slice 2 baseline on `main` (one Pi pane and one Claude pane; Claude is unverified on this branch, so its pane polls at 300 ms with the registry read failing in the isolated home, the same condition as the baseline). Idle: `20261011-021749-31328` mean 1.3 %, `detectAgentState` 0.70 % of a core, `AgentSessionResolver.resolve` 0.05 % (baseline `20261010-214229-57604`: mean 1.0 %, 0.49 %, 0.04 %; load 3.1 here against 2.6). Working: Pi writing essays under OSC authority for the whole sample with a bare shell tab selected: `20261011-022040-34669` mean 12.0 %, `detectAgentState` 0.73 %, SwiftUI `stepTransactionFlush` 8.0 %, and `20261011-022219-36659` mean 11.4 %, 1.40 %, 9.5 % (baseline `20261010-214500-60944`, both agents working: mean 26.1 %, 0.52 %, 7.8 %). The Claude pane (sonnet) finished each essay prompt before or early in the 45 s window in every attempt, so no sample has both agents working throughout; the comparable part is the per-symbol detection cost, which stays within a fraction of a percent of the baseline. With the streaming Pi tab selected instead of a bare shell (`20261011-021916-32967`) the mean rose to 31.4 % with `stepTransactionFlush` at 20 %: that is the rendering of the selected pane, not detection (`detectAgentState` 1.69 % under load 2.8). The display was off and the screen locked during every run. |
| Review loop (gate 7) | three rounds: 1 finding (the record was still being written), then 1 documentation correction, then 0; every finding was verified by reading the code before it was accepted |

## Observations

- **Pi's first Blocked and first error come from the protocol.** The legacy detector never
  produced Blocked for Pi; with OSC an extension dialog is `osc.blocked.permission` or
  `osc.blocked.question`, and a provider failure is `osc.error` (Idle, badge-eligible, held
  until the next report). `agents read` keeps Pi unsupported (`AGENT_UNSUPPORTED`), as its
  contract says.
- **The first probe already sees the report.** Pi sends `idle` within milliseconds of the
  query echo; the report wakes the probe, and the roster's first entry is `osc.idle` with
  `screen.delegated`, while the probe's own diagnostic line still reads the screen as
  `legacy.detector` idle.
- **ctrl+d closes the shell too.** The harness used two ctrl+d; inside Prowl the first one
  exits Pi (and releases the entry within one probe) and a second one closes the pane's
  shell.
- **The `/model` selector cannot reach anthropic models when the OAuth is expired** ("Could
  not refresh anthropic; showing cached models"), so the error row was replayed with
  `pi --provider anthropic --model claude` instead of the selector.
- **Same session-identity limitation as slice 3.** Delegated ticks resolve the session
  against the frame of the last key press (recorded in [004](004-claude-verified.md) *Open
  questions*); Pi's resolver uses `~/.pi/agent/sessions/<cwd>/` transcripts and is subject
  to the same rotation staleness. No Pi session resolved in the isolated instance either.

## Open questions

- `pi-subagents` card running after root `done`: the extension is installed locally, so the
  optional row can be replayed later (the code applies the root-only rule; the fallback
  `hasPiRunningAsyncSubagentCard` is consulted only without reports).
- The session-identity decision requested in 004 applies to Pi as well.

## Refs

Builds on #887 (slice 1), #892 (plan), #893 (slice 2); parallel to #895 (slice 3). #891
(legacy background-work semantics) stays open. PR number to fill in on merge.
