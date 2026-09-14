# Claude state provider — implementation and spike

Status: native aggregate provider implemented after the 2026-09-15 contract extension;
required acceptance is complete; see [001 action log](001-action.md) and
[002 implementation and acceptance](002-native-runtime-implementation.md).
The 2026-09-14 findings and original proposal below remain the research baseline.
The implementation uses native snapshots; JSONL corroborates the contract without
adding a duplicate production work ledger.

## Implemented adapter

`supacode/Infrastructure/AgentDetection/ClaudeRuntimeProvider.swift` reads at most
64 KiB from the detected PID's registry on the existing poll clock. The pure
`ClaudeRuntimeDecoder` validates PID, UTC process start, session UUID, absolute cwd,
interactive Darwin kind, timestamps, and supported status. Exact OS generation is
checked before and after acquisition. Older snapshots suspend authority.

`busy` and `shell` map to Working, `waiting` to Blocked, and `idle` to Idle. Native
state includes observed assigned children and background shell work, including work
retained across `/new`. It remains private, process-scoped heuristic evidence; a
native Idle is neither successful task delivery nor a public completion signal.

Missing/partial reads suspend authority; unsupported records revoke it. Recovery
uses the next complete snapshot without waiting for new transcript bytes. The
coordinator rebinds on process generation or configured root changes and preserves
capture ordering. An unchanged completed frame stays suppressed during suspension;
a changed blocker or interaction can become fresh screen evidence.

The supported root is the existing Prowl launch profile's config root, or `~/.claude`
by default. Shell-only root overrides without that profile, daemon/remote kinds,
and unsupported schemas use screen fallback. Older versions are not separately
supported. No version switch, hook installation, messaging socket, transcript scan,
or additional timer is introduced.

## Original recommendation and evidence scope

Reuse [shared arbitration](architecture.md), with a process-scoped native status
snapshot and optional selected-session JSONL facts. Do not copy Codex's JSONL-only
acquisition: cancellation can lack a closing transcript record, and different
processes can share one transcript while reporting different current states.

The 2026-09-14 spike used Claude Code **2.1.270**, interactive PTYs, Opus 5, low
effort, and a disposable cwd. Four runs covered hooks disabled, command-local
observer hooks, restart resume, and an independent hooks-disabled question wait.
No global hooks were installed. User/project settings and MCP configuration were
excluded. A local Stop hook deliberately requested one continuation.

The harness sampled file revisions every 25 ms and recorded terminal bytes/actions.
Sixteen assertions over those traces passed. These establish observed runtime
behavior, not production-detector tests, exhaustive schema support, or Prowl GUI
acceptance. All four test processes stopped and their PID files were removed.

Local evidence is under `.local/agent-screen-captures/claude-log-spike-20260914/`:
`REPORT.md`, `verification.json`, `verify_evidence.py`, `hooks.jsonl`, and the four
run directories. Raw captures contain private runtime data and are not committed.
The tables below preserve the findings needed for design review without those files.

## Native status and identity

Observed `~/.claude/sessions/<pid>.json` fields include `pid`, `sessionId`, `cwd`,
`startedAt`, `procStart`, `version`, `status`, `updatedAt`, and `statusUpdatedAt`.
`status` was `busy`, `waiting`, or `idle`. A question also exposed display text in
`waitingFor`; do not parse that text as a stable protocol.

Installed `claude agents --help` exposes active interactive/background sessions as
JSON. It does not promise a stable schema for the internal PID file. Read only the
relevant bounded file on Prowl's poll clock; do not launch the CLI every poll or
access messaging sockets/key files.

| Scenario | Observation | Required boundary |
| --- | --- | --- |
| `/new` (displayed as `/clear`) | Same PID, new `sessionId`; hooks report end/clear then start/clear | Rebind without waiting for a new model prompt |
| Quiet in-process `/resume ID` | PID file selects ID before model input; start/resume hook | Do not use transcript activity as selection proof |
| Restart with `--resume ID` | New PID, same session/transcript, initially Idle | Old unmatched starts are history |
| `/new` then `/resume B` after launch with `--resume A` | Launch argv still names A; native file follows current session | Argv is not permanent foreground identity |
| Two sessions in one cwd | Each PID file identifies its own session | Cwd/mtime alone is insufficient |
| Two processes on the same session | Shared JSONL, one Busy and one Idle in the same capture | Keep process-scoped state; shared log activity cannot make the idle peer Working |
| Forced process exit | PID file remained after death; later runtime startup cleaned it | Verify liveness and generation, not file existence/age |
| Active-turn descriptor probe | One `lsof` sample found no open JSONL | Persistent writable descriptors cannot be the sole discovery source |

`startedAt` differed from OS process birth; `procStart` is formatted text and local
`ps` used another time zone. Generation normalization and before/after acquisition
checks remain implementation gates. Native Busy can also include local command/UI
work; it is not an exact model-turn start.

## Event-to-JSONL correspondence

Hooks were comparison evidence, not a proposed dependency. Hook names do not imply
one-to-one persisted transcript events.

| Interaction | Observed JSONL | Native state / implication |
| --- | --- | --- |
| Human prompt | `user`, `origin.kind=human`, `promptSource=typed`, `promptId`, `uuid` | Busy; observer `prompt_id` matched `promptId` |
| Normal completion, hooks disabled | Assistant plus `system/subtype=turn_duration` | Idle; duration has no direct prompt ID, so follow parent UUID links |
| Tool call/result | Assistant `tool_use`; user-shaped `tool_result`, tool ID and `sourceToolAssistantUUID` | Busy or Waiting; tool result is not a new human turn |
| Bash permission / AskUserQuestion | Tool call; no distinct general JSONL wait event in these traces | Waiting; question wait also verified with all hooks disabled |
| Approval / answer | Tool result, reply, then duration | Busy then Idle |
| Permission cancellation | Rejected result and duration in the tested path | Idle; does not establish every cancellation path |
| Escape before output | Human start, no closing row during about 80 seconds before exit | Idle; corresponding instrumented cancellation also lacked Stop |
| Escape during confirmed streaming | Partial assistant with null `stop_reason`, then user-shaped row with `interruptedMessageId` and `promptId` | Idle; no duration/Stop for that prompt |
| Stop-hook continuation | Assistant `end_turn`, meta Stop feedback, `stop_hook_summary`, another assistant, final duration | Stayed Busy; neither `end_turn` nor hook summary alone closes work |
| Local `/clear`, `/exit`, `/model` | Local-command or user-shaped rows, not uniformly `isMeta=true` | May briefly be Busy; do not classify every user row as a prompt |

Use `interruptedMessageId`, not the English interruption message. Its absence in
pre-output cancellation means JSONL alone cannot close every observed start.
Native Idle was also observed before the final normal-completion JSONL batch, so
arrival order must not let delayed log bytes reopen completed main work.

Sampled JSONL revisions were append-only. This does not remove the need to handle
partial lines, truncation, replacement, duplicate events, and bounded parent graphs.
The existing `supacode/Infrastructure/AgentDetection/AgentTranscriptResultReader.swift`
already uses `turn_duration` and parent UUID traversal for final-answer extraction;
state detection must retain its separate responsibility.

## Child work and unverified cases

After main completion, observer `SubagentStop` events had empty `agent_type` and
nonexistent transcript paths. Their text matched suggested next prompts. This is
consistent with internal prompt-suggestion work, but that origin is an inference.
No explicit assigned child was launched. These events do not establish assigned
work, a persisted child, or child completion.

Required further evidence: real foreground/background Agent tasks; parent completion
before child completion; child reuse/cancel; session switches with children; compact
and fork; custom config roots; no-persistence/remote modes; older versions; API,
network, and authentication errors; sidecar corruption/replacement and PID reuse;
and native Prowl integration. An invalid model name was rejected locally and is
**not** API-error or StopFailure coverage.

## Proposed implementation slices

| Slice | Work and exit criterion |
| --- | --- |
| A — Contract gates | Validate generation/config-root/schema boundaries, real assigned-child lineage, and error/compact/fork traces. Every supported state/work transition needs evidence and an explicit fallback. |
| B — Native acquisition | Bounded PID-file reader and pure decoder; process generation before/after reads; session binding epoch; partial/invalid/stale file recovery. Prove late attach and recovery without new log writes. |
| C — Selected JSONL | Incremental complete-line reader, historical baseline, scoped prompt/parent links, duration and structural cancellation. Add child facts only after A establishes ownership. Replay normal, continuation, cancellation, and shared-session cases. |
| D — Shared integration | Explicit private native snapshot fact; extend coordinator generation reset to Claude; define arbitration and preserve ordering, completion fences, diagnostics, and readiness. Deterministic intermediate-state tests must pass for both adapters and screen-only runtimes. |
| E — Native acceptance | Disposable Debug panes: scrolling, completion/blockers, cancellations, switches/resumes, same-session peers, failures/recovery, children, and concurrent CLI reads. Update manual, run focused tests/check/build, then submit implementation PR. |

A precedes production event design; B/C precede D; E gates release. Genuine child
coverage is required for parity with #800. A main-only release would be a separate
scope decision, not an implicit claim that background work is covered.

### Proposed arbitration constraints

- Fresh native Waiting can establish Blocked while history is displayed. Current
  screen blockers remain evidence; a stale retained blocker needs a completion fence.
- Fresh native Busy/Idle governs main activity. Idle is a process snapshot, not a
  fabricated JSONL turn end or trusted public completion receipt.
- Verified assigned child work can retain Working after parent Idle. Shared-session
  files must not transfer another PID's work to an idle pane. If ownership cannot
  be proved, withdraw log authority and expose fallback rather than invent ownership.
- Native Idle before JSONL flush must not be reversed by delayed starts. Session
  changes, process replacement, interaction, and changed blockers need explicit
  epoch/order tests. Do not infer completion from silence.
- Temporary incomplete reads suspend authority; lost process/file continuity
  revokes it. Retained evidence during suspension must not assert successful completion.
- Preserve public identity, confidence, hook/receipt contracts, and outstanding-work
  readiness. Keep diagnostics current without causing extra UI emissions.

The exact precedence for conflicting fresh screen/native observations is a design
and test gate in D, not an implemented policy. Prefer the smallest adapter-selection
change; do not force native snapshots into an append-only abstraction or add a
second timer, mandatory hooks, global transcript scans, or a debug-dump feature.

### Validation and delivery

Capture-derived sanitized fixtures and pure tests should cover malformed/oversized
records, unsupported states, PID reuse, stale results, old history, late attachment,
shared ownership, partial writes, and recovery. Use injected time and controlled
continuations rather than sleeps. If CLI code changes, run its required build,
smoke, unit, and integration checks in addition to app checks. Record tested runtime
versions and unsupported modes in this document with the implementation amendment.

## References

- [Official hooks](https://code.claude.com/docs/en/hooks): event vocabulary and payloads.
- [Official sessions](https://code.claude.com/docs/en/sessions): storage/resume guidance.
- [Codex implementation](codex.md): reusable invariants and acquisition differences.
- [#805](https://github.com/onevcat/Prowl/pull/805): screen scroll-overlay fix, separate
  from this plan. Retaining the previous state during a history view cannot itself
  detect completion while that view remains displayed.
