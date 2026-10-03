# `prowl create` Contract

## Status

Current version: `prowl.cli.create.v1`.

`create` is the action-first lifecycle namespace. V1 exposes deterministic tab and split-pane creation.

## Input

```bash
prowl create tab <worktree> [--path <directory>] [--profile <name|uuid> [--prompt -] [--background]] [--json]
prowl create tab --worktree <worktree> [--path <directory>] [--profile <name|uuid> [--prompt -] [--background]] [--json]
prowl create pane <pane> --direction <right|left|up|down> [--profile <name|uuid> [--prompt -] [--background]] [--json]
prowl create pane --pane <pane> --direction <right|left|up|down> [--profile <name|uuid> [--prompt -] [--background]] [--json]
```

`create tab` requires exactly one positional worktree reference or `--worktree`. `--pane`,
`--tab`, and a positional-plus-flag combination fail before transport with `INVALID_ARGUMENT`.
`--path` is normalized by the CLI and must be the resolved worktree root or a subdirectory
of it. A path outside the worktree fails with `PATH_NOT_ALLOWED`.

`create pane` requires exactly one pane UUID or current-process `pN` handle, positionally or
through `--pane`, plus an explicit direction. It rejects `--target`, `--worktree`, `--tab`,
bare numeric handles, `--path`, and positional-plus-flag targeting. Public `up` maps to the
terminal layer's internal top direction. The operation resolves the anchor directly; it never
focuses a different pane as an intermediate targeting step.

Without `--profile`, the new pane inherits the anchor's working directory and split surface
configuration, becomes focused, and Prowl selects the anchor's worktree and tab exactly as
`create tab` selects the target worktree.

`--profile` launches one enabled Agent Profile in the new resource. Lookup tries a matching
UUID first, then an exact name among enabled profiles; duplicate enabled names fail with
`PROFILE_NOT_UNIQUE`, while missing or disabled profiles fail with `PROFILE_NOT_FOUND`.
Runtime availability is advisory and never blocks launch. `--prompt` accepts only `-` and
reads a non-empty kickoff prompt from piped UTF-8 stdin; an interactive terminal is rejected
instead of waiting for EOF. The UTF-8 payload is capped at 256 KiB; oversized input returns
`INVALID_ARGUMENT` before any surface exists. `--prompt` and `--background` require
`--profile`. Prompt text is carried in a reserved surface-environment carrier and expanded as
one quoted argv token; it is not written through Ghostty's initial PTY input stream. The typed
line is one `env -u` command with no assignment statement or shell builtin, so the same form
runs in zsh, bash, and fish. `env -u` keeps the carrier out of the Profile process; the pane
shell retains the reserved carrier for its lifetime. NUL bytes are rejected.

Profile launches first complete any bounded managed-signal preflight. No dispatch slot or
surface exists while that asynchronous work is suspended. After preflight, dispatch issuance,
surface creation, exact pre-input signal registration, dispatch binding, and rollback are one
synchronous transaction with no suspension point. One Profile launch owns one evidence epoch;
a prompted dispatch adopts the epoch already created by its managed hook registration.

Every prompted Profile launch is paired atomically with a pending dispatch; there is no
opt-out. Prowl injects `PROWL_DISPATCH_ID` into the launched child only and appends the
versioned completion instruction to the effective prompt. An unprompted Profile launch
retains its interactive behavior and creates no dispatch. If launch, target snapshot, signal
registration, or dispatch binding fails, Prowl removes the new resource and cancels the
unreturned receipt.

Foreground profile launches select the destination worktree/tab and focus the returned pane.
A background tab is created without changing the selected worktree, tab, or pane. A
background split is inserted beside the resolved anchor without focusing it and without
selecting a hidden anchor's worktree/tab. Split creation always targets the pre-resolved
anchor directly and inherits its working directory; `--path` remains tab-only.

## Success: tab

```json
{
  "ok": true,
  "command": "create",
  "schema_version": "prowl.cli.create.v1",
  "data": {
    "resource": "tab",
    "target": {
      "worktree": { "id": "…", "name": "App", "path": "/…", "root_path": "/…", "kind": "git" },
      "tab": { "id": "…", "title": "zsh", "selected": true },
      "pane": { "id": "…", "title": "zsh", "cwd": "/…", "focused": true }
    }
  }
}
```

## Success: pane

```json
{
  "ok": true,
  "command": "create",
  "schema_version": "prowl.cli.create.v1",
  "data": {
    "resource": "pane",
    "anchor": {
      "worktree": { "id": "…", "name": "App", "path": "/…", "root_path": "/…", "kind": "git" },
      "tab": { "id": "…", "title": "zsh", "selected": true },
      "pane": { "id": "anchor-uuid", "title": "zsh", "cwd": "/…", "focused": true }
    },
    "direction": "right",
    "target": {
      "worktree": { "id": "…", "name": "App", "path": "/…", "root_path": "/…", "kind": "git" },
      "tab": { "id": "…", "title": "zsh", "selected": true },
      "pane": { "id": "created-uuid", "title": "zsh", "cwd": "/…", "focused": true }
    }
  }
}
```

`target` identifies the newly created resource. Pane creation additionally records the resolved
`anchor` and public `direction`. `anchor` is the snapshot taken when the selector was resolved,
before the split: its `focused` / `selected` flags describe the pre-split state and may read
`true` alongside the same flags on `target`. UUID fields are the automation-safe output of this
command.

A successful Profile launch adds the following field to either tab or pane data; ordinary
shell creation omits it. When the CLI requested `--profile`, omission of this metadata is a
contract failure, preventing a newer CLI from silently accepting an ordinary shell created by
an older app:

```json
{
  "launch": {
    "profile_id": "…",
    "profile_name": "Reviewer",
    "agent": "claude"
  }
}
```

When the Profile launch was prompted, success additionally requires a pending dispatch
record. A newer CLI fails closed if an older app omits it, because the created worker would
otherwise have no completion contract:

```json
{
  "dispatch": {
    "id": "opaque-dispatch-id",
    "state": "pending",
    "created_at": "2026-08-23T04:00:00.000Z"
  }
}
```

`dispatch` is absent for unprompted Profile launches and ordinary shell creation. The target
returned alongside it is the immutable target retained by the dispatch store for later wait
success and error payloads.

A safe managed-hook preparation failure does not fail the Profile launch or alter its original
argv. Success instead adds exactly one optional warning (omitted when empty):

```json
{
  "warnings": [
    {
      "code": "managed_hook_degraded",
      "runtime": "codex",
      "message": "The effective Codex notifier could not be resolved."
    }
  ]
}
```

JSON mode retains `warnings` in stdout. Text mode renders the successful launch normally on
stdout and writes each warning exactly once to stderr. Degradation creates no persistent
public channel state and never changes dispatch receipt semantics.

## Errors

`INVALID_ARGUMENT`, `EMPTY_INPUT`, `TARGET_NOT_FOUND`, `TARGET_NOT_UNIQUE`,
`PROFILE_NOT_FOUND`, `PROFILE_NOT_UNIQUE`, `PATH_NOT_ALLOWED`, and `CREATE_FAILED` use the
common error envelope. Unsupported prompted starts and invalid prompt values return
`INVALID_ARGUMENT`; creation/provisioning failures retain a specific human-readable reason
under `CREATE_FAILED`. Client-side version mismatch errors warn that an ordinary shell or
Profile pane may already have been created and direct the caller to inspect `prowl list` and
close it. See
[`cli-output-schema.json`](../../../CLI/Sources/ProwlCLIContracts/Resources/cli-output-schema.json).
