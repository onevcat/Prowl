# `prowl profiles` Contract

## Status

Current version: `prowl.cli.profiles.v1`.

`profiles list` is the read-only discovery surface for CLI-driven Profile launches.

## Input

```bash
prowl profiles list [--json]
```

The command accepts no target. It returns every persisted Agent Profile, including disabled
profiles, in Settings list order. It does not trigger or wait for an availability refresh.

## Success

```json
{
  "ok": true,
  "command": "profiles",
  "schema_version": "prowl.cli.profiles.v1",
  "data": {
    "count": 2,
    "profiles": [
      {
        "id": "…",
        "name": "Reviewer",
        "enabled": true,
        "runtime": "claude",
        "availability": {
          "status": "available"
        }
      },
      {
        "id": "…",
        "name": "Offline",
        "enabled": false,
        "runtime": "codex",
        "availability": {
          "status": "unavailable",
          "reason": "Codex is not on your shell's PATH"
        }
      }
    ]
  }
}
```

- `id` is the canonical selector for `create tab|pane --profile`.
- `enabled` is launch admission. Disabled profiles remain discoverable but cannot launch.
- `runtime` is the stable `AgentProfileRuntime` machine token.
- `availability.status` is `available`, `unavailable`, or `unknown`. It reflects only the
  current login-shell executable probe: positive and negative answers are authoritative;
  `unknown` means the asynchronous probe has not completed. Runtime-home heuristics used by
  the UI and one-time Profile seeding are deliberately not part of this contract.
- `availability.reason` is optional human-readable context. Automation must branch on
  `status`, not parse this message.

Availability is advisory and never controls launch admission.

## Errors

`PROFILES_FAILED` uses the common error envelope in
[`cli-output-schema.json`](../../../CLI/Sources/ProwlCLIContracts/Resources/cli-output-schema.json).
