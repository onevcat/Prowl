# Authoring Prowl Workflows

Write `workflow.yaml` inside `<name>.pwlworkflow`. Validate the **directory** with
`prowl workflow validate <name>.pwlworkflow`. `prowl workflow schema` prints the v1 schema.
User bundles live at `~/.prowl/workflows/`; repository bundles at `.prowl/workflows/` under
the repository root. Repository IDs shadow user IDs. `prowl.*` IDs are reserved for built-ins.
There is no previously released workflow format or migration step.

## Minimal workflow

```yaml
schema: prowl.workflow/v1
id: summarize
name: Summarize changes
roles:
  author: {source: current}
steps:
  - id: summary
    message: author
    prompt: |
      Inspect the current changes and write a concise summary.
    expect: {delivery: summary, sections: ["## Summary"]}
  - id: done
    notify: "Summary saved to {{ deliveries.summary.path }}"
```

Do not add runtime constraints, loops, deadlines, or automatic pane closure unless they
serve the requested task. If a later step depends on agent work, use `expect`: without it,
launch/injection success advances the workflow while the agent may still be working.

## Typed values and expressions

A workflow is a reusable definition; a run is one execution of it. The worktree is
its execution target (a Git worktree, Prowl workspace, or plain directory). Role keys
are workflow participant names; `display_name` identifies the bound profile or pane.
`observed` contains `exists` and `state`, refreshed for the step. `context.initiator`
contains `pane_id` and nullable `tab_id`, or is null for a worktree-only start.

Read-only namespaces:

| Namespace | Meaning |
| --- | --- |
| `context.workflow` | definition `id`, `name` |
| `context.run` | execution `id`, `path` |
| `context.worktree` | target `id`, `path`, `name`, `branch`, `captured_at` |
| `context.initiator` | original source pane identity, or null for a worktree-only start |
| `context.roles.<role>` | binding `source`, `display_name`, `agent`, `pane_id`, and live `observed` |
| `context.step` | `id`, `iteration` (null outside loops), `captured_at` |
| `context.action` | action-only `execution_id`, `step_id`, `attempt`, `working_directory`, `artifacts_directory` |
| `inputs.<name>` | typed start-time inputs |
| `deliveries.<name>` | agent delivery `path` and nullable `verdict` |
| `actions.<step>` | action `output` object and `output_path` |
| `state.<name>` | explicitly declared, mutable typed state |

Use `{{ expression }}` in text and action inputs. A complete expression in an action input
retains its type; text interpolation accepts scalars, not arrays/objects. No implicit
string-to-number or string-to-boolean conversion occurs. Missing fields are errors;
`exists(deliveries.optional.path)` and `deliveries.optional.path ?? ''` handle absence explicitly.
`exists` does not hide arithmetic/type errors. `&&`, `||`, and `??` short-circuit.

Expressions support null, booleans, numbers, single/double quoted strings, arrays,
field/index access, parentheses, unary `!`/`-`, arithmetic `* / % + -`, comparisons
`< <= > >=`, equality `== !=`, `&&`, `||`, and `??` (listed strongest to weakest).
Functions: `length(value)`, `append(array, item)`, `slice(array, start, end)` (end exclusive),
and `exists(reference)`. Integers must stay within ±9007199254740991; numbers must be finite.
Overflow and division by zero fail. This language does not execute arbitrary code.

## State and control flow

```yaml
state:
  count: {type: integer, initial: 0}
  files: {type: 'array<string>', initial: []}
steps:
  - id: collect
    while: state.count < 3
    steps:
      - id: update
        set:
          count: state.count + 1
          files: "append(state.files, 'README.md')"
      - id: stop
        if: state.count == 2
        then:
          - id: exit
            break: true
  - id: report
    notify: "Collected {{ length(state.files) }} entries"
```

State types: `integer`, `number`, `boolean`, `string`, and nested `array<T>`.
`set` values are **expressions**, evaluated against the same old state and committed
atomically. To assign literal text, use an expression string such as `label: "'ready'"`.
No step implicitly changes state from an action result.

`if` has `then` and optional `else`. `while` has `steps` and optional literal
`max_iterations`. Conditions must be boolean. The loop tests its condition before each
iteration. In a `while` condition, `context.step.id` is the loop ID and
`context.step.iteration` is the number of completed iterations (0 on the first check).
Inside the body, iteration numbers start at 1. If the condition stays true at the cap, the run ends as `iteration_limit_reached`; it does not
report success or execute later steps. For an ordinary counted loop, express the count in
its condition. Omit the cap when the task calls for an unlimited loop.

Nested `break: true` and `continue: true` target the innermost loop. Step IDs are globally
unique. Outputs from a branch or iteration leave scope on exit and are absent at the next
entry. Retain needed values in state **inside** that scope. Roles remain bound across
iterations; launch a role once, then use `message` for repeated work.
Mutually exclusive `if` branches may launch the same role with different prompts. A later
shared step can use the role only if every branch launches it. A later launch is rejected
if any earlier branch could already have launched that role.

For a review loop, retain the initial verdict/path in state, loop while
`state.verdict != 'clean'`, ask the author to address `state.path`, ask the reviewer for a
fresh expected delivery, then update state from that delivery. Do not depend on the last
iteration's output being implicitly visible ; use the declared state and `while` condition.

## Step verbs

Each step has `id`, optional templated `title`, and one verb. Action IDs use
`builtin:<verb-object>` or `local:<verb-object>`: for example,
`builtin:collect-worktree-context` and `local:persist-handoff`. Use verb-first
kebab-case names for actions; dot-separated expressions address data, not actions.

| Verb | Payload and behavior |
| --- | --- |
| `message: role` | required `prompt` (single-line or multiline); Prowl selects direct delivery or scoped read after rendering; waits for idle; optional `expect` |
| `launch: role` | `prompt`, optional bundled `skill`, optional `expect`; at most once per persistent role |
| `action: builtin:collect-worktree-context` or `local:id` | typed `with` object; awaits validated result; no `expect`; see [actions](actions.md) |
| `notify: text` | notification |
| `close: role` | closes a launch role's pane; use only when the requested workflow needs cleanup |
| `set` | atomic state assignments |
| `if` | boolean expression, `then`, optional `else` |
| `while` | boolean expression, `steps`, optional `max_iterations` |
| `break: true` / `continue: true` | innermost loop control |

## Inputs

Each `inputs.<name>` entry declares a start-time value by `type`: `integer` (optional
`min`/`max`; a default must lie inside them), `string` (one line, no control characters), or
`enum` (`values` is required; a default must be one of them). An input without `default` is
required: the GUI start sheet asks for it (`prompt` is its label) and the CLI needs
`--input name=value`. Inputs reach steps only through `{{ inputs.<name> }}`.

## Roles

| `source` | Meaning | Key facts |
| --- | --- | --- |
| `current` | the pane the run was started from | at most one per workflow; needs a live agent only if an unskipped `message` targets it; a workflow with no `current` role runs against a worktree instead |
| `launch` | Prowl launches a new agent | `kind: interactive` only; the profile is chosen at start by binding resolution (remembered binding → exact `suggest` match → Recommended profile filtered by `agents` → ask) and frozen into the run |
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
satisfies, is a validation warning. `kind` may be omitted (`interactive` is the only kind).


## `expect` — waiting for a delivery

A `message` or `launch` step with `expect` waits until the target agent explicitly delivers
via `prowl workflow deliver`; without one the step is fire-and-forget — the run advances the
moment injection/launch succeeds, and there is no "wait without delivery" .

```yaml
expect:
  delivery: findings          # name for the delivery; default = the step id
  format: markdown          # markdown (default) | text | json
  sections: ["## Findings"] # required headings (case/level-forgiving; fenced code ignored)
  verdicts: [clean, issues]  # 2–4 slugs; makes --verdict mandatory for expressions
  timeout: 30m              # optional hard cap as <n>s|m|h (90s, 10m, 2h); NO default — omit to wait as long as the agent works
  on_timeout: attention     # only together with timeout; attention (default) | skip | cancel
  strict: false             # false: a delivery missing sections/format/verdict is kept as
                            # provisional and the run asks the user; true: rejected outright
```

Prowl appends the completion command itself — the typed line or kickoff prompt ends with
the exact `PROWL_WORKFLOW_TOKEN=… prowl workflow deliver [--verdict v] -` to run. **Never
write `prowl workflow deliver` into your own `prompt`** (the validator
warns); the runner's renderer is the only source of that command.


Expressions are limited to 16 KiB, 256 tokens, and 64 nested levels. Inner scopes must not
reuse an outer output alias. Use a different alias and assign a value to typed `state`
when it must survive the branch or iteration.

`context.worktree.branch` is refreshed before steps. `context.roles.<role>.observed`
contains the observed `exists` and `state` fields, or is null when unavailable. Observations
are a step snapshot, not a guarantee that an agent will remain idle.

`context.initiator` preserves the initiating `pane_id` and `tab_id` (null for worktree-only starts).
`exists(value) && predicate` and `!exists(value) || predicate` support optional data
without requiring a missing value on the short-circuited path.

Place `launch` before a `while` loop. Launch steps inside loops (including nested branches)
are rejected; send `message` to the persistent role for repeated work.
