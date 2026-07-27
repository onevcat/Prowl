# 052.003 — The Account a Pane Runs Under

| | |
| --- | --- |
| **Status** | Implemented and verified in the running app; build, full test suite, swiftlint and swift-format green |
| **Anchor date** | 2026-07-26 |
| **Plan** | [000-plan.md](000-plan.md) · [001-action.md](001-action.md) · [002-account-status-and-sign-in.md](002-account-status-and-sign-in.md) |

## Why

Settings could finally answer "which login is in which account", but nothing
answered the question asked far more often, in the place where mistakes happen:
"which account is *this pane* using?" The day this feature was first used, every
repository silently resolved to one account and the only way to notice was
`echo $CLAUDE_CONFIG_DIR` inside a pane.

## Delivered

- **`WorktreeTerminalState.agentAccountBySurface`** — the account each surface
  launched with, recorded in `createSurface` and dropped in `forgetSurface`.
- **`WorktreeTerminalState.agentAccount(forSurface:)`** — the pane's recorded
  account, falling back to today's resolution when a worktree has no pane yet.
  Deliberately not the live resolution: a running pane keeps the environment it
  started with, so reporting the current setting would name an account that pane
  is not using — the exact lie that made the original bug invisible.
- **`AgentAccountToolbarLabel`** — a capsule left of the branch title naming that
  account, shown only when one is in effect, so nothing changes for users who
  never configured an account. Clicking it opens Settings → Advanced.

## Notable details

- A toolbar renders `Label` **icon-only** unless `.labelStyle(.titleAndIcon)` is
  explicit — the first build shipped a lone person glyph with no name.
- The capsule leaves the navigation group's shared background
  (`sharedBackgroundVisibility(.hidden)`) and draws its own glass, the same
  escape `AgentsToolbarButton` documents. Sharing the group put the account
  inside the branch title's pill, reading as one control.
- **Debugging note worth remembering:** the capsule was missing for three build
  cycles and each fix targeted the layout. It was never a layout problem — the
  value was `nil`, because a *release* Prowl running alongside the debug build
  had rewritten `~/.prowl/settings.json` without the fields it does not know,
  deleting the account configuration. Any older build silently drops unknown
  settings keys. One log line of the four inputs ended the guessing immediately;
  it should have been the first move, not the fourth.
