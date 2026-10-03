# Deprecated `prowl tab` Contract

`prowl tab create` and `prowl tab close` are deprecated compatibility aliases for
`prowl create tab` and `prowl close <tab>`. They are retained for one shipped
release only.

- Help labels the group and leaf commands `[Deprecated]`.
- Every invocation writes a migration warning to stderr. JSON stdout remains valid.
- During the window, aliases retain their existing parser, selector projection, wire
  command (`tab`), response schema (`prowl.cli.tab.v1`), and output payload exactly.
- New docs and automation must not use them.

`tab` success payloads retain `{ "action": "create"|"close", "target": … }`.
The complete legacy response schema is `#/$defs/tabResponse` in
[`schema-bundle.json`](../../../CLI/Sources/ProwlCLIContracts/Resources/cli-output-schema.json).
