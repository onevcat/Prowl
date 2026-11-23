# 089 follow-up — A new session opens in Chat

## Context

A session started from the phone opened on the terminal and moved to Chat only after a long
wait. The phone switches when the Host reports the pane's conversation as available, which
needs the agent's transcript path. Measured on onevcat's Mac with the released app
(2026-11-21, `prowl create tab --profile … --prompt -`, `prowl agents --json` polled):

| Agent | Agent detected | Transcript file created | Host reports the transcript |
| --- | --- | --- | --- |
| Claude Code | 1.4 s | 1.3 s | 6.5 s |
| Codex | 3.3 s | 3.2–4.4 s | 12.3–12.7 s |

The phone asks for the roster every 3 s on top of that. The prompt also carried the dispatch
completion protocol, and Claude Code asked for permission to run
`prowl agents dispatch-complete`, so a new session became blocked a few seconds after it
started.

## Decisions

- **A phone launch is interactive.** The Host marks every remote Profile launch with
  `CreateLaunchInput.interactive`. The prompt goes in as typed, with no dispatch receipt and
  no completion instruction. A person reads the reply, and nothing on the phone waits on the
  receipt. The CLI has no flag for the field, so `prowl create --prompt` keeps its dispatch
  for automation.
- **Resolve a young process every second.** For 15 s after the agent process starts, the
  session resolver retries every second. Before, a session without a transcript yet (Claude
  Code's registry names it before the file exists) was cached for 5 s, and a miss that fell
  back to the wide history scan retried after 8 s. The wide scan still runs for a young
  process: a resumed Codex rollout that the TUI does not hold open (daemon mode) is found only
  there. One scan of about 1,500 rollouts takes some milliseconds, so the faster pace costs
  little. After the window, the pacing does not change.
- **Chat first for Claude Code and Codex.** These agents have a conversation adapter on the
  Host. When one of them starts with a first message, the pane shows Chat at once: the message
  as the first bubble and a playful line (`ProwlLoadingMessages`, shared with the Mac launch
  screen) under it. The roster is asked for every second while it waits. The terminal shows
  after 10 s without a conversation, or when the person taps **Terminal**. Other agents, and
  launches without a first message, open on the terminal as before.

## Result

The same measurement with the change, on a Debug Host:

| Agent | Host reports the transcript |
| --- | --- |
| Claude Code | 2.9 s |
| Codex | 3.3–4.0 s |

On the iOS simulator, the real Chat replaced the wait after about 3 s (Claude Code) and 4 s
(Codex). The first message had no Prowl instructions, and Claude Code did not ask for a
permission. The 10 s limit keeps a margin of about two times over the slowest result.

## Code

- `Shared/Sources/ProwlCLIShared/InputModels.swift`: `CreateLaunchInput.interactive`.
- `App/Sources/Features/RemoteMirror/MirrorCommandService.swift`: `personalKickoff`.
- `App/Sources/CLIService/LifecycleCommandHandler.swift`: no dispatch for an interactive launch.
- `App/Sources/Infrastructure/AgentDetection/AgentSessionResolver.swift`: `youngProcessWindow`.
- `App/Sources/Features/RemoteMirror/GhosttyMirrorPaneSource.swift`: the roster title hides
  every `PROWL_LAUNCH_*` launch command, not only one with a dispatch.
- `Mirror/Shared/ProwlLoadingMessages.swift`: the shared lines and `ProwlRotatingMessage`.
- `Mirror/iOS/ProwlMirror-iOS/Features/Pane/PaneView.swift`: `startsInChat`, `awaitChat`.
- `Mirror/iOS/ProwlMirror-iOS/Features/Conversation/ConversationView.swift`:
  `MirrorChatStartingView`.
