# Changelog

## [2026.9.6](https://github.com/onevcat/Prowl/releases/tag/v2026.9.6)

Meet **Agent Island**: all your agents' status at your Mac's notch, with a new way to navigate built for speed and muscle memory. See who is working, waiting for you, finished, or idle at a glance, then jump straight to any agent—even from another app.

### New

- **All-agent status at the notch.** Agent Island brings together status counts for every agent, with visible reminders for agents waiting for input or with unread results. It fits around the notch on your chosen display, or appears as a draggable floating bar on displays without one.
- **Agent navigation that becomes muscle memory.** Assign **Toggle Agent Island** in Display or Shortcuts settings, then use the same quick sequence from any app: open the roster, select with arrow keys, and press Return to jump to the pane. Number keys 1–9 jump directly to an agent on the current page; agents waiting for input and unread completions get priority when the roster opens. You can also expand the island and click any agent.
- **Off by default, easy to enable.** Turn on **Show Agent Island** in **Settings → Agents → Display**, or use the island toggle in the **Active Agents** panel.
- Active Agents and Agent Island preferences now live together in Settings → Agents → Display, including placement, opacity, and whether to hide the island when empty.
- Settings → Agents → CLI & Skills now shows whether the CLI connection is listening, with a reason when it is unavailable.

### Fixed

- Closing a pane or tab now asks for confirmation if an affected terminal received editing input within the last 10 seconds or still has active input-method composition.
- Agent status now follows explicit runtime indicators more reliably, including Pi and OMP working indicators, Codex background-terminal waits, and Copilot streaming output. Claude Code and Copilot workspace-trust prompts correctly appear as Blocked.
- Adding a Custom Command now scrolls to and focuses its name editor, so typing renames the command instead of the repository.
- Fixed completion-hook setup for Codex configurations without an existing notifier.

## [2026.8.31](https://github.com/onevcat/Prowl/releases/tag/v2026.8.31)

This release lays the groundwork for Agent Workflows — multi-step, multi-agent orchestrations that Prowl runs and supervises for you. The engine and CLI are ready to try today; the complete experience, including starting and managing runs from the UI, arrives together with the workflow interface in an upcoming release.

### New

- Agent Workflows (early preview): define multi-step, multi-role workflows in YAML and run them with `prowl workflow run`. Track progress with `prowl workflow status`, complete a step with `prowl workflow done`, and stop a run with `prowl workflow cancel`; validate a definition file or inspect the schema with `prowl workflow validate` and `prowl workflow schema`. The start sheet, Settings page, and built-in workflows ship in a later release.
- A workflow status indicator now appears in the toolbar for the selected worktree. Hover or pin it to see the run's active role, current step, repeat progress, and any attention that needs your input.
- `prowl agents dispatch` sends a new task into an agent that is already running in a pane, without restarting it, so you can queue a follow-up request once the agent goes idle.

### Fixed

- Creating a new tab or split, or launching an Agent Profile, no longer fails or leaves a dead shell when the display is asleep.
- Worktree rows for a blocked agent now show a "needs input" icon instead of the running spinner, so a blocked agent no longer looks like it is still working.

## [2026.8.29](https://github.com/onevcat/Prowl/releases/tag/v2026.8.29)

This release focuses on letting Prowl and your agents know what other agents are actually doing, plus new CLI and Settings tooling for skills and panes.

### New
- Agent coordination from the CLI: `prowl create tab|pane --profile <name> --prompt -` launches an Agent Profile with a kickoff prompt and returns a dispatch receipt; `prowl agents wait --dispatch <id>` blocks until the worker reports `prowl agents dispatch-complete`, and `prowl agents wait <pane> --until idle|blocked|changed|exit` waits on an observed pane state. Agents can report their own events with `prowl agents signal`, and `prowl profiles list` shows the configured Profiles with their runtime availability.
- Native completion-signal hooks for all eight supported runtimes (Claude Code, Codex, GitHub Copilot, Droid, Qoder, Pi, Oh My Pi, OpenCode) when launched from a Profile, so `agents wait` knows precisely when a turn ends or an agent needs input instead of guessing from the screen. Nothing is written to your runtime configuration; the hooks live only for that launch.
- Prowl's bundled skills (`prowl-cli`) can be installed with `prowl skills install`, or from the Agent Skills section on the new Settings → Agents → CLI & Skills page. Both link the bundled skills into your Claude, Codex, or shared `~/.agents` skill folders and show the same per-target status.
- `prowl create pane <anchor> --direction right|left|up|down` opens a split against an explicit anchor pane, and every pane now exports `PROWL_PANE_ID` so an agent or script can address its own pane without guessing from focus.

### Improved
- Settings now has an Agents group: Profiles moved there, and the new CLI & Skills page takes over the `prowl` CLI install from Advanced.

### Fixed
- Claude Code's periodic idle-prompt notification was misread as "needs input", which could make `agents wait` hang on an already-idle pane; freshly launched Profile agents are also detected as idle promptly instead of timing out.
- Pi's background sub-agent activity is now recognized as Working instead of appearing idle.
- A Claude pane with an active spinner above a queued multi-line message was incorrectly reported as idle.

## [2026.8.20](https://github.com/onevcat/Prowl/releases/tag/v2026.8.20)

This release adds per-repository diffing for workspace children and unifies the Prowl CLI's target syntax.

### New
- Workspace child rows now support diffs: click their `+N/-M` badge or use the context menu's Show Diff / Show Outgoing Changes. Diff shortcuts (⌘⇧Y, ⌥⌘⇧Y), the View menu, and Command Palette now follow the selected workspace child, not just worktrees.
- The Prowl CLI accepts `pN`/`tN` pane and tab handles directly in any target position, and adds action-first `prowl create tab` and `prowl close` commands. The older `tab`/`pane` lifecycle commands still work but print a deprecation warning.

### Fixed
- Fixed terminal tab colors occasionally resolving incorrectly when SwiftUI rendered them asynchronously off the main thread.

### Improved
- Notification and update controls in the toolbar are now grouped together for a cleaner layout.

## [2026.8.15](https://github.com/onevcat/Prowl/releases/tag/v2026.8.15)

Improved detection accuracy for Claude Code sessions, plus a new CLI command for reading agent results.

### New
- `prowl agents read <pane>` (CLI): get an immediate, read-only snapshot of a Codex or Claude Code pane's current status and completed result text. Use `--result-only` to pull just the trusted final output, e.g. for piping into scripts.

### Fixed
- Claude Code panes with a long todo list no longer flash to Idle while a spinner is still actively running.
- Claude Code panes waiting on a background agent, or showing multi-word elapsed-time status text, are now correctly detected as working instead of Idle.
- Cmd-clicking a terminal link in Canvas no longer requires repeated clicks or misfires on the wrong link.

## [2026.8.9](https://github.com/onevcat/Prowl/releases/tag/v2026.8.9)

This release streamlines the toolbar layout and improves the accuracy of agent status detection for Claude and Codex.

### New
- `prowl agents --json` can now include a `detection_reason` field, showing why an agent was classified as blocked, working, or idle.
- Added `prowl read --source detection`, which reads the same screen buffer Prowl uses internally for agent state detection.

### Improved
- Unified the top toolbar across Normal, Shelf, and Canvas modes around Agents + Quick Launch, with the notifications bell surfaced separately. The branch/folder name was removed from the toolbar since it's already shown in the sidebar.
- Rename Branch moved from the toolbar into the worktree's context menu (and an app-level sheet), keeping its configurable shortcut.

### Fixed
- Codex's directory-trust, hook-review, and first-run sign-in prompts are now correctly detected as blocked instead of being read as idle or working.
- Fixed Claude's history-search viewer being misdetected as idle after its filter/navigation footer text changed.

## [2026.8.5](https://github.com/onevcat/Prowl/releases/tag/v2026.8.5)

### New
- Agent Profiles now cover the full 15-runtime catalog, with per-runtime controls for model, reasoning effort, approval mode, and Dedicated Home shown only when that runtime actually supports them.

### Changed
- `prowl handoff` now always requires an explicit briefing choice: pass `--brief -` with agent-authored content, or `--no-brief` for a context-only handoff. The automatic recorded-session fallback briefing has been removed.

### Fixed
- Fixed a crash that could occur when two close-confirmation dialogs tried to appear at the same time.
- Pi's animated braille "Working..." loader is now recognized, so its status no longer gets stuck showing idle or blocked while it's actually working.
- Agent status detection (working/idle/blocked) no longer gets confused by old response text left on screen; only the live status region is checked.
- Tabs and splits launched from the Agents menu now show the correct runtime icon right away instead of a generic terminal icon.

### Improved
- Reduced CPU usage from idle-agent monitoring and sidebar updates, and removed tab-bar flicker caused by animated agent titles.
- Uncommitted line-change badges no longer silently undercount large untracked files; when some files can't be counted, the badge shows `+N…` and explains what was omitted.

## [2026.8.1](https://github.com/onevcat/Prowl/releases/tag/v2026.8.1)

This release introduces Agent Profiles — reusable presets for launching coding agents — along with related launcher and Settings improvements.

### New

- Agent Profiles: create named launch presets for Claude Code and Codex with a chosen model, reasoning effort, execution mode, tab/split placement, extra arguments, and per-profile environment variable overrides (for example, pointing a profile at a different API endpoint). Manage them in Settings → Agents, each with its own custom icon and an optional isolated account/home.
- Launch a profile from the toolbar Agents menu, its new one-click quick-launch segment (instantly launches your Recommended profile), or the Command Palette's "Launch Agent" rows.
- Clear a recorded keyboard shortcut with the new Clear button shown while remapping — the shortcut stays unset until you press Reset.

### Improved

- Settings now uses native macOS navigation chrome (sidebar and back button) throughout.
- The Agents popover groups launcher rows under one header and dims agents whose CLI isn't found on your PATH, showing why and rechecking automatically when you reopen it.
- A profile's environment variables and dedicated account now apply only to the agent it launches — manually running `codex` or `claude` in the same tab no longer inherits them.

### Fixed

- Fixed a crash when adding or removing rows in a profile's Environment Variables table.
- Fixed several brand icons (Claude Code, Cursor, GitHub Copilot, and others) rendering as a tiny dot in the Default Agent Profile picker.

## [2026.7.29](https://github.com/onevcat/Prowl/releases/tag/v2026.7.29)

Prowl 2026.7.29 adds automatic repository icon detection and an on-device icon suggestion tool, along with a reworked sidebar context-menu system.

### New

- Newly added repositories now get a product icon detected automatically in the background (Apple, Android, Flutter, React Native, Web, Unity, Tauri, and more project kinds are recognized). This can be turned off in Settings → Appearance → Repository Icons ("Detect project icons automatically").
- Repository Icon menu gains **Suggest an Icon…**, which recommends SF Symbols on-device based on your README or package metadata, with alternates and a "Regenerate" option.
- Sidebar context menus for repositories and worktrees have been reorganized: worktree rows get `New Terminal Tab` (always opens at the worktree root), `Stop Running Script`, `Copy Branch Name`, `Open Pull Request`, and a `Close All Tabs` action grouped with Archive/Delete.
- The `PR #N` tag in the sidebar is now a clickable link that opens the pull request.
- The Active Agents context menu gains a Session group with **Copy Session Path** and **Reveal Session in Finder**, for agents that keep a native session log on disk.

### Fixed

- Canvas tabs opened from the sidebar now focus correctly on creation.
- Grok session log paths now resolve to the correct transcript file.

## [2026.7.25](https://github.com/onevcat/Prowl/releases/tag/v2026.7.25)

### New
- **Outgoing Changes**: a new mode of the diff window showing the committed changes a worktree's branch would contribute to a pull request. Open it with ⌥⌘⇧Y, View → Show Outgoing Changes, the Command Palette, a worktree's context menu, or the new Uncommitted / Outgoing toggle in the diff window's toolbar.
- Outgoing Changes works without an open pull request: the comparison base is resolved through a clear priority order — PR base, then the repository's Base Branch setting, then the default branch — and the base in effect is always labeled in the window title and file list.
- The sidebar's expand/collapse header button now has a third state: Collapse All → Expand Active (expands only repositories and workspaces that have open tabs) → Expand All.
- Tab count badges now follow the sidebar level: a collapsed repository shows its total open-tab count on the header, and expanding it moves the count onto the individual worktree rows.

### Fixed
- Fixed the text cursor jumping to the end of the field while editing a custom command in the middle of its text.
- Fixed tab count badges getting visually compressed next to long branch names.

## [2026.7.22](https://github.com/onevcat/Prowl/releases/tag/v2026.7.22)

This release introduces cross-agent handoff, letting you pass work from one coding agent to another without losing context.

### New
- Hand off a task between coding agents: open the command palette and choose "Hand Off…", or use the new Agents capsule in the worktree toolbar. The current agent writes a briefing, then the chosen agent launches in a background tab to continue — your current tab stays focused, and a notification lets you jump over once it's ready. Any detected agent can hand off its work; the receiving side currently supports Claude Code and Codex, with more agents coming in future releases.
- Handoffs are also available from the CLI: run `prowl handoff save` or `prowl handoff to <agent>` inside an agent's terminal to capture and hand off its current state.
- Right-click a row in the Active Agents panel for a new context menu: Hand Off…, Mark as Read, Copy Path, and Reveal in Finder.

### Improved
- The Agents capsule now shows the launch alias you actually used to start an agent (e.g. "omp") instead of always showing the underlying agent name, and got a cleaner look (plain font, sparkles icon for the no-agent state).
- The Hand Off waiting screen is now non-modal, so you can keep using the terminal — for example to approve a permission prompt — while a briefing is being prepared.

### Fixed
- Fixed handoff requests occasionally being attributed to the wrong pane or session.
- Fixed pre-transport handoff CLI errors not rendering as proper JSON output.

## [2026.7.20](https://github.com/onevcat/Prowl/releases/tag/v2026.7.20)

### New

- Global Custom Commands: create custom commands in Settings that apply across all repositories instead of duplicating them per repo. Repository-local commands still take precedence if a name or shortcut conflicts.
- Prowl now detects Qoder CLI as a coding agent, so it shows up in Active Agents and `prowl agents` with correct working/blocked status.

### Improved

- Custom Commands settings now let you enable/disable local commands and opt out of a Global command per repository (Repo Settings → Custom Commands → **This Repo** checkbox), with a clearer insertion indicator while reordering.
- If a repository-local command and a Global command share the same name, Prowl now shows both instead of hiding one.

### Fixed

- Ask-style permission prompts from the OMP agent no longer show as "working" — they're now correctly reported as blocked until you respond.
- Cancelling a running shell command is more reliable and no longer waits on stream teardown to terminate the process.

## [2026.7.17](https://github.com/onevcat/Prowl/releases/tag/v2026.7.17)

Grok Build agent detection and a reworked branch-deletion memory setting.

### New
- Prowl now detects Grok Build (xAI's `grok` CLI) as an agent, showing its icon in the tab and tracking status transitions between idle, working, and blocked (e.g. bash approval, ask-user prompts).

### Improved
- When manually deleting a worktree, the "Also delete local branch" toggle now remembers your last confirmed choice for next time.
- Automatic branch cleanup (for merged PRs and expired archived worktrees) is now controlled by its own separate setting in Worktree Settings, independent of the manual delete toggle.

## [2026.7.14](https://github.com/onevcat/Prowl/releases/tag/v2026.7.14)

### New
- `prowl list` and `prowl agents` now show short handles (`t1`, `p1`, ...) for tabs and panes in their text output, and `--tab`/`--pane` selectors accept these short handles as well as UUIDs, making it much easier to reference panes across CLI calls. JSON output is unchanged and still uses full UUIDs.
- `prowl agents` can now report a detected agent's native session details—session ID, transcript path, and detection confidence—for supported CLI agents (Claude Code, Codex, Amp, Copilot, and others), without requiring any hook setup.

### Fixed
- Active Agents no longer shows the wrong pane's title when multiple agents run in split panes of the same tab; each row now reflects its own pane's title.
- Worktree deletion errors are now surfaced instead of being silently treated as success, and worktrees that failed to delete due to a locked or stuck registration no longer reappear after the next refresh.
- Repository roots opened through a symbolic link are now resolved to their canonical Git root, so branches and worktrees load consistently no matter which path was used to open the repo.
- The sidebar now updates correctly after running `git init` inside a plain (non-Git) folder that was already open in Prowl.

### Improved
- Removed the non-functional Update Channel picker from Settings → Updates, since Prowl has shipped a single release channel for a while.

## [2026.7.10](https://github.com/onevcat/Prowl/releases/tag/v2026.7.10)

This release focuses on notification control, PR status reliability, and a few editor and terminal integration additions.

### New
- Added a notification sound picker in Settings → Notifications: choose from system sounds, "Prowl Classic", or turn sounds off entirely. Selecting a sound plays a quick preview.
- Added a "Mute notifications for the active pane" setting (on by default): when a notification comes from the pane you're already viewing, the banner, sound, and dock bounce are skipped since you're already looking at it. Turn it off in Settings → Notifications if you want notifications even while viewing the pane.
- Terminal sessions now report `TERM_PROGRAM=prowl` (with `TERM_PROGRAM_VERSION`), so shell scripts and coding agents can detect they're running inside Prowl.
- Added Open actions for Zed Preview, IntelliJ IDEA EAP, and Nova in the worktree "Open" menu.

### Fixed
- Fixed PR status badges flickering to "Blocked" or briefly disappearing during refresh, including when GitHub temporarily reports an unresolved mergeable state.
- Fixed the Diff window (⌘⇧Y) following the system appearance instead of Prowl's own Dark/Light/System setting.
- Fixed symlinked config files (e.g. `settings.json` linked into a dotfiles repo) being replaced with a regular file on save, breaking the symlink.
- Fixed spurious "not a git repository" errors when your login shell isn't zsh or bash (nushell, pwsh, csh, sh/dash/ksh), which could also make Prowl fail to detect `gh`.

## [2026.7.4](https://github.com/onevcat/Prowl/releases/tag/v2026.7.4)

### New
- The diff view now shows a render-in-progress indicator when diffing and painting large files takes a moment, so it's clear the app hasn't stalled.

### Fixed
- Fixed a crash that could occur during repository loading when duplicate worktree paths were detected.
- Fixed the diff view getting stuck showing a render error with no way to recover; refreshing or reselecting the file now retries the render.
- Fixed a race condition where switching worktrees or refreshing quickly could leave stale diff content on screen.

### Improved
- Selecting a file in the diff view now applies immediately instead of always waiting for a fixed delay; only rapid successive switches between files are debounced, avoiding the flash you'd see when flicking through several files quickly.

## [2026.6.29](https://github.com/onevcat/Prowl/releases/tag/v2026.6.29)

Smarter worktree creation — Prowl now suggests branch names using Apple's on-device AI, and the refreshed Add popover lets you clone remote repos without leaving the app.

### New

- **AI branch name suggestions**: When creating a new worktree, Prowl uses Apple's on-device Foundation Model (macOS 26+) to suggest a contextual branch name based on your active terminals and repo conventions. Click "Use" to accept, or type your own name — the suggestion never overwrites what you have typed. Falls back to random adjective-animal names when the model is unavailable.
- **Clone repository from the Add popover**: The "Add..." toolbar button now opens a custom popover with a dedicated Clone option. Paste a git URL (auto-filled if your clipboard already contains one), choose a destination, and Prowl clones and selects the repo automatically. Drag-and-drop from Finder onto the drop zone also works.

### Improved

- CI check names in the PR status popover now show an underline and a pointer cursor on hover, making it clearer they are clickable links to the build run.

### Fixed

- Pressing Cmd+W while in fullscreen mode no longer leaves the screen black. Prowl now keeps the window visible instead of hiding it when fullscreen is active.
- PR status no longer surfaces pull requests from unrelated forks that happen to share the same branch name as your local branch.

## [2026.6.27](https://github.com/onevcat/Prowl/releases/tag/v2026.6.27)

Canvas view gains spatial keyboard navigation and smoother interactions, alongside a handful of targeted fixes.

### New

- **Spatial card navigation in Canvas**: Press Cmd+Ctrl+Arrow to move focus between cards based on their 2D position on the canvas. The algorithm prefers directly aligned neighbors over diagonal ones, and the viewport pans smoothly to keep the focused card visible.
- Canvas navigation shortcuts are now listed in the help popover (the `?` button in Canvas view).

### Improved

- The "Archived Worktrees" button in the sidebar footer now acts as a toggle: clicking it while already in the archived view returns you to the previously selected worktree. The icon and tooltip update to reflect the current state.
- The `prowl` CLI reports clearer error messages when it cannot reach the app socket, distinguishing between a missing socket, a stale socket, a sandbox permission denial, and other transport failures.

### Fixed

- Fixed a hang (issue #506) that could occur when the Active Agents list refreshed while Ghostty was processing a render callback, causing a reentrant call into the terminal surface.
- Fixed an incorrect SF Symbol used in the Canvas card navigation help row.

## [2026.6.25](https://github.com/onevcat/Prowl/releases/tag/v2026.6.25)

Canvas gains a Tile layout, hover-reveal help, and full toolbar PR awareness alongside fixes to PR status display and update behavior.

### New

- **Tile canvas layout** (`⌘⌥T`): resizes all cards to fill the viewport in a balanced grid. Orientation follows the window shape (wide → rows, tall → columns), and cards scale down gracefully as the count grows.
- **Canvas default layout setting**: Settings → General → Default Views now includes a "Canvas layout" picker (Uniform or Tile). Tile is the new default for all installs, including existing ones.
- **Closed PR visibility**: worktrees now display closed (non-merged) PRs with an orange badge instead of hiding them.
- **Pending checks indicator**: the sidebar now shows a yellow state when a PR has checks that are still running or expected, rather than incorrectly showing "Mergeable."

### Improved

- **Canvas help on hover**: the `?` button in the bottom-left of Canvas now reveals its popover on cursor hover and can be pinned open with a click, matching the notifications bell behavior.
- **Canvas toolbar awareness**: when Canvas is active, the toolbar center reflects the focused card's PR status and check results. "Open on Code Host" and "Open Pull Request" now act on the focused Canvas card.
- **Update install confirmation**: Prowl now asks before installing and relaunching an update, preventing an unintended relaunch triggered by a routine update check.

### Fixed

- Sidebar diff badges now refresh correctly after HEAD changes that were previously dropped on a deferred code path.

## [2026.6.23](https://github.com/onevcat/Prowl/releases/tag/v2026.6.23)

This release focuses on search usability, terminal activity detection, and window management reliability.

### Improved

- The sidebar spinner now activates for any foreground command (such as `npm run build`, `git clone`, or `sleep`), not just agent-driven tasks that emit progress signals.
- The sidebar `+N` diff badge now includes lines from untracked files and uses adaptive timing: small repos update within about 2 seconds, while large repos use a longer debounce to stay responsive.

### Fixed

- Worktree delete and archive keyboard shortcuts no longer require clicking away from the terminal first — they now work while the terminal has focus.
- Diff, Settings, and Debug windows are now visible when the main window is in fullscreen mode; they open in the active Space instead of a background one.
- Search field keyboard handling is now reliable: Enter, Shift+Enter, Escape, Cmd+G, and Cmd+Shift+G all work while the field is being edited. Search now auto-selects the newest match on first result, and Find Next (Cmd+G) moves toward newer content to match standard macOS behavior.
- Git repository detection is more robust in non-standard environments such as an unaccepted Xcode license or a broken developer path.

## [2026.6.20](https://github.com/onevcat/Prowl/releases/tag/v2026.6.20)

This release adds project workspace support, bringing multi-repository orchestration to Prowl's core workflow.

### New

- **Project workspaces**: Group multiple repositories into a single workspace. Open the "Add Repository" menu to create a workspace, choosing from three checkout modes — link existing worktrees, create a new branch, or use an existing one. Child repos appear as collapsible rows in the sidebar with their branch, diff, and PR status at a glance. Removing a workspace offers optional file cleanup and per-repo branch deletion.
- Qwen Code is now recognized as a detectable agent, with working, blocked, and idle state detection.

### Improved

- The sidebar running indicator and `prowl list` task status now reflect agent activity more accurately: a pane is shown as running whenever an agent is working or blocked, including during background Claude Code workflow runs where the input box is visible but subagents are still active.

### Fixed

- Workspace and folder names in the toolbar navigation area now have consistent padding and width, matching the appearance of branch names.
- Clicking anywhere on a workspace child row in the sidebar now selects it, not just the label text.
- "Collapse all" and "Expand all" in the sidebar header now correctly apply to workspace sections.

## [2026.6.18](https://github.com/onevcat/Prowl/releases/tag/v2026.6.18)

### New

- Canvas card title bars now have a tab context menu matching the one in Default and Shelf layouts. Right-click or use the title bar button to rename the tab, change its icon, or close it.

### Fixed

- PR status now refreshes automatically when a repository's git remotes change — adding, removing, or updating a remote URL no longer requires a restart to see updated PR badges.
- PR refresh now works correctly in fork setups with multiple remotes (e.g. `origin` + `upstream`). Prowl queries all GitHub-connected remotes and resolves PR actions against the repo that owns the PR.
- Tabs now restore correctly after quitting and relaunching the app. A race condition on launch could cause the saved layout snapshot to be cleared before restore had a chance to read it.
- The branch name icon in the toolbar no longer causes a layout jump on hover. The pencil edit icon now replaces the branch icon in place rather than appearing alongside it.

## [2026.6.16](https://github.com/onevcat/Prowl/releases/tag/v2026.6.16)

### New

- **Configurable diff tool**: Choose your preferred diff viewer in Settings — Built-in, Hunk (opens in a Prowl terminal tab), FileMerge, Kaleidoscope, or a custom command. The diff badge and Show Diff shortcut both route through this setting. Tools not installed on your system appear disabled in the picker.
- **`prowl agents` CLI command**: Run `prowl agents` (or `prowl agents --json`) to get a live roster of all active agent panes, including their project, worktree, tab, and current working/idle status.
- **Oh My Pi support**: Prowl now recognizes Oh My Pi (`omp` / `oh-my-pi`) as an agent, detects its working and interrupting states, and shows the Pi icon on tabs running it.

### Improved

- Active agent detection now uses per-pane lazy scheduling: cold panes stay idle, recently used panes are checked briefly, and full polling only starts after a known agent runtime is detected. This reduces unnecessary background work.
- Command aliases (such as wrapped `bun` invocations for Oh My Pi) are now shown with the correct icon in the Active Agents list.

### Fixed

- `prowl read --json` and other JSON CLI output no longer corrupts responses that contain terminal control characters.

## [2026.6.13](https://github.com/onevcat/Prowl/releases/tag/v2026.6.13)

This release improves multi-account GitHub workflows, expands editor support in the Open In menu, and stabilizes agent status detection.

### New

- **Per-repo GitHub identity**: You can now assign a specific GitHub CLI account to each repository in its settings. Prowl will use that identity automatically when fetching pull requests, so multi-account setups (e.g. work and personal) work without manual `gh auth switch`.
- GitHub Settings now lists all authenticated hosts and accounts instead of showing only a single entry, making it easier to see which identities are available.
- **Project-aware Automatic editor**: The "Automatic" option in the Open In menu now detects the project type (Swift/Xcode, Android, .NET, Go, Rust, and more) and prefers a matching specialist IDE when one is installed — Xcode for Swift packages, Android Studio for Gradle projects, Rider for .NET solutions, and so on. An explicit per-repo or global editor choice is always respected as-is.
- **New editors**: iTerm2, Sublime Text, Tower, and the full JetBrains family (Rider, GoLand, CLion, PhpStorm, RubyMine) are now available in the Open In menu and the Default Editor picker.
- Added an "Automatic" entry to the Open In dropdown that clears any pinned app for the current repo and returns to automatic selection.

### Fixed

- Agent status no longer flickers between Working and Done during brief pauses between steps. The stabilization hold is now 3 seconds and applies to all detected agents (Claude, Codex, Gemini, and others), not just Claude.
- Opening the transcript viewer (`ctrl+r`) or search overlay while an agent is working no longer briefly flashes the agent's status to Done.
- Conversation text that quotes Claude viewer hint strings (e.g. "ctrl+r to toggle") no longer causes the agent to appear idle while it is still working.

## [2026.6.11](https://github.com/onevcat/Prowl/releases/tag/v2026.6.11)

This release adds split-pane zoom controls, Shelf agent status badges, and trackpad navigation for the Shelf.

### New

- Hovering a split pane's drag handle now reveals a zoom button in its top-right corner. Clicking it expands that pane to fill the tab; a persistent exit button remains visible while zoomed. Press `⌘⌥⇧F` to toggle zoom from the keyboard, or use "Toggle Split Zoom" from the Command Palette.
- Shelf spines now overlay agent status badges on their tab icons, so you can see every agent's state at a glance while flipping through the stack. Toggle via "Show agent status in Shelf tabs" in Settings.
- Hold `⌘` and swipe on a trackpad in the Shelf: horizontal swipes flip between books, vertical swipes cycle the open book's tabs.

### Fixed

- The `⌘⌃←` / `⌘⌃→` keyboard shortcuts for Shelf book navigation wrap around again as expected; this had been silently broken.
- Command Palette actions that send key bindings into a terminal pane now reliably target the pane that was focused when the palette was invoked, rather than whichever pane AppKit happened to focus by the time the action ran.
- Agent working/idle detection now resyncs correctly when repositories are added or removed.

## [2026.6.9](https://github.com/onevcat/Prowl/releases/tag/v2026.6.9)

### New

- The New Worktree dialog now has an **Advanced** section where you can override the worktree's folder name and parent directory for that creation. Both fields are optional; leaving them blank keeps the default `<base>/<branch>` placement.
- PRs waiting in a GitHub merge queue now appear as **Queued** (brown label) in the worktree sidebar, with position and estimated time shown in the PR checks popover and a tinted badge.

### Improved

- App menus no longer flicker or collapse while agents are actively streaming output. Progress bar updates are coalesced to reduce CPU usage, and the terminal event buffer is capped to keep memory stable across long multi-agent sessions.

### Fixed

- The terminal now receives keyboard focus automatically after navigating with Select Next/Previous Worktree or Back/Forward in Worktree History.
- GitHub CLI output is now parsed correctly when your login shell (`.zprofile`, `.zlogin`) prints a banner before the JSON — previously this caused a "data couldn't be read" error in GitHub settings.
- The main window now restores its position and size across launches.
- Command palette: the selected row is legible in light mode, and opening the palette in light mode no longer briefly flashes dark.
- The New Worktree dialog no longer flashes empty content while sliding closed.
- Holding Cmd over a hyperlink in a non-focused terminal split now highlights the link immediately, without requiring a mouse move.
- Find Next and Find Previous in the terminal menu now display their keyboard shortcut correctly.

## [2026.6.7](https://github.com/onevcat/Prowl/releases/tag/v2026.6.7)

This release focuses on Canvas improvements, CLI automation additions, and a new in-app help feature for agent-assisted onboarding.

### New

- **Canvas expand-in-place**: cards now expand to fill the viewport with a smooth animation instead of switching to Normal view. Press **⌥⌘E** to expand or restore the focused card; a blurred scrim freezes the background while it is open. The shortcut and Expand/Restore commands are also available in the Command Palette.
- **Canvas adaptive card size**: the default card size now scales to the host screen width, so cards on a 14" MacBook Pro are appropriately smaller and stay legible after Organize/Arrange.
- **CLI tab and pane management**: `prowl tab create`, `prowl tab close`, and `prowl pane close` are now available for scripting and agent automation.
- **"Ask Agent About Prowl"**: a new action in the sidebar Help menu (and macOS Help menu) generates a ready-to-paste prompt that points your coding agent at the bundled documentation and asks it to suggest features tailored to how you work. The docs are also available directly inside the app bundle at `Prowl.app/Contents/Resources/docs/`.

### Fixed

- Deleting a worktree created outside Prowl under a symlinked path (e.g. `/tmp`) now works correctly; previously the row would disappear and immediately reappear after the next refresh.
- Collapsed-then-expanded sidebar sections no longer cause a layout spin that made scrolling unresponsive.
- Background update downloads are now handled correctly: Sparkle manages the preference, and a toolbar badge appears when an update is ready to install.

### Improved

- Canvas card terminal content and title bar now resize together during Organize/Arrange transitions instead of snapping to the final size.
- The CLI socket is now restricted to owner-only permissions and rejects connections from other users on the same machine.

## [2026.6.6](https://github.com/onevcat/Prowl/releases/tag/v2026.6.6)

This release focuses on Canvas mode: keyboard shortcuts, smoother focus navigation, and consistent behavior across sidebar, command palette, and new-tab actions.

### New

- Added keyboard shortcuts for Canvas layout actions: press `⌘⌥R` to rearrange cards preserving their sizes, or `⌘⌥G` to organize them into a uniform grid. Both shortcuts can be rebound in Settings → Shortcuts.

### Improved

- Clicking a repository, worktree, or Active Agents entry in the sidebar while in Canvas mode now focuses the matching card and centers it, rather than switching away from Canvas.
- Selecting a worktree or folder from the Command Palette in Canvas mode now focuses the corresponding card instead of leaving Canvas.
- Sidebar worktree shortcut hints (visible when holding Cmd) no longer cause layout reflow; they toggle with opacity so row heights remain stable.

### Fixed

- Opening a new tab or terminal in Canvas mode now targets the focused card's worktree, rather than falling back to an unrelated worktree.

## [2026.6.5](https://github.com/onevcat/Prowl/releases/tag/v2026.6.5)

This release focuses on CLI reliability for agent workflows and several startup and window-management fixes.

### New

- `prowl read` gains a `--wait-stable` flag that polls the pane buffer until output has stopped changing before returning, avoiding truncated reads at the moment an agent finishes generating. Use `prowl read --pane <id> --last 200 --wait-stable --json`; tuning flags `--stable-interval`, `--stable-period`, and `--wait-timeout` are available.
- New "Show tab titles in Active Agents" setting (Appearance preferences): when enabled, each agent row shows the terminal tab title as its subtitle instead of the branch name.

### Fixed

- `prowl read` no longer reports `truncated: true` when the full scrollback buffer is available but simply holds fewer lines than requested. The flag now correctly means "the returned text may be incomplete."
- Fixed a launch race and restoration hang where the default view (Shelf or Canvas) could fail to apply or stall indefinitely at startup.
- Hardened main window surfacing so Prowl reliably comes to the front when clicked in the Dock or reopened, and no longer raises unrelated helper windows.
- Worktree cleanup on a failed creation no longer requests branch deletion; directory removal is now gated on an exact path match and the presence of `.git` metadata.
- Fixed a CLI socket ownership bug where a secondary app instance could unlink or replace a live socket, breaking `prowl` CLI connectivity.

## [2026.6.1](https://github.com/onevcat/Prowl/releases/tag/v2026.6.1)

### Fixed

- Fixed a crash that occurred when multiple local repositories pointed to the same GitHub remote: pull request refresh now correctly batches and fans out results to all matching repos instead of crashing on a duplicate key.
- Internal stability improvements.

## [2026.5.30](https://github.com/onevcat/Prowl/releases/tag/v2026.5.30)

This release adds per-repository background refresh controls, safer worktree branch deletion, and a range of notification and toolbar customization options.

### New

- Each repository now has two toggles in its settings — **Observe line diffs automatically** and **Fetch pull request state** — to opt out of background Git and GitHub refresh work for repositories where you don't need it.
- The Open-in-Editor and Run buttons can now be hidden individually from Settings. A Dock badge showing the unread worktree count and an optional icon bounce are also configurable for when notifications arrive while Prowl is in the background.
- Custom commands and run scripts now work in Canvas mode, with the toolbar updating as you switch between cards.
- Shelf spine tint preferences let you choose a neutral or system-accent fallback color and optionally disable per-repository color overrides.

### Fixed

- Closing a terminal tab no longer leaves a stray shell (e.g. `zsh`) running in the background. A stale view update could recreate a terminal surface for an already-closed tab and spawn an orphaned shell process; closed tabs are now never recreated, and a closing tab also tears down its underlying shell.
- The notification bell and Dock badge could remain lit after closing a terminal tab with an unread notification; closing a tab now clears its notifications.
- Active Agents now shows the correct repository and branch based on the agent's actual working directory, not the tab's owning worktree.

### Improved

- Deleting a worktree no longer preselects local branch deletion by default. A confirmation sheet now makes the choice explicit, preselects deletion only for Prowl-created worktrees when that preference is enabled, and always prompts before a force-delete.
- Background CPU and I/O on large repositories is reduced: line-diff refreshes are now event-driven (file-system changes plus a 5-minute safety fallback) instead of periodic polling, and PR status is fetched in a single batched GraphQL query per GitHub host rather than one request per repository.

## [2026.5.26](https://github.com/onevcat/Prowl/releases/tag/v2026.5.26)

### Fixed

- The active agent indicator now correctly reflects agent state even when you have scrolled up in the terminal, instead of reading only the visible viewport.
- Prowl's main window now reliably reopens when relaunching the app after all windows have been closed.
- Using an explicit `light:X,dark:X` theme (same name on both sides, as an opt-out of the automatic fallback) is now respected; previously Ghostty's config normalization caused it to be overridden. The no-theme default also now adapts to system appearance, so a Light-mode app no longer stays stuck on a dark terminal.
- `omx` and `oh-my-codex` process names are now recognized as the Codex agent type, so the active agent panel correctly identifies sessions running through the OMX wrapper.

## [2026.5.25](https://github.com/onevcat/Prowl/releases/tag/v2026.5.25)

This release focuses on reliability improvements and a handful of UX polish items.

### New

- **Canvas is now available as a default view.** Go to Settings → Appearance → Default View and choose "Canvas View" to have Prowl open directly into Canvas on launch. If no worktrees are present at launch, it falls back to Normal view.
- Prowl now asks for confirmation before closing a pane, tab, or group of tabs that contain active or recently-completed-but-unseen terminal work, preventing accidental data loss.

### Fixed

- The toolbar no longer loses its tint color when entering or exiting macOS fullscreen. Prowl's chosen Light or Dark appearance is now used correctly throughout the fullscreen transition.
- Clicking an entry in the Active Agents list for a plain folder now navigates correctly instead of silently doing nothing.
- Worktrees that resolve to the same path are no longer listed twice after a repository refresh.
- Terminal text reads (selection, clipboard, accessibility, Quick Look, Services) now correctly handle content that contains embedded NUL bytes, preventing silent truncation.

### Improved

- Updated Sparkle to 2.9.2, addressing a potential crash in the auto-update framework that was observed in the previous beta build.

## [2026.5.24](https://github.com/onevcat/Prowl/releases/tag/v2026.5.24)

This release redesigns the terminal tab bar and sidebar to sit more naturally within macOS, introduces a window tint that colors the chrome to match your repository, and adds keyboard navigation for the Active Agents panel.

### New

- **Navigate the Active Agents panel from the keyboard.** Press ⌃⌥↓ to jump to the next agent and ⌃⌥↑ for the previous one. Navigation is anchored on the focused agent, wraps at the ends of the list, and focuses the target agent's terminal. The panel header reveals the hint while ⌘ is held, and both commands are rebindable in Settings → Shortcuts.
- **Window tint setting.** A new Window Tint option in Settings → Appearance colors the navigation panel and toolbar. Choose None for the neutral system look, Repository Color to match the active repository's pinned color, or Custom Color to apply a single color everywhere.
- **Custom repository colors.** Beyond the built-in presets, you can now assign any color to a repository from the appearance picker.
- **Canvas remembers your layout.** Card positions and stacking order are now saved and restored on relaunch instead of being auto-arranged over, and focused cards come to the front.

### Improved

- **Refined terminal tab bar.** Tabs now float as glass cards with centered titles and stretch to fill the available width. The close button moved to the leading edge and reveals on hover, with a tuned dark-mode brightness ladder and tidier spacing between the tabs and the terminal.
- **Reworked sidebar header.** The view-mode switcher is now a fixed top bar, and Expand/Collapse All is back in the repository header.
- **Redesigned command palette and Find bar.** The command palette adopts the macOS glass material with a softer selection highlight, and the in-terminal Find bar takes on a capsule shape with streamlined icon-only controls.
- **Repository-colored chrome.** The Shelf spine, and the window chrome when tinting is enabled, take on the open repository's color, and the repo color dot stays solid even when the window loses focus.
- **Polish throughout.** Restored the bagua working indicator for agents, improved the empty state shown when no repositories are open, and widened the minimum settings window.

### Fixed

- **No flicker when selecting an agent.** Choosing an agent in the Active Agents panel, by click or keyboard, no longer briefly shows the wrong tab or highlights the wrong agent.
- **Stable toolbar title.** Hovering the worktree title in the toolbar no longer shifts the other toolbar items.

## [2026.5.20](https://github.com/onevcat/Prowl/releases/tag/v2026.5.20)

### Fixed

- The PR chip on the main worktree no longer shows a stale badge from a previously merged pull request. Merged PRs are now correctly ignored when the main branch is checked out.

### Improved

- Internal build and CI improvements; no user-facing behavior changes.

## [2026.5.19](https://github.com/onevcat/Prowl/releases/tag/v2026.5.19)

This release significantly expands the command palette, making it the central hub for navigating and controlling Prowl.

### New

- **Command palette now shows content on open.** Pressing Cmd+P with no query displays a Recent section (commands used in the past month) and a Suggested section (commonly useful app-level commands), so you no longer need to know what to type first.
- **View toggle commands in the palette.** Toggle Sidebar (⌘⌃S), Toggle Active Agents Panel (⌘⌥P), Toggle Canvas (⌘⌥↩), Toggle Shelf (⌘⇧↩), and Show Diff (⌘⇧Y) are now searchable and appear in Suggested when a worktree is active.
- **Navigation commands.** Reveal in Finder, Copy Path, and Reveal in Sidebar are available from the palette when a worktree is selected.
- **Worktree action commands.** Run Script (⌘R), Stop Script (⌘.), Pin/Unpin Worktree, Delete Worktree, and Rename Branch (⌘⇧M) are now accessible from the palette. Run/Stop Script toggles automatically based on the current script state.
- **Repo Settings command.** Open the Settings window navigated directly to the current repository by searching "settings" or the repo name in the palette.
- **Custom commands appear in the palette.** Repository-defined custom commands are searchable by name; their subtitle shows the execution mode (new tab, focused terminal, or split direction).
- **Keyword aliases for app-level commands.** Terms like `preferences`, `config`, `update`, `cli`, `repo`, and `worktree` match their corresponding commands even when the exact title isn't typed.

### Fixed

- Cmd+W now closes the Settings window when it is focused.
- Diff badge in the sidebar no longer truncates on narrow layouts.
- The "Check for Updates" menu item now has an icon, consistent with other app menu entries.

## [2026.5.15](https://github.com/onevcat/Prowl/releases/tag/v2026.5.15)

### Fixed

- Command Palette (`Cmd+P`) now correctly captures keyboard input on macOS 26.4 and 26.5 (Tahoe). Previously, typed text would pass through to the terminal behind the palette instead of updating the query field.
- Dismissing the Command Palette via Escape, repeated `Cmd+P`, or passive commands (such as "Check for Updates") now reliably returns focus to the previously active terminal, including in Canvas mode.
- Long branch names in the sidebar are now truncated in the middle, keeping both the prefix and suffix visible. Hovering shows the full name in a tooltip.

## [2026.5.14](https://github.com/onevcat/Prowl/releases/tag/v2026.5.14)

This release focuses on memory stability after the active-agent detection introduced in 2026.5.11.

### New

- Split pane dividers now respect your Ghostty `split-divider-color` setting. To also control the divider width, add `prowl-split-divider-width = N` (in points, 0–32) to your Ghostty config file.

### Fixed

- Fixed a major memory leak in the Ghostty terminal layer where viewport text buffers were never freed, causing physical memory to grow at roughly 100–200 MB/h on long-running sessions.
- Fixed an additional leak introduced in 2026.5.11 where the active-agent detection loop allocated a Swift task per tick, adding to the footprint growth over time.
- Agent "blocked" state is now correctly detected when the cursor sits on the first option of a tall interactive menu (e.g. a long `/` command list or permission prompt in Claude).

## [2026.5.11](https://github.com/onevcat/Prowl/releases/tag/v2026.5.11)

This release centers on a new Active Agents panel that gives you a live view of every coding agent running across your worktrees.

### New

- **Active Agents panel**: a resizable sidebar panel that tracks every running coding agent — Claude, Codex, Cursor, Kimi, Cline, Gemini, Copilot, Droid, Amp, Pi, and more — across all worktrees, tabs, and split panes. Each row shows the worktree, branch, and current status (working, blocked, idle, or done). Click a row to jump directly to that pane. Toggle the panel with `⌘⌥P` or the button in the sidebar footer.
- **Auto-show on agent detection**: a new toggle in Settings › Appearance › Active Agents opens the panel automatically whenever an agent is detected (off by default).

### Fixed

- In Shelf mode, holding `⌘` now shows `⌘1`–`⌘9` jump glyphs only on the open book's tabs. Closed-book tabs keep their icons, no longer dim, and continue to show the close button on hover while `⌘` is held.

### Improved

- Hovering a repository header in the sidebar animates the color dot smoothly as the action buttons appear, instead of snapping. The animation is skipped when Reduce Motion is enabled.

## [2026.5.9](https://github.com/onevcat/Prowl/releases/tag/v2026.5.9)

This release adds browser-style worktree navigation, inline tab title editing, dynamic window titles, and smarter notification handling, alongside loading-state polish and several notable bug fixes.

### New

- Worktree history navigation: use ⌘⌥[ and ⌘⌥] to move back and forward through recent worktree selections. History is paused while Shelf or Canvas is active; both shortcuts are also accessible from the Worktrees menu.
- Terminal tabs now support inline tab titles editing. Double-click a tab in the tab bar to rename it; custom names survive restarts and appear in Canvas, Shelf, and CLI snapshots.
- Unread notification indicators now appear on individual terminal tabs and split surfaces. Press ⌘⌥U or use "Jump to Latest Unread" in the Command Palette to jump to the surface with the newest unread notification. Tapping a system notification also focuses the originating surface.
- Android Studio is now available as a worktree editor action alongside Xcode, VS Code, and other supported editors.

### Improved

- The main window title now reflects the current repository, worktree, canvas, archive view, or selected terminal tab. Reopening from the Dock, the CLI, the Window menu, or the quit confirmation flow now consistently targets the real main window instead of accidentally landing on Settings or other panels.
- The Add Repository button has moved from the sidebar footer to a `+` icon next to the Repositories header. The "Repositories" header is now always visible (previously hidden until you had more than 10 repos), and new users with no repositories see a pulsing arrow hint pointing to the new button.
- The worktree loading overlay now surfaces the latest five lines of streaming output inline, replacing the previous nested scroll region. Plain-folder removals now read as folder removals in the loading copy.
- Inactive split pane dimming now reads fill color and opacity from Ghostty's runtime configuration rather than a hardcoded tint, so your Ghostty theme is honored consistently.
- The Ghostty indeterminate progress bar now uses SwiftUI's phase animator, producing a smoother sweep with less state churn.
- The Help (?) menu has moved to the leading edge of the sidebar footer, separating it from the Refresh / Archived / Settings action cluster on the trailing side. Repository, Shelf, Archived, and Diff empty states now share a single `ContentUnavailableView` layout for consistent typography and Dynamic Type behavior.

### Fixed

- Holding Cmd+W to close tabs across Shelf book boundaries no longer accidentally closes the window during the brief transition between books.
- Ghostty key equivalents now require the terminal surface to be the active first responder, preventing unintended key capture when another part of the app has focus.
- Shifted menu shortcuts (e.g. Cmd+Shift+?) now match correctly when routing keys to Ghostty, fixing cases where the shifted variant was silently dropped.
- GitHub PR operations (merge, close, ready) now correctly resolve the repository for fork clones, fixing failures caused by same-branch false positives and deleted fork heads.

## [2026.5.4](https://github.com/onevcat/Prowl/releases/tag/v2026.5.4)

This release brings visual polish to split panes and the sidebar, along with a fix for keyboard-driven tab closing.

### New

- Inactive split panes now dim slightly so the focused pane stands out at a glance. The effect adapts to light and dark appearance — stronger in dark mode, subtler in light mode. To disable it, go to Settings → Appearance → Splits and turn off "Dim unfocused split panes".

### Improved

- The sidebar now groups each repository and its worktrees as a cohesive visual unit. Worktree rows are indented under their parent repository, and drag-and-drop indicators are drawn at repository boundaries for clearer reordering feedback.
- The split divider between panes uses a softer separator color, reducing visual noise alongside the new dim treatment.

### Fixed

- Cmd-W now correctly closes a terminal tab when the default Ghostty keybinding for close-tab is not set.

## [2026.4.30](https://github.com/onevcat/Prowl/releases/tag/v2026.4.30)

### New

- When you have more than 10 repositories in the sidebar, a "Repositories" header appears with an expand/collapse-all toggle. The toggle collapses all open repositories if any are currently expanded, and expands all when every repository is collapsed.

### Fixed

- The terminal now correctly regains focus when selecting a single item in the sidebar.
- The terminal now correctly regains focus after making a selection in the Shelf panel.
- Fixed an incorrect empty state displayed in the Shelf under certain conditions.

## [2026.4.29](https://github.com/onevcat/Prowl/releases/tag/v2026.4.29)

This release focuses on Shelf-mode responsiveness — switching books, especially via keyboard shortcuts, is noticeably snappier after a sweep of unnecessary SwiftUI invalidations.

### New

- Repositories can now have a custom display name. Open Repo Settings and set a **Display Name** to override the folder-derived title in the sidebar, toolbar, and canvas. Useful when multiple checkouts share a generic folder name like `src`. Clearing the field reverts to the original folder name.

### Fixed

- Switching between books in Shelf mode is noticeably smoother, particularly when using keyboard shortcuts. A cascade of unnecessary SwiftUI invalidations was traced and removed.
- A trailing space typed at the end of the Display Name field is no longer silently dropped.

## [2026.4.28](https://github.com/onevcat/Prowl/releases/tag/v2026.4.28)

This release adds per-repository visual identity across the entire app.

### New

- Each repository can now have a custom icon and color. Pick an SF Symbol or upload any image, and choose from 10 system colors in Repo Settings. The identity appears in the sidebar row, shelf spine header and background, and canvas card title bar.
- Custom Command tabs now display the command's configured icon for the lifetime of the tab. Run Script tabs keep the play icon throughout the run instead of briefly flashing before switching to the detected command icon.
- Repo Settings is now accessible from the shelf spine context menu.

### Fixed

- The "Choose Image" file picker in Repo Settings now opens inside the repository's working directory instead of the last-used Finder location.
- Hovering the spine's New Tab, Split Vertically, and Split Horizontally buttons now shows the correct per-button tooltip with the associated shortcut key. Previously, the book-level tooltip masked all three buttons.
- User-uploaded repository icon images now display with rounded corners.

## [2026.4.27](https://github.com/onevcat/Prowl/releases/tag/v2026.4.27)

### Fixed

- Fixed a bug where terminal windows could open in the wrong Light or Dark appearance at startup.

## [2026.4.25](https://github.com/onevcat/Prowl/releases/tag/v2026.4.25)

This release brings mouse-driven Canvas navigation and improves reliability for long-running sessions.

### New

- **Canvas zoom with Cmd+scroll wheel**: hold Cmd and scroll to zoom in or out, anchored on the cursor position. Works with both mouse wheels and trackpads.
- **Canvas pan with middle-click drag**: press and drag the middle mouse button to pan the Canvas. Terminals never see the click, and middle-click works normally outside Canvas mode.

### Fixed

- The `prowl` CLI no longer loses its connection to the app after a few days. macOS periodically cleans `/tmp`, which was deleting the socket file and causing `APP_NOT_RUNNING` errors even with the app running. The socket is now stored in `~/Library/Application Support/com.onevcat.prowl/`. A one-time app relaunch is required after upgrading to bind the new path.
- Prowl now applies a runtime Ghostty theme fallback when you have a single theme configured and it mismatches the current macOS appearance (light/dark). No changes are written to your Ghostty config file.
- Canvas auto-fit now reserves space for toolbars and gives cards a bit more room, so cards no longer end up hidden under UI chrome.
- The Canvas navigation help popover no longer truncates its content, and the middle-click hint is hidden for Magic Mouse users who cannot middle-click.

## [2026.4.23](https://github.com/onevcat/Prowl/releases/tag/v2026.4.23)

Tab icons now update automatically based on the running command, making it easy to tell at a glance what each terminal tab is doing.

### New

- **Auto-detecting tab icons**: Prowl now detects the running command from the terminal title and displays a matching icon in the tab bar and Shelf spine. Brand icons are available for coding agents (Claude, Codex, Gemini, Copilot, Amp, and more), editors, package managers, runtimes, VCS tools, containers, and databases — over 55 command mappings in total. The icon stays visible after a short-lived command finishes as a "what is this tab for" hint, and is never overridden if you have manually locked an icon via the Icon Picker.
- **Context-aware Shelf close action**: The Shelf spine context menu now shows "Close Worktree" or "Close Folder" depending on the book type, replacing the old "Remove Book" entry. Closing removes the book from the Shelf without touching the underlying directory or worktree. This also works on the main worktree, which previously showed the option but did nothing.

### Fixed

- Staggered background refresh schedules across worktrees so periodic git and pull-request checks no longer fire simultaneously, reducing CPU spikes when many repos are open.
- Shelf empty-state wording now consistently refers to worktrees, matching the rest of the UI.

## [2026.4.22](https://github.com/onevcat/Prowl/releases/tag/v2026.4.22)

This release introduces Shelf, a new way to view and navigate your worktrees, along with a significant performance improvement that eliminates a source of main-thread hangs.

### New

- **Shelf view**: a new presentation mode that stacks your worktrees as books with vertical spines. Press `Cmd+Shift+Enter` or click the Shelf button in the sidebar toolbar to toggle it. Each spine shows the worktree name, branch, and tab slots; click any spine to open that book.
- **Navigation shortcuts in Shelf**: navigate between books with `Cmd+Ctrl+←` / `Cmd+Ctrl+→`, navigate between tabs with `Cmd+Ctrl+↑` / `Cmd+Ctrl+↓`, or jump directly to a specific book with `Ctrl+Option+1–9`. All bindings are rebindable in Settings → Shortcuts.
- **Command-key tab hints**: hold `Cmd` while in Shelf to swap each tab slot's icon for its `1–9` digit, making keyboard switching more discoverable.
- **Default View setting**: choose whether Prowl launches into the standard view or Shelf in Settings → General.

### Improved

- Eliminated a main-thread hang (App Hang) triggered by rapid file-change or pull-request-refresh bursts. A repeated `standardizedFileURL` comparison in the sidebar render loop was accumulating enough work to stall the UI for 3+ seconds; the result is now computed once per worktree at construction time, so the sidebar stays responsive under heavy activity.

### Fixed

- Shelf now correctly restores focus to the open book's terminal after SwiftUI reparenting, and properly tracks which worktrees the user has actually opened rather than showing all known worktrees.
- Toggling into Shelf from Canvas now honors the card that was focused in Canvas as the open book, rather than falling back to a default.

## [2026.4.20](https://github.com/onevcat/Prowl/releases/tag/v2026.4.20)

This release focuses on canvas usability improvements and broader code host support.

### New

- Canvas cards now show close and expand buttons in the title bar when you hover over them, letting you act on any card without focusing it first.
- When a focused canvas card is closed (via button, Cmd+W, or any other method), focus automatically moves to the nearest surviving card so the highlighted state stays consistent.
- The "Open on Code Host" action now works beyond GitHub and beyond open pull requests. Worktrees with a PR still open the PR; others fall back to the repository homepage. GitLab-style remotes are supported.
- Code host actions in the toolbar and command palette are now labeled with the detected host name (e.g., "Open on GitHub" vs. "Open on GitLab").
- "Change Tab Icon..." and "Open Repository on Code Host" are now hidden from the command palette's empty-query list to reduce noise. Type to search for either action.

### Fixed

- Restored two-finger scroll for TUI programs (pagers, editors, etc.) inside canvas mode. A previous optimization incorrectly forwarded scroll events to the canvas when Ghostty reported no scrollback buffer, breaking apps like `nvim`, `less`, and `htop`.
- Fixed a crash (EXC_BREAKPOINT abort) that could occur during ANR detection due to Sentry invoking a Swift concurrency callback off the main thread.

## [2026.4.18](https://github.com/onevcat/Prowl/releases/tag/v2026.4.18)

This release focuses on tab customization and a less-interrupting update experience.

### New

- **Tab icons**: Right-click any terminal tab and choose "Change Tab Icon..." to pick from a curated SF Symbol preset grid or enter any SF Symbol name directly. You can also invoke this from the Command Palette (Cmd+P, search "icon"). Custom icons survive app restarts when *Restore Terminal Layout on Launch* is enabled.
- **Rename from context menu**: "Change Tab Title..." is now available directly in the tab right-click menu, in addition to the existing keyboard shortcut flow.
- **Quiet update notifications**: Available updates no longer interrupt your session with a dialog. A badge appears in the toolbar instead; click it (or use "Check for Updates...") when you are ready to install.
- **Anonymous quality telemetry**: To help improve Prowl, this release adds lightweight anonymous crash reporting and memory usage telemetry. No personal data is collected. If you prefer not to participate, you can opt out in Settings.

### Fixed

- The "Download and install automatically" setting has been removed; it conflicted with the new silent update detection flow and was not functional in this build.

## [2026.4.17](https://github.com/onevcat/Prowl/releases/tag/v2026.4.17)

This release focuses on Custom Command power-ups and two Canvas reliability fixes.

### New

- **Custom Commands can now open a New Split**, running your command in a new pane alongside the current terminal. Choose split direction (left, right, up, down) per command in Settings.
- **Close on success** toggle for New Tab and New Split targets: when enabled, the tab or split is automatically dismissed after the command exits with code 0, leaving it open on failure so you can inspect the output.
- The toolbar status badge now animates in and out smoothly, and a brief toast appears when a Custom Command completes successfully.

### Fixed

- Creating split panes with Cmd+D or Cmd+Shift+D while in Canvas mode no longer freezes rendering. All panes now display and accept input correctly.
- Two-finger pan on the Canvas is no longer interrupted when the cursor drifts over a focused terminal card mid-gesture. Scrolling on a card with no scrollback content now pans the canvas instead of being silently consumed.

## [2026.4.16](https://github.com/onevcat/Prowl/releases/tag/v2026.4.16)

### Fixed

- Fixed a race condition when entering Canvas view that could leave the terminal surface blank.

## [2026.4.15](https://github.com/onevcat/Prowl/releases/tag/v2026.4.15)

### New

- **Fetch before worktree creation**: Prowl can now run `git fetch` against the relevant remote before creating a new worktree. The option is on by default and can be toggled in Settings > Worktree. Fetch errors are logged but do not block worktree creation.
- **Merged worktree action**: The "auto-archive on merge" toggle has been replaced with a three-option picker — Do Nothing, Archive, or Delete — controlling what happens to a worktree when its pull request is merged. Find it in Settings > Worktree. Existing configurations migrate automatically.
- **Global defaults for copy flags and merge strategy**: The "copy ignored files", "copy untracked files", and "pull request merge strategy" settings can now be configured once as global defaults in Settings, with optional per-repository overrides. Repository-level pickers show the current global value when no override is set.

### Fixed

- Terminals could appear blank after exiting Canvas view due to the surface losing its host attachment. Prowl now detects and recovers from this state automatically.

## [2026.4.11](https://github.com/onevcat/Prowl/releases/tag/v2026.4.11)

This release focuses on worktree management improvements and quality-of-life fixes.

### New

- **Auto-delete archived worktrees**: A new setting in Worktree Settings lets you configure a period (1, 3, 7, 14, or 30 days) after which archived worktrees are deleted automatically.
- **Reveal in Sidebar**: Press Shift+Cmd+L to scroll the sidebar to the currently selected worktree, expanding its repository section if collapsed.
- **Archived worktrees discoverability**: Archive confirmation dialogs now tell you where to find archived worktrees (Menu Bar > Worktrees, or Control+Cmd+A). A "View Archived Worktrees" entry is also available in the command palette.

### Fixed

- Restored terminal surfaces no longer spin the CPU and GPU when they are not displayed, keeping resource usage low for non-visible tabs after session restore.

## [2026.4.9](https://github.com/onevcat/Prowl/releases/tag/v2026.4.9)

Tab layout and Worktrees menu discoverability are the main themes of this release.

### New

- All worktrees and plain folders now appear in the Worktrees menu, regardless of count. Previously only the first 9 were shown. Items beyond the 9th no longer have keyboard shortcuts but remain reachable via the menu or **Help > Search**.
- Manually renamed tab titles and icons are now saved in the terminal layout snapshot and restored when the layout is reloaded.
- Added Homepage and Release Notes links to the Help menu and sidebar footer.

### Fixed

- Plain folders were missing from the Worktrees menu entirely; they now appear in the same order as the sidebar.

## [2026.4.7](https://github.com/onevcat/Prowl/releases/tag/v2026.4.7)

### Fixed

- When using a transparent background (`background-opacity < 1`) in dark mode on macOS 26, the titlebar and window border now correctly appear dark-tinted instead of showing an unwanted light glass effect.
- The sidebar footer now displays a proper frosted glass effect when the background is transparent, rather than a plain semi-transparent fill that let the wallpaper bleed through without blur.
- When creating a worktree, the base branch picker now includes local branches alongside their upstream counterparts. Previously, tracked local branches were omitted, making the picker appear to only support remote refs.

## [2026.4.6](https://github.com/onevcat/Prowl/releases/tag/v2026.4.6)

This release brings a redesigned sidebar with a modern, cleaner, and more compact layout, along with reliability fixes across the terminal surface and CLI.

### New

- **Redesigned Sidebar** — the sidebar has been completely re-laid out for a modern, cleaner, and more compact look, giving you more room to focus on your work.
- **Reveal in Finder** is now available in the worktree context menu, opening the worktree directory directly in Finder.
- The run script indicator (green play icon) now shows a red stop button on hover; clicking it stops the running script.
- The tab count badge on repository headers now shows a tooltip with the active tab count when hovered.
- CLI tool install and uninstall results now show a toolbar toast on the main window for all entry points (Command Palette, menu bar), so you always get feedback regardless of whether Settings is open.
- `prowl key` now correctly emits ANSI control characters for `Ctrl-[`, `Ctrl-\`, `Ctrl-]`, `Ctrl-^`, and `Ctrl-_` combos, and uppercase letters preserve their shift meaning.

### Fixed

- Hovering a worktree row no longer causes a vertical layout jump when pin and archive buttons appear.
- Archive, Delete, pin, and archive buttons are now hidden for the main worktree, where those actions do not apply.
- Terminals could appear blank after exiting Canvas view due to occlusion state being applied before the surface was reattached to the view hierarchy; this is now deferred correctly.

## [2026.4.5](https://github.com/onevcat/Prowl/releases/tag/v2026.4.5)

Prowl gains a command-line tool for scripted terminal control.

### New

- **`prowl` CLI**: Control Prowl from the command line with `open`, `focus`, `send`, `read`, `list`, and `key` commands. Run `prowl --help` to get started.
- **Install the CLI from within the app**: Go to Settings > Advanced, the Prowl menu, or the Command Palette (Cmd+P) and choose "Install Command Line Tool" to add `prowl` to `/usr/local/bin`.
- **Auto-launch on `prowl open`**: If Prowl is not running when you invoke `prowl open <path>`, it launches automatically and then opens the requested path.
- **Auto-target resolution**: All selector commands (`focus`, `send`, `read`, `key`) now accept a positional `<target>` argument or `-t`/`--target` flag. Pass any pane UUID, tab UUID, or worktree name and Prowl resolves the type automatically.
- **`prowl send --capture`**: Snapshots the screen buffer before and after command execution and returns the diff as captured output, useful for scripted workflows that need to inspect command results.
- **Layout restore warning**: When a saved terminal layout snapshot cannot be restored, Prowl now shows a warning in the toolbar instead of silently resetting.

### Fixed

- Clicking anywhere on the Canvas row in the sidebar (including padding) now correctly selects Canvas. Previously only the icon and label text were responsive.
- Exiting Canvas could leave the terminal blank until you switched away and back. The surface state is now refreshed immediately on Canvas exit.

## [2026.4.2](https://github.com/onevcat/Prowl/releases/tag/v2026.4.2)

Fully customizable keyboard shortcuts and persistent terminal layout across app launches.

### New

- **Fully customizable keyboard shortcuts**: A dedicated Shortcuts page in Settings gives you complete control over every key binding in Prowl. Remap app actions, terminal tab and pane navigation, split management, and the command palette to any key combination you prefer. The editor records shortcuts directly from your keyboard, detects conflicts with existing bindings inline, and lets you replace or cancel on the spot. Whether you are a Vim user remapping splits or just want `Cmd+T` to do something different, every shortcut is now yours to define.
- **Terminal layout restore**: Prowl now remembers your full terminal layout — tabs, splits, and their arrangement — and restores it exactly when you relaunch. Enable "Restore Layout on Launch" in Settings > Advanced, and your workspace is back in seconds, no matter how complex the setup. Use "Clear saved terminal layout" to reset to the default empty state whenever you want a fresh start.
- **Custom commands revamp**: The repository custom commands editor is now a fully inline-editable table with an SF Symbol icon picker, shortcut recording, and no cap on the number of commands. Commands beyond the first three appear in a toolbar overflow menu.
- **Script environment variables**: Scripts run by Prowl now receive `PROWL_WORKTREE_PATH` and `PROWL_ROOT_PATH` environment variables (renamed from the old `SUPACODE_` prefix).
- **Window menu additions**: Tab and pane selection shortcuts are now accessible from the Window menu.

### Fixed

- Font size no longer resets when switching between worktrees or when Ghostty reloads its config due to custom command changes.
- `Cmd+0` (reset font size) now affects the current pane only; new tabs inherit the reset size. The old tab-0 and worktree-0 shortcuts (`Cmd+0` / `Ctrl+0`) have been removed to free up these key combinations.
- Terminal layout restore now works correctly for plain folders and correctly suppresses re-saving after clicking "Clear saved terminal layout."
- Pane focus is correctly restored after toggling zoom on a split pane.
- Scripts running in fish shell no longer hang due to an `exit $?` incompatibility.

## [2026.3.28](https://github.com/onevcat/Prowl/releases/tag/v2026.3.28)

Persistent terminal font size and freed-up keybindings.

### New

- Terminal font size now persists across sessions. Prowl saves your preferred size and restores it when you relaunch. Font size controls are available in the View menu.
- Cmd+0 has been freed from its previous font-size binding, making it available for custom Ghostty keybindings.

### Fixed

- Plain folder repositories now show the correct open tab count in the sidebar header.

## [2026.3.27](https://github.com/onevcat/Prowl/releases/tag/v2026.3.27)

Sidebar tab count badges and Homebrew distribution.

### New

- The sidebar now shows a small tab count badge next to each repository name, reflecting the total number of open terminal tabs across all worktrees for that repo. The badge appears automatically when tabs are open and disappears when none remain.
- Prowl is now available via Homebrew: `brew install --cask onevcat/tap/prowl`. Updates are also delivered through the tap automatically.

## [2026.3.25](https://github.com/onevcat/Prowl/releases/tag/v2026.3.25)

Canvas multi-select broadcast input — select multiple terminal cards and type once to send the same input to all of them.

### New

- Canvas multi-select: Cmd+Click to select multiple cards, Cmd+Opt+A to select all. Selected cards show a visual distinction between primary (accent ring) and followers (subtle tint).
- Broadcast input: typing in the primary card mirrors committed text and special keys (Enter, Backspace, arrows, Tab, Escape, Ctrl+key) to all selected follower cards.
- IME-safe broadcast: followers receive only committed text (e.g. 你好), not intermediate phonetic input (e.g. nihao). Works correctly with Chinese, Japanese, and other input methods.
- Cmd+V paste and right-click Paste are broadcast to all selected cards.
- Cmd+Backspace (delete line) and Cmd+Arrow (line navigation) are broadcast to followers.
- Escape clears broadcast selection. Click a follower to promote it to primary without clearing selection.

### Fixed

- Terminal scrollback position is now preserved during output, preventing unwanted scroll jumps.
- Cmd+W now correctly closes the focused surface in Canvas mode.

## [2026.3.24](https://github.com/onevcat/Prowl/releases/tag/v2026.3.24)

Plain folder support and several UX and stability improvements.

### New

- Plain folders can now be added alongside Git repositories. They open directly into terminal tabs with their own toolbar, settings, and command palette entries. Git-only actions are hidden when a plain folder is selected. Folders are automatically upgraded to Git repositories when a `.git` directory is detected, and conservatively downgraded when it is removed.
- Hotkey actions for archive and delete worktree are now scoped to the sidebar, preventing accidental triggers from the terminal. Close Window (⌘W) now works when no terminal is focused, and Show Window (⌘0) brings the main window to front.
- App size reduced by approximately 7 MB thanks to an optimized YiTong web bundle.
- Added diagnostic logging for scroll jump events to help investigate an intermittent snap-to-bottom issue during scrollback reading.

### Fixed

- Exiting Canvas could leave terminal surfaces blank. Occlusion state is now correctly restored whenever a surface is reattached, regardless of how the transition happened.
- The Settings toolbar no longer shows an unnecessary separator on macOS 26.

## [2026.3.23](https://github.com/onevcat/Prowl/releases/tag/v2026.3.23)

Canvas double-click navigation and smoother card animations.

### New

- Double-click a card's title bar in Canvas to switch directly to that tab's normal view. First click focuses the card with immediate visual feedback, second click switches the view.
- Canvas Arrange and Organize now animate smoothly when repositioning cards.

### Fixed

- Blank terminal surface when exiting Canvas via the toggle shortcut.

## [2026.3.22](https://github.com/onevcat/Prowl/releases/tag/v2026.3.22)

Command finished notifications and Canvas notification highlights.

### New

- Command finished notifications now alert you when a long-running terminal command completes. Configure the duration threshold in Settings.
- In Canvas, unseen notifications now highlight the entire title bar of the affected tab card, tracked per-tab for better granularity.
- Notifications are automatically marked as read when you type into the focused terminal, and command finished notifications are suppressed if you've recently interacted with that terminal.
- Terminal key repeat now works immediately — the macOS press-and-hold accent menu is disabled in terminal surfaces.
- Updated the embedded terminal engine to Ghostty v1.3.1.
- VSCodium is now recognized as a supported editor.

### Fixed

- Worktree selection is now cleared when entering Canvas mode, preventing stale focus state.

## [2026.3.21](https://github.com/onevcat/Prowl/releases/tag/v2026.3.21)

Ghostty keybindings and actions that previously had no effect now work in Prowl.

### New

- You can now rename a tab or terminal surface title from the command palette or a bound key. "Change Tab Title" locks the title until you clear it; "Change Terminal Title" sets the surface title and resumes auto-updates when cleared.
- "Open Config" now opens your Ghostty configuration file in the default text editor.
- Fullscreen (`toggle_fullscreen`), maximize (`toggle_maximize`), and background opacity (`toggle_background_opacity`) Ghostty actions now work as expected. Opacity toggling requires `background-opacity < 1` in your Ghostty config and has no effect in fullscreen.
- The `quit` action now routes through the standard macOS termination flow, so any confirm-before-quit prompt still triggers. `close_window` closes the window containing the active terminal.

### Fixed

- The command palette no longer shows duplicate or inapplicable entries (removed redundant "Check for Updates", single-window actions like "New Window", Ghostty debug tools, and iOS-only actions).

## [2026.3.20](https://github.com/onevcat/Prowl/releases/tag/v2026.3.20)

Faster and more reliable startup with snapshot-based repository restore.

### New

- Repositories now appear immediately on launch by restoring from a local snapshot cache, rather than waiting for the full live refresh to complete. The cache is stored at `~/.prowl/repository-snapshot.json` and is always followed by a background refresh to stay up to date.
- Worktree discovery now runs in parallel across all repositories, and the bundled `wt` tool is invoked directly instead of through a login shell, reducing startup latency.

### Fixed

- Prowl no longer deletes `~/.supacode` on first launch when co-installed with Supacode. Migration now copies data to `~/.prowl` instead of moving it.

## [2026.3.19](https://github.com/onevcat/Prowl/releases/tag/v2026.3.19)

Canvas improvements: better card layout, smarter focus behavior, and a keyboard shortcut to toggle the view.

### New

- Press `⌥⌘↩` to toggle Canvas view. The command has also moved to the View menu.
- Canvas now auto-arranges cards on first entry using a masonry-style packing algorithm, which produces a more compact, better-scaled layout.
- When entering Canvas, focus automatically returns to the card you were last working on. When exiting, focus restores to the exact worktree and tab you had active inside Canvas.
- Added notification settings for focus events, allowing you to control when Prowl alerts you about focus changes.

### Fixed

- File paths containing Unicode characters (e.g., Chinese filenames) were not shown correctly in diffs and untracked file lists.

## [2026.3.18.2](https://github.com/onevcat/Prowl/releases/tag/v2026.3.18.2)

Canvas layout and polish improvements.

### New

- Added an "Arrange" button to the Canvas toolbar that automatically lays out cards in a waterfall pattern, making it easy to tidy up a crowded canvas.
- Increased the default card size and raised the maximum resize limit, giving more room to work with agent output at a glance.

### Fixed

- The Canvas toolbar title no longer appears as a tappable navigation button.
- The Canvas sidebar button label is now properly centered, and no longer bleeds through overlapping content when scrolling.

## [2026.3.18](https://github.com/onevcat/Prowl/releases/tag/v2026.3.18)

Initial public release of Prowl, rebranded from Supacode.

### New

- Prowl is now the app's name and identity, with an updated app icon to match.
- Sparkle auto-update support is included, so future releases will be delivered automatically.
