# 098 — Mirror demo mode: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-23 | Plan, demo Host, demo content, onboarding entry, demo Host menu, tests, docs | #1164 |
| 2026-11-23 | Review: Try the Demo becomes a link under Pair with a Mac; the top-left Host menu becomes the Settings menu (gear, red mark only on a failed connection) so app settings can join it | #1164 |
| 2026-11-23 | Duo walkthrough: the demo terminal said “Update Host to enable remote scrolling”; the demo Host now pages its screen | #1164 |
| 2026-11-23 | Review: the Settings menu keeps quick actions (up to five Hosts, Add Host…) and opens a Settings sheet with Hosts, Notifications and About; Manage Hosts is gone | #1164 |

## Outcome & current state (as of 2026-11-23)

- `Mirror/iOS/ProwlMirror-iOS/Features/Demo/MirrorDemoHost.swift`: the in-memory Host.
  `makeTransport()` returns one `MirrorTransport` per connection; messages go out on the next
  main-actor turn, in order. It answers `list`, `subscribe` (conversation snapshot and events,
  or text frames with `screenPrompt`), `refresh`, `history`, `ping` and the commands `list`,
  `profiles`, `create`, `agentsInput`, `send`, `promptRespond`, `agentKeys`. It also pages the terminal
  screen (`remote-scroll`, `scroll-state-v1`). Capabilities leave out `push-v1`, `deflate-v1` and
  `launch-shell`.
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
  "New to Prowl? Visit prowl.cat". `AgentsComponents.swift`: `MirrorSettingsMenu` shows the demo items.
- Tests: `MirrorDemoHostTests` (10, Swift Testing) drive real `MirrorHostSession` /
  `MirrorSession` against the demo Host; UI test
  `testDemoRunsTheAppWithoutAMacAndLeavesNothing` goes onboarding → demo → answer → exit.
- Docs: `docs/remote-mirror.md`, `Mirror/iOS/README.md`.

- Settings: `Features/Agents/AgentsComponents.swift` `MirrorSettingsMenu` (quick actions,
  `listedHostLimit` = 5, **All Hosts…** beyond it, **Settings…**);
  `Features/Settings/MirrorSettingsView.swift` (sheet: `MirrorHostsSection` from
  `Features/Hosts/HostsView.swift`, `MirrorNotificationsSection`, `MirrorAboutSection` with
  version, website, `https://prowl.cat/privacy`, `https://prowl.cat/terms` and the bundled LICENSE). The demo sheet shows
  About only. Decision: the menu stays for frequent actions; every setting lives in the sheet,
  so a subscription section (096) or a long Host list needs no menu change. Notifications moved
  out of the Hosts sheet because they are app-wide.

## Deviations from plan

- The demo copy and the Host name are English only: the iOS target has no string catalog yet.

## Open questions

- `https://prowl.cat/privacy` and `/terms` are added by Prowl-Site PR #26 (not merged on
  2026-11-23). They must be live before App Review (Guideline 5.1.1(i)).

- Review notes and the demo video for App Review are not written yet.
- The DEBUG `MirrorUIFixture` still has its own fake transport; it could move onto
  `MirrorDemoHost` later, but its test flags (held scrolls, refused input) do not fit the demo.
