---
name: prowl-workflow
description: >-
  Author, validate, run, and participate in Prowl Agent Workflows — the `prowl.workflow/v1`
  bundles that orchestrate several live coding agents (launch, message, loop on verdicts,
  collect outputs, run built-in or local script actions) inside the running Prowl app.
  Use it to create, test, or debug a workflow action. Reach for this whenever the user wants a
  workflow created or edited ("write me a Prowl workflow that has two agents review each
  other", "add an input to the guessing-game workflow"), wants one executed ("use Prowl's
  adversarial-review workflow on this branch", "run the count-files workflow", "跑一下
  xxx workflow"), asks about a run's progress or its result files, or when a `[Prowl] …`
  line with a `prowl workflow deliver` command appears in this pane — that means this agent is
  a participant in a run and must deliver through the workflow protocol. Not for driving
  individual panes directly (use prowl-cli) and not for Prowl settings/UI questions.
metadata:
  prowl-summary: Teaches an agent to write, validate, and run Prowl Agent Workflow bundles, to create and test local script actions, to act as a participant when a workflow messages it, and to read a run's logs and output files. Link it into a runtime's skill folder so the agent can build and drive multi-agent workflows on request.
---

# Prowl Agent Workflows

A workflow is a `.pwlworkflow` directory with `workflow.yaml` (`schema: prowl.workflow/v1`)
and optional local script actions, helpers, schemas, and assets. It declares roles and
sequential steps, typed state, nested conditions and loops. Prowl executes it; agent roles
use real terminal panes. Sources, later shadowing earlier by ID: app bundle (`prowl.*`
reserved), user (`~/.prowl/workflows/*.pwlworkflow`), repo
(`<repo root>/.prowl/workflows/*.pwlworkflow`). Pass bundle directories, not loose YAML files.

Pick the section for the task; load a reference file only when that task is at hand:

| Task | Where |
| --- | --- |
| Write or edit a workflow | read [references/authoring.md](references/authoring.md) first — full DSL, validator rules, patterns, worked example |
| Create or test a script action | [references/actions.md](references/actions.md) — package layout, JSON protocol, approval, result records |
| Start a workflow, inspect or debug a run, decode an error | [Running](#running-a-workflow) below; details in [references/runbook.md](references/runbook.md) |
| A `[Prowl] …` line appeared in this pane | [Participating](#participating-in-a-run) below |

## Authoring loop

Read `references/authoring.md`, draft the requested workflow, validate it with
`prowl workflow validate <bundle.pwlworkflow>`, and fix errors while assessing warnings. `validate` and
`prowl workflow schema` work with Prowl closed. Passing static validation does not guarantee
start-time admission or successful execution: profiles, panes, inputs, CLI connectivity,
and the agents' work still matter. If validation cannot run, disclose that limitation.
Creating a definition does not itself require starting it; run it when that is part of
the user's request.

For launch roles, **omit `agents` unless the user explicitly requires particular runtimes
or the task has a concrete runtime-specific requirement**. Omission allows any qualifying
Agent Profile. Do not invent an allow-list from your own runtime, installed profiles,
example tokens, or assumptions about which model is best. Leave `suggest` unset too unless
it expresses a user-provided preference or a concrete task requirement; let Prowl's profile
picker and saved preferences choose the agent by default.

Examples demonstrate individual capabilities, not a mandatory architecture. Use the roles,
steps, and output contracts the task needs; add loops, deadlines, and automatic pane closure
only when their behavior serves the requested outcome. The authoring reference explains
data dependencies, loop exits, and typed state and result scopes.

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
- When starting from the `current` role's own pane, inspect the `run` response for
  `self_initiated` (`.data.self_initiated` with `--json`). If present, follow its `line` or
  `instruction_path` and completion command yourself; Prowl does not type that first task
  back into the same pane. Waiting for another message would leave your own step unfinished.
- The run is asynchronous: `run` returns the run id and frozen bindings; poll
  `prowl workflow status <run-id> --json` (`.data.status.state` is `running`,
  `needs_attention`, or a terminal state; `.data.finished_at` appears when it ended) or read
  the run directory (`~/.prowl/logs/workflow-runs/<root-name>-<root-hash>/YYYY-MM/<run-id>/` — `log.md` is the
  timeline; field guide, layout, and error tables in `references/runbook.md`). Finishing never
  closes launched panes; only a `close:` step does.
- The GUI starts (Command Palette, Agents capsule popover, Active Agents context menu) go
  through the same admission — behavior is identical to the CLI. Settings › Agents › Workflows
  lists every bundle with the same validation diagnostics, the enable toggle (a disabled workflow
  is `WORKFLOW_DISABLED` for `run`), and the remembered profile per launch role.

## Participating in a run

An active task delivered by Prowl in this pane, a launched role's kickoff protocol, or a
`self_initiated` task in the run response makes this agent a participant. A message task
looks like this:

```
[Prowl] <instruction…> — finish with: PROWL_WORKFLOW_TOKEN=<token> prowl workflow deliver [--verdict <v>] -
```

1. Do the work the instruction asks for, completely, before delivering.
2. Deliver by running the **exact rendered command** with the body on stdin as markdown
   (`printf '…' | PROWL_WORKFLOW_TOKEN=… prowl workflow deliver -`). When verdict variants are
   offered, pick exactly one and run that variant.
3. Include the declared sections, format, and verdict. Empty bodies are rejected; other
   contract mismatches are provisional by default or rejected under `strict: true`. Check
   the receipt: **Delivered** means accepted; **Provisional** still needs resolution, even
   when the command exits successfully. Do not report a step completed merely because its
   output file exists. A provisional delivery waits for the user's decision; **Ask again**
   reopens delivery so you can correct it. Do not blindly resubmit or invent a replacement
   token; [runbook](references/runbook.md) explains the states.
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

## Assigned content and retention

Use the scoped `prowl workflow read` command supplied with the task to retrieve
instructions. Read returned resource IDs with the same run ID and invocation number;
`workflow-resource:` references are handles, not filesystem paths. Use `--json`
for byte-preserving reads, decode each chunk by its `encoding`, and continue with
`--offset <next_offset>` until `next_offset` is absent. Only the assigned pane can read this content; reads do not require a token.
Deliver ordinary text/JSON on stdin with `prowl workflow deliver -`; no project-local
temporary output file is needed. Explicit delivery is required.

Run artifacts expire with their run: 30 days for unpinned terminal runs, with a
5 GiB soft global budget and a 24-hour diagnostic window. Keep Run prevents automatic
cleanup. Export a terminal run from Execution History for a durable complete ZIP.
