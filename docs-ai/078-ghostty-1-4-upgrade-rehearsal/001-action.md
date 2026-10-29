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
| 2026-10-10 | Second live pass with the screen unlocked: rendering, glyphs, mouse selection, Japanese IME, AX; prebuilt GhosttyKit published for the pinned commit; artifact scripts fixed for the `App/` layout | release `xcframework-6ae1993379cf06f4e6ee9784b60c0e1e75b01ae1-prowl-v1` |
| 2026-10-30 | Tagged port: upstream `v1.4.0` (`83fb95624`, 350 commits after `9d479dcb1`, Zig 0.17.0); five patches replayed on `release/v1.4.0-patched` (`c141458f0`) | `onevcat/ghostty` branch `release/v1.4.0-patched` |
| 2026-10-30 | GhosttyKit built with Zig 0.17.0 on the Xcode 27.0 SDK; fork Zig tests 4087 pass / 26 skipped / 0 fail; Prowl builds with no source change | release `xcframework-c141458f04c16b49edb582537103f8f39d6d3a57-prowl-v1` |

## Outcome & current state (as of 2026-10-10)

- Branch `ghostty-tip-rehearsal` on `onevcat/Prowl` (PR #886) pins `ThirdParty/ghostty` at
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

The first pass ran with the screen locked, which marks every surface occluded, so the
rendering, AX, mouse and IME rows were added in a second pass after the screen was unlocked
(the same instance, 02:10–02:20). Everything else was driven through the bundle's `prowl` CLI.

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
| Terminal rendering after unlock: surfaces that had been occluded all night, tab switch both ways, new tab first frame within 0.4 s, split | PASS | screenshots `v1-unlocked-current`, `va-*`, `vb-newtab-0.4s`: full scrollback and prompt drawn, no blank or stale pane |
| Glyphs: Japanese, Chinese (simplified and traditional), Korean, emoji with flag and ZWJ family, bold/italic/underline, 16-color and truecolor, box drawing, nerd icons, math | PASS | screenshot `vc-glyphs-crop` |
| Mouse drag selection + ⌘C (SelectionGesture rewrite) | PASS | `pbpaste` returned `SELECT-ME-TOKEN-ABC` after a CGEvent drag over the row |
| Japanese IME (Kotoeri romaji): preedit, conversion, commit | PASS | preedit `日本語` underlined in the pane; committed text read back through `cat -v` |
| Hidden tab streaming 150 MB while another tab is visible | PASS | app CPU 0.5–1.5 % while hidden (43 % only in the first second of the stream), 0.3–0.5 % idle |
| Accessibility value of the terminal | PASS | AX walk found an `AXTextArea` whose value holds `AX-TOKEN-7731` plus the prompt |
| Prebuilt artifact path (`make ensure-ghostty` from a clean artifact state, then `make build-app`) | PASS | downloaded and validated in 8 s from release `xcframework-6ae19933…-prowl-v1` on `onevcat/ghostty`; app built with 0 warnings |

A first attempt at the OSC 52 read scenario looked like a frozen pane. A symbolized build and
`lldb` showed the io-reader idle in the new two-stage read pipeline waiting for pty data: the
zsh `read -t 5 -d $'\a'` harness blocks forever once any input is available because the reply
ends with `ESC \`, not BEL. Sending ctrl-g released it. No Ghostty defect.

## Deviations from plan

- The plan expected to try Xcode 27 first and fall back to 26.3; no fallback was needed.
- The plan listed IME, selection and rendering checks; they had to wait for an unlocked
  screen and ran in a second pass.
- `scripts/package-ghosttykit-artifacts.sh` still used the pre-074 `Frameworks/` and
  `Resources/` roots and could not run; it and the installer now derive the directories
  from the `App/` paths.
- An argv lifetime bug in Prowl, not in the plan, turned out to be the only launch blocker. It
  is latent on `v1.3.1` too and can ship ahead of the port.

## Open questions

- Upstream PR #14444 (surface teardown deadlock, issue #14245) was still open; the heavy-output
  close scenario did not trigger the deadlock, but it is timing dependent.
- `AppFeatureCommandPaletteTests/copyPathWritesWorktreePathToPasteboard()` writes the user's
  general pasteboard during `make test`; it collided with the clipboard scenario once and it
  overwrites whatever the user had copied.
- Upstream's macOS app now sends `insertText` commits as key events (upstream `ecbeb60ca`);
  Prowl still routes them through `ghostty_surface_text` (paste semantics). Decide separately.
- Prowl auto-approves clipboard confirmations, now including Kitty clipboard protocol reads.
  Whether that needs a prompt is a product decision for the port.

## Tagged v1.4.0 port (2026-10-30)

Upstream tagged `v1.4.0` at `83fb95624` on 2026-10-27. Prowl `main` already pinned the
rehearsal (`f35f9a84d` = tip `9d479dcb1` + five patches), so the port only had to absorb the
350 commits between the rehearsal base and the tag.

### What the 350 commits change for Prowl

- **Toolchain.** `minimum_zig_version` is `0.17.0`, and the build checks the major and minor
  version. Most of the delta is the treewide Zig 0.17 migration (`dupeZ` → `dupeSentinel`,
  `@intFromEnum` → `@backingInt`, `stackFallback` → `BufferFirstAllocator`, `builtin.os` →
  `builtin.target.os`). `mise.toml` pins Zig 0.17.0. The default Xcode 27.0 SDK links; no
  `DEVELOPER_DIR` override.
- **Embedded C API.** One addition, `ghostty_surface_paste_text` (paste protection for text
  that does not come from the clipboard, used by upstream for drag and drop). No removals or
  signature changes, so Prowl builds unchanged.
- **OSC 7501.** Protocol revision 0.4 (`b7207b2ef`): the support reply now lists the accepted
  states and kinds (`?:states=idle,working,done,blocked,error:kinds=permission,question,auth`).
  Ids with disallowed bytes now discard the whole report (`dcaf6984e`); Prowl's own ids
  (`prowl-launch/<16 hex>/<status>`) are valid. A record without `app` inherits it from its
  nearest ancestor; `ProgramStatusRecordStore.app(of:)` already does that.
- **VT formatter.** Upstream now keeps background-only cells, empty gaps, hyperlinks and
  trailing blank rows in VT output (`152bdbc68`, `510b253db`, `c7cbc9bfd`). This overlaps
  with fork patch 4.
- **Security fixes in the core** that Prowl gets for free: carriage returns count as line
  endings for paste protection (`5c9a3d8a9`), shell integration escapes directory names
  (`6eb24a0f0`), tmux control-mode layout validation (`1851e121b`), cursor-page prune
  use-after-free (`65ff54c67`, `e257bb45e`).

### Patch replay

| # | Patch on `release/v1.4.0-patched` | Replay |
| --- | --- | --- |
| 1 | `5a9ce021f` child PID | Clean. |
| 2 | `e0e70c18c` VT snapshot | Clean. |
| 3 | `318ca0789` bounded text | `dupeZ` → `dupeSentinel`. |
| 4 | `f4fde9cab` snapshot keyboard modes | Conflict in `formatter.zig`; took upstream. The fork's VT blank-row check (no text and no style) and upstream's (no text and no background cell) serve the same case: rows erased while a background color is set. The fork test `display snapshot preserves background-only cells after reset` passes on upstream's check and fails when that check is removed, so the formatter hunk is dropped and the test stays. |
| 5 | `c141458f0` OSC 7501 action | The termio support reply now uses `osc.program_status.query_reply`, the same bytes as the libghostty-vt path, plus a unit test. |

### Findings outside the port

- Prowl's `GhosttySurfaceBridge.handleAction` returns `false` for `GHOSTTY_ACTION_OPEN_URL`,
  so libghostty falls back to `internal_os.open` (`/usr/bin/open`) for every cmd-clicked link,
  whatever the scheme or local target. Upstream fixed the matching advisories
  (GHSA-cw69-wm67-5pv8, GHSA-mfw9-xcr3-7gfp) in its macOS Swift layer (`UntrustedURL`), which
  Prowl does not use. The issue predates the port; it is handled separately.
- Prowl sends dropped text through `ghostty_surface_text`. Upstream moved drag and drop to
  `ghostty_surface_paste_text` (GHSA-v8cw-fg4j-jcc4). While Prowl approves every clipboard
  confirmation without a dialog, both calls behave the same (bracketed paste, no prompt), so
  the switch belongs with the clipboard confirmation decision.
- The Makefile GhosttyKit target and `scripts/ensure-ghosttykit-artifacts.sh` delete every
  `DerivedData/Prowl-*` folder when the pinned hash changes, including a folder that a running
  `make test` uses. Run artifact checks in another clone only when no build is running.

