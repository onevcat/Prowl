# Authoring Prowl Workflows

Full reference for writing `prowl.workflow/v1` files. The JSON Schema from
`prowl workflow schema` is authoritative for field shapes; this file adds the rules a
schema cannot express and the patterns that work. Validate every draft with
`prowl workflow validate <file>` — it is static, strict, and fast, and its errors carry
line numbers.

## Worked example

One existing agent, one launched reviewer, a verdict loop, and an input — most of the
machinery in ~60 lines:

```yaml
schema: prowl.workflow/v1
id: myteam.quick-review           # slug; never the reserved `prowl.` prefix
name: Quick Review
description: A launched reviewer checks this pane's work until it is clean.
icon: magnifyingglass.circle      # optional SF Symbol

inputs:
  focus: { type: string, prompt: "What should the reviewer focus on?" }  # no default = required
  max_rounds: { type: integer, default: 3, min: 1, max: 10 }

roles:
  author:
    source: current               # the pane the run starts from (at most one per workflow)
  reviewer:
    source: launch                # Prowl starts a new agent for this role
    kind: interactive
    agents: [claude, codex]       # allow-list of runtime tokens; omit = any launchable
    suggest: { agent: claude }    # used by binding resolution; never a profile name/UUID
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
    expect: { output: brief, timeout: 15m }

  - id: launch-reviewer
    title: "Reviewer starting"
    launch: reviewer
    prompt: "Read {{ outputs.brief.path }} and review the work it describes. Deliver '## Findings' and choose a verdict."
    expect: { output: findings, sections: ["## Findings"], verdict: [clean, issues], timeout: 30m }

  - id: rounds
    repeat:
      max: "{{ inputs.max_rounds }}"     # positive literal 1–20, or exactly one integer input
      until: outputs.findings.verdict == clean
    steps:                               # NOTE: `steps` is a SIBLING of `repeat:`, not nested inside it
      - id: fix
        title: "Round {{ loop.index }}: author fixing"
        message: author
        text: "Address every finding in {{ outputs.findings.path }}, then deliver your disposition."
        expect: { output: disposition, timeout: 30m }
      - id: rereview
        title: "Round {{ loop.index }}: reviewer re-checking"
        message: reviewer
        text: "Re-review against {{ outputs.disposition.path }} and deliver new findings with a verdict."
        expect: { output: findings, verdict: [clean, issues], timeout: 30m }

  - id: done
    notify: "Quick review: {{ outputs.findings.verdict }} after {{ loop.count }} round(s)"

  - id: cleanup
    close: reviewer                # closes only the pane this run launched; no confirmation
```

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

## Step verbs

Each step has a unique `id`, an optional templated `title` (shown in the status center),
and exactly one verb:

| Verb | Payload | Rules |
| --- | --- | --- |
| `message: <role>` | `text` (one line, typed into the pane) or `instruction` (multi-line, materialized to a file; a pointer line is typed) | target must be alive: `current`, `pick`, or a `launch` role **after** its launch step. Injected only when the role is idle — a working role queues the step, a blocked one raises attention |
| `launch: <role>` | `prompt` (templated kickoff), optional `skill` (bundled skill id) | once per role per run; rendered prompt ≤ 32 KiB |
| `action: <id>` | `with` (templated map) | native built-ins: `git.context`, `handoff.transition`, `handoff.checkpoint`; synchronous typed outputs under `{{ actions.<step>.<key> }}`; `prowl workflow schema` prints their input/output schemas; cannot carry `expect` |
| `notify: <text>` | — | notification bell; click focuses the `current` role's pane (or the source worktree) |
| `close: <role>` | — | `launch` roles only, no confirmation; a cancelled run never closes panes |
| `repeat` | `max` (required), `until` (optional), sibling `steps` | while-loop: `until` is checked before entry and after each iteration and compares one declared verdict only (`outputs.<n>.verdict == v` / `in [..]`); no nesting, no `launch` inside; reaching `max` unsatisfied ends the run as `max_rounds_reached` |

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
  timeout: 30m              # optional hard cap; NO default — omit to wait as long as the agent works
  on_timeout: attention     # attention (default) | skip | cancel
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

There are no expressions and **no inlined output text** (`outputs.<name>.text` does not
exist). Content moves between agents by path — the receiver reads the file, which costs an
agent nothing. An agent-produced value can reach templates only as a verdict. Referencing
an output at a point where no earlier step could have produced it is a validation error
(see the seed pattern below). `roles.<r>.pane` is valid only after that role's launch step.

## Rules the validator enforces (write with these in mind)

- `steps` is a **sibling** of `repeat:` — nesting it inside `repeat` is the classic mistake.
- `text`, rendered lines, and string inputs are single-line; no control characters.
- `message`/`close` on a `launch` role must come after its launch step.
- At most one `current` role; `launch` at most once per role; `repeat` not nested, no
  `launch` inside; `max` is 1–20 (a literal, or a template naming exactly one integer input).
- `verdict` is 2–4 slug values; `until` literals must belong to the declared set.
- `expect` only on `message` and `launch` steps.
- A skippable step (`--skip` / the start sheet's Skip) is one whose output has no
  non-optional consumer; skipping a step whose output a later template needs ends the run
  instead of advancing, and the validator/panel names the dependent step.

## Patterns that work

- **Seed delivery**: before a loop whose body references `{{ outputs.reply.path }}`, have an
  opening step deliver `reply` once (e.g. with a spare verdict value like `ready`) so the
  first iteration's reference has a producer.
- **Poor-man's `if`**: `repeat: { max: 1, until: outputs.x.verdict == ok }` runs its body
  exactly once when the verdict is not `ok` and skips it entirely otherwise (`until` is
  evaluated before entry).
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

## Placement and ids

User workflows go to `~/.prowl/workflows/<file>.yaml`; repo workflows to
`<repo root>/.prowl/workflows/<file>.yaml` (shadowing the user file with the same id for
that repo). Ids are slugs; the `prowl.` prefix is reserved for bundled workflows and
rejected elsewhere. The file name is free; the id is the identity.
