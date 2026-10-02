# 074 — Project Restructure, Prowl Naming, and Tuist-Generated Projects: Plan

| | |
| --- | --- |
| **Status** | Planned |
| **Anchor date** | 2026-10-03 |
| **Primary PRs** | #848 (S1) |
| **Related** | [004-prowl-rebrand](../004-prowl-rebrand/000-plan.md), [016-dev-build-and-ci-workflow](../016-dev-build-and-ci-workflow/000-plan.md), [017-upstream-sync-process](../017-upstream-sync-process/000-plan.md), [067-remote-mirror](../067-remote-mirror/000-plan.md), [release-runbook.md](../001-fork-bootstrap-and-release-pipeline/release-runbook.md) |

## Background

[004](../004-prowl-rebrand/000-plan.md) renamed the product for users, but the repository still
uses the upstream name inside. On 2026-10-02, `supacode` occurred 2187 times in 684 tracked
files: the Xcode project `supacode.xcodeproj`, the targets and scheme `supacode` and
`supacodeTests`, the module (`@testable import supacode` in 340 test files), source folders,
types such as `SupacodePaths` and `SupaLogger`, cache folder names, and scripts.

The repository root grew by addition. The macOS app (`supacode/`, `supacodeTests/`,
`Resources/`, `Frameworks/`), the CLI (`ProwlCLI/`, `ProwlCLIContracts/`, `ProwlCLITests/`), the
mirror relay (`MirrorRelay/`, `MirrorRelayTests/`), and the mirror clients (`MirrorClient/`) are
all top-level folders. Code that two products share is inside the app folder:
`supacode/CLIService/Shared` is a target of the root `Package.swift` and also a nested package
(`supacode/CLIService/Shared/Package.swift`) for Xcode, and the two manifests pin dependencies
differently. `supacode/Features/RemoteMirror/RelayWire` is app source and also a SwiftPM target.

Two Xcode projects are in Git: `supacode.xcodeproj` and
`MirrorClient/iOS/ProwlMirror-iOS.xcodeproj`. The Makefile, `scripts/release.sh`, and the CI
cache keys read `project.pbxproj` directly (for example, the version numbers).

## Goals

- One name. Each project-level use of `supacode` becomes `Prowl`.
- A root folder for each product: the macOS app, the CLI, the mirror parts, and shared code.
- No Xcode project in Git. Tuist generates the macOS project and the iOS mirror project from
  manifests.
- The `make` targets, the `release` skill, and `scripts/release.sh` keep their interface.
- No change that a user can see: bundle identifiers, product and executable names, entitlements,
  `Info.plist` content, data locations, and update feed stay the same.

### Non-goals

- No change to the Android client build (Gradle is already declarative).
- No Tuist server features and no Tuist account in S1 and S2.
- No change of the dependency integration model (see Decisions).
- No change to numbered `docs-ai` files. They are immutable history.

## Design / Approach

### Slices

| Slice | Content | Result |
| --- | --- | --- |
| S1 | Tuist generates the two projects. Paths, target names, and module names stay. The two `.xcodeproj` folders leave Git. | Declarative projects; behavior parity |
| S2 | Rename identifiers and move folders. Split the SwiftPM package into three. | Final layout and names |
| S3 (optional) | Trial of Tuist server features (Xcode compilation cache, test insights). | A recorded decision |

S1 comes first because, with a manifest, each rename and move in S2 is a small text edit that the
same parity checks can verify.

### S1 — generated projects

- Root manifests: `Tuist.swift`, `Workspace.swift` (projects `.` and `MirrorClient/iOS`), and
  `Project.swift` for the macOS app. `MirrorClient/iOS/Project.swift` describes the iOS client.
  The generated `Prowl.xcworkspace` and `*.xcodeproj` are ignored by Git.
- Build settings move without change from the two `project.pbxproj` files into xcconfig files
  (project, app, and tests, for Debug and Release). The manifests use `defaultSettings: .none`.
  Tuist derives `PRODUCT_NAME` and `PRODUCT_BUNDLE_IDENTIFIER` and these override xcconfig
  values, so the manifests set them explicitly (`Prowl Debug` / `Prowl`,
  `$(TARGET_NAME)` for the iOS targets).
- Sources stay Xcode synchronized folders (`buildableFolders`). The app folder excludes
  `Info.plist` and `CLIService/Shared`. The test folder excludes `Fixtures` and adds it again as
  a folder reference, which keeps the "apply once to folder" behavior.
- Dependencies stay Xcode-native Swift packages (`packages:` and `.package(product:)`). The
  lockfile becomes the root `.package.resolved`; Tuist links it into the generated workspace.
  Thus each `xcodebuild` call uses `-workspace Prowl.xcworkspace`.
- `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` move to one `Version.xcconfig`.
  `make bump-version`, `make sync-cli-version`, and `scripts/release.sh` read and write that file.
- Makefile: a `generate` target (stamp file, inputs are the manifests, the xcconfig files,
  `.package.resolved`, and `mise.toml`) becomes a prerequisite of `build-app`, `test-app`,
  `archive`, `bench`, and the contract-test targets. `generate` depends on `ensure-ghostty`
  because generation fails when `Frameworks/GhosttyKit.xcframework` is absent. The build-settings
  cache of `run-app` and `install-dev-build` uses the stamp instead of the `pbxproj` time.
- `mise.toml` pins Tuist to 4.210.0 or later. CI gets it through `mise install`.
  `.github/actions/setup-macos/action.yml` replaces the `pbxproj`, scheme, and
  `Package.resolved` hash inputs with the manifests, the xcconfig files, and `.package.resolved`.
- `scripts/localization.py`, `scripts/benchmark-build.sh`, `scripts/test-remote-mirror.sh`, and
  `scripts/ci-source-mtimes.py` change from the project to the workspace. The DerivedData folder
  name changes from `supacode-*` to `Prowl-*` (the workspace name), so the cleanup lines in the
  Makefile and `scripts/ensure-ghosttykit-artifacts.sh` change too.

### S2 — names and layout

Target layout (all paths below are planned):

| Now | After S2 |
| --- | --- |
| `supacode/`, `supacodeTests/` | `App/Sources/`, `App/Tests/` |
| `Resources/`, `Frameworks/` | `App/Resources/`, `App/Frameworks/` |
| `supacode/Info.plist`, entitlements, xcconfig files | `App/Config/` |
| `ProwlCLI/`, `ProwlCLIContracts/`, `ProwlCLITests/`, root `Package.swift` | `CLI/` (package `ProwlCLI`) |
| `supacode/CLIService/Shared` | `Shared/` (package `ProwlShared`, library `ProwlCLIShared`) |
| `MirrorRelay/`, `MirrorRelayTests/`, `supacode/Features/RemoteMirror/RelayWire` | `Mirror/Relay/` (package) |
| `MirrorClient/iOS`, `MirrorClient/Android`, `MirrorClient/Shared` | `Mirror/iOS`, `Mirror/Android`, `Mirror/Shared` |
| `Resources/git-wt` (submodule) | `ThirdParty/git-wt` |
| `bins/` | `scripts/bin/` |
| root `supacode.json` | deleted (no code reads it) |

Names:

| Changes | Stays |
| --- | --- |
| Targets, scheme, module: `supacode` → `Prowl`, `supacodeTests` → `ProwlTests` | Bundle identifiers; `Prowl.app` / `Prowl Debug.app`; executable `ProwlApp` |
| `SupacodeApp`, `SupacodeAppDelegate`, `SupacodeAppStoreBox`, `SupacodePaths`, `SupaLogger` → `Prowl…` | Stored raw value `supacodeClassic` of `NotificationSound` (the Swift case gets a new name) |
| `supacode-spm-cache`, `build/supacode.xcarchive`, `/tmp/supacode-worktree-trash`, `__supacode_login_argv` | Readers of the legacy `~/.supacode` folder and `supacode.json` files |
| Feedback link `onevcat/supacode` → `onevcat/Prowl` | Keychain profile `supacode-notary`; upstream name `supabitapp/supacode` |
| Paths in scripts, CI, skills, `docs/`, `AGENTS.md`, living `docs-ai` files | Numbered `docs-ai` files; mirror identifiers `com.awhisper.*` and project name `ProwlMirror-iOS` |

- The three packages replace the root package and the nested manifest. `CLI` depends on
  `Shared` through a local path; the app uses `Shared` as a local package. The app compiles the
  two `RelayWire` files and the two `Mirror/Shared` files as extra sources, as it does now for
  `MirrorClient/Shared`. `make build-cli` and the `test-cli-*` targets keep their names and call
  `swift` with `--package-path`.
- Commits: (1) `git mv` only, (2) mechanical identifier changes, (3) manifests, Makefile, CI,
  scripts, skills, and documents. This keeps `git log --follow` and blame usable.
- A new check in `make check` (same pattern as `scripts/check_workflow_naming.py`) fails when
  `supacode` occurs outside an allowlist (the "Stays" column above).
- `docs-ai/README.md` gets an old-to-new path table. The note about the module name in
  `.claude/skills/write-ai-doc/SKILL.md` and the path tables in
  `.claude/skills/sync-docs/SKILL.md` are updated.

### Verification

| Slice | Acceptance |
| --- | --- |
| S1 | Resolved build settings equal the old projects (script diff, Debug and Release, all targets) except the accepted deltas below. `make check`, `make test`, CLI tests pass. A Release archive has the same bundle layout and `Info.plist` as the last release. One release dry run up to the signed export. |
| S2 | Same checks. An installed Debug build reads the existing data in `~/.prowl`. The legacy-name check passes. |

Accepted deltas (measured in the spike): Tuist adds one `-L` linker search path and one framework
search path; in Debug, `ProwlCLIShared`, `JSONSchema`, and `Yams` link statically into the app
instead of three `*_PackageProduct.framework` bundles (Release already links them statically).

Spike result (2026-10-02, scratch copy, Tuist 4.208.0, Xcode 27.0): generation takes 4 to 7
seconds; the 618 resolved app settings match; the app and test bundle build; 41 tests in 4
suites pass; the Debug `Info.plist` is identical; the iOS client builds for the simulator from
the same workspace.

## Alternatives & decisions

Decisions agreed with onevcat on 2026-10-03:

| Topic | Decision | Reason |
| --- | --- | --- |
| Generator | Tuist, not XcodeGen | Swift manifests with type checks, one workspace for the two projects, shared helpers, and a path to caching. XcodeGen 2.46 also supports synchronized folders, but has none of the other items. Upstream already uses Tuist, so there is a working reference (`Project.swift` on `upstream/main`). |
| Dependency integration | Xcode-native packages | Zero behavior change, proven by the settings diff. The Tuist-native mode (`Tuist/Package.swift`, `.external`) is necessary only for the module cache, and brings `-ObjC`, static/dynamic, and Sparkle artifact risks. |
| Module name | `Prowl` | No type has this name. `ProwlApp` stays the executable name. |
| SwiftPM layout | Three packages | A root `Package.swift` is read by Tuist as its dependency manifest (a warning on each generation). A target path cannot leave its package root, so a single manifest for all products is possible only at the root. Three packages also remove the double definition of `ProwlCLIShared`. |
| Order | Generation first, then rename and move | Smallest first step; later steps reuse its checks. A single large change was rejected because a failure would be hard to isolate. |
| History documents | Not rewritten | Rule of `docs-ai/README.md`. A path table gives the mapping. |
| Server features | Not in S1 and S2 | The app is one target with one test bundle, so the module cache and selective testing give little. The Xcode compilation cache and test insights are trial items for S3. |

Risks:

- Each new Xcode needs a Tuist release that supports it. The pinned version limits surprises.
  Tuist 4.208.0 has a false circular-dependency error on Xcode 27 in the `.external` mode
  (fixed in 4.210.0); the native mode in this plan is not affected.
- A fresh clone has no project until `make generate` runs. `make build-app` stays one command.
- The module rename changes the frame names in Sentry, so issue grouping resets once.
- Paths move further away from upstream. Upstream changes are ported by hand since 2026-03
  (see [upstream-ledger.md](../017-upstream-sync-process/upstream-ledger.md)), so the cost is low.
- Local state: the first build after each slice is a full build (new DerivedData and package
  cache names). Unmerged local branches need a rebase across the moves.

## Open questions

- The spike built Debug only. Release archive, export, and notarization parity are S1 checks.
- CI runs on `macos-26` runners. Tuist 4.210 with the Xcode version of these runners is not yet
  tested.
- Generation of the iOS client alone (without `GhosttyKit.xcframework`) is not yet tested. If it
  is not possible, mirror-only work also needs `make ensure-ghostty` (a download, not a build).
- It is not known whether Xcode can replace the `.package.resolved` link with a regular file. If
  it does, `make generate` must copy the file back.
- Tuist prints a warning because `PRODUCT_NAME` differs between Debug and Release. This is the
  current product design and the spike shows no effect.

## Amendments

- Updated 2026-10-03: S1 implemented and verified (generated projects, version xcconfig, workspace builds) — see [002-s1-generated-projects.md](002-s1-generated-projects.md)
