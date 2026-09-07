# 063.017 — Action Bundle Implementation Contract

## Status and authorization

Implemented in [PR #774](https://github.com/onevcat/Prowl/pull/774), 2026-09-06. The owner authorized implementation of 015,
delegated the remaining contract decisions, and requested tests, a PR, self-review,
at least two adversarial reviews, real action/workflow verification, and documentation.
This amendment resolves the specification details left open in 015.

## Language decisions

- `prowl.workflow/v1` lives in a `.pwlworkflow` directory with `workflow.yaml`.
  Workflows have never shipped. The owner confirmed that bundles are v1 directly;
  no version migration or compatibility layer is needed. Validation takes the bundle directory.
- JSON values preserve null, boolean, integer, finite number, string, array, and object.
  Integers use the interoperable exact range -9007199254740991...9007199254740991.
  Overflow, division by zero, nonfinite numbers, and implicit coercion are errors.
- `{{ expression }}` preserves the value type when it occupies a complete action input.
  Interpolation into text accepts scalar values only. Missing fields are errors.
- Expressions use literals, field/index access, parentheses, unary `!`/`-`, arithmetic
  `* / % + -`, comparisons `< <= > >=`, equality `== !=`, `&&`, `||`, and `??`, in that
  precedence order. Boolean operators and coalescing short-circuit. `exists` handles
  missing references only. Pure functions include `length`, `append`, and `slice`.
- State declarations use `type` and `initial`; array types use `array<T>`. `set` maps
  state field names to expressions. Assignments evaluate against the same old state.
- `if` uses `then`/`else` step lists; `while` uses `steps` and optional `max_iterations`.
  `break: true` and `continue: true` target the innermost loop. IDs are globally unique.
  Each branch/iteration owns its outputs; leaving that scope removes those values.
  Retention requires an explicit state assignment. Roles remain persistent bindings.
- A `while` condition uses its own step ID and completed iteration count (0 initially);
  steps in the body use 1-based positions. Launch roles before a loop and use `message`
  inside it; static validation rejects repeated launches.
- Interpreter batches yield after at most 64 control steps so cancellation stays responsive.

## Execution and approval decisions

- One bounded JSON object on stdin and one JSON object on stdout; stderr is diagnostic.
  Default timeout is 30 seconds. Stdout limit is 1 MiB, stderr retention 1 MiB, JSON depth
  64, bundle size 16 MiB, and bundle file count 2048. Exceeding a limit is an error.
- Script declarations select a literal interpreter and action-relative entrypoint; optional
  arguments are literal strings. Resolve executable paths before a run starts.
- Base environment contains PATH, HOME, TMPDIR, LANG, and LC_ALL when present. Explicit
  inherited variable names may add values; PROWL_* control variables are always removed.
  Set `PYTHONDONTWRITEBYTECODE=1` to prevent normal Python helper imports from changing
  the fixed bundle. Request and metadata records contain no inherited environment values.
- Each action attempt has a UUID, request/result/metadata/raw stdout/stderr files and an artifacts
  directory. Bounded raw stdout survives malformed JSON and nonzero exit; only validated
  success produces `result.json`. Completions must match that UUID; failures expose manual retry/cancel.
- Script-bearing bundles require native UI approval of canonical source plus SHA-256
  fingerprint. Reject symlinks, special files, and colliding paths. Include helpers/assets.
  Approval cannot be granted through CLI. A reviewed candidate becomes the run's fixed copy;
  verify its integrity before each action. Copied files are owner-read-only. Directories
  retain owner write access for normal run cleanup; content checks detect replacement or
  added files. This is not isolation from code running as the same user. Mutation is an
  integrity failure.
- UI review shows source, changed files, interpreter/entrypoint declarations, and local-user
  permissions. Review and approve are explicit actions. Approval does not start a run.
- Cancellation and timeout terminate the owned process group, then force termination after
  a bounded grace period. Already performed side effects are not rolled back.
- `builtin:collect-worktree-context` writes to invocation artifacts. Legacy handoff CLI remains intact;
  workflow-only handoff actions are removed. Restarted runs are inspection-only/interrupted.

## Validation and delivery

Use focused tests before implementation at each pure boundary, reducer tests for changed
logic, real interpreter tests, CLI build/smoke/unit/integration gates, `make check`, and
`make build-app`. Enable workflow UI by default as requested; retain an explicit `PROWL_WORKFLOW_UI=0`
override. Use a separate Debug verification process with an isolated configuration directory. Keep the user's current app and reviewer sessions running. Record actual evidence
and unresolved limitations, without treating static validation as execution acceptance.

Update bundled definitions, schemas, user documentation, and workflow skills in the same PR.
Review findings must focus on plan coverage and practical UX/correctness, with verified
regressions fixed red-to-green and summarized in PR comments.

## Bounded implementation decisions

- Limit expressions to 256 tokens as well as 16 KiB and 64 nested levels. This also
  bounds the depth of flat operator trees.
- Reject output aliases that shadow an outer scope; explicit state assignments retain
  selected values across scopes without losing the outer result.
- Support bundle-local JSON/YAML schema references, without network resolution or `$id`
  base changes.
- `test-action --input-json` transports literal JSON; only workflow `with` uses expressions.
- Track owned subprocess groups in app-private storage with PID and process start time.
  On startup, recover groups whose owner no longer exists; never trust a repository PID.
- Keep the existing handoff collector intact. Native `builtin:collect-worktree-context` uses the same cancellable
  process transport as scripts so workflow cancellation does not block on synchronous git.

## Delivery and acceptance

The implementation includes shared typed parsing/evaluation, the scoped interpreter,
bundle snapshots and native approval, cancellable script/native backends, invocation
records, CLI action testing, Settings/start review, shipped Repository Context, and the
workflow authoring/action references. Self-review and adversarial review corrections are
recorded in the PR; regression fixes use test-first evidence.

The full app suite, focused workflow/reducer suites, CLI gates, lint, and Debug build pass.
Live verification completed Repository Context and a repository-context → agent task →
repository-context workflow with an accepted output. Installed shell, Python, and Ruby
probes exercise the production process transport. Three custom actions cover inventory,
report artifacts, and verification; their bundle validates and their scripts execute through
the process transport. Unapproved workflow and single-action starts reject admission.

Native approval and the approved custom-action workflow passed live verification on
2026-09-06. The review sheet displayed the bundle files, interpreter entrypoints, source,
and permission scope. Approval did not start a run; closing review enabled Run on the
existing start screen. Starting there completed repository context, file inventory, two
report iterations, state retention of the second report, and report verification. All five
action invocations succeeded; the verifier returned six lines and `valid: true`. Approved
CLI single-action testing also completed. Approval was performed through the native UI.

The earlier unattended UI access limitation was resolved with Computer Use targeting the
exact Debug app path. One source-list selection used a screenshot-based physical click;
no product or accessibility code changes were required. Run records and screenshots are
retained in the local validation archive, and the acceptance results are recorded in #774.
