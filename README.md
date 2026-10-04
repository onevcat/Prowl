<p align="center">
  <img src="https://prowl.onev.cat/images/prowl-icon-rounded.png" width="128" alt="Prowl">
</p>

<h1 align="center">Prowl</h1>

<p align="center">
  <b>Your terminal wasn't built for agents. Until now.</b><br>
  A native macOS command center for running AI coding agents in parallel.
</p>

<p align="center">
  <a href="https://github.com/onevcat/Prowl/releases/latest/download/Prowl.dmg"><b>Download</b></a>
  ·
  <a href="https://www.youtube.com/watch?v=4GYlXPttwi0">Watch Demo</a>
  ·
  <a href="https://prowl.onev.cat/details/">Feature Tour</a>
  ·
  <a href="https://prowl.onev.cat/manual/">Manual</a>
  ·
  <code>brew install --cask onevcat/tap/prowl</code>
</p>

<p align="center">
  <img src="https://prowl.onev.cat/images/shots/canvas.webp" alt="Prowl Canvas: five live terminals tiled as cards (Claude Code waiting on a permission prompt, Codex and Pi done, a git log) next to the Active Agents panel">
</p>

<p align="center">
  <sub>Canvas with five live terminals. One agent waits on a permission prompt, two are done, and Active Agents shows which one to look at first.</sub>
</p>

---

## Why Prowl?

You're not just typing commands anymore. You're running Claude Code in one branch, Codex in another, and a third agent on a migration, and the hard part is knowing which one needs you next. Prowl is a native macOS terminal built around exactly that:

- **[See every agent at once](#see-every-agent-at-once)**: Canvas and Shelf lay out all your worktrees and live sessions.
- **[Know who needs you](#know-who-needs-you)**: Agent Island and Active Agents flag the blocked or finished agent, even while another app is in front.
- **[Automate the loop](#automate-the-loop)**: launch agents from profiles, let them review each other's work in workflows, and put your daily commands on a key.
- **[Let your agents drive](#let-your-agents-drive-the-terminal)**: the `prowl` CLI lets an agent read panes, run commands, and start helper agents.

Works with the agents you already use: **Claude Code, Codex, Gemini CLI, Cursor Agent, Cline, OpenCode, GitHub Copilot, Kimi, Droid, Amp, Qoder CLI, Qwen Code, Grok Build, Pi, and Oh My Pi.**

## 🐾 Meet Prowl through your agent

Prefer to learn the agentic way instead of scrolling? Hand this prompt to your coding agent (Claude Code, Codex, …) or any AI assistant — it reads Prowl's full documentation and gives you a tailored introduction:

```text
Read Prowl's documentation and introduce it to me.

Prowl is a native macOS command center for running many AI coding agents in parallel. Its full manual lives here:
https://raw.githubusercontent.com/onevcat/Prowl/refs/heads/main/docs/README.md

Fetch that index and read it (it links to an overview and per-feature manuals in the same docs/ folder — read the relevant ones). Then:
1. Briefly tell me what Prowl is and why it's worth my time.
2. Based on what you know about how I work, suggest 3–4 Prowl features that would genuinely help me, each with a one-line "how".
3. Then answer my follow-up questions, consulting the matching doc.

Reply in my preferred language.
```

> Already installed Prowl? Your agent can read the same docs straight from the app bundle — choose **Help → Ask Agent About Prowl** in the app to copy a version localized to your language.

## See every agent at once

Repositories hold worktrees, worktrees hold tabs, and tabs hold panes. Prowl lays out that hierarchy in three ways, and switching between them never touches your running sessions.

### 🖼 Canvas — every agent, at a glance

Three agents running, one just finished. _Where?_ The screenshot at the top is Canvas: every open tab becomes a card on a zoomable board, and every card is a **live, interactive terminal**, not a thumbnail. Click into any card to type.

- **Broadcast.** Select cards with ⌘-click or `⌘⌥A`, then type once. "Run the tests", "commit", `/clear`: every selected agent gets it.
- **Finished cards light up.** When a task completes, its card's title bar turns orange until you look at it.
- **Tile like a window manager.** `⌘⌥T` fills the window, `⌘⌥R` packs the cards, `⌘⌥G` resets a uniform grid. Toggle Canvas with `⌘⌥↩`.

### 📚 Shelf — your worktrees, lined up like books on a shelf

<img align="left" width="400" src="https://prowl.onev.cat/images/shots/shelf-1200.webp" alt="Shelf view with worktree spines on both sides and one open terminal">

Every worktree becomes a vertical **spine** in its repository's color, with its tabs and each agent's status marker underneath. One book is open in the middle. Flip through the stack from the keyboard — **`⌘⌃←` / `⌘⌃→` flips books · `⌘⌃↑` / `⌘⌃↓` cycles tabs** — so when you've got six agents in flight, you triage them one keystroke at a time, never losing your place. Toggle Shelf with `⌘⇧↩`.

<br clear="all">

## Know who needs you

With several agents in flight, the bottleneck is not running them. It is knowing where to look next. Prowl watches every pane, names the state, and puts the agent that needs you a glance or a single key away.

### 🏝 Agent Island — your agents, around the notch

<p align="center">
  <img width="425" src="https://prowl.onev.cat/images/shots/agent-island.webp" alt="Agent Island bar showing one blocked, one done and two idle agents, with Blocked and Done cells below it">
</p>

<img align="right" width="400" src="https://prowl.onev.cat/images/shots/agent-island-roster.webp" alt="Agent Island expanded roster listing four agents with their state and 1–4 shortcuts">

Agent Island puts the agent roster at the top of your display, so it stays visible while another app is in front. On a notched Mac it wraps around the camera; on other displays it floats over the menu bar.

- **Counts by state**, in attention order: blocked, done, working, idle.
- **Blocked and Done cells drop below the bar** the moment they happen. Click one, and Prowl comes forward on exactly that pane.
- **Drive it from any app.** Assign a *Toggle Agent Island* shortcut, then use the arrows or `j`/`k` to move, `1`…`9` to pick, and `↩` to jump.
- **Quiet by default.** Turn it on in Settings → Agents → Display.

<br clear="all">

### 🚦 Active Agents — one live roster

<img align="left" width="272" src="https://prowl.onev.cat/images/shots/active-agents.webp" alt="Active Agents panel listing Claude Code, Codex and Pi with Blocked, Done and Idle states">

Every agent across every worktree, tab, and split, in one list. Click a row to land in that agent's pane, or cycle through agents with `⌥⌃↑` / `⌥⌃↓`.

🔴 **Blocked**: waiting on you, at a permission or confirmation prompt.<br>
🔵 **Done**: finished, and you have not looked yet.<br>
🟠 **Working**: still processing.<br>
⚪ **Idle**: nothing running.

Walk away: Prowl posts a macOS notification when an agent finishes or stops to ask you something. `⌘⌥U` jumps to the latest unread pane.

<br clear="all">

## Automate the loop

Starting the same agents, running the same build, the same "review this and hand it off" routine, every day. Prowl turns each of them into one click: profiles to launch agents, workflows to run multi-agent loops, and buttons for your commands.

### 🚀 Agent Profiles — every agent, launched your way

<img align="right" width="240" src="https://prowl.onev.cat/images/shots/agents-menu.webp" alt="The toolbar Agents menu: a Run a workflow section, then launch rows for Claude Code, Codex, Gemini CLI, Cursor Agent and Cline">

A profile is a named launch preset: runtime, model, reasoning effort, execution mode, and where the pane opens. Prowl creates one for each agent CLI you have installed, so the toolbar's Agents menu is ready on first launch. One click starts a fresh agent in the current worktree, set up exactly how you want it.

- **Launch from anywhere**: the toolbar Agents menu, its one-click button for the repository's recommended profile, `⌘P` → *Launch Agent*, or `prowl create tab --profile` from a script.
- **As many as you like**: a careful high-effort reviewer and a fast fixer can share one runtime. Prowl shows only the options that the CLI supports, and a preview shows the exact command.
- **Second accounts and endpoints**: give a profile its own environment variables (they never appear in the typed command or shell history) or its own runtime home for a separate account.
- **Reliable completion**: for supported runtimes such as Claude Code and Codex, an agent launched from a profile reports through native hooks when its turn ends.

<br clear="all">

### 🔁 Agent Workflows — put your agents in a loop

A workflow scripts several live agents: who takes part, and what happens in which order. Prowl types each instruction into the right pane, waits for the agent to deliver, branches or loops on its verdict, and shows the run in the toolbar. Every participant is a real terminal pane that you can watch, or step into at any time.

Two workflows come built in:

- **Review Loop**: start it from the agent that just wrote the code. Prowl opens a reviewer from any Agent Profile in a split beside it. The reviewer reports findings, the author fixes them or pushes back, and they repeat (2–4 rounds by default) until the review is clean.
- **Handoff**: context is the expensive part. The current agent writes a briefing (objective, current state, next steps) to `.prowl/handoff/`, and Prowl can start a different agent to continue: Claude Code to Codex, Codex to Pi.

<p align="center">
  <img width="760" src="https://prowl.onev.cat/images/shots/workflow-history.webp" alt="Workflow History panel over a Handoff run that needs attention, with the Prepare handoff briefing step expanded and Focus Pane / Cancel Run actions">
</p>

Start a workflow from `⌘P`, the toolbar Agents menu, a right-click on an Active Agents row, or `prowl workflow run`. The toolbar shows the current step and tells you when a run needs you; Workflow History keeps every prompt, delivery, and script output.

**Write your own.** A workflow is a `.pwlworkflow` bundle with a `workflow.yaml`: roles, steps, and typed state. Keep it in `~/.prowl/workflows`, or commit it to the repository's `.prowl/workflows` so that it travels with the code. You don't even have to write the YAML yourself: the bundled `prowl-workflow` skill teaches your agent to write and debug workflows for you.

```yaml
# ~/.prowl/workflows/second-opinion.pwlworkflow/workflow.yaml
schema: prowl.workflow/v1
id: second-opinion
name: Second opinion
roles:
  author:   {source: current}   # the pane you start from
  reviewer: {source: launch}    # a fresh agent from one of your profiles
steps:
  - id: brief
    message: author
    prompt: Summarize the change you just made and how you verified it.
    expect: {delivery: brief}
  - id: review
    launch: reviewer
    prompt: Review {{ deliveries.brief.path }} against the current diff.
    expect: {delivery: findings, verdicts: [clean, issues]}
  - id: done
    notify: "Review verdict: {{ deliveries.findings.verdict }}"
```

### ⚡ Custom Actions — one keystroke, any routine

<p align="center">
  <img width="470" src="https://prowl.onev.cat/images/shots/custom-commands.webp" alt="Toolbar with an Xcode button and Run, Build, Check and Test command buttons">
</p>

Pin `swift build`, `npm test`, or `claude -p "review this diff"` to a toolbar button with an icon and a hotkey such as `⌘B`. Set them up once globally or per repository, and stop typing the same thing every day. Pair them with `claude -p` / `codex exec` to turn your terminal into a daily AI-powered assistant.

## Let your agents drive the terminal

Your agent needs to run a test, read the output, and decide what's next. Prowl ships with a `prowl` CLI that talks to the running app, so both you and your agents can see, address, and coordinate panes:

```bash
prowl list                              # discover worktrees, tabs, panes, and agent states
prowl send p6 "npm test" --capture      # run a command and capture exactly its output
prowl read p4 --last 40 --wait-stable   # read a screen once it settles
prowl key p4 enter                      # send keystrokes

# start a reviewer in a split beside this pane, then wait until it reports back
echo "Review this branch" | prowl create pane "$PROWL_PANE_ID" \
  --direction right --profile Reviewer --prompt - --json
prowl agents wait --dispatch <dispatch-id>
```

Install the CLI from **Settings → Agents → CLI & Skills**. Then run `prowl skills install` to link the bundled `prowl-cli` and `prowl-workflow` skills into Claude Code, Codex, and other agents, so they know when and how to drive Prowl. The links point into the app, so every app update also updates the skills.

## And the fundamentals, done right

- **Fully native**: rendered by libghostty, the Ghostty terminal engine. No Electron, no web views. CJK-safe out of the box, and your Ghostty config is respected.
- **Git worktrees, first-class**: `⌘N` creates a parallel branch for a new agent, with an on-device Apple Intelligence branch name suggestion. Setup and archive scripts run on the worktree lifecycle.
- **Diff and GitHub, built in**: `⌘⇧Y` shows what an agent changed. Pull request state, review decision, and CI status appear on each worktree row; merge or re-run failed jobs from `⌘P`.
- **Workspaces**: link several repositories in one folder, so one agent can work across an app, its API, and a shared package.
- **Command Palette**: `⌘P` reaches every action by name. Remap any shortcut in Settings → Shortcuts.
- **Notarized and auto-updated**: Sparkle keeps you on the latest release. The UI is available in English and Simplified Chinese.

Want the full picture? Take the [feature tour](https://prowl.onev.cat/details/) or browse the [manual](https://prowl.onev.cat/manual/).

## Install

**Download:** [Prowl.dmg](https://github.com/onevcat/Prowl/releases/latest/download/Prowl.dmg) (notarized)

**Homebrew:**

```bash
brew install --cask onevcat/tap/prowl
```

Then add a repository with `⌘⇧O`, press `⌘N` to create a worktree, and launch an agent from the toolbar's Agents menu. Run a few in parallel and turn on Agent Island: you will always know which one needs you.

## Requirements

macOS 26.0+

---

## For Developers

A personal fork of [Supacode](https://github.com/supabitapp/supacode), built on [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) and [libghostty](https://github.com/ghostty-org/ghostty), maintained for daily use. Requires [mise](https://mise.jdx.dev/) for dev tooling.

### First build from a fresh clone

```bash
git clone --recurse-submodules https://github.com/onevcat/Prowl.git
cd Prowl
make build-app
```

`make build-app` installs the pinned development tools and fetches the pinned GhosttyKit
artifact when needed. If you cloned without `--recurse-submodules`, run
`git submodule update --init --recursive` before building.

### Build & run

```bash
make build-ghostty-xcframework   # Build GhosttyKit from Zig source
make build-app                   # Build the macOS app (Debug)
make generate                    # Generate Prowl.xcworkspace with Tuist to open the project in Xcode
make run-app                     # Build and launch the Debug app with log streaming
make install-dev-build           # Build Debug and install to /Applications/Prowl Debug.app
make install-release             # Build Release, sign locally, install to /Applications
```

### Develop & test

```bash
make check                 # Format changed Swift files, then run lint and repository checks
make format-changed        # Format changed Swift files only
make format                # Full-tree Swift format cleanup
make lint                  # SwiftLint only
make test                  # Run the Mac app tests
make test-all              # Run every test suite, including the CLI and both mirror clients
make log-stream            # Stream app logs (subsystem: com.onevcat.prowl)
```

### CLI

```bash
make build-cli             # Build `prowl` CLI via SwiftPM
make test-cli-smoke        # Quick CLI smoke checks
make test-cli-unit         # CLI unit tests
make test-cli-integration  # End-to-end CLI socket integration tests
```

### Ghostty sync

```bash
make ensure-ghostty        # Fast SHA check (auto-run by build-app/test)
make sync-ghostty          # Force rebuild + clear DerivedData
```

### Release

Day-to-day releases are driven by the `release` agent skill defined in [`.claude/skills/release/SKILL.md`](.claude/skills/release/SKILL.md). It wraps two scripts you can also run directly:

```bash
./scripts/release-notes.sh <VERSION>   # Generate user-facing notes → build/release-notes.md
./scripts/release.sh <VERSION>         # Bump, build, sign, notarize, DMG, appcast, GitHub Release, Prowl-Site update
```

The skill walks the flow interactively: verify branch & tree state, confirm the version, review the generated notes, then run `release.sh`. All fork releases are notarized.
