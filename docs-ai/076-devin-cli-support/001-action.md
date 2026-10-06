# 076 — Devin CLI Support: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-06 | Added runtime, screen detection, exact session ownership, Profiles, workflow delivery, and skill installation. | #813 |
| 2026-10-06 | Moved paste confirmation rules into `AgentComposerProfile`; `prowl send` types directly into Devin menus and drafts again; agent registries are exhaustive switches again. | Post-merge review of #865 |

## Outcome & current state (as of 2026-10-06)

- `DevinRuntimeAdapter` supports model selection, standard and unrestricted modes,
  interactive prompts after `--`, and headless invocation. Profile menus and workflow
  role binding use the existing runtime registry. The tab icon uses the MIT-licensed
  Lobe Icons asset.
- `DevinScreenProfile` identifies working footers, directory trust, selection menus,
  and an empty composer. Each typed rule has a real terminal capture in the fixture
  corpus; retained output has negative regression coverage.
- The classifier selects the native ACP child while preserving launcher identity.
  `DevinSessionProfile` resolves only process-owned lock descriptors. Two sessions
  in one working directory were observed with different exact native session IDs.
- `AgentPromptDelivery` shares composer acknowledgement across supported runtimes.
  `AgentComposerProfile` holds the only per-runtime rules: how to read the input box,
  which paste echo counts, and which purposes wait. Dispatch waits for every readable
  composer. Workflow messages wait only for Devin, which can lose an early Enter.
  `prowl send` with Enter waits for Devin only from an empty composer; it types directly
  into menus and drafts. `WorktreeTerminalState.submitAgentLine` is the single entry.
  Soft wraps inside tokens are accepted only at screen row boundaries. User edits, IME
  input, pane replacement, cancellation, and run fences prevent stale submission.
- Devin retitles its terminal to `devin: <folder>`; the `devin:` icon key covers it.
- The `devin` skill target uses `.config/devin/skills` in the user home and
  `.devin/skills` in a project. CLI schemas and the agent-facing manual include Devin.

## Validation

Devin 3000.11.3 was exercised in an isolated Debug app and scratch repository with
SWE-1.6 Slow. A Profile launched successfully; a two-step workflow delivered exactly
`DEVIN_LAUNCH_OK` and `DEVIN_MESSAGE_OK` and reached Completed. The second message
was submitted automatically. Trust, tool permission, model selection, working,
idle, and same-directory session ownership were observed. The real-model budget
was limited to four short task inputs, including the initial investigation.

Focused regressions cover process ownership, launch arguments, screen history,
lock paths, Profile binding, paste acknowledgement, and cancellation during an
async workflow delivery. All 202 selected app tests passed. CLI validation passed
296 unit tests, 106 integration tests, 8 relay tests, and executable smoke checks.
CLI checks include the native skill target and schema. `make check` passed, including
234 script tests; the Debug app and CLI builds passed.

## Deviations from plan

Immediate paste plus Enter was unreliable in the live CLI. Workflow delivery now
permits an acknowledgement wait and checks its run fence again before Enter. A
cancelled wait may leave an unsent draft. Existing synchronous runtimes retain their
submission behavior.

## Open questions

Native diagnostic logs and database saves do not establish a complete live state
contract. Native `Stop` and `PermissionRequest` hooks precede other hook decisions,
so this integration does not advertise a managed hook channel or native state
provider. Workflow completion remains an explicit Prowl delivery. Account home
relocation and a separate reasoning-effort option remain unsupported until verified.
