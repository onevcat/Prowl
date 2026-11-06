# 089.003 — S1: Agents Home

## Context

S1 replaces the Hosts → Panes screens with one Agents screen. It adds the roster fields the
screen needs on the Host, and gives the app Prowl's colors, state words and agent marks.
During review on the simulator, onevcat found the first draft too close to the reference
app (a card rail, project chips, the reference's demo names) and a little busy. The plan's
Agents section is corrected in place.

## Change

| Area | Change |
| --- | --- |
| Wire | `MirrorPaneDescriptor` gets `displayState` (adds `done`), `stateChangedAt`, `tabTitle`, `worktreeName`, `repositoryColor`, `projectOrder`, `groupName`. `panes` gets `hostName`. All optional (`docs/remote-mirror-wire.md`, "Pane roster fields"). |
| Host | `GhosttyMirrorPaneSource` fills the fields from `PaneAgentState.displayState` and `lastChangedAt`, and from `MirrorRosterDecorations`, which `MirrorRosterDecorationsSync` builds from the materialized sidebar layout, the repository appearances and the custom titles, and pushes through `RemoteMirrorStore.updateRosterDecorations(_:)`. The `.list` reply copies each descriptor and only sets `busy`, so new fields cannot be dropped again (#1040). `hostName` is `SCDynamicStoreCopyComputerName`. |
| iOS root | `MirrorRootView`: `MirrorOnboardingView` until a Host is paired, then `AgentsView` for `MirrorHostStore.selectedHost` (persisted as `mirror.selectedHost`). `HostsManagerView` (sheet) replaces `HostsView`; `PanesView` is gone. |
| Agents screen | Large title with the Mac's name; `HostMenu` (`macbook` with a connection mark); `MirrorStateSummary` (Blocked / Working / Done counts that filter); inset grouped sections from `MirrorAgentsRoster` in sidebar order with repository color and group; `MirrorPaneRow`; folded terminals; a section `…` menu that opens New Agent Pane on that project. |
| Visual language | `MirrorPaneState` with the Mac's colors and words; `MirrorBaguaIndicator` (static dot with Reduce Motion); `MirrorFailureLabel` (`exclamationmark.circle.fill`); `MirrorAgentIcon` with the Mac's agent marks (copied to `Assets.xcassets/AgentIcons`, same licenses as `App/Sources/Assets.xcassets/CommandIcons/README.md`). `AccentColor` is the icon's deep teal (#0A7A72 light, #18A190 dark), `UserBubble` a quieter teal for S2. |
| App | iOS 26 deployment target; the Prowl icon as the iOS app icon (it had none). |
| Fixtures | `--mirror-ui-roster-fixture` adds panes in Prowl, Kingfisher and FengNiao in every state; `--mirror-ui-onboarding-fixture` starts with no Host. |

Tests: `MirrorAgentsRosterTests`, `MirrorHostStoreSelectionTests`, the roster and
decoration tests in `MirrorHostConversationTests` (Mac), and the UI tests
`testAgentsScreenSummarizesStatesAndFoldsTerminals` and `testOnboardingLeadsToPairing`.

## Decisions

- The reference screenshots set the feel only. Layout, copy and demo data are Prowl's own:
  the Mac's state words ("Blocked", not "Needs you"), the Mac sidebar order and colors, and
  fixture projects from onevcat's own repositories.
- A sliding "Agent Island" capsule for blocked and done agents was built and removed:
  the counts already filter to them, and the capsule made the screen busier.
- The dark accent is a mid teal, not the mint `ProwlAccent`: white text on mint fails
  contrast in filled controls.

## Refs

#1046
