# `prowl agents` Contract

Current version: `prowl.cli.agents.v1`.

```bash
prowl agents [--json]
```

The command is global discovery and accepts no target selector. It returns
`count` and an `agents` array. Each entry has its canonical pane `id`, detected
agent `type`/`name`, `status`, `raw_state`, optional `detection_reason` and `screen_reason`,
`last_changed_at`, project/worktree/tab/pane metadata, and optional session
attribution. Each detected row also contains `signals`, whose `channels` describe current
process/session-epoch evidence by normalized source, confidence, observed event kinds, and
last-seen time. Optional `last` and `last_binding` preserve the latest eligible diagnostic;
stale or unbound evidence never becomes current coverage. Evidence-only shell panes do not
create roster rows. Text output additionally shows a current-process `pN` handle.

Use `prowl agents read <pN|pane-uuid>` for a semantic agent snapshot. A process inside
a Prowl pane can report cooperative runtime events with `prowl agents signal`; these
commands have separate [read](agents-read.md) and [signal](agents-signal.md) contracts.
Condition and exact-receipt waiting, and re-dispatching a new task into an existing agent
pane with `prowl agents dispatch`, are specified by [agents-wait](agents-wait.md).
The complete roster response schema is
`#/$defs/agentsResponse` in
[`schema-bundle.json`](../../../ProwlCLIContracts/Resources/cli-output-schema.json).
