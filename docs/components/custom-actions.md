# Custom Actions, Scripts & Run Commands

> Turn repeated commands into buttons and hotkeys: the Run Script, the automatic
> Setup/Archive scripts, and per-repo Custom Commands.

**Keywords:** custom command, custom action, run script, setup script, archive script, button, hotkey, PROWL_WORKTREE_PATH, PROWL_ROOT_PATH, close on success, split, terminal input, swift build, npm test, claude -p

**Related:** [repositories-and-worktrees](repositories-and-worktrees.md) · [terminal](terminal.md) · [settings](settings.md) · [keyboard-shortcuts](../reference/keyboard-shortcuts.md)

## Overview

Prowl has four distinct mechanisms for "run my command":

| Mechanism | Scope | When it runs | Configured in |
|-----------|-------|--------------|---------------|
| **Run Script** | one per repo | on demand (`⌘R`) | Repo Settings → Run Script |
| **Setup Script** | one per repo | automatically after a worktree is created | Repo Settings → Setup Script |
| **Archive Script** | one per repo | automatically before a worktree is archived | Repo Settings → Archive Script |
| **Custom Commands** | many per repo | on demand (button / hotkey / palette) | Repo Settings → Custom Commands |

All scripts run with these **environment variables** injected:
- `PROWL_WORKTREE_PATH` — the active worktree's directory.
- `PROWL_ROOT_PATH` — the repository root.

Run Script, Setup Script, Archive Script, and Custom Commands can keep their
inline command text or reference a reusable Script Profile from
`~/.prowl/script-profiles.json`. Existing inline settings remain the default.
Profile pickers in Repo Settings provide a direct action to open
**Settings → Scripts** for profile management.

## Run Script (`⌘R` / `⌘.`)

A single per-repo command you launch on demand.

- **Run:** `⌘R` (`run_script`) — runs the repo's Run Script in the focused
  worktree. If no Run Script is set, you're prompted for one.
- **Stop:** `⌘.` (`stop_script`).
- A toolbar **Run** button is shown when `showRunButtonInToolbar` is on.
- While running, the worktree shows a running status; the tab is title-locked to
  the command until it finishes.

## Setup Script (automatic on create)

Set a per-repo **Setup Script** to bootstrap every new worktree — install deps,
copy env files, warm caches, etc. It runs automatically right after worktree
creation, in the new worktree, with `PROWL_WORKTREE_PATH` / `PROWL_ROOT_PATH` set.

## Archive Script (automatic on archive)

A per-repo **Archive Script** runs **before** a worktree is archived — tear down
servers, clean artifacts, etc. If it exits non-zero, archiving stops and the
worktree stays active, with the error shown.

## Custom Commands (buttons + hotkeys)

The most flexible option: define **multiple** named actions per repository, each
with its own SF Symbol icon, shell command, execution mode, optional **close on
success**, and optional **keyboard shortcut**.

**Execution modes:**

| Mode | What it does | Supports "close on success" |
|------|--------------|-----------------------------|
| **Shell script** | runs in a new terminal tab | ✅ |
| **Terminal input** | types the command into the focused pane | ❌ |
| **Split** | runs in a new split of the focused pane (direction: right/left/down/top) | ✅ |

**Close on success** auto-closes the tab/split shortly after the command exits 0
(a brief delay lets you see the final output).

**Hotkeys:** each Custom Command can carry a `⌘`/`⇧`/`⌥`/`⌃` shortcut. Within the
focused repository, a Custom Command's hotkey takes **precedence over app
shortcuts**; conflicts (with reserved app actions or other custom commands) are
detected when you record the key, and you choose Replace / Cancel.

**Where they appear:** as buttons in the UI, in the Worktrees menu, and in the
[Command Palette](command-palette.md). Custom Commands are also stored per repo,
in `~/.prowl/repo/<repo-name>/prowl.onevcat.json`.

## Example uses

- `swift build` on `⌘B` (shell script).
- `npm run dev` as a split that stays open (split mode, no close-on-success).
- `claude -p "review the current diff and summarize risks"` (shell script) — a
  one-keystroke AI assistant.
- `git push && gh pr create --fill` on a hotkey.

## Settings recap

- Per repo (Repo Settings): `runScript`, `setupScript`, `archiveScript`, and the
  Custom Commands list. Each can use inline command text or a Script Profile
  reference.
- Global: `showRunButtonInToolbar`, `showDefaultEditorInToolbar`.

## Gotchas for agents

- The three named scripts (`runScript`/`setupScript`/`archiveScript`) are
  **one each per repo**; Custom Commands are the "many" option.
- Scripts always have `PROWL_WORKTREE_PATH` and `PROWL_ROOT_PATH` available — use
  them instead of assuming a working directory.
- "Terminal input" mode types into whatever pane is focused — be sure of the
  target (the same caution as [`prowl send`](cli.md)). A profile-backed command
  cleans up its temporary script without exiting that focused shell; New Tab
  and New Split commands exit their created shell after the profile completes.
