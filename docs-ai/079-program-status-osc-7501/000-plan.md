# 079 — Program Status (OSC 7501): Plan

| | |
| --- | --- |
| **Status** | Planned (slices 1, 2, and 4 implemented; slice 3 in its own PR) |
| **Anchor date** | 2026-10-10 |
| **Primary PRs** | #887 (slice 1); #893 (slice 2, [003-generic-provider.md](003-generic-provider.md)); #895 (slice 3, Claude Code, separate PR); #896 (slice 4, [005-pi-verified.md](005-pi-verified.md)) |
| **Related** | [078-ghostty-1-4-upgrade-rehearsal](../078-ghostty-1-4-upgrade-rehearsal/000-plan.md), [068-agent-state-providers](../068-agent-state-providers/architecture.md), [064-agent-completion-signals](../064-agent-completion-signals/000-plan.md), `docs/components/agent-detection.md`, [producer-baseline.md](producer-baseline.md), [#891](https://github.com/onevcat/Prowl/issues/891) (legacy background-work semantics, deferred) |

## Background

OSC 7501 (the program status protocol, Rex revision 0.3 of 2026-10-07) lets a program put one
status record per terminal into the PTY stream: `idle`, `working`, `done`, `blocked` (with
`kind=permission|question|auth`), `error`, plus `clear`; optional `id` (`/` nests records),
`app`, `progress`, base64 `title` and `msg`. A program may probe with `OSC 7501 ; ?` and
start reporting when the terminal echoes it; revision 0.3 also allows reports without a
probe, and the parser accepts either. Claude Code 2.1.295 and Pi 1.1.0 ship native support
and both probe first; [producer-baseline.md](producer-baseline.md) records what each one
actually sends.

Prowl decides Working/Blocked/Idle per pane on a 300 ms poll: process probe, screen read and
per-agent string rules, session resolution, then the optional file providers (Codex log,
Claude native registry) through `AgentDetectionCoordinator` and the pure `AgentStateMachine`
(068). Every stage polls; the screen rules are the maintenance burden, and a spinner frame
makes the screen cache miss on every tick while an agent works. OSC 7501 is an explicit,
push-based state signal from the program itself, so it can become the first-priority *state*
evidence and let the poll shrink to process identity. It carries no identity (`id` is a
record key, `app` is self-declared) and no delivery receipt, so it cannot replace the
session resolver, managed hooks, transcript readers, or workflow delivery.

Slice 1 (#887) gave Prowl the bytes: the `onevcat/ghostty` fork answers the query and
delivers every valid report as `GHOSTTY_ACTION_PROGRAM_STATUS`, and
`GhosttyProgramStatusReport` copies it on the main thread. Nothing consumes the reports yet.
The rest of this entry is the detection policy, designed on 2026-10-10 after reading the
detection layer as it is on `main` (see the second amendment for what that review corrected).

## Goals

- Keep a bounded record tree per surface with the protocol's lifetime rules.
- Make the root record the first-priority state evidence for verified producers, applied
  the moment a report arrives rather than on the next poll.
- Stop reading the screen and the native/log files while a verified producer's root record
  is live; keep only a slow process probe for identity and presence.
- Release a pane's agent entry as soon as the shell reports that the foreground command
  finished, for every agent.
- Keep every legacy path intact as the fallback: no root record means today's behaviour.
- Record producer behaviour as replayable baselines before a producer is marked verified.

### Non-goals

- No public `AgentSignal` from OSC reports: `source: .osc` stays reserved. Hook, receipt,
  `--min-confidence exact` and workflow delivery semantics do not change.
- No session identity from `app`/`id`; `logSessionID` keeps coming from native/log providers.
- No version detection and no user setting. A producer either reports or it does not; a
  verified producer is trusted whenever it reports. The escape hatches are the producer's
  own variables (`CLAUDE_CODE_DISABLE_TERMINAL_TITLE`, `PI_PROGRAM_STATUS=0`) and a Prowl
  release that flips the support table back.
- No change to the legacy providers' outstanding-work semantics (Claude native `busy`,
  Codex log children, `claude.backgroundWork`): deferred to #891.
- No removal of screen rules: they stay as the fallback for older producer versions.
- No UI for non-agent producers (cargo, terraform), no Blocked-kind or error presentation,
  no Mirror DTO change; the record store is generic so a later entry can add them.
- No upstream submission: the action stays a fork patch (decided 2026-10-10).

## Design / Approach

### Slice 1 — fork action and Swift copy (landed, #887)

| Fork file (`onevcat/ghostty`, branch `rehearsal/tip-9d479dcb1-patched`) | Change |
| --- | --- |
| `src/termio/stream_handler.zig` | `.program_status`: query → `write_stable` echo with the same terminator (always, Prowl consumes reports); report → copy the validated body into `apprt.surface.Message.WriteReq` and post to the surface mailbox; `fullReset` posts `clear` with an empty id |
| `src/apprt/surface.zig` | `Message.program_status` = `{ state, data: WriteReq }` (owned copy, like `pwd_change`) |
| `src/Surface.zig` | decode `id`/`app`/`kind`/`progress` and the base64 `title`/`msg` into stack buffers sized by the parser limits, perform the action, free the copy |
| `src/apprt/action.zig` | `ProgramStatus { report: *const Report }`; `Report` is the extern struct; `State`/`Kind` enums checked against `ghostty.h` by `checkGhosttyHEnum` tests; passed by pointer so `ghostty_action_u` keeps its 24-byte size |
| `include/ghostty.h` | `ghostty_action_program_status_state_e`, `ghostty_action_program_status_kind_e`, `ghostty_action_program_status_s` (NUL-terminated strings, empty when absent, valid only during the callback), `GHOSTTY_ACTION_PROGRAM_STATUS` appended to the tag enum, pointer member in the union |
| `src/apprt/gtk/class/application.zig` | listed as unimplemented so GTK keeps compiling |

Prowl side: `App/Sources/Infrastructure/Ghostty/GhosttyProgramStatusReport.swift` copies the C
struct into a `Sendable` value inside the synchronous action callback (`ghostty_app_tick`
dispatches surface actions on the main thread, so the strings are valid for the copy);
`GhosttySurfaceBridge.onProgramStatus` hands it to the terminal owner, which only logs it.
The harness `scripts/program_status_probe.py` replays producers outside Prowl.

### Slice 2 — record store, state machine, delegated schedule (generic)

Three signals share the work. OSC 7501 answers "busy, waiting, or at rest" and is pushed by
the agent. OSC 133 D (`GHOSTTY_ACTION_COMMAND_FINISHED`, emitted by Ghostty's shell
integration, not by the agent) answers "the foreground command ended" and is pushed by the
shell. The process probe answers "who is in this pane, is it alive, did it relaunch" and
stays a poll, slowed down while OSC holds authority.

```text
GHOSTTY_ACTION_PROGRAM_STATUS
  -> GhosttySurfaceBridge.onProgramStatus            (main thread, copied)
  -> ProgramStatusRecordStore (one per surface, owned by WorktreeTerminalState)
  -> agent bound to this surface?
       yes -> AgentDetectionCoordinator.receive(programStatus:) -> decision -> publishDecision (immediate)
       no  -> wakeAgentDetection (immediate probe; the next observe pulls the store snapshot)
  -> AgentStateMachine.resolve: programStatus > native > log > screen
```

**Record store** (`App/Sources/Domain/AgentDetection/ProgramStatusRecordStore.swift`, pure):
a report replaces its record completely; `clear` removes the record and its descendants,
with an empty id everything (a full reset arrives this way from the fork); a record without
`app` inherits the nearest ancestor's; at most 256 records with LRU eviction; a monotonic
`revision` per surface and an `arrivedAt` (`Date()` at the callback) per record.
`commandFinished(upTo: revision)` drops the `working` and `blocked` records whose revision is
at or below the store revision captured when the 133 D arrived, and keeps `idle`/`done`/`error`;
this is the protocol's rule for a new shell prompt, scoped to the records that existed when
the command finished so that a successor's reports arriving after the D are never touched.
`title`/`msg` are kept within the parser
limits and are neither logged nor published. The store belongs to the surface, next to
`surfaceAgentStates`, because reports can arrive before the probe has bound an agent (Pi
sends `idle` within 10 ms of the query echo) and because records belong to the terminal, not
to a process.

**Attribution fence** (coordinator). A root record is eligible only when it exists, its
`app` (after inheritance) equals `DetectedAgent.programStatusApp` (`claude` → `claude-code`,
`pi` → `pi`, every other agent `nil`), and `arrivedAt >= process.startedAt` of the detected
agent's process generation (`ProcessDetection.processStartDate` has microsecond precision).
The arrival-time test applies to every record, not only the root: a child left behind by a
previous process (it exited without `clear` and a new root replaced only the root record)
has an `arrivedAt` before the new process started and is ineligible, whatever `app` it
inherits now. Ineligible records stay in the store for diagnostics. The fence is attribution,
not trust: a wrapper, a nested program, or `cat` can write a root, so `app` decides whose
state a record is, never whether it is authentic.

The fence is only as current as the coordinator's process binding. Today `observe` rebinds
on a same-agent process change only for agents with a provider (`hasProvider`, Claude and
Codex); a Pi relaunch keeps the first generation. Slice 2 rebinds for every agent with a
`programStatusApp` as well (reset the machine, adopt the new generation), and the push path
consumes a report only against the generation the last probe confirmed. A binding stays
current until a probe reports a different generation or a miss; a report that arrives during
a probe gap is consumed against the last confirmed binding, and the arrival-time test is
what keeps a predecessor's records out of it. The generation is the identified agent process
(`agentProcessID`, the same generation the providers use), not the shell-launched
`launchProcessID`.

**State machine.** New event `.programStatus(ProgramStatusEvidence?)`; `nil` withdraws the
evidence (root cleared, command finished, eligibility lost) and the machine falls back to
native > log > screen with the reasons it reports today. No silence timeout, ever. The pane
state follows the root record only:

| Evidence | Decision | `detection_reason` |
| --- | --- | --- |
| root `working` | Working | `osc.working` |
| root `blocked` | Blocked | `osc.blocked.permission` / `.question` / `.auth` / `.unspecified` |
| root `idle` / `done` | Idle | `osc.idle` / `osc.done` |
| root `error` | Idle | `osc.error` |
| any child `blocked` | Blocked | `osc.childBlocked.<kind>` |
| child `working` | no change; the record stays in the store | — |

`hasOutstandingWork` is true for a root `working`/`blocked` and for any eligible child
`blocked`; a child `working` never sets it. Background agents and subagents therefore do not
keep a pane Working and do not veto `agents wait --until idle`, dispatch readiness, or
workflows (decision of 2026-10-10; the legacy providers still do, see #891). A child
`blocked` still reads as Blocked and still vetoes idle admission, because a subagent's prompt
is shown to the user and needs an answer, and because `AgentConditionEvidence.exactMatch`
accepts a post-arm `turn-ended` without detector corroboration: without the veto, a parent
turn end would release a wait while the child's prompt is open. While an eligible root exists
the screen is not consulted at all (it is not even read, see the schedule); it enters only
when the evidence is withdrawn.

**Done presentation.** `PaneAgentState.displayState` keeps its meaning: Done is a completed
turn the user has not looked at, and it turns into Idle when the pane is actually viewed
(`markAgentSeen`, `isViewedSurface`). What changes is which idle decisions may earn the badge:
`osc.done` and `osc.error` may, `osc.idle` never does, because `idle` is sent at mount, on
interrupt (Esc), and on a session reset, none of which leaves a result to look at.
`resolvedSeen` reads the decision reason; the legacy paths keep their transition rule.

**Push path.** The terminal owner gains `publishDecision(surfaceID:decision:)`, extracted
from the tail of `detectAgentState` (pane state, seen, tab busy flag, Active Agents entry).
`onProgramStatus` applies the report to the store and, when a coordinator is bound, calls
`receive(programStatus:)` and publishes synchronously, so Active Agents, the tab indicator,
and the CLI flip in the same main-thread turn. `observe` also pulls the store snapshot on
every poll, so the push and the poll converge. The commit contract for the two paths:

- The machine records the highest store revision it has applied and ignores a snapshot with
  an older or equal revision. A poll that captured its snapshot before suspending at the
  provider `await` and applies it afterwards therefore cannot roll back a newer push.
- The push publishes by merging state, decision, seen, and `lastChangedAt` into the current
  `PaneAgentState`; session, pid, launch observation, and profile metadata are untouched.
- A poll whose captured `previous` pane state went stale during its suspension is discarded
  as today (`guard previous == latest` in `detectAgentState`) and the next tick redoes it.
  State transitions are rare relative to the poll, so the discard cannot starve session
  metadata; a `working` report that only changes `msg` does not change the decision and
  publishes nothing.
- The coordinator's `revision`/`invalidate` and `lastCapturedAt` ordering (064.024) are
  unchanged; a push after `invalidate` is dropped like any other stale result.

**Detection schedule.** `AgentDetectionSchedule` gains `.delegated`:

| Schedule | Interval | Work per tick | Condition |
| --- | --- | --- | --- |
| cold | none | — | no agent, warm window expired |
| warm | 2 s | full | within 30 s of a key press, or an agent just left |
| active | 300 ms | probe + screen read and rules + session + provider sample | agent present, no OSC authority |
| delegated (new) | 2 s (`idleAgentDetectionInterval`) | probe + session resolution only | eligible root and the producer is verified |

Leaving delegated for active: evidence withdrawn (`clear`, a confirmed command-finished
release), a key press, or a probe miss. The probe and the session resolver themselves do not
change in this entry. `wakeAgentDetection` becomes a real wake: the loop's sleep is
interruptible, and a key press, `COMMAND_FINISHED`, a report arriving while no agent is
bound, and an OSC withdrawal each trigger an immediate probe. The title-coalescing trailing
flush keeps riding the loop.

When eligible OSC evidence first takes authority, the machine retires the provider facts
and screen fences it will not refresh while delegated: the native snapshot, the suppressed
screen frame and its session, and the log roots' recency. This is a dedicated transition
inside the `.programStatus` handling, not `.suspended`: suspension is continuity-preserving
by design (it keeps the native snapshot and the completed-frame fence so a transient read
failure recovers without flicker, see 068 and `AgentNativeStateTests`), and it also sets
`hasLogProvider`, which would turn Pi's fallback reason from `legacy.detector` into
`screen.logUnavailable`. The dedicated transition touches neither. A withdrawal does not
publish by itself: the last published state stands until an `observe` whose capture started
after the withdrawal completes with a fresh screen read and a fresh provider sample. The
coordinator stamps each observation with an authority epoch that the transition bumps; a
provider sample that was already in flight when OSC took authority is **discarded** when it
lands (its events are not applied), because applying it would recreate the native snapshot
and completed-frame fence the transition just retired, and a later `suspended` first read
after a withdrawal would then publish that pre-OSC Idle through the retained-completion path.
The machine itself re-resolves on the withdrawal (its current decision immediately stops
carrying an `osc.*` reason); only the pane publication waits for the fresh observe.

**Release on command finished** (every agent, not only OSC producers). `handleCommandFinished`
wakes the probe with the `AgentProcessProbe` cache bypassed (the cache keeps hits and misses
for 0.75 s, so a cached sample could neither confirm nor deny the exit). `AgentDetectionPresence`
treats a miss from that fresh sample as sufficient to release the entry instead of waiting
for `releaseMissThreshold` (6) misses; a cached or unrelated miss does not qualify. The fresh
sample has three outcomes:

Two generations matter here and they are different keys. The *engine* generation is the
identified agent process (`agentProcessID`), which binds the OSC/provider evidence and may
legitimately change while the same launch continues (a runtime that forks or replaces an
engine child; `PaneAgentState.retainedLaunchProcessID` keeps the launcher while it is still
a live ancestor). The *owner* generation is the shell-launched process (`launchProcessID` +
start), which keys the launch profile and the managed-hook evidence epoch. The D arrival
also captures the store revision for the scoped cleanup.

| Fresh sample after 133 D | Effect |
| --- | --- |
| same owner, same engine (nested-shell D) | nothing: records, OSC authority, schedule, launch context all stay |
| same owner, different engine (engine child replaced) | the coordinator rebinds the evidence generation; launch context stays; no cleanup |
| no agent | entry released; `commandFinished(upTo:)` drops the `working`/`blocked` that existed at the D (`done`/`error` stay for a later non-agent UI); the coordinator is invalidated |
| different owner (a successor launch started before the probe ran) | the finished owner's launch context is retired exactly as a release would retire it (`launchProfilesBySurface`, hook registration), the coordinator rebinds, the successor is detected as the user's own agent, and `commandFinished(upTo:)` drops only the predecessor's records: anything the successor sent after the D keeps its revision above the captured one and stays |

The last row closes a gap the six-miss path has today, where a successor that appears before
the first miss inherits the predecessor's profile attribution. The probe stays the judge in
all four. `clear` is not exit evidence (it is a legitimate "remove my status") and only
withdraws and wakes.
Ghostty emits `COMMAND_FINISHED` only when a 133 C started a command timer, so a prompt
without a preceding C/D gets no accelerated release; the probe and the time fence cover it.
Prompt start (133 A) is not exposed as an action; D is the approximation this entry uses.

**Support table.** `ProgramStatusSupport` is a static table keyed by `DetectedAgent`:

| Value | Meaning | Published decision | Schedule |
| --- | --- | --- | --- |
| `.unverified` | reports are stored, fenced, and resolved, but only compared with the live decision; disagreements are logged | legacy | active |
| `.verified` | an eligible root drives the decision | OSC | delegated |

Slice 2 ships every agent `.unverified`, so unverified OSC evidence never replaces the legacy
decision. The slice is not behaviour-neutral, though: the command-finished release and the
interruptible wake are active for every agent, so its gate includes legacy-only regression
checks (an agent that never reports, a cached probe sample, dispatch and `wait --until exit`
after a fast release). Slice 3 flips Claude, slice 4 flips Pi. Adding a producer later is: baseline replay, a `programStatusApp`
mapping, a table flip, docs. An unmapped `app` that reports is logged once per surface
("program status present, app=<x> unmapped") so new producers show up in dogfooding logs.

**Diagnostics.** Shadow disagreements are logged on transition in the `AgentDetection`
category (surface, agent, OSC decision and reason, live decision and reason, revision),
throttled per surface like the provider warnings, never with `msg`.

**CLI surface.** `detection_reason` gains the `osc.*` values. While delegated,
`screen_reason` is `screen.delegated` and `raw_state` is the last screen scan. `prowl agents`
takes both from the decision when it is OSC-driven (today `AgentsCommandHandler` prefers the
cached scan over the decision's screen reason, which would hide the marker). `prowl agents
read` is the on-demand exception: it keeps reading and classifying a fresh screen, reports
the decision's status and reason, and fills `blocker.text` only when a screen rule finds it;
an OSC-only Blocked (no screen blocker) returns a null blocker rather than
`blockerUnreadable`, and Pi stays unsupported by `agents read`. `AgentConditionEvidence`
treats every OSC idle decision (`osc.idle`, `osc.done`, `osc.error`) like `native.idle`: an
unmatched screen is still idle evidence under current OSC authority, and the child-blocked
veto comes through `hasOutstandingWork`. For that to hold, the condition snapshots that
`agents wait`, `agents dispatch`, and the workflow runner build must read the coordinator's
**current** decision (`AgentDetectionCoordinator.decision`, the machine's latest resolution),
not the `stateDecision` carried by the reducer's Active Agents entry and not the published
`surfaceAgentStates` decision either. The reducer entry is wrong because
`equalsIgnoringRawState` drops reason-only changes from emission on purpose, so a reason that
moved from `screen.*` to `osc.idle` never reaches it until the state itself changes. The
published pane decision is wrong in the other direction: a withdrawal publishes nothing until
the fresh observe, so it would still carry `osc.idle` while the authority is gone, and a wait
armed in that window would accept an unmatched screen as idle evidence. The machine
re-resolves on the withdrawal, so its current decision drops the `osc.*` reason at once; the
OSC exemption therefore applies exactly when the current decision's reason is `osc.*`.
`AgentConditionSnapshot` gains that decision next to the entry; emission dedup and pane
publication are unchanged. The living contracts
`docs-ai/013-prowl-cli/contracts/agents.md` and `agents-read.md` are updated with the new
values and the delegated semantics. No `Shared/` change: reasons are strings.

**Lifecycle** (existing signals only):

| Signal | Store | Decision |
| --- | --- | --- |
| `clear` (including RIS from the fork) | remove by id / empty | withdrawn → fallback |
| `COMMAND_FINISHED` (OSC 133 D) | revision captured; untouched until the fresh probe reports: same owner → nothing; no agent or a different owner → `commandFinished(upTo:)` drops the `working`/`blocked` that existed at the D | same owner → nothing (an engine-child change only rebinds); no agent → entry released; different owner → launch context retired, successor rebinds (see the release table) |
| probe finds the agent gone | untouched | coordinator invalidated; the time fence rejects the old records for the next agent |
| undo-close retains the surface | kept and still fed: the bridge callback for reports stays wired to the store while publication is suppressed (the process keeps running and the protocol has no heartbeat, so a dropped store could never be rebuilt for an unchanged `blocked`). The retained surface has no entry, detector, or probe (`forgetSurface` removed them), so a `COMMAND_FINISHED` during retention applies `commandFinished(upTo:)` to the store directly with the revision at that D; a nested-shell D in that window is an accepted degradation (fallback after restore until the next report) | on restore the wake probe rebinds and pulls the snapshot through the fence |
| surface closed | removed | — |

`GHOSTTY_ACTION_SHOW_CHILD_EXITED` is not a lifecycle input: for a live pane the shell's
exit closes the pane, and `onChildExited` is wired only for undo-close surfaces. The 15 s
OSC 9;4 stale watch in `GhosttySurfaceBridge` is not reused, and OSC 9;4 is not mapped into
7501 records; both keep feeding `taskStatus` independently as today.

**Tests.** Store (replacement, subtree clear, clear of a missing record, inheritance across
a missing parent, LRU eviction of a root with children, `commandFinished`, revision, a report
with no preceding query); machine (every mapping, child blocked veto, withdrawal fallback,
root-only outstanding work, done versus idle badge eligibility, older snapshot revision
ignored, OSC authority retiring the native snapshot and completed-frame fence while
`hasLogProvider` and Pi's `legacy.detector` reason are untouched, native idle + unchanged
working frame + OSC turns + withdrawal with a `suspended` first sample); coordinator (app
mismatch, per-record time fence with a predecessor's child left behind, rebinding on same-app
relaunch and PID reuse, report before the first probe, presence hold, unverified never
drives, verified push, push during a suspended provider sample, in-flight provider sample
from an earlier authority epoch discarded when it lands, then withdrawal with a `suspended`
first read must not publish a pre-OSC Idle, invalidate before push, injected table); presence
and release (single-miss release only from the fresh post-wake sample, cached hit and cached
miss ignored, nested-shell false positive does not release, same owner with a replaced engine
child rebinds without retiring the launch context, a different owner retires it, a successor
root `working`/`blocked` that arrived after the D and before the probe survives
`commandFinished(upTo:)` and keeps OSC authority without a further report); readiness,
through the real `AgentConditionSnapshot` builders (`idleVerdict`, `exactMatch`, dispatch
admission, and workflow role waits with root done + child blocked and pre-/post-arm
`turn-ended`; `osc.error` with an unknown screen; a reason-only change from `screen.*` to
`osc.idle` reaching the wait; a wait armed between a withdrawal and the fresh observe does not
use the withdrawn `osc.idle`); pipeline (report → `PaneAgentState`); terminal state (wake when unbound,
undo-close keeps feeding the store and a retained D applies directly, restore rebinds, close
during a suspended observe, delegated tick skips screen and provider sample, withdrawal
publishes nothing until an observe that started after it, engine-child takeover does not
retire the launcher); CLI (`agents` delegated marker precedence, `agents read` OSC-only
Blocked). Swift Testing, injected clocks, no sleeps.

**Docs.** `docs/components/terminal.md` (Prowl now keeps the records), `agent-detection.md`
(new "Program status (OSC 7501)" section: support table, reasons, release on command
finished, no setting, producer variables), `cli.md` (reason values, delegated fields),
`docs-ai/013-prowl-cli/contracts/agents.md` and `agents-read.md` (living contracts).
Amendment `003-generic-provider.md`.

### Slice 3 — Claude Code verified

Flip `claude` to `.verified`. In delegated mode `ClaudeRuntimeProvider` is not sampled, so
the 300 ms read of `~/.claude/sessions/<pid>.json` disappears while OSC holds authority. On a
withdrawal the active tick samples it again: the provider keeps `lastUpdatedAt`, so an
unchanged file resumes authority and an older or unreadable one reports `suspended` as today.
Because OSC authority retired the pre-OSC native snapshot and completed-frame fence when it
began (see the schedule section), a `suspended` first sample after withdrawal falls to the
fresh screen read, never to a snapshot from before the OSC turns. The provider and the six
Claude screen rules stay as the fallback. Managed hooks are untouched and remain the exact
path.

| Claude boundary | Handling |
| --- | --- |
| trust dialog | no report before it is answered → screen rule `claude.blockedPrompt`, as today; `idle` after acceptance takes over |
| `/clear` | same PID, new session; OSC unchanged. The public session follows the resolver's existing cache and retention policy (successful results cached 5 s, the old session retained for up to two fresh misses), invoked on the 2 s tick, so rotation can take a few ticks longer than under the 300 ms poll; OSC never supplies identity |
| interrupt (Esc) | expected `idle` (static mapping `stopped → idle`, not yet observed) |
| subagents (Agent tool) | expected child records; the pane follows the root |
| background agents | expected root `done` with or without child records → Idle/Done; the fallback rule `claude.backgroundWork` keeps the old Working for older versions |
| `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`, `CLAUDE_CODE_SESSION_KIND=bg`, < 2.1.295 | no reports → legacy native + screen |

Acceptance in an isolated Debug instance through `prowl agents --json`: trust → accept →
`osc.idle` and delegated; prompt → `osc.working` before the screen spinner; Bash write →
`osc.blocked.permission` → approve → `osc.done` → Done → view → Idle; AskUserQuestion kind;
Agent tool children; background agent → Idle; Esc and `/clear` → `osc.idle`; invalid API key;
`/exit` and kill -9 → release under 100 ms; relaunch in the same pane (time fence); undo-close
restore; disable variable → `native.*`; Profile launch with hooks and `agents wait --until
idle`; `make measure-cpu` idle and working against the slice 2 baseline. Docs:
`agent-detection.md` Claude section, `068/claude.md` program-status section,
baseline "inside Prowl" rows, amendment `004-claude-verified.md`.

### Slice 4 — Pi verified

Flip `pi` to `.verified`. Pi has had only the screen legacy detector (`legacy.detector`,
Working/Idle, never Blocked); OSC gives it its first provider and its first Blocked
(extension dialogs: `ctx.ui.confirm` → permission, `select`/`input`/`editor` → question).
The Pi screen rules and the managed `-e prowl-hooks.ts` extension are untouched.

| Pi boundary | Handling |
| --- | --- |
| pi-subagents still running after root `done` | Idle, by the root-only rule; the fallback `hasPiRunningAsyncSubagentCard` keeps Working for older versions; documented with Pi #10664 |
| built-in selectors (`/model`, `/settings`) | no report → previous root state; no regression (Pi never had Blocked) |
| `error` (provider auth failure) | Idle, `osc.error`, badge-eligible; stays until exit |
| wrapper writing the root | another `app` → fenced; no `app` → ineligible; `app=pi` → trusted |
| Oh My Pi | separate agent, `app` unknown, stays `.unverified` |
| `PI_PROGRAM_STATUS=0`, < 1.1.0 | no reports → legacy screen |

Acceptance: launch → `osc.idle` on the first probe; prompt → `osc.working` → `osc.done` →
Done → view → Idle; Esc → `osc.idle`; gate extension confirm → `osc.blocked.permission`;
gate extension select → `osc.blocked.question`; `/model` → unchanged (documented gap);
pi-subagents (optional, extension not installed locally) → Idle; expired OAuth → `osc.error`;
ctrl+d and kill -9 → release under 100 ms; relaunch (time fence); `PI_PROGRAM_STATUS=0` →
`legacy.detector`; Profile launch with the extension and `agents wait --until idle`;
`make measure-cpu`. Docs: `agent-detection.md` Pi section, new living doc `068/pi.md`,
baseline rows, amendment `005-pi-verified.md`.

### Slices and gates

| Slice | PR | Content | Gate to merge |
| --- | --- | --- | --- |
| 1 | #887 | fork action, Swift copy, harness, baselines | landed |
| 2 | #893 ([003](003-generic-provider.md)) | store, machine, coordinator, delegated schedule, command-finished release, all `.unverified` | `make check`, `make test`, `make build-app`; a Debug run with Claude and Pi shows shadow disagreements only where expected; legacy-only regression checks for the fast release (an agent that never reports, kill -9 and normal exit, relaunch in the same pane, `wait --until exit`, a pending dispatch across the release) |
| 3 | — | Claude `.verified` | acceptance list above replayed; no case where OSC was wrong and the legacy decision right; CPU recorded |
| 4 | #896 ([005](005-pi-verified.md)) | Pi `.verified` | same, for Pi |

PRs merge in order: slice 2 alone, then slices 3 and 4 from `main` in parallel (their
acceptance runs on merged slice 2 code). `001-action.md` is written when slice 4 lands.

### Expected timings

Targets, not measurements: slices 3 and 4 record what the isolated instance actually shows.

| Event | Today | After slices 2–4 |
| --- | --- | --- |
| agent appears in Active Agents | ≤ 2 s (warm poll after the key press) | first report wakes the probe: tens of ms; Claude before the trust dialog still ≤ 2 s |
| state flip while working | 0–300 ms plus a screen rule hit | same main-thread turn as the report |
| exit, shell integration present (normal or kill -9) | 1.8–2.1 s | < 100 ms (133 D, one confirming miss) |
| normal exit, no shell integration | 1.8–2.1 s | ≈ 1.8 s (`clear` returns to active, six misses) |
| kill -9, no shell integration | 1.8–2.1 s | ≤ 2 s first miss + 1.5 s ≈ 3.5 s (the only regression) |
| non-OSC agent exit with shell integration | 1.8–2.1 s | < 100 ms |

Ghostty's `detect` shell integration is injected for the first zsh/bash/fish/elvish shell of
every pane, so most panes have OSC 133; nested interactive shells, ssh, tmux, and clobbered
hooks do not. The probe's residual cost in delegated mode (a dozen syscalls every 2 s per
pane) is expected to be noise; slices 3 and 4 measure it.

## Alternatives & decisions

- **libghostty-vt callback** (`GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS`): rejected, it attaches
  to a standalone `GhosttyTerminal`, and `ghostty.h` has no accessor to a surface's terminal.
- **Pure Swift or a second PTY parser**: rejected, the OSC is consumed by the parser and
  never reaches screen text; a second parser duplicates ownership and backpressure.
- **Wait for upstream**: rejected, there is no plan or timeline; the fork struct mirrors the
  libghostty-vt `GhosttyTerminalProgramStatus` field set and enum names so an eventual
  upstream action is a rename.
- **By-value C struct in the action union**: rejected, it would grow `ghostty_action_u`
  past the size upstream asserts; the report is passed by pointer like other owned payloads.
- **Opt-in query reply**: rejected for the fork, Prowl always consumes reports; the vt layer's
  "only answer when a handler is set" rule is satisfied by construction.
- **OSC as public signal / identity**: rejected (see Non-goals); the research note's boundary
  "state yes, identity and delivery no" is kept as the contract.
- **Drop the store on a process generation change** (first draft): replaced by the
  arrival-time fence. The generation is not known when a report arrives, and records belong
  to the terminal; comparing `arrivedAt` with the process start time is exact and needs no
  extra bookkeeping.
- **Child `working` keeps the pane Working / sets outstanding work** (first draft):
  rejected on 2026-10-10. onevcat wants background work to leave the pane Idle and never
  block workflows; the legacy providers are aligned later (#891).
- **Screen blocker tie-break under OSC authority**: rejected. The screen is not read while a
  verified root is live; an unreported local menu is a producer gap to report upstream, not
  something to patch with string rules. Dispatch keeps its own input-area check.
- **Version gating** (`Claude ≥ 2.1.295`, `Pi ≥ 1.1.0` in the first draft): replaced by
  "an eligible root exists". Older producers never answer the query, so the fallback is the
  default and the minimum versions are documentation only.
- **User setting to disable OSC detection**: rejected by onevcat; a verified producer is
  trusted unconditionally and the producer's own variables are the escape hatch.
- **Fully event-driven presence** (fork exposes OSC 133 C so a pane with shell integration
  stops polling entirely): deferred. The 2 s delegated probe is expected to be noise; the
  fork patch is justified only if `make measure-cpu` says otherwise.
- **Stacked PRs for slices 3 and 4**: rejected; their acceptance must run on merged slice 2
  code, so they branch from `main` after it lands.
- **`done`/`error` records kept until `markAgentSeen`** (first draft): dropped. Store
  lifetime follows the protocol; the seen flag is a presentation concern of the pane.
- **Drop `working`/`blocked` on every `COMMAND_FINISHED`** (first draft): replaced by
  "release first, then drop". A 133 D from a nested interactive shell would otherwise erase a
  live agent's records with no way to get them back (no heartbeat), and the probe is the
  only judge of whether the command that finished was the agent.
- **Drop the store on undo-close** (first draft): replaced by keeping it fed while retained.
  The process keeps running during retention, and an unchanged `blocked` is never re-sent.
- **Child `blocked` without an idle veto** (first draft): the child's prompt now sets
  `hasOutstandingWork`, otherwise a parent `turn-ended` could release a wait while the
  prompt is open. Child `working` still sets nothing (decision A).
- **`.suspended` on entering delegated** (review round 1 fix): replaced by a dedicated
  transition. Suspension preserves the native snapshot and the completed-frame fence by
  design and sets `hasLogProvider`; reusing it would publish a pre-OSC Idle after a
  withdrawal with a failed first read and would rename Pi's fallback reason.
- **Readiness from the reducer's entry** (first draft, implicit): the condition snapshots
  read the live terminal decision instead. Emission dedup intentionally hides reason-only
  changes from the reducer, and the OSC idle exception is a reason.
- **Root-only time fence** (first draft): every record is fenced by arrival time, so a
  predecessor's child cannot survive a root replacement.
- **Store-wide `commandFinished()`** (review round 1 fix): scoped to the revision captured
  at the D. The successor branch deliberately allows a new launch to be reporting before the
  probe confirms it, and a store-wide drop would delete that launch's live root with no way
  to get it back.
- **One generation for binding and ownership** (review round 1 fix): split into the engine
  generation (OSC/provider binding, may change under the same launch) and the owner
  generation (launch profile and hook epoch, `launchProcessID`). The existing
  engine-child retention contract (`retainedLaunchProcessID`) and the launcher-based hook
  epoch already draw this line.
- **Apply late provider samples under OSC authority** (review round 1 fix): discarded by
  authority epoch instead, because a late pre-authority snapshot recreates the facts the
  transition retired.
- **Readiness from the published pane decision** (review round 1 fix): the coordinator's
  current decision is used instead, because publication is intentionally held back during
  a withdrawal while the machine has already dropped the `osc.*` reason.

## Amendments

- Updated 2026-10-10: slice 1 landed (fork action, Swift copy, harness, baselines) — see [002-fork-action-and-bridge.md](002-fork-action-and-bridge.md)
- Updated 2026-10-10: slices 2–4 redesigned in place after reviewing the detection layer on `main` (the entry has no action log yet, so the plan was corrected rather than amended). Corrections: lifecycle inputs are `COMMAND_FINISHED` and the agent's own `clear` (not `SHOW_CHILD_EXITED`, which only fires for undo-close surfaces); the generation-change store reset became the arrival-time fence; store lifetime no longer tied to `markAgentSeen`; a push path replaces "the coordinator pulls on the next poll"; version gates replaced by root eligibility; the pane follows the root record only; a delegated schedule, command-finished release, and the `.verified`/`.unverified` support table were added; no user setting. Decisions recorded under Alternatives.
- Updated 2026-10-10: design review round 1 (11 findings, all accepted) folded in: push/poll
  commit contract, binding refresh for OSC-capable agents, cache-bypassing wake and
  release-before-drop on `COMMAND_FINISHED`, child-blocked idle veto, provider suspension on
  entering delegated and no publish on withdrawal, store kept fed during undo-close, `prowl
  agents` precedence and the `agents read` exception, `osc.error` as idle evidence, slice 2
  regression gates, resolver cache wording, 013 contracts in the docs list.
- Updated 2026-10-10: design review round 2 (5 new findings, all accepted; 6 partial
  resolutions closed): a dedicated authority transition instead of `.suspended`, condition
  snapshots read the live decision, per-record arrival-time fence, three outcomes of the
  post-D fresh sample including successor retirement, retained-surface D applied directly,
  and the protocol summary no longer claims a mandatory query handshake.
- Updated 2026-10-10: design review round 3 (1 new finding, 3 partials closed): the
  command-finished cleanup is scoped to the revision captured at the D; owner and engine
  generations are separate keys in the post-D table (engine-child replacement rebinds, a new
  owner retires the launch context); late provider samples from an earlier authority epoch
  are discarded; condition snapshots read the coordinator's current decision so a withdrawn
  `osc.*` reason is never readiness evidence.
- Updated 2026-10-10: slice 2 implemented (record store, state machine event and authority
  transition, coordinator push path and authority epoch, delegated schedule, interruptible
  wake, command-finished release, undo-close feed, readiness through the coordinator's
  current decision, CLI surface; every agent `.unverified`) — see
  [003-generic-provider.md](003-generic-provider.md), which also lists the small
  deviations (shadow lines on every transition, unmapped-app line from the poll,
  revision bump on `commandFinished`, last scan text for the delegated resolver, owner
  generation keyed by `launchProcessID` alone).
- Updated 2026-10-11: slice 4 implemented (Pi `.verified`; the acceptance list replayed in an isolated Debug instance with Pi 1.1.0, CPU compared with the slice 2 baseline) — see [005-pi-verified.md](005-pi-verified.md)
