# Handoff — Workflow

> Use the built-in `prowl.handoff` workflow to collect an agent-authored briefing,
> preserve durable context under `.prowl/handoff/`, and optionally launch a receiver.

**Keywords:** handoff, hand off, briefing, workflow, `.prowl/handoff`, current.md, cross-agent, workspace

**Related:** [workflows](workflows.md#built-in-handoff) · [cli](cli.md) · [workspaces](workspaces.md)

## Start a handoff

Run the workflow from the source agent pane. With a receiver, select an enabled Agent Profile:

```bash
prowl workflow run prowl.handoff --role receiver=Codex --json
```

For a save-only handoff, no receiver is required:

```bash
prowl workflow run prowl.handoff --input next=save --json
```

The start response contains `self_initiated.line`. Follow that exact instruction and deliver a
Markdown briefing with `## Objective`, `## Current State`, and `## Next Steps`. A completed
workflow confirms the packet was saved and, when requested, that the receiver was launched; it
does not mean the receiver has finished the task.

The same workflow is available from the Agents popover, Active Agents context menu, Command
Palette, and Settings › Agents › Workflows. Those entry points use the normal workflow start
sheet and profile admission rather than a dedicated Handoff UI.

## Durable packet

`builtin:save-handoff` validates the briefing before changing shared state. It saves generated
repository and source-session context beneath the runnable root:

```text
<root>/.prowl/handoff/
  current.md
  context.md
  archive/workflow-<run UUID>.md
  sessions/
```

The receiver uses its immutable run-specific packet in `archive/`; later workflow runs can
update `current.md` without changing that packet. Prowl creates a local `.gitignore` for this
state. Keep secrets out of the briefing, and use the toolbar's Workflow History to inspect the
recorded run.

## Retired CLI migration

For one release, `prowl handoff …` returns `HANDOFF_RETIRED` without connecting to Prowl,
writing artifacts, or starting an agent. Use the workflow commands above; the error repeats
the receiver and save-only replacements so old scripts cannot silently perform a different
operation.

## Safety

Saving reads repository state and does not commit, push, or execute destructive Git commands.
A source pane must have a detected agent, and the receiver is launched only when the workflow
selects that branch. Existing `.prowl/handoff/` artifacts remain available to the workflow and
history file actions.
