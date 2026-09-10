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
- CLI and persisted activations name their delivery with `delivery`. CLI delivery
  receipts expose `record`; the schema definition is `workflowDeliveryRecord`.
  Persisted skipped dependencies use `skipped_deliveries`.
- Delivery diagnostics use `delivery_shadowing` and `delivery_name_slug`.
- The terminal loop-limit state is `iteration_limit_reached`.

## Prompt contract follow-up (2026-09-09)

Implemented: `message` and `launch` both require `prompt`. Remove `message.text`,
`message.instruction`, and `WorkflowMessageContent`; reject the retired YAML fields.
There are no aliases, migrations, or old-record compatibility requirements.

The runner chooses transport after rendering: short, safe single-line messages may be
injected directly; other messages use the pane-scoped read command. Launch keeps its
kickoff transport. `expect` alone determines whether the runner waits for a delivery.
Persist task-only bodies under `prompts/<step>.<ordinal>.md`; expose `prompt_path`
and the `prompt` read resource. Completion guidance stays in the transport protocol,
not in the saved task body. Update schemas, bundles, templates, tests, authoring skills,
and maintained design references together.

History details use execution-time target snapshots, rendered notification bodies,
condition outcomes, and each action execution's saved request. They never reconstruct
past inputs from current variables or associate an old attempt with a relaunched pane.

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

### Fourth review follow-up (2026-09-08)

The fourth review confirmed the previous fixes and found one remaining required
scanner correction: nested custom keys could replace the outer exemption scope,
and a sequence mapping beginning with `with` was not recognized. The checker now
retains the outer key indentation and ends the exemption at its actual siblings.
Regression cases cover reordered step keys, nested schema properties, and a real
sibling expectation that must still fail. Additional probes cover spaced custom
paths and a custom field named `max_rounds_reached`.

Flow-style YAML declaration scanning remains an optional coverage gap. The runtime
workflow/action parsers reject those retired declaration keys; the lightweight
repository check does not parse all YAML syntax. No new runtime/schema/reference
naming defect was confirmed in the fourth review.

### Delivery contract follow-up (2026-09-08)

Implemented: complete delivery naming in CLI and persisted records. Use
`activation.delivery` for the delivery name, `delivery.record` for its record,
`skipped_deliveries` for skipped-name dependencies, and `workflowDeliveryRecord`
for the JSON schema definition. Rename delivery-specific diagnostics and internal
helpers. Correct active CLI examples to bundle paths. No aliases or migration.

Encoded-key assertions and retired-shape rejection cover CLI payloads and persisted
records. Validation passed: CLI build/smoke, 291 CLI unit tests, 112 integration tests,
3147 App tests, and `make check` with 152 script tests. The original serialization
assertions failed before the implementation changed. Final App build passed.
