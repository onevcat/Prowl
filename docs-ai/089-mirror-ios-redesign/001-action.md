# 089 — Mirror iOS Redesign: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-05 | Plan and decisions D1–D6 recorded after a live walkthrough | #1044 |
| 2026-11-06 | P0: agent descriptor on launch, injected-text folding, attention cleared on resolve, Markdown blocks, launch keyboard | #1045, [002](002-p0-defect-fixes.md) |
| 2026-11-06 | S1: Agents home (attention first, project sections in sidebar order, Mac state colors and the Bagua spinner), Hosts as a switcher, brand accent | #1046, [003](003-s1-agents-home.md) |
| 2026-11-06 | S2: pane chrome, folded tool steps, floating glass composer. Review round 1 fixed stale tool details, paging inside a tool run, and the composer margin; round 2 sized the margin to the measured buttons | #1047, [004](004-s2-pane-and-chat.md) |
| 2026-11-06 | S3: composer-shaped New Session sheet; `profiles` returns model, effort and icon | #1049, [005](005-s3-new-session.md) |
| 2026-11-06 | S4: `promptRespond` answers screen prompts, checked key by key | #1050, [006](006-s4-prompt-answers.md) |
| 2026-11-06 | S5: Terminal key bar and Stop (`agentKeys`); `vt-v1` rendering deferred | #1051, [007](007-s5-terminal-keys.md) |
| 2026-11-06 | S6: messages reach a working agent (queue or steer by the agent's rules); `agents dispatch` still waits for idle | S6 PR, [008](008-s6-input-while-working.md) |
| 2026-11-06 | Shell commands from the phone (`shell-send`: clear the line, then type or paste at the shell's own prompt) and the key bar in shell panes (`shell-keys`) | [010](010-shell-commands.md) |

The slices form one stack (#1045 → #1051, then S6).

## Outcome & current state (as of 2026-11-06)

**iOS client:**

- `Mirror/iOS/ProwlMirror-iOS/Features/Agents/MirrorRootView.swift` opens on the agents of the selected Host.
- `Mirror/iOS/ProwlMirror-iOS/Features/Agents/AgentsView.swift` lists blocked panes first, then projects in the Mac sidebar order.
- `Mirror/iOS/ProwlMirror-iOS/Features/Agents/MirrorPaneState.swift` holds the state colors and the spinner.
- `Mirror/iOS/ProwlMirror-iOS/Features/Hosts/HostsView.swift` holds the Hosts manager and pairing.
- `Mirror/iOS/ProwlMirror-iOS/Features/Pane/PaneView.swift` hosts Chat and Terminal:
  - `ComposerBar.swift` is the composer, with Send/Stop;
  - `MirrorPromptPanel.swift` holds the prompt answers;
  - `MirrorKeyBar.swift` holds the Terminal keys.
- `Mirror/iOS/ProwlMirror-iOS/Features/Conversation/`:
  - `MirrorChatRows.swift` folds tool runs;
  - `MirrorMarkdown.swift` parses Markdown blocks;
  - `ConversationView.swift` renders the chat.
- `Mirror/iOS/ProwlMirror-iOS/Features/Launch/MirrorLaunchView.swift` starts a session from a Profile.

**Host (Mac):**

- `App/Sources/Features/RemoteMirror/MirrorRosterDecorations.swift` sends the sidebar order, colors, groups and custom titles.
- `App/Sources/Features/RemoteMirror/Conversation/MirrorScreenPrompt.swift` reads choice menus from the screen.
- `App/Sources/Features/RemoteMirror/MirrorHost.swift` handles `promptRespond` and `agentKeys` itself.
- `App/Sources/Features/RemoteMirror/GhosttyMirrorPaneSource.swift` presses the keys after the input protection checks.

**Wire:** `PanesPayload` gains `hostName`. Pane descriptors gain `displayState`, `stateChangedAt`, `tabTitle`, `worktreeName`, `repositoryColor`, `projectOrder` and `groupName`. New capabilities are `prompt-respond` and `agent-keys`. `docs/remote-mirror-wire.md` documents them.

## Deviations from plan

- **The Agents design is plainer than planned.** The card rail and filter chips were dropped. The wording follows the Mac, and the layout and fixture names avoid the look of the reference app. The plan is corrected in place.
- **D6 comes from the screen, not the `PermissionRequest` hook.** The screen is what the answering keys must match. It also works for agents started by hand.
- **S5 shipped keys and Stop only.** The `vt-v1` terminal rendering (fixed grid, ANSI colors) is deferred; see Open questions.
- **No typed answers from the phone.** The "Type something" rows of a prompt still point to the Mac.

## Open questions

- **Terminal rendering** (research on 2026-11-06):
  - Upstream Ghostty 1.4 dropped full libghostty on iOS. libghostty-vt is supported there.
  - The recommended path is libghostty-vt from the Mac fork's commit, with an own CoreText row renderer. Keys would be encoded with its key encoder.
  - Fallbacks are libghostty-spm, for a quick spike only, and SwiftTerm, which has a fidelity risk.
  - Decide first how a phone-width grid relates to the Mac pane's columns: resize the pane or a mirror-only grid, or pan horizontally.
- **Codex prompts were not tested live.** The Codex approval was not answered from the phone in E2E, because the isolated Profiles ran Codex unrestricted. Only the 0.146.1 fixture covers that parser.
- **`testLaunchSheetKeepsTheRosterUntilDismissal` is flaky** in full UI runs. It passes when run alone.
