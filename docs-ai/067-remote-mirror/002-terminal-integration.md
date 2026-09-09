# 067.002 — Terminal snapshot baselines and byte-preserving input

## Context
Real Ghostty surfaces exposed defects hidden by the injected terminal source in
protocol tests. The fixture uses production Host/Client objects in one App test
process, loopback TLS, and actual relay subprocesses attached to replica PTYs.
It compares the Host and replica grid dimensions and complete exported VT state.

## Change
- `GhosttySurfaceView.updateSurfaceSize()` preserves padding and fractional-cell
  pixel space when setting a mirror grid. Passing only cell dimensions made the
  replica one row/column smaller. `MirrorReplica` uses the resulting full pixel size.
- `GhosttyMirrorPaneSource.write()` passes length-delimited raw bytes to the text
  binding action and escapes only backslashes. Ghostty interprets `\xNN` as a
  Unicode scalar, so escaping every byte corrupted Chinese. The byte path also
  preserves NUL, invalid UTF-8, and UTF-8 split across calls.
- `MirrorRelay` applies RIS before each complete snapshot. The formatter emits
  modes only when they differ from defaults; clearing cells alone left bracketed
  paste enabled after the Host disabled it. A default baseline prevents stale modes.
  This resets only the replica terminal, not the Host process.
- `MirrorTerminalIntegrationTests` covers colored Chinese, cursor placement,
  overwritten output, remote and local input, resize authority, raw control bytes,
  arrow/Ctrl-C encoding, bracketed paste, stable history paging, exclusive
  subscriptions, reconnect, and Host process survival after disconnect/server stop.

## Current state
The complete real-terminal scenario passed in 3.382 seconds. It checks serialized
display state, not GPU pixels or visual flicker. History is independently paged text.
No Ghostty repository change was needed for these adapter fixes.
The final Debug build succeeded. App-hosted regression testing passed all 38 tests
across `MirrorProtocolTests`, `MirrorHostTests`, `MirrorTerminalIntegrationTests`,
and `GhosttySurfaceViewTests`. No mirror relay subprocess remained after testing.

Native UI preflight returned `SKIPPED: agent_ctrl_not_installed`. The repository's
`.claude/skills/prowl-ui/SKILL.md` requires stopping that UI scenario rather than
installing tools or switching to another UI automation method during self-verification.
Two independent App instances, button flows, physical IME, font scaling, and LAN
behavior remain unverified. Test windows are not shown; temporary terminal processes,
listeners, settings, and files are disposed without touching the installed App.
