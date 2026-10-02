# `prowl handoff` Contract

Current version: `prowl.cli.handoff.v2`.

```bash
prowl handoff save [source] [--brief -|--no-brief] [--note <text>] [--json]
prowl handoff to <agent> [source] [--brief -|--no-brief] [--note <text>] [--no-launch] [--json]
```

An explicit generic target follows [targeting.md](targeting.md). With no source,
handoff resolves the pane that spawned the CLI process; it never uses unstable UI
focus. `--brief -` reads a validated briefing from stdin, while `--no-brief` is the
explicit context-only mode.

The success payload reports `action`, `artifact_path`, source/destination agents,
repository summary, change count, briefing state, optional archived path/session
context, and optional launched pane. The complete response contract, including the
v2 schema discriminator, is `#/$defs/handoffResponse` in
[`schema-bundle.json`](../../../CLI/Sources/ProwlCLIContracts/Resources/cli-output-schema.json).
