# CLI Contract: `prowl agents read`

> Living normative contract of entry 013.

This file defines the immediate agent-snapshot command:

```bash
prowl agents read <pN|pane-uuid> [--max-bytes <1...4194304>] [--result-only] [--json]
```

## Scope

V1 supports only a currently active **Codex** or **Claude Code** pane. The target is
always explicit: use the `pN` shown by text `prowl agents`, or the canonical
`.data.agents[].pane.id` from JSON `prowl agents`. Worktree/tab selectors, focus-derived
targets, wait mode, and timeouts are deliberately unsupported.

The command takes one immediate snapshot. It is read-only; respond to a blocker with
the existing `prowl key --pane …` or `prowl send --pane …` commands. The read and a
later write are not atomic, so automation should re-read before a consequential action.

## Snapshot semantics

A successful snapshot always reports the currently observed agent status. A transcript
result is separate evidence and may be unavailable without invalidating the live
snapshot. This prevents an unresolvable transcript from hiding a useful blocker.

- `status` is Prowl's stabilized `working`, `blocked`, `done`, or `idle` display state.
- `raw_state` and `screen_reason` come from the fresh active-screen classifier.
- `detection_reason` explains the final state decision. Log evidence can override a
  retained screen frame; only `status: blocked` indicates a current blocker.
- `blocker.text`, when present, is the current typed-profile interaction region. It
  preserves the question, visible options, current selection marker, and keyboard hints;
  it is not a reconstructed or generic terminal viewport.
- Transcript access requires a fresh `exact` or `high` native session resolution. A
  `medium` candidate is never read.

## Success payload

```json
{
  "ok": true,
  "command": "agents.read",
  "schema_version": "prowl.cli.agents.read.v1",
  "data": {
    "output_mode": "snapshot",
    "target": {
      "worktree": { "id": "/Projects/App", "name": "main", "path": "/Projects/App", "root_path": "/Projects/App", "kind": "git" },
      "tab": { "id": "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0", "title": "Agent", "selected": true },
      "pane": { "id": "6E1A2A10-D99F-4E3F-920C-D93AA3C05764", "title": "Claude", "cwd": "/Projects/App", "focused": false }
    },
    "agent": {
      "type": "claude",
      "status": "blocked",
      "raw_state": "blocked",
      "detection_reason": "claude.blockedPrompt",
      "screen_reason": "claude.blockedPrompt",
      "last_changed_at": "2026-08-11T12:00:00Z"
    },
    "blocker": {
      "text": "Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel · Tab to amend"
    },
    "result": {
      "state": "unavailable",
      "error": {
        "code": "SESSION_UNRESOLVED",
        "message": "No exact or high-confidence transcript session is available."
      }
    }
  }
}
```

`target` follows the shared resolved-target shape in `read.md`. `agent.session` is
present only when the transcript result used an eligible session; it contains `id`,
`confidence` (`exact` or `high`), and `source`, never a local transcript path.

### `result`

| `state` | `text` | Meaning |
| --- | --- | --- |
| `complete` | required | A final answer from a complete, attributable native transcript turn. |
| `pending` | absent | The agent is working or blocked; the transcript is not consulted, so an earlier completed turn is never surfaced as the current result. |
| `unavailable` | absent | Idle/done agent without an exact/high transcript session. |
| `missing` | absent | Idle/done agent has no completed final answer in its trusted transcript. |
| `incomplete` | absent | The candidate turn is max-token-limited, malformed, unsupported, or not closed. |
| `too_large` | absent | A complete answer exceeds the requested `max_bytes`. |

Non-`complete` states include `result.error` with the stable code
`SESSION_UNRESOLVED`, `RESULT_NOT_FOUND`, `RESULT_INCOMPLETE`, or
`RESULT_TOO_LARGE`, except `pending`, which is ordinary live activity rather than an
error. Partial text is never returned.

Codex accepts only a latest terminal `event_msg.payload.type == "task_complete"`
record with a non-empty `turn_id`, integer Unix-seconds `completed_at`, non-empty
`last_agent_message`, and no `error`. A newer `turn_aborted` terminal event makes
the result incomplete instead of exposing an earlier answer. Claude Code accepts a
`system/turn_duration` close record and a bounded same-session parent chain to an
assistant message containing only text blocks with `end_turn` or `stop_sequence`.

## Text output

Without `--json`, default output is uncoloured Markdown-like text. It always includes
`Agent`, `Status`, `Reason` when known, `Changed`, and `Result`; it then appends
`## Blocker` and/or `## Latest result` as applicable.

`--result-only` is text-only and is mutually exclusive with `--json`. It succeeds only
for `result.state == "complete"`, writes the result bytes exactly to stdout (no heading
or synthetic trailing newline), and otherwise exits non-zero with the corresponding
result error code.

## Limits

`--max-bytes` defaults to 1,048,576 and accepts `1...4,194,304`. The limit applies to
the UTF-8 result text before response encoding. Oversized results are not truncated and
are never written to an output file. Socket frames permit up to 32 MiB, independently
of the smaller result limit.

## Error payload and codes

Normal snapshot failures use the standard error envelope with command
`"agents.read"` and schema `"prowl.cli.agents.read.v1"`.

| Code | Meaning |
| --- | --- |
| `INVALID_ARGUMENT` | Invalid pane form, `max_bytes`, or `--result-only --json`. |
| `TARGET_NOT_FOUND` | The explicit pane handle/UUID no longer resolves. |
| `AGENT_NOT_FOUND` | The pane no longer hosts an active agent. |
| `AGENT_UNSUPPORTED` | The active agent is not Codex or Claude Code. |
| `AGENT_READ_FAILED` | Prowl cannot capture the active screen. |
| `BLOCKER_UNREADABLE` | A blocked screen was detected but no coherent interaction region could be extracted. |
| `SESSION_UNRESOLVED` | `--result-only` requested a result without exact/high session evidence. |
| `RESULT_NOT_FOUND` | `--result-only` requested a result but no completed answer exists. |
| `RESULT_INCOMPLETE` | `--result-only` requested a non-final or unsupported result. |
| `RESULT_TOO_LARGE` | `--result-only` requested a result over `max_bytes`. |
