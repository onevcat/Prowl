# 063.019 — Workflow Naming

Status: implemented and verified 2026-09-07.

## Scope

Normalize the unreleased workflow language, action protocol, CLI, schemas, examples,
skills, and design references before D3. No compatibility aliases or data migration.
This change does not implement handoff migration, new context collectors, or review workflows.

## Contract

- Workflow identifies a definition; run identifies one execution; worktree identifies its target.
- `context.workflow.id` and `name` describe the definition. `context.run.id` and `path`
  describe the run. Keep `context.worktree` and `context.step`.
- Rename `context.source` to `context.initiator`. Role bindings expose `display_name`
  and `pane_id`; retain `source`, `agent`, and `observed`.
- Action-only context is `context.action`, with `execution_id`, `step_id`, `attempt`,
  `working_directory`, and `artifacts_directory`.
- Agent submissions are deliveries: `expect.delivery`, `expect.verdicts`, and
  `deliveries.<name>.path|verdict`. Actual submitted verdicts stay singular.
- Actions return `actions.<step>.output` and `output_path`. Script manifests retain
  `input_schema` and `output_schema`; inherited environment names use `backend.inherit_env`.
- Action identifiers use `builtin:<verb-object>` or `local:<verb-object>`.
  Rename the existing collector to `builtin:collect-worktree-context`; its current
  single-Git-directory behavior remains unchanged. Broader collection belongs to D3.
- Participant submission is `prowl workflow deliver` and socket `command: workflow` with `action: deliver`.
  Retain `run`, `status`, `read`, `cancel`, and `test-action`.
- The terminal loop-limit state is `iteration_limit_reached`.

## Verification

Add parser, expression/runtime, command/schema, and retired-name rejection coverage.
Check active source, shipped resources, documentation, and skills for stale names.
Keep deliberate rejection fixtures distinguishable from supported examples.
Run CLI build/smoke/unit/integration, relevant App workflow tests, `make check`, and
`make build-app`. Complete three sequential reviews with the neighboring Pi agent;
fix confirmed findings before each next review. Publish a non-draft fork PR.

## Outcome

Implemented the contract across runtime contexts, native action requests, expression
validation, delivery persistence, CLI routing/payloads, published schemas, bundled
examples, localized authoring prompts, documentation, and shipped skills. Removed the
unused legacy template renderer; tests now inspect the context produced by the runner.

Three sequential adversarial reviews were completed. Confirmed corrections included
the actual script-request execution ID, obsolete names hidden in optional expressions,
local action ID syntax, stale reference examples, and naming-check false positives on
custom data. Each confirmed issue received a fix and relevant regression coverage.
The third round's optional quoted-key/whitespace coverage was also added.

Validation passed: `make check` (150 script tests), CLI build and smoke checks, 291 CLI
unit tests, 112 CLI integration tests, 3147 App tests, and `make build-app`. Native-action
tests decode the actual `request.json`; the expression tests distinguish optional
availability from valid namespace spelling.

`make check-workflow-naming` is a lightweight source/reference regression check, not
a complete YAML parser or semantic validator. It exempts explicit historical records
and the old-to-new mapping in this document. Runtime parsing and bundle validation
remain authoritative; custom input and output schemas do not reserve retired words.

D3 remains separate: the renamed collector still requires one Git directory, and no
handoff migration or additional collector was implemented.
