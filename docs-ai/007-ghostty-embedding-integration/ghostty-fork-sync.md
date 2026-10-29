# Ghostty Fork Sync

> Living document of entry 007. Migrated from `doc-onevcat/fork-sync-ghostty.md` on 2026-07-12; update in place.

Prowl embeds GhosttyKit from `ThirdParty/ghostty`. The submodule points to the `onevcat/ghostty` fork so Prowl can carry small embedded API patches that are not yet upstream.

## Branch Model

- Upstream remote: `https://github.com/ghostty-org/ghostty`
- Fork remote: `git@github.com:onevcat/ghostty.git`
- Per-version patched branches: `release/v<UPSTREAM_TAG>-patched`
- Current patched branch: `release/v1.4.0-patched`
- Current pinned tip: `c141458f04c16b49edb582537103f8f39d6d3a57` (upstream `v1.4.0` +
  5 patches)

Each patched branch starts at the matching upstream tag and only adds onevcat patches. Do not rewrite an existing patched branch after publishing it.

## Current Patches

Listed in topological order on `release/v1.4.0-patched`. When upgrading to a new upstream
tag, cherry-pick these commits, not older copies on previous branches.

1. `5a9ce021f` — `embedded: expose surface child PID`
   - Adds `ghostty_surface_pid(ghostty_surface_t)` to the embedded C API.
   - Returns the local surface child process PID, or `0` when unavailable or exited.
2. `e0e70c18c` — `Add active-screen VT snapshot bridge for embedded surfaces`
   - Adds `ghostty_surface_read_snapshot` for the remote mirror display (contributed by
     Awhisper). Read-only; release the buffer with `ghostty_surface_free_text`.
3. `318ca0789` — `Expose bounded read-only terminal text capture`
   - Adds `ghostty_surface_read_text_bounded` for bounded mirror history (contributed by
     Awhisper). Read-only; release the buffer with `ghostty_surface_free_text`.
4. `f4fde9cab` — `Preserve keyboard modes in display snapshots`
   - Exports modifyOtherKeys and Kitty keyboard state in active-screen VT snapshots so replica
     input uses the Host's negotiated encoding.
   - On `v1.3.1` this patch also changed the VT formatter to keep background-only blank rows.
     Upstream `v1.4.0` does that itself (`152bdbc68`, `c7cbc9bfd`), so only the snapshot tests
     remain. The background test fails when the upstream check is removed, so it guards the
     upstream behavior. Keep the patch until upstream snapshots carry the keyboard state.
5. `c141458f0` — `embedded: expose program status reports (OSC 7501) as an action`
   - Routes validated OSC 7501 reports from termio to the apprt as
     `GHOSTTY_ACTION_PROGRAM_STATUS` (upstream `v1.4.0` parses them, but its GUI ignores them).
   - Answers the support query with `osc.program_status.query_reply` (protocol revision 0.4:
     `?:states=…:kinds=…`), the same bytes as the libghostty-vt path.
   - This is the commit the submodule points at. Matching artifacts use release tag
     `xcframework-c141458f04c16b49edb582537103f8f39d6d3a57-prowl-v1`.

Patches dropped on the way to `v1.4.0`: the foreground process group patches (replaced by
upstream `ghostty_surface_foreground_pid`) and the text free ABI and lazy display link
backports (both upstream). [078](../078-ghostty-1-4-upgrade-rehearsal/001-action.md) records
the rehearsal on upstream tip and the tagged port.

## Upgrade To A New Ghostty Tag

```bash
cd ThirdParty/ghostty

git fetch upstream --tags
git fetch onevcat

PREV=v1.4.0
NEXT=v1.4.1
PATCH_TIP=c141458f04c16b49edb582537103f8f39d6d3a57

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
rm -rf App/Frameworks/GhosttyKit.xcframework App/Resources/ghostty App/Resources/terminfo .ghostty_hash .ghostty_build_stamp
make ensure-ghostty
make build-app
```

## Force Push Policy

Do not force-push `release/v*-patched` branches. If a cherry-pick needs repair, use a temporary fix branch, validate it, then fast-forward the patched branch.

## Build Note

Ghostty `v1.4.0` requires Zig 0.17.0 (`minimum_zig_version` in `build.zig.zon`; the build
checks the major and minor version). `mise.toml` pins it, and `make sync-ghostty` builds the
universal xcframework with the default Xcode (27.0 at the time of writing). No
`DEVELOPER_DIR` override is needed.

The Xcode 26.3 requirement of the `v1.3.1` line is gone: it came from Zig 0.15.2, whose Mach-O
linker could not match the `arm64e`-only `libSystem.tbd` in SDK 26.4 and later
(ziglang/zig#31658). Zig 0.16 and later link against those SDKs. A freshly installed Xcode may
still lack the Metal toolchain that `Ghostty.metallib` needs;
`xcodebuild -downloadComponent MetalToolchain` fixes `cannot execute tool 'metal'`.

The Makefile's GhosttyKit target runs `git submodule update` first. Stage a new submodule
pointer (`git add ThirdParty/ghostty`) before you build, or the target checks out the
previously committed commit and builds that instead.

`zig build test` on macOS also runs the upstream Ghostty.app tests through `xcodebuild`.
To run only the Zig unit tests, pass a filter: an empty `-Dtest-filter=` matches every test
and skips the app test step.

Build Prowl itself with the current Xcode (27.0 at the time of writing, verified on macOS 27.0);
no `DEVELOPER_DIR` is needed for `make build-app`.

The app target links `GameController` explicitly (`OTHER_LDFLAGS`). `libghostty.a` bundles
Dear ImGui's macOS backend (`imgui_impl_osx.o`), which references `GCController` but is never
called by Prowl. Nothing pulls that archive member in until a dependency adds `-ObjC` to the
link line: swift-navigation 2.9+ (a transitive dependency of TCA 1.26+) does exactly that for
its `UIKitNavigation` target, and `-ObjC` loads every archive member that defines an
Objective-C class. Without the explicit framework the link fails with
`Undefined symbols: _OBJC_CLASS_$_GCController`. Keep the flag when bumping TCA or Ghostty.
