# 085 — Ghostty CLI Entry in the App Bundle: Plan

| | |
| --- | --- |
| **Status** | Planned |
| **Anchor date** | 2026-10-29 |
| **Primary PRs** | (fill in) |
| **Related** | [078-ghostty-1-4-upgrade-rehearsal](../078-ghostty-1-4-upgrade-rehearsal/000-plan.md), [075-terminal-config-source](../075-terminal-config-source/000-plan.md), [082-ssh-remote-agents](../082-ssh-remote-agents/000-plan.md), `docs/components/terminal.md`, issue #1002 |

## Background

Issue #1002: with `shell-integration-features = ssh-env,ssh-terminfo`, every `ssh` in a
Prowl pane fails:

```
fish: Unknown command: /Applications/Prowl.app/Contents/MacOS/ghostty
```

How the setting works:

1. When libghostty starts a shell, it sets `GHOSTTY_BIN_DIR` to the folder of the running
   executable (`ThirdParty/ghostty/src/termio/Exec.zig`, the `ghostty_path` block). With the
   `path` feature (on by default), it also appends that folder to `PATH`. In Prowl, the
   folder is `Prowl.app/Contents/MacOS`, which holds only `ProwlApp`.
2. If `GHOSTTY_SHELL_FEATURES` contains `ssh-*`, the shell integration of every shell
   (bash, zsh, fish, elvish, nushell under `ThirdParty/ghostty/src/shell-integration/`)
   defines an `ssh` function: `"$GHOSTTY_BIN_DIR/ghostty" +ssh <flags> -- "$@"`.
3. `ghostty +ssh` (`ThirdParty/ghostty/src/cli/ssh.zig`) installs the embedded terminfo on
   the remote host once per destination (cached in `$XDG_STATE_HOME/ghostty/ssh_cache`),
   then spawns `ssh` with `SetEnv=TERM=…` and `SendEnv` options and waits for it to write
   the cache entry.

This is a regression from the Ghostty 1.4 update (#886). Before upstream `484d6ec66`
("cli: add an ssh-wrapping +ssh action"), the wrapper was shell code that called
`ghostty +ssh-cache` only for the cache, with `|| true`, so a missing binary was not fatal.
Now the wrapper has no fallback.

Prowl's own remote panes are not affected: `RemoteTerminalLaunch` runs `/usr/bin/ssh`
by absolute path, which skips the shell function.

## Goals

- `"$GHOSTTY_BIN_DIR/ghostty" +<action>` works in Prowl panes and uses the libghostty that
  Prowl embeds: the same version, the same embedded terminfo as `Resources/terminfo`, and
  the same `ssh_cache` file as Ghostty.app.
- Other CLI actions work too (`+version`, `+list-themes`, `+show-config`, `+ssh-cache`, …).
- `ghostty` without an action never starts a second Prowl instance.
- No change to a normal app launch, to the test host, or to the release signing steps.

### Non-goals

- A `ghostty` command that opens windows. Prowl is not a Ghostty GUI.
- Switching the theme fallback (`GhosttyRuntime+ThemeFallback.swift`, which runs an
  external `ghostty +show-config` / `+list-themes`) to the bundled entry. It is a separate
  change with its own behavior questions (see Open questions in the action log).
- A Prowl setting for environment variables. The Ghostty `env` config key already applies
  to every surface, after Ghostty's own variables; `docs/` documents it.

## Design / Approach

The macOS Ghostty app has one executable for the GUI and the CLI: `main.swift` calls
`ghostty_init(argc, argv)` and then `ghostty_cli_try_action()`, which runs a `+action` and
exits, or returns when argv has no action. Prowl links the same C API, so Prowl does the
same, selected by the name of the program:

1. **Bundle entry.** A post-build script phase in `App/Project.swift` creates the relative
   symlink `Contents/MacOS/ghostty -> ProwlApp`. Xcode signs the bundle after all build
   phases, so the seal records the symlink. Relative symlinks inside the bundle are valid
   for `codesign --deep --strict` and for notarization (1Password ships one in
   `Contents/MacOS`).
2. **Entry point.** A new `@main enum ProwlMain` replaces `@main` on `ProwlApp`. Its
   `main()` checks the basename of `argv[0]`. For `ghostty`, it runs
   `GhosttyCLIEntry.run()` and never returns. Otherwise it calls `ProwlApp.main()`. This
   check runs before Sentry, PostHog, `@Shared`, and the synthesized Ghostty argv in
   `ProwlApp.init`.
3. **`GhosttyCLIEntry`** (`App/Sources/Infrastructure/Ghostty/GhosttyCLIEntry.swift`):
   - `ghostty_init` with the real `CommandLine.argc` / `CommandLine.unsafeArgv`. On failure
     (an unknown action, or two actions), print Ghostty's hint to stderr and exit 1.
   - `ghostty_cli_try_action()`. Does not return when argv has an action.
   - No action (for example a plain `ghostty` or `ghostty -e …`): print that this entry runs
     only CLI actions, and exit 1.

The process name in `ps` is `ProwlApp` (the kernel records the real file name), and
`argv[0]` is `…/ghostty`. Pane detection reads `argv0`/`name` per process, and the `ssh`
child of `+ssh` stays an `ssh` in the same foreground job, so 082 remote detection still
sees it.

### Verification

- Unit: the program-name rule (`GhosttyCLIEntry.isGhosttyInvocation`).
- Hosted test: the test host bundle has the `ghostty` symlink; running it with `+version`
  prints the Ghostty version and exits 0; running it with no action exits 1 with the
  message and does not start the app. The child gets a clean environment so that XCTest
  injection does not follow it.
- Bundle: `codesign --verify --deep --strict` on the built app.
- E2E in an isolated Prowl Debug instance: with `ssh-env,ssh-terminfo`, `ssh <host>` to a
  real host connects, the remote `TERM` is `xterm-ghostty`, `ghostty +ssh-cache` lists the
  host; 082 remote pane detection still sees the `ssh`.

## Alternatives & decisions

| Option | Decision |
| --- | --- |
| Symlink `ghostty` to `ProwlApp` and dispatch on the program name | **Chosen.** No extra binary, exact libghostty match, same model as Ghostty.app. |
| Hard link or copy of `ProwlApp` | Rejected. `ProwlApp` is ~83 MB. Archive and update tools can turn a hard link into a copy, and a copy is a second Mach-O to sign. |
| Separate helper executable that links GhosttyKit | Rejected. A second large static link, a second signing step in `scripts/release.sh`, and no benefit over the symlink. |
| Dispatch on `argv[1]` starting with `+` | Rejected. It would change the meaning of a normal app launch; the program name is unambiguous. |
| Set `GHOSTTY_BIN_DIR` to an installed Ghostty.app | Rejected. It depends on another app and its version: Ghostty ≤ 1.3 has no `+ssh`. Documented only as a user workaround. |
| Remove `ssh-*` from the features in Prowl | Rejected. It silently drops a feature the user turned on. |

## Amendments
