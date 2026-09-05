# 066.003 — Prowl Shortcut Loop

## Context

PR #758 initially gave Agent Island a default global `⌘⇧P` toggle plus transient
`⌘⌥1`…`⌘⌥9` global shortcuts for strong reminders. Carbon registration necessarily owns a
chord ahead of the frontmost application. The default toggle therefore displaced established
commands such as editor command palettes and Cocoa Page Setup, while attention shortcuts made
other applications fail intermittently as agent state changed.

The numbered shortcuts also created the wrong memory model. A slot number was temporary, changed
meaning as reminders arrived, and disappeared when its entry stopped needing attention. Agent
Island instead needs one deliberate entry gesture followed by stable local controls.

## Change

- Keep `toggle_agent_island` remappable but give it no default binding. A user-assigned binding is
  the sole global Prowl shortcut; reset returns it to Unassigned.
- Register the Carbon shortcut only while Agent Island has visible entries and Prowl is not the
  active application. While Prowl is active, use the normal menu key equivalent so the existing
  app conflict and Ghostty precedence model remains authoritative.
- Remove global attention-slot registration and its `⌘⌥1`…`⌘⌥9` card labels. Direct number
  activation remains local to the expanded roster and accepts a digit regardless of held
  modifier flags, so users can keep the global shortcut modifiers held while choosing a row.
- When the roster opens, select the highest-priority strong reminder first: Blocked before
  unviewed Done, newest first within each state. Without a strong reminder, retain the focused
  surface anchor and then fall back to the first entry.
- Make `Return` the primary activation gesture, with Space retained as an alias. The resulting
  handling loop is: invoke the Prowl shortcut, press Return, handle the agent, then repeat.
- Restore the previously key Prowl window when an in-app roster collapses. Do not call
  `resignKey()` directly; when the roster was opened over another application, leave that
  application's focus undisturbed.
- Keep the island surface free of delayed hover tooltips. Visible labels, accessibility labels,
  and the expanded roster's persistent keyboard legend carry discovery without obscuring the
  compact surface.
- Add a link to the Agent Island settings footer that opens Shortcuts with
  `Toggle Agent Island` already filtered and highlighted instead of suggesting a default binding.
- Reject newly recorded app shortcuts that collide with an active Custom Command. Mark legacy or
  externally introduced collisions as Unavailable in Shortcuts while retaining Custom Command
  precedence. Compare canonical triggers so the recorder's physical `digit_N` tokens conflict
  with the equivalent logical `N` tokens stored by Custom Commands and app defaults.
- Treat Carbon registration as a fallible runtime operation. Preserve the failed binding in
  transient app state and expose it in both the shortcut row and Agent Island settings footer;
  clear it after a binding change, successful retry, unassignment, or disabling Agent Island.
- Tear down registered hot keys and the Carbon event handler from `deinit` as a final safeguard in
  addition to the controller's explicit lifecycle cleanup.
- Isolate the floating island's opacity animation from its content transaction so opening the
  roster immediately after a silent-opacity transition cannot animate the footer through the
  compact bar.

The command ID remains stable, and existing explicit user overrides continue to resolve. This
follow-up does not add the planned Active Agents settings destination or another shortcut
recorder surface.

## Refs

- PR: #758

## Current state

Implemented on 2026-09-04. `toggle_agent_island` now has a nil app default while retaining its
stable command ID and resolver override path. The Carbon registrar owns only that command and is
refreshed across binding, entry-presence, keyboard-layout, and application-activation changes.
Attention cells no longer expose transient number labels; expanded-roster digits are local and
modifier-tolerant. Collapse restores the prior visible Prowl key window when applicable.
Island-owned controls and rows no longer attach hover tooltips; accessibility labels remain.
The Agent Island settings footer links directly to the unassigned shortcut's filtered,
highlighted recorder row.
Opacity still fades, while roster geometry now updates without inheriting that animation.
Active Custom Command collisions can no longer fail silently: new assignments are rejected and
pre-existing collisions are marked Unavailable, including physical/logical digit aliases. Carbon
registration failures are likewise visible
in Shortcuts and the Agent Island settings footer until the binding is changed or registers
successfully.

Verification: `make check`, the focused Agent Island / Active Agents / shortcut / Custom Command
suites, and `make build-app` pass locally. The latest CI `test` workflow is green across the app,
CLI, and script suites.
