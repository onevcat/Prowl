# 079 — Program Status (OSC 7501): Action Log

The outcome of [000-plan.md](000-plan.md) across its four slices. Each slice has its own
record with the code, the review rounds, the gate runs, and the observations; this file is
the index and the state after the last merge.

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-10 | Slice 1: fork action `GHOSTTY_ACTION_PROGRAM_STATUS`, the Swift copy of the report, the pty harness `scripts/program_status_probe.py`, and the producer baselines for Claude Code 2.1.296 and Pi 1.1.0 | #887, [002](002-fork-action-and-bridge.md), [producer-baseline.md](producer-baseline.md) |
| 2026-10-10 | Plan reviewed (11 → 5 → 1 → 0 findings) and merged | #892 |
| 2026-10-10 | Slice 2: record store with the time fence, state machine event and authority transition, coordinator push path and authority epoch, delegated schedule, interruptible wake, `COMMAND_FINISHED` release, undo-close feed, readiness through the coordinator's current decision, `prowl agents` reasons; every agent `.unverified`. Three review rounds (8 → 2 → 0) | #893, [003](003-generic-provider.md) |
| 2026-10-11 | Slice 3: Claude Code `.verified`; the acceptance list replayed in an isolated Debug instance; the pane's session identity moved from the screen fingerprint to Claude's pid registry (`process_log` / `exact`, a three-miss hold across transient read failures, `agents read` reports current evidence). Six review rounds | #895, [004](004-claude-verified.md) |
| 2026-10-11 | Slice 4: Pi `.verified`; the acceptance list replayed with Pi 1.1.0; a 3 s settle window after each wake keeps the screen reads that attribute an in-process `/new` or `/resume`. Five review rounds | #896, [005](005-pi-verified.md) |
| 2026-10-11 | #895 merged; #896 merged after the reconciliation with `main` (both producers `.verified`, the two table tests combined with an unverified codex control, the support rows in the manual and the living docs) | this record |
| 2026-10-12 | Oh My Pi `.verified` (`app=omp`, 18.8.7+): harness baseline with omp 18.10.0, the acceptance list replayed in an isolated Debug instance, the table tests extended | #900, [006](006-omp-verified.md) |

## Outcome & current state (as of 2026-10-17)

- **Who decides.** For Claude Code 2.1.295+ (`app=claude-code`), Pi 1.1.0+ (`app=pi`),
  Oh My Pi 18.8.7+ (`app=omp`, since [006](006-omp-verified.md)), and Codex 0.163.0+
  (`app=codex`, since [007](007-codex-verified.md)) the pane's OSC 7501 root record is the first-priority state evidence, applied the moment
  the report arrives. While it decides, the detection loop delegates: every 2 s it probes
  the process and resolves the session, reads no screen, and `screen_reason` reports
  `screen.delegated`. A wake (key press, CLI input, finished command, report for an unbound
  pane, withdrawal) keeps the 300 ms cadence with screen reads for 3 s before the pane
  delegates again. Every other agent is `.unverified`: records are stored, fenced, and
  resolved, the shadow comparison is logged, and the legacy decision is published. The
  table is static (`ProgramStatusSupport.level(for:)`); the producer's own variables
  (`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`, `PI_PROGRAM_STATUS=0`, Oh My Pi's
  `terminal.programStatus: false`) are the escape hatch where available. Codex
  0.163.0 has no OSC-specific opt-out.
- **What the fallbacks are.** Claude Code: the native registry snapshot and the screen rules,
  as before slice 3; the native provider is not sampled while the record decides. Pi: the
  legacy screen detector (`legacy.detector`). Oh My Pi: its screen rules. Codex: its
  log provider and screen rules. The record is withdrawn by `clear`, by the
  `COMMAND_FINISHED` probe when the agent is gone, and by the time fence on relaunch.
- **Root-only mapping.** The root record decides; a child `blocked` vetoes, a child `working`
  is ignored. Claude Code 2.1.296 does send child records, and it keeps the root `working`
  while it waits for a background agent (the result is auto-submitted as a new turn before
  `done`), so the Idle-while-background decision of 2026-10-10 does not take effect for
  Claude until the producer reports the main turn as done; decided on 2026-10-11 to keep the
  behaviour and to make workflow and dispatch delivery independent of the agent state later.
- **What every agent got.** The `COMMAND_FINISHED` release: an agent that exits is released
  within one probe (Claude `/exit` 545–793 ms, `kill -9` 394 ms; Pi ctrl+d 69 ms, `kill -9`
  143 ms, all CLI-polled; `main` before 079 took 1.8–2.1 s), and an undo-close restores the
  pane with its store intact. Oh My Pi is the exception once it has drawn a user message:
  its own OSC 133 marks use up the shell's command timer, so its exit takes the six-miss
  release (2.1–3.4 s observed; a fresh session still releases within 0.3 s), see
  [006](006-omp-verified.md).
- **Session identity.** Claude Code: `ClaudeSessionRegistry` reads `~/.claude/sessions/<pid>.json`
  (`process_log` / `exact`); a rotation is visible within one delegated tick (`/clear` 2.1 s,
  in-process `/resume` 4.2 s, no input needed). Pi: the transcript scan plus the screen
  fingerprint, with the settle window (an in-process `/resume` followed in 2.5 s). Oh My Pi:
  the transcript scan over `~/.omp/agent/sessions` plus the screen fingerprint, with the
  settle window.
- **Cost.** `make measure-cpu` against the slice 2 baseline on `main`: idle `detectAgentState`
  0.49 % of a core before, 0.52 % (slice 3 build) and 0.70 % (slice 4 build, higher load)
  after; under OSC authority the per-symbol working cost is lower than the 300 ms loop's. The
  overall working means are not like-for-like across runs (locked screen, model, window).
- **Flipping the next producer** repeats slices 3/4 (and 006): harness rows in the baseline,
  the acceptance list replayed in an isolated Debug instance, the *Verification inside Prowl*
  table filled, a living doc under 068, `ProgramStatusSupport.level(for:)` and `programStatusApp` updated, the two
  table tests (`defaultTableVerifiesClaudeCodePiAndOMP()`,
  `productionTableVerifiesClaudeCodePiAndOMP()`) extended, and the support rows in
  `docs/components/agent-detection.md`, [068/architecture.md](../068-agent-state-providers/architecture.md),
  and the `agents` contract updated.

## Deviations from plan

- Slice 2's small deviations (shadow line on every transition, unmapped-app line from the
  poll, revision bump on `commandFinished`, last scan text for the delegated resolver, owner
  generation keyed by `launchProcessID` alone) are listed in [003](003-generic-provider.md).
- The plan assumed the delegated tick could keep the session from the last full tick's frame.
  Slice 3's review showed an in-process `/resume` to a session with a process-lifetime
  transcript stayed on the outgoing session until the next input; the fix was not in the
  plan: Claude's pid registry (#895) and, for Pi and registry-less Claude versions, the 3 s
  settle window (#896). See *Session identity under delegation* in [004](004-claude-verified.md).
- The plan's baseline rows listed child records as "not observed"; the 2026-10-11 harness
  replay showed Claude Code 2.1.296 sends them, and that the root stays `working` across a
  background agent (recorded in the baseline and in [004](004-claude-verified.md)).
- `/clear` on Claude Code sends `working` then `idle` (the plan's row said idle only).

## Open questions

- [#891](https://github.com/onevcat/Prowl/issues/891): the legacy paths still show
  background work as Working; deferred, the OSC path applies the root-only rule.
- [#897](https://github.com/onevcat/Prowl/issues/897): panes under `/tmp` or `/var` never
  resolve a cwd-keyed transcript session (`resolvingSymlinksInPath()` strips `/private`);
  found during the slice 4 replay, pre-existing on `main`. Resolved: the resolver now
  derives the physical variant with `realpath(3)`.
- [#894](https://github.com/onevcat/Prowl/issues/894): `agents dispatch` on a manual Claude
  Code 2.1.296 pane is refused because the composer placeholder reads as a draft.
- Producer gap to report upstream: Claude Code keeps the root `working` while a background
  agent runs, so the pane cannot go Idle without a Prowl-side heuristic.
- Child records are stored but not observable from inside Prowl (no per-report diagnostic,
  the CLI exposes the root decision only); a Debug-only report line would make the next
  producer's replay cheaper.
- Not replayed: Pi's `kind=auth` (needs a real OAuth login) and a running `pi-subagents` card
  after the root `done`; Claude's "no report before the trust dialog" is verified in the pty
  harness only.

## Refs

PRs #887, #892, #893, #895, #896, #900. Records [002](002-fork-action-and-bridge.md),
[003](003-generic-provider.md), [004](004-claude-verified.md), [005](005-pi-verified.md),
[006](006-omp-verified.md), [007](007-codex-verified.md), [008](008-more-producers.md);
[producer-baseline.md](producer-baseline.md). Living docs:
[068/architecture.md](../068-agent-state-providers/architecture.md),
[068/claude.md](../068-agent-state-providers/claude.md), [068/pi.md](../068-agent-state-providers/pi.md),
[068/omp.md](../068-agent-state-providers/omp.md),
`docs/components/agent-detection.md`.
