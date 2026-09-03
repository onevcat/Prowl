# Agent Workflows

> Multi-step, multi-agent orchestrations that Prowl runs and supervises for
> you: a YAML file declares the roles (the pane you start from, an agent Prowl
> launches, an agent you pick) and the steps (message a role, launch one, loop
> until a verdict, notify, close); Prowl types the instructions into the right
> panes, waits for each delivery, and shows the run in the toolbar. This page
> covers the feature end to end — files, entry points, the start sheet, the run
> panel, and Settings → Agents → Workflows. For the CLI commands and their JSON,
> see [`cli.md`](cli.md#prowl-workflow); to write or debug a workflow, an agent
> should load the bundled `prowl-workflow` skill.

**Keywords:** workflow, workflows, agent workflow, orchestration, multi-agent, adversarial review, roles, steps, repeat until, verdict, yaml, prowl.workflow/v1, start sheet, run workflow, bindings, don't ask again, workflow status, run panel, needs attention, nudge, skip step, cancel run, workflow-runs, settings workflows, new workflow, ask an agent

**Related:** [cli](cli.md) · [agent-profiles](agent-profiles.md) · [command-palette](command-palette.md) · [active-agents](active-agents.md) · [settings](settings.md) · [notifications](notifications.md)

## What it is

A workflow file scripts several live agents: who takes part and what happens in
order. Prowl executes it — every participant is a real terminal pane you can
watch — and agents take part only through the `prowl` CLI, so any runtime Prowl
recognizes can play any role. A typical workflow: the pane you are working in
writes a brief, Prowl launches a reviewer beside it from an Agent Profile, the
reviewer reports findings with a verdict, and the two loop until the verdict is
`clean` or the round cap is hit.

The file format is `schema: prowl.workflow/v1`. Roles have a `source`:

| `source` | Meaning | How it is chosen |
|---|---|---|
| `current` | the pane the run was started from | the pane you start from (or pick in the sheet) |
| `launch` | a new agent Prowl starts from an [Agent Profile](agent-profiles.md) | remembered profile → profile matching the role's `suggest` → the repository's Recommended profile → the sheet asks |
| `pick` | an existing detected agent pane in the same worktree | always chosen at start |

Steps are `message` (type one line or point the role at a materialized
instruction file), `launch` (start a launch role with a kickoff prompt),
`repeat … until outputs.<name>.verdict == <value>` (bounded loop),
`action` (a native Prowl action), `notify`, and `close`. A `message` or
`launch` step may `expect` an output: the role finishes by running the exact
`prowl workflow done …` command Prowl typed into its pane, with the body on
stdin. The full DSL, validator rules, and authoring patterns are the
`prowl-workflow` skill's job (`prowl skills install prowl-workflow`);
`prowl workflow schema` prints the JSON Schema.

## Where workflow files live

Three sources, later ones winning for the same `id`:

| Source | Location | Notes |
|---|---|---|
| Built-in | `Prowl.app/Contents/Resources/workflows/` | ids `prowl.*` are reserved for it. No built-in ships yet; the first (`prowl.adversarial-review`) arrives in a later release. |
| Your workflows | `~/.prowl/workflows/*.yaml` | personal; not tied to a repository |
| Repository | `<repo root>/.prowl/workflows/*.yaml` | travels with the repo; seen only from that repository's worktrees |

A file that fails validation is never offered for a run; a file with the same
id in two sources is offered once (the repository file wins over yours). A
workflow is **enabled by default**; switch it off in Settings (below) to hide it
from every entry point and refuse `prowl workflow run` for it.

## Starting a workflow

Every start — GUI or CLI — goes through the same admission, so behavior is
identical:

- **Command Palette** (`⌘P`) → **Run Workflow: <name>** — one row per
  runnable workflow visible to the selected worktree.
  → [command-palette](command-palette.md)
- **Toolbar Agents capsule** → the **Workflows** section — each row starts the
  workflow; its trailing `ellipsis.circle` ("Run with Options…") forces the
  start sheet even when the workflow would start silently; files that fail
  validation are listed dimmed with their reason. → [agent-profiles](agent-profiles.md#launching)
- **Active Agents** → right-click a row → **Run Workflow ▸** — starts it with
  that pane fixed as the `current` role's source. → [active-agents](active-agents.md)
- **CLI** — `prowl workflow run <id|name> [source] [--role r=…] [--input k=v] [--skip step]`.
  → [cli](cli.md#prowl-workflow)

### The start sheet

The sheet collects what the run needs before it exists:

- **You** — the pane that serves the `current` role. Pre-selected from the
  worktree's focused pane (fixed when started from an Active Agents row); a bare
  shell qualifies only while no step messages that role.
- **One profile picker per `launch` role** — pre-selected by binding resolution,
  filtered to profiles that qualify (`agents` allow-list, prompt support);
  profiles that do not qualify are dimmed with the reason. **Create profile from
  suggestion…** appears when the role's `suggest` matches no enabled profile: it
  creates a normal Agent Profile inline and selects it.
- **One pane picker per `pick` role** — detected agents in the worktree,
  excluding panes already in a run and the source pane.
- **Inputs** — declared inputs with their defaults pre-filled; required inputs
  without a default must be filled before Run enables.
- **Skip <step>** — for steps whose output nothing later depends on; the sheet
  says whether skipping ends the run early.
- **Don't ask again for this workflow** — writes the per-workflow **Automatic**
  bind mode (same control as Settings → Workflows → Bindings), so the next start
  skips the sheet when nothing is undecided.
- A banner blocks Run when the `prowl` CLI is not usable (missing, or a dangling
  link — with an inline Install / Repair) or when Prowl is not listening on its
  socket (the reason is shown; participants could not deliver).

A workflow with `bind: auto` roles, resolved bindings, no `pick` roles, and
fully defaulted inputs starts **without the sheet**; the toolbar status item is
the feedback.

## While a run is active

- The toolbar's center **status item** shows the selected worktree's active run:
  the current step, an orange attention glyph when the run waits for you, and a
  count when several runs share the worktree. Hover previews the run panel;
  click pins it.
- The **run panel** lists every active run in that worktree: role chips (click
  focuses that pane), repeat rounds, the step list with the current instruction,
  the run folder and log, and **Cancel Run**.
- **Needs attention** is a state, not a deadline: a late delivery is still
  accepted. The panel offers exactly the recoveries the runner permits — Focus
  Pane, Nudge Again, Keep Waiting, Retry, Relaunch Role, Accept as Delivered,
  Accept with a declared verdict, Ask Again, Skip Step, Cancel Run.
- Waiting is state-driven: a working agent is never interrupted; an agent whose
  turn ended without delivering gets one typed nudge with the completion command.
- Completion and attention go through the bell with click-to-focus (quiet while
  you are already watching that worktree). → [notifications](notifications.md)
- Active Agents rows bound to a run show `in <workflow> · <role>` for the life
  of the run; a pane belongs to at most one run at a time.
- Finishing or cancelling never closes a pane; only an explicit `close:` step does.

Every run leaves `<worktree root>/.prowl/workflow-runs/<run id>/` (self-ignored
by Git): `log.md` (the timeline), `run.json` (bindings, invocations, step
states), `instructions/`, `outputs/<name>.md` (latest delivery, with every
version beside it), and `skills/`. Read `log.md` first to learn what happened.

## Settings → Agents → Workflows

The page lists every file Prowl can see, grouped by source — **Built-in**,
**Your Workflows** (`~/.prowl/workflows`), and one section per repository that
holds files — and follows the folders live: edit a file in your editor and its
status updates without leaving Settings.

Per row:

| Control | Effect |
|---|---|
| Checkbox | enable/disable (`disabledWorkflowIDs`, keyed `<scope>/<id>`). Disabled workflows appear in no entry point and `prowl workflow run` refuses them with `WORKFLOW_DISABLED`. The same id in two repositories shares one key. |
| Status line | **Valid**, **Valid, N warnings**, or **N errors** with **Show Details** listing every diagnostic as `line:column message code` — the same output as `prowl workflow validate`. An **Overridden …** note names the file or repository whose same-id definition wins. |
| **Reveal** | shows the file in Finder |
| **Bindings** (workflows with `launch` roles) | **Follow file** (the YAML's `bind`), **Always ask**, or **Automatic** — the tri-state override the start sheet's "Don't ask again" also writes |
| Role pickers (one per `launch` role) | the remembered profile for that role, or **Ask at start** to forget it. Only qualifying enabled profiles are offered; a remembered profile that no longer qualifies is shown with the reason. **Manage Profiles…** jumps to Settings → Agents → Profiles. |

Page actions (under Your Workflows): **New Workflow…** writes a validated
starter file (`new-workflow.yaml`, then `new-workflow-2.yaml`, …; its id is the
file name) into `~/.prowl/workflows` and reveals it; **Ask an Agent…** shows a
copyable, localized prompt that points your coding agent at the bundled
`prowl-workflow` skill and this manual and asks it to write, validate, and place
a workflow for you; **Show Folder** reveals `~/.prowl/workflows` (creating it).

A banner at the top mirrors the start sheet's preflight: Install when `prowl`
is missing (Repair when the link is dangling), or the reason Prowl is not
listening on its socket (also shown as the **Status** row under Settings →
Agents → CLI & Skills → Connection).

## Gotchas for agents

- Validate before handing over: `prowl workflow validate <file>` works with Prowl
  closed; Settings shows the same diagnostics. A file with errors is never
  runnable, and its row says so.
- `prowl.*` ids are reserved for built-ins; a user or repo file using one is
  invalid (`reserved_id`).
- Repository workflows are visible only from that repository's worktrees;
  `prowl workflow list` from a pane answers for that pane's worktree.
- A remembered binding is keyed by the role's requirements (`agents`,
  `suggest`, …): editing those in the file forgets the binding; editing prompts
  keeps it.
- Participants must deliver with the exact `prowl workflow done …` command Prowl
  typed (token included); `prowl agents dispatch-complete` is refused inside a
  workflow activation with `WORKFLOW_DELIVERY_REQUIRED`.
- Nothing is closed automatically; a launched reviewer pane stays open after the
  run unless the workflow has a `close:` step.
