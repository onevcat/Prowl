# Keybinding System

> Living document of entry 012. Migrated from `doc-onevcat/keybinding-system.md` on 2026-07-12; update in place.

Guide for agents working on keyboard shortcuts in Prowl.

## Architecture Overview

```
AppShortcuts (built-in registry, ~50 commands)
    ↓
KeybindingSchemaDocument (versioned schema, all command definitions)
    ↓
KeybindingResolver.resolve(schema, userOverrides, migratedOverrides)
    ↓
ResolvedKeybindingMap (merged result: default + migrated + user)
    ↓
┌──────────────────────────────┐
│ SwiftUI Environment          │  @Environment(\.resolvedKeybindings)
│ Ghostty CLI args             │  --keybind=...=unbind / --keybind=...=action
│ Menu items & tooltip display │  .keyboardShortcut / .help()
└──────────────────────────────┘
```

## Scopes & Conflict Policies

| Scope | `allowUserOverride` | Conflict Policy | Example |
|-------|---------------------|-----------------|---------|
| `configurableAppAction` | true | `warnAndPreferUserOverride` | New Worktree, Command Palette, Toggle Sidebar |
| `systemFixedAppAction` | false | `disallowUserOverride` | Quit App — cannot be changed |
| `localInteraction` | true | `localOnly` | Rename Branch, Select All Canvas Cards |
| `customCommand` | true | `warnAndPreferUserOverride` | User-defined repo commands |

## Resolution Precedence

```
appDefault  →  migratedLegacy (from old custom command shortcuts)  →  userOverride
```

- Higher priority overrides lower.
- `systemFixedAppAction` ignores all overrides (always stays at default).
- `isEnabled=false` on an override clears the binding (disables the shortcut).
- If migrated or user override is identical to default, source stays `appDefault`.

## Key Files

| Purpose | File |
|---------|------|
| **Data models, resolver, migration** | `App/Sources/App/KeybindingSchema.swift` |
| **Built-in command registry** | `App/Sources/App/AppShortcuts.swift` |
| **Conflict detection** | `App/Sources/Features/Settings/BusinessLogic/ShortcutConflictDetector.swift` |
| **Cascading reset planner** | `App/Sources/Features/Settings/BusinessLogic/ShortcutResetPlanner.swift` |
| **NSEvent → key token** | `App/Sources/Features/Settings/BusinessLogic/ShortcutKeyTokenResolver.swift` |
| **Settings UI & recorder** | `App/Sources/Features/Settings/Views/ShortcutsSettingsView.swift` |
| **Persistence (GlobalSettings)** | `App/Sources/Features/Settings/Models/GlobalSettings.swift` |
| **Settings reducer** | `App/Sources/Features/Settings/Reducer/SettingsFeature.swift` |
| **App-level resolution & propagation** | `App/Sources/Features/App/Reducer/AppFeature.swift` |
| **SwiftUI environment key** | `App/Sources/App/ResolvedKeybindingsEnvironment.swift` |
| **Ghostty init & keybinding sync** | `App/Sources/App/ProwlApp.swift` |

## How It Works

### Storage

User overrides are stored in `GlobalSettings.keybindingUserOverrides` (`KeybindingUserOverrideStore`), persisted via `@Shared(.settingsFile)`. Each override maps a command ID to an optional `Keybinding` + `isEnabled` flag.

### Resolution (AppFeature)

On settings change, `AppFeature` recomputes `resolvedKeybindings`:

1. Builds schema from `AppShortcuts.bindings` + custom command schemas.
2. Migrates legacy custom command shortcuts via `LegacyCustomCommandShortcutMigration`.
3. Calls `KeybindingResolver.resolve()` with schema, user overrides, and migrated overrides.
4. Filters out app-level shortcuts that conflict with custom commands (custom commands win).
5. Injects result into SwiftUI environment and passes CLI args to Ghostty.

### Recorder UI

`ShortcutsSettingsView` uses `NSEvent.addLocalMonitorForEvents` to capture key-down events. `ShortcutKeyTokenResolver` converts the `NSEvent.keyCode` to a portable key token (e.g., `"a"`, `"digit_1"`, `"arrow_up"`, `"return"`). At least one modifier key is required.

### Conflict Handling

When a new binding is recorded:

1. `ShortcutConflictDetector.firstConflictCommandID()` checks for conflicts (skipped for `disallowUserOverride` policy).
2. If conflict found → alert with Replace / Show Conflict / Cancel.
3. Replace saves new binding AND disables the conflicting command.

### Reset Cascading

When resetting an override back to default:

1. `ShortcutResetPlanner.makePlan()` simulates removal.
2. If the restored default binding conflicts with another override, that override is also queued for reset.
3. Cascades transitively until no conflicts remain.
4. User confirms the full cascade list before reset executes.

### Ghostty Integration

`AppShortcuts.ghosttyCLIKeybindArguments()` generates two kinds of CLI args:

- **Unbind**: `--keybind=KEY+MODIFIERS=unbind` — prevents Ghostty from intercepting app-level shortcuts.
- **Bind**: `--keybind=KEY+MODIFIERS=goto_tab:N` etc. — routes terminal shortcuts through Ghostty.

These args are passed at Ghostty init and re-synced whenever keybindings change.

### Legacy Migration

`LegacyCustomCommandShortcutMigration.migrate(commands:)` converts old `UserCustomCommand.shortcut` to keybinding overrides with ID `custom_command.{commandID}`. Only single-character shortcuts with non-empty IDs are migrated; others are logged as issues.

## Test Coverage

| Test file | Covers |
|-----------|--------|
| `KeybindingSchemaTests.swift` | Schema encode/decode, resolver precedence, migration |
| `KeybindingBehaviorMatrixTests.swift` | Scope × policy × state matrix (defaults, overrides, disable, migration, conflict, reset, persistence) |
| `ShortcutConflictDetectorTests.swift` | Conflict detection across policies |
| `ShortcutResetPlannerTests.swift` | Cascading reset behavior |
| `ShortcutKeyTokenResolverTests.swift` | NSEvent key token parsing |
| `AppShortcutsTests.swift` | Display, Ghostty CLI args, app integration |
| `SettingsFeatureTests.swift` | Keybinding persistence fan-out |

## Adding a New Shortcut

1. Add a new entry in `AppShortcuts.bindings` with command ID, title, scope, and default binding.
2. The schema and resolver pick it up automatically.
3. Use `resolvedKeybindings.keyboardShortcut(for: "your_command_id")` in views.
4. If it's a terminal action, add Ghostty bind args in `ghosttyCLIKeybindArguments()`.
