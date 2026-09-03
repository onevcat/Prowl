---
name: prowl-workflow
description: >-
  Author, validate, run, and participate in Prowl Agent Workflows — the `prowl.workflow/v1`
  YAML files that orchestrate several live coding agents (launch, message, loop on verdicts,
  collect outputs) inside the running Prowl app. Reach for this whenever the user wants a
  workflow created or edited ("write me a Prowl workflow that has two agents review each
  other", "add an input to the guessing-game workflow"), wants one executed ("use Prowl's
  adversarial-review workflow on this branch", "run the count-files workflow", "跑一下
  xxx workflow"), asks about a run's progress or its result files, or when a `[Prowl] …`
  line with a `prowl workflow done` command appears in this pane — that means this agent is
  a participant in a run and must deliver through the workflow protocol. Not for driving
  individual panes directly (use prowl-cli) and not for Prowl settings/UI questions.
metadata:
  prowl-summary: Teaches an agent to write, validate, and run Prowl Agent Workflow YAML files, to act as a participant when a workflow messages it, and to read a run's logs and output files. Link it into a runtime's skill folder so the agent can build and drive multi-agent workflows on request.
---

# Prowl Agent Workflows

A workflow is one YAML file (`schema: prowl.workflow/v1`) that scripts several live agents:
who takes part (`roles`), and what happens in order (`steps` — launch an agent, message one,
loop until a verdict, ring a notification, close a pane). The running Prowl app executes it;
every participant is a real terminal pane. Definitions are discovered from three sources,
later shadowing earlier by id: the app bundle (ids `prowl.*`, reserved), user
(`~/.prowl/workflows/*.yaml`), repo (`<repo root>/.prowl/workflows/*.yaml`).

Pick the section for the task; load a reference file only when that task is at hand:

| Task | Where |
| --- | --- |
| Write or edit a workflow | read [references/authoring.md](references/authoring.md) first — full DSL, validator rules, patterns, worked example |
| Start a workflow, inspect or debug a run, decode an error | [Running](#running-a-workflow) below; details in [references/runbook.md](references/runbook.md) |
| A `[Prowl] …` line appeared in this pane | [Participating](#participating-in-a-run) below |

## Authoring loop

Draft → `prowl workflow validate <file>` → fix → place the file → run. Validation is static
and strict; if it passes, the file is runnable. `validate` and `prowl workflow schema` (the
authoritative JSON Schema) work with Prowl closed. Never hand over an unvalidated workflow,
and read `references/authoring.md` before drafting — several rules are not guessable.

## Running a workflow

```bash
prowl workflow list [--json]                  # what this worktree can see, with validation status
prowl workflow run <id|name> [source] \
    [--role r=<profile|auto|pN>] [--input k=v] [--skip <step-id>] [--json]
prowl workflow status [run-id] [--json]       # no args inside a run: who am I / what is awaited
prowl workflow cancel <run-id> [--json]
```

- `[source]` is a pane/tab/worktree reference (`pN`, `tN`, UUID, or the worktree name that
  `prowl workflow list` prints as `Worktree: <name>` — `main`, not the `Repo:main` label of
  `prowl list`). Omitted inside a pane: that pane serves the `current` role and its worktree
  is the run's; outside a pane the focused worktree is used, and a workflow with a `current`
  role fails with `SOURCE_REQUIRED`. Required inputs without defaults must be passed via
  `--input k=v`.
- The run is asynchronous: `run` returns the run id and frozen bindings; poll
  `prowl workflow status <run-id> --json` (`.data.status.state` is `running`,
  `needs_attention`, or a terminal state; `.data.finished_at` appears when it ended) or read
  the run directory (`<worktree root>/.prowl/workflow-runs/<run-id>/` — `log.md` is the
  timeline; field guide, layout, and error tables in `references/runbook.md`). Finishing never
  closes launched panes; only a `close:` step does.
- The GUI starts (Command Palette, Agents capsule popover, Active Agents context menu) go
  through the same admission — behavior is identical to the CLI.

## Participating in a run

When a line like this appears in the pane, this agent is a workflow participant:

```
[Prowl] <instruction…> — finish with: PROWL_WORKFLOW_TOKEN=<token> prowl workflow done [--verdict <v>] -
```

1. Do the work the instruction asks for, completely, before delivering.
2. Deliver by running the **exact rendered command** with the body on stdin as markdown
   (`printf '…' | PROWL_WORKFLOW_TOKEN=… prowl workflow done -`). When verdict variants are
   offered, pick exactly one and run that variant.
3. Include the declared sections; an empty body is rejected, and a body missing declared
   sections/verdict is held as provisional and bothers the user — deliver properly instead.
4. Lost? `prowl workflow status` (no arguments) answers "who am I": this pane's run, role,
   awaited step, its requirements and completion command.
5. Never use `prowl agents dispatch-complete` for a workflow activation — it is rejected
   with `WORKFLOW_DELIVERY_REQUIRED` naming the correct command.
6. A launched participant finds the same contract in its kickoff prompt ("Prowl workflow
   completion protocol"), with the token already in its environment as
   `PROWL_WORKFLOW_TOKEN`.

This skill ships inside the app: `prowl skills install prowl-workflow` links it into every
detected agent skill folder; `prowl skills list` shows per-target status. `prowl-cli` is
the companion skill for driving individual panes outside a workflow.
