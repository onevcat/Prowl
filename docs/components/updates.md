# Updates

> Prowl keeps itself current via Sparkle. Auto-check and manual checks.

**Keywords:** updates, sparkle, auto-update, check for updates, version, ⌘⇧U

**Related:** [settings](settings.md)

## What it is

Prowl uses the **Sparkle** framework for auto-updates. Releases are notarized.

- **Check now:** `⌘⇧U` (`check_for_updates`), or Command Palette → "Check for
  Updates", or Settings → Updates → "Check for Updates Now".
- **Background checks:** if `updatesAutomaticallyCheckForUpdates` is on, Prowl
  checks periodically (roughly hourly). When a background check finds an update, a
  badge appears immediately after the notification bell in the same toolbar control;
  clicking it opens the standard Sparkle dialog.
- **On quit with a downloaded update:** Prowl offers to install or defer.
- **Install confirmation:** installing and relaunching always requires an
  explicit confirmation. When an update is ready (or a user-initiated check finds
  one already at the installing stage), Prowl shows an "Install Update and
  Relaunch?" prompt. Choosing **Install and Relaunch** quits and relaunches to
  finish; choosing **Later** cancels the current install attempt **without**
  permanently skipping the version, so the same update is offered again on the
  next check. A "Check for Updates" action will therefore never install and
  relaunch on its own.

## Settings

- `updatesAutomaticallyCheckForUpdates` — background checks (default on).
- `updatesAutomaticallyDownloadUpdates` — present in settings but **not currently
  wired** to Sparkle or exposed in the UI; the background-download preference is
  chosen via Sparkle's own permission dialog.

## Install via Homebrew

Prowl is also distributed as a cask: `brew install --cask onevcat/tap/prowl`. The
in-app Sparkle updater and Homebrew are separate channels.

## Gotchas for agents

- This updates **the Prowl app itself**, not your projects or agents.
- A bell badge that isn't a notification may be an **available update** — check
  Settings → Updates.
