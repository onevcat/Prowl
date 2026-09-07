> Historical slice record. For executable definitions and current names, use the
> [DSL specification](dsl-spec.md) and [019 naming contract](019-workflow-naming.md).
> The old substitution renderer and dedicated handoff actions described below have been removed.

# 063.006 — Workflow Definitions (B1): Plan

## Status

Implemented on `feat/workflow-definitions-b1` (2026-08-29); PR [#740](https://github.com/onevcat/Prowl/pull/740). Owner decisions were settled
in a grill session on 2026-08-29 (below) after a re-read of [dsl-spec.md](dsl-spec.md) against what
R1 shipped; the spec's §4/§5/§9/§10/§12 were amended in #738. The "Delivered" section records
what landed and where it deviates from the scope below.

## Context

R1 delivered the primitives the runner needs (A1/A2 launch boundary, 064-S1 observer, S2
dispatch receipts, S3 hooks on all eight tier-A runtimes, 065 bundled skills), but the DSL
exists only as a spec. B1 makes it concrete: a file can be parsed, validated, and listed, and
authoring agents get a machine-readable schema. Nothing runs yet — B2 (runner core) and B3
(wiring, `run/status/deliver/cancel`) follow, with #733 re-dispatch landing before B3.

The spec was written before S2/S3 shipped. Re-reading it against `main` surfaced one
structural overlap (the `expect` completion channel duplicated the dispatch model) and a few
stale rules; those are settled here so B2/B3 do not inherit them.

## Decisions (grilled with onevcat, 2026-08-29)

| # | Decision | Alternatives rejected |
| --- | --- | --- |
| G1 | **Activation = dispatch.** A workflow activation is a record in `AgentDispatchStore`: `launch` steps create it through the S2 prompted-launch path, `message` steps through #733's re-dispatch into an existing surface. `prowl workflow deliver` resolves the caller pane to its current pending record (peer PID + ancestry, as `dispatch-complete`), requires the activation token to match (correlation only, never trust), validates the body, persists the output, completes the record. `agents wait --dispatch` works on activations. No `WorkflowRequestRegistry`. | A parallel registry + token protocol as first drafted (two "one pending task per pane" mechanisms with drifting semantics). |
| G2 | **Definitions live in `ProwlCLIShared`.** Model, Yams decoding, validator, JSON Schema, and three-source discovery are compiled into both the CLI and the app; `prowl workflow validate` / `schema` run without the app; `list` needs the app (enabled state, worktree-scoped repo source). | App-only parsing with every subcommand over the socket (authoring agents and CI could not validate without a running Prowl; Settings and CLI could not share one validator). |
| G3 | **Watchdog is exact-signal-first and ships in B2** (064-S5's watchdog part moves from D2). `needs-input` → attention immediately; `turn-ended` without delivery → `turn_grace` 15 s (floor 5 s, re-check at expiry) → one nudge → `idle_grace` 3 min → attention; heuristic rules only without a channel. | Heuristic-only watchdog in B2, exact signals retrofitted in D2 (pure rework: hooks already cover all tier-A runtimes). Shorter `turn_grace`: the detector still needs 2 s of heuristic stability plus poll/event skew, and OpenCode can fire `session.idle` twice. |
| G4 | **`launch.prompt` may be multi-line** (A2's `PROWL_LAUNCH_PROMPT` carrier; NUL rejected; 32 KiB cap → `PROMPT_TOO_LARGE`); materialization stays for `message` only. The runner appends the workflow protocol block instead of S2's dispatch block; `dispatch-complete` against an activation fails with `WORKFLOW_DELIVERY_REQUIRED` carrying the exact replacement command. | Keeping the one-line rule; treating a stray `dispatch-complete` as a body-less completion (the step would advance with a missing output). |
| G5 | **`message` injects only into an idle role** (`waitingForRole`). The shipped signal set has no `turn-start`, so a mid-turn injection makes the next `turn-ended` belong to the previous turn and trips S2's `incomplete` rule; the CLI's #733 refusal is the same rule without an observer. Input queueing is assumed to work on every runtime but is not the deciding factor. | Queue semantics as first drafted, with "ignore the first `turn-ended` after injecting into a working role" (real races around Codex's late `turn-ended`). A `turn-start` signal is the V2 path to early injection. |
| G6 | **B1 includes `prowl workflow list`** over the socket, reading a hidden enabled set (`@Shared`, everything enabled until D1's Settings page adds the toggle), so the slice has an app-side surface for the end-to-end pass. | Local `validate`/`schema` only, `list` deferred to B3 (a library-only slice verifiable by unit tests alone). |

## Scope

Owned by 063; nothing here changes 064 code.

- **Yams** as a SwiftPM dependency of `ProwlCLIShared` (`Package.swift`) and of the app target
  (xcodeproj package reference). Pin an exact version. First third-party dependency in the
  Shared directory: remember that Shared sources are also app sources, so no helper may
  collide with an app symbol.
- **Model** (`supacode/CLIService/Shared/WorkflowDefinition.swift` and neighbours):
  `WorkflowDefinition` (schema, id, name, description, icon, inputs, roles, steps), role
  sources `current | launch | pick`, launch requirements (`kind`, `agents`, `suggest`, `bind`,
  `placement`, `direction`, `background`), step verbs (`message`, `launch`, `action`, `notify`,
  `close`, `repeat`), `expect`, inputs (`integer`, `string`, `enum`). Decoding through Yams
  into `Codable` types; unknown keys are errors (spec §7).
- **Validator** (`WorkflowValidator`): every error and warning listed in spec §7, including
  template-variable whitelist checks, producer-dominates-consumer for `deliveries.*` /
  `actions.*` / `roles.<r>.pane`, `repeat` rules, verdict/`until` consistency, slug patterns,
  `skill:` resolution against the bundled registry (`ProwlSkills`, 065), and the
  "spells `prowl workflow deliver`" warning. Diagnostics carry YAML line/column where Yams
  provides them.
- **Action registry (schemas only)**: the V1 native actions `handoff.transition`,
  `handoff.checkpoint`, `git.context` declared with their typed `with` inputs and output keys
  so the validator and `schema` can check references. Execution comes with B2.
- **JSON Schema** (`prowl workflow schema`): generated from the model, checked in under
  `docs-ai/013-prowl-cli/contracts/` beside the CLI output schema, pinned by a test so the
  two cannot drift.
- **Discovery** (`WorkflowDiscovery`): bundle (`Prowl.app/Contents/Resources/workflows/`,
  absent until the first bundled definition ships with D2 — discovery tolerates a missing
  folder) < user (`~/.prowl/workflows/*.yaml`) < repo (`<root>/.prowl/workflows/*.yaml`);
  `prowl.*` ids reserved; repo overrides user for the same non-reserved id. The repo source is
  resolved per worktree by the app.
- **CLI** (`ProwlCLI/Commands/WorkflowCommand.swift`): `prowl workflow validate <file>
  [--json]` and `prowl workflow schema` execute locally (same shape as `SkillsCommandExecutor`);
  `prowl workflow list [--json]` goes through the socket to a `WorkflowCommandHandler` that
  merges discovery with the enabled set. Output contract `prowl.cli.workflow.v1` with a
  `data.action` discriminator (as `prowl.cli.skills.v1`), errors `WORKFLOW_NOT_FOUND`,
  `WORKFLOW_INVALID`, `INVALID_ARGUMENT`.
- **Enabled set**: `@Shared` app storage of *disabled* `(scope, id)` pairs — opt-out, so a
  new file is enabled by default; no UI (D1).
- **Docs**: `docs/components/cli.md` gains the three commands; contract page
  `docs-ai/013-prowl-cli/contracts/workflow.md`; `cli-output-schema.json` updated. The
  `prowl-cli` skill is not taught these commands until B3 makes `run`/`deliver` real (same rule as
  064.012 B1: never name unshipped commands to agents).

### Non-goals

`prowl workflow run/status/deliver/cancel`, the runner and watchdog (B2/B3), Settings › Workflows
(D1), bundled definitions and skills (`prowl.handoff`, `prowl.adversarial-review`; D2/D3),
the `Resources/workflows` staging in the Makefile (ships with the first bundled definition).

## Test plan (red first)

- Decoding: the §4 example decodes to the expected model; unknown key, wrong type, and
  duplicate step id fail with positioned diagnostics.
- Validator: one test per §7 error and warning; producer-dominance cases (reference before
  producer, inside vs outside `repeat`); `repeat.max` literal/template bounds; verdict set
  size and `until` literal membership; slug patterns for every id class; `skill:` unknown id.
- Schema: generated JSON Schema equals the checked-in file (drift guard); the §4 example
  validates against it with a JSON Schema validator in the test.
- Discovery: precedence and reserved-id rules over temp directories; missing bundle folder
  tolerated; repo scope resolved from a worktree root.
- CLI: `validate` / `schema` executor tests (JSON and text), `list` socket round trip with a
  stubbed handler, contract schema conformance for every payload shape.

## Verification (2026-08-29, all run)

- Red first: the parser and validator suites were written against the spec and failed on
  the first run for real reasons (`MappingReader` double-reported a non-mapping document,
  `notify`/`close` rejected `expect` as an unknown key instead of `expect_not_allowed`, the
  minimal fixture lacked a trailing newline, catalog ordering put an invalid repo file
  before the valid user winner, `JSONEncoder` escaped `/`); each fix is pinned by the test
  that caught it.
- Gates: `make check` (swift-format, SwiftLint strict, 44 script tests), `make build-cli`,
  `make test-cli-unit` (194), `make test-cli-smoke`, `make test-cli-integration` (106, four
  new `workflow` cases: real `prowl` process for `validate`/`schema`, mock socket for `list`),
  `make build-app`, and the full `make test` (2671 passed, 0 failed) including
  `WorkflowCommandHandlerTests` (6) and the router test.
- Live, against an isolated Debug instance of this build (`CFFIXED_USER_HOME` scratch home,
  own `PROWL_CLI_SOCKET`, a scratch Git repo opened with `prowl open`, the bundled CLI from the
  copied app; script kept in the session scratchpad as `e2e/b1-live.sh`):
  `workflow list --json` from outside any pane resolved the focused worktree and listed the
  repo `demo` as the winner, the user `demo` as shadowed, the user `prowl.mine` and the repo
  `prowl.adversarial-review` as invalid (reserved id; `skill_not_found` against the real
  bundle, which ships only `prowl-cli`), and an unparsable `broken.yaml` as `(unparsed)`;
  `list main` and `list <pane UUID>` resolved the same worktree; `list nope` returned
  `TARGET_NOT_FOUND`; the bundled CLI's `validate --scope bundle` on the §4 example failed
  only on the unbundled skill (a `swift build` CLI reports `skill_unchecked` instead, as
  documented); `validate` on the broken file returned `WORKFLOW_INVALID` with a positioned
  `yaml_syntax` diagnostic; `schema` printed the definition schema; and `prowl send` of
  `workflow list --json` into the pane resolved the **caller's own pane** to the worktree
  without any selector. The instance was ended with SIGKILL — quitting through AppleScript
  hit a two-minute AppleEvent timeout, which is unrelated to this slice.
- A crash report that arrived during this verification (`ProwlApp-2026-08-29-112626.ips`)
  belongs to a different isolated instance: its binary UUID matches the #733 worktree build
  (`apps/new`), launched before this slice's E2E started. It was handed to that branch for
  investigation.

## Delivered

- **Yams 6.2.2** pinned exactly in `Package.swift` (`ProwlCLIShared` and the test target) and as
  an `XCRemoteSwiftPackageReference` on the app target. Every new Shared declaration is
  `nonisolated` because the app target defaults to MainActor isolation — the first two app
  builds failed on exactly that, and on an `Equatable` conformance of `WorkflowInput` that
  pulled in `TargetSelector`'s main-actor conformance (dropped; the input needs no equality).
- **Model + parser** (`WorkflowDefinition.swift`, `WorkflowDocumentParser.swift`): Yams
  `compose` into a positioned `Node` tree read by `MappingReader` / `SequenceReader`, so every
  diagnostic carries the YAML line/column (1-based) and unknown keys are errors. Plain scalars
  are typed (`max: 5` is an integer, `max: "5"` a string); durations are `\d+[smh]`; `until` is
  parsed into `(output, values)`; `repeat.max` keeps either the literal or the raw template.
  Structural rules that the spec lists under validation but that need no cross-reference
  (`kind: headless`, `expect` on `action`/`notify`/`close`, nested `repeat`, `launch` inside
  `repeat`, missing `max`) are parser diagnostics, so a file with them yields no definition.
- **Validator** (`WorkflowValidator.swift`): one `Walker` pass in document order with a
  `repeat`-scoped action table; `deliveries.*` references need an earlier producer anywhere
  (loop bodies included), `actions.*` references need a producer in the same or an enclosing
  sequence, `roles.<r>.pane` needs the role launched, `loop.index` needs a loop, `loop.count`
  a loop before or around. `until` accepts a producer before the loop or inside its body (the
  pre-entry check then simply reads "not satisfied"; B2 owns that rule). Warnings:
  `skill_unchecked` (no bundle), `unknown_agent` / `agents_not_installed` (only when the
  catalogs are supplied), `timeout_long`, `spells_completion_command`, `skip_ends_run`,
  `direction_ignored`. Diagnostic codes are the contract; messages are not.
- **Action registry** (`WorkflowActionRegistry.swift`): `handoff.transition`,
  `handoff.checkpoint`, `git.context` with typed inputs/outputs for the validator and schema.
- **JSON Schema** (`WorkflowJSONSchema.swift` + `ProwlCLIContracts/Resources/
  workflow-definition-schema.json`): hand-written Draft 2020-12, `oneOf` per step shape and
  per role source, loop steps exclude `launch`/`repeat`; a test pins the resource to the Swift
  constant and validates the spec example (via Yams → JSON) plus six structural negatives.
- **Discovery** (`WorkflowDiscovery.swift`): `WorkflowSources` (bundle/user/repo URLs),
  per-directory `files`, and `catalog` with precedence and shadowing; the bundle directory
  (`SupacodePaths.bundledWorkflowsURL`) is absent until D2 and tolerated.
- **CLI** (`WorkflowCommand.swift`, `WorkflowCommandExecutor.swift`,
  `OutputRenderer+Workflow.swift`): `validate <file> [--scope]` and `schema` local;
  `list [target]` over the socket with `WorkflowInput { action: list, target }` and the new
  `Command.workflow` case. An invalid file returns `ok: false` / `WORKFLOW_INVALID` with the
  validate payload in `error.details` and exit status 1; text mode prints
  `path:line:column: severity[code]: message` lines and an `OK` / `INVALID` summary.
- **App** (`WorkflowCommandHandler.swift`, router + `supacodeApp` wiring): caller pane →
  focused worktree → explicit selector resolution, then discovery with the bundle's skill ids,
  the `DetectedAgent` catalog, and the availability probe as `installedAgents`. The enabled
  set is `UserGlobalSettings.disabledWorkflowIDs` (`<scope>/<id>`, sorted, deduplicated;
  opt-out so new files are enabled).
- **Contracts and docs**: `cli-output-schema.json` gained `workflowResponse` (+ nine defs),
  `docs-ai/013-prowl-cli/contracts/workflow.md`, the coverage row in `schema.md`, and a
  `prowl workflow` section plus error rows in `docs/components/cli.md`. The `prowl-cli` skill
  is unchanged until B3.

### Deviations from the scope above

- `list --json` reports `errors` / `warnings` counts only; diagnostics stay with `validate`
  (the second open item, resolved as the default).
- No app-side `installedAgents` when the availability probe has not run yet (nil skips the
  warning rather than reporting everything as not installed).

## Review

Adversarial review with a `Pi Reviewer` Profile in a split beside the implementing pane
(`prowl create pane … --profile "Pi Reviewer" --prompt -` → `agents wait --dispatch`, briefs
and findings under `/tmp/prowl-b1-review/`), read-only and SwiftPM-only so it could run beside
the app builds.

- **Round 1 — 7 findings, all real, fixed test-first in `51460efe`.** P0: a duration such as
  `9223372036854775807h` overflowed `amount * 3600` and trapped the CLI (now
  `multipliedReportingOverflow` → `timeout_syntax`). P1: `handoff.transition`'s `from`/`to`
  were free strings (now `WorkflowActionInput.Kind.role`, literal declared roles only). P1:
  output metadata accumulated monotonically — a later producer without a verdict still let
  `{{ deliveries.x.verdict }}` validate, and outputs first produced inside a loop with `until`
  stayed visible after a loop that may run zero times (now per-producer tracking with
  `latestVerdicts`, and `foldSkippableLoopOutputs` after a skippable loop). P2: `steps: []` and
  `id: 1` passed the parser but not the published schema (`steps_empty`, `strictText`); a tab
  passed `isSingleLine` (all C0/C1 controls rejected now); the "no enabled profile matches
  `suggest`" warning had no data (`WorkflowValidationContext.enabledProfiles`, fed by the app);
  an unreadable source directory listed as empty (discovery throws → `WORKFLOW_FAILED`).
- **Round 2 — 1 P1 + 4 P2, all real, fixed test-first.** P1: `until` intersected every producer
  in the loop body although only the body's final delivery is read after an iteration (now the
  final in-body producer plus the folded pre-loop `latestVerdicts`, which also fixes a later
  skippable loop reading a skipped loop's historical producer). P2: folding dropped
  `on_timeout: skip` metadata (`skipOutputs` tracked apart from the output table); blank
  `name`, agent tokens, and enum values were accepted against the schema's `minLength`
  (`name_empty`, `agent_token_empty`, `enum_value_empty`); a directory or dangling link named
  `*.yaml` was listed as `unreadable` (discovery keeps regular files and links to them only).
- **Round 3 — 3 P2, all real, fixed test-first in `90bd561b`.** `skip_ends_run` ignored
  reader order (now `OutputUse{ordinal, loopID}`: a reader after the skip, or anywhere in the
  same loop body including the loop's `until`, blocks; an earlier reader does not); a FIFO
  named `*.yaml` passed the regular-file check (`FileAttributeType.typeRegular` after
  resolving links); `until`/`timeout` trimmed surrounding whitespace the schema rejects.
- **Round 4 — 1 P2 (grammar only), fixed test-first.** `parseUntil` accepted non-slug output
  names and `==` values that the schema's `until` pattern rejects; the validator caught them
  semantically (`until_output` / `until_verdict_literal`), so behavior was safe but the
  parser and schema grammars differed. The parser now uses the schema's slug tokens. Nothing
  at P0–P1 remained after round 2; the loop is closed here.

## Open items

- The `Resources/workflows` staging (Makefile + folder reference) ships with the first
  bundled definition (D2); discovery already tolerates the missing folder.
