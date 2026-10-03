# 074.003 — S2: Prowl Names and Product Layout

## Context

Slice S2 of [000-plan.md](000-plan.md), on top of S1 ([002-s1-generated-projects.md](002-s1-generated-projects.md)).
The project name becomes `Prowl` everywhere and each product gets a root folder.

## Change

Three commits, in this order, so that `git log --follow` and blame stay usable:

1. **Moves only** (1342 renames). The mapping is the table in `docs-ai/README.md`. The `git-wt`
   submodule moves to `ThirdParty/git-wt`. The root `supacode.json` is deleted.
2. **Mechanical identifier changes** in 457 Swift files: the module (`@testable import Prowl`),
   `ProwlApp`, `ProwlAppDelegate`, `ProwlAppStoreBox`, `ProwlPaths`, `ProwlLogger`,
   `NotificationSound.prowlClassic` (raw value `"supacodeClassic"`), and internal names (worktree
   trash folder, login shell variable, feedback link, file header comments, test temporaries).
3. **Manifests, tooling, documents.**
   - `App/Project.swift`: target `Prowl` (module `Prowl`), target `ProwlTests`, scheme `Prowl`.
     The source folder needs no exceptions now, because `Info.plist`, the entitlements, and the
     shared code are outside `App/Sources`.
   - SwiftPM: `Shared/Package.swift` (`ProwlShared`, library `ProwlCLIShared`), `CLI/Package.swift`
     (`prowl`, depends on `../Shared`), `Mirror/Relay/Package.swift` (`prowl-mirror-relay`). The
     nested manifest and the root package are gone. The app compiles the two
     `Mirror/Relay/Sources/MirrorRelayProtocol` files and the two `Mirror/Shared` files as extra
     sources.
   - Makefile: same public targets. `make test-cli-unit` also runs the relay package tests.
     `make check` has a new step, `check-legacy-naming` (`scripts/check_legacy_naming.py`), that
     fails when `supacode` occurs outside its allowlist.
   - Names of local state: `~/Library/Caches/prowl-spm-cache`, `build/Prowl.xcarchive`, result
     bundles `prowl-*.xcresult`.
   - CI cache paths and keys (new key versions, because the cached paths moved).
   - `AGENTS.md` has a "Repository Layout" section. Skills, `docs/`, and the living `docs-ai`
     files use the new paths. Numbered `docs-ai` files are not changed.

What keeps the old name, by design: the stored sound value `supacodeClassic`, the readers of
`~/.supacode` and `supacode.json`, the keychain profile `supacode-notary`, the upstream
repository name, and test data that names the upstream repository.

## Verification (2026-10-03, Tuist 4.210.0, Xcode 27.0)

| Check | Result |
| --- | --- |
| `make build-app` | Passed; generation prints no warning |
| `make test` | 3638 + 12 + 72 + 3 tests passed, 0 failed (same counts as S1) |
| `make test-cli-smoke test-cli-unit test-cli-integration` | 296 CLI unit, 8 relay unit, 106 integration tests passed (296 + 8 = the 304 of S1) |
| `make check` | Passed, with the new legacy-name check; `swift-format` changed no file |
| Resolved build settings against the original project | Differences are only names, paths, the module name, and the S1 deltas |
| iOS client: unit tests from the workspace | 67 tests passed |
| `make archive` and `make export-archive` with the Developer ID identity | Passed; `codesign --verify --deep --strict` passed |
| Exported `Prowl.app` against the S1 export | Same 846 bundle paths, `Info.plist`, entitlements, linked libraries, signing identity |
| Debug app in an isolated home (`CFFIXED_USER_HOME`, own CLI socket) | Starts; `prowl list --json` from `CLI/.build` returns `ok`; a seeded `~/.supacode` is copied to `~/.prowl` and `notificationSound` stays `supacodeClassic` |

## Notes

- Local state after checkout of this slice: run `git submodule update --init` (the `git-wt` path
  moved); the first build is a full build. A leftover root `.build` folder, an old
  `supacode.xcodeproj` folder that only holds `xcuserdata`, and `~/Library/Caches/supacode-spm-cache`
  are no longer used and can be deleted.
- Sentry groups issues by frame; the module name in frames changes from `supacode` to `Prowl`, so
  existing issues regroup once after the first release from this layout.
- `assets/` (the icon source) stays at the root. It was not part of the agreed layout.

## Refs

PR #849 (stacked on #848)
