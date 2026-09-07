# 063.015 — Action Bundles, Execution Context, and Control Flow

| | |
| --- | --- |
| **Status** | Implementation follows the accepted decisions and [017](017-action-bundle-implementation.md) |
| **Date** | 2026-09-05 |
| **Related** | [Workflow plan](000-plan.md), [current V1 specification](dsl-spec.md), [release order](release-plan.md) |

## Objective and scope

The owner redirected the current work from handoff migration to the workflow execution
foundation. Actions provide programmable, non-LLM operations; workflows become self-contained
bundles with typed data, shared context, conditional execution, and unbounded loops. Handoff
will later consume these general capabilities instead of dedicated handoff actions.

This is a proposed replacement for the affected V1 language surfaces, not a claim about
current behavior. The existing runner, profile launch, delivery, and status UI remain reusable.
The owner authorized implementation on 2026-09-06 and delegated the remaining decisions. Do not expand R2b release
scope silently: action/language work now precedes handoff, with release assignment reassessed
when the implementation slices are agreed.

## Accepted decisions

- Directory bundles use `.pwlworkflow`; user actions are private to their containing bundle.
  No independently distributed actions, plugin manager, registry, or version dependency solver.
- Two execution backends: scripts using installed interpreters, and Prowl-owned Swift built-ins.
- Remove `handoff.transition` and `handoff.checkpoint` from the workflow action surface.
- No user-format compatibility or migration layer. Update repository fixtures, examples, and
  authoring documentation together with the new language.
- Approve the entire script-bearing bundle in native Prowl UI. Approval binds source location
  and content fingerprint, is stored outside the bundle, and cannot be granted by CLI/agents.
- Execute with the local user's OS permissions. No sandbox or read-only/network restrictions
  are promised. Environment inheritance is explicit; internal Prowl identity tokens are removed.
- Bundle changes require renewed approval for new runs. Existing runs and retries use their
  approved fixed copy. Approval does not automatically restart a blocked invocation.
- Ordinary inputs, selected worktree, and runtime context changes do not require reapproval.
- Context belongs to the entire workflow, available to templates and actions alike. Separate
  frozen bindings from dynamic observations; use one snapshot per step evaluation.
- Explicit typed state and atomic `set`; pure expressions; nested conditionals and loops with
  optional iteration limits. Missing outputs are errors, never implicit nulls or stale values.
- No automatic retry, rollback, restart continuation, or breakpoint recovery. Persisted records
  support inspection only; interrupted runs do not resume after application restart.
- Sequential step scheduling and state mutation. A launch/message without `expect` advances
  after successful launch/injection; agent work may overlap. Actions await completion.

## Current implementation and gaps

| Existing boundary | Consequence for this work |
| --- | --- |
| `WorkflowActionRegistry.swift` declares three fixed actions; input/output transport is `[String: String]` | Introduce JSON values, contract resolution, and backend dispatch |
| `WorkflowRunMachine.swift` identifies action completion by step ID | Add invocation identity for loop iterations/retries and reject late results |
| `WorkflowRunsFeature.swift` lets a started native action finish after cancellation, discarding results | Add a cancellable action lifecycle suitable for child processes |
| `WorkflowDiscovery.swift` reads loose YAML files | Discover and validate directory bundles and their private actions |
| `WorkflowSettingsClient.swift` watches discovery directories | Watch relevant bundle contents and invalidate diagnostics/approval on edits |
| `WorkflowTemplateRenderer.swift` returns strings and fixed-depth references | Add typed evaluation and a unified read-only context namespace |
| `WorkflowRunStore.swift` already stores run logs and versioned agent outputs | Extend with approved definitions and per-action execution artifacts |
| `ShellClient.swift` supports process cancellation, but stdin is empty and parent termination is the main mechanism | Reuse appropriate patterns; do not assume it already meets JSON/process-group requirements |
| `Package.swift` already uses `swift-json-schema` for tests | Evaluate the pinned library for shared runtime validation; do not invent another schema validator |

These filenames refer to the existing files in `supacode/CLIService/Shared`,
`supacode/Domain/Workflow`, `supacode/Features/Workflow/Reducer`, and the corresponding clients.
The exact dependency wiring and cancellation mechanics remain implementation work.

## Bundle and action contract

Proposed layout (new paths, not existing resources):

```text
handoff.pwlworkflow/
  workflow.yaml
  actions/
    collect-context/
      action.yaml
      main.py
      helpers.py
  assets/
    briefing-guide.md
```

`workflow.yaml` is the only workflow manifest; no additional package manifest. The package is
an ordinary directory suitable for source control. Discovery retains app/user/repository scope
and the reserved `prowl.*` workflow namespace. Local action IDs derive from action directories;
references are explicit: `local:collect-context` versus `builtin:collect-worktree-context`.

Use `prowl.workflow/v1` for the bundle workflow and `prowl.action/v1` for action declarations.
The owner confirmed on 2026-09-06 that workflows have never shipped: define the bundle format
as v1 directly, without version migration or compatibility behavior.
A script declaration names a literal interpreter and bundle-contained entrypoint; input values
never become shell command fragments. Fixed arguments may be supported, without expression
interpolation into executable selection. Resolve and record the interpreter at run preparation;
missing interpreters fail preflight. No interpreter/dependency installation or dynamic Swift
library loading is included.

```yaml
schema: prowl.action/v1
name: Collect Context
input_schema:
  type: object
  properties:
    include_untracked: { type: boolean }
  required: [include_untracked]
  additionalProperties: false
output_schema:
  type: object
  properties:
    summary_path: { type: string }
    changed_files: { type: array, items: { type: string } }
  required: [summary_path, changed_files]
  additionalProperties: false
backend:
  type: script
  interpreter: python3
  entrypoint: main.py
timeout: 30s
```

Input/output roots are JSON objects; nested JSON data is allowed. Validate schemas at package
load, effective inputs before invocation, and outputs before publishing them. Resolve schema
references only within the package or embedded dialect resources; validation performs no network
requests. Schema defaults are annotations, not hidden input mutation. An omitted optional field
remains absent unless the workflow explicitly supplies it. Built-ins share this contract and
result validation, even though their transport is an in-process Swift call.

## Script protocol and execution records

One JSON request on stdin, followed by EOF; exactly one JSON result on stdout; diagnostics on
stderr. Exit zero plus valid schema-conforming output is success. Nonzero exit, malformed JSON,
output mismatch, timeout, and cancellation remain distinguishable. JSONL/progress events are
not part of the initial protocol. The following is illustrative, not a finalized field schema:

```json
{
  "protocol": "prowl.action/v1",
  "input": { "include_untracked": true },
  "context": {
    "workflow": { "id": "prowl.handoff", "name": "Handoff" },
    "run": { "id": "...", "path": "..." },
    "action": {
      "execution_id": "...", "step_id": "snapshot", "attempt": 1,
      "working_directory": "...", "artifacts_directory": "..."
    },
    "worktree": { "id": "...", "path": "...", "name": "..." }
  }
}
```

Each invocation gets a unique execution ID and directory, including repeated loop steps and
manual retries. Proposed run layout:

```text
<run-id>/
  definition/                         # approved package copy
  deliveries/                            # existing agent delivery files
  actions/<step-id>/<execution-id>/
    request.json
    result.json
    execution.json
    stderr.log
    artifacts/
```

Bound stdout, stderr, JSON depth/size, and artifact handling; concrete limits belong in the
implementation contract. Drain both pipes without deadlock. Cancellation/timeout terminates the
owned process group with a bounded grace period; do not promise control over deliberately
escaped descendants. Every completion is correlated to its execution ID. Do not publish partial
or cancelled outputs. Side effects already performed cannot be undone by cancelling.

Failure enters attention with manual retry/cancel. Retry creates a new attempt and retains
previous evidence, using the same approved package and a fresh dynamic context snapshot.
Effective inputs are evaluated and recorded for each attempt against its step-entry state.
No other workflow step updates state while this step is pending. A retry is not exactly-once
execution; successful side effects may already have happened before a failure was reported.

## Approval and execution integrity

Approval is a native Prowl UI action after creation or before first execution. Show package
source, executable entrypoints/interpreters, local-user execution permissions, and reviewable
contents. After changes, show added/modified/removed files and explicitly say prior approval
no longer applies. CLI returns an approval-required result and a route to open the UI; there is
no `--yes`, environment override, or package-declared approval. Read/validate/discover operations
never execute code. Action test commands follow the same approval policy as workflow runs.

Hash the full bundle using deterministic file ordering, normalized relative paths, and file
contents. Account for any file metadata that affects execution, or normalize it when copying.
Reject symlinks, special files, and ambiguous/colliding paths in the first implementation.
Approval binds canonical source location and fingerprint, not merely a workflow ID. The record
lives in Prowl-owned application storage and is never exported with the bundle.

Create the candidate run copy, verify its fingerprint, and run only an approved copy. Original
package edits do not affect active runs. Verify executable-package integrity before later action
invocations as well: an earlier script must not silently alter another script in the run copy.
Store artifacts separately from approved code. Treat code mutation as an integrity failure,
not a normal retry. OS read-only permissions and checks are defense against accidental or
opportunistic mutation, not isolation from arbitrary code running as the same user.

Approval covers the package's behavior over runtime inputs. It does not pin external programs,
interpreter libraries, workspace files, or network responses. No sandbox guarantee or protection
against a compromised same-user account is claimed. Pure built-in packages need no script
approval; script-bearing packages require approval even when one current branch skips a script.

Environment policy: provide an explicit base environment and declared extra variable references;
strip pane/workflow/dispatch control tokens. Resolve credential values from local configuration,
never bundle literals. Do not record secret values in request/metadata. A script can itself print
or return secrets, so unrestricted script output is not guaranteed secret-free; logging and
redaction policy must say what it actually covers.

## Unified context and typed references

`context` is workflow-wide, not an action-only API. The same step snapshot feeds condition
and template evaluation and the action request. Proposed groups:

- `context.workflow`: definition identity and name; frozen for the run.
- `context.run`: run identity and path; frozen for the run.
- `context.worktree`: fixed target identity/path plus timestamped dynamic branch observations.
- `context.initiator`: original initiating pane/tab identity, nullable for worktree-only starts.
- `context.roles`: frozen profile bindings plus current pane existence and agent observations.
- `context.step`: current step/invocation/loop position and snapshot capture time.
- `context.action`: action-specific `execution_id`, `step_id`, `attempt`, `working_directory`, and `artifacts_directory`, only available
  during an action invocation; other steps cannot reference it as though it existed.

The action process has no terminal pane. Never impersonate a source/role pane as the script's
own identity. Keep the target worktree fixed even if the user changes GUI focus. Dynamic data is
an observation, not a guarantee that a pane, branch, or file stays unchanged after capture.
Do not attach full Git diffs, terminal text, transcripts, or all Prowl worktrees by default;
expensive data remains an explicit action/CLI query. Final field names and the exact cheap
observation set require a schema review before implementation.

Replace V1's parallel `run.*`, `worktree.*`, `roles.*`, and loop references with their documented
`context.*` equivalents. Keep `inputs.*`, `deliveries.*`, `actions.*`, and `state.*` distinct.
An action exposes `actions.<step>.output` (typed JSON) and `actions.<step>.output_path` (a file).
A whole-value reference in `with` preserves JSON type. String interpolation accepts scalars,
not implicit serialization of objects/arrays. Complex agent inputs should use result files.

## State, expressions, conditionals, and loops

Accepted state types are deliberately simple: boolean, integer, number, string, and explicitly
typed arrays. No custom object types, unions, implicit conversions, or full JSON Schema syntax
for state declarations. Initial values are required and type checked. Exact numeric ranges,
array nesting, and literal syntax remain to be specified rather than inherited accidentally
from Swift/JSON decoding.

A `set` evaluates every right-hand side against the same pre-update state, validates all
assignments, and commits them together. Unknown fields, mismatched types, and failed evaluation
cause a diagnostic with no partial state update. Only `state` is mutable through DSL assignment.

Expressions are parsed into a typed AST, not shell/Python/JavaScript `eval`. Support field/index
access, arithmetic, comparisons, short-circuit boolean operators, and a small explicit set of
pure functions. `exists`/null-coalescing handle intentionally absent values; they must not mask
unrelated runtime errors. No file, network, clock, randomness, or process access in expressions.
Define numeric overflow, equality, precedence, and array/string operations before implementing.

Support nested `if`/`else`, `while`, `break`, and `continue`. Test `while` before each iteration;
omitting an optional iteration cap means no fixed count limit. A configured cap is a visible
limit-exceeded outcome, not successful completion. Break/continue target the innermost loop;
using them outside one is invalid. Step IDs remain globally unique within the definition;
execution IDs distinguish their repeated invocations. Remove the V1 prohibition on nested
control flow, without silently permitting repeated launch of one role: roles remain persistent
run bindings. Repeated work uses `message` to an already launched role; launching it twice is
an error. Dynamic role creation is outside this first design.

Strict result lifetime is accepted: an unexecuted branch has no outputs, and a new loop iteration
cannot inherit the prior iteration's deliveries. Cross-iteration retention requires `set`. Outer
scope results remain available to inner scopes; retain per-invocation history on disk even when
values leave evaluation scope. Static validation rejects definite unavailable references, while
runtime checks handle branch-dependent availability. Never inject an empty string or reuse stale
results to make a template work.

Theoretical completeness requires more than an infinite loop. The intended language can express
state transitions, branching, and unbounded iteration, with growable data structures in its
abstract model. A minimal pure array operation set must support constructing and consuming state
(e.g. stack push/pop), not merely inspecting fixed input arrays. Real execution is memory bounded;
do not claim a formal completeness proof or turn this goal into an arbitrary-eval escape hatch.
Cancellation must remain responsive even in a loop containing only `set`/conditions: execute
bounded interpreter batches and yield to the scheduler, rather than recurse synchronously forever.

## Scheduling, completion, and interruption

| Step | When the next step may start |
| --- | --- |
| Agent message/launch with `expect` | Accepted explicit delivery |
| Agent message/launch without `expect` | Successful injection/launch, not agent task completion |
| Action | Successful execution, output validation, and persistence |
| Set/control flow | Successful evaluation and atomic state/control update |

There are no parallel DSL branches or parallel action steps. Agents launched without `expect`
can work concurrently, and different runs remain independent. This is sequential scheduling,
not a promise that the worktree cannot change concurrently. No unawaited step contributes a
workflow output. Per-step snapshots/state do not lock external files or other agents.

Persist records/state for inspection, with no resume/replay engine. After application restart,
unfinished work is interrupted and cannot continue from a checkpoint. Do not infer whether an
external side effect finished just because its result was not recorded. Process crash cleanup
and visible interruption diagnostics need explicit tests; durable recovery is excluded.

## Removal, integration, and implementation slices

Remove the two handoff action declarations, dispatcher branches, JSON schema entries, and
associated workflow-only fixtures/docs. Do not delete HandoffStore/HandoffCoordinator code
still used by the shipped legacy HUD/CLI. Extract reusable repository snapshot collection for
`builtin:collect-worktree-context`; save to the current invocation's artifacts, never shared handoff paths.
Old loose YAML and removed-action definitions receive specific unsupported-format/action errors,
not silent fallback or a compatibility runner. No migration command is planned.

1. **Language contracts:** package/action/context schemas, JSON values, typed references, simple
   state types and expression grammar; review end-to-end examples before execution code.
2. **Interpreter:** scoped outputs, conditions/loops, atomic set, invocation identity, sequential
   scheduling, yielding/cancellation and typed diagnostics; tests use fake action/agent clients.
3. **Bundle and approval:** discovery, recursive change observation, review UI, approved copies,
   fingerprint invalidation, CLI approval-required responses, and source integrity tests.
4. **Backends and records:** shared validation, built-in snapshot action, script protocol,
   interpreter resolution, process cleanup, limits, explicit environment and per-attempt evidence.
5. **Authoring and integration:** bundle creation/open/reveal, action test entrypoint, schema/CLI
   diagnostics, bundled resources, skills/manuals, and real backend plus GUI E2E verification.

Mandatory regression cases include altered helpers/assets/manifests, source edits during a run,
run-copy mutation, CLI approval bypass refusal, malformed/oversized output, child pipe pressure,
cancel/timeout/late completion, unknown/missing data, short-circuiting, branch skips, nested loop
lifetimes, state type errors and atomic updates, unlimited-loop cancellation, and agent overlap
without `expect`. Run installed sh/Python/Ruby probes without installing interpreters. Verify the
actual app bundle contains definitions/actions and native UI is the only approval grant route.

## Remaining specification work

Interview-level direction is accepted. Before coding, consolidate exact expression syntax,
numeric semantics, context field schemas, loop scope/reset rules, diagnostic codes, process/output
limits, built-in cancellation behavior, and the review UI into an implementable contract. These
are explicitly unresolved details, not permission to choose conflicting semantics silently.
The owner reviews this consolidated proposal before implementation begins.
