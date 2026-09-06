import ProwlCLIShared
import Testing

@testable import supacode

struct ShortcutResetPlannerTests {
  @Test func resetPlanCascadesForReplaceEdgeCase() {
    let commandOne = "command.one"
    let commandTwo = "command.two"

    let defaultOne = binding("u")
    let defaultTwo = binding("c")

    let schema = testSchema([
      testCommand(id: commandOne, title: "Command One", defaultBinding: defaultOne),
      testCommand(id: commandTwo, title: "Command Two", defaultBinding: defaultTwo),
    ])

    let overrides = KeybindingUserOverrideStore(
      overrides: [
        commandOne: KeybindingUserOverride(binding: defaultTwo),
        commandTwo: KeybindingUserOverride(binding: nil, isEnabled: false),
      ]
    )

    let plan = ShortcutResetPlanner.makePlan(
      commandID: commandTwo,
      schema: schema,
      userOverrides: overrides
    )

    #expect(plan.conflictingCommandIDs == [commandOne])
    #expect(plan.commandIDsToReset == [commandTwo, commandOne])
    #expect(plan.restoredBinding == defaultTwo)

    let resolvedAfterReset = resolvedAfterApplying(plan: plan, to: overrides, schema: schema)
    #expect(resolvedAfterReset.binding(for: commandOne)?.binding == defaultOne)
    #expect(resolvedAfterReset.binding(for: commandTwo)?.binding == defaultTwo)
    let commandOneBinding = resolvedAfterReset.binding(for: commandOne)?.binding
    let commandTwoBinding = resolvedAfterReset.binding(for: commandTwo)?.binding
    #expect(commandOneBinding != commandTwoBinding)
  }

  @Test func resetPlanCascadesTransitively() {
    let commandOne = "command.one"
    let commandTwo = "command.two"
    let commandThree = "command.three"

    let defaultOne = binding("1")
    let defaultTwo = binding("2")
    let defaultThree = binding("3")

    let schema = testSchema([
      testCommand(id: commandOne, title: "Command One", defaultBinding: defaultOne),
      testCommand(id: commandTwo, title: "Command Two", defaultBinding: defaultTwo),
      testCommand(id: commandThree, title: "Command Three", defaultBinding: defaultThree),
    ])

    let overrides = KeybindingUserOverrideStore(
      overrides: [
        commandOne: KeybindingUserOverride(binding: defaultTwo),
        commandTwo: KeybindingUserOverride(binding: defaultThree),
        commandThree: KeybindingUserOverride(binding: nil, isEnabled: false),
      ]
    )

    let plan = ShortcutResetPlanner.makePlan(
      commandID: commandThree,
      schema: schema,
      userOverrides: overrides
    )

    #expect(plan.conflictingCommandIDs == [commandTwo])
    #expect(plan.commandIDsToReset == [commandThree, commandTwo, commandOne])

    let resolvedAfterReset = resolvedAfterApplying(plan: plan, to: overrides, schema: schema)
    #expect(resolvedAfterReset.binding(for: commandOne)?.binding == defaultOne)
    #expect(resolvedAfterReset.binding(for: commandTwo)?.binding == defaultTwo)
    #expect(resolvedAfterReset.binding(for: commandThree)?.binding == defaultThree)
  }

  @Test func resetPlanDoesNotCascadeWhenNoConflict() {
    let commandOne = "command.one"
    let commandTwo = "command.two"

    let defaultOne = binding("a")
    let defaultTwo = binding("b")
    let custom = binding("z")

    let schema = testSchema([
      testCommand(id: commandOne, title: "Command One", defaultBinding: defaultOne),
      testCommand(id: commandTwo, title: "Command Two", defaultBinding: defaultTwo),
    ])

    let overrides = KeybindingUserOverrideStore(
      overrides: [
        commandOne: KeybindingUserOverride(binding: custom)
      ]
    )

    let plan = ShortcutResetPlanner.makePlan(
      commandID: commandOne,
      schema: schema,
      userOverrides: overrides
    )

    #expect(plan.conflictingCommandIDs.isEmpty)
    #expect(plan.commandIDsToReset == [commandOne])
    #expect(plan.restoredBinding == defaultOne)
  }

  @Test func resetPlanForSectionCascadesAcrossSeeds() {
    let commandOne = "command.one"
    let commandTwo = "command.two"
    let commandThree = "command.three"

    let defaultOne = binding("a")
    let defaultTwo = binding("b")
    let defaultThree = binding("c")

    let schema = testSchema([
      testCommand(id: commandOne, title: "Command One", defaultBinding: defaultOne),
      testCommand(id: commandTwo, title: "Command Two", defaultBinding: defaultTwo),
      testCommand(id: commandThree, title: "Command Three", defaultBinding: defaultThree),
    ])

    let overrides = KeybindingUserOverrideStore(
      overrides: [
        commandOne: KeybindingUserOverride(binding: defaultTwo),
        commandTwo: KeybindingUserOverride(binding: defaultThree),
        commandThree: KeybindingUserOverride(binding: nil, isEnabled: false),
      ]
    )

    let plan = ShortcutResetPlanner.makePlan(
      commandIDs: [commandTwo, commandThree],
      schema: schema,
      userOverrides: overrides
    )

    #expect(plan.restoredBinding == nil)
    #expect(plan.conflictingCommandIDs == [commandOne])
    #expect(plan.commandIDsToReset == [commandTwo, commandThree, commandOne])

    let resolvedAfterReset = resolvedAfterApplying(plan: plan, to: overrides, schema: schema)
    #expect(resolvedAfterReset.binding(for: commandOne)?.binding == defaultOne)
    #expect(resolvedAfterReset.binding(for: commandTwo)?.binding == defaultTwo)
    #expect(resolvedAfterReset.binding(for: commandThree)?.binding == defaultThree)
  }

  private func resolvedAfterApplying(
    plan: ShortcutResetPlan,
    to overrides: KeybindingUserOverrideStore,
    schema: KeybindingSchemaDocument
  ) -> ResolvedKeybindingMap {
    var updated = overrides
    for commandID in plan.commandIDsToReset {
      updated.overrides.removeValue(forKey: commandID)
    }
    return KeybindingResolver.resolve(
      schema: schema,
      userOverrides: updated
    )
  }

  private func testSchema(_ commands: [KeybindingCommandSchema]) -> KeybindingSchemaDocument {
    KeybindingSchemaDocument(
      version: KeybindingSchemaDocument.currentVersion,
      commands: commands
    )
  }

  private func testCommand(
    id: String,
    title: String,
    defaultBinding: Keybinding
  ) -> KeybindingCommandSchema {
    KeybindingCommandSchema(
      id: id,
      title: title,
      scope: .configurableAppAction,
      platform: .macOS,
      allowUserOverride: true,
      conflictPolicy: .warnAndPreferUserOverride,
      defaultBinding: defaultBinding
    )
  }

  private func binding(_ key: String) -> Keybinding {
    Keybinding(
      key: key,
      modifiers: KeybindingModifiers(command: true)
    )
  }
}
