# 078 — Ghostty 1.4 Upgrade Rehearsal: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-10 | Inventory: fork = `v1.3.1` + 9 commits; upstream `main` at `9d479dcb1` (2895 commits ahead, Zig 0.16.0, `1.3.2-dev`); milestone 1.4.0 at 749 closed / 29 open | this entry |
| 2026-10-10 | Fork patch replay on tip: 4 patches kept, 2 backports dropped (upstream has `4803d58bb`, `a177ba90a`), 2 process-group patches dropped (upstream `ghostty_surface_foreground_pid`) | `onevcat/ghostty` branch `rehearsal/tip-9d479dcb1-patched` (`6ae199337`) |
| 2026-10-10 | Zig 0.16 adaptations folded into the kept patches: `Io.Mutex.lockUncancelable(io)` / `unlock(io)`, `global.alloc()`, tests use `Terminal.init(io, alloc, opts)` and the infallible `stream.nextSlice` | same branch |
| 2026-10-10 | GhosttyKit built with Zig 0.16.0 on the default Xcode 27.0 SDK (no Xcode 26.3); fork Zig tests `-Dtest-filter` snapshot / bounded text / display: 221 pass | `deb068ed` (submodule pin + `mise.toml`) |
| 2026-10-10 | Prowl adapted to the tip C API: config-based key binding lookup, Kitty-protocol clipboard callbacks, length-decoded clipboard writes, upstream foreground pid; xcframework sync with `--delete`; installer accepts `ghostty-internal.a` | `ff365b8e` |
| 2026-10-10 | Launch crash on tip fixed: libghostty keeps the argv pointer; Prowl passed a Swift array buffer that was freed after `ghostty_init` | `78994f1a` |
| 2026-10-10 | `make check`, `make build-app` (0 warnings), `make test` 3695 pass / 0 fail; live scenarios in an isolated Debug instance (below) | logs in the session scratchpad |

## Outcome & current state (as of 2026-10-10)

- Branch `ghostty-tip-rehearsal` on `onevcat/Prowl` (pushed, no PR) pins `ThirdParty/ghostty` at
  `6ae199337` = upstream `9d479dcb1` + four fork patches. The branch is a rehearsal, not a
  release candidate: it tracks a nightly, not a tag.
- Fork branch `rehearsal/tip-9d479dcb1-patched` on `onevcat/ghostty` holds the replayed patch
  set. When `v1.4.0` is tagged, replay these four commits onto the tag (the Zig 0.16 fixes are
  already inside them) and drop this branch.
- Prowl-side changes that the real 1.4 port needs, all in `App/Sources/Infrastructure/Ghostty/`
  plus `App/Sources/App/ProwlApp.swift`:
  - `GhosttyRuntime+AppKey.swift`: `ghostty_config_key_is_binding(config, key)`.
  - `GhosttyRuntime.swift`, `GhosttyRuntime+Callbacks.swift`, `GhosttyRuntimeSupport.swift`:
    `read_clipboard_cb` receives a MIME list and a listing flag and returns
    `ghostty_clipboard_read_result_e`; `confirm_read_clipboard_cb` receives
    `ghostty_clipboard_confirm_s`; completion goes through `ghostty_clipboard_complete_s` or
    `ghostty_surface_deny_clipboard_request`. `GhosttyClipboardPayload` owns the copied data;
    `NSPasteboard.ghosttyData(forMime:)` / `ghosttyAvailableMimes()` serve it. Prowl still
    approves every confirmation without a dialog. Tests: `App/Tests/GhosttyClipboardPayloadTests.swift`.
  - `GhosttySurfaceBridge.swift`: `foregroundProcessGroupID()` reads `ghostty_surface_foreground_pid`.
  - `ProwlApp.swift`: argv for `ghostty_init` is heap-allocated for the process lifetime.
  - `Makefile`: `rsync -a --delete` for the xcframework (upstream dropped the iOS slices and
    renamed the archive to `ghostty-internal.a`); `scripts/ensure-ghosttykit-artifacts.sh`
    runs `ranlib` on whatever `*.a` the slice holds.
  - `App/Tests/RemoteMirror/MirrorVTExportSpikeTests.swift`: test runtime config follows the new
    callback shape.
- Build facts: the Xcode 26.3 requirement in
  [007 ghostty-fork-sync.md](../007-ghostty-embedding-integration/ghostty-fork-sync.md) lapses
  with Zig 0.16 (the `arm64e` `libSystem.tbd` problem is fixed on that line). Full
  `make -B build-ghostty-xcframework` took about 2 minutes on an M2-class machine.

### Live verification (isolated Debug instance, `CFFIXED_USER_HOME`, dedicated socket)

The screen was locked for the whole run, so every scenario that needs rendering or AX is
inconclusive; everything else was driven through the bundle's `prowl` CLI.

| Scenario | Outcome | Evidence |
| --- | --- | --- |
| Launch with the first adapted build | FAIL → fixed | `ProwlApp-2026-10-10-011557.ips`: SIGSEGV in `strlen` under `ghostty_config_load_cli_args`; dangling argv (see `78994f1a`) |
| Launch after the fix, open repo, create tab | PASS | `prowl list` shows the pane, cwd correct |
| Shell basics, `send --capture`, CJK and emoji round trip through `read` | PASS | `REHEARSAL:/tmp/prowl-rehearsal-repo:prowl`, `日本語 中文 émoji 🐱 ✓` |
| Legacy key encoding (`cat -v`): ctrl-a, F1, up, shift-tab, home, escape | PASS | `^A^[OP^[[A^[[Z^[[H^[` |
| Paste with ⌘V through the new read callback | PASS | pasted text arrived in `cat -v` |
| OSC 52 write to the system pasteboard | PASS | `pbpaste` returned the written text (length-decoded) |
| OSC 52 read with `clipboard-read = ask` (auto-confirm path) | PASS | reply `ESC]52;c;<base64>ESC\` received by the shell |
| Close a pane three times while it streams 400 MB of `yes` output (upstream #14245 risk) | PASS | each close 209–290 ms, app responsive, no leaked `yes`/`zsh`, RSS 519 → 423 MB |
| Split pane, run a command in it | PASS (functional) | output captured; rendering not verifiable |
| Undo close (⌘Z within `undo-timeout`) | PASS | same tab and pane UUID restored, scrollback intact, shell alive |
| 60 000-line scrollback (compressed pages), `read --last` | PASS | tail correct; RSS 479 MB after the fill |
| Agent detection with `claude` (foreground process group through upstream `ghostty_surface_foreground_pid`) | PASS | `agents --json`: `claude` blocked on the trust prompt, then `done`; `pane.agent = "claude"` |
| Idle CPU after the scenarios | PASS | `top`: 0.0 % |
| Terminal rendering (first frame, hidden-tab GPU release, display-link parking, fonts) | INCONCLUSIVE | locked screen marks every surface occluded; tip shows only the cursor box, the v1.3.1 control shows one initial frame, both then stop drawing |
| Accessibility snapshot of the terminal (`ghostty_surface_read_snapshot`) | SKIPPED | AX degrades under the lock screen; the export is covered by the fork Zig tests and `MirrorTerminalIntegrationTests` |
| Mouse selection, IME composition | SKIPPED | need an unlocked screen and a switched input source |

A first attempt at the OSC 52 read scenario looked like a frozen pane. A symbolized build and
`lldb` showed the io-reader idle in the new two-stage read pipeline waiting for pty data: the
zsh `read -t 5 -d $'\a'` harness blocks forever once any input is available because the reply
ends with `ESC \`, not BEL. Sending ctrl-g released it. No Ghostty defect.

## Deviations from plan

- The plan expected to try Xcode 27 first and fall back to 26.3; no fallback was needed.
- The plan listed IME, selection and rendering checks; the locked screen made them impossible.
  They stay on the list for the tagged port.
- An argv lifetime bug in Prowl, not in the plan, turned out to be the only launch blocker. It
  is latent on `v1.3.1` too and can ship ahead of the port.

## Open questions

- Rendering on tip has not been seen with an unlocked screen. Launch the branch's Debug build
  and look at a tab, a split, and a tab switch before the real port.
- Upstream PR #14444 (surface teardown deadlock, issue #14245) was still open; the heavy-output
  close scenario did not trigger the deadlock, but it is timing dependent.
- `AppFeatureCommandPaletteTests/copyPathWritesWorktreePathToPasteboard()` writes the user's
  general pasteboard during `make test`; it collided with the clipboard scenario once and it
  overwrites whatever the user had copied.
- Upstream's macOS app now sends `insertText` commits as key events (upstream `ecbeb60ca`);
  Prowl still routes them through `ghostty_surface_text` (paste semantics). Decide separately.
- Prowl auto-approves clipboard confirmations, now including Kitty clipboard protocol reads.
  Whether that needs a prompt is a product decision for the port.
