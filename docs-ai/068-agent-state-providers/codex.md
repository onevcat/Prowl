# Codex state provider

Status: implemented in [#800](https://github.com/onevcat/Prowl/pull/800), merge
`919cf30a`, released in [v2026.9.12](https://github.com/onevcat/Prowl/releases/tag/v2026.9.12).
Reference baseline: `e54b1e19`, 2026-09-14. Shared arbitration is in
[architecture.md](architecture.md).

## Acquisition contract

`App/Sources/Infrastructure/AgentDetection/CodexLogProvider.swift` samples writable
rollout descriptors owned by the detected process. Process generation is checked
before and after sampling. State authority requires a complete inventory, unlike
best-effort public session lookup.

| Boundary | Implemented behavior |
| --- | --- |
| Discovery | At most 32 files; root/child lineage comes from session metadata |
| Read limits | Header and pending line each at most 1 MiB; appended reads at most 8 MiB per sample |
| Cursor | File identity, offset, pending bytes, and decoder state; consume complete lines |
| Initial attach/recovery | Baseline existing history; do not replay old starts as live work |
| Fresh files | Creation time relative to provider start distinguishes new persistence from old history |
| Copied fork history | `forked_from_id` requires the file's own `thread_settings_applied` boundary |
| Temporary incomplete inventory/header | Suspend authority, retain cursors and observed work |
| Replacement, truncation, malformed lifecycle, I/O continuity loss | Clear authority and require a new baseline |

Header timestamps can precede file creation by minutes. Fresh main and child files
therefore do not require a settings marker unless they contain copied fork history.
Main source strings include `cli`, `exec`, `vscode`, and `mcp`; child lineage uses
`source.subagent.thread_spawn.parent_thread_id`. Unsupported or missing lineage
cannot acquire authority, even when the file cursor remains cached.

The provider uses the existing polling cadence, including ticks without appended
bytes. Diagnostics are rate-limited by category with recovery reporting; they do
not include transcript content. Current limits and failures are not a full replay log.

## Lifecycle decoding

`App/Sources/Infrastructure/AgentDetection/CodexLogDecoder.swift` emits private facts:

| Runtime record | Private interpretation |
| --- | --- |
| `event_msg/task_started` | Open main or child work with `turn_id` |
| `event_msg/task_complete` or `turn_aborted` | Close only the matching main/child turn |
| Parent `item_completed` / `SubAgentActivity` started | Provisional child work, replaced by the child's own turn |
| Follow-up call/result | Track call identity to distinguish work-triggering interaction from an idle message |
| Child completion notification | Preserve child turn identity; stale notification cannot close reused work |
| Parent interrupt request | Does not itself prove the child has stopped |

A late scheduling notice cannot replace an already observed child turn. The
child's own abort is authoritative; an interrupt request alone is not completion.
Unknown lifecycle shapes fail closed instead of silently dropping possible work.

## Decisions and limits

One eligible root can supply log authority. Open main/child work stays Working
without a timeout, subject to current screen Blocked. Parent completion alone does
not release child work. The main activity window is 120 seconds; it is a selection
heuristic, not a work timeout or proof of exact foreground identity.

- Attach in the middle of a turn can remain screen-only until a later trackable turn.
- Quiet resume and multiple eligible roots remain ambiguous; public resolver output
  does not resolve that ambiguity for this provider.
- Missing/null legacy source is unsupported. No general old-version compatibility
  guarantee follows from accepting current headers.
- Continuity loss can leave detection screen-only until new live evidence arrives.
- Completed-frame suppression has a sole-root fallback limit; expired multi-root
  ambiguity can expose retained Working/Blocked screen state again.

## Existing verification

#800's live acceptance used Codex 0.154.0 and the Debug app's native terminal/CLI
path. It observed a fresh hook-free log turn despite a raw Idle screen, approval and
question blockers, parent completion before a still-working child, and `/new`
fallback followed by recovery. That `/new` run did not retain multiple main files,
so it did not prove live grace-window selection recovery.

Deterministic follow-ups cover capture order, suspended completion fences, stale
results, diagnostic emission, and CLI schema/read freshness. The final corrective
round did not repeat live TUI or energy acceptance. See
[064.022](../064-agent-completion-signals/022-provider-implementation.md),
[064.023](../064-agent-completion-signals/023-provider-continuity-hardening.md), and
[064.024](../064-agent-completion-signals/024-observation-order-and-emission.md)
for scoped receipts. This consolidation adds no new runtime verification claim.
