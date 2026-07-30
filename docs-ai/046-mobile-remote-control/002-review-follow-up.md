# 046.002 — Review Follow-up

## Context

Review of #583 identified TCP lifecycle risks in the initial bridge. Commit `155cb24f`
made client I/O concurrent and time-bounded, shut active sockets down during stop, and
suppressed `SIGPIPE`. A later audit confirmed those mechanisms and found one remaining
resource-bound issue: the concurrent client queue admitted an unlimited number of
blocking handlers.

The same audit found stale references in the original action log and docs sync metadata.

## Change

- `RemoteControlConnectionRegistry` now admits at most 16 active sockets. Excess
  connections are closed before a client worker is dispatched.
- `RemoteControlServer.stop()` now quiesces the accept queue before shutting down the
  registered clients, so an accepted socket cannot register after the shutdown sweep.
- Tests cover rejection at the connection limit, capacity reuse after close, and the
  stalled peer being closed before `stop()` returns.
- `001-action.md` now names the documentation, TCP hardening, and concurrency-cap
  commits directly.
- The agent-facing remote-control manual was rechecked and required no behavioral edits.

## Refs

- PR #583
- `155cb24f`
- `ba1de11b`

## Current state

The bridge remains loopback-only, authenticated, and read-only. Blocking client work is
bounded by both the 16-connection admission limit and the existing per-connection I/O
timeouts and deadline.
