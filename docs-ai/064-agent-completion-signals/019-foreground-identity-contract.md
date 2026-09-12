# 064.019 — Foreground Session Identity Contract

## Target

Resolve the main session currently selected by the TUI, then attach its log
provider. A process can retain several sessions, but writable ownership does not
identify which one the TUI displays. Child activity belongs to the selected root's
subtree, not to an arbitrary session retained by the process.

## Self identity and existing detection

On 2026-09-12, the current agent's tool process exposed `CODEX_THREAD_ID`.
Its value matched the current pane's `prowl agents --json` session ID, reported
as `source: open_file`, `confidence: exact`. `PROWL_PANE_ID` identifies the pane;
it is a separate identity and does not change merely because the chat changes.

Prowl already implements session attribution in
`supacode/Infrastructure/AgentDetection/AgentSessionResolver.swift`. It does not
read `CODEX_THREAD_ID`. It first accepts a unique writable rollout as exact, then
uses other profile evidence, screen/transcript matching, and conservative file
candidates. Resolved results have a five-second cache. `PaneAgentState` retains
an unresolved session for two fresh misses and drops it on the third.

Resume was partly considered: the Codex profile includes old date directories,
and writable-file filtering excludes read-only history access. These measures do
not establish the selected session after a same-process switch. In particular,
the `/new` observation in [018](018-foreground-and-subagent-findings.md) leaves
only the old writable rollout before the first prompt. The resolver's unique-file
branch would still classify that old session as exact. This is a code-path
conclusion from the captured inputs, not a native Prowl switch test.

## Selection events

The tested JSONL stream did not expose a foreground-selection event for `/new`
or `/resume`. The successful resume changed the selected session without changing
either rollout. This establishes a limitation of the observed external log
channel, not the absence of internal runtime events.

`CODEX_THREAD_ID` permits a tool to report its executing session. It does not
provide a passive event when the user switches chats without running a tool.
Automatic updates of that variable across new/resume were not tested here.
`/status` exposed the selected ID in the earlier resume probe, but invoking a UI
command is an active inspection, not a background event subscription.

The log provider must therefore remain gated by independently verified foreground
identity. Process ownership, latest mtime, cached identity, and a tool's past
self-report must not be promoted to a permanent foreground-selection contract.
Until a selection channel is verified, the screen provider remains necessary
when foreground attribution is unavailable.
