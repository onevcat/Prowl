# Agent Workflows

> Workflow UI is enabled by default. Start Prowl with `PROWL_WORKFLOW_UI=0` to hide its UI and skill row; CLI workflow and skill commands remain available. The switch is read at process startup.

> Multi-step, multi-agent orchestrations that Prowl runs and supervises for
> you: a workflow bundle declares the roles (the pane you start from, an agent Prowl
> launches, an agent you pick) and the steps (message a role, launch one, loop
> until a verdict, notify, close); Prowl types the instructions into the right
> panes, waits for each delivery, and shows the run in the toolbar. This page
> covers the feature end to end — files, entry points, the start sheet, the run
> panel, and Settings → Agents → Workflows. For the CLI commands and their JSON,
> see [`cli.md`](cli.md#prowl-workflow); to write or debug a workflow, an agent
> should load the bundled `prowl-workflow` skill.

**Keywords:** workflow, workflows, agent workflow, orchestration, multi-agent, adversarial review, roles, steps, typed state, while, if, action bundle, verdict, yaml, prowl.workflow/v1, start sheet, run workflow, bindings, don't ask again, workflow status, run panel, needs attention, nudge, skip step, cancel run, workflow-runs, settings workflows, new workflow, ask an agent

**Related:** [cli](cli.md) · [agent-profiles](agent-profiles.md) · [command-palette](command-palette.md) · [active-agents](active-agents.md) · [settings](settings.md) · [notifications](notifications.md)

## What it is

A workflow bundle scripts several live agents: who takes part and what happens in
order. Prowl executes it — every participant is a real terminal pane you can
watch — and agents take part only through the `prowl` CLI, so any runtime Prowl
recognizes can play any role. A typical workflow: the pane you are working in
writes a brief, Prowl launches a reviewer beside it from an Agent Profile, the
reviewer reports findings with a verdict, and the two loop until the verdict is
`clean` or the round cap is hit.

A `.pwlworkflow` directory contains `workflow.yaml` with `schema: prowl.workflow/v1`,
and optional local script actions and assets. Workflow definitions are loaded from bundle directories. Roles have a `source`:

| `source` | Meaning | How it is chosen |
|---|---|---|
| `current` | the pane the run was started from | the pane you start from (or pick in the sheet) |
| `launch` | a new agent Prowl starts from an [Agent Profile](agent-profiles.md) | remembered profile → profile matching the role's `suggest` → the repository's Recommended profile → the sheet asks |
| `pick` | an existing detected agent pane in the same worktree | always chosen at start |

For a `launch` role, omit `agents` by default to allow any qualifying Agent Profile.
Only add a runtime allow-list for an explicit user requirement or a concrete runtime-specific
capability. `agents: []` allows none; `any` and `*` are not wildcard tokens. Leave `suggest`
unset unless there is a specific preference to express; profile selection normally belongs
to the user's saved preferences and the start-sheet picker.

Steps are `message` (type one line or provide scoped CLI access to persisted
instructions), `launch` (start a launch role with a kickoff prompt),
`set`, nested `if`/`else`, `while`, `break`/`continue`,
`action` (built-in or local script), `notify`, and `close`. A `message` or
`launch` step may `expect` an output: the role finishes by running the exact
`prowl workflow deliver …` command Prowl typed into its pane, with the body on
stdin. The full DSL, validator rules, and authoring patterns are the
`prowl-workflow` skill's job (`prowl skills install prowl-workflow`);
`prowl workflow schema` prints the workflow JSON Schema; `prowl workflow schema --action` prints the action manifest schema.

## Where workflow files live

Three sources, later ones winning for the same `id`:

| Source | Location | Notes |
|---|---|---|
| Built-in | `Prowl.app/Contents/Resources/workflows/` | ids `prowl.*` are reserved for it. Includes Repository Context (`builtin:collect-worktree-context`). |
| Your workflows | `~/.prowl/workflows/*.pwlworkflow` | personal; not tied to a repository |
| Repository | `<repo root>/.prowl/workflows/*.pwlworkflow` | travels with the repo; seen only from that repository's worktrees |

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
- **Toolbar Agents capsule** → the **Run a workflow** section — each row uses the
  workflow's YAML icon and starts the workflow. Its trailing `ellipsis.circle`
  menu offers **Run with Options…** (which forces the start sheet) and **Show
  Details in Settings…**. Files that fail validation remain dimmed with their
  reason and still link to their Settings detail. → [agent-profiles](agent-profiles.md#launching)
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
- **Don't ask again for this workflow** — writes **Run Directly When Possible**
  (the same choice shown under Settings → Workflows → Run Setup), so the next
  start skips the sheet when nothing is undecided.
- A banner blocks Run when the `prowl` CLI is not usable or when Prowl is not
  listening on its socket (participants could not deliver). Inline action per
  state: **Install** when missing, **Repair** for a dangling link, **Reinstall**
  for a foreign link that is not executable; a real file or folder in the slot
  gets no button, only the instruction to remove it (same matrix as the
  Workflows page banner below). A socket failure shows its reason.

A workflow with `bind: auto` roles, resolved bindings, no `pick` roles, and
fully defaulted inputs starts **without the sheet**; the toolbar status item is
the feedback.

## While a run is active

- The toolbar's center **status item** shows the selected worktree's active run:
  the current step, an orange attention glyph when the run waits for you, and a
  count when several runs share the worktree. Hover previews the run panel;
  click pins it.
- The **run panel** lists every active run in that worktree: role chips (click
  focuses that pane), loop iterations, the step list with the current instruction,
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

Every run, including `workflow test-action`, stores its runtime data in
`~/.prowl/logs/workflow-runs/<root-name>-<root-hash>/YYYY-MM/<run-id>/`.
The hash identifies the canonical, symlink-resolved execution directory. Worktrees
and clones have separate histories; changing a branch keeps the same identity.
The creation month stays fixed. No project-local runtime files or Git-ignore rules
are created. Personal and team workflow definitions keep their existing locations.

Each run contains `run.json`, `log.md`, its frozen bundle in `definition/`,
`instructions/`, `skills/`, `deliveries/`, and `actions/`. Metadata records the original
execution root. `prowl workflow status <run-id>` finds saved history even after that
root is closed, moved, or deleted. A moved folder does not inherit the old history.

Open **Settings → Agents → Workflows → Execution History** for usage, search,
**Keep Run**, **Export**, and **Preview Cleanup**. Export creates a complete ZIP of
a terminal run; choose a location outside workflow history for durable results.
Outputs and action artifacts inside history expire with their run.

Automatic cleanup retains unpinned terminal runs for 30 days after completion.
The global budget is **5 GiB, soft**: older eligible runs are removed first when
history exceeds it. Runs finished in the last 24 hours, kept runs, live runs
(including Needs Attention), occupied runs, and ambiguous or unsafe records are
protected. These protections can keep usage above 5 GiB; the history view reports
why space cannot be reclaimed. The policy is fixed. Startup and completion trigger
background cleanup with a shared five-minute rate limit.

Manual cleanup shows candidate runs and estimated reclaimed space, then requires
confirmation. It uses the same protections and checks eligibility again before
deleting each complete run. Old project-local data is neither migrated nor deleted.

Agents retrieve assigned instructions and explicit input resources with
`prowl workflow read`, using the run ID, invocation number, and assigned pane. Prowl owns
persistence; deliver text or JSON through `prowl workflow deliver -` on stdin. Run
paths are temporary artifact locations, not durable downstream references.

## Settings → Agents → Workflows

The global page is a compact index of **Built-in** and **Your Workflows**
(`~/.prowl/workflows`) only. A row shows the YAML icon, name, id, description,
and one effective status: **Ready**, **Disabled**, **Invalid**, or
**Superseded**. Select the row to open its detail; the index itself contains no
workflow-specific controls.

Repository workflows live directly in the matching Repository Settings, in a
**Workflows** section immediately after **Agents**. It uses the same compact
rows and the same detail page—there is no intermediate workflow page.

The detail page owns these controls and explanations:

| Section | Effect |
|---|---|
| **Workflow** | identity, effective status, and **Enabled**. Disabled workflows disappear from launch surfaces and `prowl workflow run` refuses them with `WORKFLOW_DISABLED`. Repository settings are keyed by canonical repository root plus workflow id, so the same id in two repositories remains independent. |
| **Run** | **Run in <worktree>** names the actual target. Its menu lists other legal worktrees and **Run with Options…**. Repository workflows only list worktrees from that repository. Every choice uses the same admission path as the other GUI and CLI entry points; if that explicit worktree closes first, Prowl refuses the run instead of falling back to another target. |
| **Roles** | every `current`, `pick`, and `launch` role with a plain-language behavior summary. Only a `launch` role has a **Preferred Agent Profile** menu; **Choose Automatically** forgets the preference and lets Prowl resolve a qualifying profile at start. Unqualified profiles remain visible with the reason but cannot be selected. **Manage Agent Profiles…** appears once per page. |
| **Run Setup** | **Follow Workflow**, **Always Review Before Running**, or **Run Directly When Possible**. The last choice starts immediately only when profiles, required role choices, inputs, and validation are already resolved; otherwise the review sheet still opens. |
| **Validation** | every diagnostic as message, source location, and stable code. Saving the YAML revalidates automatically; there is no separate Validate button. |
| **Source File** | **Open Workflow** uses the default YAML app; the folder button reveals it in Finder. **Delete Workflow…** asks for confirmation, then moves a personal or repository workflow to Trash and returns to the list. Failed deletions keep the detail open with an error. Built-ins are read-only and cannot be deleted. YAML remains the source of truth—Settings does not embed an editor. |

Starting from Settings keeps the review panel in the Settings window. Cancelling
returns to the same detail without bringing the main window or terminal forward.

**New Workflow…** writes a validated starter (`new-workflow.pwlworkflow/workflow.yaml`, then
`new-workflow-2.pwlworkflow/workflow.yaml`, …) into the current page's workflow folder and opens it
in the default YAML app. **Ask an Agent…** provides a copyable prompt that
points at the bundled `prowl-workflow` skill and this manual. The folder button
reveals the current workflow folder, creating it when needed.

The page follows its source folders live, so saving, adding, deleting, or
renaming YAML updates the index and an open detail automatically. If an open
file disappears, its detail becomes **Workflow Unavailable** instead of
silently switching to another workflow.

A banner mirrors start admission: Install when `prowl` is missing (Repair for a
dangling link, Reinstall for a foreign non-executable link), or the reason Prowl
is not listening on its socket. The same status appears under Settings → Agents
→ CLI & Skills → Connection.

## Gotchas for agents

- Validate before handing over: `prowl workflow validate <bundle.pwlworkflow>` works with Prowl
  closed and is the static check; Settings shows the same diagnostics plus
  availability warnings (installed runtimes, enabled profiles) that only the
  app can evaluate. Errors, not warnings, make a file unrunnable — and its row
  says so.
- `prowl.*` ids are reserved for built-ins; a user or repo file using one is
  invalid (`reserved_id`).
- Repository workflows are visible only from that repository's worktrees;
  `prowl workflow list` from a pane answers for that pane's worktree.
- A remembered binding is keyed by the role's requirements (`agents`,
  `suggest`, …): editing those in the file forgets the binding; editing prompts
  keeps it.
- Participants must deliver with the exact `prowl workflow deliver …` command Prowl
  typed (token included); `prowl agents dispatch-complete` is refused inside a
  workflow activation with `WORKFLOW_DELIVERY_REQUIRED`.
- Nothing is closed automatically; a launched reviewer pane stays open after the
  run unless the workflow has a `close:` step.

## Script actions and bundles

Local actions live under `actions/<id>/action.yaml` in a `.pwlworkflow` bundle, with scripts,
helpers, and assets beside them. Steps reference `local:<id>` or `builtin:collect-worktree-context`.
Action inputs and results are typed JSON; validated results appear at
`actions.<step>.output` and `actions.<step>.output_path`. The built-in repository context
writes per-invocation artifacts, not shared handoff files. Legacy `prowl handoff` remains a
separate CLI feature. These actions are also distinct from shell-command Custom Actions.

Scripts have your local user permissions. In Settings > Agents > Workflows, open the bundle's
script review, inspect the source location, interpreter, entrypoint, and changed files, then
approve that version. Approval does not start the workflow. CLI starts and single-action tests
use the same approval; the CLI cannot grant it. Changing or moving a bundle requires review
again. A run uses a fixed definition copy; changes to that copy invalidate execution.

Use `prowl workflow test-action <workflow-id> local:<id> --input-json '{}'` to exercise one
approved action in a real run. Then run the workflow to test its agent interactions and data
flow. Tests have the same side effects as normal execution. Each attempt records its request,
result, metadata, bounded raw stdout/stderr, and artifacts under the run's `actions/<step>/<execution UUID>/`.
Retries create a fresh attempt and can repeat side effects. Cancel and timeout terminate the
owned script process group; neither operation rolls back completed work.

Typed `state` retains values explicitly. Branch and loop iteration results leave scope on
exit. Use state to carry a verdict/path to the next iteration. A loop with no cap is permitted;
a loop whose condition remains true at `max_iterations` ends as `iteration_limit_reached`.
In the condition, `context.step.id` names the loop and `context.step.iteration` is the
completed count, starting at 0. Steps in the body use iteration numbers starting at 1.
A role stays bound for the run: launch it once, then send messages for repeated work.

Install the `prowl-workflow` skill for bundle examples, the action manifest and JSON protocol,
approval guidance, expression rules, and test commands.

When a script bundle needs approval, the workflow start screen provides **Review Bundle…**
and keeps Run disabled. Approval returns to the same start screen; it does not start a run.

## Sandbox access

`workflow read` and `workflow deliver` use the existing Prowl Unix socket. File-read
access and socket access are separate permissions. If the runtime returns
`SOCKET_PERMISSION_DENIED`, use its native approval mechanism for the specific
Prowl command or socket; do not disable sandboxing or grant home-directory access.
An existing `current` or `pick` pane keeps its launch permissions. Prowl does not
retrofit new sandbox grants into it. No project-local staging is automatic.

For isolated Debug acceptance, `PROWL_DEBUG_DATA_DIRECTORY` selects temporary
settings, cache, and workflow-history storage. Use a separate Debug process and
matching `PROWL_CLI_SOCKET`. Release builds ignore this directory override.

### Fixed size limits

| Content | Limit |
| --- | --- |
| Action input and `test-action --input-json` | 16 MiB |
| Action stdout | 16 MiB |
| Action stderr | 4 MiB |
| `workflow deliver` body (CLI and App) | 16 MiB of UTF-8 |
| `workflow read` page | 256 KiB; continue with `next_offset` |
| Complete launch prompt, including protocol text | 128 KiB |
| Frozen workflow bundle | 64 MiB / 8192 entries |
| `history.json` | 64 KiB |
| JSON socket frame / serialized action request | 96 MiB + 64 KiB, including escaping and envelope fields |

Action input is measured as compact JSON; request context and JSON escaping have
separate transport headroom. These are Prowl limits; an agent runtime can impose
a smaller launch limit. Larger results should use action artifacts. Individual
artifacts and complete runs have no hard byte cap; the 5 GiB history budget remains soft.

`history.json` holds bounded display and lifecycle fields, separately from full
action/state data in `run.json`. Long workflow names are shortened only in history
metadata. History scans check the record's file identity without decoding its
contents. Missing metadata or a changed record protects the run from cleanup and
export until it can be inspected. Record replacement invalidates the old metadata
before publishing the new pair. No old-history migration or fallback is performed.
