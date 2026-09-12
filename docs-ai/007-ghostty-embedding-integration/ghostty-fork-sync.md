# Ghostty Fork Sync

> Living document of entry 007. Migrated from `doc-onevcat/fork-sync-ghostty.md` on 2026-07-12; update in place.

Prowl embeds GhosttyKit from `ThirdParty/ghostty`. The submodule points to the `onevcat/ghostty` fork so Prowl can carry small embedded API patches that are not yet upstream.

## Branch Model

- Upstream remote: `https://github.com/ghostty-org/ghostty`
- Fork remote: `git@github.com:onevcat/ghostty.git`
- Per-version patched branches: `release/v<UPSTREAM_TAG>-patched`
- Current patched branch: `release/v1.3.1-patched`
- Current pinned tip: `5afdc9cf7315ef78533f245b97ef142dc50da67a`, published on
  `fix/prowl-display-snapshot-state` ahead of that branch.

Each patched branch starts at the matching upstream tag and only adds onevcat patches. Do not rewrite an existing patched branch after publishing it.

## Current Patches

Listed in topological order through the current pinned tip. When upgrading to a
new upstream tag, carry all patches, including the follow-up after the release branch.

1. `76dce319f55db097b2b7ae3cad2f6267475936f0` — `embedded: expose surface child PID`
   - Adds `ghostty_surface_pid(ghostty_surface_t)` to the embedded C API.
   - Returns the local surface child process PID, or `0` when unavailable or exited.
2. `a284127166ce76d872320d7dfa2a5c57268be9de` — `embedded: expose surface foreground process group`
   - Adds `ghostty_surface_foreground_process_group(ghostty_surface_t)` to the
     embedded C API for callers that need the pty's foreground job, not just the
     shell PID.
3. `fe714860c12da41442b63135d09ba80e293b66ad` — `surface: use libc tcgetpgrp for foreground group`
   - Switches the foreground-group lookup from `proc_bsdinfo.e_tpgid` to
     `tcgetpgrp` on the pty fd, which is more reliable when the shell PID
     itself is not the controlling process.
4. `48365577c1ae8e422c0dd90489921f07b9f79171` — `Backport Ghostty text free ABI fix`
   - Backports upstream `ghostty-org/ghostty#12025` before an upstream tag that includes it exists.
   - Keeps the public `ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*)`
     API shape and fixes the Zig export to accept the unused surface parameter.
   - Drop this patch when upgrading to an upstream tag that contains `4803d58`.
5. `a0671ce9bf8a8e5ac8079021385adf2047462cc6` — `Backport Ghostty lazy display link creation`
   - Backports upstream `ghostty-org/ghostty#13639` (`a177ba90af`, merged 2026-08-05) before an
     upstream tag that includes it exists.
   - Makes CoreVideo display link creation lazy and non-fatal in `src/renderer/generic.zig`
     (`syncDisplayLink`), so `ghostty_surface_new` succeeds with zero active displays (display
     asleep, locked session) and falls back to change-driven rendering until a display-id update
     recreates the link. `pkg/macos/video/display_link.zig` reports `CreationFailed` instead of
     `OutOfMemory`. Background: `docs-ai/063-agent-workflows/009-display-sleep-surface-spike.md`.
   - Drop this patch when upgrading to an upstream tag that contains `a177ba90af`.
6. `a00717e450f93d691037af00731e205b6501799e` — `Merge pull request #2 from Awhisper/feat/mobile-mirror-bridge`
   - Includes `02b3c6704` (active-screen VT snapshot) and `df5b32481` (bounded terminal text capture), contributed by Awhisper.
   - Adds `ghostty_surface_read_snapshot` and `ghostty_surface_read_text_bounded` for remote mirror display and bounded history.
   - Both exports are read-only and use `ghostty_surface_free_text` to release returned buffers.
7. `5afdc9cf7315ef78533f245b97ef142dc50da67a` — preserve mirror keyboard and styled blank-row state
   - Exports modifyOtherKeys and Kitty keyboard state in active-screen VT snapshots so replica input uses the Host's negotiated encoding.
   - Preserves background-only styled cells in VT output; plain-text and HTML trimming remain unchanged.
   - Keep this patch until the upstream snapshot/formatter paths preserve the same state. Recheck both actual key bytes and effective cell colors when dropping it.
   - This is the commit the submodule currently points at. Matching artifacts use release tag `xcframework-5afdc9cf7315ef78533f245b97ef142dc50da67a-prowl-v1`.

## Upgrade To A New Ghostty Tag

```bash
cd ThirdParty/ghostty

git fetch upstream --tags
git fetch onevcat

PREV=v1.3.1
NEXT=v1.3.2
PATCH_TIP=5afdc9cf7315ef78533f245b97ef142dc50da67a

git checkout -b "release/${NEXT}-patched" "${NEXT}"
git cherry-pick $(git rev-list --reverse --no-merges "${PREV}..${PATCH_TIP}")
git push -u onevcat "release/${NEXT}-patched"

cd ../..
git -C ThirdParty/ghostty checkout "release/${NEXT}-patched"
git add ThirdParty/ghostty
git commit -m "ghostty: bump submodule to ${NEXT}-patched"
make sync-ghostty
make build-app
```

## Prebuilt Artifact Publishing

Prowl's default `make ensure-ghostty` path downloads pinned prebuilt artifacts
from `onevcat/ghostty` before falling back to a local source build.

Release tag format:

```text
xcframework-<ghostty_commit_sha>-prowl-v1
```

Assets:

```text
GhosttyKit.xcframework.tar.gz
GhosttyKit-resources.tar.gz
```

After a local `make sync-ghostty`, package the current artifacts with:

```bash
scripts/package-ghosttykit-artifacts.sh
```

Upload both generated assets to the matching `onevcat/ghostty` release, then add
the emitted manifest line to `scripts/ghosttykit-checksums.txt` in Prowl. The
manifest is reviewed source of truth for downloaded artifact integrity.

Verify the prebuilt path from a clean artifact state:

```bash
rm -rf Frameworks/GhosttyKit.xcframework Resources/ghostty Resources/terminfo .ghostty_hash .ghostty_build_stamp
make ensure-ghostty
make build-app
```

## Force Push Policy

Do not force-push `release/v*-patched` branches. If a cherry-pick needs repair, use a temporary fix branch, validate it, then fast-forward the patched branch.

## Build Note

Build GhosttyKit with Xcode 26.3:

```bash
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer make sync-ghostty
```

Xcode 26.3 is a hard requirement for the Zig side, not a preference: from Xcode 26.4 on, the
macOS SDK's `libSystem.tbd` lists `arm64e-macos` instead of `arm64-macos`, and zig 0.15.2's
Mach-O linker cannot match its `aarch64-macos` target to it, so `zig build` fails while linking
its own build runner with a wall of undefined libc symbols (`_waitpid`, `_sigaction`, …;
ziglang/zig#31658, fixed on the 0.16 line but never released for 0.15). Xcode 26.3 ships SDK
26.2, the last one with the old target list. Revisit when the fork moves to a Ghostty release
that requires zig 0.16. A freshly installed Xcode 26.x may also lack the Metal toolchain that
`Ghostty.metallib` needs; `xcodebuild -downloadComponent MetalToolchain` fixes
`cannot execute tool 'metal'`.

Build Prowl itself with the current Xcode (26.6 at the time of writing); no `DEVELOPER_DIR` is
needed for `make build-app`.
