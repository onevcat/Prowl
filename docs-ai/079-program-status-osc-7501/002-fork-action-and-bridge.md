# 079.002 — Fork action and Swift copy (slice 1)

## Context

Slice 1 of [000-plan.md](000-plan.md): give Prowl the bytes before any detection policy changes. Upstream parses OSC 7501 but neither the app path nor `include/ghostty.h` exposes the reports, so the fork grows an action and Prowl copies it out.

## Change

### Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-10 | Research: parser and libghostty-vt callback present on the 078 pin, app path ignores `.program_status`, nothing upstream plans the app wiring; the C API exists only in `include/ghostty/vt/terminal.h` | MyNotes `osc-7501-prowl-agent-state-research`, upstream #14560 |
| 2026-10-10 | Producer probes with the pty harness: Claude Code 2.1.296 and Pi 1.1.0 (Pi upgraded from 1.0.2 via the Homebrew npm global) | [producer-baseline.md](producer-baseline.md) |
| 2026-10-10 | Fork commit `f35f9a84d` on `onevcat/ghostty` `rehearsal/tip-9d479dcb1-patched`: query reply, owned surface message, decode on the app thread, `GHOSTTY_ACTION_PROGRAM_STATUS`, `ghostty.h` enum tests | submodule pin in this branch |
| 2026-10-10 | Prebuilt GhosttyKit published as release `xcframework-f35f9a84d57074dd98780ae53e67a14ed0dd6213-prowl-v1`; checksums recorded | `scripts/ghosttykit-checksums.txt` |
| 2026-10-10 | Prowl: `GhosttyProgramStatusReport`, `GhosttySurfaceBridge.onProgramStatus`, diagnostics hook in the terminal owner, manual note, replay harness in `scripts/` | this branch |
| 2026-10-10 | Verification: `zig build test -Dtest-filter=ghostty.h` pass; `make build-app` 0 warnings; `GhosttyProgramStatusReportTests` 5 pass; `make check` pass; isolated Debug instance received `idle` → `working` → `done` from `claude-code` through the action; `make test`: ProwlTests 3701 pass / 0 fail / 5 skipped, plus the mirror (53), event monitor (12) and shell cancellation (3) bundles | session logs |

## Current state (as of 2026-10-10)

- The fork answers `OSC 7501 ; ?` for every surface and delivers each valid report as
  `GHOSTTY_ACTION_PROGRAM_STATUS` with a pointer to `ghostty_action_program_status_s`
  (state, kind, progress, NUL-terminated `id`/`app`/`title`/`message`). A full reset delivers
  `clear` with an empty id. Files: `ThirdParty/ghostty/src/termio/stream_handler.zig`,
  `src/apprt/surface.zig`, `src/Surface.zig`, `src/apprt/action.zig`, `include/ghostty.h`,
  `src/apprt/gtk/class/application.zig` (unimplemented arm).
- Prowl copies the report in `App/Sources/Infrastructure/Ghostty/GhosttyProgramStatusReport.swift`
  inside the synchronous action callback (`GhosttySurfaceBridge.handleCommandStatus`) and hands
  it to `WorktreeTerminalState+Surfaces.swift`, which only logs
  `[ProgramStatus] surface=… state=… kind=… id=… app=… progress=…` (no `message`). Undo-close
  clears the hook like the other bridge callbacks. Nothing drives the activity indicator or
  agent detection yet: slice 2 of the plan.
- `scripts/program_status_probe.py` replays producers outside Prowl; the observed sequences
  live in [producer-baseline.md](producer-baseline.md).
- `docs/components/terminal.md` lists OSC 7501 next to the other sequences Prowl reacts to.

## Findings

- Two build-time pitfalls worth keeping:
  - Ghostty's `build.zig` panics with "tagged releases must be in vX.Y.Z format" when any tag
    points at the checked-out commit. Fetching the fork's `xcframework-<sha>-prowl-v1` release
    tag into the submodule therefore breaks a local Zig build at that pin; delete the local tag
    (the remote release keeps it).
  - `apprt.Action` is `union(Key)` and Zig requires the union field order to match the enum
    order, so a new action goes at the end of both lists.
- Debug `ProwlLogger` prints to stdout, which is fully buffered when redirected to a file; the
  isolated-instance run only showed log lines when the app ran under `script -F`.

## Open questions

- Claude Code did not show the trust dialog in the isolated instance's fresh `/tmp` repo, so
  the "no report before trust" row in the baseline is only verified in the pty harness.
- Pi 1.1.0 sent nothing for the `/model` selector and ran a Bash tool without a confirmation
  under onevcat's settings; `blocked` from Pi is still unobserved.
- Whether to propose the action upstream (issue or PR against `ghostty-org/ghostty`) is open;
  the struct mirrors the libghostty-vt field set and enum names to keep that cheap.
