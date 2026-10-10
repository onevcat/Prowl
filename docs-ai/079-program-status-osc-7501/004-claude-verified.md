# 079.004 — Claude Code verified (slice 3)

## Context

Slice 3 of [000-plan.md](000-plan.md): flip Claude Code to `.verified` so that the root
record Claude Code 2.1.295+ writes decides the pane state, the detection loop delegates
while it does, and the native registry and the screen rules become the fallback. The
plan's *Slice 3 — Claude Code verified* section is the normative spec; this record lists
what landed, what the gates showed, and the one limitation the review surfaced.

## Change

| Layer | Files | What |
| --- | --- | --- |
| Support table | `App/Sources/Domain/AgentDetection/ProgramStatusEvidence.swift` | `ProgramStatusSupport.level(for:)` returns `.verified` for `.claude`; every other agent stays `.unverified` (Pi flips in slice 4) |
| Tests | `App/Tests/AgentCoordinatorProgramStatusTests.swift`, `App/Tests/WorktreeTerminalStateProgramStatusTests.swift` | the production table is pinned at both levels (red before the flip, green after): the coordinator built with the default table delegates a Claude root and must not sample the native provider, while a Pi root keeps `legacy.detector`; the terminal owner built with the default table publishes a Claude push (`osc.working`, delegated schedule) and publishes nothing for a Pi push |
| Docs | `docs/components/agent-detection.md`, `docs-ai/068-agent-state-providers/architecture.md`, `claude.md` (new *Program status* section with the observed boundary table), `docs-ai/013-prowl-cli/contracts/agents.md`, [producer-baseline.md](producer-baseline.md) (the Claude "Verification inside Prowl" table), `000-plan.md` (boundary rows corrected from the observations) |

No other code changed: the push path, the delegated tick, the withdrawal fence, the
command-finished release, readiness, and the CLI surface are slice 2's (#893).

## Review

A read-only Pi Reviewer loop against the branch (brief: plan, 003, baseline, 068, 064.024,
the diff, and the code paths the flip activates). Round 1 returned three findings:

| # | Finding | Disposition |
| --- | --- | --- |
| 1 | A delegated tick hands the session resolver the screen text of the last full tick, so after a same-PID `/clear` or `/resume` the fingerprint matcher can keep selecting the outgoing session with high confidence until the next key press (no fresh miss ages it); the plan's "a few ticks longer" understated this | Accepted as a known limitation, not changed in this slice (see *Open questions*); the plan's `/clear` row and `068/claude.md` now state it precisely |
| 2 | The table was flipped before the inside-Prowl acceptance record existed | Closed by this record and the baseline table; the gate runs are below |
| 3 | The manual described a finished command as an unconditional fallback and delegated work as "process only" | Accepted: `agent-detection.md` now says `clear` withdraws authority, a finished command wakes a probe that keeps the authority for the same owner and releases a confirmed exit, and delegated ticks probe the process and resolve the session |

Round 2 (against the docs written after the replay) returned four findings, all accepted
and all documentation corrections: `seen` starts true, so the Done badge seen after the
trust dialog cannot come from `osc.idle` (the explanation was rewritten); the session
limitation does not extend to `agents read`, which resolves again from a fresh screen; the
new Claude provider section had described a confirmed exit as a provider resumption; and
`prowl agents` reads the published pane decision, not the coordinator's current one. Round 3
confirmed the four fixes against the code with no new finding.

## Verification

| Gate | Result |
| --- | --- |
| TDD | `defaultTableVerifiesClaudeCodeOnly()` and `productionTableVerifiesClaudeCodeAndNotPi()` failed before the flip (`.unverified` for `.claude`; the pushed pane stayed `idle`) and passed after it; the five program-status test classes (63 tests) passed on the flipped tree |
| `make check` | passed on the final tree (swift-format, SwiftLint strict after two test locals were renamed for `identifier_name`, script tests, naming and localization checks) |
| `make test` | passed on the final tree: ProwlTests 3799 passed / 0 failed (verified xcresult 3805 tests, one more than #893), event monitor 12, mirror 72 (1 skipped), shell cancellation 3; the 12 build warnings are the pre-existing ones on `main` |
| `make build-app` | passed with 0 warnings on the final tree |
| Isolated Debug run (gate 6) | Branch build in a second instance (`CFFIXED_USER_HOME=/tmp/prowl-079-s3-home`, own socket, `script -F` log) with Claude Code 2.1.296; the real `~/.claude/sessions` and `~/.claude/projects` linked read-only into the isolated home so the native and session paths are observable. Every row of the plan's acceptance list was replayed and is recorded in the baseline's *Verification inside Prowl* table: trust → `claude.blockedPrompt` → `osc.idle` delegated; prompt → `osc.working` (≈ 100–350 ms CLI-polled); Bash write → `osc.blocked.permission` → `osc.done` → Done → viewed → Idle; AskUserQuestion → `osc.blocked.question`; foreground subagent → root-driven; background subagent → root `working` while Claude waits for it (see below); Esc and `/clear` → `osc.idle`; invalid API key → `osc.blocked.auth`; `/exit` 545–793 ms and `kill -9` 394 ms to release (CLI-polled; `main` 1.8–2.1 s); relaunch → own `osc.idle`; close + undo (`prowl key <pane> cmd-z`) → restored pane carries `osc.done` from the retained store; `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` → `native.*` with the screen rules; `Claude Test` Profile (sonnet, bypass permissions, managed hooks) → launch dispatch receipt, `agents wait --until idle`, and a re-dispatch all resolved with `hook_claude` at `exact`. The Pi pane in the same instance stayed `legacy.detector` with shadow lines. No case was found where OSC was wrong and the legacy decision right: on every disagreement-prone row (`/compact`, background agents) the fresh screen rule read by `agents read` agreed with the root record |
| CPU (gate 2) | `make measure-cpu` on the slice build against the slice 2 baseline on `main` (one Claude pane and one Pi pane). Idle: `20261011-013537-61800` mean 1.0 %, `detectAgentState` 0.52 % of a core, `AgentSessionResolver.resolve` 0.06 % (baseline `20261010-214229-57604`: mean 1.0 %, 0.49 %, 0.04 %). Working, both agents writing essays for the whole sample: `20261011-014153-69839` mean 9.5 %, `detectAgentState` 0.31 %, `AgentSessionResolver.resolve` 0.03 %, SwiftUI `stepTransactionFlush` 5.4 % (baseline `20261010-214500-60944`: mean 26.1 %, 0.52 %, 0.02 %, 7.8 %). The working mean is not a like-for-like saving: the display was off and the screen locked during this run, the Claude pane ran the `sonnet` model, and the baseline window was key; the per-symbol numbers are the comparable part. Load 1.6–2.8 on 12 cores. An earlier working sample in which Claude finished mid-window (`20261011-013707-63680`) showed `detectAgentState` at 1.08 % and is kept only as a caution about short tasks |
| Review loop (gate 7) | three rounds: 3 findings, then 4 documentation corrections, then 0; every finding was verified by reading the code before it was accepted |

## Observations

- **Background agents keep the pane Working.** Claude Code 2.1.296 does not end the turn
  when it starts a background subagent: the TUI shows `✻ Waiting for 1 background agent to
  finish`, the prompt box is usable, and the root record stays `working` until the subagent
  returns, when the turn ends with `done`. The fallback screen rule `claude.backgroundWork`
  reads the same frame as Working, so the two paths agree. The product decision of
  2026-10-10 (background work leaves the pane Idle and never blocks a workflow) is
  implemented on Prowl's side (child `working` is ignored) but does not take effect for
  Claude until Claude Code reports the main turn as `done` with the subagent as a child
  record; that is a producer gap to report upstream, not a Prowl change.
- **`osc.blocked.auth`.** An invalid `ANTHROPIC_API_KEY` accepted at launch makes the first
  prompt fail with `Invalid API key`; Claude reports `blocked kind=auth` and holds it, so
  the pane is Blocked where the legacy path showed an idle composer. Treated as correct:
  the agent cannot continue without the user.
- **Done badge after the trust dialog.** The first manual pane showed Done when the trust
  dialog gave way to `osc.idle`. `seen` starts true and `osc.idle` neither earns nor clears
  the badge, so the badge cannot come from that report; the legacy poll runs at 300 ms while
  the dialog is Blocked, and a legacy Blocked → Idle transition on the mounting TUI, before
  Claude's `idle` report arrived, is the only path in the code that earns it (observed cause,
  not instrumented). A relaunch without the dialog went `fallback.noRuleMatched` → `osc.idle`
  and stayed Idle, which agrees.
- **Roster status can trail the reason by one hop.** `prowl agents` reads `detection_reason`
  from the published terminal pane decision (`surfaceAgentStates`) and `status` from the
  reducer's Active Agents entry, which the push updates asynchronously, so a single poll
  taken between the two can show the old status with the new reason. Readiness (`agents
  wait`, dispatch, workflows) reads the coordinator's current decision instead, which drops
  an `osc.*` reason at once on a withdrawal while the published decision waits for the fresh
  observe. Pre-existing architecture.
- **Isolated homes hide the registry.** With `CFFIXED_USER_HOME` the native provider reads
  `<home>/.claude/sessions`, which is empty, so slice 2's runs saw `screen.logUnavailable`
  where the plan expected `native.*`; linking the real `sessions` directory into the
  isolated home restores the `native.*` fallback. The session resolver likewise needs the
  pane's cwd to be the real path (`/private/tmp/...`, not `/tmp/...`) to find the
  transcripts, and a cwd shared by several Claude sessions defeats its unique-candidate
  fallback; neither is specific to this slice.
- **Undo-close under a locked screen.** A posted ⌘Z never reached Ghostty's keybinding while
  `loginwindow` was frontmost; `prowl key <other pane> cmd-z` within the undo timeout did.

## Open questions

- **Session identity while delegated** (review finding 1). Under delegation the session is
  re-resolved every 2 s against the frame read at the last key press. A rotation the frame
  did not yet show (`/clear`, `/resume` typed moments before the tick read the screen) can
  keep the outgoing session, with `high` confidence, until the next key press or CLI input.
  This is the roster's and the pane's retained identity only: `agents read` resolves the
  session again from a fresh screen (`resolveFresh`) and reports `unavailable` rather than
  the old transcript when that fails. Three options were
  weighed and none taken here: (a) pass no screen text on delegated ticks, which would age a
  fingerprint-matched session to nil after three misses during any long idle stretch;
  (b) skip the resolver on delegated ticks and keep the last session as non-fresh, which
  also stops the file-based `recent_file` resolution; (c) keep the active cadence for a
  short window after each input (say 5 s) so the rotation is read with a fresh frame, which
  reintroduces screen reads around interactions. (c) is the author's recommendation and
  needs a decision from onevcat; the plan's `/clear` row now states the current behaviour.
- The live replay could not resolve any Claude session in the isolated instance (two
  sessions shared the cwd and the fingerprint matcher did not match), so the rotation
  scenario above is a code-reading result, not a reproduced one.
- Child records were not observed from inside Prowl: there is no per-report diagnostic for
  verified producers, and the CLI exposes only the root decision. A Debug-only report line
  (state, id, app, kind; never `msg`) would make the next producer's replay cheaper.

## Refs

Builds on #887 (slice 1), #892 (plan), #893 (slice 2). #891 (legacy background-work
semantics) stays open. PR #895.
