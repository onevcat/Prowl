# 078 — Ghostty 1.4 Upgrade Rehearsal: Plan

| | |
| --- | --- |
| **Status** | Implemented (rehearsal executed; branch not merged) |
| **Anchor date** | 2026-10-10 |
| **Primary PRs** | #886 (branch `ghostty-tip-rehearsal`; pins upstream tip, re-pin at the `v1.4.0` tag); see [001-action.md](001-action.md) |
| **Related** | [007-ghostty-embedding-integration/ghostty-fork-sync.md](../007-ghostty-embedding-integration/ghostty-fork-sync.md), [041-ghosttykit-prebuilt-artifacts](../041-ghosttykit-prebuilt-artifacts/000-plan.md), [063.009 display sleep spike](../063-agent-workflows/009-display-sleep-surface-spike.md), [069-undo-close-terminal](../069-undo-close-terminal/000-plan.md), [075-terminal-config-source](../075-terminal-config-source/000-plan.md) |

## Background

Prowl embeds GhosttyKit from the `onevcat/ghostty` fork. The pinned commit is
`5afdc9cf7` = upstream `v1.3.1` + 9 fork commits (7 patches, 2 of them backports). Upstream
is preparing 1.4.0 (milestone 12: 749 closed / 29 open items on 2026-10-10, no due date) and
`build.zig.zon` on `main` still says `1.3.2-dev`. The fork wants to ship 1.4.0 as soon as it
is tagged, so the port must be rehearsed before the tag exists.

Upstream `main` at the time of this plan: `9d479dcb1` (2026-10-09), 2895 commits after
`v1.3.1`, minimum Zig 0.16.0 (the fork builds with Zig 0.15.2 and Xcode 26.3).

## Goals

- Measure how much of the fork patch set still applies to upstream tip and which patches
  upstream has absorbed.
- Rebuild the patch set on tip in a throwaway fork branch, build GhosttyKit from it with
  Zig 0.16, and make Prowl compile against the new embedded C API.
- Run the full check and test surface, then verify the live app in an isolated Debug
  instance through `prowl` CLI, accessibility driving, and screenshots.
- Record every regression, API break, and build pitfall so the real 1.4.0 port is a
  replay of this entry instead of a discovery.

### Non-goals

- Merging the rehearsal branch, publishing prebuilt artifacts, or changing the release
  pinning policy. The fork keeps tracking upstream tags.
- Porting Prowl-side behavior changes that the upstream macOS app made (for example,
  sending `insertText` commits as key events, upstream `ecbeb60ca`). They are follow-ups.

## Findings that shape the approach

### Fork patch set versus tip

| # | Fork commit | Fate on tip |
| --- | --- | --- |
| 1 | `76dce319f` `ghostty_surface_pid` (child PID) | Keep. Upstream has no child-PID export. |
| 2 | `a28412716` `ghostty_surface_foreground_process_group` | Drop. Upstream `9a9002202` added `ghostty_surface_foreground_pid` (`tcgetpgrp` on the pty master, `u64`, 0 on failure), which is the same lookup as patch 3. |
| 3 | `fe714860c` use `tcgetpgrp` for the foreground group | Drop with 2. |
| 4 | `48365577c` backport text free ABI fix | Drop. Upstream `4803d58bb` is on `main`. |
| 5 | `a0671ce9b` backport lazy display link | Drop. Upstream `a177ba90a` is on `main`. |
| 6 | `02b3c6704` + `df5b32481` VT snapshot and bounded text exports (merge `a00717e45`) | Keep. The `TerminalFormatter` API they use (`extra.modes/keyboard/screen.cursor/kitty_keyboard`, `content.selection`) is unchanged on tip. |
| 7 | `5afdc9cf7` keyboard modes and blank styled cells in snapshots | Keep. The `hasTextAny` hunk in `formatter.zig` still exists at the same shape. |

Dry-run `cherry-pick` of the kept patches conflicts only in `include/ghostty.h` (every
declaration gained a `GHOSTTY_API` prefix) and in neighbouring `embedded.zig` lines.

### Embedded C API breaks that Prowl must adapt

| Change | Upstream commit | Prowl site |
| --- | --- | --- |
| `ghostty_app_key_is_binding(app, key)` → `ghostty_config_key_is_binding(config, key)` | `7c91cef28` | `App/Sources/Infrastructure/Ghostty/GhosttyRuntime+AppKey.swift` |
| `read_clipboard_cb` takes a MIME list and returns `ghostty_clipboard_read_result_e`; `confirm_read_clipboard_cb` takes `ghostty_clipboard_confirm_s*`; `ghostty_surface_complete_clipboard_request` takes `ghostty_clipboard_complete_s*`; new `ghostty_surface_deny_clipboard_request` | `0ce9054bf` … `25c61e852` (Kitty clipboard protocol) | `GhosttyRuntime.swift`, `GhosttyRuntime+Callbacks.swift` |
| `ghostty_input_key_s.translated` removed | `971753074` | none (Prowl never set it) |
| `ghostty_surface_foreground_process_group` (fork) → `ghostty_surface_foreground_pid` (upstream) | `9a9002202` | `GhosttySurfaceBridge.swift` |
| New actions `EXPORT_TERMINAL_IO`, `SET_WINDOW_TITLE`, `SELECTION_CHANGED`, `MOVE_TAB_TO_NEW_WINDOW`, `RESIZE_WINDOW`; `open_config` payload became an enum | various | action switches already have `default` arms |

Every config key Prowl reads (`font-size`, `undo-timeout`, `scrollbar`, `background`,
`unfocused-split-*`, `split-divider-color`, `focus-follows-mouse`, `command-palette-entry`,
`background-opacity`) keeps its type on tip.

### Risk register (what to test first)

| Area | Upstream change | Why it matters to Prowl |
| --- | --- | --- |
| Surface teardown | `ghostty_surface_free` can deadlock the app thread when the reader is blocked pushing into the app mailbox (upstream issue #14245, fix PR #14444 still open) | Prowl closes panes while agents stream output. Pre-existing, but tip has more mailbox traffic. |
| Renderer lifecycle | GPU resources released for occluded surfaces (`c4e16970a`), display link parked while idle (`6688aa072`), vsync of unfocused dirty surfaces (`97f57edcc`), shared render device (`40d5b860d`), shader release on thread exit (`140feb86a`) | Prowl drives `ghostty_surface_set_occlusion` per tab/split and keeps closed surfaces alive off-tree for undo (069). Wrong visibility means blank or frozen panes. |
| Scrollback compression | Offscreen pages are compressed (`7e02af879`, `421fe8dab`) | Fork snapshot and bounded-text exports read history through the formatter; long agent logs exercise decompression. |
| Clipboard | Kitty clipboard protocol, OSC 52 confirmation deferral, mode 5522 paste events | Prowl's callbacks are rewritten; paste, copy-on-select, OSC 52 and the confirmation path need live checks. |
| Keyboard encoding | `modifyOtherKeys` 2 encodings, F13–F25, alt prefixes as UTF-8, no fallback text on release (`bd647035e`), DECBKM | Agents (Claude Code, Codex) run with Kitty/MOK2 encodings; the mirror replays key bytes from snapshots. |
| Selection | `SelectionGesture` rewrite, click-count behaviors, middle-click action, `selection_changed` action | Prowl's mouse bridge and copy-on-select. |
| Fonts | glyph cache keys repacked, nerd-font constraint table, Apple Color Emoji exact lookup, CoreText null handling | CJK fallback (075) and emoji in agent output. |
| Process info | `getProcessInfo` moved into `termio`/`pty.zig` | Fork child-PID patch sits next to it. |
| Toolchain | Zig 0.16.0, `std.Io` migration, xcframework headers now only `ghostty.h` + module map (iOS slices removed) | `mise.toml`, the `build-ghostty-xcframework` recipe, the Xcode 26.3 requirement. |

## Design / Approach

1. **Fork branch.** In `ThirdParty/ghostty`, branch `rehearsal/tip-9d479dcb1-patched` from
   upstream `9d479dcb1`; cherry-pick patches 1, 6, 7 with `-x`; resolve the header prefix
   conflicts by hand. Push to `onevcat` as a throwaway branch (never force-pushed).
2. **Toolchain.** Bump `mise.toml` to Zig 0.16.0 on the Prowl branch. Try the default
   Xcode 27 SDK first: the `arm64e` `libSystem.tbd` problem (ziglang/zig#31658) is fixed on
   the 0.16 line, so the Xcode 26.3 requirement may lapse. Fall back to
   `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer` if linking fails.
3. **Prowl adaptation** on branch `ghostty-tip-rehearsal`: bump the submodule, port the
   three API breaks above, keep `GhosttySurfaceBridge.foregroundProcessGroupID()` on
   `ghostty_surface_foreground_pid`. Keep changes minimal and local to
   `App/Sources/Infrastructure/Ghostty/`.
4. **Static verification.** `make check`, `make test`, `make build-app`.
5. **Live verification.** Isolated Debug instance (`CFFIXED_USER_HOME`, dedicated
   `PROWL_CLI_SOCKET`) driven through `prowl` CLI and accessibility, with screenshots:
   tab/split create and close under heavy output, hidden-tab switching, undo close, IME
   composition, clipboard read/write/confirm, long scrollback, mirror snapshot read, agent
   status detection, CPU at idle.
6. **Record** everything in `001-action.md` and refresh the fork sync runbook with the
   Zig 0.16 outcome.

## Alternatives & decisions

- **Wait for the `v1.4.0` tag, then port.** Rejected: the point is an early warning so
  the tagged port is mechanical.
- **Carry patches 2 and 3 unchanged.** Rejected: upstream's `ghostty_surface_foreground_pid`
  performs the same `tcgetpgrp` lookup; two fewer patches to replay on every tag.
- **Keep `ghostty_app_key_is_binding` through a fork shim.** Rejected: the upstream
  replacement is a one-line call-site change and the runtime already owns the config.
- **Move the fork to track upstream `main`.** Rejected: unchanged release pinning policy;
  the rehearsal branch is explicitly disposable.

## Amendments

- Updated 2026-10-10: rehearsal executed; results, deviations and open questions in [001-action.md](001-action.md).
