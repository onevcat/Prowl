> Historical slice record. For executable definitions and current names, use the
> [DSL specification](dsl-spec.md) and [019 naming contract](019-workflow-naming.md).
> The old substitution renderer and dedicated handoff actions described below have been removed.

# 063.007 — Workflow Runner Core (B2): Plan

## Status

Implemented on `feat/workflow-runner-core-b2` (2026-08-29); PR [#743](https://github.com/onevcat/Prowl/pull/743).
The decisions below were grilled with onevcat on 2026-08-29 before code (H2, H4, H5, H6, H8,
H10, H11, H12, H7 each settled on the recommended option); "Delivered", "Verification", and
"Review" record what landed after four adversarial rounds.

## Context

B1 (#740) made a workflow file parseable, validatable, and listable; #733 (#741) gave the
dispatch store a re-dispatch into an existing pane; #726 T0 (#739) added the version attestation.
B2 is the engine that turns a validated `WorkflowDefinition` into a run: the state machine,
the run directory, the renderers, delivery validation, the exact-signal-first watchdog, the native
actions, and pure binding resolution. It ships no user-facing surface and stays dormant on `main`:
B3 wires it into TCA and the CLI (`prowl workflow run/status/deliver/cancel`), C1 makes runs visible.

Decisions G1–G6 ([006](006-b1-definitions.md)) and the 2026-08-29 spec amendments are inputs, not
subjects: activation = dispatch record, no `WorkflowRequestRegistry`, `message` injects only into an
idle role, `launch.prompt` may be multi-line, the watchdog consumes exact signals first.

## Decisions

Every row was either a default derivable from the code base (H1, H3, H9, H13) or grilled on 2026-08-29; the
"Alternatives rejected" column records what the grill turned down.

| # | Decision | Alternatives rejected |
| --- | --- | --- |
| H1 | **B2 lives in `supacode/Domain/Workflow/` (app target), tests in `supacodeTests/`.** It depends on app types (`AgentSignal`, `ObservedAgentState`, `AgentProfile`, `HandoffStore`, dispatch records) that never enter `ProwlCLIShared`. Two additions go to Shared: `WorkflowSchema.tokenEnvironmentKey` (`PROWL_WORKFLOW_TOKEN`, read by B3's CLI `deliver`) and the markdown fence/preamble normalizer that `HandoffStore.validatedBriefing` and the delivery validator share. | Putting the text-level helpers (template renderer, completion command, delivery validation) in Shared so `swift test` covers them: nothing in the CLI consumes them in V1 and Shared carries the `nonisolated` / name-collision tax; revisit if B3 wants a local pre-validation in `deliver`. |
| H2 | **Reducer-style core.** `WorkflowRunMachine.apply(_ event) -> [WorkflowRunEffect]` is a pure, synchronous transition over a `WorkflowRun` value; every transport concern (idle wait, injection, launch, native action, notify, close, persistence, watchdog arming) is an *effect* B3's `WorkflowRunsFeature` interprets with the terminal boundaries. B2 tests drive the machine directly and, for the composition, through a test harness that interprets effects against fakes (store on a temp directory, fake bridge, `TestClock`). The harness is the executable specification of how B3 must interpret each effect. | A stateful `WorkflowRunner` class in B2 that owns state and calls the boundaries itself (B3 would either wrap it as an `@Observable` store beside TCA or discard it; the plan says the runner is reducer-owned). Async methods on the machine (transitions entangled with I/O; the Retry/Relaunch/Skip/Cancel × phase matrix becomes hard to pin). |
| H3 | **Activation bridge = one protocol, `WorkflowActivationBridge`**, with exactly the dispatch-store operations the effects need: open a message activation (issue + bind to the pane's current epoch, #733's `issueAgentDispatch(boundTo:)`), abandon with a reason, observe a record, complete a record on delivery. The launch activation is opened by the launch boundary itself (S2's issue → attach → launch → bind), so the `.launch` effect carries the token and the environment values and receives the dispatch id back in `.launched`. B2 tests use a fake. | Folding the operations into `TerminalClient` closures now (that is B3's wiring); a second registry (rejected in G1). |
| H4 | **Token check lives in the machine, not in the store.** Each activation holds its token in `WorkflowRun` state; `deliver` in B3 resolves the caller pane → its pending dispatch id → the run and activation (through `WorkflowRun.activation(forDispatchID:)`) → `machine.deliver(ordinal:token:body:verdict:)`, which answers `STEP_NOT_EXPECTING` / `TOKEN_REQUIRED` / `TOKEN_INVALID` / `OUTPUT_*` / `VERDICT_REQUIRED` itself. `dispatch-complete` against a workflow activation is refused by B3's handler from the same index (`WORKFLOW_DELIVERY_REQUIRED` with the replacement command rendered by B2). The dispatch store (064 code) is untouched. | Storing the token in `AgentDispatchBinding` and checking it in `AgentDispatchStore.complete` (the store would learn workflow semantics; every 064 completion path would grow a branch). |
| H5 | **`run.json` is `WorkflowRunRecord` v1**: top-level `version: 1`; `run` (id, workflow id/name, scope, definition path, status, started/updated/finished), `worktree` (id, name, branch, path), `inputs`, `bindings` (per role: source; launch → profile id/name/agent, pane id/handle once launched; current/pick → pane id/handle, detected agent), `invocations` (ordinal, step, iteration, role, kind, instruction path, activation → dispatch id + state `waiting/delivered/skipped/revoked` + output name/path/verdict), `deliveries` (latest per name), `actions` (step → declared keys), `loop` (count), `steps` (entered step records with state). **Delivery tokens are not persisted** (correlation only, useless after restart, and the file then carries nothing a reader could replay); dispatch ids are (needed by `status` / `agents wait --dispatch`). No environment values, extra arguments, home paths, or credentials — the frozen launch *plan* stays in memory with B3, only profile id/name/agent reach the file. Readers tolerate unknown keys; the launch-time `interrupted` scan reads only `version` and `run.status`. | Persisting the token (no consumer); persisting the launch plan (its surface environment carries override values); a schemaless dictionary. |
| H6 | **Watchdog observes per activation**: `observeAgentDispatch(id)` (already epoch-gated by the store: `.needsInput`, `.incomplete` = coalesced `turn-ended`, `.changed(gone)`) for exact evidence and `observeAgentState(surfaceID)` for detector levels, `removed`, `surfaceClosed`, plus a `snapshot(surfaceID:)` re-read at every grace expiry. Two streams and an injected clock per waiting activation, torn down with it. | One bus through `AppFeature`'s single `eventStream` subscription (the 2026-08-22 topology, written before 064-S1 shipped the multicast observer; the spec §10 already names `observeAgentState` / `observeAgentDispatch`). |
| H7 | **Attention and nudge copy** (the only strings agents and users see from B2): nudge `[Prowl] When your work for this step is fully complete, finish with: <commands>`; attention reasons (panel text, C1 renders): *needs input* "The reviewer is waiting for input in its pane" (Focus pane / Cancel), *idle without delivery* "The reviewer has been idle for 3 min without delivering findings — nudged once" (Nudge again / Keep waiting / Skip / Cancel), *blocked* (heuristic) "The reviewer looks blocked (screen) for 30 s" (Focus pane / Cancel), *agent gone* "The reviewer's agent session ended" / "…pane was closed" / "…process is gone" (Relaunch / Skip / Cancel for launch roles; Skip / Cancel otherwise), *injection failed* "The line could not be typed into the author's pane" with the unsubmitted-line hint when the insert succeeded (Retry / Skip / Cancel), *launch failed* (Retry / Skip / Cancel), *rendered text invalid* (Skip / Cancel), *action failed* (Retry / Cancel), *timeout* (`on_timeout: attention`: Nudge / Keep waiting / Skip / Cancel). | Free-form strings composed in C1 (two places to keep in sync). |
| H8 | **Relaunch is offered for `launch` roles only.** It abandons the current activation, mints a new invocation for the *current* step, and re-delivers it as the kickoff prompt of a fresh launch of the frozen profile (message content + workflow protocol block); the role's pane is rebound on `.launched`. A `current` / `pick` role that is gone offers Skip / Cancel (a "Rebind pane" action is V2). | Relaunching a `pick` role by re-running the picker (needs C2's sheet; not a runner concern). |
| H9 | **`agents wait --dispatch <id>` works on activations, so B2 records the dispatch id per activation** in state and `run.json`; the `run`/`status` responses (B3) read it from there. | Exposing only the token (the store is addressed by dispatch id). |
| H10 | **Binding resolution in B2 = the pure resolver**: `WorkflowBindingResolver.resolve(role:remembered:override:context:)` walks remembered → `suggest` exact match → Recommended (053: designated → last launched → first enabled, over the `agents`-filtered set) → `.ask(candidates:)`; every candidate is re-validated (exists, enabled, satisfies `agents`, adapter renders a seeded prompt — probed through `AgentRuntimeAdapterRegistry.makeStartInvocation(.prompt)`, injectable); the memory key is `(scope, workflow id, role, SHA-256 of canonical `{source, kind, agents, suggest}` JSON)`. B3 owns the `@Shared` memory, `--role` parsing, and freezing the plan; C2 owns the sheet. | Reading profiles/settings inside B2 (no `@Shared` in a pure module). |
| H11 | **Skip resolves its consequence immediately.** Skipping an activation (panel, `on_timeout: skip`, `--skip` at start) computes the §5 consequence from the remaining steps: a later template / `until` / required action input → the run ends `skipped(step, dependent)` at once; only optional action inputs continue (key absent). The same query (`WorkflowRun.skipConsequence(for:)`) feeds the panel's confirmation text. | Ending the run lazily when the consumer is reached (a `notify` or `close` between them would still run). |
| H12 | **Native actions run through `WorkflowActionExecuting`**; `WorkflowNativeActionRunner` implements `handoff.transition` / `handoff.checkpoint` over `HandoffCoordinator` (archive-first; absent `briefing` → context-only; transition removes `current.md`) and `git.context` over `HandoffStore.save` (the existing `context.md` generator; outputs `path`, `branch`). `to`'s agent token is the frozen profile binding's agent; an invalid briefing file fails the action (Retry / Cancel). | A separate context generator writing under the run directory (a second generator for the same document). |
| H13 | **The hard `expect.timeout` is scheduled by the watchdog driver** on the same injected clock; it fires `.timeout(policy)` into the machine. | A separate timer effect. |
| H14 | **Delivery validation is a review gate, not a wall** (decided with onevcat after the PR was opened). Token, empty body, and the size cap always reject; `sections` / `format` / `verdict` findings are *issues*: the body is persisted as provisional, the CLI answers `ok` + `warnings`, and the run asks the user — Accept as delivered, Accept with verdict (when a declared verdict is missing or undeclared), Ask again (re-types the requirements, same token), Skip, Cancel. `expect.strict: true` restores the hard rejection for outputs a tool must be able to read. Section matching also forgives heading level and case. | Keeping the hard rejection as the default (an agent with weak instruction following gets bounced and may never retry; the user had no way to accept work that was actually done). Inferring the verdict from prose (rejected in the plan: termination must read a machine-declared verdict). |

## Design outline

All new types are `nonisolated` where the app target's MainActor default would otherwise apply,
`Sendable`, and `Equatable` where they enter state.

- `WorkflowRun.swift` — `WorkflowRun` (id, definition, `WorkflowRunContext` {scope, worktree
  facts, inputs, run directory}, `bindings: [String: WorkflowRoleBinding]`, `status:
  WorkflowRunStatus`, `phase: WorkflowRunPhase`, position cursor with loop state, `invocations:
  [WorkflowInvocation]`, `outputs: [String: WorkflowOutputRecord]`, `actionOutputs`,
  `skippedOutputs`, `loopCount`, `stepRecords`), `WorkflowRoleBinding` (`current(pane)`,
  `pick(pane)`, `launch(profile, pane?)`), `WorkflowPaneIdentity` (surface id, tab id, handle,
  display name, agent token), `WorkflowActivation` (ordinal, step, role, token, dispatch id?,
  expect, state), `WorkflowAttention` (reason + `Set<WorkflowAttentionAction>`),
  `WorkflowRunStatus` (`running`, `needsAttention`, `completed`, `cancelled`, `skipped`,
  `iterationLimitReached`, `interrupted`).
- `WorkflowRunMachine.swift` — `WorkflowRunEvent` (`roleIdle`, `injectionSucceeded/Failed`,
  `launched/launchFailed`, `actionCompleted/Failed`, `watchdog(ordinal, verdict)`,
  `timeout`, `user(action)`), `WorkflowRunEffect` (`awaitRoleIdle`, `materializeInstruction`,
  `inject`, `launch`, `runAction`, `notify`, `close`, `abandonActivation`, `completeActivation`,
  `armWatchdog`, `disarmWatchdog`, `persistOutput`, `persist`, `log`, `finished`), `start(...)`,
  `apply(_:)`, `deliver(...) -> Result<WorkflowDeliveryReceipt, WorkflowDeliveryError>`,
  `skipConsequence(for:)`, `activation(forDispatchID:)`.
- `WorkflowTemplateRenderer.swift` — `WorkflowTemplateContext` (typed §6 whitelist) and
  `WorkflowTemplate.render(_:context:)`; `WorkflowTemplateError.missingOutput` is the Skip rule's
  runtime signal.
- `WorkflowLineRenderer.swift` — `WorkflowCompletionCommand` (message form with the env prefix,
  launch protocol block, nudge, instruction-file trailer, `WORKFLOW_DELIVERY_REQUIRED` message),
  typed-line formats with `AgentDispatchPrompt.injectedPrefix`, `WorkflowRenderedText.validate`
  (no line terminators, no C0/C1; `RENDERED_TEXT_INVALID`), the 32 KiB / NUL prompt gate
  (`PROMPT_TOO_LARGE`).
- `WorkflowDeliveryValidator.swift` — format (`markdown` normalized like
  `HandoffStore.validatedBriefing`, `text`, `json`), `sections`, `verdict` (`VERDICT_REQUIRED`,
  undeclared → `OUTPUT_INVALID`), size (`WorkflowDeliveryLimits`: default 1 MiB, hard max 4 MiB →
  `OUTPUT_TOO_LARGE`).
- `WorkflowRunStore.swift` — `<root>/.prowl/workflow-runs/<run-id>/` layout, self-ignoring
  `.gitignore`, `WorkflowRunRecord` (Codable, `version` 1), append-only `log.md`,
  `instructions/<step>.<ordinal>.md`, `deliveries/<name>.<ordinal>.md` + atomically replaced
  `deliveries/<name>.md`, `skills/<id>/` copied from the bundle, every path from validated slugs and
  the run UUID under `AgentProfileHomeProvisioner.validatePhysicalContainment`, and
  `markInterruptedRuns()` for launch.
- `WorkflowWatchdog.swift` — `WorkflowWatchdogSettings` (`turnGrace` 15 s floor 5 s, `idleGrace`
  3 min, `blockedGrace` 30 s), the pure `WorkflowWatchdogPolicy` (phase machine over observation
  events and deadline expiries; exact mode when a `verified_live` channel covers `turn-ended`,
  heuristic otherwise; one automatic nudge per activation), and the `WorkflowWatchdog` driver that
  merges the two streams, schedules cancellable deadlines on the injected clock, and yields
  `WorkflowWatchdogVerdict`s (`nudge`, `attention(reason)`, `timeout`).
- `WorkflowActivationBridge.swift` — the protocol of H3 and the failure enums the machine maps
  (`roleBusy` → back to `awaitRoleIdle`, `surfaceMissing`, `insertFailed`, `submitFailed`,
  `capacityExceeded`).
- `WorkflowNativeActions.swift` — H12.
- `WorkflowBindingResolver.swift` — H10; `WorkflowBindingMemoryKey` (Codable) with the digest.
- Shared: `WorkflowSchema.tokenEnvironmentKey`; `MarkdownArtifactNormalizer` (fence/preamble
  stripping moved out of `HandoffStore`, which now calls it).

## Test plan (red first)

- Machine: linear run through message → launch → repeat → action → notify → close; `until`
  before entry (satisfied → loop skipped, `loop.count` 0) and after each iteration; `max`
  reached → `iterationLimitReached`; latest-wins outputs across steps with the same name; `until`
  reading the body's final producer; Skip consequences (template / `until` / required input end
  the run, optional input continues with the key absent, `--skip` at start); every attention
  reason with its action set; Retry mints a new ordinal and token; Relaunch re-delivers the
  current step as a launch prompt and rebinds the pane; Cancel abandons with a reason naming run
  and step and keeps outputs; late delivery during attention accepted; delivery after Skip →
  `STEP_NOT_EXPECTING`; wrong / missing token; duplicate delivery; `roleBusy` returns to the
  idle wait; message advances only after `injectionSucceeded`; self-initiated first step.
- Renderers: every §6 variable; `roles.<r>.pane` after launch; single-line boundary rejects
  `\n`, `\r`, U+2028/2029, C0/C1 (tab included) without partial output; completion command with
  and without verdict, joined per value; nudge; launch protocol block; instruction trailer;
  prompt cap and NUL.
- Delivery validation: markdown fence/preamble stripping, missing section, `text`, `json`
  parse failure, empty body, verdict required / undeclared / not declared, 1 MiB default, 4 MiB
  hard max.
- Store: layout and `.gitignore`; versioned + latest outputs (atomic replace); instruction and
  skill materialization; unsafe slugs rejected; symlinked run-directory leaf rejected; escaping
  path rejected; `run.json` round trip without tokens/env; interrupted scan flips only
  non-terminal runs.
- Watchdog (TestClock): exact mode — `needs-input` immediate; `incomplete` → 15 s → re-read
  `working`/`session-start`/`progress` re-arms, idle → nudge → 3 min → attention; `session-end`,
  `surfaceClosed`, dispatch `gone` → attention; `removed` diagnostic only when a channel covers
  `session-end`; heuristic mode — `blocked` 30 s, `idle` 3 min → nudge → 3 min → attention,
  `working` cancels; `turn_grace` floor 5 s; hard timeout; keep-waiting never nudges twice.
- Actions (temp git repo): transition with and without briefing (archive first, `current.md`
  removed, `has_briefing`), checkpoint keeps an earlier `current.md`, `git.context` outputs.
- Binding: digest canonical form (sorted `agents`, absent keys omitted, prompt edits keep the
  key); remembered → suggest → recommended → ask; a disabled / missing / `agents`-violating /
  prompt-less candidate falls through.
- Harness: the §4 example end to end against fakes, and the `prowl.handoff` shape with
  `--skip brief` (context-only through the optional input).

## What B3 verifies live (B2 has no surface)

Idle wait and re-dispatch against real Claude Code / Codex panes; the typed line reaching the
composer as one entry with the token prefix; a real `prowl workflow deliver -` resolving through
caller ancestry to the activation; `agents wait --dispatch` on an activation id; the launch
protocol block and `PROWL_WORKFLOW_TOKEN` in the child environment only; the watchdog's nudge
and attention timings on hooked and unhooked runtimes; `dispatch-complete` refused with
`WORKFLOW_DELIVERY_REQUIRED`; run directory contents after a full `prowl.adversarial-review`.

## Delivered

Everything lives in `supacode/Domain/Workflow/` (app target) plus three Shared touches:

- `WorkflowRun.swift` — the run value (`WorkflowRun`), bindings (`WorkflowRoleBinding` with
  `WorkflowPaneIdentity` / `WorkflowProfileBinding`), context (`WorkflowRunContext`,
  `WorkflowRunScope`, `WorkflowRunWorktree`), path derivation (`WorkflowRunPaths`),
  invocations / activations / outputs, the position cursor with loop state, step records,
  attention (`WorkflowAttention`, reasons, actions), status and phase.
- `WorkflowRunMachine.swift` — `WorkflowRunStartRequest` + `start(_:now:makeToken:)` (input
  defaults / ranges / single-line, `UNSAFE_PATH`, `repeat.max` in 1…20, `--skip` legality,
  missing bindings), `apply(_:)`, `deliver(ordinal:selector:body:verdict:)`,
  `skipConsequence(forStep:)`, `activation(forDispatchID:)`, `templateContext()`; the effect
  vocabulary (`WorkflowRunEffect`, `WorkflowLaunchRequest`, `WorkflowWatchdogRequest`) and the
  event vocabulary (`WorkflowRunEvent`, `WorkflowUserAction`, `WorkflowInjectionFailure`,
  `WorkflowWatchdogVerdict`).
- `WorkflowLineRenderer.swift` — `WorkflowCompletionCommand` (message form, launch form, typed
  suffix, instruction trailer, protocol block, nudge, `WORKFLOW_DELIVERY_REQUIRED` message),
  `WorkflowTypedLine` (`[Prowl] ` prefix from `AgentDispatchPrompt.injectedPrefix`),
  `WorkflowRenderedText` (the §10 boundary over `WorkflowValidator.isSingleLine`),
  `WorkflowLaunchPrompt` (NUL, 32 KiB).
- `WorkflowTemplateRenderer.swift` — `WorkflowTemplateContext` and `WorkflowTemplate.render`;
  `missingOutput` is the runtime Skip-rule signal; substituted values are never re-scanned.
- `WorkflowDeliveryValidator.swift` — `WorkflowDeliveryLimits` (1 MiB default, 4 MiB hard
  max), `WorkflowDeliveryError` with the §9 codes, markdown normalization through the Shared
  `MarkdownArtifactNormalizer`, `text`, `json`.
- `WorkflowRunStore.swift` — `WorkflowRunRecord` v1 (+ `WorkflowRunRecordInfo` /
  `Invocation` / `Activation`), `WorkflowRunStore` (layout + `.gitignore`, `run.json`, `log.md`,
  instructions, versioned outputs with `rename(2)` latest view, bundled-skill copy, the
  `AgentProfileHomeProvisioner` containment gate on the run directory and a symlink check on
  every subdirectory, `markInterruptedRuns(now:)`).
- `WorkflowWatchdog.swift` — `WorkflowWatchdogSettings` (15 s / 5 s floor, 3 min, 30 s), the
  pure `WorkflowWatchdogPolicy`, and the `WorkflowWatchdog` driver (two streams + deadlines on
  an injected clock; `snapshot(from:)` maps `AgentConditionSnapshot` so the watchdog and
  `agents wait` agree on what a live channel is).
- `WorkflowNativeActions.swift` — `WorkflowActionExecuting`, `WorkflowActionContext`,
  `WorkflowNativeActionRunner` (`handoff.transition`, `handoff.checkpoint`, `git.context`; path
  inputs must resolve inside the worktree, canonical comparison).
- `WorkflowBindingResolver.swift` — `WorkflowBindingMemoryKey`, `requirementsDigest`
  (canonical JSON via `JSONSerialization.sortedKeys` + SHA-256), `resolve(role:remembered:override:context:)`
  returning `.resolved(profile, tier:)` / `.ask(candidates:suggestion:)` plus the rejections a
  CLI override should warn about; the seeded-prompt probe goes through
  `AgentRuntimeAdapterRegistry` (Amp rejects).
- `WorkflowActivationBridge.swift` — the protocol of H3 (`openMessageActivation`,
  `cancelActivation`, `abandonActivation`, `completeActivation`, `observeActivation`).
- Shared: `MarkdownArtifactNormalizer` (moved out of `HandoffStore`, which now calls it; it
  additionally recognizes chatter *before* the opening fence), `WorkflowSchema.tokenEnvironmentKey`
  / `runEnvironmentKey` / `roleEnvironmentKey`, and the §9 error-code constants in `CLIErrorCode`
  (`STEP_NOT_EXPECTING`, `TOKEN_REQUIRED`, `TOKEN_INVALID`, `OUTPUT_INVALID`, `OUTPUT_TOO_LARGE`,
  `VERDICT_REQUIRED`, `RENDERED_TEXT_INVALID`, `UNSAFE_PATH`, `PROMPT_TOO_LARGE`,
  `WORKFLOW_DELIVERY_REQUIRED`, `RUN_NOT_FOUND`, `PANE_BUSY`, `ROLE_MISMATCH`). `CLIErrorCode`
  itself became `nonisolated` so nonisolated domain code can read it.

### Behaviors worth knowing (beyond the spec text)

- A `repeat` without `until` ends the run as `iteration_limit_reached` after `max` iterations, as
  §4 says; it never falls through to the steps after it.
- `roleBusy` from the bridge (the #733 refusal) is not attention: the step returns to
  `waitingForRole` with the same invocation and token.
- A delivery is two-phase: `deliver` validates and emits `.persistOutput`; the run advances
  and the dispatch record completes only on `.outputPersisted`. While `persisting`, a second
  `deliver` is `STEP_NOT_EXPECTING`; Skip / Cancel abandon the record as they would a waiting one.
- A delivery with issues (H14) becomes `provisional` after persistence: the dispatch record
  stays pending, `outputs[name]` is not set, and the run waits for Accept / Accept with verdict
  / Ask again. Ask again returns the same activation to `waiting` and re-arms the watchdog with
  a fresh nudge; `run.json` records the issue codes under `status.attention.issues`.
- After the automatic nudge is spent (or after "Keep waiting"), a later `turn-ended` still earns
  `idle_grace` before the run asks for attention; only an `idle_grace` that expires idle
  escalates. A grace expiry that saw activity (`working`, `session-start`, `progress`) re-arms
  the same grace (amended by B3, [008](008-b3-runner-wiring.md): the original policy only
  cleared the flag, and a freshly launched agent whose first detector `working` arrived after
  its hook `turn-ended` left the watchdog silent for good). `needs-input` and heuristic `blocked` raise attention but keep watching, so a
  later `turn-ended` without delivery can still nudge.
- Skip of an `action` step is not offered (Retry / Cancel); Skip of a `launch` step leaves the
  role without a pane, and a later `message` to it raises `agent_gone:not_launched` with
  Relaunch.
- `git.context`'s `root` and `handoff.*`'s `briefing` must resolve inside the worktree
  (`UNSAFE_PATH` otherwise), so a repo-scoped workflow cannot point an action elsewhere; both
  are re-walked from the worktree root without following links right before use.
- The run store refuses a `<root>/.prowl` or `<root>/.prowl/workflow-runs` that is a symbolic
  link, and every leaf it writes or reads (`run.json`, `log.md`, instructions, outputs).
- A watchdog armed on a pane that is already gone raises `agent_gone:pane_closed` at once; an
  explicit `expect.timeout` keeps counting through grace-based attention, and a deadline that
  already passed applies its policy on Keep waiting / Nudge.

### What B3 must do with each effect (the harness is the reference)

`awaitRoleIdle` → the #733 idle precondition without its 5 s cap, then `.roleIdle`;
`inject` → `openMessageActivation` (issue + bind) then `insertCommittedText` + `submitLine`,
`.injectionSucceeded(dispatchID)` or `.injectionFailed` (cancelling the issuance);
`openActivation` → issue + bind only (self-initiated first step; the line is in
`run.selfInitiatedLine`); `materializeInstruction` before the inject that names it;
`launch` → plan the frozen profile with `.prompt`, attach the environment values as child-only
carriers (like `attachingDispatch`), issue the dispatch when `expectsDelivery`, then `.launched`;
`runAction` → `WorkflowNativeActionRunner`; `armWatchdog` → one `WorkflowWatchdog` per request,
`disarmWatchdog` → `cancel()`; `persist` / `log` → `WorkflowRunStore`; `persistOutput` → `WorkflowRunStore.writeOutput`
then `.outputPersisted(ordinal)` (or `.outputPersistFailed`), and the CLI `deliver` response is
sent only after that event;
`abandonActivation` / `completeActivation` → the bridge; `cancelRoleWait` → stop the idle wait;
`finished` → tear down. A `.launched` that arrives after the run ended must abandon its
dispatch record (the machine ignores events on terminal runs).

## Verification

- Red first: every suite was written before its implementation compiled (the first
  `xcodebuild build-for-testing` of batch A failed on the missing types; the normalizer test
  failed on the "preamble before the opening fence" case, which the normalizer then learned);
  the machine suite (29 tests) was authored from this record's test plan and passed on its
  first full run; the watchdog policy suite caught two real semantics errors on its first run
  (`sawActivity` not reset per heuristic window; a spent nudge escalating straight to
  attention on the next `turn-ended`), both fixed in the policy.
- App suites (`xcodebuild test`, 165 workflow tests after four review rounds and H14 — together
  with the handoff suites the normalizer change touches — all passing): `WorkflowLineRendererTests`,
  `WorkflowTemplateRendererTests`, `WorkflowDeliveryValidatorTests`, `WorkflowRunMachineTests`,
  `WorkflowRunStoreTests`, `WorkflowWatchdogPolicyTests`, `WorkflowWatchdogDriverTests`
  (TestClock), `WorkflowNativeActionsTests` (temp git repositories),
  `WorkflowBindingResolverTests`, `WorkflowRunHarnessTests`, plus the untouched
  `HandoffStoreTests` over the moved normalizer.
- Gates: `make check` (swift-format + SwiftLint strict) clean; `make build-cli`;
  `make test-cli-unit` (227 tests); `make test-cli-smoke`; `make test-cli-integration` (109
  tests); `make build-app` (0 warnings in the changed files); full `make test` after each review round and after H14 (2796 → 2808 → 2816 → 2819 → 2827 tests, zero failures).

## Review

Adversarial review with the `Pi Reviewer` Profile in a split beside the implementing pane
(`prowl create pane … --profile "Pi Reviewer" --prompt -` for round 1, `prowl agents dispatch`
into the same pane for round 2, awaited with `agents wait --dispatch`), read-only and
SwiftPM-only so it could run beside the app builds; briefs and findings under
`/tmp/prowl-b2-review/`.

- **Round 1 — 10 findings (1 P0, 6 P1, 3 P2), all accepted and fixed.** P0: `appendLog` and
  `readRecord` followed a symbolic-link leaf (now `O_NOFOLLOW` + `fstat` on the log, and every
  leaf the store writes or reads refuses a link). P1: a `roleBusy` refusal re-rendered the same
  invocation with a *second* token (the `.waiting` activation is reused now); `--skip` was
  accepted for steps without an `expect` (`skipNotExpecting`); `deliver` advanced before the
  output was on disk (delivery is two-phase now — `deliver` validates and emits
  `.persistOutput`, `.outputPersisted` completes the dispatch record and advances,
  `.outputPersistFailed` raises `persist_failed` with Retry / Cancel; B3 answers the CLI only
  after persistence); an idle-grace attention cancelled the explicit `expect.timeout` (the
  policy keeps the timeout deadline alive and the machine re-arms with the *remaining* time
  of an absolute deadline); native-action paths were check-then-use (the canonical URL is
  what the action uses, the briefing is read through `O_NOFOLLOW` + regular-file check;
  `HandoffStore`'s own writes under `.prowl/handoff/` stay on the pre-existing handoff trust
  model); `run.json` persisted input values (names only now). P2: required sections were
  matched with `contains` (heading lines outside fences now); enum inputs skipped the
  rendered-text boundary at start (checked, and the validator rejects multi-line enum values
  with `enum_value_multiline`); the Skip consequence inside a loop scanned readers that could
  never run again (position-aware now: later in the iteration, earlier only when another
  iteration follows, after the loop only when an `until` can exit it). Every fix carries a
  regression test; the two-phase delivery reshaped the machine tests (`deliverPersisted`).
- **Round 2 — 8 findings (1 P0, 3 P1, 4 P2), all accepted and fixed; round-1 fixes verified
  (three with objections that became these findings).** P0: a `<root>/.prowl` or
  `workflow-runs` that is a symbolic link (a repository can ship one) moved the whole run
  directory elsewhere, and `readRecord` bypassed the run-directory gate (both refused now;
  the interrupted scan reports a linked run directory as unreadable). P1: watchdog verdicts
  were still applied while a delivery was `persisting` (`deliver` disarms first, verdicts
  need a `.waiting` activation, a persist Retry never re-arms); the canonical-path fix of
  round 1 did not cover a parent directory swapped for a link (briefing and `git.context` root
  are now walked from the worktree root with `openat(O_NOFOLLOW | O_DIRECTORY)` right before
  use); a watchdog armed on a pane that was already gone waited forever (arm-time `gone`
  raises attention). P2: re-arming after an expired hard deadline granted a one-second window
  (the timeout policy runs instead); start-time `--skip` still scanned readers after a
  `repeat` without `until`; `HandoffStore.validatedBriefing` still matched sections by
  substring (heading lines outside fences now, through the shared normalizer); tilde-fenced
  replies were not unwrapped. Residual, recorded rather than fixed: `HandoffStore`'s own
  path-based writes under `.prowl/handoff/` keep the pre-existing handoff trust model, and a
  concurrent local process racing directory swaps is outside B2's threat model (it already
  runs as the user) — static links from a repository are what the gates close.
- **Round 3 — 5 findings (0 P0, 2 P1, 3 P2), all accepted and fixed; round-2 fixes verified.**
  P1: the launch-time restart scan enumerated and decoded records through a linked base before
  the new gate (it now checks the owned base first and gates every run directory); an
  activation armed on a live pane without a detected agent (`absent`) still waited forever
  (a 10 s `appearanceGrace` now ends in `agent_gone:process_gone`, while a launch that has not
  settled gets time to appear — immediate attention was rejected for that reason). P2: the
  restart scan decoded whole records instead of the header H5 promised (a `version` /
  `run.status.state` header is read first and other versions are left untouched); the fence
  scanner accepted a fake closer such as `` ```still code `` (CommonMark closers now: same
  character, at least the opening length, whitespace only after the run); the observer reader
  gave up after three buffer overflows (it re-subscribes while the watchdog runs). Fresh pass
  over the binding resolver, the template renderer, and the harness found nothing at P0–P2.
- **Round 4 (verification) — round-3 fixes verified; 0 P0, 0 P1, 2 P2, both fixed.** The
  heading scan treated any trimmed `#` line as a heading (four-space-indented code satisfied a
  section) and missed a validly indented heading inside a wrapper; and a code block in a
  reply's trailer kept the wrapper closer and the trailer in the persisted artifact. The
  normalizer now parses CommonMark ATX headings and closes a wrapper at the last matching bare
  run before a trailer code block opens — the embedded bare code blocks the handoff tests pin
  still survive. The loop is closed here: nothing at P0–P2 remains.

## Open items

- B3 verifies live what B2 cannot (listed above); the bundled `prowl.adversarial-review` and
  the reviewer skill are D2.
- Watchdog grace values (including the 10 s appearance grace) are constructor settings; the
  Settings › Workflows page (D1) will feed them from `@Shared`.
- `HandoffStore` still performs ordinary path-based writes under `<root>/.prowl/handoff/`
  (the pre-existing handoff contract); moving it to descriptor-rooted I/O would close the
  remaining check-then-use window that `git.context` inherits from it. Recorded as a follow-up
  for D3, when the handoff actions become the shipped path.
- B3 must answer `prowl workflow deliver` only after `.outputPersisted`, cancel a run's watchdog
  on acceptance, and abandon the dispatch of a `.launched` that arrives after the run ended.
