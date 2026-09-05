import Foundation

enum ShortcutConflictDetector {
  static func firstConflictCommandID(
    commandID: String,
    binding: Keybinding,
    policy: KeybindingConflictPolicy,
    schema: KeybindingSchemaDocument,
    userOverrides: KeybindingUserOverrideStore
  ) -> String? {
    guard shouldWarnForConflict(policy: policy) else {
      return nil
    }

    var tentative = userOverrides
    tentative.overrides[commandID] = KeybindingUserOverride(binding: binding)

    let resolved = KeybindingResolver.resolve(
      schema: schema,
      userOverrides: tentative
    )

    for command in schema.commands where command.allowUserOverride && command.id != commandID {
      guard
        resolved.binding(for: command.id)?.binding?.hasSameTrigger(as: binding) == true
      else { continue }
      return command.id
    }

    return nil
  }

  private static func shouldWarnForConflict(policy: KeybindingConflictPolicy) -> Bool {
    switch policy {
    case .warnAndPreferUserOverride, .localOnly:
      return true
    case .disallowUserOverride:
      return false
    }
  }

  static func firstActiveCustomCommandConflict(
    binding: Keybinding,
    customCommands: [EffectiveCustomCommand],
    resolvedKeybindings: ResolvedKeybindingMap
  ) -> EffectiveCustomCommand? {
    customCommands.first { command in
      resolvedKeybindings.keybinding(for: command.keybindingID)?.hasSameTrigger(as: binding) == true
    }
  }
}
