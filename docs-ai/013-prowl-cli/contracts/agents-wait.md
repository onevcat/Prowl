# `prowl agents wait` and dispatch contracts

## Status

Current versions:

- `prowl.cli.agents.dispatch.v1`
- `prowl.cli.agents.dispatch-complete.v1`
- `prowl.cli.agents.dispatch-abandon.v1`
- `prowl.cli.agents.wait.v1`

## Exact dispatch completion

Every prompted `create tab|pane --profile … --prompt -` returns a pending dispatch, and
`agents dispatch` (below) returns one for an agent already running in a pane. Callers cannot
supply an id to completion manually.

```bash
prowl agents dispatch-complete --outcome succeeded|failed --summary <text> [--json]
```

`--summary` is required, control-free, and limited to 32768 UTF-8 bytes. The app resolves the
socket peer ancestry to the caller's pane and completes that pane's current pending record;
with no pending record it addresses the pane's most recently issued record so an identical
retry replays its receipt and a conflicting one fails. A caller outside any pane fails with
`DISPATCH_CONTEXT_REQUIRED`; a pane that never held a dispatch fails with
`DISPATCH_NOT_FOUND`. The launch child still receives `PROWL_DISPATCH_ID`, and the CLI
forwards it when present, but it is compatibility diagnostics only: a process launched with an
older id completes the pane's current record. Completion is first-write-wins. `turn-ended` is
observation only and never becomes success.

Success returns `target`, completed `receipt`, and `replayed`. The immutable receipt contains
`id`, `state=completed`, `outcome`, `summary`, `created_at`, and `completed_at`.

## Re-dispatch into an existing pane

```bash
prowl agents dispatch <pN|pane-uuid> --prompt - [--json]
```

The pane is resolved once to the immutable target snapshot. `--prompt` accepts only `-` and
reads piped UTF-8 stdin up to 256 KiB; an interactive terminal is rejected. CRLF is
normalized and trailing newlines are dropped by the CLI; the app rejects an empty prompt or
any control character other than newline and tab with `INVALID_ARGUMENT`, because the text is
delivered through the pane's input path (one bracketed paste — `ghostty_surface_text` goes
through Ghostty's paste encoder, so newlines survive as one message in Claude Code and Codex —
followed by Enter) where other control bytes are stripped or reinterpreted.

Checks run in this order, before any text is typed:

1. `DISPATCH_PENDING` when the pane already holds a pending record; `error.details.record`
   carries it. The existing record is never overwritten — complete, abandon, or lose it first.
2. `AGENT_NOT_FOUND` when the pane hosts no detected agent (no appearance grace: the command
   targets an agent that already exists); `AGENT_GONE` when the surface is closed.
3. `DISPATCH_TARGET_BUSY` unless the agent is idle by the arm-time rules of
   `agents wait --until idle` under `auto`: an exact `turn-ended` level counts only with detector
   corroboration (idle/done); a detector-only idle view counts after two seconds unchanged, and
   only where the wait would fall back to the detector (no covering `verified_live` channel, or
   one holding no terminal level). Idle by one source alone — a `turn-ended` the detector has
   not corroborated yet, or a detector view still stabilizing — is not a refusal: the
   precondition polls every 200 ms for up to five seconds, as the wait would, and refuses only
   when the budget expires. A working or blocked detector state without
   such evidence, or a runtime `needs-input` level, refuses immediately.
   `error.details.observation` and `signals` carry the evidence.

Then one main-actor step issues the record and binds it to the pane's *current* evidence
epoch — never a new one, so the generation that will report the receipt is the one already
proven for the pane — and the rendered text (`[Prowl] ` + prompt + the versioned completion
protocol) is inserted and submitted. A delivery failure cancels the issuance. Success returns
`target` and the pending `dispatch` record with the `create` shape; the id never appears in the
typed text.

Every later rule is unchanged: `agents wait --dispatch`, `dispatch-abandon`,
`DISPATCH_NEEDS_INPUT`, `DISPATCH_INCOMPLETE`, `AGENT_GONE`, capacity, and eviction apply to the
new record exactly as to a launch record. One pending record per surface is enforced by the
store on binding (`surfacePending`), so a launch and a re-dispatch can never race for one pane.

## Explicit abandonment

```bash
prowl agents dispatch-abandon --dispatch <id> --reason <text> [--json]
```

Abandonment terminalizes only the coordinator's retained record. It does not stop, close,
succeed, or fail the worker. A retry against an already terminal record (completed, abandoned,
or gone) fails with `DISPATCH_ALREADY_TERMINAL`; later completion is rejected.
Pending records never expire or evict automatically. The in-memory app-lifetime store holds
at most 256 records and evicts the oldest terminal record first; if all 256 are pending, a new
prompted launch fails before creating a surface.

## Exact dispatch wait

```bash
prowl agents wait --dispatch <id> [--timeout 1...600] [--include-screen 1...200] [--json]
```

Dispatch mode is id-only and rejects pane, condition, and confidence options. A succeeded
receipt returns success with `mode=dispatch`, `waited_ms`, immutable `target`, `receipt`,
current `signals`, and optional stable `screen`. Failed, abandoned, gone, needs-input,
incomplete-turn, and timeout outcomes are nonzero structured errors. Known-dispatch error
details retain `mode`, `waited_ms`, `target`, the current tagged-union `record`, available
observation/signal evidence, and stable `screen` evidence when requested.

`turn-ended`, matching `session-end`, and surface close open a 300 ms completion-priority
window. A completion arriving inside the window wins; otherwise waits report
`DISPATCH_INCOMPLETE` or retained `AGENT_GONE`. Detector removal alone is diagnostic. Multiple
waiters are non-destructive. App restart resets all receipts.

## Generic condition wait

```bash
prowl agents wait <pane> --until idle|blocked|changed|exit \
  [--timeout 1...600] [--min-confidence auto|exact|high|heuristic] \
  [--include-screen 1...200] [--json]
```

The pane is resolved once to a stable target. `changed` requires a post-baseline revision.
`exit` is satisfied by an exact `session-end`, by surface closure, or — when no `verified_live`
channel can report `session-end` (Codex's notifier, OpenCode's relay, a manually launched
agent) — by the detector losing the agent for two seconds while the surface stays live; a
channel that reports `session-end` makes that signal or surface closure the only exit
evidence. Surface closure satisfies `exit`; for `idle`, `blocked`, or `changed` it returns
structured condition-mode `AGENT_GONE` immediately.
Exact/high current-epoch cooperative evidence wins. `auto` may fall back to a heuristic
idle/blocked match only after the observed detector state has remained unchanged for two
seconds (signals do not restart that window: a matching one resolves the wait exactly, a
contradicting terminal one suppresses the fallback, and a `progress` or `session-start` leaves
it to the labelled heuristic), and only while no covering `verified_live` channel holds a
terminal signal (a channel that has only reported `session-start` does not suppress the
fallback; one holding an opposite level does, so exact evidence is never overridden by the
screen). `changed` never falls back while such a channel exists.
Higher minimum-confidence settings reject weaker
evidence rather than relabelling it.

`idle` and `blocked` are state observations, not edge detectors. The active terminal signal
present when the wait was armed satisfies the condition only when the screen detector
corroborates it (`idle`/`done` for `idle`, `blocked` for `blocked`); a signal that arrives
after arming satisfies it on its own. `changed` is the edge wait. The reported
`observation.status`/`raw_state` are the detector's view at match time; `source` and
`confidence` describe the evidence that matched.

A pane with no detected agent is not an immediate failure: the wait polls for up to
`agentAppearanceGraceMilliseconds` (10 s), bounded by `--timeout`, and only then fails with
`AGENT_NOT_FOUND` carrying condition-mode details (`waited_ms`, `target`, `signals`, optional
`screen`). Once an agent has been seen, its later disappearance does not end an `idle`,
`blocked`, or `changed` wait.

Evidence is bound to PID plus process start time and, when known at exact/high confidence,
the current session id. A dispatch launch accepts its first detected process generation only
when that process started within ten seconds of binding; a later-started process is a
replacement epoch even if the original runtime escaped detection. Medium-confidence session
guesses remain diagnostic and never bind or rotate an evidence epoch. PID reuse, delayed
children, replaced sessions, mismatched sessions, and unverifiable sessionless signals remain
diagnostic only. Generic success and timeout
details report the actual source, confidence, timestamp, revision, and current signal channels.

When requested, screen evidence reads the detection buffer every 200 ms until unchanged for
800 ms, capped at two seconds, and returns only the requested trailing lines. Success payloads
and structured wait errors both retain it. It is evidence, not completion proof.

## Cancellation and schemas

After consuming a request frame, the app monitors the Unix peer without consuming response
bytes. EOF, unexpected extra input, or task cancellation cancels the route and unregisters
wait-store subscribers promptly; no response is written to a disconnected peer.

All dispatch records and wait mode/screen payloads are strict tagged unions with
`additionalProperties: false`. Errors may include governed `error.details`; legacy errors
omit it. Canonical executable schemas live in
[`cli-output-schema.json`](../../../ProwlCLIContracts/Resources/cli-output-schema.json).
