# 016 — Dev Build & CI Workflow: Plan

| | |
| --- | --- |
| **Status** | Implemented (retrospective) |
| **Anchor date** | 2026-04-04 |
| **Documented** | 2026-07-12 (backfilled) |
| **Primary PRs** | #140, #142, #144, #145, #152 (anchor wave); later waves: #248/#503, #266/#269/#307/#308/#333, #391/#461/#479/#482 |
| **Sources** | PR descriptions, commits `1028d5b3` (#140) and `72a3dd2e` (hook revert), current `Makefile` / `.github/` tree |
| **Related** | [001-fork-bootstrap-and-release-pipeline](../001-fork-bootstrap-and-release-pipeline/000-plan.md), [013-prowl-cli](../013-prowl-cli/000-plan.md), [041-ghosttykit-prebuilt-artifacts](../041-ghosttykit-prebuilt-artifacts/000-plan.md), `CLAUDE.md` (build command reference) |

## Background

Prowl builds against `Frameworks/GhosttyKit.xcframework`, compiled from the Zig source in
the `ThirdParty/ghostty` submodule, and embeds the SwiftPM-built `prowl` CLI into the app
bundle. By early April 2026 the day-to-day developer workflow had several recurring pains:

- Switching branches that pinned a different Ghostty submodule SHA left stale local
  artifacts in place, producing compile-time symbol drift (e.g. missing
  `ghostty_config_load_file`) that had to be diagnosed by hand.
- Conversely, CI rebuilt Ghostty (~10 minutes) inside `make build-app` even when the
  artifact cache had hit, because the freshness markers were not part of the cache.
- `make test` printed raw `xcodebuild` output — noisy for humans and expensive for coding
  agents; CI test failures gave no actionable detail (fork issue #103).
- `make build-app` (Debug) depended on the release-mode CLI build (`swift build -c release`),
  a Debug/Release mismatch that slowed every dev iteration.

This entry covers the tooling that fixed these, and the three later waves that kept
extending the same surface (Makefile, `.github/workflows/test.yml`,
`.github/actions/setup-macos/action.yml`, project build settings) — formatter/lint
alignment, CI throughput/caching, and Debug-app identity + local dev-loop speed.

## Goals

- Keep local GhosttyKit artifacts automatically in sync with the pinned submodule SHA;
  rebuild only when the SHA changes or artifacts are missing.
- Make the CI Ghostty cache actually short-circuit the rebuild.
- Structured, agent-friendly build/test output (xcsift TOON) plus actionable failure
  details extracted from the `.xcresult` bundle, locally and as a CI artifact.
- Embed a debug-mode CLI in Debug app builds; keep release CLI for distribution builds.
- Later waves (see Amendments): idempotent formatting tooling, faster and non-lying CI,
  stable Debug app identity, and a fast `make run-app` loop.

## Design / Approach

Anchor wave, all landed 2026-04-04/05:

1. **GhosttyKit auto-sync by submodule SHA** (#140). `make ensure-ghostty` compares
   `git rev-parse HEAD:ThirdParty/ghostty` against the last-synced SHA persisted in
   `.ghostty_hash`; a build-stamp file (`.ghostty_build_stamp`) plus make prerequisites
   gate the actual rebuild. `build-app` and `test` route through `ensure-ghostty`, and a
   SHA change also clears `supacode-*` DerivedData (Ghostty header/module changes).
   `make sync-ghostty` remains as the explicit force-rebuild path.
2. **CI cache alignment** (#142). Include `.ghostty_hash` and `.ghostty_build_stamp` in
   the Ghostty cache payload (namespace bumped to `ghostty-v1`), and always refresh the
   marker files after restore/build so the `ensure-ghostty` fast path works on clean
   runners.
3. **Structured test output + failure details** (#144, fixing fork issue #103). `make test`
   pipes `xcodebuild test` through `xcsift --format toon`, persists the result bundle at
   `build/test-results/supacode-tests.xcresult`, preserves the real exit code via
   `PIPESTATUS[0]`, and on failure runs `scripts/print-xcresult-failures.sh` to print test
   name/identifier/failure text. CI uploads the `.xcresult` as an artifact on failure.
4. **Warning/debt cleanup** (#145). Remove local test-compiler warnings; opt CI JavaScript
   actions into the Node 24 runtime (`FORCE_JAVASCRIPT_ACTIONS_TO_NODE24`).
5. **Debug CLI for dev builds** (#152). New `embed-cli-debug` target builds the CLI with
   plain `swift build` and copies it to `Resources/prowl-cli/prowl`; `build-app` uses it,
   while `archive` (Release) keeps the universal release `embed-cli`.

## Alternatives & decisions

- **Repo-managed git hooks — shipped, then dropped same day.** #140 added
  `.githooks/post-checkout` / `.githooks/post-merge` and `make setup-local-hooks` to
  auto-run `ensure-ghostty` after branch/merge changes. Commit `72a3dd2e` ("keep global
  hooks and drop repo hook override") removed them hours later: overriding the user's
  global `core.hooksPath` was judged too invasive. Freshness relies on `build-app`/`test`
  always passing through `ensure-ghostty` instead.
- **Marker files over make-only dependency tracking**: the SHA hash file makes the fast
  path survive CI cache restores and DerivedData wipes, which pure make timestamps do not.
- **Debug/Release CLI split** (#152): distribution builds intentionally keep the
  release-mode universal binary; only the dev loop got the debug CLI.
- **xcsift TOON as the output format** for all xcodebuild invocations (build, test,
  archive), managed via mise (`github:ldomaradzki/xcsift` in `mise.toml`).

## Amendments

- Updated 2026-04-29 (+ 2026-06-24): swift-format ↔ SwiftLint trailing-comma alignment;
  `make lint` became a pure check — see [002-format-lint-alignment.md](002-format-lint-alignment.md)
- Updated 2026-05-24: CI throughput & caching wave — workflow concurrency, SPM cache out
  of `/tmp`, parallel test steps + failure-masking fix, compilation-cache key fix +
  type-checker hotspots — see [003-ci-throughput-and-caching.md](003-ci-throughput-and-caching.md)
- Updated 2026-06-20: Debug app identity at project level + local dev-loop acceleration
  (`run-app` guard removal, content-aware build inputs, build-settings cache, incremental
  compilation) — see [004-debug-identity-and-dev-loop.md](004-debug-identity-and-dev-loop.md)
- Updated 2026-08-05: fixed-path build benchmarks, rotating toolchain-scoped caches, an
  integrated CI build/test graph, and measured type-checker hotspot cleanup — see
  [005-build-test-time-optimization.md](005-build-test-time-optimization.md)
- Updated 2026-09-06: content-checked CLI source timestamps and cache input coverage — see
  [006-ci-source-cache-reuse.md](006-ci-source-cache-reuse.md)
- Updated 2026-09-06: App incremental-state reuse and measured module extraction — see
  [007-app-incremental-and-module-boundaries.md](007-app-incremental-and-module-boundaries.md)
