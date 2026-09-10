> **Current naming (2026-09-07):** [019](019-workflow-naming.md) and the
> [DSL specification](dsl-spec.md) define the current authoring contract. Earlier
> slice descriptions below record design history; loose YAML, repeat/until, and
> dedicated handoff actions are superseded. D3 remains future work.

# 063 — Agent Workflows: Plan

| | |
| --- | --- |
| **Status** | In progress — R1 shipped in v2026.8.29; R2a shipped in v2026.8.31: B1 (#740, [006](006-b1-definitions.md)), #733 (#741), #726 T0 (#739), B2 (#743, [007](007-b2-runner-core.md)), B3 (#744, [008](008-b3-runner-wiring.md)), and C1 (#747, [010](010-c1-workflow-status-center.md)); R2b in progress: C2 (#752, [011](011-c2-start-sheet.md)) and D1 (#754/#761, [013](013-d1-workflows-settings.md)) merged; D1's post-merge Settings UI refinement merged in #763 ([014](014-workflow-settings-ui-refinement.md)); #726 T1a inventory/configuration preflight is implemented in [064.016](../064-agent-completion-signals/016-t1-contract-test-plan.md); eight-runtime headless checks verified; T1 verification and scoped publication merged (#769); D3 handoff and first built-in E2E next for R2b; D2 deferred to R3 |
| **Anchor date** | 2026-08-21 |
| **Primary PRs** | R1: #709 (C0), #710 (A1), #713 (A1b), #714 (A2) — shipped in v2026.8.29; R2a: #740 (B1), #743 (B2, [007](007-b2-runner-core.md)); #744 (B3, [008](008-b3-runner-wiring.md)); #747 (C1, [010](010-c1-workflow-status-center.md)); R2b: #752 (C2, [011](011-c2-start-sheet.md)), #754 (D1 skill), #761 (D1 rest, [013](013-d1-workflows-settings.md)), D1 Settings UI refinement (#763, [014](014-workflow-settings-ui-refinement.md)); D2–D3 TBD |
| **Related** | [047 cross-agent-handoff](../047-cross-agent-handoff/000-plan.md), [049 agents-toolbar-entry](../049-agents-toolbar-entry/000-plan.md), [053 agent-profiles](../053-agent-profiles/000-plan.md), [055 agent-profile-runtimes](../055-agent-profile-runtimes/000-plan.md), [059 agent-transcript-snapshots](../059-agent-transcript-snapshots/000-plan.md), [060 cli-targeting-and-contract-governance](../060-prowl-cli-targeting-and-contract-governance/000-plan.md), [061 native-toolbar-controls](../061-native-toolbar-controls/toolbar-controls.md), [064 agent-completion-signals](../064-agent-completion-signals/000-plan.md) (signal bus, `agents signal` / `agents wait`), [#699 `prowl create pane`](https://github.com/onevcat/Prowl/issues/699), [PR #651 (direction reference, not merged)](https://github.com/onevcat/Prowl/pull/651), [DSL spec (living)](dsl-spec.md), [release plan (living)](release-plan.md), `docs/components/handoff.md`, `docs/components/agent-profiles.md`, `docs/components/cli.md` |

> Current implementation scope: [015](015-action-bundles-and-control-flow.md) and
> [017](017-action-bundle-implementation.md) define the authorized action-bundle work.
> Workflows remain formally unreleased; `.pwlworkflow` is the v1 format directly. The living
> DSL specification supersedes the old loose-file/repeat/handoff replacement sections below.
> Legacy `prowl handoff` stays intact; this implementation enables workflow UI by default
> and retains `PROWL_WORKFLOW_UI=0` as an explicit override.


> Historical intervening-release scope update: [016 — workflow UI gate](016-workflow-ui-release-gate.md). The next release ships Island/detection improvements with workflow UI hidden by default; action bundles, handoff migration, and review workflows are deferred.

## Background

Prowl already runs several coding agents side by side, identifies them per pane, launches
them through Agent Profiles (053/055), reads their trustworthy results (059), and hands a
task from one agent to another (047/049). The handoff that exists today is valuable but
structurally stuck:

- Its flow is a fixed state machine (`HandoffStage` `requesting → finishing`,
  `HandoffHudPhase` choose/run/finish in
  `supacode/Features/HandoffHud/Reducer/HandoffHudFeature.swift`); target list, briefing
  sections, kickoff prompt, and injection text are literals
  (`supacode/CLIService/Shared/HandoffAgentSupport.swift`,
  `supacode/CLIService/HandoffCommandHandler.swift`,
  `supacode/Domain/Handoff/HandoffInjection.swift`).
- Its two launch paths (CLI → `WorktreeTerminalState.createTab(initialInput:)`, HUD
  fallback → `TerminalClient.Command.createTabWithInput`) bypass Agent Profiles entirely:
  `AgentStartRequest.dedicatedHome` is always nil, and model/effort/extra arguments/env
  never reach the receiver. PR #651 tried to thread a profile UUID through that fixed flow;
  the direction (profile-bound receiver, freeze before commit, one shared launch boundary
  returning exact pane identity, no secrets in artifacts) is right, the shape is not.
- The orchestration onevcat actually runs day to day — agent 1 opens a split, launches
  agent 2 with a prompt, monitors it, reads its result, fixes, asks for another round until
  clean — lives only in ad-hoc `prowl` CLI usage and cannot be reproduced or shared.

The foundations that make a general solution possible are all on `main` now: a pure
profile launch planner with a typed `.prompt` start intent
(`supacode/Domain/AgentProfile/AgentProfileLaunchPlan.swift`,
`supacode/Domain/AgentRuntime/AgentRuntimeAdapter.swift`), text injection into a live pane
(`TerminalClient.sendTextToSurface`), caller-pane identity for CLI calls
(`supacode/CLIService/CLICommandContext.swift`), one-shot request ownership
(`supacode/Domain/Handoff/HandoffRequestRegistry.swift`), briefing validation
(`HandoffStore.validatedBriefing`), the agent status event stream, a toolbar status slot
(`supacode/Features/Repositories/Views/ToolbarStatusView.swift`), and the four-layer CLI
contract governance of 060.

## Goals

- Replace the hard-coded handoff flow with **Agent Workflows**: data-driven, multi-agent
  orchestrations declared in a YAML DSL (`prowl.workflow/v1`, normative text in
  [dsl-spec.md](dsl-spec.md)) and executed by a reducer-owned runner inside Prowl.
- Make the orchestration onevcat runs by hand (launch reviewer in a split → review →
  fix → re-review until clean) expressible, reproducible, and shareable as a file.
- Bind workflow roles to Agent Profiles **without** coupling the file to a machine: a
  workflow declares abstract role requirements; the role → profile binding is local,
  remembered, and overridable.
- Surface runs in the toolbar's central status slot (`Adversarial Review · 3/6 · Round 2:
  reviewer re-checking`) with a popover for steps, role panes, and controls; keep every
  existing entry point (Agents capsule popover, Command Palette, Active Agents context menu).
- Let agents participate through the `prowl` CLI only (`prowl workflow deliver`), so every
  recognized runtime can play any interactive role, and keep the pure-CLI route (an agent
  orchestrating others by hand) first-class by shipping the missing primitives.
- Ship two built-in workflows — `prowl.handoff` (replacing the current implementation) and
  `prowl.adversarial-review` — plus bundled skills, and a documented path for users (and
  their agents) to author custom workflows.

### Non-goals

- A visual workflow editor. Authoring is YAML + `prowl workflow validate` + agent
  assistance (bundled docs/skill).
- General control flow (conditions, parallel fan-out, nesting) in V1. V1 control flow is
  sequential steps plus one bounded `repeat … until <verdict>` construct.
- Executing shell commands, writing arbitrary files, git/network operations, sending
  keystrokes, or answering permission prompts from a workflow.
- Launching agents outside Agent Profiles. `suggest` may match or create a profile; it
  never bypasses one.
- Cross-worktree roles (all roles of a run live in the source worktree) and resuming runs
  across app restarts — both V2 candidates.
- Analytics for workflows; workflow ids, role bindings, and run content never enter
  PostHog/Sentry.

## Design / Approach

### Concepts

| Term | Meaning |
| --- | --- |
| Workflow | A `prowl.workflow/v1` YAML document: id, inputs, roles, steps. Sources: bundle (`prowl.*` ids), user (`~/.prowl/workflows/*.yaml`), repo (`<root>/.prowl/workflows/*.yaml`). |
| Role | A participant: `source: current` (the pane the run was started from; it must host a detected agent only if the runner will actually deliver a `message` to it — steps skipped at start via `--skip` / the start sheet do not count — so a bare shell can still be the source of a context-only handoff), `pick` (an existing detected agent pane in the same worktree, chosen at start), or `launch` (a new agent Prowl starts). V1 launch roles are interactive (TUI in a tab/split); `kind: headless` is reserved for V2 (see Alternatives). |
| Binding | Role → concrete Agent Profile (or, for `pick`, an existing pane), resolved at start and frozen into the run. |
| Step | One verb: `message` (say something to a live role), `launch` (start a launch role), `action` (built-in Swift action), `notify`, `close`; plus `repeat` blocks. Each step has a `title` for the status slot and an optional `expect`. |
| Expect | Only on `message` / `launch` steps: what must happen before the run advances — a named `delivery` submitted by the step's target role via the generated `prowl workflow deliver` command, optional `sections`/`format` validation, optional `verdicts` list (safe slugs), optional `timeout` / `on_timeout`. |
| Run | One execution: state snapshot + artifacts under `<root>/.prowl/workflow-runs/<run-id>/`. |

### Execution model: Prowl runs, agents participate

The runner is a TCA feature (`WorkflowRunsFeature`, reducer-owned like the handoff HUD was)
that advances one step at a time through existing terminal boundaries:

- `launch` → the shared profile launch boundary (`launchAgentProfile` extended with
  `AgentStartIntent.prompt`, placement override, anchor surface, background, returning the
  created tab/surface identity — the #651 "shared terminal boundary" done properly).
- `message` → `TerminalClient.sendTextToSurface` into the role's pane, gated by detection.
  Injection is synchronous (insert + submit, no Prowl-side queue); a `working` agent
  receives the line in its own input queue (Claude Code and Codex queue typed input), and
  the panel says so. A `message` step advances only after a *successful* injection: if
  the role is `blocked`, its surface is gone, or injection fails, the step stays active in
  `needsAttention` (Retry / Skip / Cancel) — it never advances on a line that was not
  delivered. At most one pending injection exists per role; Cancel / Skip / Relaunch drop
  it.
- `expect` → a `WorkflowRequestRegistry` entry (generalizing `HandoffRequestRegistry`)
  keyed by an **opaque per-activation delivery token** (a UUID, hence shell-safe). Lifecycle
  (normative in the DSL spec §5): every `message`/`launch` execution mints a run-global
  invocation ordinal on entry; when the step has an `expect`, that invocation is an
  activation `(run, step, ordinal, role)` whose token is minted *before* the line is
  rendered and injected (the injected text carries it); every `repeat` iteration and every
  Retry/Relaunch is a new invocation. One delivery per activation. The token is placed in
  the generated completion command
  (`PROWL_WORKFLOW_TOKEN=<token> prowl workflow deliver -`, the same env-prefix technique as
  today's `PROWL_HANDOFF_REQUEST_ID`; `--token <token>` is the explicit form). The entry
  is claimable exactly once; a `deliver` that arrives without the token, with a revoked token
  (Skip / Cancel / Relaunch revoke), or from a pane other than the role's is rejected — so
  a delayed or duplicated `deliver` from a pane that has since moved on to another step can
  never be misattributed. Tokens are never written into YAML, and the **generated
  command is the only spelling agents ever see**: one completion-command renderer produces
  the initial hint, every nudge, and every re-delivery (token always present; for verdict
  steps one complete executable command per allowed value on every transport — typed
  line, scoped-read response, and `prowl workflow status` — never a placeholder);
  built-ins and examples say
  "finish with the generated completion command"; the validator warns when
  `prompt` spells out `prowl workflow deliver`. `expect` is valid only on
  `message` and `launch` (their target role delivers); native actions return typed
  outputs synchronously. Skipping a step whose expected output is referenced by a later
  template ends the run as `skipped` (the panel says which step depends on it) — V1 has
  no optional template values, so the alternative would be an unrenderable step. The one
  tolerated consumer is a `with` input declared optional by the action's schema: the key is
  simply absent, which is how skipping the brief turns `prowl.handoff` into a context-only
  transition (the old HUD's "Context Only" fallback, now a generic rule).
- `action` → native or bundle-local actions (`builtin:collect-worktree-context`, `local:<verb-object>`).
- `notify`/`close` → the existing bell pipeline and protected close path.

**Data channels.** Both `message` and `launch` author their task as `prompt`.
The runner saves a task-only body for each invocation. After rendering, short safe
messages are typed directly; multiline or longer messages use pane-scoped read.
Launch uses its kickoff carrier. The DSL spec §§4/5/8 define transport and storage.
Completion guidance is generated separately from the saved task body.
Outbound is `prowl workflow deliver [--verdict v] -` (stdin): the caller pane identifies the
run/role, the delivery token identifies the awaited step — the YAML itself carries nothing
machine-specific. Transcript observation (`agents read`) and headless adapter capture are
V2 channels (see Alternatives).

**Event topology.** `WorktreeTerminalManager.eventStream()` is single-consumer (a new
subscription finishes the previous stream) and `AppFeature` is its only subscriber. The
runner therefore lives as a child reducer of `AppFeature`, which forwards
`agentEntryChanged` / `agentEntryRemoved` / `taskStatusChanged` to it; nothing else
subscribes to `TerminalClient.events()`. `prowl agents wait` (and any other CLI observer)
uses a per-surface multicast observer on `WorktreeTerminalManager`, independent of the
reducer stream and typed so that disappearance is observable. The observer is delivered
by 064-S1 in release R1 (it was first specified here) and consumed by this entry's B3:

```swift
struct AgentObservationSnapshot: Sendable {
  let agent: ActiveAgentEntry?
  let latestSignal: AgentSignal?
  let revision: UInt64
}
enum ObservedAgentState: Sendable {
  case snapshot(AgentObservationSnapshot) // always first, including a normal shell
  case changed(ActiveAgentEntry)
  case removed                            // published agent gone; pane may remain alive
  case signal(AgentSignal)
  case surfaceClosed                      // pane closed; stream finishes after this
}
func observeAgentState(surfaceID: UUID) -> AsyncThrowingStream<ObservedAgentState, Error>
```

Each subscriber gets its own bounded buffer. Registration and snapshot capture happen in
one main-actor step so no change can fall between them, the snapshot precedes live events,
cancellation removes the subscriber, and `surfaceClosed` terminates the stream. A slow
subscriber receives an explicit `bufferOverflow` error instead of silently losing signal or
lifecycle evidence; S2's `agents wait` re-subscribes and evaluates the newer snapshot before
surfacing an error. `agents wait` maps `removed` /
`surfaceClosed` to a terminal `AGENT_GONE` error (not to `deliver`) unless `--until exit`
was requested. The runner's watchdog likewise reads the role's *current* state first and
schedules cancellable grace deadlines on the injected clock; it never relies on a later
event alone.

**Data bus.** `<root>/.prowl/workflow-runs/<run-id>/` holds `run.json`, `log.md`,
`prompts/` and `deliveries/` (both versioned by the run-global invocation ordinal, latest
output view replaced atomically — layout normative in the DSL spec §8), `skills/`
(materialized from the embedded skill registry only — `skill:` ids are safe slugs that must
resolve to a bundled skill).
Distribution is "the next instruction names the path"; Prowl never inlines one agent's
output into another agent's input box, and every rendered line is re-validated as a
single terminal line before injection (template values such as inputs or paths cannot
smuggle a newline past the boundary). Outputs are agent-authored
content persisted at the agent's request (default cap 1 MiB, hard max 4 MiB,
`OUTPUT_TOO_LARGE` otherwise; same bounds as `agents read`), kept until the user deletes
the run folder (retention policy is a V2 item, as for `.prowl/handoff/archive`). Step ids
and output names are restricted to safe slugs because they become path components; run
directories are created with canonical containment checks under
`<root>/.prowl/workflow-runs/` (no symlink leaf), mirroring
`AgentProfileHomeProvisioner`. Repo-scoped workflow files are untrusted input and go
through the same validator.

**Binding resolution** (per `launch` role, at start): remembered binding → enabled
profile matching `suggest` exactly → 053's Recommended filtered by `agents` → ask. The
memory key is `(definition scope, workflow id, role, role-requirements digest)` where
scope is `bundle`, `user`, or `repo:<repository id>` and the digest covers the role's
requirement block (`source`, `kind`, `agents`, `suggest`) — so a repo workflow that
shadows a same-id user workflow, the same id in two repositories, two worktrees of one
repository carrying divergent definitions, or an edited role in a same-id file never
reuses a binding made for different requirements, while prompt-only edits keep it. Every
candidate (remembered
or `--role` override included) is re-validated before use: still exists, enabled,
satisfies `agents`, and its adapter supports the intent the role needs (seeded prompt);
otherwise resolution falls through to the next tier. The Start sheet shows a picker per
role with "Create profile from suggestion…" when nothing matches; `bind: auto` skips the
sheet when resolution is unambiguous. CLI overrides are source-specific (`--role
<launch-role>=<profile name|uuid|auto>`, `--role <pick-role>=<pN|pane UUID>`; see the DSL
spec §9).

**Waiting is state-driven, not wall-clock.** `expect` has no default timeout: a working
agent is never interrupted however long it takes. Instead the runner's watchdog consumes
the existing detection events (`agentEntryChanged` / `agentEntryRemoved`, produced by the
periodic detection schedule) with grace periods, because detection is heuristic and a
wrong guess must be harmless: a role `blocked` for ≥ `blocked_grace` (default 30 s) →
`needsAttention` (Focus pane / Cancel); a role `idle`/`done` for ≥ `idle_grace` (default
3 min) without `deliver` → Prowl **auto-nudges once** (types `[Prowl] When your work for this
step is fully complete, finish with: <the activation's rendered completion command — token
and, for verdict steps, one executable command per value>`, harmless if the agent was in
fact still working — the runtime just queues the line) and escalates to
`needsAttention` (Nudge again / Keep
waiting / Skip / Cancel) only after another `idle_grace`; the role's agent process
disappearing → `needsAttention` (Relaunch role / Skip / Cancel). `needsAttention` is a UI
state, never a deadline: a late `deliver` is still accepted. Grace values are global settings
(Settings › Workflows); an author may still add an explicit `expect.timeout` with
`on_timeout: attention|skip|cancel` for hard caps.

**Invariants** (carried from 047/053/#651): a pane belongs to at most one run at a time
(`PANE_BUSY`); injection only into panes bound to the run; roles and their plans are frozen
at start; `deliver` is accepted only from the bound pane with a live delivery token, unless an
explicit `--run/--step` (manual, logged) or `--force` is given; attention states wait for a
person, they never discard delivered outputs; cancel never closes a pane; Prowl-originated
metadata (requests, payloads, `run.json`, logs) never carries extra arguments, environment
values, home paths, or credentials — agent-authored outputs are the agents'
responsibility and stay under the self-ignored run directory; the runner performs no git
writes.

### UI

- **Status center**: `ToolbarStatusView` gains a `workflowRun` state with priority
  toast > active run of the selected worktree > PR > palette hint. The slot itself stays
  minimal — an animated running indicator plus the current step's `title` (orange
  attention glyph in `needsAttention`; a count badge when the worktree has several active
  runs) — because the principal item cannot carry more. Everything else lives in the
  hover-open/pin-on-click popover (same pattern as `PullRequestChecksPopoverButton` /
  `ToolbarNotificationsPopoverButton`): header (workflow, worktree, elapsed, state), role
  chips (profile icon + name + `pN`, click → focus), a height-capped **scrolling** step
  list (authors may declare any number of steps; `repeat` iterations grouped as `Round
  k/max`; the active step rendered as title + dimmed body with the full instruction
  text), the attention block with its actions (Focus pane / Nudge / Keep waiting / Skip /
  Relaunch / Cancel as applicable), and Cancel / Reveal run folder / Open log. Completion
  reuses the `success` toast. Notifications for attention and completion go through the
  bell with click-to-focus, silenced while the user watches that worktree. Detailed
  visual design is deferred to C1 (build-time, 061 visual verification). Follows 061: the
  principal slot stays a display item; no new glass exceptions.
- **Start sheet**: the centered HUD card pattern of the handoff HUD (keyboard-capturing,
  not window-modal) becomes `WorkflowStartOverlay`: title/description → "You: <agent> in
  pN" for the `current` role → one picker per `launch` role (filtered by `agents`,
  pre-selected, unavailable rows dimmed with reason, "Create from suggestion…" when
  nothing matches) → one pane picker per `pick` role (detected agents excluding panes
  already in a run and the current pane) → inputs → "Don't ask again for this workflow"
  (when `bind: ask`) → Cancel / Run. A CLI-not-installed banner with an inline Install
  action disables Run. `bind: auto` with unambiguous bindings and defaulted inputs skips
  the sheet.
- **Entry points**: Agents capsule popover gains a Workflows section (`Hand Off…` stays
  its first row); Command Palette `Run Workflow: <name>`; Active Agents row context menu
  `Run Workflow ▸` and an `in <workflow> · <role>` subtitle on rows that belong to a run.
  The start sheet replaces the handoff HUD's choose stage; the HUD's run/finish stages are
  subsumed by the status center (049's deferred PR2).
- **Settings information architecture**: the Agents star feature becomes a sidebar
  *group* (`Section("Agents")`, same native pattern as the Repositories group in
  `supacode/Features/Settings/Views/SettingsView.swift`) with three pages — **Profiles**
  (today's Agents page, renamed), **Workflows** (new), **Command Line Tool** (the `prowl`
  install/status/socket/"Ask your agent" entry, moved out of Advanced because agents are
  its primary consumer). Workflows ↔ Profiles stay linked by cross-reference, not by
  merging: each workflow row shows its role → profile bindings (editable, jump to
  Profiles); a CLI dependency banner with an inline Install action sits atop Workflows and
  the runner preflights CLI installation before a run. The group ships in R1 with
  Profiles + Command Line Tool (C0); the Workflows page arrives with D1 in R2. Workflows
  page contents: Built-in
  / User / Repo lists, enable toggle, per-workflow "ask for bindings" override, validation
  status with YAML line errors, Reveal, New Workflow… (template file), Ask your agent to
  write one (prompt pointing at bundled `docs/` + `skills/`).
- **CLI reachability status** (deferred from C0 #709, see
  [002-settings-agents-group.md](002-settings-agents-group.md); lands with D1's preflight):
  the Command Line Tool page shows only `ProwlSocket.defaultPath` — a computed value that
  honours `PROWL_CLI_SOCKET` — not whether Prowl is actually listening there. Today
  `CLISocketServer.start()` (`supacode/CLIService/CLISocketServer.swift`) throws
  `CLIServiceError` (`socketAlreadyOwned` when another Prowl instance holds the lock,
  `lockFailed`, `permissionFailed`, `bindFailed`, `listenFailed`, `socketPathTooLong`,
  `socketCreationFailed`), `supacodeApp.makeCLISocketServer` only logs the failure, and
  `isRunning` is private — nothing downstream observes it, so a user whose `prowl` cannot
  connect sees a healthy-looking Settings page. D1's CLI dependency banner and the runner
  preflight need the same signal, so build it once: a `CLIServiceStatus`
  (`listening(path)` / `failed(CLIServiceError, path)` / `stopped`) published by the server
  through a small dependency client or the existing `TerminalClient`-style event stream (not
  NSNotification), read by `SettingsFeature` for a status row under Command Line Tool ›
  Connection (tri-state indicator like the install row; failure text names the reason and,
  for `socketAlreadyOwned`, the competing instance) and by the workflow preflight
  (`install` / `socket` blockers before a run). Tests: reducer tests with a stubbed status,
  plus a `CLISocketServer` test that `start()` on an already-owned path surfaces
  `socketAlreadyOwned`.

### CLI (per 060's four-layer rule)

`prowl workflow list | run <id> [source] [--role r=…] [--input k=v] [--skip <step>] | status
[run] | deliver [-|--file] [--verdict v] [--token t] [--run --step] [--force] | cancel <run> |
validate <file> | schema` — `[source]` is 060's `GenericTarget` (`pN`, `tN`, UUID,
worktree ref); omitted,
the source is the caller pane when the workflow has a `current` role, and a worktree
reference is required otherwise; `--role` is source-specific (`launch` role →
`<profile name|uuid|auto>`, `pick` role → `<pN|pane UUID>` in the source worktree,
`current` → none); `prowl profiles list` (read-only, for CLI-driven orchestration);
prerequisites
`prowl create pane <pane> --direction … [--profile <name|uuid> --prompt -]` (#699 extended);
`prowl agents signal` / `prowl agents wait` (deterministic completion signals for the
CLI-driven route) are specified and delivered by
[064 agent-completion-signals](../064-agent-completion-signals/000-plan.md), which consumes
this entry's observer and launch boundary. `prowl handoff to|save` are **retired**: one
release of non-executing stubs that answer `HANDOFF_RETIRED` with the exact `prowl workflow
run …` replacement, then removal (see Built-ins).

### Built-ins and distribution

> The design below predates action bundles and is historical. The current distribution
> unit is a `.pwlworkflow` directory. D3 will compose general-purpose actions and agent
> steps; dedicated handoff actions are no longer planned. See [015](015-action-bundles-and-control-flow.md)
> and [019](019-workflow-naming.md) before implementing a built-in.


- `Resources/workflows/*.yaml` are embedded like `docs/` (`Makefile` `embed-docs` pattern);
  `Resources/skills/` and the bundled-skill registry are owned by
  [065-bundled-agent-skills](../065-bundled-agent-skills/000-plan.md) (`embed-skills`,
  `ProwlSkills`); `skill:` references resolve through that registry and are materialized
  into the run directory so sandboxed agents can read them.
- `prowl.adversarial-review`: interactive reviewer in a right split (transparency and user
  trust outweigh headless precision), `repeat … until deliveries.findings.verdict == clean`
  with `max_rounds`.
- `prowl.handoff`: `message source` (brief) → `action handoff.transition` (keeps the
  `.prowl/handoff/` artifact contract; outputs `kickoff_prompt`, `artifact_path`,
  `has_briefing`) → `launch receiver` (background tab, prompt from the action output) →
  notify. The receiver role carries **no `agents:` restriction**: any runtime whose adapter
  supports a seeded prompt is admissible (055 verified all but Amp, which the adapter
  rejects itself); the 047-era claude/codex-only admission is retired. Skipping the brief
  (start sheet, `--skip brief`, or the panel) gives the context-only transition through
  the Skip rule — the replacement for the old HUD's "Context Only". A second small
  built-in, `prowl.handoff-checkpoint` (brief → `handoff.checkpoint`), covers "save
  progress for a later successor". **The legacy `prowl handoff to|save` commands are
  retired, not adapted** (decision 2026-08-22): for one release they are non-executing
  stubs returning `HANDOFF_RETIRED` with the copy-pasteable replacement
  (`prowl workflow run prowl.handoff [--role receiver=…] [--skip brief]` /
  `prowl workflow run prowl.handoff-checkpoint`, briefing delivered with the returned
  `prowl workflow deliver -`); afterwards the commands, `HandoffCommandHandler`,
  `HandoffHudFeature`, `HandoffRequestRegistry`, and the `prowl.cli.handoff.v2` contract
  are deleted. A self-initiated run returns the first step's instruction and completion
  command in its response instead of typing them into the caller's own pane, so an agent's
  self-handoff stays two commands.
- `skills/prowl-workflow/SKILL.md`: how to author and run workflows; `prowl workflow
  schema` prints the machine-readable reference.

### Prerequisite interfaces (A1/A2) and test strategy

Shapes are intentionally close to what exists so the runner and the CLI share one boundary.

- **Anchored split primitive** (`supacode/Features/Terminal/Models/WorktreeTerminalState+Surfaces.swift`):
  `createSplit(of anchorSurfaceID: UUID, direction:, initialInput:, additionalEnvironment:,
  focusing:) -> Result<UUID, SplitCreationError>` — the current
  `createSplitOnFocusedSurface` becomes a wrapper that resolves the focused surface and
  delegates. No focus-then-split (per #699).
- **Launch boundary** (`WorktreeTerminalState.swift`, `TerminalClient.swift`,
  `AgentProfileLaunchPlan.swift`): `AgentProfileLaunchPlanner.plan(for:intent:homeBaseDirectory:)`
  gains the intent (default `.interactive`; stays pure); a new
  `AgentProfileLaunchRequest { plan, placement: .tab(background:) | .split(anchor: UUID?,
  direction:, background:), workingDirectoryOverride: URL?, title: String? }`;
  `WorktreeTerminalState.launchAgentProfile(_ request) -> Result<LaunchedSurface {tabID,
  surfaceID}, AgentProfileLaunchError>`; a synchronous result-returning `TerminalClient`
  closure (same style as `createTabInDirectory`), with the existing fire-and-forget
  `Command.launchAgentProfile(worktree, plan:)` kept as a wrapper that still emits
  `agentProfileLaunched` / `agentProfileLaunchFailed` for the menu/palette path.
- **CLI additions**: `CreateInput` gains `direction` and an optional `launch { profile:
  <name|uuid>, prompt: String? }`; `LifecycleCommandHandler` gains a `createPane` provider
  and a profile-launch provider; profile lookup is UUID first, then exact unique name
  (`PROFILE_NOT_FOUND` / `PROFILE_NOT_UNIQUE`); `prowl.cli.create.v1` is extended
  additively (`resource: pane`, `anchor`, `direction`, optional `launch {profile_id,
  profile_name, agent}`). `prowl profiles list` is a read-only snapshot of enabled/disabled
  profiles with availability (`prowl.cli.profiles.v1`). `prowl agents wait` is owned by
  [064](../064-agent-completion-signals/000-plan.md): it consumes the typed
  `ObservedAgentState` observer described above (snapshot first; `removed` /
  `surfaceClosed` → `AGENT_GONE`) and adds the signal bus, `source`/`confidence`, and
  launch-scoped hooks on top of this entry's launch boundary.
- **Tests**: terminal-layer coverage extends `supacodeTests/WorktreeTerminalStateAgentProfileTests.swift`
  (anchored split, placement override, background tab, returned identity, provisioning
  failure); planner intent rendering per adapter in `supacodeTests/AgentProfileTests.swift`
  / `AgentRuntimeAdapterTests.swift` (Amp rejects seeded prompts); handler coverage in
  `supacodeTests/CLILifecycleCommandHandlerTests.swift` and new handlers for `profiles
  list` / `agents wait` (TestClock for the timeout); parser tests beside
  `ProwlCLITests/AgentsCommandParsingTests.swift`; socket round trips plus schema validation
  in `ProwlCLITests/ProwlCLIIntegrationTests.swift`; contracts (`create.md`,
  `targeting.md`, new `profiles.md`, `agents-wait.md`), `docs/components/cli.md`, and the
  `prowl-cli` skill updated in the same PRs; the runner's own tests use fake
  `TerminalClient` closures, a temp run directory, and `TestClock` for the watchdog.

### Delivery slicing

This section defines **what** each slice contains. **When** it ships and in what order —
including the interleaving with 064's signal slices — is owned by the living
[release-plan.md](release-plan.md) (R1 CLI primitives + signals, R2a workflow engine + CLI,
R2b workflow GUI + handoff migration, R3 adversarial review; latest ordering decision
2026-09-05). Only two couplings cross the two
entries: 064-S1 delivers the `ObservedAgentState` observer that B3 consumes, and 064-S3
attaches hooks through A2's launch boundary.

| Slice | Track | Depends | Contents / expectation |
| --- | --- | --- | --- |
| **C0** | C | — | Settings IA: `Section("Agents")` with **Profiles** (today's Agents page, renamed) and **Command Line Tool** (moved from Advanced); the Workflows page comes with D1. Independent, small; decides where everything lands. |
| **A1** | A | 060 | `prowl create pane` (#699) + target-surface split primitive returning the surface id; CLI four layers. Foundation for every `launch` into a split. |
| **A1b** | A | A1 | `PROWL_PANE_ID` injected into every pane's environment (beside `PROWL_WORKTREE_PATH` / `PROWL_ROOT_PATH`), documented in `docs/components/cli.md`, and the `prowl-cli` skill's self-identification rewritten around it. Convenience identity only — trusted attribution (064 `agents signal`, `workflow deliver`) stays on caller-PID resolution. |
| **A2** | A | A1 | Profile launch boundary (`.prompt`, placement override, anchor, background, synchronous `LaunchedSurface` result) + `prowl create tab/pane --profile --prompt -` + `prowl profiles list`; exposes the seam 064-S3 uses for launch-scoped hooks. Unlocks the CLI-driven route; the runner's `launch` boundary. |
| **B1** | B | — | Definitions: Yams, `AgentWorkflow` model + validator + JSON Schema, three-source discovery, `prowl workflow list/validate/schema`. Makes the DSL concrete and authorable (no user-facing surface until R2). Lives in `ProwlCLIShared` so `validate`/`schema` run without the app; `list` goes through the socket and reads a hidden enabled set (`@Shared`, all enabled until D1's page). Record: [006](006-b1-definitions.md). |
| **B2** | B | B1 | Runner core (pure): run state machine incl. `repeat`, run store, template renderer, action registry, watchdog with injected clock that consumes exact signals first (064-S5's watchdog part, moved here 2026-08-29) — tested against fake boundaries. Activations live in the shared dispatch store; there is no separate `WorkflowRequestRegistry` (decision 2026-08-29). |
| **B3** | B | A2, 064-S1, B2, #733 | Runner wiring: reducer-owned `WorkflowRunsFeature` effects, per-activation `observeAgentDispatch` + `observeAgentState` watchdog streams, CLI admission preflight, `prowl workflow run/status/deliver/cancel` + contracts. Engine first powered on. |
| **C1** | C | B3 | Status center fifth state + run panel + attention triggers + notifications (061 visual verification). Runs become visible. |
| **C2** | C | B3 | Start sheet (bindings, suggestion-based profile creation, don't-ask-again, `--skip` equivalent) + entry points (capsule popover, palette, Active Agents context menu). GUI-initiated runs. |
| **D1** | D | B1, C2, 065-K1 | `prowl-workflow` authoring skill (registered by adding it to `skills/`; embedding and the registry come from [065](../065-bundled-agent-skills/000-plan.md)), `docs/components/workflows.md`, Settings › Workflows page (enable/validate/Reveal/New/Ask-agent/per-workflow auto) added to the Agents group. Distribution and docs. |
| **D2** | D | D3 acceptance / R2b shipped; A2, C2, D1, 064-S3 wave 1, #733, #726 T1 | `prowl.adversarial-review` built-in + reviewer skill + loop/verdict/watchdog E2E. Deferred to R3 after handoff validates the first built-in path. |
| **D3** | D | A2, C2, D1, 064-S3 wave 1, #733, #726 T1 | `prowl.handoff` + `prowl.handoff-checkpoint` built-in bundles composed from general-purpose actions and agent steps; `prowl handoff to\|save` → `HANDOFF_RETIRED` stubs; remove `HandoffHudFeature`, `HandoffCommandHandler`, `HandoffRequestRegistry`; rewrite `docs/components/handoff.md` and the `prowl-cli` skill. First built-in workflow and Debug E2E in R2b; release candidate after handoff/checkpoint acceptance. |
| **V2** | — | — | observe mode (`expect.status` + `agents read` / hook `last_assistant_message`), `on_attention: ask <role>`, fan-out (`count`, `wait all`), run persistence/resume, retention, cross-worktree roles, GUI editor. |

## Alternatives & decisions

- **Prowl-native runner, not an orchestrator agent.** A reducer-owned state machine is
  deterministic, observable in the toolbar, costs no extra model turns, and is the natural
  generalization of 047/049's "trigger + observer" HUD. The CLI-driven route stays possible
  (and is why #699/profile launch/`agents wait` are prerequisites), but it is not the
  product's main line.
- **YAML (Yams) as the source of truth; Mermaid render-only.** Multi-line prompts are the
  bulk of a workflow; block scalars are essential. JSON remains valid input. Parsing
  Mermaid into stable orchestration semantics is fragile and was rejected.
- **`deliver`-first outbound channel, not transcript observation.** `prowl workflow deliver` is
  runtime-agnostic, validated, correlated by caller pane + delivery token, and proven by
  the inline brief. `agents read` covers only Claude/Codex and depends on intermittent
  session attribution; it becomes a V2 assist.
- **Headless roles deferred to V2.** The adapters only *render* `.headless` invocations;
  there is no process executor, output protocol, or per-runtime trusted-result extraction
  yet (cwd/env, stdout/stderr bounds, exit/cancel/timeout semantics all undefined). Neither
  V1 built-in needs it, and the interactive reviewer is the product default anyway, so
  `kind: headless` stays a reserved key until a `HeadlessAgentExecutor` is specified.
- **File + pointer inbound; `text` for short lines.** Typed text is one line by
  construction (TUIs submit on newline; `ghostty_surface_text` is not bracketed paste).
  Long content is materialized; short messages are typed verbatim so users can see them.
- **Interactive reviewer by default.** Side-by-side visibility of the review happening is
  part of the product's trust model (onevcat, 2026-08-21); headless roles are a V2 item.
- **Roles reference requirements, never local profile names.** `agents:` (allowed
  runtimes) + `suggest:` (match-or-create) + remembered local bindings keep shared files
  portable while profiles remain the only launch authority (053 boundary intact).
- **`repeat … until <verdict>` in V1, no expression language.** The one loop onevcat's
  real flow needs is "re-review until clean"; termination reads a machine-declared
  `--verdict`, never prose. `max` is mandatory. `until` is evaluated **before entering and
  after every iteration** (while-loop semantics), so a first-round `clean` verdict skips
  the loop entirely.
- **Step completion is `prowl workflow deliver`, not `submit <name>`.** Prowl knows which
  step awaits which pane, so the agent names nothing; output names live in YAML
  (`expect.delivery`).
- **Run directory under the target root**, mirroring `.prowl/handoff/`: sandboxed agents
  read cwd-relative files most reliably; definitions live beside it in
  `<root>/.prowl/workflows/` so a repo can ship its workflows.
- **Retire `prowl handoff` instead of emulating it.** Ten review rounds showed that
  preserving every legacy semantic (`--no-brief`, `--no-launch`, bare-shell sources,
  synchronous failure codes, the v2 payload) needed an adapter with its own preflight,
  seeded outputs, a destination-only binding kind, and a parity matrix — all machinery
  that exists only for compatibility. A `HANDOFF_RETIRED` stub with the exact replacement
  command gives users the same migration in one line; `--skip brief` and the optional
  action input cover the context-only case generically.

## Decisions recorded during design review (2026-08-21)

- **Handoff CLI** (revised 2026-08-22): `prowl workflow run prowl.handoff` is the only
  invocation. The shipped `prowl handoff to|save` are **retired outright** — one release of
  non-executing `HANDOFF_RETIRED` stubs carrying the exact replacement command, then
  removal. The earlier plan to keep a schema-compatible alias through a
  `LegacyHandoffAdapter` (with its preflight, seeded outputs, destination-only binding,
  and `failurePolicy: .fail`) was dropped as not worth its complexity once migration
  guidance proved to be a one-line message; review-round notes below that mention those
  mechanisms are historical. The `.prowl/handoff/` artifact contract survives inside the
  `handoff.transition` / `handoff.checkpoint` actions.
- **Binding default**: built-ins use `bind: ask`. Users switch a workflow to `auto` without
  editing the file: a "Don't ask again for this workflow" toggle in the start sheet and a
  per-workflow toggle in Settings › Workflows store a local override next to the binding
  memory. Direction: V1 edits YAML in an external editor; a GUI editor with file ↔ UI
  two-way sync is the long-term goal (see Open questions for the round-trip constraint).
- **CLI-driven orchestration primitives ship with #699**: `prowl create tab|pane
  --profile <name|uuid> [--prompt -]` and `prowl profiles list` are part of the
  prerequisite PRs, not a later wave. (`prowl agents wait` was initially listed here and
  moved to 064 on 2026-08-22 — see below.)
- **Completion signals split out as 064 (2026-08-22)**: the layered signal bus,
  `prowl agents signal`, launch-scoped hooks, and `prowl agents wait` with
  `source`/`confidence` are an independent entry. 063 V1 does not depend on it (steps
  complete on `deliver`; the heuristic watchdog is harmless by design); 064-S1 delivers the
  `ObservedAgentState` observer that B3 consumes, 064-S3 builds on the launch boundary
  (A2), and in return 064 sharpens the watchdog and enables 063's V2 observe mode /
  `on_attention: ask <role>`.
- **Settings IA**: Agents becomes a sidebar group with Profiles / Workflows / Command Line
  Tool pages (see Design / UI); the CLI install leaves Advanced.
- **No default wall-clock timeout; state-driven watchdog with grace periods** (see Design
  / Execution model). Detection is heuristic, so every trigger is designed to be harmless
  when wrong: grace before acting, a nudge that only asks the agent to finish with `deliver`
  when it is truly complete, and attention states that never discard a late delivery.
- **PR order / releases** (revised 2026-09-05): R1 CLI/signals and R2a workflow engine/CLI
  have shipped. R2b = C2, D1, T1, then D3 handoff/checkpoint migration and first built-in E2E;
  consider releasing at that boundary. D2 adversarial review moves to the next release, R3;
  064-S4 remains independently planned there. Slice IDs remain stable. Handoff's simpler flow
  now validates the engine first; D2 adds loop/verdict-specific acceptance later. Preserve
  the one-release non-executing CLI retirement period from handoff's actual release. The
  single source for order and release assignment is [release-plan.md](release-plan.md).
  S3 has no wave 2: runtimes requiring global-config, dedicated-home, or project-file writes
  do not receive Prowl-managed hooks.
- **Review round (2026-08-22)** — accepted corrections: runner as an `AppFeature` child
  fed by the single event subscription + a per-surface multicast observer for CLI waits;
  opaque per-step delivery tokens for `deliver`; `LegacyHandoffAdapter` with a full parameter
  map instead of a "byte-compatible" claim; binding memory scoped by definition source +
  repository and re-validated; `pick` restricted to the source worktree; `kind: headless`
  moved to V2; output size caps, slug-safe ids, run-directory containment, and the
  privacy wording split into Prowl metadata vs. agent-authored outputs; `until` checked
  before entry and after each iteration.
- **Review round 2 (2026-08-22)** — accepted: typed `ObservedAgentState` observer
  (snapshot / changed / removed / surfaceClosed, per-subscriber buffering, `AGENT_GONE`
  mapping for `agents wait`); the generated completion command is the only spelling in
  built-ins/examples, `--token` in the grammar, shell-safe UUID tokens, tokenized nudges;
  `LegacyHandoffAdapter` admits a bare-shell source when the brief is pre-supplied/skipped
  and uses `failurePolicy: .fail` → `HANDOFF_FAILED`; skipping an output referenced later
  ends the run as `skipped`; binding memory keyed additionally by a role-requirements
  digest; `message` steps advance only after a successful synchronous injection (no
  Prowl-side queue); P2 wording fixes (role `name`/`pane` semantics, `run` source
  grammar, privacy phrasing, `repeat` terminal results).
- **Review round 3 (2026-08-22)** — accepted: one completion-command renderer (token +
  verdict choices, used for hints, nudges, re-deliveries); §3 binding key with a canonical
  role-requirements digest as the single normative definition; per-activation identity
  and tokens for `repeat`; `expect` restricted to `message`/`launch`; source-specific
  `--role` grammar incl. `pick` panes; `LegacyHandoffAdapter` preflight (`BRIEF_REQUIRED`
  / `EMPTY_INPUT` / `INVALID_BRIEF`, legacy failure mapping); rendered-text boundary
  (post-substitution single-line validation, single-line string inputs, `UNSAFE_PATH`);
  `skill:` restricted to the embedded registry; wording cleanups (runtime input queue,
  bare-shell `current`, privacy phrasing, atomic observer registration, slug patterns).
- **Review round 4 (2026-08-22; verified item by item before adopting)** — the renderer
  now emits one complete executable command per verdict value on every transport (no
  placeholders); run-global monotonic activation ordinals make `deliveries/<name>.<ordinal>.md`
  and `prompts/<step>.<ordinal>.md` collision-free, with atomic "latest" replacement;
  native actions declare typed input/output schemas and `actions.<step>.<key>` is validated
  like `deliveries.*` (known action, declared key, producer dominates consumer); `repeat.max`
  is a positive integer literal or exactly one integer-input template, resolved at start,
  bounded `1…20`; verdict values are unique safe slugs and `until` literals must be
  declared; optional fixes (`UNSAFE_PATH` listed, `tN` in the source grammar, concepts
  table and binding text aligned with the DSL, `notify` fallback without a `current` role,
  legacy parity list includes the preflight cases).
- **Review round 5 (2026-08-22; verified before adopting)** — run-directory specifics in
  the plan now defer to the DSL spec (§§5/8 normative); a run-global *invocation* ordinal
  is minted on entry to every `message`/`launch` execution (artifact naming for
  non-waiting steps too), with *activation* = waiting invocation; `--role r=<binding>` in
  the synopsis; `agents wait` wording aligned with the `ObservedAgentState` observer and
  `AGENT_GONE` payload; a compact V1 action schema table added to the DSL.
- **Review round 6 (2026-08-22; verified before adopting)** — `handoff.checkpoint.briefing`
  is optional (absent = context-only checkpoint, preserving today's `handoff save
  --no-brief`) with a `has_briefing` output, and both `save` variants join the legacy
  parity matrix; message Retry is a new invocation (token revoked and re-minted; guidance
  when an insert succeeded but the submit failed); the plan's token paragraph now
  cross-references the DSL invocation/activation lifecycle.
- **Review round 7 (2026-08-22; verified before adopting)** — absent
  `handoff.transition.briefing` is normatively the context-only *transition* (archive,
  remove stale `current.md`, regenerate context, context-only kickoff, `has_briefing:
  false`) — distinct from the checkpoint rule; `--no-launch` freezes the receiver as a
  typed destination-only binding (token, no profile/pane/plan) that `handoff.transition`
  resolves `to` from, profile lookup happens only when a launch is requested; both cases
  join the parity matrix; Retry revokes/re-mints a token only when the step has `expect`.
- **Review round 8 (2026-08-22; verified before adopting)** — internal-only *seeded
  outputs* give a pre-delivered legacy brief a legal run-store identity (run-global
  ordinal, `deliveries/brief.<ordinal>.md`, `seeded` record, no token/pane), preserving the
  invalid-brief-before-any-artifact property; the destination-only binding is
  cross-referenced from the binding model, the `run` response, and `run.json`.
- **Review round 9 (2026-08-22; verified before adopting, mechanism chosen differently)** —
  instead of an adapter-private input overlay, the Skip rule tolerates missing outputs for
  optional action inputs (key absent → `handoff.transition` context-only), which serves
  `--no-brief`, `save --no-brief`, and the GUI "Context Only" skip with one rule; `current`
  role admission depends on whether a message will actually be delivered (pre-skipped and
  seeded-completed steps do not count); seeded outputs are validated against the step's
  `expect`; outputs may be agent- or caller-authored.

## Open questions

- GUI workflow editor (V2): Yams does not preserve comments/formatting on re-serialization;
  two-way sync needs either a comment-preserving writer or a "managed file" policy.

## Amendments

- Updated 2026-08-31 (C1 kickoff, grilled): the workflow status center is the selected
  worktree's runtime indicator/control only; it lists active runs without history, renders every
  machine-authorized attention action, and keeps R2a CLI-first. C1 is one PR with exhaustive cheap
  tests, two or more neighboring-agent adversarial review rounds, and reviewed-head live E2E as its
  merge gate. Display sleep relies on #746 and does not add a headless/fail policy. Plan and evidence:
  [010-c1-workflow-status-center.md](010-c1-workflow-status-center.md).
- Updated 2026-08-30: a two-round display-sleep spike located the `CREATE_FAILED` cause in the
  pinned GhosttyKit, not in Prowl's launch ordering: with zero active displays the renderer's
  eager CoreVideo display link (`window-vsync = true`) aborts `ghostty_surface_new`, while
  `window-vsync = false` — even toggled at runtime — creates fully working tabs, splits, and
  Profile panes that render normally after wake. #746 implements upstream Ghostty's #13639 fix
  in the fork, so neither a Prowl-side display override nor the headless-or-fail workflow policy
  remains planned; honest rollback for otherwise unknown tab/split creation failures remains
  optional generic hardening — see
  [009-display-sleep-surface-spike.md](009-display-sleep-surface-spike.md).
- Updated 2026-08-29 (B2, grilled): the runner core is a pure reducer (`WorkflowRunMachine`)
  whose effects B3 interprets; activation tokens are checked in the machine, the dispatch store
  stays untouched; the watchdog observes each activation through `observeAgentDispatch` +
  `observeAgentState` on an injected clock; `run.json` v1 records dispatch ids but never tokens;
  Relaunch is offered for `launch` roles only; a Skip resolves its §5 consequence immediately;
  binding resolution is a pure resolver (memory storage and the sheet stay with B3/C2). The
  spec's §4/§5/§8/§10 were clarified accordingly — see [007-b2-runner-core.md](007-b2-runner-core.md).
- Updated 2026-08-29 (B2, H14): `prowl workflow deliver` validation became a review gate — a
  delivery that misses `sections` / `format` / `verdict` is kept as provisional and the run asks
  the user (Accept / Accept with verdict / Ask again / Skip); `expect.strict: true` restores the
  hard rejection. Spec §5/§9/§10 amended; see [007-b2-runner-core.md](007-b2-runner-core.md).
- Updated 2026-08-29 (B1 kickoff, grilled): the DSL spec was aligned with what R1 shipped.
  (1) `expect` activations are records in the shared dispatch store — `launch` via the S2
  prompted-launch path, `message` via #733's re-dispatch — and `workflow deliver` is the
  body-validating completion of that record; the per-activation token stays for correlation
  only, and the `WorkflowRequestRegistry` of the execution-model section is not built.
  (2) Model, validator, JSON Schema, and discovery live in `ProwlCLIShared`; `validate`/`schema`
  work without the app. (3) The watchdog consumes exact signals first (064-S5's watchdog part
  moves from D2 to B2; `turn_grace` 15 s, floor 5 s, re-check at expiry). (4) `launch.prompt`
  may be multi-line (A2's prompt carrier; 32 KiB cap); the appended protocol block is the
  workflow one and `dispatch-complete` on an activation is `WORKFLOW_DELIVERY_REQUIRED`.
  (5) A `message` step injects only into an idle role (`waitingForRole`); early injection
  needs a `turn-start` signal and is V2. (6) B1 includes `list` over the socket with a hidden
  enabled set. Spec: [dsl-spec.md](dsl-spec.md) §4/§5/§9/§10/§12; record:
  [006-b1-definitions.md](006-b1-definitions.md).
- Updated 2026-08-29: R1 shipped in v2026.8.29. R2 is split into R2a (B1–C1) and R2b (C2–D2);
  #733 (re-dispatch into an existing pane) and #726 T0 (version attestation) are scheduled in
  R2a as D2 prerequisites, #726 T1 precedes D2 in R2b, and the working cadence is recorded in
  [release-plan.md](release-plan.md). The Settings page this plan and C0's record call
  "Command Line Tool" shipped under that name and was renamed **CLI & Skills** in #735.
- Updated 2026-08-23: removed 064-S3 wave 2 from R3. Prowl does not install hooks for
  runtimes that require writes to global configuration, dedicated homes, or project files;
  those runtimes continue to use cooperative, transcript/process, or heuristic evidence.
- Updated 2026-08-23: 064-S2 merged in #718 after full validation and authenticated
  Claude/Codex dispatch E2E. The next R1 orchestration critical-path slice is 064-S3 wave 1;
  065-S0/K1 remains independent parallel work — see [release-plan.md](release-plan.md) and
  [064.005](../064-agent-completion-signals/005-s2-action.md).
- Updated 2026-08-23: 064-S1 merged in #715 and the owner locked S2's paired dispatch and
  evidence-wait contract, leaving S2 as the next R1 critical-path PR — see
  [064.003](../064-agent-completion-signals/003-s2-dispatch-wait-design.md).
- Updated 2026-08-22: Shipped C0 with the Agents sidebar group, Profiles page, and Command Line Tool page; Workflows remains deferred to D1 — see [002-settings-agents-group.md](002-settings-agents-group.md).
- Updated 2026-08-22: Implemented A1 with the direct anchored split primitive and schema-governed `prowl create pane` command — see [003-cli-create-pane.md](003-cli-create-pane.md).
- Updated 2026-08-22: Implemented A1b — `PROWL_PANE_ID` in every pane's environment, manual identity section, and the `prowl-cli` skill rewritten around it — see [004-pane-identity-env.md](004-pane-identity-env.md).
- Updated 2026-08-22: Implemented A2 with the typed Profile launch boundary, prompted/background `create tab|pane`, and `profiles list`; the final A1/A2 Swift interface question is resolved — see [005-cli-profile-launch.md](005-cli-profile-launch.md).
- Updated 2026-08-22: Hardened A2 after review: capped prompts bypass canonical PTY input through a zsh/bash/fish-portable surface-environment carrier command, launch failures retain typed reasons, interactive stdin/version skew fail closed, and hidden-worktree background selection is covered — see [005-cli-profile-launch.md](005-cli-profile-launch.md#review-hardening).
- Updated 2026-09-04: The D1 authoring skill shipped early as `prowl-workflow` (#754) — the singular name supersedes `prowl-workflows`; see the release-plan change log.
- Updated 2026-09-04 (D1 rest): Settings › Agents › Workflows, `docs/components/workflows.md`, and the C0-deferred CLI reachability status merged in #761; the watchdog grace values stay constants for now (not in D1's slice contents) — see [013-d1-workflows-settings.md](013-d1-workflows-settings.md).
- Updated 2026-09-04 (D1 post-merge UI refinement, grilled): the global page becomes a minimal native list with drill-in details; repository workflows move into a shared list section in each repository's Settings; `Bindings` becomes user-facing Run Setup and role Profile preferences; run targets are explicit; source files open in their associated editor; repo preferences become repository-qualified; and YAML icons reach the Agents capsule. Plan: [014-workflow-settings-ui-refinement.md](014-workflow-settings-ui-refinement.md).

- Updated 2026-09-05: Confirmed D1 refinement #763 merged; T1 remains before D2, with inventory, low-cost model candidates, and a proposed repeatable harness in [064.016](../064-agent-completion-signals/016-t1-contract-test-plan.md). No inference verification performed.

- Updated 2026-09-05 (T1 closure): Full eight-runtime verification and explicit scoped publication passed; the baseline and matrix were advanced while preserving interactive history. Release guidance now uses `verify` then `publish`. See [064.016](../064-agent-completion-signals/016-t1-contract-test-plan.md). Merge this closure, then proceed to D2; GUI E2E is outside #726 T1.

- Updated 2026-09-05 (owner sequencing decision): D3 moves before D2 into R2b; handoff/checkpoint carry the first built-in Debug E2E. Consider R2b release after acceptance, with adversarial review deferred to R3. This supersedes earlier D2-first/migrate-handoff-last ordering; CLI retirement and artifact contracts remain unchanged.

- Updated 2026-09-05: Recorded accepted action/bundle authorization, workflow-wide context, typed state, conditions/unbounded loops, sequential scheduling, and no recovery decisions in [015](015-action-bundles-and-control-flow.md). Consolidated syntax remains under review; no implementation yet.

- Updated 2026-09-05: Added the process-scoped workflow UI release gate in [016](016-workflow-ui-release-gate.md); the CLI/runtime remain available and future workflow slices do not block this release.

- Updated 2026-09-06: Personal workflow history and fixed retention — see [018-history-storage-plan.md](018-history-storage-plan.md).

- Updated 2026-09-07: Normalize workflow naming before D3; no aliases or migration — see [019](019-workflow-naming.md).

- Updated 2026-09-08: Complete delivery naming in CLI/persisted records, diagnostics, helpers, and active examples — see [019](019-workflow-naming.md).

- Updated 2026-09-08: add only `prowl.handoff`, keep existing handoff entry points, and make receiver launch optional — see [020](020-handoff-workflow.md). This supersedes D3's two-workflow and legacy-retirement scope for this slice.

- Updated 2026-09-08: Plan generic step history with source-or-role pane association and external full-output viewing — see [021](021-step-history-ui.md).
