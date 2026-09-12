# 064.020 — Foreground Selection Channels and Safe Fallback

| | |
| --- | --- |
| **Status** | Research complete; no production implementation |
| **Date** | 2026-09-12 |
| **Related** | [017 state decision](017-agent-state-decision.md), [018 lifecycle evidence](018-foreground-and-subagent-findings.md), [019 identity contract](019-foreground-identity-contract.md) |

## Decision

The inspected default Codex TUI does not expose a passive, supported notification
that identifies its selected main session. Rollout ownership and app-server thread
lifecycle events cannot replace that missing selection signal.

There is a useful **configured, hook-free alternative**: expose thread identity in
the TUI status line and terminal title. Real 0.154.0 tests confirmed both follow
`/new` and resume before a model turn. However, these are presentation surfaces:
the title truncates UUIDs and a narrow viewport truncates the status line. Treat
them as version-tested identity signals with explicit fallback, not a universal API.

Recommended first scope: keep screen status authoritative wherever current
foreground identity cannot be verified. Do not enable log authority merely because
one rollout is writable. A future optional configured identity provider can expand
log coverage; this spike does not change user configuration or choose that UX.

## Sources and version boundary

The installed CLI reported `codex-cli 0.154.0`. Source inspection used the official
`rust-v0.154.0` tag, commit `6b9826e3aa83b1a5947db50f4332cb9c65f1b340`.
A limited comparison against main `944d6fd1ba4baab69dbedd205282dc72ec20abb5`
found no foreground-selection notification added to the protocol declaration,
and no removal of the title UUID truncation. Main was not built or run.

Relevant public discussions:

- [#8923](https://github.com/openai/codex/issues/8923): the self-ID request was
  answered with `CODEX_THREAD_ID` and the app-server API. Neither answer promises
  to publish another TUI client's selected thread.
- [#18690](https://github.com/openai/codex/issues/18690): delayed rollout creation
  was discussed explicitly. Our current measurements, rather than that older
  report's timing, establish the pre-prompt gap used in this design.
- [#38297](https://github.com/openai/codex/issues/38297): retained parent writers
  after a fork provide another report of ownership differing from selection.
- [#2109](https://github.com/openai/codex/issues/2109): discussion mentions the
  optional TUI recording environment variables. Source and live checks below
  establish what the current recording actually includes.

The [official app-server documentation](https://learn.chatgpt.com/docs/app-server)
describes thread and turn APIs. A client controlling its own thread requests knows
its chosen thread; this does not establish the foreground selection of an existing
terminal client.

## Source findings

All source links below are pinned to the tested release commit.

| Surface | Finding and implication |
| --- | --- |
| [TUI session lifecycle](https://github.com/openai/codex/blob/6b9826e3aa83b1a5947db50f4332cb9c65f1b340/codex-rs/tui/src/app/session_lifecycle.rs) | `start_fresh_session_with_summary_hint` starts an in-memory thread, then replaces the chat widget. `resume_target_session` gets a thread response, then replaces the widget. Selection also changes local active receivers and snapshots. An attempted operation is not a successful selection. |
| [Thread routing](https://github.com/openai/codex/blob/6b9826e3aa83b1a5947db50f4332cb9c65f1b340/codex-rs/tui/src/app/thread_routing.rs) | `enqueue_primary_thread_session_with_presentation` assigns `primary_thread_id` and activates its channel. `primary_thread_id` and the displayed `active_thread_id` are separate: the user can view a child. |
| [Protocol declarations](https://github.com/openai/codex/blob/6b9826e3aa83b1a5947db50f4332cb9c65f1b340/codex-rs/app-server-protocol/src/protocol/common.rs) | Thread start/status/close and turn notifications exist; no per-TUI selected-thread notification was found. Loaded-thread lists describe server state, not client focus. |
| [TUI startup](https://github.com/openai/codex/blob/6b9826e3aa83b1a5947db50f4332cb9c65f1b340/codex-rs/tui/src/lib.rs) | The embedded path returns an `InProcessAppServerClient`. Starting another app-server is not attaching an observer to that in-process client's UI state. Local-daemon and remote paths also exist; they were not tested here. |
| [TUI recording](https://github.com/openai/codex/blob/6b9826e3aa83b1a5947db50f4332cb9c65f1b340/codex-rs/tui/src/session_log.rs) | `CODEX_TUI_RECORD_SESSION=1` enables a separate JSONL file, optionally named by `CODEX_TUI_SESSION_LOG_PATH`. Writes flush immediately. `/new` gets `kind: new_session`; generic events record only a variant name. No selected ID is supplied for resume. It records requests before dispatch, so failures and cancellations cannot be read as successful switches. |
| [Status rendering](https://github.com/openai/codex/blob/6b9826e3aa83b1a5947db50f4332cb9c65f1b340/codex-rs/tui/src/chatwidget/status_surfaces.rs) | `StatusLineItem::SessionId` renders the current chat widget's full UUID. `TerminalTitleItem::SessionId` truncates it to 32 characters, including `...`, despite the enum comment saying full UUID. Title-generation progress can append a spinner. |
| [Session application](https://github.com/openai/codex/blob/6b9826e3aa83b1a5947db50f4332cb9c65f1b340/codex-rs/tui/src/chatwidget/session_flow.rs) and [OSC writer](https://github.com/openai/codex/blob/6b9826e3aa83b1a5947db50f4332cb9c65f1b340/codex-rs/tui/src/terminal_title.rs) | Applying a session sets the widget thread ID and refreshes both surfaces. The terminal title is emitted as OSC 0 with BEL. Prowl already receives this in `supacode/Infrastructure/Ghostty/GhosttySurfaceBridge.swift`. |

The inspected state database stores thread metadata and lineage, not a per-TUI
selection record. Polling its update times has the same ownership/activity-versus-
selection problem as rollout mtimes. Parsing diagnostic traces or proxying an
app-server connection does not create a selection guarantee absent from the
underlying interface. Owning a new app-server frontend, or adding a dedicated
upstream selection notification, would be a separate integration project.

## Live spike

Two isolated PTY runs used the installed binary, hooks disabled, an isolated
config home, and copies of the previous spike's disposable sessions. Only this
temporary config enabled:

```toml
[tui]
terminal_title = ["app-name", "thread-id"]
status_line = ["session-id"]
```

| Case | Observation |
| --- | --- |
| Startup resume A, then `/new` | New UUID in the footer and matching prefix in OSC, before any prompt; no new rollout. |
| Resume B, then A by explicit ID | Correct identity updates with no model call or rollout changes. |
| Four successful switches in total | OSC identity observed 49.9–55.7 ms after the observer wrote Enter. This is an observer measurement, not a latency guarantee. |
| Invalid resume target | Recording emitted the same `ResumeSessionByIdOrName` variant as successful requests; selected identity remained A. |
| Child runs after parent completion; `/new` again | New root identity remained selected through the old child's later completion. The second new root also had no rollout. |
| Open and cancel resume picker | The footer identity was hidden by the picker; opening it did not select another thread. |
| 30-column terminal | Footer UUID was truncated. OSC still contained only its width-independent 29-character UUID prefix plus `...`. |

The wide-screen OSC sample was `codex | <29 UUID characters>...`, while the footer
contained the full 36-character UUID. Thus putting identity first in the title
does not avoid the per-item truncation. A unique prefix can narrow known full IDs,
but it is not itself the full ID and cannot locate an unpersisted new session.

Raw PTY output, replayed viewports, recording logs, source checkout, scripts, and
assertions remain in ignored `.local/agent-screen-captures/codex-selection-spike/`.
`verify.py` validates the measured transitions, absent new rollouts, failed-resume
behavior, background completion, recording fields, and narrow-screen truncation.
Both TUI processes stopped and the temporary auth symlink was removed. No native
Prowl integration, remote/daemon attachment, child-view navigation, or release
compatibility beyond this binary was exercised.

Offline assertions, Python syntax checks, document links, and `git diff --check`
passed. `make build-app` passed with zero errors and warnings. No production tests
were added because this change only records research and a proposed contract.

## Proposed fallback contract

The decision component receives identity confidence separately from turn status.
Use `(pane, process generation, selection epoch, root session, turn)` to scope log
evidence. Do not encode an uncertain identity as Idle.

| Identity mode | Allowed behavior |
| --- | --- |
| Unverified or switching | Screen decides status; logs may be discovered and read but cannot change the pane's status. |
| Verified foreground, log absent/unusable | Keep selected identity if still evidenced; screen decides status while the matching log is unavailable. Never attach a different log as a substitute. |
| Verified foreground and usable log | Combine scoped parent/child lifecycle with current screen Blocked evidence as specified in 017/018. |

Rules for entering and leaving these modes:

1. A verified full UUID in the current status region can identify the displayed
   thread. Require the actual current viewport and known configured layout, not
   scrollback text or an arbitrary UUID in a response. Resolve a displayed child
   to its root only with verified lineage; `forked_from_id` alone is not subagent
   parentage. Until child-view behavior is tested, fall back when it is encountered.
2. A configured title prefix is useful for invalidation and candidate narrowing.
   It must not become `exact` identity. Reject missing, conflicting, ambiguous, or
   unmatched prefixes. A prefix change immediately invalidates the old binding,
   even if only the old rollout exists. Read surface title events before tab-title
   presentation coalescing; a transient title without identity is not permission
   to replay the old log state.
3. Loss of visible identity, a picker/transition, process replacement, or a gap in
   the selected-identity channel suspends log authority. A new full-ID observation
   can rebind; elapsed time, latest mtime, or a repeated old descriptor cannot.
   Slash-command/input and optional recording events can invalidate early, but
   they must never prove success. Cancellation can restore authority only from
   fresh identity evidence.
4. Without a configured identity channel, multiple retained **root sessions** are
   a sufficient reason to stay screen-only for that process generation. Multiple
   files alone are not: child rollouts are normal. Unknown lineage is ambiguous.
   Conversely, one writable root is not proof of selection: `/new` already showed
   a new foreground with only the old persisted root. A strict default therefore
   stays screen-only whenever it lacks independent current selection evidence,
   including a late attachment to a running TUI.
5. Before publishing after rebind, establish the matching log's current baseline
   and own open turn/child state. Historical replay must not emit new transitions.
   Ignore completions from older selection epochs. Log silence alone does not
   revoke a healthy identity or mean Idle. Process death does revoke the binding.
6. Returning to one open file after ambiguity does not automatically restore log
   authority. Recovery requires fresh selected identity and a valid matching log.
   If screen evidence is itself unknown, expose/retain uncertainty under the
   existing screen policy; do not revive the invalidated log's Working state.

An optional status-line/title configuration is feasible, but layout customization
and UI visibility are real constraints. The production decision remains whether
to offer that configuration. A dedicated, versioned selection signal containing
full root/displayed IDs and a sequence number would be a cleaner future upstream
contract. No upstream issue, PR, runtime patch, or Prowl behavior change was made.
