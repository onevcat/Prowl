# `prowl agents signal` Contract

Current version: `prowl.cli.agents.signal.v1`.

```bash
prowl agents signal <turn-ended|needs-input|session-start|session-end|progress>
                    [--progress <0...100>]
                    [--session <id>]
                    [--origin <claimed-origin>]
                    [--detail <short-result-or-reason>]
                    [--json|--no-color]
```

## Semantics

The command reports an observation for the pane that spawned the calling `prowl`
process. It accepts no target selector. The app obtains the kernel peer PID from the
Unix socket, walks process ancestry against live pane shell PIDs, and either attributes the
signal to that exact pane or fails with `SOURCE_REQUIRED`. UI focus and
`PROWL_PANE_ID` are never fallback identity sources.

Events:

- `turn-ended` — the runtime ended one interaction turn; it does not mean an assigned task
  or workflow step completed.
- `needs-input` — progress requires user/agent input.
- `session-start` / `session-end` — producer-reported session lifecycle.
- `progress` — indeterminate when `--progress` is absent, otherwise 0 through 100.

Every public invocation is recorded as `source: cooperative_cli`, `confidence: exact`.
Here `exact` means explicit channel plus exact caller-pane attribution; it does not make the
producer's business judgment authoritative. `--origin` is caller-authored metadata only and
cannot upgrade source/confidence or satisfy a native-hook capability check.

Attribution and evidence eligibility are separate. The receipt reports `binding`:

- `current` — the caller descends from the detected agent's launch process (PID + start time)
  and, when Prowl knows the agent's session, names no other session. The signal is wait and
  dispatch evidence.
- `unbound` — no detected agent, a caller outside the agent's process tree, or a mismatched
  `--session`. The signal is retained only as the diagnostic `signals.last`; it never satisfies
  a wait or dispatch. The command still exits zero, and `data.warnings[]` carries exactly one
  `signal_unbound` item that text mode prints once on stderr.

Terminal events (`turn-ended`, `needs-input`, `session-end`) replace one another as the pane's
active terminal evidence; waits poll that single value every 200 ms rather than consuming a
queue, so two events reported back to back within one interval leave only the later one
observable.

## Bundled native-hook ingress

The bundled CLI also contains a hidden `agents _hook` bridge for Prowl-managed Claude Code,
Codex, Copilot, Droid, Qoder, Pi, Oh My Pi, and OpenCode Profile launches. It is intentionally
absent from help and shell completion and is not a targetable public API. Codex appends one
bounded JSON argv; every other supported runtime writes its payload to bounded stdin (Pi, Oh My
Pi, and OpenCode through Prowl's bundled extensions, which forward the runtime's own event
names such as `agent_settled`, `session_switch`, or `session.idle` in the same envelope). The bridge ignores unknown fields, never forwards `last_assistant_message`, stays
silent, uses a bounded socket attempt, and exits successfully when Prowl rejects or cannot
receive evidence.

The app accepts a hook only when an in-memory launch token, runtime/native event, normalized
launch cwd, exact caller pane, and current or pending process generation all match. A valid
receipt uses `source: hook_claude`, `hook_codex`, `hook_copilot`, `hook_droid`,
`hook_qodercli`, `hook_pi`, `hook_omp`, or `hook_opencode`; neither the token nor forwarding
metadata appears in the response. Public `agents signal` cannot supply hook context and always remains
`cooperative_cli`.

Hook `turn-ended` is runtime evidence only. It never completes an assigned dispatch or
workflow. A matching `dispatch-complete` receipt retains priority over an adjacent hook edge.

`--session` and `--origin` are non-empty, control-free UTF-8 up to 256 bytes. `--detail`
is non-empty, control-free UTF-8 up to 32768 bytes. Detail is a short result or reason returned
with the signal; it is not logged and does not change confidence. Large results use
`agents read`; assigned-task results use `agents dispatch-complete --summary`.

## Success response

Text:

```text
Signaled turn-ended for pane <pane-uuid>.
Signaled progress=75 for pane <pane-uuid>.
```

JSON:

```json
{
  "ok": true,
  "command": "agents.signal",
  "schema_version": "prowl.cli.agents.signal.v1",
  "data": {
    "pane": {
      "id": "6E1A2A10-D99F-4E3F-920C-D93AA3C05764",
      "worktree_id": "/Projects/Prowl"
    },
    "signal": {
      "event": "turn-ended",
      "source": "cooperative_cli",
      "confidence": "exact",
      "binding": "current",
      "at": "2026-08-22T12:00:00.000Z",
      "session_id": "session-1",
      "detail": "Review complete",
      "claimed_origin": "manual-review"
    }
  }
}
```

`binding` is required. An unbound receipt carries `"binding": "unbound"` together with
exactly one `"warnings": [{"code": "signal_unbound", "message": "…"}]` entry under `data`; a
`current` receipt never carries `warnings`, and the schema enforces that pairing. Managed
native-hook receipts are always `current`. Text mode prints `warning: [signal_unbound] …` on
stderr after the receipt line.

Optional fields are omitted rather than encoded as `null`. The executable schema is
`#/$defs/agentsSignalResponse` in
[`cli-output-schema.json`](../../../CLI/Sources/ProwlCLIContracts/Resources/cli-output-schema.json).

## Errors

- `INVALID_ARGUMENT` — invalid event/option combination, progress range, empty value,
  control character, or UTF-8 byte limit.
- `SOURCE_REQUIRED` — the socket peer process cannot be attributed to a live Prowl pane
  (including an external terminal or ancestry broken by tmux/detached wrappers).
- `AGENT_GONE` — the attributed pane closed before the signal was recorded.
- `AGENTS_FAILED` — the app could not encode the signal receipt.

## Deferred paired completion

`dispatch-complete` is deliberately not part of v1 S1. S2 ships one atomic paired path:
CLI `create tab|pane --profile --prompt` returns an opaque `dispatch_id`; the agent reports
`dispatch-complete --outcome succeeded|failed --summary <non-empty-summary>` from its
launch-scoped context; a bounded in-memory receipt survives pane closure but not app restart;
and ID-only `agents wait --dispatch` re-snapshots after observer overflow. Generic runtime
`turn-ended` never substitutes for that dispatch receipt. This paragraph
is a forward reference, not a shipped command contract; the owner-reviewed S2 design is
[064.003](../../064-agent-completion-signals/003-s2-dispatch-wait-design.md), and normative
wait/completion contracts ship with the implementation.
