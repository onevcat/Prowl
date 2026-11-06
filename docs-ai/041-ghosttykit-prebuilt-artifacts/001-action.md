# 041 — GhosttyKit Prebuilt Artifacts: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-06-14 | Downloader, validator, packager, checksum manifest, `ensure-ghostty` rewiring, CI setup action update, ghostty fork-sync runbook update; first artifact set published and pinned for Ghostty commit `48365577` | PR #450 (commit `a415d35e`) |

Everything landed in a single commit. Verification recorded in the PR: fallback exit code
`2` with no pinned artifact and with a missing release repository, validator
accept/reject fixtures, a full `sync-ghostty` → package → release → clean
`make ensure-ghostty` round trip against the published release
`xcframework-48365577c1ae8e422c0dd90489921f07b9f79171-prowl-v1`, plus `make check` and
`make build-app`.

## Outcome & current state (as of 2026-07-12)

- `scripts/ensure-ghosttykit-artifacts.sh` — downloader with the exit-code contract
  (0 = done, 2 = fall back, else hard fail). Unchanged since PR #450. Environment
  overrides exist beyond the plan: `PROWL_GHOSTTY_ARTIFACT_REPOSITORY`,
  `PROWL_GHOSTTY_ARTIFACT_FLAVOR`, `PROWL_GHOSTTY_CHECKSUMS_FILE`,
  `PROWL_GHOSTTY_ARTIFACT_VALIDATOR`, and `PROWL_GHOSTTY_NO_PREBUILT=1` (force local
  build). Downloads use `curl --retry 3` with timeouts; both the prebuilt path (script)
  and the fallback path (Makefile) clear `~/Library/Developer/Xcode/DerivedData/supacode-*`
  when the pinned SHA changed.
- `scripts/validate-ghosttykit-artifacts.py` — tar allowlist validator, roots
  `GhosttyKit.xcframework` / `ghostty` + `terminfo`.
- `scripts/package-ghosttykit-artifacts.sh` — packages from `Frameworks/` and
  `Resources/` with `COPYFILE_DISABLE=1`, self-validates, prints tag + manifest line.
  Output dir `dist/ghosttykit` (overridable via `PROWL_GHOSTTY_ARTIFACT_DIST_DIR`).
- `scripts/ghosttykit-checksums.txt` — one entry, `48365577c1ae8e422c0dd90489921f07b9f79171`,
  which still equals the current gitlink (`git rev-parse HEAD:ThirdParty/ghostty`); the
  submodule has not been bumped since, so the pinned commit is fully covered.
- `Makefile` — `ensure-ghostty` runs the downloader first and interprets exit 2 as
  "build locally via `make -B build-ghostty-xcframework`"; it is a prerequisite of
  `build-app`, `test`, and `test-app`. `sync-ghostty` remains the explicit force-rebuild.
  Release-shaped targets (`install-release`, `archive`) still depend on
  `build-ghostty-xcframework` (source build path), not `ensure-ghostty`.
- `.github/actions/setup-macos/action.yml` — computes `GHOSTTY_SHA` from the gitlink,
  caches `Frameworks/GhosttyKit.xcframework`, `Resources/ghostty`, `Resources/terminfo`
  and both marker files under key `…-ghostty-v1-$GHOSTTY_SHA`, runs `make ensure-ghostty`
  only on cache miss, then unconditionally rewrites the marker files to match the pinned
  SHA.
- Operational publishing steps (tag format, packaging, manifest update, clean-path
  verification) are maintained in the living
  [ghostty-fork-sync runbook](../007-ghostty-embedding-integration/ghostty-fork-sync.md).
  The Xcode 26.3 `DEVELOPER_DIR` pin of that time is obsolete: since Ghostty 1.4 (Zig 0.17)
  GhosttyKit builds with the default Xcode.

## Deviations from plan

- The environment-variable overrides (repository/flavor/manifest/validator paths,
  `PROWL_GHOSTTY_NO_PREBUILT`) were not in the plan; they were added for testability
  (negative download tests against a missing repository) and as an operator escape hatch.
- Otherwise the implementation checklist in the plan was completed as written.

## Open questions

- `archive` and `install-release` bypass the prebuilt path by depending on
  `build-ghostty-xcframework` directly. Because that target is stamp-file-gated, a
  release build on a machine that acquired artifacts via `ensure-ghostty` reuses them
  (the downloader writes `.ghostty_build_stamp`), which appears intentional — but it
  means release builds are only source-built when no stamp exists (with the default Xcode
  since Ghostty 1.4). Not verified whether this asymmetry is deliberate policy or just
  historical wiring.
