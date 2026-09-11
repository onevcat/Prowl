# 063.020 — Additive Handoff Workflow

Status: Superseded by workflow-only handoff retirement; original additive implementation was reviewed and accepted in Debug (PR #786, 2026-09-08).

## Legacy retirement plan (2026-09-10)

The owner has approved complete retirement of the hardcoded Handoff feature. `prowl.handoff`
is now the only Handoff entry point and replaces the legacy CLI protocol, HUD, command-palette
and agent-row entry points, request correlation, and dedicated receiver-launch path. Remove
those definitions, handlers, payloads, schemas, error codes, UI/reducer state, tests, user
docs, and bundled-skill instructions with a non-executing `HANDOFF_RETIRED` CLI migration stub, but no forwarding command.

Keep the shared durable artifact boundary: `HandoffStore`, the save/checkpoint portion of
`HandoffCoordinator`, session-context capture used by `builtin:save-handoff`, history
containment for `.prowl/handoff/`, and the native workflow action. Existing artifacts remain
readable by those retained boundaries. Replace current documentation and skills with the
workflow run/start instructions; historical records retain their original additive account and
are explicitly superseded rather than rewritten.

Validation must prove that `prowl workflow` exposes and runs `prowl.handoff`, no executing
legacy handoff protocol or hardcoded UI action remains, generic profile context injection continues
to work, and archive/save behavior stays covered. The one-release `prowl handoff` stub must emit
`HANDOFF_RETIRED` without socket or filesystem side effects. Run the normal app and CLI gates,
plus a best-effort isolated Debug workflow check.

## Legacy retirement result (2026-09-10)

Implemented the workflow-only boundary. The legacy `prowl handoff` subcommand parser, command
envelope, socket handler, v2 response schema/payload renderer, and old execution error codes are gone. The hardcoded
HUD, its injected shell request and registry, Agents-popover and Active Agents handoff entries,
and Command Palette row are removed. There is no forwarding or compatibility execution path; one release retains a non-executing `HANDOFF_RETIRED` CLI migration stub.

`HandoffStore` remains the durable local archive/context store, but its saved session model is
now an internal store type rather than a CLI payload. `HandoffCoordinator` retains only the
validated checkpoint operation used by `builtin:save-handoff`; the workflow runner continues to
capture source-pane session context for that action. History containment for `.prowl/handoff/`
and pre-existing artifacts remain unchanged.

Current manuals and bundled skills now direct users to `prowl workflow run prowl.handoff`, its
save-only input, and the workflow start surfaces. The CLI manual documents the one-release
non-executing `HANDOFF_RETIRED` migration message. This document's original additive instructions
below are historical and superseded by this section.

Final retirement validation passed on 2026-09-10: CLI build and smoke, 218 CLI unit tests, and
104 CLI integration tests (including the retired command against an unavailable socket); `make
build-app` completed with zero warnings; and `make check` passed formatting, SwiftLint, Python,
and workflow naming checks. After the final store/coordinator simplification, `make test`
passed 3155 main tests and two process tests with zero failures. Independent review found no
required fixes.

An isolated final Debug build used a separate data directory and socket. At 1200- and
1000-point widths, the Agents popover showed the built-in Handoff under Run a workflow,
without the dedicated Hand Off action. Selecting it opened the workflow start surface.
This check used a plain shell, not a detected agent; it did not run an inference-backed
handoff or repeat Shelf/Canvas acceptance. Local evidence is under
`build/verification/legacy-handoff-recovery/` and `build/verification/legacy-handoff-retirement/`.

## Scope and authority

Add one built-in, `prowl.handoff`. Keep the existing handoff HUD, CLI, and execution
path. Do not add `prowl.handoff-checkpoint`, retire legacy commands, or publish a
release. This owner decision supersedes the migration scope of the earlier D3 plan.

## Infrastructure assessment

The runner already provides explicit deliveries, self-initiated first messages,
profile launch, scoped content access, action records, and retry/cancel attention.
HandoffStore and HandoffCoordinator already preserve briefing, generated context,
archives, and session excerpts across Git worktrees, workspaces, and plain directories.
Reuse these boundaries instead of adding a file-operation library or another launcher.

Two small gaps remain: a reusable action to persist a workflow briefing, and profile
admission for a launch branch disabled by immutable start inputs. The latter must agree
between the CLI, start sheet, and machine. Unknown/runtime-dependent conditions remain
conservative; do not predict runtime state or execute actions during admission.

## Workflow

1. The current agent writes a briefing with Objective, Current State, and Next Steps.
   This is the first step so self-initiated runs receive the delivery contract directly.
2. A native `builtin:save-handoff` action validates the briefing and saves it with
   repository/session context under `.prowl/handoff/`, using the existing storage core.
   Keep an immutable, run-specific handoff copy for the receiver, separate from mutable
   `current.md` and expiring workflow history. Validate inputs before writing shared state.
3. An input selects saving only or launching a receiver (default). Launch uses the normal
   profile picker and workflow launch path, without runtime restrictions or pane closure.
   The receiver reads the saved packet and continues the recorded task. Workflow completion
   means the packet was saved and the optional receiver launched, not that its task is done.
4. Report the saved artifact through the workflow result/notification.

Do not require a receiver profile in save-only mode. Preserve unrelated role constraints;
prune only launch roles proven unused by immutable inputs or explicit step skips.
Use the existing surface-specific session capture through dependency injection.

## Validation and review gates

Use failing behavior tests before fixes: artifact validation/archiving, immutable packet,
non-Git/workspace roots, save-only profile admission, launch selection, self-initiated
briefing, and action failure/cancel boundaries. Run CLI build/smoke/unit/integration,
relevant App tests, make check, and make build-app.

Self-review plan coverage and unnecessary complexity before opening a non-draft PR.
Then request at least two adversarial review rounds from the neighboring Pi pane. Verify
findings, reproduce real issues, and add regression tests before fixes. Record each round
on the PR; continue while P0/P1 or major-UX P2 issues remain.

After the review gate, use an isolated Debug instance for actual Codex/Pi scenarios:
self-initiated and GUI starts, save-only, receiver continuation, and relevant failure
handling. Check the packet, receipt, run state, and receiver behavior. Finally reconcile
component/CLI documentation and the shipped workflow skill with the observed behavior.

## Implementation and self-review

The shipped bundle uses the existing delivery and launch steps. `WorkflowHandoffAction`
reuses `HandoffCoordinator.makeCheckpoint`; its receiver packet is built from the save's
own values rather than mutable shared files. The generic role requirement calculation is
shared by admission, machine startup, and the native start sheet. Runtime expressions keep
both branches eligible. No profile/runtime allow-list, new launcher, or legacy migration was
introduced.

Self-review checked the approved additive scope, first-step self-initiation, archive lifetime,
source-session capture, optional profile selection, and failure-before-write boundaries.
Focused tests cover Git/plain storage, preserved old briefings, immutable packets, rejected
external/invalid/symlink inputs, both admitted paths, and reducer session capture. Existing
HandoffStore tests cover workspace collection; existing runner tests cover cancellation.
The normal local `workflow validate` command treats files as user scope and correctly rejects
reserved IDs; the shipped bundle is tested with bundle-scope discovery instead.

Before PR: CLI build, smoke, unit (225 XCTest plus 69 Swift Testing), and integration
(112 tests) passed. The initial app core run passed 137 tests; focused follow-ups passed
25 and 53 tests. Bundle/role tests passed four tests. `make check` passed. External review
and live acceptance are tracked separately below when complete.

## Adversarial review

PR #786 received two reviews from the neighboring Pi session. Round 1 confirmed one P2:
the CLI guide section was accidentally placed inside a delivery heredoc. A focused Markdown
boundary check reproduced the failure; 58c29416 corrected it and the same check passed.
Round 2 verified the fix and found no new issues. The P0/P1/major-UX P2 gate is clean.
No runtime code changed during review. Both rounds are recorded on the PR.

## Debug acceptance and documentation

The isolated Debug instance used the matching checkout CLI and `/tmp/prowl-self-verify.sock`.
Native AX inspection showed that selecting `save` hides the Receiver picker and keeps Run
enabled. A GUI-started Codex save-only run completed with only an author binding, no new
pane, and a durable briefing/session packet. A self-initiated Codex-to-Pi run then completed;
its log confirms that the first instruction returned to the caller instead of being typed.
Pi read the packet, created the exact requested receipt, and preserved the input file. The
source pane stayed open and the receiver launched in the background. The previous packet
remained byte-for-byte unchanged.

A third live run submitted a briefing without required sections. It returned `OUTPUT_INVALID`;
cancellation produced no delivery/action output, no new receiver, and no changes to the shared
handoff files (verified by hashes). Component, CLI, and shipped skill documentation now
reflect these observed paths and distinguish workflow completion from receiver task completion.

Verification friction was environmental: the installed CLI lacked `workflow read`, so agents
used the matching Debug CLI; AX key delivery could not raise the window, while semantic
Agents-menu/start-sheet actions worked. After all test tabs closed, AX window re-discovery
failed. All created panes were closed and the isolated process was stopped; local evidence
and its temporary directory entry were retained. No UI metadata repair was warranted.

## Receiver focus amendment

The owner requested `receiver.background: false` after initial acceptance. The receiver now
opens in a new tab and takes focus; the source remains open. The earlier Debug evidence above
records the original background behavior, not a live verification of this amendment. Both
launch and save-only still require a detected source agent to author the briefing. Admission
rejects a missing source pane or bare shell before the run starts.
