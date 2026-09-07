# `prowl workflow` Contract

## Status

Current version: `prowl.cli.workflow.v1` (docs-ai 063 B1 for `list` / `validate` / `schema`,
063 B3 for `run` / `status` / `deliver` / `cancel`).

`workflow` is the surface of Agent Workflows: it discovers, validates, and describes
`prowl.workflow/v1` workflow bundles, and runs them. `list`, `run`, `status`, `deliver`, and `cancel`
cross the socket; `validate` and `schema` are **local-only** and work with Prowl closed. Every
response uses `command: "workflow"` and one closed `data` object discriminated by `action`.
The run protocol itself (roles, activations, tokens, the two-phase delivery) is specified in
[063 dsl-spec §9](../../063-agent-workflows/dsl-spec.md#9-cli-participant-protocol); this page
is the wire contract.

## Input

```bash
prowl workflow list [target] [--target|--worktree|--tab|--pane <selector>] [--json]
prowl workflow run <id|name> [source] [--role <role>=<binding>]... [--input <name>=<value>]... [--skip <step>]... [--json]
prowl workflow read [resource-id] --run <run-id> --invocation <number> [--offset <bytes>] [--json]
prowl workflow status [run-id] [--json]
prowl workflow deliver (-|--file <path>) [--verdict <v>] [--token <t>] [--run <run-id> --step <step>] [--force] [--json]
prowl workflow cancel <run-id> [--json]
prowl workflow validate <file> [--scope bundle|user|repo] [--json]
prowl workflow schema [--json]
```

Wire request: `command: "workflow"` with `action` (`list` | `run` | `status` | `deliver` |
`cancel` | `read`), `target` (060 selector), and the action's fields — `workflow`, `roleBindings[]`,
`inputValues[]`, `skippedSteps[]` (`run`); `runID` (`status`, `cancel`, `deliver`); `stepID`,
`body`, `verdict`, `token`, `force` (`deliver`). The CLI reads the `deliver` body itself (stdin or
`--file`, UTF-8, at most 16 MiB → `OUTPUT_TOO_LARGE` client-side) and fills `token` from
`--token` or `$PROWL_WORKFLOW_TOKEN`.

### `read` assigned content

The socket request uses `action: "read"`, `runID` (UUID), `invocation` (positive
ordinal), optional `contentResource` (default `instruction`), and `contentOffset`
(default 0). The caller is resolved from socket peer ancestry. There is no read token
and no arbitrary path argument. The pane must own this run and the invocation must
be its role's last assigned task. Skipped/revoked activations and cancelled runs are
rejected. Normal completion preserves the last assignment until reassignment,
history cleanup, or app exit. Attribution is checked again after filesystem I/O.

Successful `data` has `action: "read"`, `run`, `invocation`, `role`, `step`, `resource`,
`body`, `encoding` (`utf-8` or `base64`), `resources` (objects with `id` and `name`),
`offset`, `total_bytes`, and optional `next_offset`. Each page contains at most
256 KiB. Repeat the same run/invocation/resource with `--offset <next_offset>` until
that field is absent. Decode each page independently and concatenate its bytes.
Resources expose assigned skills and explicitly passed output/action artifacts.
A directory resource body is a JSON array of its contained file IDs and names.

Read errors use the usual workflow error envelope:

| Code | Condition |
| --- | --- |
| `SOURCE_REQUIRED` | No caller pane can be resolved. |
| `STEP_NOT_EXPECTING` | Run/invocation does not match the current assignment, the task was skipped/revoked, or attribution changed during I/O. |
| `WORKFLOW_FAILED` | Resource is unknown, history is missing/unsafe/unreadable, or offset is outside the resource. |

Missing required CLI options and malformed numeric options fail argument parsing
before a socket request. Reading never completes a task or delivers an output.

### Sources and precedence

| Scope | Directory | Notes |
| --- | --- | --- |
| `bundle` | `Prowl.app/Contents/Resources/workflows/` | ids `prowl.*` are reserved for this source; includes Repository Context |
| `user` | `~/.prowl/workflows/` | |
| `repo` | `<worktree root>/.prowl/workflows/` | resolved per worktree |

Directories ending in `.pwlworkflow` contain `workflow.yaml` and optional local actions,
helpers, and schemas. Discovery reads bundles in file-name order; loose YAML is not a workflow.
Valid bundles shadow valid bundles by ID (`repo` > `user` > `bundle`). Invalid bundles remain
visible with diagnostics and do not shadow valid definitions.

### `list` worktree resolution

- No selector: the caller's own pane (socket peer ancestry → pane → worktree), then the
  focused worktree. When neither exists the response omits `worktree` and `sources.repo` and
  searches the bundle and user sources only.
- Any selector follows the 060 targeting rules (`TARGET_NOT_FOUND` / `TARGET_NOT_UNIQUE`);
  a pane or tab selector resolves to its worktree.

### `run` source and preflight (063 B3, decisions W2/W4)

The definition is the unshadowed entry with that `id`, or the unique one with that `name`
(`WORKFLOW_NOT_FOUND`; `INVALID_ARGUMENT` names the ids when several share a name). It must
be valid (`WORKFLOW_INVALID`, `details` = the validate payload) and enabled
(`WORKFLOW_DISABLED`).

- **Source.** A workflow with a `current` role binds it to a pane: the caller's own pane when
  no source is given (`SOURCE_REQUIRED` outside a pane), or an explicit pane / tab target
  (`pN`, `tN`, UUID, `--pane`, `--tab`). A workflow without one takes a worktree: the caller's,
  then the focused one, or any worktree target. A worktree target for a workflow with a
  `current` role is `SOURCE_REQUIRED`.
- **Bindings** are frozen before any side effect, in role declaration order. `current`: the
  source pane, which must not belong to another active run (`PANE_BUSY`), must not hold a
  pending dispatch record (`DISPATCH_PENDING`; an activation is a dispatch record and a pane
  holds one at a time — #733 D4), and must host a detected agent when a `message` step to it
  survives the skips (`AGENT_NOT_FOUND`); a bare shell is a valid source otherwise. `pick`:
  `--role <role>=<pN|pane UUID>` is required (`INVALID_ARGUMENT`), inside the source worktree
  (`TARGET_NOT_FOUND`), hosting a detected agent (`AGENT_NOT_FOUND`), not the source pane or
  another bound pane (`INVALID_ARGUMENT`), not in another run (`PANE_BUSY`), not holding a
  pending dispatch (`DISPATCH_PENDING`). `launch`: `--role <role>=<profile name|UUID|auto>`
  (`PROFILE_NOT_FOUND`, `PROFILE_NOT_UNIQUE`), else the remembered binding for the role's
  requirements digest, else a profile matching `suggest`, else the repository's Recommended
  profile; every candidate is re-validated (exists, enabled, satisfies `agents`, its runtime
  accepts a seeded prompt) — a rejected override or remembered binding falls through and is
  noted in the run log; nothing left is `PROFILE_NOT_FOUND`. The profile's launch plan is
  frozen in memory (`WORKFLOW_FAILED` when it cannot be planned); only its id, name, and agent
  reach the record. A `current` role takes no override, unknown roles and duplicate overrides
  are `INVALID_ARGUMENT`.
- **Inputs / skips.** `--input` values are checked against the declared inputs (unknown,
  missing without default, range, enum, single line → `INVALID_ARGUMENT`); `--skip` must name
  a step with an `expect` whose output nothing that can still run requires
  (`INVALID_ARGUMENT` names the dependent step). A worktree path that cannot be rendered on
  one line is `UNSAFE_PATH`.
- **Reply point.** The run directory exists and `run.json` is written before the response;
  the first step is already in progress. A self-initiated first step is answered only once its
  activation record exists (or its opening failed and the run sits in attention), so the
  returned completion command is attributable the moment the caller runs it; nothing was typed.

### `deliver` attribution (decision W3)

1. The caller pane (socket peer ancestry) and its pending dispatch record identify the
   activation; the machine then checks the token (`TOKEN_REQUIRED`, `TOKEN_INVALID`) and the
   body (`OUTPUT_INVALID`, `OUTPUT_TOO_LARGE`, `VERDICT_REQUIRED`). A pane whose record is not
   a waiting workflow activation is `STEP_NOT_EXPECTING`.
2. `--run <id> --step <step>` is the manual path: from outside any pane (else
   `SOURCE_REQUIRED` without it), or from a pane that holds no workflow activation. It targets
   the step's *current* activation without a token; the run must be live (`RUN_NOT_FOUND`), the
   step must be the one waiting (`STEP_NOT_EXPECTING`). The run log records `source=manual`.
3. Both present and disagreeing (the caller pane waits for another step or run) is
   `ROLE_MISMATCH` unless `--force`, which takes the manual path (`source=manual --force`).

The response is sent only after the output reached the run directory (decision W1): a cancel
or skip that lands while it is being written answers `STEP_NOT_EXPECTING`, a write failure
`WORKFLOW_FAILED`; a client that disconnects first sees `REQUEST_CANCELLED` while the run
continues. `agents dispatch-complete` from a pane that owes a workflow delivery is refused with
`WORKFLOW_DELIVERY_REQUIRED` whose message carries the replacement `deliver` command.

### `status` (decision W5)

Without a run id the calling pane must belong to an active run (`SOURCE_REQUIRED` outside a
pane, `RUN_NOT_FOUND` otherwise). With one, a live run is reported from the app; a run the app
no longer holds is read from its `run.json` in personal workflow history (`source: "record"`); neither
is `RUN_NOT_FOUND`. Runs an earlier app instance left `running` / `needs_attention` are marked
`interrupted` when unoccupied runs are recovered; nothing is resumed.

### `validate` scope

`--scope` decides whether a `prowl.*` ID is allowed. When omitted, the bundle location
selects user or repository scope. The path must be an existing `.pwlworkflow` directory
containing `workflow.yaml`; a loose YAML file is not accepted.

### Bundle resolution for skills

`skill:` references are checked against the bundled skill registry resolved exactly as
`prowl skills` does (`PROWL_SKILLS_DIR`, then the executable's app bundle). When no bundle can
be resolved the reference is reported as a `skill_unchecked` **warning** and the file stays
valid; the app-side `list` always has the bundle.

## Success

### `list`

```json
{
  "ok": true,
  "command": "workflow",
  "schema_version": "prowl.cli.workflow.v1",
  "data": {
    "action": "list",
    "worktree": { "id": "…", "name": "main", "path": "/Projects/App", "root_path": "/Projects/App" },
    "sources": {
      "bundle": "/Applications/Prowl.app/Contents/Resources/workflows",
      "user": "/Users/me/.prowl/workflows",
      "repo": "/Projects/App/.prowl/workflows"
    },
    "workflows": [
      {
        "id": "review",
        "name": "Review",
        "description": "…",
        "scope": "repo",
        "path": "/Projects/App/.prowl/workflows/review.yaml",
        "enabled": true,
        "valid": true,
        "errors": 0,
        "warnings": 1,
        "shadowed": false
      }
    ]
  }
}
```

- `worktree`, `sources.bundle`, and `sources.repo` are omitted when they do not apply.
- `workflows[]` is ordered by id (winners first, then shadowed files by scope precedence
  and path); files without an id come last. `id`, `name`, and `description` are omitted when
  the file did not parse or has no description.
- `enabled` is the user's per-definition switch keyed by `<scope>/<id>` (all enabled by
  default; the Settings toggle arrives with 063 D1). A file without an id is never enabled.

### `run` / `status` / `cancel` — the run object

```json
{
  "ok": true,
  "command": "workflow",
  "schema_version": "prowl.cli.workflow.v1",
  "data": {
    "action": "run",
    "id": "0BADCAFE-0000-4000-8000-000000000042",
    "workflow": { "id": "review", "name": "Review" },
    "scope": "repo",
    "definition_path": "/Projects/App/.prowl/workflows/review.yaml",
    "source": "live",
    "status": { "state": "running" },
    "step": "brief",
    "role": "author",
    "worktree": { "id": "…", "name": "feature", "branch": "feat/x", "path": "/Projects/App" },
    "run_directory": "/Users/example/.prowl/logs/workflow-runs/App-<root-hash>/2026-08/0BADCAFE-0000-4000-8000-000000000042",
    "bindings": {
      "author": { "source": "current", "pane": { "id": "…", "tab_id": "…", "handle": "p1", "display_name": "Claude Code", "agent": "claude" } },
      "reviewer": { "source": "launch", "profile": { "id": "…", "name": "Codex", "agent": "codex" } }
    },
    "activation": {
      "ordinal": 1, "step": "brief", "role": "author", "state": "waiting", "dispatch_id": "…", "output": "brief",
      "expect": { "format": "markdown", "sections": ["## Scope", "## Claims"], "strict": false,
                  "completion": ["PROWL_WORKFLOW_TOKEN=… prowl workflow deliver -"] },
      "deadline": "2026-08-30T01:10:00.000Z"
    },
    "deliveries": {},
    "started_at": "2026-08-30T01:00:00.000Z",
    "updated_at": "2026-08-30T01:00:00.000Z",
    "self_initiated": {
      "line": "[Prowl] Read …/instructions/brief.1.md and follow it — finish with: PROWL_WORKFLOW_TOKEN=… prowl workflow deliver -",
      "instruction_path": "…/instructions/brief.1.md",
      "completion": ["PROWL_WORKFLOW_TOKEN=… prowl workflow deliver -"]
    }
  }
}
```

- `source` is `live` (the app holds the run) or `record` (read from `run.json`; then
  `activation` and `self_initiated` are absent and no token is spelled anywhere).
- `status.state` is `running` | `needs_attention` | `completed` | `cancelled` | `skipped`
  (with `step` and `dependent`) | `iteration_limit_reached` | `interrupted`; `status.attention`
  carries `reason` (`needs_input`, `idle_without_delivery`, `blocked`, `agent_gone:<why>`,
  `injection_failed:<why>`, `launch_failed`, `rendered_text_invalid`, `action_failed`,
  `persist_failed`, `delivery_issues`, `timeout`), `message`, `step`, `role`, `ordinal`,
  `actions[]` (the controls C1 will offer), and `issues[]` for a provisional delivery.
- `step` is the step in progress; absent once the run ended. `role` is the *verified* calling
  pane's role when it is bound in the run; only when that pane owns the current activation does
  `activation.expect.completion` spell the completion commands (they carry the token) — a
  worktree-started run, a manual or forced `deliver`, and any other role's pane get an empty list. `activation` is the activation
  waiting for, persisting, or holding a provisional delivery — the one `deliver` can address; a
  step stuck in an injection or launch attention reports none.
- `bindings.<role>.profile` is the frozen profile (id, name, agent) of a `launch` role;
  `bindings.<role>.pane` is the role's pane (`launch` roles gain it once launched).
- `deliveries` is the latest delivered output per name (`name`, `ordinal`, `path`,
  `latest_path`, `verdict`, `delivered_at`).
- `self_initiated` appears on `run` only, when the run started from the pane that is its
  `current` role and the first step messages that role: the runner typed nothing.
- `cancel` returns the run after cancellation (`status.state: "cancelled"`).

### `deliver`

```json
{
  "ok": true,
  "command": "workflow",
  "schema_version": "prowl.cli.workflow.v1",
  "data": {
    "action": "deliver",
    "run": { "…": "the run object above, after the delivery" },
    "delivery": {
      "state": "provisional",
      "ordinal": 1, "step": "brief", "role": "author",
      "output": { "name": "brief", "ordinal": 1, "path": "…/deliveries/brief.1.md", "latest_path": "…/deliveries/brief.md", "delivered_at": "…" },
      "warnings": [{ "code": "missing_sections", "message": "missing section(s) ## Claims" }]
    }
  }
}
```

`delivery.state` is `delivered` (the output is the step's output and the run advanced) or
`provisional` (the body had issues a non-strict step tolerates — codes `missing_sections`,
`unparsable_json`, `verdict_missing`, `verdict_undeclared`, `verdict_unexpected` — it is on
disk and the run is in `needs_attention` until the user accepts it, asks again, or skips;
B3 offers no CLI control for that decision, C1 does).

### `validate`

```json
{
  "ok": true,
  "command": "workflow",
  "schema_version": "prowl.cli.workflow.v1",
  "data": {
    "action": "validate",
    "path": "/Projects/App/.prowl/workflows/review.yaml",
    "valid": true,
    "workflow": { "id": "review", "name": "Review" },
    "diagnostics": [
      { "severity": "warning", "code": "timeout_long", "message": "…", "line": 31, "column": 9 }
    ]
  }
}
```

`diagnostics[]` lists parse diagnostics first, then validation diagnostics; `line` and
`column` are 1-based and omitted when a diagnostic has no position. `workflow` is present
whenever the file parsed. Codes are stable identifiers (`unknown_key`, `undefined_role`,
`message_before_launch`, `until_verdict_literal`, `skill_unchecked`, …) and are the
contract; messages are not.

### `schema`

```json
{
  "ok": true,
  "command": "workflow",
  "schema_version": "prowl.cli.workflow.v1",
  "data": { "action": "schema", "schema": { "$schema": "https://json-schema.org/draft/2020-12/schema", "…": "…" } }
}
```

`data.schema` is the Draft 2020-12 workflow definition schema
(`ProwlCLIContracts/Resources/workflow-definition-schema.json`, `$id`
`https://prowl.onev.cat/contracts/workflow/v1/workflow-definition.json`). In text mode the
schema is printed alone, pretty-printed.

## Errors

| Code | When |
| --- | --- |
| `WORKFLOW_INVALID` | `validate` found at least one error, or `run` named a definition with errors. `details` carries the full validate payload. Exit status 1. |
| `WORKFLOW_NOT_FOUND` / `WORKFLOW_DISABLED` | `run`: no unshadowed definition with that id or unique name; or it is switched off. |
| `WORKFLOW_FAILED` | A source directory could not be read, the run directory could not be created, a profile could not be planned, an accepted output could not be saved, or a payload could not be encoded. |
| `SOURCE_REQUIRED` | `run` of a workflow with a `current` role outside a pane (or with a worktree target); `status` without a run id and `deliver` without `--run --step` outside a pane. |
| `PANE_BUSY` / `DISPATCH_PENDING` / `AGENT_NOT_FOUND` / `PROFILE_NOT_FOUND` / `PROFILE_NOT_UNIQUE` / `UNSAFE_PATH` | `run` preflight, see above. |
| `RUN_NOT_FOUND` | `cancel` / manual `deliver` of a run that is not live; `status <id>` of a run neither live nor recorded; `status` from a pane outside any active run. |
| `STEP_NOT_EXPECTING` / `TOKEN_REQUIRED` / `TOKEN_INVALID` / `ROLE_MISMATCH` | `deliver` attribution, see above. |
| `OUTPUT_INVALID` / `OUTPUT_TOO_LARGE` / `VERDICT_REQUIRED` | `deliver` body validation (dsl-spec §5): empty body, above the cap, or a `strict` step's requirements. |
| `WORKFLOW_DELIVERY_REQUIRED` | `agents dispatch-complete` from a pane whose pending record is a workflow activation. |
| `REQUEST_CANCELLED` / `REQUEST_CONFLICT` | The socket peer disconnected while `deliver` waited for persistence; an in-app request id collision (never expected). |
| `TARGET_NOT_FOUND` / `TARGET_NOT_UNIQUE` | Selector resolution (`list`, `run`). |
| `PATH_NOT_FOUND` / `INVALID_ARGUMENT` | `validate` path is missing or is not a workflow bundle; malformed `--role` / `--input` / `--skip`, conflicting selectors, a non-UUID run id, half a manual target. |
| `APP_NOT_RUNNING` | Any socket action without a reachable app. Never raised by `validate` or `schema`. |

## Verification

`ProwlCLITests/WorkflowDocumentParserTests`, `WorkflowValidatorTests`,
`WorkflowDiscoveryTests`, `WorkflowSchemaTests` (output contract for every action + definition
schema pinned to `WorkflowJSONSchema.definitionSchemaJSON`), `WorkflowCommandParsingTests`,
`WorkflowCommandExecutorTests`, and the `workflow` cases in `ProwlCLIIntegrationTests`
(real `prowl` process for `validate`/`schema`, mock socket for `list` and `deliver`);
`supacodeTests/WorkflowCommandHandlerTests` (worktree / source resolution, enabled set),
`WorkflowRunAdmissionTests` (preflight), `WorkflowRuntimeCoordinatorTests` (`deliver`
attribution, `status`, `cancel`), `WorkflowCLIRendezvousTests`, and `WorkflowRunsFeatureTests`
(the reducer: ordered effects, the two-phase `deliver` answer, late launches, restart scan).
