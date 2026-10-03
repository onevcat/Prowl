# 074.002 — S1: Tuist-Generated Projects

## Context

Slice S1 of [000-plan.md](000-plan.md). The two Xcode projects leave Git and Tuist generates them.
Paths, target names, the scheme name, and the module name do not change in this slice.

## Change

- Manifests: `Tuist.swift`, `Workspace.swift`, `Project.swift` (macOS app), and
  `MirrorClient/iOS/Project.swift` (iOS client). `supacode.xcodeproj` and
  `MirrorClient/iOS/ProwlMirror-iOS.xcodeproj` are deleted; `.gitignore` ignores the generated
  `*.xcodeproj`, `*.xcworkspace`, and the generation stamp.
- Build settings: `Config/Xcode/*.xcconfig` and `MirrorClient/iOS/Config/*.xcconfig`, extracted
  from the two `project.pbxproj` files. Settings that are equal in Debug and Release are in the
  base file (`Project.xcconfig`, `App.xcconfig`, `Tests.xcconfig`); the `-Debug` and `-Release`
  files include the base file. The manifests use `defaultSettings: .none`.
- Version: `Config/Xcode/Version.xcconfig` holds `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION`. `make bump-version`, `make sync-cli-version`, and
  `scripts/release.sh` use it.
- Lockfile: the former `Package.resolved` of the Xcode project is now the root
  `.package.resolved`. Tuist links it into `Prowl.xcworkspace`.
- Makefile: `generate` (public) stages the Debug resources and generates; `ensure-project`
  (internal) generates only when the workspace is absent or older than its inputs, and stops when
  a path that the app target copies is absent. All `xcodebuild` calls use
  `-workspace Prowl.xcworkspace`. The DerivedData cleanup uses `Prowl-*`.
- Tooling: `mise.toml` pins Tuist 4.210.0. `Tuist.swift` resolves packages into the checkout
  folder that the Makefile passes to `xcodebuild`, so generation and builds share one copy.
- CI: `.github/actions/setup-macos/action.yml` hashes the manifests, the xcconfig files, and
  `.package.resolved` instead of the project files.
- Scripts: `scripts/localization.py`, `scripts/benchmark-build.sh`,
  `scripts/test-remote-mirror.sh`, `scripts/ci-source-mtimes.py`, `scripts/release.sh`.

## Verification (2026-10-03, Tuist 4.210.0, Xcode 27.0)

| Check | Result |
| --- | --- |
| Resolved build settings, old project against generated project (5 targets, Debug and Release) | Equal, except the deltas below |
| Generated schemes against the old schemes | Same actions, configurations, test language and region |
| `make build-app` | Passed |
| `make test` | 3638 + 12 + 72 + 3 tests passed, 0 failed |
| `make test-cli-smoke test-cli-unit test-cli-integration` | 304 unit and 106 integration tests passed |
| `make check` (includes `make test-scripts`, 210 tests) | Passed |
| iOS client from the workspace: simulator build, unit tests | Built; 67 tests passed |
| `make archive` and `make export-archive` with the Developer ID identity | Passed; `codesign --verify --deep --strict` passed |
| Exported `Prowl.app` against an export from the old project of the same day | Same 846 bundle paths, same `Info.plist`, same entitlements, same signing identity and team, both universal |
| `.package.resolved` after all builds | Unchanged; the workspace link is still a link |

The old export came from a commit before PR #847. The new binary links `CoreImage` because that PR
added the pairing QR code; this is a source difference, not a project difference.

Deltas that are accepted:

- Tuist adds `-L$(TOOLCHAIN_DIR)/usr/lib/swift/<platform>` to `OTHER_LDFLAGS`, the `Frameworks`
  folder to `FRAMEWORK_SEARCH_PATHS`, and `EXCLUDED_SOURCE_FILE_NAMES = .gitkeep .DS_Store`.
- In Debug, `ProwlCLIShared`, `JSONSchema`, and `Yams` link statically into the app. Tuist links a
  package product only into the host app when the hosted test bundle also uses it. Release was
  already static.
- The iOS test targets get `SUPPORTS_MACCATALYST = NO` and the two "designed for iPhone/iPad"
  settings as `NO` from the `[.iPhone, .iPad]` destinations. The app target already had these
  values.
- The product reference in the generated scheme is `Prowl Debug.app` (Tuist resolves the Debug
  product name). The old scheme had `Prowl.app`. Xcode resolves the product at build time.

## Answers to the open questions of the plan

- Release archive and signed export are equal to the old project (table above). Notarization was
  not run; it does not depend on the project format.
- The iOS client can be generated alone, without `GhosttyKit.xcframework`:
  `mise exec -- tuist generate --path MirrorClient/iOS`.
- Xcode did not replace the `.package.resolved` link during builds, tests, or the archive.
- With `productName: "Prowl"` and a Debug-only override of `PRODUCT_NAME`, Tuist 4.210.0 prints
  no product-name warning.
- A root `Package.swift` still exists in S1, so each generation prints "We detected outdated
  dependencies". S2 removes the cause.
- CI on the `macos-26` runner: see the PR checks.

## Refs

PR #848
