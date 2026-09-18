# 034.004 — Registry Vnode Lifecycle

## Context

PR #810 by Simon Heimlicher adds per-entry `gitdir` monitoring so external
`git worktree move` operations reach the existing repository refresh debounce.
Directory sources alone do not observe these in-place file writes.

A vnode source follows an open file, not its path. Keeping a source merely because
its URL is unchanged leaves it attached to a deleted inode after atomic replacement
or removal and recreation of an entry before main-queue callbacks run.

## Change

The follow-up branch retains Simon Heimlicher's original #810 commit
`52f8cd8fba41af4d1f1fd34461bdac186510022e` without rewriting it. It extends target synchronization in
`supacode/Features/Repositories/BusinessLogic/WorktreeInfoMonitors.swift`:

- Compare each source's open descriptor with the current path using device and inode.
- Cancel and reopen stale sources, retaining sources that still watch the current file.
- Apply the same identity check to `worktrees/` itself. Removing the last worktree
  can remove this directory; rapid recreation must not retain the old directory source.
- Keep the directory fallback until an entry's `gitdir` exists.
- Make cancellation terminal so queued callbacks cannot recreate subscriptions.

Real-monitor tests in `supacodeTests/GitWorktreeRegistryMonitorTests.swift`
cover ordinary Git moves, same-name recreation, atomic replacement, fallback promotion,
registry directory recreation, and cancellation. OS event delivery is asynchronous;
tests wait for actual callbacks with bounded timeouts, not an injected clock that
cannot drive vnode events.

This avoids reopening all entry sources on every event, and does not add another
polling loop or change the existing two-second repository debounce.

## Verification

The same-name and atomic-replacement tests failed against the original #810 monitor.
The registry-directory test also failed before the directory source identity check.
After the fixes, the monitor and watcher-manager suites passed all 31 cases across
five repetitions (155 test runs). The tests retain the original four target-selection
cases and add six live-monitor cases.
