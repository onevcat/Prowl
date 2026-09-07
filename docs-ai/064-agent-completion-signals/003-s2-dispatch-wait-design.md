# 064.003 — S2 Paired Dispatch and Agent Wait Design

## Context

S1 merged in #715 and delivered the per-surface signal state, `ObservedAgentState`
multicast observer, lifecycle events, and cooperative `prowl agents signal` ingress. S2 is
the first consumer-facing slice: it must replace hand-written polling with an atomic,
stale-safe dispatch receipt while also making generic state waits honest about their
evidence.

This amendment records the final owner review completed on 2026-08-23. It supersedes the
provisional S2 command spelling in `002-s1-work-note.md`; S1's shipped `agents signal
--detail` contract is unchanged.

## Starting state and confirmed seams

- `supacode/Features/Terminal/BusinessLogic/AgentObservationStore.swift` provides
  snapshot-first, independently buffered multicast observation and retains only the latest
  signal per live surface. It has no per-source channel registry or session/launch epoch.
  It is the right state/signal wait source but cannot retain a task receipt after surface
  closure or answer whether a deterministic channel is still live.
- `supacode/CLIService/AgentSignalCommandHandler.swift` already attributes cooperative
  events to a surface through the socket peer's process ancestry. The current resolver stops
  at the pane shell and does not prove which agent-process generation emitted an event. S2
  must preserve the surface trust boundary while adding generation-aware evidence matching;
  dispatch completion separately reuses the surface attribution plus launch context.
- `supacode/Domain/AgentProfile/AgentProfileLaunchPlan.swift` distinguishes child command
  environment from surface shell environment. Only the former is safe for a launch-scoped
  dispatch id.
- `supacode/CLIService/LifecycleCommandHandler.swift` already returns typed profile-launch
  metadata, but prompted launches have no task identity or receipt today.
- `supacode/CLIService/ReadCommandHandler.swift` owns stable viewport capture behavior that
  can supply optional post-wait evidence without redefining completion.
- `supacode/CLIService/CLISocketServer.swift` allows an async handler to suspend while other
  requests are accepted. S2 is the first long-lived CLI wait, so disconnect cancellation
  must be propagated instead of leaving a subscription alive until timeout. The current
  server does not monitor peer EOF after reading the request frame.
- `supacode/CLIService/Shared/CommandResponse.swift` currently carries only error code and
  message. S2 needs an optional structured error-details field for receipts and last-known
  observation; omitting that field preserves existing wire responses.
- `supacode/CLIService/Shared/AgentsCommandPayload.swift` exposes detected state but no
  signal evidence. S2 adds live observed/verified signal visibility.
- `supacode/Features/Terminal/Models/WorktreeTerminalState+AgentDetection.swift` removes an
  agent entry when the foreground-job probe loses its stabilized identity. That event is
  useful heuristic observation, but it is not proof that the launched dispatch runtime
  exited and cannot directly create an immutable gone receipt.

Consequently, S2 needs a separate dispatch store and subscriber path while consuming the
S1 observer for status, signal, and lifecycle evidence. Reusing the existing signal record
as receipt storage would lose the result on pane closure and allow unrelated later signals
to overwrite it.

## Scope

S2 ships three connected surfaces in one PR:

1. CLI `create tab|pane --profile ... --prompt ...` becomes an atomic paired dispatch and
   returns an opaque dispatch id.
2. The launched agent reports one immutable terminal outcome through
   `prowl agents dispatch-complete`; `prowl agents wait --dispatch` consumes the resulting
   non-destructive receipt.
3. Generic `prowl agents wait <pane> --until ...`, `--include-screen`, and the `agents`
   `signals` field expose deterministic observations where available and labelled
   heuristics otherwise.

S2 does not install runtime hooks, watch transcript files, infer completion with an LLM,
persist receipts across app restarts, or change `prowl workflow deliver` semantics. Those
remain owned by S3/S4, the orchestrating skill, and 063 respectively.

## Two planes, one observer context

Signals and dispatch receipts are deliberately separate:

| Plane | Answers | Scope | Storage | Consumer |
| --- | --- | --- | --- | --- |
| Signal observation | What just happened to this agent/runtime? | Surface | Latest in-memory observation; ends with the surface | `wait <pane> --until ...`, later watchdogs |
| Dispatch receipt | Did this exact assigned task reach a terminal outcome? | Opaque dispatch id | Bounded immutable in-memory receipt; survives surface closure | `wait --dispatch <id>` |

`turn-ended` is a runtime edge, not task completion. `dispatch-complete` never fabricates or
maps to `turn-ended`; a normal run may record the dispatch receipt first and receive an
independent runtime `turn-ended` signal afterward. Conversely, a deterministic terminal
signal while a receipt remains pending is actionable evidence that the completion protocol
was not fulfilled, not permission to synthesize success.

## Paired dispatch protocol

Every prompted profile launch through CLI `create tab|pane` is a dispatch. S2 intentionally
has no `--no-dispatch` path:

```text
create --profile --prompt
  -> mint pending dispatch
  -> append the versioned Prowl completion instruction to the effective prompt
  -> launch the runtime with child-only PROWL_DISPATCH_ID
  -> return pane identity plus dispatch.id
```

Launch failure removes the pending record and returns the existing typed launch error. The
capacity check and id issuance happen before starting the runtime; binding the returned
surface, an immutable launch-time `TabTarget` snapshot, and the dispatch evidence epoch,
then completing the create response, remain one main-actor lifecycle transaction. The
private target snapshot outlives surface metadata and is the source for every later
completion or wait response; it is not duplicated inside the public receipt tagged union.

An unprompted `create --profile` remains an interactive launch without a dispatch. A caller
that needs byte-for-byte prompt delivery can create an interactive pane and use the existing
`send` command.

This rule is deliberately scoped to the CLI create request, not every internal consumer of
the shared profile-launch boundary. The lifecycle request passes an explicit dispatch
context into the shared launch seam. 063 workflow launches keep their separate
`prowl workflow deliver` activation protocol, and future prompt launchers must choose their own
completion contract rather than inheriting dispatch behavior accidentally.

The id must be passed through the launch plan's child-process command environment, not the
surface shell environment. The latter outlives the launched runtime and could let a later,
manually started agent inherit a stale dispatch id. The effective prompt contains the
protocol command but never the id itself.

The injected instruction tells the agent to choose one terminal outcome and make the
completion command its final tool action:

```bash
prowl agents dispatch-complete \
  --outcome succeeded \
  --summary "Implemented the requested change; all tests pass."
```

or:

```bash
prowl agents dispatch-complete \
  --outcome failed \
  --summary "The required SDK is unavailable on this deployment target."
```

`--outcome succeeded|failed` and a non-empty, single-line, control-free `--summary` are
required. Summary is capped at 32 KiB of UTF-8 and is the concise result retained with the
receipt, not a transcript or artifact transport. S1 keeps optional `agents signal --detail`:
signal detail is event
context or a reason, whereas dispatch summary is the required terminal delivery synopsis.
An accepted completion command returns success for either outcome because it recorded the
receipt correctly; `outcome: failed` becomes nonzero only when a coordinator later consumes
that receipt through `wait --dispatch`.

The completion command accepts no public dispatch-id option. It reads the child-only
`PROWL_DISPATCH_ID`; the app independently resolves the socket peer's process ancestry and
requires the caller pane to match the dispatch-bound surface. Missing launch context fails
with `DISPATCH_CONTEXT_REQUIRED`; a mismatched caller fails with
`DISPATCH_SOURCE_MISMATCH`.

### Create response and version skew

The existing `prowl.cli.create.v1` response gains an optional sibling to `launch`:

```json
{
  "dispatch": {
    "id": "opaque-dispatch-id",
    "state": "pending",
    "created_at": "2026-08-23T02:00:00.000Z"
  }
}
```

This is an additive v1 response property: unprompted and ordinary shell creates omit it.
The new CLI must nevertheless fail closed when its own request contained both `--profile`
and `--prompt`: a successful app response without a valid pending dispatch object becomes
`CREATE_FAILED` with the same inspect-and-close warning used by the existing launch
compatibility guard. This prevents a newer CLI talking to an older app from silently
launching untracked work. Parser, shared payload, executable-schema, and old-app response
fixtures pin the conditional check.

## Receipt lifecycle and idempotency

The terminal manager owns a separate dispatch store with a maximum of 256 records:

- pending records are never evicted;
- creating a dispatch evicts the oldest terminal record first;
- if all 256 records are pending, creation fails before launch with
  `DISPATCH_CAPACITY_EXCEEDED`;
- succeeded, failed, gone, and explicitly abandoned records are terminal and survive agent
  and pane closure;
- app restart clears the store, after which an old id returns `DISPATCH_NOT_FOUND`;
- there is no disk persistence or TTL in S2.

Completion is first-write-wins. Retrying the same id with the same outcome and summary is
idempotent and returns the original receipt. A later completion with different content
returns `DISPATCH_ALREADY_COMPLETED` and cannot mutate the recorded outcome seen by existing
or future waiters. A completion that loses a race to a committed gone or abandoned state
returns `DISPATCH_ALREADY_TERMINAL`.

S2 provides an explicit recovery action for an assignment that will never complete:

```bash
prowl agents dispatch-abandon --dispatch <dispatch-id> \
  --reason "The worker returned to a shell without reporting completion."
```

The exact opaque id and a non-empty reason of at most 32 KiB UTF-8 are required. The command
does not stop the runtime, close its pane, or claim task failure; it only records the
coordinator's decision to stop waiting. The resulting immutable `abandoned` variant carries
`abandoned_at` and `reason`, makes current and future waits fail with
`DISPATCH_ABANDONED`, and becomes eligible for ordinary terminal-record eviction. An
identical retry is idempotent; a different reason or an already completed/gone record returns
`DISPATCH_ALREADY_TERMINAL`. Abandonment and worker completion are main-actor serialized,
and whichever commits first wins. Because abandonment is an explicit local administrative
action rather than a worker report, it is addressed by id and does not require caller-pane
ancestry. The opaque id acts as the local capability, and the retained record supplies the
in-memory audit trail until eviction or app restart.

This recovery path is intentionally manual. A timeout leaves the receipt pending; detector
removal, a quiet shell, elapsed time, and process-probe ambiguity cannot abandon it. If the
worker may still be running, the coordinator must inspect or stop that worker separately
before choosing to abandon the dispatch.

All store operations are main-actor serialized. Wait registration and initial lookup are
one operation. A terminal transition stores one immutable receipt snapshot and resumes all
currently registered waiters with their own copy before another dispatch can trigger
eviction. Eviction affects only future lookup; a waiter that already received or captured a
receipt is not invalidated and does not pin store capacity. “Later waiter” therefore means a
waiter that starts while the terminal receipt is still retained; after eviction it receives
`DISPATCH_NOT_FOUND`.

## Wait contracts

### Exact dispatch wait

Dispatch identity is sufficient; a pane argument would be redundant and would stop working
after surface closure:

```bash
prowl agents wait --dispatch <dispatch-id> [--timeout 1...600] \
  [--include-screen <1...200>]
```

`--timeout` defaults to 600 seconds. It limits the time to reach a matching receipt or
terminal observation, not the optional post-match screen capture.

Only the matching receipt can return task success. Idle state, screen content, and
`turn-ended` never substitute for it. The outcomes are:

- succeeded receipt: successful command with the immutable summary;
- failed receipt: nonzero exit and structured `DISPATCH_FAILED`, including the receipt;
- abandoned record: nonzero `DISPATCH_ABANDONED`, including its reason;
- exact/high `needs-input`: nonzero `DISPATCH_NEEDS_INPUT`, receipt remains pending;
- exact/high stable `turn-ended` without a receipt: nonzero `DISPATCH_INCOMPLETE`, receipt
  remains pending;
- exact/high `session-end` for the matching evidence epoch, or surface closure before
  completion: `AGENT_GONE` backed by a retained gone record;
- timeout: `WAIT_TIMEOUT` with the last observation and evidence.

`turn-ended`, matching `session-end`, and surface closure are terminal-adjacent evidence that
can race with `dispatch-complete` over independent socket or lifecycle paths. They therefore
enter one 300 ms coalescing window. During that window a matching completion has priority:
it commits the succeeded/failed receipt and cancels the candidate transition. If the window
expires first, `turn-ended` surfaces `DISPATCH_INCOMPLETE` while leaving the record pending;
matching `session-end` or surface closure commits an immutable gone record. A completion
arriving after a gone record commits is rejected by first-write-wins. `needs-input` remains
immediate because it is an attention state, not an irreversible terminal record.

Surface closure reaches the dispatch store directly and unconditionally from
`WorktreeTerminalManager.onSurfaceClosed`, independently of whether
`AgentObservationStore` has a record or subscribers. The observation store still receives
its ordinary close publication, but it is not the dispatch lifecycle bridge. A detector
`.removed` event is diagnostic only for a pending dispatch: it cannot write an irreversible
gone receipt or end a strict dispatch wait. A completed receipt returns immediately unless
the caller explicitly requests stable screen evidence.

The receipt read is non-destructive: any number of concurrent or later waiters observe the
same outcome. Socket-client disconnect or CLI cancellation must cancel the server-side wait
subscription rather than leave a waiter alive until the timeout cap.

### Connection cancellation

S2 adds a request-scoped peer-disconnect monitor after the server has consumed the request
frame. A `DispatchSourceRead` on the client file descriptor runs off the main actor and uses
non-consuming `recv(..., MSG_PEEK | MSG_DONTWAIT)` to distinguish peer EOF from unexpected
extra input. EOF wins a single response-versus-disconnect race and cancels the route task;
unexpected post-frame input closes the protocol-violating connection; normal route
completion cancels the monitor before response writing.

The route task carries ordinary Swift task cancellation into the wait handler. The handler
uses `withTaskCancellationHandler` to unregister both dispatch-store and observation-store
subscriptions promptly and returns no response after peer loss. An explicit protocol cancel
request is insufficient because SIGINT/SIGTERM/SIGKILL may prevent the client from sending
it, so S2 does not add one.

### Generic observation wait

```bash
prowl agents wait <pane> --until idle|blocked|changed|exit \
  [--timeout 1...600] [--min-confidence auto|exact|high|heuristic] \
  [--include-screen <1...200>]
```

`--timeout` defaults to 600 seconds. Confidence is an ordered minimum: `exact` accepts only
exact evidence, `high` accepts exact or high, and `heuristic` accepts all three levels.
`auto` is both the default and an explicit accepted token:

- a fresh matching exact/high event always resolves the condition;
- when a verified-live channel covers the requested condition, heuristic changes update
  diagnostics and invalidate stale terminal facts but cannot resolve the wait;
- without such a channel, an already-stabilized screen/process observation may resolve the
  wait with `confidence: heuristic` after 2 seconds of unchanged normalized state;
- `changed` requires a post-baseline normalized state or signal change and is never
  satisfied by the initial snapshot;
- `exit` accepts exact/high matching `session-end`, exact surface closure, or stabilized
  detector removal only as heuristic fallback; disappearance is `AGENT_GONE` for other
  requested conditions only when the evidence is exact/high.

### Deterministic matching and freshness

The waiter evaluates semantic evidence, not merely `latestSignal`:

| `--until` | Exact/high match | Heuristic fallback | Initial snapshot |
| --- | --- | --- | --- |
| `idle` | active `turn-ended` in the current evidence epoch | stabilized detected `idle` or `done` | allowed while the evidence remains active |
| `blocked` | active `needs-input` in the current evidence epoch | stabilized detected `blocked` | allowed while the evidence remains active |
| `changed` | any qualifying signal with revision greater than the wait baseline | normalized detected-state change after baseline | never |
| `exit` | active matching `session-end`, or `surfaceClosed` after subscription | stabilized detector removal | allowed for active `session-end` only |

Each surface has an evidence epoch minted for the CLI dispatch launch (or the first stable
agent detection on an unpaired surface). Detection records an `AgentProcessGeneration` as
the agent PID plus its process start time; a stable replacement mints a new epoch even when
the detected agent kind is unchanged. The first generation observed after dispatch launch
attaches to the launch epoch only when its process start time falls within ten seconds of
launch binding. Observation itself may arrive later. A process started outside that acquisition
window mints a replacement epoch, so an initially missed short-lived runtime cannot lend its
old dispatch to an unrelated agent launched later in the same pane.

S2 extends caller resolution to retain the process ancestry walked before the pane shell.
Surface attribution is enough to accept and retain a cooperative signal, but not enough to
let that signal satisfy an epoch-sensitive wait. Such a signal is match-eligible only when
its caller ancestry contains the current `AgentProcessGeneration`. A supplied session id
must additionally match the independently resolved current `AgentSession.id` when one is
available at exact/high confidence. Medium-confidence session guesses remain diagnostic and
cannot bind or rotate an evidence epoch. If no active generation can be proved, the signal
remains diagnostic and cannot resolve generic or dispatch wait.

The first eligible non-empty session id may bind the current epoch. After an epoch is bound,
only an eligible `session-start` carrying a different non-empty id that also matches the
independently resolved current session may advance to a new session epoch. Every other
mismatched-id event is diagnostic only. A sessionless signal may bind to the current epoch
only when caller generation is proved and that process generation has not crossed a prior
session-id replacement; after such a replacement, sessionless events stay diagnostic until
a new process generation begins. These rules make consecutive `session-start A` / `B`
deterministic and prevent a delayed child of A from satisfying B's waits. They deliberately
prefer losing an optimization over accepting stale evidence.

An eligible `turn-ended` activates idle evidence and invalidates blocked evidence; an
eligible `needs-input` does the inverse. Later `progress`, `session-start`, or normalized
transition into normalized working activity invalidates both terminal facts without letting
heuristic activity itself satisfy a deterministic wait. Metadata-only emissions while already
working, such as an animated title, do not constitute new activity.
An eligible `session-end` invalidates both and activates exit. Therefore an old terminal
snapshot may return immediately only when it is from the current epoch and no later activity
revision has invalidated it. Diagnostic/unbound signals may appear in error evidence but
never drive a transition. The terminal signal itself needs no multi-second stabilization;
the dispatch-only 300 ms coalescing window handles receipt/signal delivery reordering.

An exit-zero heuristic result means only that the requested observable condition matched.
It never means the assigned task completed. The bundled `prowl-cli` skill teaches the
orchestrating agent to inspect `agents read`, optional screen evidence, and task context
before it decides to proceed, nudge, retry, or ask the owner.

`--include-screen` applies to both wait modes and is explicit and diagnostic. It captures
1...200 recent detection-source lines, sampling every 200 ms until unchanged for 800 ms,
with a 2-second post-match capture cap. A capture timeout returns the last sample with
`stabilized: false`; an unavailable or already-closed surface returns screen status
`unavailable`. Neither case changes the primary wait outcome or exit code. Condition
`waited_ms` stops at the match; screen evidence reports its own `waited_ms`.

Observer overflow is never ignored. The waiter re-subscribes and evaluates a fresh snapshot;
if lost signal history prevents a safe conclusion, it surfaces a structured failure instead
of guessing.

## Signal visibility

`prowl agents --json` reports current evidence, not runtime marketing or theoretical
capability:

- cooperative CLI is listed as event-only `observed` after it has been seen in the current
  epoch; this proves the event but not future delivery coverage;
- a future S3 hook is `verified_live` only after launch injection and self-check succeed;
- the latest signal retains event, source, confidence, timestamp, and optional detail;
- screen/process state remains heuristic observation evidence and does not masquerade as a
  deterministic signal channel;
- no observed or verified deterministic source means an empty `channels` array. Auto
  fallback depends specifically on `verified_live` coverage, not array emptiness.

The command continues to enumerate detected-agent rows only. S2 does not turn `agents` into
a live-surface or bare-shell listing. A signal received before detector row creation may be
retained internally, but it is exposed on a later row only if it was already bound to that
row's current evidence epoch; unbound or stale evidence is not retroactively promoted.
Evidence-only surfaces remain addressable through explicit pane targets where the command
supports them, and dispatch state remains addressable by dispatch id. This keeps the JSON
row semantics stable while making the visibility boundary explicit.

S2 extends the observation record with `EvidenceChannelState` keyed by normalized source
(`cooperative_cli`, hook runtime, transcript, process, or OSC), independently of
`latestSignal`. Each entry records `observed|verified_live`, confidence, covered event kinds,
evidence epoch, and last-seen revision/time. A new signal updates only its own channel;
therefore hook observed → cooperative signal cannot erase hook liveness or enable heuristic
success. Epoch change and surface close invalidate old channel state; future S3 self-check
failure removes `verified_live` status. Only `verified_live` coverage suppresses heuristic
auto fallback—an event-only cooperative observation does not promise the next event.

## Error and response model

The common CLI error envelope gains `details: RawJSON?` so timeout, protocol, and task
failures can return their last observation or immutable receipt without encoding data into
error strings. This is a governed change: `CommandError` coding, the common executable
`error` schema (currently closed to code/message), command-specific details schemas, text
rendering, and raw-socket fixtures change together. Existing errors omit the optional field
and remain wire-compatible.

`create` adds a dispatch object alongside existing launch information. Wait success includes
the dispatch id, outcome, summary, immutable launch target metadata, completion timestamp,
waited duration, and observation provenance. `DISPATCH_FAILED`, `DISPATCH_ABANDONED`,
`DISPATCH_NEEDS_INPUT`, `DISPATCH_INCOMPLETE`, `AGENT_GONE`, and `WAIT_TIMEOUT` use distinct
nonzero errors.

New commands use `prowl.cli.agents.dispatch-complete.v1`,
`prowl.cli.agents.dispatch-abandon.v1`, and `prowl.cli.agents.wait.v1`; additive `dispatch`
and `signals` fields remain in the existing `prowl.cli.create.v1` and
`prowl.cli.agents.v1` responses. The shared dispatch record is a strict tagged union. A
completed variant is:

```json
{
  "id": "opaque-dispatch-id",
  "state": "completed",
  "outcome": "succeeded",
  "summary": "Implemented and verified.",
  "created_at": "2026-08-23T02:00:00.000Z",
  "completed_at": "2026-08-23T02:03:00.000Z"
}
```

`pending` carries only `id/state/created_at`; `completed` additionally requires
`outcome/summary/completed_at`; `gone` additionally requires `gone_at` and
`gone_reason: session_end|surface_closed`; `abandoned` additionally requires
`abandoned_at` and `reason`. Gone and abandoned carry no outcome or summary. Every variant
uses `additionalProperties: false`.

The success payloads are fixed as follows:

- dispatch completion: `target` (the existing `#/$defs/target` shape), `receipt` (completed
  record), and `replayed` (Boolean; true only for an identical retry);
- dispatch abandonment: `target`, `record` (abandoned variant), and `replayed`;
- dispatch wait: `mode: dispatch`, `waited_ms`, `target`, `receipt` (completed record),
  `signals`, and optional `screen`;
- generic wait: `mode: condition`, `condition`, `waited_ms`, `target`, `observation`,
  `signals`, and optional `screen`.

The generic observation requires `status`, `raw_state`, `source`, `confidence`, `at`, and
`revision`. A signal channel requires `source`, `state: observed|verified_live`,
`confidence`, `events`, and `last_seen_at`, with optional `session_id`; `signals.last` uses
the existing signal payload shape and is omitted when absent. When `last` is present, the
signals object also requires `last_binding: current|unbound|stale`. Detected-agent rows expose
only `current`; wait error diagnostics may carry the other two values so a coordinator never
mistakes retained but ineligible evidence for a matching event.

A present screen object requires `status: captured|unavailable`, `requested_lines`,
`source: detection`, and `waited_ms`. Captured evidence additionally requires `text`,
`line_count`, and `stabilized`; unavailable evidence carries none of those fields. Optional
members are omitted rather than encoded as null.

Error details are strict mode-specific objects. Once `create` has returned a dispatch id,
the private binding always exists, so every known-dispatch error carries `mode: dispatch`,
`waited_ms`, the required immutable launch `target`, the current dispatch record, and
optional last observation/signals and optional `screen` when requested. Only lookup failures
such as `DISPATCH_NOT_FOUND` lack a binding and target. Generic errors carry `mode: condition`,
`condition`, `waited_ms`, optional target, optional last observation/signals, and optional
`screen` when requested. A failed receipt is
`DISPATCH_FAILED`, and an abandoned record is `DISPATCH_ABANDONED`; neither is a success
payload. These shapes and their `additionalProperties: false` schemas ship in the S2
normative command contracts before handlers turn GREEN.

## Implementation boundaries

The PR changes the existing launch planner and lifecycle handler under
`supacode/Domain/AgentProfile/` and `supacode/CLIService/`, adds the dispatch store and
evidence-channel state beside the existing observation store under
`supacode/Features/Terminal/BusinessLogic/`, and adds governed wire,
parser, renderer, router, schema, and handler coverage through `ProwlCLI/`,
`supacode/CLIService/Shared/`, `ProwlCLITests/`, and `supacodeTests/`.

`WorktreeTerminalManager` owns the direct lifecycle fan-out: surface close is delivered to
both observation and dispatch stores even when either store has no existing observation
record. Signal caller resolution also gains a generation-aware result backed by the pane's
current `PaneAgentState` process id and `ProcessDetection.processStartDate`; focus and
caller-claimed ids remain invalid trust sources.

The same PR updates the normative contracts under `docs-ai/013-prowl-cli/contracts/`, the
current CLI and agent-detection manuals under `docs/components/`, and the bundled
`prowl-cli` skill. S3 runtime adapter hook injection is explicitly excluded.

## Verification plan

- Dispatch store: issuance, binding and immutable target snapshot, both outcomes, identical
  retry, conflicting retry, two waiters, completion/lookup/eviction linearization,
  all-pending capacity, explicit abandonment and replay, completion-versus-abandonment race,
  pane closure, post-eviction not-found, and app-lifetime reset.
- Launch: child-only id propagation, no surface-shell leakage, prompt protocol rendering,
  atomic cleanup on launch failure, unprompted launch parity, and new-CLI/old-app fail-closed
  behavior when a prompted response omits dispatch.
- Completion ingress: missing context, caller ancestry mismatch, wrong pane, validation,
  summary UTF-8 bounds, and immutable receipt behavior.
- Dispatch wait: already completed, delayed completion, failed and abandoned outcomes,
  needs input, terminal signal grace, exact session/surface exit, detector-removal
  non-terminal behavior, timeout evidence, cancellation, and concurrency. Deterministic
  lifecycle coverage includes create -> no signal/detection/wait -> close -> first wait,
  plus two-socket `session-end`/completion and surface-close/completion reverse ordering on
  both sides of the 300 ms boundary.
- Generic wait: initial snapshot, transition, post-baseline `changed`, exact/high gating,
  session/epoch freshness, delayed child A versus replacement B, consecutive
  `session-start A`/`B`, sessionless evidence after replacement, confidence thresholds, auto
  heuristic fallback, stable screen evidence, overflow resnapshot, and target exit.
- Channel registry: per-source preservation, epoch invalidation, observed versus
  verified-live coverage, and hook observed → cooperative event → heuristic still blocked.
- Real transport cancellation: framed wait request followed by direct peer close, plus a
  killed CLI process, returns observer/dispatch subscriber counts to baseline without
  waiting for the 600-second timeout.
- Four CLI layers: parser, shared wire models, router/handler, text/JSON rendering,
  executable schema, raw socket fixtures, and current manuals/skill.
- Closed-surface payloads: succeeded, failed, gone, and abandoned records retain the exact
  launch target snapshot after live terminal metadata is removed.
- Capacity recovery: 256 pending records reject another launch; explicitly abandoning one
  creates an evictable terminal record and allows the next prompted create without restart.
- Required gates before PR: CLI build, smoke and integration tests, format/lint, app tests,
  app build, and live prompted-profile checks for the paired route and heuristic fallback.

## Owner decision record

1. Every prompted CLI `create tab|pane` profile launch appends the documented completion
   protocol.
2. Dispatch completion and runtime `turn-ended` remain separate facts and stores.
3. `wait --dispatch` is strict and never accepts an idle or heuristic substitute.
4. Exact/high stable signals may accelerate attention or failure transitions; heuristic
   changes are evidence for the orchestrating agent only.
5. Dispatch uses required `summary`; S1 signal keeps optional `detail` because their content
   roles differ.
6. Completion is first-write-wins with idempotent identical retries.
7. Terminal outcomes are explicitly `succeeded` or `failed`.
8. The store is memory-only, bounded to 256 records, and survives pane closure but not an
   app restart; pending is never evicted or expired automatically.
9. Generic wait uses deterministic evidence when present and honest heuristic auto fallback
   otherwise.
10. `wait --dispatch` is addressed only by dispatch id.
11. A failed receipt makes wait return nonzero `DISPATCH_FAILED` with structured receipt
    details.
12. The prompted CLI create dispatch path has no opt-out in S2; other internal prompt
    launchers do not inherit it implicitly.
13. Completion accepts only implicit launch context plus verified caller-pane ancestry.
14. `agents.signals` reports only current-epoch observed or verified-live channels on the
    command's existing detected-agent rows; S2 does not enumerate evidence-only surfaces.
15. Surface attribution alone cannot make a signal epoch-sensitive. Sessionless cooperative
    evidence must prove the current process generation and becomes diagnostic after a
    same-generation session replacement.
16. `turn-ended`, matching `session-end`, and surface closure share a 300 ms receipt-priority
    coalescing window; surface closure reaches the dispatch store directly, regardless of
    observation-store state.
17. A coordinator may explicitly terminalize an unrecoverable pending assignment with
    `dispatch-abandon --dispatch ... --reason ...`; this does not stop or fail the worker.
18. A private dispatch binding retains the immutable launch target snapshot for all later
    completion, wait, gone, and abandonment responses.

## External review disposition

The 2026-08-23 PR #716 initial review correctly identified that the owner decisions were
closed but several implementation contracts were not. S2 adopts its cancellation,
deterministic matching/freshness, channel registry, exact-screen grammar, old-app fail-closed,
eviction linearization, schema, and scope findings.

The follow-up review at `f4a31c8a` identified six remaining lifecycle and visibility gaps.
All six are accepted at the contract level: close now fans out directly to the dispatch
store; cooperative evidence gains process-generation proof and an unbound diagnostic state;
terminal evidence uses receipt-priority coalescing; `agents --json` explicitly retains its
detected-row boundary; private bindings retain launch targets; and pending capacity has an
explicit abandonment path.

The remedies are intentionally narrower than several possible alternatives: cancellation is
driven by actual peer EOF rather than an explicit cancel request that cannot survive process
death; `agents` does not begin enumerating bare shells; and detector `.removed` never creates
a dispatch gone receipt or auto-abandons pending work. Only a coalesced, matching
`session-end`, exact surface closure, or explicit coordinator abandonment owns those terminal
transitions.

No owner-level product choice remains open for S2. The review-frozen transition, transport,
compatibility, and payload rules above are implementation acceptance criteria; internal type
names may still change without weakening them.
