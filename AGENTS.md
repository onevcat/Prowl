This fork is primarily for onevcat-specific customizations; before doing any release work, read `docs-ai/001-fork-bootstrap-and-release-pipeline/release-runbook.md` (and the upstream ledger `docs-ai/017-upstream-sync-process/upstream-ledger.md`) for fork publishing guidance. Fork history and design decisions are recorded under `docs-ai/` (see `docs-ai/README.md`).

## Build Commands

```bash
make build-ghostty-xcframework  # Rebuild GhosttyKit from Zig source (requires mise)
make build-app                   # Build macOS app (Debug) via xcodebuild
make run-app                     # Build and launch Debug app
make install-dev-build           # Build and copy to /Applications (Debug)
make sign-debug-app              # Sign the built Debug app (runs from build-app; PROWL_CODESIGN_IDENTITY overrides)
make install-release             # Build Release, sign locally, install to /Applications
make format-changed              # Run swift-format on changed Swift files only
make format                      # Run full-tree swift-format cleanup
make lint                        # Run swiftlint only
make check                       # Run changed-file format, swift-format lint, and swiftlint
make test                        # Run all tests
make benchmark-build             # Benchmark CI-like clean/warm-CAS build and test time
make bench                       # Run performance benchmarks with -O; append absolute medians to ~/Library/Logs/Prowl/measurements/bench/
make measure-cpu                 # Steady-state CPU + per-symbol attribution of the running Prowl Debug app
make capture-spike               # Sample the running Prowl Debug app when CPU crosses a threshold
make measure-titles              # Black-box check that animated tab titles stay coalesced (~1 change/s)
make log-stream                  # Stream app logs (subsystem: com.onevcat.prowl)
make build-cli                   # Build CLI (prowl) via SwiftPM
make test-cli-smoke              # Run CLI smoke tests (unit-level)
make test-cli-integration        # Run CLI integration tests (socket round-trip)
make bump-version                # Bump version (date-based YYYY.M.DD) and create git tag; used by release.sh
```

Run a single test class or method:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TerminalTabManagerTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

**Swift Testing vs XCTest `-only-testing` format**: Swift Testing (`@Test`) requires trailing `()` in the test identifier. Without it, `xcodebuild` silently matches nothing and reports `TEST SUCCEEDED` with zero tests run.

```bash
# XCTest (func testFoo)
-only-testing:supacodeTests/FooTests/testBar
# Swift Testing (@Test func bar)
-only-testing:"supacodeTests/FooTests/bar()"
```

Requires [mise](https://mise.jdx.dev/) for zig, swiftlint, and xcsift tooling.

`make log-stream` shows no `TCA` action lines by default: per-action logging — the action label plus a full app-state snapshot and diff — is gated off because it runs on every action and shows up as steady main-thread cost. Launch with `PROWL_LOG_TCA_ACTIONS=1` (scheme env var, or exported before `open`) to trace the action stream through the unified log.

## Architecture

Prowl is a macOS orchestrator for running multiple coding agents in parallel, using GhosttyKit as the underlying terminal.

### Core Data Flow

```
AppFeature (root TCA store)
├─ RepositoriesFeature (repos + worktrees)
├─ CommandPaletteFeature
├─ SettingsFeature (appearance, updates, repo settings)
└─ UpdatesFeature (Sparkle auto-updates)

WorktreeTerminalManager (global @Observable terminal state)
├─ selectedWorktreeID (tracks current selection for bell logic)
└─ WorktreeTerminalState (per worktree)
    └─ TerminalTabManager (tab/split management)
        └─ GhosttySurfaceState[] (one per terminal surface)

GhosttyRuntime (shared singleton)
└─ ghostty_app_t (single C instance)
    └─ ghostty_surface_t[] (independent terminal sessions)
```

### TCA ↔ Terminal Communication

The terminal layer (`WorktreeTerminalManager`) is `@Observable` but outside TCA. Communication uses `TerminalClient`:

```
Reducer → terminalClient.send(Command) → WorktreeTerminalManager
                                                    ↓
Reducer ← .terminalEvent(Event) ← AsyncStream<Event>
```

- **Commands**: `createTab`, `closeFocusedTab`, `prune`, `setSelectedWorktreeID`, etc.
- **Events**: `notificationReceived`, `tabCreated`, `tabClosed`, `focusChanged`, `taskStatusChanged`
- Wired in `supacodeApp.swift`, subscribed in `AppFeature.task`

### Key Dependencies

- **TCA (swift-composable-architecture)**: App state, reducers, side effects
- **GhosttyKit**: Terminal emulator (built from Zig source in ThirdParty/ghostty)
- **Sparkle**: Auto-update framework
- **swift-dependencies**: Dependency injection for TCA clients
- **PostHog**: Analytics
- **Sentry**: Error tracking

## Ghostty Keybindings Handling

- Ghostty keybindings are handled via runtime action callbacks in `GhosttySurfaceBridge`, not by app menu shortcuts.
- App-level tab actions should be triggered by Ghostty actions (`GHOSTTY_ACTION_NEW_TAB` / `GHOSTTY_ACTION_CLOSE_TAB`) to honor user custom bindings.
- `GhosttySurfaceView.performKeyEquivalent` routes bound keys to Ghostty first; only unbound keys fall through to the app.

## Code Guidelines

- Target macOS 26.0+, Swift 6.2+
- Before doing a big feature or when planning, consult with pfw (pointfree) skills on TCA, Observable best practices first.
- Use `@ObservableState` for TCA feature state; use `@Observable` for non-TCA shared stores; never `ObservableObject`
- Always mark `@Observable` classes with `@MainActor`
- Modern SwiftUI only: `foregroundStyle()`, `NavigationStack`, `Button` over `onTapGesture()`
- Before changing a window toolbar control, its grouping, or Liquid Glass, read `docs-ai/061-native-toolbar-controls/toolbar-controls.md` and perform a Debug visual verification.
- When a new logic changes in the Reducer, always add tests
- In unit tests, never use `Task.sleep`; use `TestClock` (or an injected clock) and drive time with `advance`.
- Prefer Swift-native APIs over Foundation where they exist (e.g., `replacing()` not `replacingOccurrences()`)
- Avoid `GeometryReader` when `containerRelativeFrame()` or `visualEffect()` would work
- Do not use NSNotification to communicate between reducers.
- Prefer `@Shared` directly in reducers for app storage and shared settings; do not introduce new dependency clients solely to wrap `@Shared`.
- Use `SupaLogger` for all logging. Never use `print()` or `os.Logger` directly. `SupaLogger` prints in DEBUG and uses `os.Logger` in release.

### Formatting & Linting

- 2-space indentation, 120 character line length (enforced by `.swift-format.json`)
- `swift-format` is the source of truth for trailing commas: multi-element collection literals keep trailing commas, while single-element collection literals may have them removed.
- SwiftLint runs in strict mode; never disable lint rules without permission
- Custom SwiftLint rule: `store_state_mutation_in_views` — do not mutate `store.*` directly in view files; send actions instead
- Before creating a PR, run `make check`. Use `make format` only for intentional full-tree formatting cleanup.
- If `make check` fails with `swift-format: command not found`, the Xcode toolchain is not on `PATH`. The Makefile invokes `swift-format` unqualified, and the binary ships inside Xcode rather than in a standard bin directory. Prepend it for the invocation:

  ```bash
  export PATH="$(dirname "$(xcrun --find swift-format)"):$PATH"
  make check
  ```

  `make lint` is unaffected — it already runs SwiftLint through `mise exec`.

## UX Standards

- Buttons must have tooltips explaining the action and associated hotkey
- Use Dynamic Type, avoid hardcoded font sizes
- Components should be layout-agnostic (parents control layout, children control appearance)
- Never use custom colors, always use system provided ones.
- We use `.monospaced()` modifier on fonts when appropriate

## Rules

- After a task, ensure the app builds: `make build-app`
- When working on CLI code (`ProwlCLI/`, `ProwlCLITests/`, `Package.swift`), run `make build-cli`, `make test-cli-smoke`, and `make test-cli-integration` before committing.
- When you change user-facing behavior (keyboard shortcuts, settings, the `prowl` CLI, or a feature's UX), update the matching file under `docs/` in the same change. For a full audit, run the `sync-docs` skill.
- `docs-ai/` is curated, durable product/design documentation — never a working-note archive. Use the `write-ai-doc` skill only for a substantial feature or a non-trivial fix whose design and result must guide future implementation. Do not create entries for reviews, audits, routine research or investigations, status reports, test runs, or docs-only work unless onevcat explicitly asks for a `docs-ai/` record. When uncertain, do not create an entry. For qualifying work, create `docs-ai/NNN-<slug>/000-plan.md` before coding and complete `001-action.md` after implementation. Follow-up work on the same topic amends the existing entry (see `docs-ai/README.md`).
- When implementing a new feature or fixing a bug that is unrelated to the current branch's active work, first create a dedicated branch from the latest `origin/main`; then work, commit, push, and open a PR from that branch.
- Automatically commit your changes and your changes only. Do not use `git add .`
- Before you go on your task, check the current git branch name, if it's something generic like an animal name, name it accordingly. Do not do this for main branch
- After implementing an execplan, always submit a PR if you're not in the main branch
- PRs must target `onevcat/Prowl` (this fork), never the upstream `supabitapp/supacode`, unless explicitly requested.
- Fork releases must be notarized. Never publish non-notarized releases (`ENABLE_NOTARIZATION=0` is forbidden).

## Submodules

- `ThirdParty/ghostty` (`https://github.com/ghostty-org/ghostty`): Source dependency used to build `Frameworks/GhosttyKit.xcframework` and terminal resources.
- `Resources/git-wt` (`https://github.com/khoi/git-wt.git`): Bundled `wt` CLI used by Prowl Git worktree flows at runtime.
