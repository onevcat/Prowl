# `prowl close` Contract

## Status

Current version: `prowl.cli.close.v1`.

`close` is the action-first destructive lifecycle command. Its target spelling
selects the resource to close; it never projects a worktree to a focused tab/pane.

## Input

```bash
prowl close <pane-or-tab> [--force] [--json]
prowl close --pane <pane> [--force] [--json]
prowl close --tab <tab> [--force] [--json]
```

The positional form accepts only a UUID, `pN`, or `tN`. A prefixed handle routes to
that resource type; an unprefixed UUID resolves pane first, then tab. `--pane` and
`--tab` retain typed bare-number handles. A target is mandatory.

Reject `--target`, `--worktree`, bare-number positionals, cross-selector mixing,
and positional-plus-selector mixing with `INVALID_ARGUMENT` before transport.

Without `--force`, protected agent work or a running command may trigger the same
GUI confirmation policy as an app-originated close. `--force` skips that policy and
must only be used after identifying the target.

## Success

```json
{
  "ok": true,
  "command": "close",
  "schema_version": "prowl.cli.close.v1",
  "data": {
    "resource": "pane",
    "target": { "worktree": { "id": "…" }, "tab": { "id": "…" }, "pane": { "id": "…" } }
  }
}
```

`resource` is `pane` or `tab`; `target` describes the resource immediately before
it was closed.

## Errors

`INVALID_ARGUMENT`, `TARGET_NOT_FOUND`, `TARGET_NOT_UNIQUE`, and `CLOSE_FAILED`
use the common response envelope in
[`schema-bundle.json`](../../../CLI/Sources/ProwlCLIContracts/Resources/cli-output-schema.json).
