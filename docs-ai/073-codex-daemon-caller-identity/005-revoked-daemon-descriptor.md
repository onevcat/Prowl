# 073.005 — Revoked terminal descriptors in the shared daemon

## Context

After the pane that started a shared Codex daemon closed, every caller-scoped command
from a daemon thread failed with `SOURCE_REQUIRED`. Daemon-mode transcript binding also
stopped. The failure lasted until the daemon restarted. 004 recorded the symptom (one
descriptor that returns `0 / ENOENT`) but did not find its source.

Root cause, observed on Codex 0.164.0 (2026-10-28):

- On macOS, `codex-rs/tui/src/tui/terminal_stderr.rs` saves stderr with a plain
  `libc::dup(STDERR_FILENO)` before it redirects stderr to `/dev/null`. The copy is not
  close-on-exec. Each live TUI held fd 10 as its pane's `/dev/ttysNNN` with
  `PROC_FP_CLEXEC` clear.
- The TUI starts `codex app-server daemon pid-update-loop`, and that process starts the
  daemon. Both inherit fd 10. When the starting pane's session leader exits, the kernel
  revokes that tty. `lsof` then shows `(revoked)`, and `PROC_PIDFDVNODEPATHINFO` fails
  with `ENOENT` for the rest of the daemon's life.
- `ProcessDetection.openFilePaths(pid:complete:)` marked the inventory incomplete for any
  failure, so `CodexDaemonThreadMapper` refused every lookup.

A reproduction with `pty.fork` and an inherited `ttyname(0)` descriptor gave the same
result. An in-process `openpty` and `revoke(2)` also give the same result.

## Why `ENOENT` alone is not proof

In XNU, `pid_vnodeinfopath` returns `ENOENT` from `vnode_getwithvid` for a dead vnode
(revoked, or reclaimed by a forced unmount). It also passes up errors from
`fill_vnodeinfo`: `mac_vnode_check_fsgetpath` and `vn_stat`. A file system can return
`ENOENT` from `getattr` for a live file. `openFilePaths` is generic and is not limited to
local APFS. So a descriptor that fails with `ENOENT` can still hide a live rollout.

If the hidden rollout holds a pane's newest submit, the old algorithm falls back to an
older indexed submit. It can then bind a pane that already switched threads to the
previous thread. This is the risk that 004 identified.

## Change

- `ProcessDetection.openFileInventory(pid:)` returns `OpenFileInventory`: the writable
  paths, the `errno` of each unreadable vnode descriptor (`EILSEQ` for a path that does not
  decode), and `isTruncated`. It does not interpret failures.
  `openFilePaths(pid:complete:)` is unchanged for other callers: any failure is incomplete.
- `CodexDaemonInventory` accepts an inventory whose failures are all `ENOENT` as
  **partial**. Any other failure, or a truncated listing, is still rejected.
- With a partial inventory, the mapper does not fall back to older submits:
  - `binding(for:rollouts:isPartial:)` binds only through the newest submit after the
    selection fence. If that submit is unindexed, the lookup is unavailable.
  - `resolve(threadID:rollouts:logs:isPartial:)` counts a pane only through its newest
    submit. Suppose a pane's newest submit is unindexed and its earlier history reaches the
    target root. That pane may still drive the thread, so the result is nil. A pane with an
    unindexed newest submit and no indexed submits on the target root does not affect the
    result.

A complete inventory keeps the earlier behavior: a pending steer keeps the earlier binding.
With a partial inventory, a pending steer has no binding until its message reaches the
rollout. A caller command issued in that interval gets `SOURCE_REQUIRED`, and it succeeds
when retried after the steer is written.

## Remaining assumption

Strict matching removes the stale-thread fallback. It does not detect one case: a pane
whose only submits go to a rollout that the inventory omits, inside the target's root
family, while no submit of that pane reaches the target root in a readable rollout. For
example, the pane submitted only to a subagent thread of the target, and that thread's
descriptor failed with `ENOENT`. Another pane can then win the target. The omitted
rollout is in the same session directory as the readable target rollout, so it is on the
same file system, and that file system must return `ENOENT` for a live open file. This is
accepted.

## Alternatives

- Ignore `ENOENT` in `openFilePaths`: rejected. It changes every caller and keeps the
  older-submit fallback.
- A caller-independent review loop (detached main role): not needed for this failure.
- Fix the leak in Codex (`F_DUPFD_CLOEXEC`): out of Prowl's scope. It would not help
  daemons that are already running.

## Verification

- Unit tests: a revoked `openpty` descriptor is reported as an `ENOENT` failure, and the
  strict wrapper still reports it as incomplete. Only `ENOENT` failures give a partial
  inventory. With a partial inventory, a switched pane does not resolve to its previous
  thread, and another pane whose newest submit is unknown makes the result ambiguous.
  The two negative tests fail when the partial-mode branches are disabled.
- Live: the running daemon (fd 10 revoked) gave failures `[ENOENT]` and a partial
  inventory. The current Codex thread resolved to its own pane.

## Refs

- Branch `fix/codex-daemon-revoked-descriptor`
- Related: issue #911 (a long-running daemon stopped mapping until restart)
