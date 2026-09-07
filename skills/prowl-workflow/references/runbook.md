# Run Runbook

What happens when a workflow runs, how to observe it, and how to read what it leaves
behind. Commands: `prowl workflow list | run | status | cancel` (see SKILL.md for the
invocation shapes).

## What happens at start

1. **Admission** validates the definition, the source (pane or worktree), inputs, `--role`
   overrides, and `--skip` choices; errors use the codes below.
2. **Binding resolution** picks a profile for every `launch` role: remembered binding →
   enabled profile matching `suggest` exactly → the worktree's Recommended profile filtered
   by `agents` when explicitly constrained → ask. Omit `agents` by default so all qualifying
   profiles remain available; runtime restrictions require a user instruction or a concrete
   task requirement (see [authoring](authoring.md#runtime-constraints-and-preferences)).
   In the GUI, `bind: ask` roles (and any ambiguity or missing required
   input) present the start sheet; `bind: auto` with nothing undecided starts silently. The
   CLI never shows UI; unresolved bindings fail instead — pass `--role r=<profile|auto>`.
3. Chosen bindings and rendered launch plans are **frozen into the run** — later profile
   edits do not affect it. The `run` response (with `--json`) carries the run id and every
   frozen binding.

Static validation checks structure and semantic constraints, not live readiness. Admission
can still fail because a profile or source pane is unavailable, required inputs are missing,
or the CLI cannot reach the intended Prowl instance.

When the caller is the `current` role and the first step messages that role, the `run`
response returns the task directly in `self_initiated` (`.data.self_initiated` in JSON):
`line`, optional `instruction_path`, and `completion`. The agent that invoked `run` must
perform it and deliver; there is no separate injected first message to wait for.

## While it runs

- Steps execute strictly in order; one step is active at a time. A `message` step injects
  only when its target is idle — the run sits in "waiting for role to be idle" while the
  agent works. Nothing is ever typed into a busy pane.
- Without an explicit deadline, the watchdog responds to participant state: a working
  agent is left to work; a turn ending without delivery may lead to a nudge and then
  attention. An explicit `expect.timeout` can expire even while the agent is working;
  its configured policy governs the run, not the lifetime of the agent process.
- Attention states (timeout with `on_timeout: attention`, provisional deliveries under
  `strict: false`, blocked agents) pause the step and surface in Prowl's status center for
  the user to resolve (Accept / Ask again / Skip / Cancel); the CLI sees them in
  `prowl workflow status`.
- Skipping a step makes its output absent. Required downstream references end the run as
  `skipped`; explicit `exists`/`??` handling can permit continuation. The UI shows the
  consequence before confirmation. Nested control expressions and action inputs count too.
- Neither finishing nor `prowl workflow cancel <run-id>` (which revokes all outstanding
  delivery tokens) closes a pane: a `completed` run leaves every launched pane open unless an
  explicit `close:` step (authored by the workflow) closed it.
  Cancelling stops orchestration; it does not stop already-running agent work or undo edits.
- Run states (`status.state`): `running`, `needs_attention` (the panel waits for the user),
  then one terminal state — `completed`, `iteration_limit_reached` (a `while` condition stayed
  true at `max_iterations`; later steps do not execute), `skipped` (required output skipped),
  `cancelled`, or `interrupted` (unfinished in an earlier app instance; never resumed).

Script-bearing bundles require native approval before a start or single-action test. The
CLI cannot approve them. The approved bundle is copied into the run; source edits apply to
future starts and require a new grant. An invalidated run copy must be cancelled. See
[actions](actions.md) for process limits, environment, approval, and per-attempt records.


## Watching a run

For a `deliver --json` response, inspect `.data.delivery.state`: `delivered` is accepted,
whereas `provisional` may still return `ok` and an output path but leaves the run in
`needs_attention`. The user can Accept, Ask again, Skip, or Cancel. **Ask again** returns
the activation to waiting so the participant can submit a corrected delivery; repeated
submissions while it is still provisional are rejected. Under `strict: true`, an invalid
delivery is rejected instead and the participant can correct it while the step is waiting.

`prowl workflow status <run-id> --json` is the poll target (the text form omits timestamps):

- `.data.status.state` — see the states above; `.data.finished_at` is set once the run ended.
  `.data.status.attention` (`reason`, `message`, `step`, `actions`) explains a `needs_attention`.
- `.data.step` — the step in progress; `.data.activation` — the awaited delivery (`step`,
  `role`, `output`, `state` `waiting` | `persisting` | `provisional`, `ordinal`, `deadline`,
  and `expect.completion[]`, the exact commands that complete it).
- `.data.deliveries.<name>` — the latest accepted delivery (`path`, `latest_path`, `ordinal`,
  `verdict`); `.data.bindings` and `.data.run_directory` are frozen at start.
- `.data.started_at` / `.data.finished_at` carry milliseconds; `log.md` and `run.json` round
  to seconds.
- `.data.source` is `live`, or `record` after an app restart (read back from `run.json`: no
  activation, no tokens). Without a run id the command answers for the calling pane only and
  is `RUN_NOT_FOUND` when that pane is not in an active run.

## Reading a run afterwards

Runtime data lives in personal history, outside the execution root:

```
~/.prowl/logs/workflow-runs/<root-name>-<root-hash>/YYYY-MM/<run-id>/
├── log.md                       # timestamped timeline (start here)
├── run.json                     # machine record: bindings, invocations, step states, deliveries
├── deliveries/
│   ├── <name>.<ordinal>.md      # output for an invocation; corrected submissions can replace it
│   └── <name>.md                # "latest" view, replaced atomically on each delivery
├── definition/                  # frozen workflow bundle
├── actions/                     # action results and artifacts
├── instructions/
│   └── <step>.<ordinal>.md      # task instructions and granted resource references
└── skills/
    └── <id>/SKILL.md            # bundled skills named by `launch … skill:` (empty otherwise)
```

- `log.md` records every launch (with the frozen profile and pane id), wait, nudge,
  delivery, loop round, skip, and the final state — it answers "what happened" without
  asking any agent.
- **Invocation ordinals** — `log.md` says `(invocation 4)`, `run.json` lists them under
  `invocations[]` — are run-global and monotonic across all steps and iterations
  (fire-and-forget steps consume them too), so sorting the ledger by number replays the run
  in order. A loop whose condition was false at entry has no executed body records in
  `run.json` with step state `skipped`: the loop was skipped, unrelated to the run's `skipped`
  terminal state.
- `<name>.md` is the newest persisted body of that name, swapped via atomic rename so a
  reader never sees a half-written file. Persistence happens before acceptance: provisional
  bodies appear here too. Corrections after **Ask again** reuse the invocation ordinal and
  replace both files, so this is not an immutable history of every submission. Use the
  delivery receipt and run state to distinguish persisted content from accepted results.
- Output bodies are capped (16 MiB in both the CLI and App).
- To summarize or debug a finished run: read `log.md`, then walk `deliveries/` in ordinal
  order; `run.json` maps each ordinal to its step and loop iteration.

## Where the delivery token travels

Every awaited step mints a fresh token for its activation; Skip/Cancel/Relaunch revoke it.

- **Launched roles**: the token is in the pane's environment as `PROWL_WORKFLOW_TOKEN`, and
  the kickoff prompt's protocol block spells the bare `prowl workflow deliver [--verdict v] -`.
- **Messaged panes** (`current`/`pick`): the token rides the typed line as an environment
  prefix — the command in the `[Prowl] …` line is complete and directly executable.
- Delivery requires the caller pane and the token to agree; a stale, duplicated, or
  token-less delivery is rejected instead of misattributed.

## Common errors

| Error | Meaning / fix |
| --- | --- |
| `WORKFLOW_NOT_FOUND` / `WORKFLOW_INVALID` | wrong id, or the file fails validation — run `prowl workflow validate` on it |
| `SOURCE_REQUIRED` | the workflow has a `current` role and the call wasn't made from a pane — pass a source |
| `INVALID_ARGUMENT` | bad `--input` value, unknown/duplicate `--role`, or a `--skip` on a step another step depends on (the message names it) |
| `PANE_BUSY` | the pane chosen for a `pick` role already belongs to a run |
| `DISPATCH_PENDING` | a `pick` pane still holds a pending `prowl agents dispatch`; complete or abandon it first |
| `TARGET_NOT_FOUND` / `AGENT_NOT_FOUND` | the source or `--role` pane/worktree does not exist, or a `pick` pane hosts no detected agent |
| `RUN_NOT_FOUND` | no such run id, or `status` without an id from a pane that is not in an active run |
| `PROFILE_NOT_FOUND` / `PROFILE_NOT_UNIQUE` | a `--role` override doesn't match exactly one enabled profile |
| `TOKEN_REQUIRED` / `TOKEN_INVALID` / `STEP_NOT_EXPECTING` | delivering without/with a stale token, or the step has moved on — check `prowl workflow status` |
| `OUTPUT_INVALID` / `VERDICT_REQUIRED` / `OUTPUT_TOO_LARGE` | empty body / missing mandatory verdict under `strict` / body over the cap |
| `WORKFLOW_DELIVERY_REQUIRED` | `dispatch-complete` was used inside a workflow activation — run the `prowl workflow deliver` command the error echoes |
| `PROMPT_TOO_LARGE` / `RENDERED_TEXT_INVALID` | a rendered launch prompt over 128 KiB / a rendered line that isn't one clean terminal line — shorten, or move content into an `instruction` |
