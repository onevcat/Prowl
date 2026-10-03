# 074 — Project Restructure, Prowl Naming, and Tuist-Generated Projects: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-02 | Research and a Tuist spike in a scratch copy (Tuist 4.208.0, Xcode 27.0): settings parity, build, 41 tests, iOS client in the same workspace | [000-plan.md](000-plan.md) |
| 2026-10-03 | Decisions agreed; plan written | [000-plan.md](000-plan.md) |
| 2026-10-03 | S1: Tuist generates the macOS and iOS projects; the `.xcodeproj` folders leave Git; version in an xcconfig file | [002-s1-generated-projects.md](002-s1-generated-projects.md), #848 |
| 2026-10-03 | S2: folders move to `App`, `CLI`, `Mirror`, `Shared`; module, targets, and types use the Prowl name; three SwiftPM packages; legacy-name check | [003-s2-names-and-layout.md](003-s2-names-and-layout.md), #849 |

## Outcome & current state (as of 2026-10-03)

- Generation: `Tuist.swift`, `Workspace.swift`, `App/Project.swift`, `Mirror/iOS/Project.swift`.
  `make generate` creates `Prowl.xcworkspace`; every build target of the Makefile does this when
  the manifests, the xcconfig files, `.package.resolved`, or `mise.toml` changed. Tuist is pinned
  in `mise.toml`.
- Build settings: `App/Config/*.xcconfig` and `Mirror/iOS/Config/*.xcconfig`. The version is in
  `App/Config/Version.xcconfig` (written by `make bump-version`).
- Layout: `App/` (`Sources`, `Tests`, `Resources`, `Config`), `CLI/`, `Shared/`, `Mirror/`
  (`iOS`, `Android`, `Relay`, `Shared`), `ThirdParty/` (`ghostty`, `git-wt`), `scripts/`
  (`scripts/bin` holds the former `bins`).
- Names: app target, scheme, and module `Prowl`; test target `ProwlTests`; `ProwlApp`,
  `ProwlPaths`, `ProwlLogger`. `scripts/check_legacy_naming.py` (in `make check`) keeps the old
  name out of maintained files.
- No user-visible change: the exported Release app has the same bundle paths, `Info.plist`,
  entitlements, linked libraries, and signing identity as an export from the old project.
- Path mapping for older entries: `docs-ai/README.md`.

## Deviations from plan

- The plan put the xcconfig files of S1 "per configuration". They are split into a base file and
  `-Debug` / `-Release` files that include it, so that shared settings are written once. The
  resolved settings are equal.
- `SWIFT_FORMAT_PATHS` and `.swiftlint.yml` now list `Shared/Sources` and the relay wire sources
  explicitly. Before the move these files were inside `supacode/` and thus already in scope.
- `make test-cli-unit` runs two packages (CLI and relay). Before, one root package held both.

## Open questions

- S3 (trial of the Tuist Xcode compilation cache and test insights) is not started. It needs a
  Tuist account and a recorded decision.
- Notarization was not run in the dry runs. The next release is the first full run of
  `scripts/release.sh` on this layout.
- The iOS client keeps the bundle identifiers and the development team of the imported project
  (`Mirror/iOS/Config/Project.xcconfig`). A decision on these is outside this entry.
