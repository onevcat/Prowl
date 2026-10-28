# 085 — Ghostty CLI Entry in the App Bundle: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-29 | Root cause of #1002 traced to upstream `484d6ec66` (Ghostty 1.4 `+ssh`); workaround and `env` usage posted on the issue | #1002 |
| 2026-10-29 | Symlink build phase, `ProwlMain` entry, `GhosttyCLIEntry`, tests, `docs/components/terminal.md` | #1004 |
| 2026-10-29 | Review round 1: an entry linked from outside the bundle exported a wrong `GHOSTTY_RESOURCES_DIR` (`Bundle.main` is the outside folder); `GhosttyCLIEntry.appBundle(executableURL:)` now resolves the symlinks to the app | #1004 |

## Outcome & current state (as of 2026-10-29)

- `App/Project.swift`: post-build phase **Link ghostty CLI entry** runs
  `ln -sfh "$EXECUTABLE_NAME" "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/ghostty"` and
  declares the link as its output (user script sandboxing is on).
- `App/Sources/App/ProwlApp.swift`: `@main enum ProwlMain` checks the program name and
  then calls `ProwlApp.main()`. `ProwlApp` is no longer `@main`.
- `App/Sources/Infrastructure/Ghostty/GhosttyCLIEntry.swift`: `GhosttyCLIEntry`
  (program-name rule, `appBundle(executableURL:)`, `run()`), and
  `GhosttyBundledResources.export(from:)`, which both the app launch and the CLI entry use
  to set `GHOSTTY_RESOURCES_DIR`.
- `App/Tests/GhosttyCLIEntryTests.swift`: the name rule, the bundle lookup, the symlink in
  the test host bundle, and runs of the real entry (`+version`, no action, unknown action,
  `+list-themes` through a link from outside the bundle) with a clean child environment.
- `docs/components/terminal.md`: the `env` key and a "Ghostty CLI and SSH integration"
  section.

Verification that was run:

| Check | Result |
| --- | --- |
| `GhosttyCLIEntryTests` before the build phase | 4 of 6 failed (no symlink) |
| `GhosttyCLIEntryTests` after the build phase | 6 of 6 passed (8 of 8 after review round 1) |
| `make check`, `make build-app` | passed |
| `codesign -vvv --deep --strict` on the Debug app | valid; `CodeResources` seals `MacOS/ghostty` as `symlink => ProwlApp` |
| Release `xcodebuild archive` (ad-hoc identity) | symlink in the archived app, universal binary, `--deep --strict` valid, valid after a `ditto` zip round trip |
| `ghostty +version` start time (Debug) | about 26 ms |
| E2E, isolated Debug instance, zsh, `ssh-env,ssh-terminfo`, host `mini` without Ghostty terminfo | `Setting up xterm-ghostty terminfo on onevcat@mini...`, then login; remote `TERM=xterm-ghostty`, `~/.terminfo/78/xterm-ghostty` installed; `ghostty +ssh-cache` lists `onevcat@mini`; the cache file is under the `XDG_STATE_HOME` set through the `env` key; the `ghostty` process ends with `ssh` |
| E2E, 082 remote detection through the wrapper | `LC_PROWL_PANE` still reaches the remote shell; a remote `codex` reports `remote.correlation = correlated`, `confidence = probed` |

## Deviations from plan

- `GhosttyBundledResources.export(from:)` was added so that the app and the CLI entry set
  `GHOSTTY_RESOURCES_DIR` the same way; the plan did not name it. The CLI entry passes the
  bundle that `GhosttyCLIEntry.appBundle(executableURL:)` finds through the symlinks, so a
  link from outside the bundle (for example `~/.local/bin/ghostty`) also works.

## Open questions

- Notarization of the symlink was not run in this change. Evidence: a notarized Developer
  ID app (1Password) ships a relative symlink in `Contents/MacOS` and passes
  `codesign --deep --strict`. The first release with this change confirms it.
- The ad-hoc Release archive cannot start (dyld rejects Sparkle: different Team IDs under
  the hardened runtime). `ProwlApp` itself fails the same way there, so this is a property
  of the ad-hoc archive, not of the entry.
- Only zsh was run end to end. bash, fish, elvish, and nushell use the same
  `$GHOSTTY_BIN_DIR/ghostty +ssh` call.
- `+ssh` forwards `COLORTERM`, `TERM_PROGRAM`, and `TERM_PROGRAM_VERSION`; the remote
  `sshd` drops them unless its `AcceptEnv` lists them (macOS accepts only `LANG LC_*`).
- `GhosttyRuntime+ThemeFallback.swift` still looks for an external `ghostty` for
  `+show-config` and `+list-themes`. It could use the bundled entry, but `+show-config`
  reads Ghostty's default config files, not a dedicated Prowl file (075).
