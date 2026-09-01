# Run Runbook

What happens when a workflow runs, how to observe it, and how to read what it leaves
behind. Commands: `prowl workflow list | run | status | cancel` (see SKILL.md for the
invocation shapes).

## What happens at start

1. **Admission** validates the definition, the source (pane or worktree), inputs, `--role`
   overrides, and `--skip` choices; errors use the codes below.
2. **Binding resolution** picks a profile for every `launch` role: remembered binding →
   enabled profile matching `suggest` exactly → the worktree's Recommended profile filtered
   by `agents` → ask. In the GUI, `bind: ask` roles (and any ambiguity or missing required
   input) present the start sheet; `bind: auto` with nothing undecided starts silently. The
   CLI never shows UI; unresolved bindings fail instead — pass `--role r=<profile|auto>`.
3. Chosen bindings and rendered launch plans are **frozen into the run** — later profile
   edits do not affect it. The `run` response (with `--json`) carries the run id and every
   frozen binding.

## While it runs

- Steps execute strictly in order; one step is active at a time. A `message` step injects
  only when its target is idle — the run sits in "waiting for role to be idle" while the
  agent works. Nothing is ever typed into a busy pane.
- Waiting is supervised by a state-driven watchdog, not wall-clock: a working agent is
  never interrupted; an agent whose turn ends without delivering gets one typed nudge with
  the completion command; `expect.timeout` (when declared) is the hard cap.
- Attention states (timeout with `on_timeout: attention`, provisional deliveries under
  `strict: false`, blocked agents) pause the step and surface in Prowl's status center for
  the user to resolve (Accept / Ask again / Skip / Cancel); the CLI sees them in
  `prowl workflow status`.
- Skipping a step marks its output missing. A missing output is tolerated only by an
  action's optional `with` input; any other reference (`text`/`instruction`/`prompt`/
  `notify` templates, a `repeat` `until`) ends the run as `skipped` — the consequence is
  computed and shown before the skip is confirmed.
- `prowl workflow cancel <run-id>` revokes all outstanding delivery tokens and never closes
  panes; only an explicit `close:` step (authored by the workflow) closes a pane the run
  launched.
- Run states: `completed`, `max_rounds_reached` (a `repeat` hit `max` with `until`
  unsatisfied — steps after the loop do NOT execute), `skipped`, `cancelled`, plus failure
  states surfaced through the status center.

## Reading a run afterwards

Everything lives under the source worktree:

```
<worktree root>/.prowl/workflow-runs/<run-id>/
├── log.md                       # timestamped timeline (start here)
├── run.json                     # machine record: bindings, invocation map, activations
├── outputs/
│   ├── <name>.<ordinal>.md      # the ledger — one immutable file per delivery
│   └── <name>.md                # "latest" view, replaced atomically on each delivery
└── instructions/
    └── <step>.<ordinal>.md      # materialized multi-line instructions for message steps
```

- `log.md` records every launch (with the frozen profile and pane id), wait, nudge,
  delivery, loop round, skip, and the final state — it answers "what happened" without
  asking any agent.
- **Ordinals** are run-global and monotonic across all steps and iterations (fire-and-forget
  steps consume them too), so sorting the ledger by number replays the run in order.
- `<name>.md` always holds the newest accepted delivery of that name: deliveries are
  serialized, persisted before the run advances, and the file is swapped via atomic rename —
  a reader never sees a half-written or stale-after-advance file.
- Output bodies are capped (1 MiB default, 4 MiB hard maximum).
- To summarize or debug a finished run: read `log.md`, then walk `outputs/` in ordinal
  order; `run.json` maps each ordinal to its step and loop iteration.

## Where the delivery token travels

Every awaited step mints a fresh token for its activation; Skip/Cancel/Relaunch revoke it.

- **Launched roles**: the token is in the pane's environment as `PROWL_WORKFLOW_TOKEN`, and
  the kickoff prompt's protocol block spells the bare `prowl workflow done [--verdict v] -`.
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
| `PROFILE_NOT_FOUND` / `PROFILE_NOT_UNIQUE` | a `--role` override doesn't match exactly one enabled profile |
| `TOKEN_REQUIRED` / `TOKEN_INVALID` / `STEP_NOT_EXPECTING` | delivering without/with a stale token, or the step has moved on — check `prowl workflow status` |
| `OUTPUT_INVALID` / `VERDICT_REQUIRED` / `OUTPUT_TOO_LARGE` | empty body / missing mandatory verdict under `strict` / body over the cap |
| `WORKFLOW_DELIVERY_REQUIRED` | `dispatch-complete` was used inside a workflow activation — run the `prowl workflow done` command the error echoes |
| `PROMPT_TOO_LARGE` / `RENDERED_TEXT_INVALID` | a rendered launch prompt over 32 KiB / a rendered line that isn't one clean terminal line — shorten, or move content into an `instruction` |
