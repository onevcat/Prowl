# 076 — Devin CLI Support: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-10-06 |
| **Related** | #813, [agent state providers](../068-agent-state-providers/000-plan.md) |

## Background

Devin CLI runs in Prowl but has no process classification, screen rules, or launch
adapter. The installed CLI is 3000.11.3. A short local task verified its trust
prompt, working footer, permission choices, and idle composer.

## Goals

- Detect manual and Profile launches, with an identifiable tab icon.
- Support model selection, standard and unrestricted permission modes, interactive
  prompts, headless invocation, and the existing workflow launch/delivery path.
- Classify live working, blocked, and idle screens without matching retained output.
- Resolve native sessions from process-owned lock descriptors, including concurrent
  sessions in one directory. Preserve the launcher identity when selecting its ACP child.
- Add focused regression tests and current user documentation. Verify a real Profile
  and workflow with a small number of model calls because the account has limited usage.

## Design / Approach

Extend the existing runtime and detection registries. Use a dedicated screen profile
with stable rule identifiers and bounded, composer-relative matching. Devin's prompt
must follow `--`; bare positional values open Desktop in this CLI version. Explicitly
render `--permission-mode auto` or `dangerous`. Reasoning effort is part of the model
identifier, not a separate verified option.

The native ACP process holds `~/.local/share/devin/cli/session_locks/<id>.lock` open.
Use the existing descriptor resolver, without scanning the shared transcript directory
or treating leftover lock files as active sessions.

## Alternatives & decisions

- Do not infer live state from session database writes or diagnostic timing spans:
  neither provides a complete, process-scoped state contract.
- Do not advertise managed completion hooks yet. `Stop` runs before other hooks can
  prevent stopping, and `PermissionRequest` runs before hook permission decisions.
  Prowl workflow and dispatch completion continue to require explicit delivery.
- Do not relocate the account through `--config`: it overrides user configuration,
  not all credentials and session storage. Preserve existing user configuration.
- Reuse the runtime-neutral workflow engine; no Devin-only workflow execution path.

## Validation

Use failing-then-passing logic tests, recorded screen shapes and negative cases,
native lock-path tests, and existing Profile/workflow regressions. Run `make check`,
the relevant app tests, and `make build-app`. Keep raw experiments outside the repo.
Exercise a small live workflow to validate readiness, prompt delivery, and receipts.

## Amendments

- Updated 2026-10-06: Live paste testing found that immediate Enter can be consumed
  before Devin accepts the draft. Reuse the existing composer acknowledgement helper
  for Devin dispatch, send, and workflow messages. The workflow delivery boundary becomes
  async and rechecks its run fence before Enter; cancellation may leave an unsent draft.

- Updated 2026-10-06: Devin also wraps inside tokens. Paste acknowledgement accepts
  missing spaces only at rendered row boundaries, while preserving within-row text
  and edit-revision checks. See [001-action.md](001-action.md).
