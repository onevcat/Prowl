# Agent Workflow DSL — `prowl.workflow/v1` (living spec)

Updated 2026-09-06 for action bundles. Workflows have not been formally released. This is
the v1 bundle format, not a version migration. This specification supersedes the earlier
loose-document, `repeat/until`, and workflow-handoff-action design. The separate handoff CLI
remains unchanged. Design rationale: [015](015-action-bundles-and-control-flow.md) and
[017 implementation contract](017-action-bundle-implementation.md).

## 1. Execution model

A workflow runs sequential steps against one fixed worktree. Agent roles use real terminal
panes and frozen profile bindings. A message/launch with `expect` waits for an accepted
explicit delivery. Without `expect`, successful injection/launch advances the workflow;
agent work may still continue. Actions await a validated result. State/control steps execute
in-process and yield after a bounded batch. Cancellation stops scheduling and owned script
process groups, without undoing side effects or stopping independent agent work.

## 2. Workflow bundles

A directory `<name>.pwlworkflow` contains `workflow.yaml`, with `schema`, `id`, `name`, optional
`description`, `icon`, `inputs`, `roles`, `state`, and nonempty `steps`. Local action manifests
live at `actions/<slug>/action.yaml`; their entrypoints, helpers, assets, and referenced
schemas are part of the same bundle. Validation takes the bundle directory.

Discovery precedence by workflow ID: app bundle, `~/.prowl/workflows/*.pwlworkflow`, then
`<repository root>/.prowl/workflows/*.pwlworkflow`. Only app-bundled definitions may use
`prowl.*` IDs. A disabled or invalid bundle cannot start. Loose YAML is not a workflow bundle.
Symlinks, special files, path collisions, more than 8192 entries, and more than 64 MiB are
rejected. File contents, including helpers/assets, contribute to the SHA-256 fingerprint.

## 3. Roles

```yaml
roles:
  author:
    source: current                  # the pane the run was started from (needs a detected agent only if a step messages it — see table)
  reviewer:
    source: launch                   # Prowl starts a new agent for this role
    kind: interactive                # V1: interactive only; `headless` is a reserved V2 value (§12)
    agents: [codex, claude]          # optional allow-list of agent tokens (as in `prowl agents` `type`); omitted = any launchable
    suggest:                         # optional; match an existing enabled profile exactly, or offer to create one
      agent: codex
      reasoning_effort: xhigh
      execution_mode: standard
    bind: ask                        # ask (default) | auto
    placement: split                 # split | tab (default: split)
    direction: right                 # right | left | up | down (split only)
    background: false                # true = do not focus/select the new surface
  partner:
    source: pick                     # an existing detected agent pane in the SAME worktree, chosen at start (CLI: --role partner=p12)
```

| Field | Rules |
| --- | --- |
| `source` | At most one `current` role per workflow. A `current` role must host a detected agent only if the runner will actually **deliver** to it — i.e. at least one `message` step targeting it is not skipped at start (`--skip <step>` / the start sheet's skip option, §9); otherwise a bare shell pane is a valid source (e.g. a context-only handoff). A workflow without a `current` role needs an explicit worktree at start. `pick` roles are chosen from the detected agents of the source worktree at start; a pane already in a run is not offered. |
| `kind` | Only for `launch`. accepts `interactive` only; `headless` is reserved (§12) because no executor/output protocol exists yet. |
| `agents` | Tokens from the detected-agent catalog. Validator warns (not errors) when none is installed locally. |
| `suggest` | Subset of profile preset fields (`agent`, `model`, `reasoning_effort`, `execution_mode`). Never a reference to a profile name or UUID. |
| `bind` | `ask`: the start sheet always shows the role picker (pre-filled). `auto`: the sheet appears only when resolution is ambiguous. |

**Binding resolution** (per `launch` role, at start, in order): remembered local binding
→ enabled profile matching `suggest` exactly → Recommended profile (053 rules) filtered by
`agents` → ask. The memory key is the four-tuple
`(definition scope, workflow id, role, role-requirements digest)` where scope is
`bundle` | `user` | `repo:<repository id>` and the digest is SHA-256 over the canonical
JSON encoding (sorted keys, `agents` sorted, absent keys omitted) of the role's requirement
block `{source, kind, agents, suggest}` — so a change to any requirement invalidates the
memory while prompt-only edits keep it. This paragraph is the single normative definition;
§10 refers back to it. Every candidate, including a remembered binding or a `--role`
override, is re-validated first (exists, enabled, satisfies `agents`, adapter supports a
seeded prompt); a failing candidate falls through to the next tier. The chosen profile is
frozen into the run together with its launch plan; later profile edits do not affect the
run. CLI overrides are source-specific (§9): `--role <launch-role>=<profile name|uuid|auto>`,
`--role <pick-role>=<agent pane: pN | pane UUID>`; `current` roles take no override.


## Typed values and expressions

A workflow is a reusable definition; a run is one execution of it. The worktree is
its execution target (a Git worktree, Prowl workspace, or plain directory). Role keys
are workflow participant names; `display_name` identifies the bound profile or pane.
`observed` contains `exists` and `state`, refreshed for the step. `context.initiator`
contains `pane_id` and nullable `tab_id`, or is null for a worktree-only start.

Read-only namespaces:

| Namespace | Meaning |
| --- | --- |
| `context.workflow` | definition `id`, `name` |
| `context.run` | execution `id`, `path` |
| `context.worktree` | target `id`, `path`, `name`, `branch`, `captured_at` |
| `context.initiator` | original source pane identity, or null for a worktree-only start |
| `context.roles.<role>` | binding `source`, `display_name`, `agent`, `pane_id`, and live `observed` |
| `context.step` | `id`, `iteration` (null outside loops), `captured_at` |
| `context.action` | action-only `execution_id`, `step_id`, `attempt`, `working_directory`, `artifacts_directory` |
| `inputs.<name>` | typed start-time inputs |
| `deliveries.<name>` | agent delivery `path` and nullable `verdict` |
| `actions.<step>` | action `output` object and `output_path` |
| `state.<name>` | explicitly declared, mutable typed state |

Use `{{ expression }}` in text and action inputs. A complete expression in an action input
retains its type; text interpolation accepts scalars, not arrays/objects. No implicit
string-to-number or string-to-boolean conversion occurs. Missing fields are errors;
`exists(deliveries.optional.path)` and `deliveries.optional.path ?? ''` handle absence explicitly.
`exists` does not hide arithmetic/type errors. `&&`, `||`, and `??` short-circuit.

Expressions support null, booleans, numbers, single/double quoted strings, arrays,
field/index access, parentheses, unary `!`/`-`, arithmetic `* / % + -`, comparisons
`< <= > >=`, equality `== !=`, `&&`, `||`, and `??` (listed strongest to weakest).
Functions: `length(value)`, `append(array, item)`, `slice(array, start, end)` (end exclusive),
and `exists(reference)`. Integers must stay within ±9007199254740991; numbers must be finite.
Overflow and division by zero fail. This language does not execute arbitrary code.

## State and control flow

```yaml
state:
  count: {type: integer, initial: 0}
  files: {type: 'array<string>', initial: []}
steps:
  - id: collect
    while: state.count < 3
    steps:
      - id: update
        set:
          count: state.count + 1
          files: "append(state.files, 'README.md')"
      - id: stop
        if: state.count == 2
        then:
          - id: exit
            break: true
  - id: report
    notify: "Collected {{ length(state.files) }} entries"
```

State types: `integer`, `number`, `boolean`, `string`, and nested `array<T>`.
`set` values are **expressions**, evaluated against the same old state and committed
atomically. To assign literal text, use an expression string such as `label: "'ready'"`.
No step implicitly changes state from an action result.

`if` has `then` and optional `else`. `while` has `steps` and optional literal
`max_iterations`. Conditions must be boolean. The loop tests its condition before each
iteration. In a `while` condition, `context.step.id` is the loop ID and
`context.step.iteration` is the number of completed iterations (0 on the first check).
Inside the body, iteration numbers start at 1. If the condition stays true at the cap, the run ends as `iteration_limit_reached`; it does not
report success or execute later steps. For an ordinary counted loop, express the count in
its condition. Omit the cap when the task calls for an unlimited loop.

Nested `break: true` and `continue: true` target the innermost loop. Step IDs are globally
unique. Outputs from a branch or iteration leave scope on exit and are absent at the next
entry. Retain needed values in state **inside** that scope. Roles remain bound across
iterations; launch a role once, then use `message` for repeated work.
Mutually exclusive `if` branches may launch the same role with different prompts. A later
shared step can use the role only if every branch launches it. A later launch is rejected
if any earlier branch could already have launched that role.

For a review loop, retain the initial verdict/path in state, loop while
`state.verdict != 'clean'`, ask the author to address `state.path`, ask the reviewer for a
fresh expected delivery, then update state from that delivery. Do not depend on the last
iteration's output being implicitly visible ; use the declared state and `while` condition.

## Step verbs

Each step has `id`, optional templated `title`, and one verb. Action IDs use
`builtin:<verb-object>` or `local:<verb-object>`: for example,
`builtin:collect-worktree-context` and `local:persist-handoff`. Use verb-first
kebab-case names for actions; dot-separated expressions address data, not actions.

| Verb | Payload and behavior |
| --- | --- |
| `message: role` | required `prompt` (single-line or multiline); waits for the role to be idle before delivery; optional `expect` |
| `launch: role` | `prompt`, optional bundled `skill`, optional `expect`; at most once per persistent role |
| `action: builtin:collect-worktree-context` or `local:id` | typed `with` object; awaits validated result; no `expect`; see [actions](../../skills/prowl-workflow/references/actions.md) |
| `notify: text` | notification |
| `close: role` | closes a launch role's pane; use only when the requested workflow needs cleanup |
| `set` | atomic state assignments |
| `if` | boolean expression, `then`, optional `else` |
| `while` | boolean expression, `steps`, optional `max_iterations` |
| `break: true` / `continue: true` | innermost loop control |


The runner chooses message transport after rendering. A safe single-line prompt whose
complete typed line is at most 4 KiB is injected directly; otherwise Prowl injects a
pane-scoped `workflow read` command. Launch uses the kickoff carrier (128 KiB cap).
Both verbs save only the rendered task body under `prompts/<step>.<ordinal>.md`,
with granted resource references. `prompt_path` identifies that file. Completion
commands are added by the transport and scoped-read response, not stored in the body.
The default read resource is `prompt`. There are no alternate content keys or aliases.

## 5. `expect`

```yaml
expect:
  delivery: findings          # output name; default = step id; the same name may be produced by several steps (latest wins)
  format: markdown          # markdown (default) | text | json (parseable)
  sections: ["## Findings"] # markdown: required headings (fence/preamble stripped before checking, as HandoffStore.validatedBriefing)
  verdicts: [clean, issues]  # declares 2–4 allowed values (safe slugs); the rendered completion command then carries `--verdict <value>` and it becomes mandatory
  timeout: 2h               # optional hard cap; NO default — without it Prowl waits as long as the agent works
  on_timeout: attention     # only with `timeout`: attention (default) | skip | cancel
  strict: false             # default false: a delivery that misses sections/format/verdict is kept as
                            # provisional and the run asks the user; true: it is rejected outright
```

- **Validation is a review gate, not a wall (decision 2026-08-29, [007](007-b2-runner-core.md) H14).**
  `prowl workflow deliver` always rejects what the pipeline cannot use at all — a missing or
  wrong token, an empty body, a body above the size cap. Everything the *author* declared —
  `sections`, `format`, `verdicts` — is checked too, but by default a delivery that misses
  them is **persisted as provisional** (`deliveries/<name>.<ordinal>.md` is written, the CLI
  answers `ok` with `warnings`), the dispatch record stays pending, and the run enters
  `needsAttention` with **Accept as delivered** (or **Accept with verdict …** when a declared
  verdict is missing or not one of the declared values — the user picks one), **Ask again**
  (Prowl types what was missing plus the completion command into the role's pane; the same
  activation and token keep waiting), Skip, and Cancel. Only `strict: true` turns those
  findings into `OUTPUT_INVALID` / `VERDICT_REQUIRED` rejections; use it when a downstream
  consumer needs a machine guarantee (a `json` output read by a tool). Section matching is
  forgiving about heading level and letter case (`### findings` satisfies `## Findings`), but
  a heading inside a code fence never counts.

- **Activation = dispatch (decision 2026-08-29).** Every activation is a record in the shared
  dispatch store (`AgentDispatchStore`, 064-S2): a `launch` step creates it through the
  prompted-launch path, a `message` step through #733's re-dispatch into an existing surface.
  One pending record per surface; it is created only while the role is idle (§4), so exactly
  one runtime turn belongs to it and a `turn-ended` without a delivery is the `incomplete`
  evidence the watchdog consumes (§10). `prowl workflow deliver` resolves the caller pane to that
  pane's current pending record (kernel peer PID + process ancestry, as `dispatch-complete`
  does) and additionally requires the activation token to match — correlation, not trust —
  then validates the body, persists the output, and completes the record. Skip / Cancel /
  Relaunch abandon the record (the reason names run and step). The `run` response and
  `workflow status` expose each activation's dispatch id, so `prowl agents wait --dispatch`
  works on workflow activations too; there is no separate `WorkflowRequestRegistry`.
- **Invocation and activation identity.** Every execution of a `message` or `launch` step
  — once for a plain step, once per iteration inside a loop, again after Relaunch —
  mints a run-global, monotonic **invocation ordinal** (1, 2, 3, … across all steps and
  iterations) on entry, whether or not the step waits; it names the step's artifacts
  (`prompts/<step>.<ordinal>.md`). When the step has an `expect`, the same invocation
  is also its *activation* `(run id, step id, ordinal, delivery role)`: the runner mints a
  fresh delivery token for it, and the previous activation of the same step (if any) is
  terminal. Exactly one successful `deliver` is accepted per activation, identified by its
  token; a later, stale, or token-less delivery gets `STEP_NOT_EXPECTING` /
  `TOKEN_REQUIRED` / `TOKEN_INVALID`. Skip / Cancel / Relaunch revoke the *current*
  activation's token (Relaunch then mints a new invocation/activation). Every delivery is
  persisted as `deliveries/<name>.<ordinal>.md` (collision-free by construction, even when
  several steps produce the same output name); `deliveries/<name>.md` is the "latest" view,
  replaced atomically (temp file + rename); `run.json` records the invocation → step /
  iteration / activation / file mapping.
- Output bodies are capped (16 MiB in both the CLI and App → `OUTPUT_TOO_LARGE`).
- **Skip rule.** Skipping an expected delivery marks its output absent. The runner examines
  remaining expressions, nested control steps, and typed action inputs. A required reader
  ends the run as `skipped`; explicit `exists`/`??` handling permits continuation. Optional
  action schema fields do not implicitly remove missing expressions. The panel shows the
  consequence before confirmation. The validator warns about `on_timeout: skip` consumers.
- Waiting is supervised by the state-driven watchdog (§10), not by wall-clock time; a
  `working` role is never interrupted.


## 9. CLI participant protocol

```bash
prowl workflow list [--json]                                  # sources, enabled, validation status
prowl workflow run <id|name> [source] [--role r=<binding>]... [--input k=v]... [--skip <step-id>]... [--json]   # <binding> grammar is source-specific, see below
                                                              # [source]: 060 GenericTarget (pN | tN | UUID | worktree ref); omitted → caller pane
                                                              # when the workflow has a `current` role (SOURCE_REQUIRED outside a pane), a
                                                              # worktree reference otherwise
prowl workflow status [run-id] [--json]                       # no args: "who am I" — caller pane's run, role, awaited step and its requirements
prowl workflow deliver [-|--file <path>] [--verdict <v>] [--token <token>] [--run <id> --step <id>] [--force] [--json]
prowl workflow cancel <run-id> [--json]
prowl workflow validate <bundle.pwlworkflow> [--json]
prowl workflow schema                                         # JSON Schema / reference for authoring agents
```

**Resolution of `deliver`.** Two independent facts must agree: the **caller pane** (socket
peer PID → process ancestry → shell PID → pane) identifies the run and role, and the
**delivery token** (`PROWL_WORKFLOW_TOKEN` — set in the launch environment for a `launch`
step's activation exactly like `PROWL_DISPATCH_ID`, carried as the typed line's environment
prefix for a `message` step's activation exactly like `PROWL_HANDOFF_REQUEST_ID` today, or
`--token`) identifies the awaited step. Prowl mints the token when the step starts waiting,
embeds it in the typed hint, and
revokes it on Skip / Cancel / Relaunch; a stale or duplicated `deliver` from a pane that has
moved on to another step is therefore rejected instead of misattributed. A pane belongs
to at most one run at a time, so no run/step ids are needed in the typed command. Explicit
`--run --step` is required when no caller pane exists (manual delivery, logged as
`source=manual`, no token needed): it targets the step's *current* activation and is
attributed to that activation's delivery role; if the step is not currently waiting the
result is `STEP_NOT_EXPECTING`. If caller pane and explicit ids disagree,
`ROLE_MISMATCH` unless `--force`. Launched surfaces may additionally carry
`PROWL_WORKFLOW_RUN` / `PROWL_WORKFLOW_ROLE` as a cross-check hint; the dispatch store is the
authority.

**`--role` grammar** (source-specific; duplicate overrides for one role and overrides for
unknown roles are `INVALID_ARGUMENT`; a missing override falls back to binding resolution):

```text
--role <launch-role>=<profile name | profile UUID | auto>
--role <pick-role>=<pN | pane UUID>        # must be a detected agent pane in the source worktree, not in another run (PANE_BUSY), not the current pane
# current roles take no override
```

The `run` response records every frozen binding (launch: profile id/name/agent; pick: pane
id/handle and detected agent).

**`--skip <step-id>`** (repeatable) marks a step skipped at start. It is accepted only for
steps whose `expect` output has no non-optional consumer (§5 Skip rule) — e.g.
`prowl workflow run prowl.handoff --skip brief` is a context-only handoff; anything else is
`INVALID_ARGUMENT` naming the dependent step. The start sheet offers the same choice
("Skip <step title>") for such steps, which is also how a bare-shell pane can start a
handoff.

**Self-initiated runs.** When `run` is invoked from the pane that becomes the `current`
role and the first step is a `message` to that role, the response carries that step's
rendered prompt (or scoped `workflow read` command) and its completion command, and the runner does **not**
also type them into the caller's pane — the caller already has them. For an agent this
makes a self-handoff two commands: `prowl workflow run prowl.handoff`, then the returned
`… prowl workflow deliver -` with its briefing on stdin.

Error codes: `WORKFLOW_NOT_FOUND`, `WORKFLOW_INVALID`, `RUN_NOT_FOUND`, `PANE_BUSY`,
`ROLE_MISMATCH`, `STEP_NOT_EXPECTING`, `TOKEN_REQUIRED`, `TOKEN_INVALID`,
`OUTPUT_INVALID` (empty body; sections/format/verdict only under `strict: true`), `OUTPUT_TOO_LARGE`,
`VERDICT_REQUIRED` (`strict: true` only),
`PROFILE_NOT_FOUND`, `PROFILE_NOT_UNIQUE`, `SKILL_NOT_FOUND`, `RENDERED_TEXT_INVALID`
(a generated protocol line or `--input` value would not survive as one terminal line),
`UNSAFE_PATH`, `PROMPT_TOO_LARGE` (a rendered `launch` prompt above 128 KiB),
`WORKFLOW_DELIVERY_REQUIRED` (`agents dispatch-complete` from a pane whose pending record is a
workflow activation; the message carries the exact `prowl workflow deliver` replacement).
(`AGENT_GONE` and `WAIT_TIMEOUT` belong to the `agents wait` contract, not to
`prowl workflow`.)

Companion primitives for CLI-driven orchestration (same boundaries as the runner):
`prowl create pane <pane> --direction <dir> [--profile <name|uuid> --prompt -]`,
`prowl create tab <worktree> [--profile … --prompt -]`, `prowl profiles list`,
`prowl agents wait <pane> --until idle|blocked|changed|exit [--timeout]`,
`prowl agents wait --dispatch <id>`, `prowl agents dispatch <pane> --prompt -` (#733 — the
re-dispatch that `message` + `expect` rides on), `prowl agents signal`, `prowl send`,
`prowl agents read`. `agents wait` (and `agents signal`) are specified in
[064 agent-completion-signals](../064-agent-completion-signals/000-plan.md); they consume
the typed per-surface observer (`ObservedAgentState`: `snapshot` first, then `changed` /
`removed` / `surfaceClosed`, plus 064's `.signal`), return immediately when the snapshot
already satisfies `--until`, report `source`/`confidence`, and map `removed` /
`surfaceClosed` to the terminal error `AGENT_GONE` (never to `done`) unless `--until
changed` / `exit` was requested.



## Action contract, approval, and records

`prowl.action/v1` manifests declare a name, object-root `input_schema`/`output_schema`, a script
backend (`interpreter`, action-relative `entrypoint`, optional literal `arguments` and inherited
`inherit_env` names), and optional timeout (1s...86400s; default 30s). JSON Schema Draft 2020-12
validates the schema, effective input, and result. Bundle-relative JSON/YAML schema resources
and fragments are supported without network fetching. `$id` overrides are rejected; use local
references and anchors. Defaults remain annotations. `prowl workflow schema --action` exports
the manifest shape. The built-in repository collector uses the same value/schema validator.

A script receives one JSON object on stdin: `protocol`, typed `input`, and `context`. It must
exit zero and emit one schema-conforming JSON value on stdout. Stderr is diagnostic.
Input and stdout each have a 16 MiB limit; stderr has a 4 MiB limit. The serialized
request allows JSON/context overhead up to 96 MiB + 64 KiB; JSON nesting is limited to 64. Base environment:
PATH, HOME, TMPDIR, LANG, LC_ALL; named inherited variables may extend it. Strip PROWL_* control
variables. Set `PYTHONDONTWRITEBYTECODE=1` to keep Python helper imports from writing
bytecode into the fixed bundle. Environment values are not included in request or execution metadata.

Native approval binds canonical source location to the whole content fingerprint. The review
sheet shows source, scripts, changed files (including removals), and permission implications.
Approval does not start a workflow. CLI cannot grant it. A stale displayed candidate cannot be
approved. Changed content or location needs approval again. Runs use fixed copies and verify
integrity before actions; an invalid copy offers cancel only. Retry keeps the approved copy,
creates a new UUID/attempt, and can repeat side effects. It is never automatic.

`builtin:collect-worktree-context` takes optional `root` within the selected worktree and returns an object
with `path` and `branch`. It writes invocation artifacts and has no dependency on shared
handoff files. `local:<slug>` selects only an action from this bundle.

A run directory is `~/.prowl/logs/workflow-runs/<root-name>-<root-hash>/YYYY-MM/<UUID>/`:

```text
definition/                         Fixed bundle copy
run.json                            Status, bindings, typed state, attempts, output references
log.md                              Timeline
prompts/<step>.<ordinal>.md   Rendered task body without completion protocol
deliveries/<name>.<ordinal>.md         Accepted/provisional agent delivery
deliveries/<name>.md                   Latest file view
skills/<skill>/                     Materialized bundled skill
actions/<step>/<execution UUID>/
  request.json
  result.json                       Only after validated success
  execution.json                    Started/final state and failure detail
  stdout.log                        Bounded raw script output, including failed attempts
  stderr.log
  artifacts/
```

The canonical execution root identifies its history bucket; the UTC month is fixed at
creation. Global UUID lookup does not depend on open projects. See
[personal history and retention](018-history-storage-plan.md) for the fixed 30-day
policy, 5 GiB soft budget, 24-hour protection, Keep Run, and complete ZIP export.
Agents use `workflow read` with pane/task attribution for prompts and explicitly
granted output/action resources; ordinary delivery remains `workflow deliver -` on stdin.

Only the current execution UUID may publish an action result. Cancel terminates the owned
process group, escalating after a bounded grace period. App-private process ownership records
use PID plus process start time; restart cleanup skips live owners and stale PID identities.
Repository run records never authorize killing a process. Previous unfinished runs become
`interrupted`, for inspection only, with no resume.

## Built-in and unsupported features

The shipped sample is Repository Context (`prowl.repository-context`). Agent review workflows
are authored from roles, deliveries, typed state, and control flow. There is no global script
registry, remote action download, parallel DSL branch, automatic retry, rollback, or resume.
Headless roles and additional action backends are outside this contract.

`context.initiator` preserves the initiating `pane_id` and `tab_id` (null for worktree-only starts).
`exists(value) && predicate` and `!exists(value) || predicate` support optional data
without requiring a missing value on the short-circuited path.

Place `launch` before a `while` loop. Launch steps inside loops (including nested branches)
are rejected; send `message` to the persistent role for repeated work.
