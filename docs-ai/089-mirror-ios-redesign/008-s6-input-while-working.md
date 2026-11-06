# 089.008 — S6: Messages to a Working Agent

## Context

`agents.input` (067.009) reused the readiness check of `agents dispatch` (064.014 D5). That check waits for the turn to end and refuses a working or blocked agent, so the phone could not send a message while the agent worked. The S2 composer note even said that the message "waits until it is free", but no part of the system waited: the Host refused the message with `DISPATCH_TARGET_BUSY`.

The idle rule has a reason for automation: one dispatch is one turn, and its receipt must not merge with a running turn. Human input has no receipt. A person at the Mac can type while the agent works, and the agent decides what to do with the text. onevcat decided (2026-11-06) that mirror users get the same behavior: follow the agent's default, and treat the message as a queue or a steer.

## Change

| Area | Change |
| --- | --- |
| Host readiness | `AgentDispatchCommandHandler.humanInputRefusal` replaces the idle wait for `agents.input`. It refuses a gone pane, a pane without an agent and a blocked agent: a question or permission on screen would take the text as its answer. Idle and working agents get the message. A runtime `needs-input` level refuses only when the detector reports blocked too: the level stays until the turn ends, also after the question is answered from the Mac or the phone, and every level that predates the call needs the detector's agreement (`AgentConditionEvidence.exactMatch`). `agents dispatch` keeps `awaitIdleAgent`. |
| Input protection | Unchanged: IME text, a local edit in the last 2 s, and a draft or an unrecognized composer still refuse. |
| Claude composer | `ClaudeScreenProfile.isEmptyComposerHint` also accepts the dim `Press up to edit queued messages` hint, which Claude Code shows in the empty composer while a turn holds queued input. Without it, a second message during a turn read as a draft. |
| iOS | The composer note for a working agent is removed. Send stays available; Stop still replaces it when the draft is empty. |

Observed behavior (2026-11-06, in tmux, captured with styles):

| Agent | Composer while working | Enter while working |
| --- | --- | --- |
| Claude Code 2.1.318 | Empty `❯ `; after a queued message, the dim queued messages hint | Queues the message (`ctrl+x ctrl+s to send now` under it); the transcript records `queue-operation`, which the feed shows as `user.queued` |
| Codex 0.166.0 | The same empty composer with its dim hint as when idle; `CodexScreenProfile.composerIsEmpty` already accepts it | Adds the message to the running turn (steer). Tab would queue it; the Host does not use Tab |

Tests:

- `interactiveInputReachesAWorkingAgentButNotABlockedOne`: working delivers (also with a leftover `needs-input` level), blocked refuses, `agents dispatch` still refuses a working agent. Red on the old handler.
- `interactiveInputRetainsProtectionAndReportsUnconfirmedDelivery`: a working agent now reaches delivery.
- `dimQueuedMessagesHintReadsAsAnEmptyComposer`: the captured styled row reads as empty; the same words typed by the user stay a draft. Red on the old profile.

## Refs

PR: S6 on top of #1051.
