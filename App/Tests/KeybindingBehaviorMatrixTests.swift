import CustomDump
import Foundation
import Testing

@testable import supacode

// MARK: - Behavior matrix tests for the keybinding resolver pipeline.
// Dimensions: scope × conflict-policy × state (default / override / disable / migrate / reset).

struct KeybindingBehaviorMatrixTests {

  // MARK: - Defaults

  @Test func defaultsResolveToAppDefaultForAllScopes() {
    let schema = matrixSchema()
    let resolved = KeybindingResolver.resolve(schema: schema)

    for command in schema.commands {
      let result = resolved.binding(for: command.id)
      #expect(result?.binding == command.defaultBinding)
      #expect(result?.source == .appDefault)
    }
  }

  @Test func defaultsResolveToNilBindingWhenSchemaHasNoDefault() {
    let command = makeCommand(
      id: "cmd.no_default",
      scope: .customCommand,
      policy: .warnAndPreferUserOverride,
      allowOverride: true,
      defaultBinding: nil
    )
    let schema = KeybindingSchemaDocument(commands: [command])
    let resolved = KeybindingResolver.resolve(schema: schema)

    #expect(resolved.binding(for: "cmd.no_default")?.binding == nil)
    #expect(resolved.binding(for: "cmd.no_default")?.source == .appDefault)
  }

  // MARK: - Override enforcement by scope

  @Test func configurableAppActionAcceptsUserOverride() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.configurable",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      )
    ])
    let overrides = overrideStore(["cmd.configurable": .init(binding: binding("z"))])
    let resolved = KeybindingResolver.resolve(schema: schema, userOverrides: overrides)

    #expect(resolved.binding(for: "cmd.configurable")?.binding == binding("z"))
    #expect(resolved.binding(for: "cmd.configurable")?.source == .userOverride)
  }

  @Test func systemFixedAppActionIgnoresUserOverride() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.fixed",
        scope: .systemFixedAppAction,
        policy: .disallowUserOverride,
        allowOverride: false,
        defaultBinding: binding("q")
      )
    ])
    let overrides = overrideStore(["cmd.fixed": .init(binding: binding("z"))])
    let resolved = KeybindingResolver.resolve(schema: schema, userOverrides: overrides)

    #expect(resolved.binding(for: "cmd.fixed")?.binding == binding("q"))
    #expect(resolved.binding(for: "cmd.fixed")?.source == .appDefault)
  }

  @Test func systemFixedAppActionIgnoresMigratedOverride() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.fixed",
        scope: .systemFixedAppAction,
        policy: .disallowUserOverride,
        allowOverride: false,
        defaultBinding: binding("q")
      )
    ])
    let migrated = ["cmd.fixed": KeybindingUserOverride(binding: binding("z"))]
    let resolved = KeybindingResolver.resolve(schema: schema, migratedOverrides: migrated)

    #expect(resolved.binding(for: "cmd.fixed")?.binding == binding("q"))
    #expect(resolved.binding(for: "cmd.fixed")?.source == .appDefault)
  }

  @Test func localInteractionAcceptsUserOverride() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.local",
        scope: .localInteraction,
        policy: .localOnly,
        allowOverride: true,
        defaultBinding: binding("r")
      )
    ])
    let overrides = overrideStore(["cmd.local": .init(binding: binding("t"))])
    let resolved = KeybindingResolver.resolve(schema: schema, userOverrides: overrides)

    #expect(resolved.binding(for: "cmd.local")?.binding == binding("t"))
    #expect(resolved.binding(for: "cmd.local")?.source == .userOverride)
  }

  @Test func customCommandAcceptsUserOverride() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "custom_command.build",
        scope: .customCommand,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: nil
      )
    ])
    let overrides = overrideStore(["custom_command.build": .init(binding: binding("b", shift: true))])
    let resolved = KeybindingResolver.resolve(schema: schema, userOverrides: overrides)

    #expect(resolved.binding(for: "custom_command.build")?.binding == binding("b", shift: true))
    #expect(resolved.binding(for: "custom_command.build")?.source == .userOverride)
  }

  // MARK: - Disable behavior

  @Test func disableOverrideClearsBindingForConfigurableCommand() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.configurable",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      )
    ])
    let overrides = overrideStore(["cmd.configurable": .init(binding: nil, isEnabled: false)])
    let resolved = KeybindingResolver.resolve(schema: schema, userOverrides: overrides)

    #expect(resolved.binding(for: "cmd.configurable")?.binding == nil)
    #expect(resolved.binding(for: "cmd.configurable")?.source == .userOverride)
  }

  @Test func disableOverrideHasNoEffectOnFixedCommand() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.fixed",
        scope: .systemFixedAppAction,
        policy: .disallowUserOverride,
        allowOverride: false,
        defaultBinding: binding("q")
      )
    ])
    let overrides = overrideStore(["cmd.fixed": .init(binding: nil, isEnabled: false)])
    let resolved = KeybindingResolver.resolve(schema: schema, userOverrides: overrides)

    #expect(resolved.binding(for: "cmd.fixed")?.binding == binding("q"))
    #expect(resolved.binding(for: "cmd.fixed")?.source == .appDefault)
  }

  @Test func disableOverrideClearsBindingForLocalInteraction() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.local",
        scope: .localInteraction,
        policy: .localOnly,
        allowOverride: true,
        defaultBinding: binding("r")
      )
    ])
    let overrides = overrideStore(["cmd.local": .init(binding: nil, isEnabled: false)])
    let resolved = KeybindingResolver.resolve(schema: schema, userOverrides: overrides)

    #expect(resolved.binding(for: "cmd.local")?.binding == nil)
    #expect(resolved.binding(for: "cmd.local")?.source == .userOverride)
  }

  // MARK: - Migration precedence

  @Test func migratedOverrideAppliesWhenNoUserOverride() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.alpha",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      )
    ])
    let migrated = ["cmd.alpha": KeybindingUserOverride(binding: binding("m"))]
    let resolved = KeybindingResolver.resolve(schema: schema, migratedOverrides: migrated)

    #expect(resolved.binding(for: "cmd.alpha")?.binding == binding("m"))
    #expect(resolved.binding(for: "cmd.alpha")?.source == .migratedLegacy)
  }

  @Test func userOverrideTakesPrecedenceOverMigratedOverride() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.alpha",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      )
    ])
    let migrated = ["cmd.alpha": KeybindingUserOverride(binding: binding("m"))]
    let overrides = overrideStore(["cmd.alpha": .init(binding: binding("u"))])
    let resolved = KeybindingResolver.resolve(
      schema: schema,
      userOverrides: overrides,
      migratedOverrides: migrated
    )

    #expect(resolved.binding(for: "cmd.alpha")?.binding == binding("u"))
    #expect(resolved.binding(for: "cmd.alpha")?.source == .userOverride)
  }

  @Test func userDisableOverridesMigratedBinding() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.alpha",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      )
    ])
    let migrated = ["cmd.alpha": KeybindingUserOverride(binding: binding("m"))]
    let overrides = overrideStore(["cmd.alpha": .init(binding: nil, isEnabled: false)])
    let resolved = KeybindingResolver.resolve(
      schema: schema,
      userOverrides: overrides,
      migratedOverrides: migrated
    )

    #expect(resolved.binding(for: "cmd.alpha")?.binding == nil)
    #expect(resolved.binding(for: "cmd.alpha")?.source == .userOverride)
  }

  @Test func migratedOverrideDoesNotApplyToFixedScope() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.fixed",
        scope: .systemFixedAppAction,
        policy: .disallowUserOverride,
        allowOverride: false,
        defaultBinding: binding("q")
      )
    ])
    let migrated = ["cmd.fixed": KeybindingUserOverride(binding: binding("m"))]
    let resolved = KeybindingResolver.resolve(schema: schema, migratedOverrides: migrated)

    #expect(resolved.binding(for: "cmd.fixed")?.binding == binding("q"))
    #expect(resolved.binding(for: "cmd.fixed")?.source == .appDefault)
  }

  @Test func migratedSourcePreservedWhenIdenticalToDefault() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.alpha",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      )
    ])
    // Migrated binding is identical to default — source stays appDefault because didChange is false
    let migrated = ["cmd.alpha": KeybindingUserOverride(binding: binding("a"))]
    let resolved = KeybindingResolver.resolve(schema: schema, migratedOverrides: migrated)

    #expect(resolved.binding(for: "cmd.alpha")?.binding == binding("a"))
    #expect(resolved.binding(for: "cmd.alpha")?.source == .appDefault)
  }

  // MARK: - Conflict detection across policies

  @Test func warnPolicyDetectsConflictWithExistingBinding() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.one",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      ),
      makeCommand(
        id: "cmd.two",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("b")
      ),
    ])

    let conflict = ShortcutConflictDetector.firstConflictCommandID(
      commandID: "cmd.two",
      binding: binding("a"),
      policy: .warnAndPreferUserOverride,
      schema: schema,
      userOverrides: .empty
    )

    #expect(conflict == "cmd.one")
  }

  @Test func disallowPolicySkipsConflictDetection() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.one",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      ),
      makeCommand(
        id: "cmd.fixed",
        scope: .systemFixedAppAction,
        policy: .disallowUserOverride,
        allowOverride: false,
        defaultBinding: binding("x")
      ),
    ])

    let conflict = ShortcutConflictDetector.firstConflictCommandID(
      commandID: "cmd.fixed",
      binding: binding("a"),
      policy: .disallowUserOverride,
      schema: schema,
      userOverrides: .empty
    )

    #expect(conflict == nil)
  }

  @Test func localOnlyPolicyDetectsConflictWithAppAction() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.global",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      ),
      makeCommand(
        id: "cmd.local",
        scope: .localInteraction,
        policy: .localOnly,
        allowOverride: true,
        defaultBinding: binding("b")
      ),
    ])

    let conflict = ShortcutConflictDetector.firstConflictCommandID(
      commandID: "cmd.local",
      binding: binding("a"),
      policy: .localOnly,
      schema: schema,
      userOverrides: .empty
    )

    #expect(conflict == "cmd.global")
  }

  @Test func noConflictWhenBindingsAreDifferent() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.one",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      ),
      makeCommand(
        id: "cmd.two",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("b")
      ),
    ])

    let conflict = ShortcutConflictDetector.firstConflictCommandID(
      commandID: "cmd.two",
      binding: binding("c"),
      policy: .warnAndPreferUserOverride,
      schema: schema,
      userOverrides: .empty
    )

    #expect(conflict == nil)
  }

  @Test func conflictDetectionConsidersUserOverridesNotJustDefaults() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.one",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      ),
      makeCommand(
        id: "cmd.two",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("b")
      ),
    ])
    // cmd.one was overridden to "z" — so assigning "z" to cmd.two should conflict
    let overrides = overrideStore(["cmd.one": .init(binding: binding("z"))])

    let conflict = ShortcutConflictDetector.firstConflictCommandID(
      commandID: "cmd.two",
      binding: binding("z"),
      policy: .warnAndPreferUserOverride,
      schema: schema,
      userOverrides: overrides
    )

    #expect(conflict == "cmd.one")
  }

  @Test func noConflictWithDisabledCommand() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.one",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      ),
      makeCommand(
        id: "cmd.two",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("b")
      ),
    ])
    // cmd.one was disabled — its binding is gone, so "a" is now free
    let overrides = overrideStore(["cmd.one": .init(binding: nil, isEnabled: false)])

    let conflict = ShortcutConflictDetector.firstConflictCommandID(
      commandID: "cmd.two",
      binding: binding("a"),
      policy: .warnAndPreferUserOverride,
      schema: schema,
      userOverrides: overrides
    )

    #expect(conflict == nil)
  }

  // MARK: - Reset behavior

  @Test func resetSingleCommandRestoresDefault() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.one",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      )
    ])
    let overrides = overrideStore(["cmd.one": .init(binding: binding("z"))])

    let plan = ShortcutResetPlanner.makePlan(
      commandID: "cmd.one",
      schema: schema,
      userOverrides: overrides
    )

    #expect(plan.commandIDsToReset == ["cmd.one"])
    #expect(plan.conflictingCommandIDs.isEmpty)
    #expect(plan.restoredBinding == binding("a"))

    let resolved = resolvedAfterReset(plan: plan, overrides: overrides, schema: schema)
    #expect(resolved.binding(for: "cmd.one")?.binding == binding("a"))
    #expect(resolved.binding(for: "cmd.one")?.source == .appDefault)
  }

  @Test func resetCascadesWhenRestoredDefaultConflicts() {
    // cmd.one default=a, overridden to b
    // cmd.two default=b, disabled (because cmd.one took b)
    // Resetting cmd.two restores b, which conflicts with cmd.one's override → cascade
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.one",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      ),
      makeCommand(
        id: "cmd.two",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("b")
      ),
    ])
    let overrides = overrideStore([
      "cmd.one": .init(binding: binding("b")),
      "cmd.two": .init(binding: nil, isEnabled: false),
    ])

    let plan = ShortcutResetPlanner.makePlan(
      commandID: "cmd.two",
      schema: schema,
      userOverrides: overrides
    )

    #expect(plan.commandIDsToReset.contains("cmd.one"))
    #expect(plan.commandIDsToReset.contains("cmd.two"))
    #expect(plan.conflictingCommandIDs == ["cmd.one"])

    let resolved = resolvedAfterReset(plan: plan, overrides: overrides, schema: schema)
    #expect(resolved.binding(for: "cmd.one")?.binding == binding("a"))
    #expect(resolved.binding(for: "cmd.two")?.binding == binding("b"))
  }

  @Test func resetAllCommandsInSectionCascadesOutside() {
    // Section contains cmd.two and cmd.three
    // cmd.one (outside section) overrides to cmd.two's default
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.one",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      ),
      makeCommand(
        id: "cmd.two",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("b")
      ),
      makeCommand(
        id: "cmd.three",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("c")
      ),
    ])
    let overrides = overrideStore([
      "cmd.one": .init(binding: binding("b")),
      "cmd.two": .init(binding: nil, isEnabled: false),
      "cmd.three": .init(binding: binding("x")),
    ])

    let plan = ShortcutResetPlanner.makePlan(
      commandIDs: ["cmd.two", "cmd.three"],
      schema: schema,
      userOverrides: overrides
    )

    #expect(plan.commandIDsToReset.contains("cmd.one"))
    #expect(plan.conflictingCommandIDs == ["cmd.one"])

    let resolved = resolvedAfterReset(plan: plan, overrides: overrides, schema: schema)
    #expect(resolved.binding(for: "cmd.one")?.binding == binding("a"))
    #expect(resolved.binding(for: "cmd.two")?.binding == binding("b"))
    #expect(resolved.binding(for: "cmd.three")?.binding == binding("c"))
  }

  // MARK: - Persistence round-trip

  @Test func userOverrideStoreEncodeDecodeRoundTrip() throws {
    let store = KeybindingUserOverrideStore(
      version: 1,
      overrides: [
        "cmd.alpha": KeybindingUserOverride(binding: binding("x"), isEnabled: true),
        "cmd.beta": KeybindingUserOverride(binding: nil, isEnabled: false),
        "cmd.gamma": KeybindingUserOverride(
          binding: Keybinding(
            key: "arrow_up",
            modifiers: KeybindingModifiers(command: true, shift: true)
          )
        ),
      ]
    )

    let data = try JSONEncoder().encode(store)
    let decoded = try JSONDecoder().decode(KeybindingUserOverrideStore.self, from: data)

    expectNoDifference(decoded, store)
  }

  @Test func resolvedStateIsIdenticalAfterPersistenceRoundTrip() throws {
    let schema = matrixSchema()
    let overrides = KeybindingUserOverrideStore(
      version: 1,
      overrides: [
        "cmd.configurable": KeybindingUserOverride(binding: binding("z")),
        "cmd.local": KeybindingUserOverride(binding: nil, isEnabled: false),
      ]
    )

    let resolvedBefore = KeybindingResolver.resolve(schema: schema, userOverrides: overrides)

    let data = try JSONEncoder().encode(overrides)
    let restored = try JSONDecoder().decode(KeybindingUserOverrideStore.self, from: data)
    let resolvedAfter = KeybindingResolver.resolve(schema: schema, userOverrides: restored)

    expectNoDifference(resolvedAfter, resolvedBefore)
  }

  // MARK: - Edge cases

  @Test func overrideForUnknownCommandIDIsIgnored() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.one",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      )
    ])
    let overrides = overrideStore(["cmd.nonexistent": .init(binding: binding("z"))])
    let resolved = KeybindingResolver.resolve(schema: schema, userOverrides: overrides)

    #expect(resolved.binding(for: "cmd.one")?.binding == binding("a"))
    #expect(resolved.binding(for: "cmd.one")?.source == .appDefault)
    #expect(resolved.binding(for: "cmd.nonexistent") == nil)
  }

  @Test func enabledOverrideWithNilBindingPreservesDefault() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.one",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      )
    ])
    // isEnabled=true but binding=nil → no change, preserves default
    let overrides = overrideStore(["cmd.one": .init(binding: nil, isEnabled: true)])
    let resolved = KeybindingResolver.resolve(schema: schema, userOverrides: overrides)

    #expect(resolved.binding(for: "cmd.one")?.binding == binding("a"))
    #expect(resolved.binding(for: "cmd.one")?.source == .appDefault)
  }

  @Test func multipleCommandsWithSameDefaultBindingResolveIndependently() {
    let schema = KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.one",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      ),
      makeCommand(
        id: "cmd.two",
        scope: .localInteraction,
        policy: .localOnly,
        allowOverride: true,
        defaultBinding: binding("a")
      ),
    ])
    let resolved = KeybindingResolver.resolve(schema: schema)

    #expect(resolved.binding(for: "cmd.one")?.binding == binding("a"))
    #expect(resolved.binding(for: "cmd.two")?.binding == binding("a"))
    #expect(resolved.binding(for: "cmd.one")?.source == .appDefault)
    #expect(resolved.binding(for: "cmd.two")?.source == .appDefault)
  }
}

// MARK: - Helpers

extension KeybindingBehaviorMatrixTests {

  /// A schema covering all four scopes with representative conflict policies.
  private func matrixSchema() -> KeybindingSchemaDocument {
    KeybindingSchemaDocument(commands: [
      makeCommand(
        id: "cmd.configurable",
        scope: .configurableAppAction,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: binding("a")
      ),
      makeCommand(
        id: "cmd.fixed",
        scope: .systemFixedAppAction,
        policy: .disallowUserOverride,
        allowOverride: false,
        defaultBinding: binding("q")
      ),
      makeCommand(
        id: "cmd.local",
        scope: .localInteraction,
        policy: .localOnly,
        allowOverride: true,
        defaultBinding: binding("r")
      ),
      makeCommand(
        id: "custom_command.build",
        scope: .customCommand,
        policy: .warnAndPreferUserOverride,
        allowOverride: true,
        defaultBinding: nil
      ),
    ])
  }

  private func makeCommand(
    id: String,
    scope: KeybindingScope,
    policy: KeybindingConflictPolicy,
    allowOverride: Bool,
    defaultBinding: Keybinding?
  ) -> KeybindingCommandSchema {
    KeybindingCommandSchema(
      id: id,
      title: id,
      scope: scope,
      platform: .macOS,
      allowUserOverride: allowOverride,
      conflictPolicy: policy,
      defaultBinding: defaultBinding
    )
  }

  private func binding(_ key: String, shift: Bool = false) -> Keybinding {
    Keybinding(key: key, modifiers: KeybindingModifiers(command: true, shift: shift))
  }

  private func overrideStore(_ overrides: [String: KeybindingUserOverride]) -> KeybindingUserOverrideStore {
    KeybindingUserOverrideStore(overrides: overrides)
  }

  private func resolvedAfterReset(
    plan: ShortcutResetPlan,
    overrides: KeybindingUserOverrideStore,
    schema: KeybindingSchemaDocument
  ) -> ResolvedKeybindingMap {
    var updated = overrides
    for commandID in plan.commandIDsToReset {
      updated.overrides.removeValue(forKey: commandID)
    }
    return KeybindingResolver.resolve(schema: schema, userOverrides: updated)
  }
}
