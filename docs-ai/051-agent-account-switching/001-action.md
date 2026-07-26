# 051 — Agent Account Switching: Action

| | |
| --- | --- |
| **Status** | Implemented; app build and XCTest run outstanding (no Xcode on the authoring machine) |
| **Anchor date** | 2026-07-25 |
| **Plan** | [000-plan.md](000-plan.md) |

## Delivered

- **`supacode/Domain/AgentAccount.swift`** — the whole feature's logic.
  `storedName` (trim, blank → `nil`) is what gets persisted; `normalizedName`
  additionally rejects `/`, `.` and `..` and is what callers must pass through
  before a name becomes a directory. `resolvedName` applies override → longest
  matching rule → global default. `environment(forAccountNamed:)` is pure;
  `prepareDirectories(forAccountNamed:)` is the only function that touches disk
  and it throws.
- **`SupacodePaths.agentAccountsDirectory`** — `~/.prowl/accounts`.
- **`RepositorySettings.agentAccount`** (`String?`) — per-repository override.
- **`GlobalSettings.defaultAgentAccount` / `.agentAccountRules`** — added with
  the property-default + `decodeIfPresent` pattern established by
  `externalDiffToolID`; decoded through `decodeAgentAccountSettings` to keep
  `init(from:)` inside the body-length limit.
- **`WorktreeTerminalState.makeSurfaceEnvironment()`** — prepares the account
  directories, logs a failure through the file's existing `terminalStateLogger`,
  and returns the account env merged over `worktree.scriptEnvironment`. A method,
  not a property, because the directories must exist before the shell starts, so
  building and preparing cannot be separated without an unwritten ordering
  contract. Needed a second `@SharedReader` on `.settingsFile` for the global
  default and rules.
- **UI** — `AdvancedSettingsView` gains an "Agent Accounts" section: default
  account field plus a rules editor built from `AgentAccountRuleRow`, one row per
  `AgentAccountRule`, added and removed by identity
  (`addAgentAccountRuleButtonTapped` / `removeAgentAccountRuleButtonTapped(id:)`).
  `RepositorySettingsView` gains an "Agent Account" section whose placeholder
  comes from `RepositorySettingsFeature.State.inheritedAgentAccount`.
  `AgentAccountNameWarning` explains an unusable name next to the field holding it.
- **Docs** — `docs/components/settings.md` (new "Agent accounts" section, tab
  table), `docs/components/terminal.md` (env paragraph),
  `docs/reference/settings-fields.md` (three fields).

## Decisions that changed during review

- **The rules editor was a text blob (`path = account` per line) mirrored in
  `SettingsFeature.State`.** That made the state a second source of truth over a
  lossy parser: every keystroke persisted a filtered array, and a typo silently
  disappeared on the next open. Replaced with `[AgentAccountRule]` bound
  directly; the parser, the serializer and the mirror are gone.
- **Nothing the user types is dropped on the way to disk.** Persistence applies
  only `storedName`; rejection lives at resolution time and is surfaced by
  `AgentAccountNameWarning`. Normalizing in the binding would have erased the
  field mid-typing (typing `/` would clear it), which is why the canonical
  `RepositorySettingsFeature.binding` site trims but does not reject.
- **Paths are built without `directoryHint: .isDirectory`** — the hint leaves a
  trailing slash in the exported value. A test caught this.
- **Rules carry identity** (`AgentAccountRule.id`, the `UserCustomCommand`
  pattern), so the editor is `ForEach($store.agentAccountRules)` rather than an
  index-keyed list. Index-as-identity made every row after a deletion mean
  something else to SwiftUI, and forced a stale-index guard in the reducer; both
  are gone. New ids come from `@Dependency(\.uuid)` so tests stay deterministic.
- **The inherited-account placeholder is derived in the reducer**
  (`State.inheritedAgentAccount`, next to `exampleWorktreePath`), so the view no
  longer reads `.settingsFile` or resolves accounts itself.

## Verification

- `supacodeTests/AgentAccountTests.swift` — resolution precedence,
  longest-prefix, path boundaries, tilde expansion, name rejection vs. storage,
  env purity, directory preparation.
- `supacodeTests/AgentAccountSettingsTests.swift` — `SettingsFeature.State` ↔
  `globalSettings` round-trip preserving half-typed and unusable rules,
  add/remove rule actions persisting through `@Shared`, `RepositorySettings`
  JSON round-trip keeping an unusable account, and the repository binding's
  trim/clear behavior.
- The `AgentAccount` assertions were additionally compiled and **run** standalone
  (`swiftc` with a stubbed `SupacodePaths`), since the machine has no Xcode: all
  pass.
- `swiftc -parse`, `swift format lint --strict` and a formatting diff are clean
  on every changed file.
- **Not run:** `make build-app`, `make test`, `swiftlint` — all require Xcode /
  mise, neither installed on the authoring machine. The app target has not been
  compiled.
- **Known unrelated breakage:** `supacodeTests/GhosttyRuntimeScrollbackOverrideTests.swift`
  (pre-existing, untracked) references `GhosttyRuntime.scrollbackOverrideContents`,
  which does not exist in the target. Because `supacodeTests` is a synchronized
  root group, that file alone fails the test-target build. It was briefly moved
  aside during this work and has been put back: it is not this branch's file, and
  whether to delete it or land the missing implementation is onevcat's call.
