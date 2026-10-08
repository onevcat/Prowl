# 073.003 — Daemon Transcript Resolution

## Context

Issue #875 reports that `agents read` loses a daemon-owned session while the user
views old terminal output. The log state provider uses the daemon mapper, but the
session resolver only checks the TUI files and transcript fingerprints.

## Change

- Pass the pane identity into both fresh and background session resolution.
- Reuse the daemon binding when a Codex TUI owns no rollout. Validate the process
  generation across the asynchronous lookup and select only the root transcript
  whose header matches the binding, within the effective `CODEX_HOME`.
- Report `process_log` / `exact`; do not extend the CLI schema or relax confidence.
- Preserve embedded-runtime resolution and the existing fallback when no verified
  binding is available. Do not cache daemon bindings across session transitions.
- Cover old/empty screens, separate panes, session changes, child/fork boundaries,
  and invalid or missing root transcripts. Check the installed runtime and a Debug
  build separately; preserve their distinct evidence.
- Validate a complete metadata line within the existing 1 MiB provider limit;
  real Codex 0.161 metadata can exceed 8 KiB because it contains instructions.
- Fence selected-transcript binding at TUI new/clear/attach reset events. Preserve
  historical submits for caller routing while waiting for a new indexed submit.
  A pending selection explicitly suppresses both the fallback cache and text
  matching, so a fork cannot return its parent transcript through copied history.
  Reject client IDs that claim more than one rollout.
- Preserve local open-file resolution when a complete TUI inventory contains an
  owned rollout, even if the same home also has a managed daemon. Otherwise a known
  selection reset suppresses fallback, including when the inventory is incomplete.
  Accepting a daemon binding requires a complete inventory with no TUI-owned rollout.
- Share a bounded parsed TUI-log cache between caller routing and session lookup.
  Check device, inode, size, modification time, and change time on every lookup;
  read and parse only changed files. Validate the snapshot across reads and bound
  reads to 64 MiB. Do not retain prompt bytes or delay selection checks with a TTL.

## Boundary

The mapper identifies a root family after an indexed submit; it is not a complete
TUI selection protocol. Codex 0.161 logs most inbound events by name only, including
startup completion. A future explicit pane-owned selection event can cover the
pre-submit and selected-child cases. Daemon `thread/read` is useful once a thread
ID is known, but `thread/loaded/list` does not supply pane ownership.
