# Deprecated `prowl pane` Contract

`prowl pane close` is a deprecated compatibility alias for `prowl close <pane>`.
It is retained for one shipped release only.

- Help labels the group and leaf command `[Deprecated]`.
- Every invocation writes a migration warning to stderr without contaminating JSON
  stdout.
- During the window it preserves its legacy parser, selector projection, wire command
  (`pane`), response schema (`prowl.cli.pane.v1`), and output payload.
- New docs and automation must use `prowl close pN`, `prowl close --pane <uuid>`,
  or the equivalent tab form.

The legacy success payload remains `{ "action": "close", "target": … }`; the
complete schema is `#/$defs/paneResponse` in
[`schema-bundle.json`](../../../CLI/Sources/ProwlCLIContracts/Resources/cli-output-schema.json).
