# Authoring Prowl Workflows

Full reference for writing `prowl.workflow/v1` files. The JSON Schema from
`prowl workflow schema` is authoritative for field shapes; this file adds the rules a
schema cannot express and the patterns that work. Validate every draft with
`prowl workflow validate <file>` — it is static, strict, and fast, and its errors carry
line numbers.

## Minimal example

A single launched worker and one awaited result need no reviewer loop or current-pane
role. The task is a required start-time input; the selected worktree supplies the context.

```yaml
schema: prowl.workflow/v1
id: myteam.task
name: Run a Task
inputs:
  task: { type: string, prompt: "What should the worker do?" }
roles:
  worker:
    source: launch
steps:
  - id: work
    launch: worker
    prompt: "{{ inputs.task }}"
    expect: { output: result }
```

`expect` keeps the run waiting for the worker's explicit delivery. There is no imposed
deadline or automatic pane closure; the user can inspect the worker afterwards.

## Execution and data flow

Steps advance sequentially, but a `launch` or `message` without `expect` advances once
delivery to the pane succeeds, not once the agent finishes its work. Put an `expect` on
work whose completion or output a later step needs. A terminal that looks idle is not
an accepted workflow result. Give each producer a clear deliverable and each consumer
the corresponding output path; headings and verdicts should match what consumers need.

All roles operate in the run's worktree. Concurrent workers share its files, so use
independent work or explicit file ownership when they edit. V1 has no per-role worktree
isolation. Parallel work uses separate launches and explicit result collection, not an
invented `parallel` or `wait-all` verb.

V1 has no arbitrary shell/script step, general `if`/`when`, nested loops, headless roles,
or templated access to JSON output fields. A worker can perform task work described in
its prompt; the YAML itself only has the verbs and template paths documented below.
Use `skill` only for an id confirmed in the installed bundle; it is not a local file path
or an arbitrary skill name. A `skill_unchecked` warning means that availability was not
verified, not that the named skill exists.

## Worked example: review loop

One existing agent, one launched reviewer, a verdict loop, and inputs, for a task that
specifically calls for repeated review. No runtime is required, so the launch role omits
`agents` and `suggest`; the user chooses a qualifying Agent Profile at start:

```yaml
schema: prowl.workflow/v1
id: myteam.quick-review           # slug; never the reserved `prowl.` prefix
name: Quick Review
description: A launched reviewer checks this pane's work until it is clean.
icon: magnifyingglass.circle      # optional SF Symbol

inputs:
  focus: { type: string, prompt: "What should the reviewer focus on?" }  # no default = required
  depth: { type: enum, values: [quick, deep], default: quick }            # enum needs `values`; default must be one of them
  max_rounds: { type: integer, default: 3, min: 1, max: 10 }

roles:
  author:
    source: current               # the pane the run starts from (at most one per workflow)
  reviewer:
    source: launch                # Prowl starts a new agent for this role
    kind: interactive             # optional; the only V1 kind
    bind: ask                     # ask = start sheet always shows the picker; auto = silent when unambiguous
    placement: split              # split | tab
    direction: right              # split only: right | left | up | down
    background: false             # true = do not steal focus

steps:
  - id: brief
    title: "Author writing the brief"
    message: author               # multi-line content -> use `instruction`; single line -> `text`
    instruction: |
      Summarize what you just built and how to verify it, focusing on {{ inputs.focus }}.
      Deliver the summary with the generated completion command.
    expect: { output: brief }

  - id: launch-reviewer
    title: "Reviewer starting"
    launch: reviewer
    prompt: "Read {{ outputs.brief.path }} and do a {{ inputs.depth }} review of the work it describes. Deliver '## Findings' and choose a verdict."
    expect: { output: findings, sections: ["## Findings"], verdict: [clean, issues] }

  - id: rounds
    title: "Reconciling findings"
    repeat:
      max: "{{ inputs.max_rounds }}"     # positive literal 1–20, or exactly one integer input
      until: outputs.findings.verdict == clean
    steps:                               # NOTE: `steps` is a SIBLING of `repeat:`, not nested inside it
      - id: fix
        title: "Round {{ loop.index }}: author fixing"
        message: author
        text: "Address every finding in {{ outputs.findings.path }}, then deliver your disposition."
        expect: { output: disposition }
      - id: rereview
        title: "Round {{ loop.index }}: reviewer re-checking"
        message: reviewer
        text: "Re-review against {{ outputs.disposition.path }} and deliver new findings with a verdict."
        expect: { output: findings, sections: ["## Findings"], verdict: [clean, issues] }

  - id: done
    notify: "Quick review: {{ outputs.findings.verdict }} after {{ loop.count }} round(s)"
```

The initial review happens before the loop; `max_rounds` limits additional fix/review
cycles. An initial `clean` verdict skips the loop. If it is still `issues` at the cap,
the run ends as `max_rounds_reached` and the `done` notification does not run. This is
not successful completion or a guaranteed cleanup path. If a final summary must run on
exhaustion too, use the explicit giving-up verdict pattern below. Add `close` only when
closing the launched pane is intended; a step after a loop is not a `finally` block.

## Inputs

Each `inputs.<name>` entry declares a start-time value by `type`: `integer` (optional
`min`/`max`; a default must lie inside them), `string` (one line, no control characters), or
`enum` (`values` is required; a default must be one of them). An input without `default` is
required: the GUI start sheet asks for it (`prompt` is its label) and the CLI needs
`--input name=value`. Inputs reach steps only through `{{ inputs.<name> }}` and `repeat.max`.

## Roles

| `source` | Meaning | Key facts |
| --- | --- | --- |
| `current` | the pane the run was started from | at most one per workflow; needs a live agent only if an unskipped `message` targets it; a workflow with no `current` role runs against a worktree instead |
| `launch` | Prowl launches a new agent | V1 `kind: interactive` only; the profile is chosen at start by binding resolution (remembered binding → exact `suggest` match → Recommended profile filtered by `agents` → ask) and frozen into the run |
| `pick` | an existing detected agent pane in the source worktree, chosen at start | always explicit: the GUI start sheet shows a pane picker, the CLI requires `--role <role>=<pN\|pane UUID>`; panes already in a run are not offered |

`bind: ask` (default) always shows the role's picker in the GUI start sheet; `bind: auto`
resolves silently when unambiguous. The CLI never shows UI — resolution just runs, and
`--role <launch-role>=<profile name|uuid|auto>` overrides it. `suggest` takes profile
preset fields (`agent`, `model`, `reasoning_effort`, `execution_mode`), never a profile
name or UUID.

### Runtime constraints and preferences

**Default: omit `agents`.** Any enabled Agent Profile that supports a launch prompt can
qualify. A review, implementation, or summarization role does not by itself need a runtime
restriction. Do not infer one from your own agent identity, the locally installed profiles,
sample YAML, or an opinion about which model suits the role.

Only add `agents` when the user explicitly requires certain runtimes or the task depends
on a concrete runtime-specific capability. State that reason in the YAML comment beside
the allow-list. The field is a hard eligibility constraint, not a preferred-profile hint:
it excludes every profile whose runtime is not listed. Omission means any; `agents: []`
allows none, and `any` / `*` are not wildcard tokens.

For a user-provided preference rather than a hard requirement, use `suggest` if appropriate
and leave `agents` omitted. Do not invent `suggest.agent`, model, or other preset fields
either. Without an explicit preference, rely on Prowl's remembered binding, Recommended
profile, and start-sheet picker.

When a restriction is required, `agents` lists runtime tokens — the agent column of
`prowl profiles list`: `claude`, `codex`,
`gemini`, `pi`, `omp`, `opencode`, `droid`, `cursor-agent`, `copilot`, `kimi`, `amp`,
`qodercli`, `qwen`, `grok`, `cline`. An unknown token, or a list no installed agent
satisfies, is a validation warning. `kind` may be omitted (`interactive` is the only V1 kind).

## Step verbs

Each step has a unique `id`, an optional templated `title` (shown in the status center),
and exactly one verb:

| Verb | Payload | Rules |
| --- | --- | --- |
| `message: <role>` | `text` (one line, typed into the pane) or `instruction` (multi-line, materialized to a file; a pointer line is typed) | target must be alive: `current`, `pick`, or a `launch` role **after** its launch step. Injected only when the role is idle — a working role queues the step, a blocked one raises attention |
| `launch: <role>` | `prompt` (templated kickoff; may span lines as a YAML `\|` block), optional `skill` (bundled skill id) | once per role per run; rendered prompt ≤ 32 KiB, no NUL |
| `action: <id>` | `with` (templated map) | native built-ins: `git.context`, `handoff.transition`, `handoff.checkpoint`; synchronous typed outputs under `{{ actions.<step>.<key> }}`; `prowl workflow schema` prints their input/output schemas; cannot carry `expect` |
| `notify: <text>` | — | notification bell; click focuses the `current` role's pane (or the source worktree) |
| `close: <role>` | — | `launch` roles only, no confirmation; a cancelled run never closes panes |
| `repeat` | `max` (required), `until` (optional), sibling `steps` | while-loop: `until` is checked before entry and after each iteration and compares one declared verdict only (`outputs.<n>.verdict == v` / `in [..]`); no nesting, no `launch` inside. A satisfied `until` is the **only** way past a loop: reaching `max` with it unsatisfied — or a loop with no `until` at all — ends the run as `max_rounds_reached` and no later step runs (see the patterns below) |

## `expect` — waiting for a delivery

A `message` or `launch` step with `expect` waits until the target agent explicitly delivers
via `prowl workflow done`; without one the step is fire-and-forget — the run advances the
moment injection/launch succeeds, and there is no "wait without delivery" in V1.

```yaml
expect:
  output: findings          # name for the delivery; default = the step id
  format: markdown          # markdown (default) | text | json
  sections: ["## Findings"] # required headings (case/level-forgiving; fenced code ignored)
  verdict: [clean, issues]  # 2–4 slugs; makes --verdict mandatory and drives `until`
  timeout: 30m              # optional hard cap as <n>s|m|h (90s, 10m, 2h); NO default — omit to wait as long as the agent works
  on_timeout: attention     # only together with timeout; attention (default) | skip | cancel
  strict: false             # false: a delivery missing sections/format/verdict is kept as
                            # provisional and the run asks the user; true: rejected outright
```

Prowl appends the completion command itself — the typed line or kickoff prompt ends with
the exact `PROWL_WORKFLOW_TOKEN=… prowl workflow done [--verdict v] -` to run. **Never
write `prowl workflow done` into your own `text`/`instruction`/`prompt`** (the validator
warns); the runner's renderer is the only source of that command.

## Templates (whitelist; substitution only)

`{{ run.id }}`, `{{ run.dir }}`, `{{ worktree.path|name|branch }}`,
`{{ roles.<r>.name|agent|pane }}`, `{{ outputs.<name>.path }}`,
`{{ outputs.<name>.verdict }}`, `{{ actions.<step>.<key> }}`, `{{ inputs.<k> }}`,
`{{ loop.index }}`, `{{ loop.count }}`.

`loop.index` is the 1-based round inside a `repeat`; `loop.count` is the number of completed
rounds of the latest loop, valid inside and after it, and renders `0` after a loop that was
skipped before entry.

There are no expressions and **no inlined output text** (`outputs.<name>.text` does not
exist). Content moves between agents by path — the receiver reads the file rather than
embedding its body in a terminal message. An agent-produced value can reach templates only
as a verdict. Referencing an output at a point where no earlier step could have produced it is a validation error
(see the seed pattern below). `roles.<r>.pane` is valid only after that role's launch step.

## Rules the validator enforces (write with these in mind)

- `steps` is a **sibling** of `repeat:` — nesting it inside `repeat` is the classic mistake.
- `text`, rendered lines, and string inputs are single-line; no control characters.
- `message` on a `launch` role must come after its launch step.
- At most one `current` role; `launch` at most once per role; `repeat` not nested, no
  `launch` inside; `max` is 1–20 (a literal, or a template naming exactly one integer input).
- `verdict` is 2–4 slug values; `until` literals must belong to the declared set.
- `expect` only on `message` and `launch` steps; `on_timeout` only next to a `timeout`;
  `min`/`max` only on `integer` inputs, `values` only on `enum` inputs.
- A skippable step (`--skip` / the start sheet's Skip) is one whose output has no
  non-optional consumer; skipping a step whose output a later template needs ends the run
  instead of advancing, and the validator/panel names the dependent step.

## Patterns that work

- **Seed delivery**: before a loop whose body references `{{ outputs.reply.path }}`, have an
  opening step deliver `reply` once (e.g. with a spare verdict value like `ready`) so the
  first iteration's reference has a producer.
- **Poor-man's `if`**: `repeat: { max: 1, until: outputs.x.verdict == ok }` skips its body when
  the verdict is already `ok` (`until` is evaluated before entry) and runs it once otherwise.
  It is only an `if` when that one round is certain to make the verdict `ok`: if it does not,
  the run ends as `max_rounds_reached` right there.
- **Bounded loop that must go on**: V1 has no "try N times, then continue regardless". Reserve
  a verdict for giving up — `verdict: [agree, disagree, gave_up]` with
  `until: outputs.check.verdict in [agree, gave_up]` — and tell the agent in the loop body to
  choose it on the last round (`Round {{ loop.index }} of {{ inputs.max_rounds }}`); the
  steps after the loop can then run once that terminating verdict is accepted. This is a
  prompt contract, not a runner-enforced fallback: if the agent still delivers a nonterminal
  verdict at the cap, the run still ends there. Otherwise accept `max_rounds_reached`
  as an outcome: the status center reports it and launched panes stay open for inspection.
- **Fork / ordered join**: expect-less `launch` steps return immediately, so two workers run
  wall-clock concurrently; join by messaging each in turn with an `expect`. Phrase the fork
  prompt as "do the work now, deliver only when asked" and the join as "deliver when your
  work is complete" — an agent that backgrounds its work reads as idle, so an early
  "deliver now" can arrive before the work is done.
- **Broadcast**: several steps delivering to one output name makes `outputs/<name>.md` a
  shared "latest announcement" file any role can be pointed at.
- **Conditional behavior** ("whoever won writes the summary") lives in prompts, not the
  DSL: ask every candidate and let each decide from the run's files. It is a contract with
  the model, not a guarantee — keep such prompts explicit about both branches.
- Launch busy helper roles with `background: true` so runs don't steal the user's focus;
  keep the pane the user should watch in the foreground.

## Deadlines and delivery contracts

Omit `expect.timeout` unless the task needs an explicit deadline. It limits elapsed
waiting time even while the agent is working; it is not an inactivity timeout. With no
timeout, the watchdog still detects idle, blocked, or missing participants. Choose
`on_timeout: skip` or `cancel` only when automatic continuation or termination is intended;
skipping a required output can end the whole run.

Use `sections`, `format`, and `verdict` for actual downstream needs, and describe those
deliverables consistently in the prompt. `strict: true` rejects mismatches; the default
retains them provisionally for a user decision. Neither headings nor a verdict prove
that the underlying work is correct. For JSON output consumed by a tool, strict JSON
validation helps enforce syntax, but V1 does not validate a custom JSON schema.

## Placement and ids

User workflows go to `~/.prowl/workflows/<file>.yaml`; repo workflows to
`<repo root>/.prowl/workflows/<file>.yaml` (shadowing the user file with the same id for
that repo). Ids are slugs; the `prowl.` prefix is reserved for bundled workflows and
rejected elsewhere. The file name is free; the id is the identity.
