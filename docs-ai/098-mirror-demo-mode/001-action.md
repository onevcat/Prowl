# 098 — Mirror demo mode: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-23 | Plan, demo Host, demo content, onboarding entry, demo Host menu, tests, docs | PR (this entry's PR) |

## Outcome & current state (as of 2026-11-23)

- `Mirror/iOS/ProwlMirror-iOS/Features/Demo/MirrorDemoHost.swift`: the in-memory Host.
  `makeTransport()` returns one `MirrorTransport` per connection; messages go out on the next
  main-actor turn, in order. It answers `list`, `subscribe` (conversation snapshot and events,
  or text frames with `screenPrompt`), `refresh`, `history`, `ping` and the commands `list`,
  `profiles`, `create`, `agentsInput`, `send`, `promptRespond`, `agentKeys`. Capabilities leave
  out `push-v1`, `deflate-v1`, `remote-scroll` and `launch-shell`.
- `MirrorDemoContent.swift`: the pane model (descriptor, worktree, sequenced events, open
  screen prompt, answer scripts, autoplay), state tracking that marks a finished turn
  **done** like the Mac, the terminal screen and history rendered from the events, Stop's
  interruption events, and the scripted reply to any message.
- `MirrorDemoContent+Standard.swift`: the sample Mac — Kingfisher (blocked Claude Code
  permission, done Codex release notes, a test shell), FengNiao (Codex scan that finishes
  after two minutes or stops on Esc), Prowl (idle Claude Code review, a git shell).
- `MirrorDemo.swift`: `MirrorDemo` (store on the cleared suite
  `com.onevcat.prowl.mirror.demo`, sessions with demo factories, `end()`), and the
  `mirrorDemo` environment value with **Pair with a Mac** and **Exit Demo**.
- `ContentView.swift`: `MirrorAppRoot` switches between the paired Hosts and the demo; the
  DEBUG connection fixture goes through it too, so UI tests reach the demo.
- `MirrorRootView.swift`: onboarding shows **Try the Demo** (only with no paired Host) and
  "New to Prowl? Visit prowl.cat". `AgentsComponents.swift`: `HostMenu` shows the demo items.
- Tests: `MirrorDemoHostTests` (10, Swift Testing) drive real `MirrorHostSession` /
  `MirrorSession` against the demo Host; UI test
  `testDemoRunsTheAppWithoutAMacAndLeavesNothing` goes onboarding → demo → answer → exit.
- Docs: `docs/remote-mirror.md`, `Mirror/iOS/README.md`.

## Deviations from plan

- The demo copy and the Host name are English only: the iOS target has no string catalog yet.

## Open questions

- Review notes and the demo video for App Review are not written yet.
- The DEBUG `MirrorUIFixture` still has its own fake transport; it could move onto
  `MirrorDemoHost` later, but its test flags (held scrolls, refused input) do not fit the demo.
