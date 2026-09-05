import Foundation
import SwiftUI

nonisolated enum KeybindingPlatform: String, Codable, Equatable, Sendable {
  case macOS
}

nonisolated enum KeybindingScope: String, Codable, Equatable, Sendable {
  case configurableAppAction
  case systemFixedAppAction
  case localInteraction
  case customCommand
}

nonisolated enum KeybindingConflictPolicy: String, Codable, Equatable, Sendable {
  case warnAndPreferUserOverride
  case disallowUserOverride
  case localOnly
}

nonisolated enum KeybindingSource: String, Equatable, Sendable {
  case appDefault
  case migratedLegacy
  case userOverride
}

nonisolated struct KeybindingModifiers: Codable, Equatable, Sendable {
  var command: Bool
  var shift: Bool
  var option: Bool
  var control: Bool

  init(command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
    self.command = command
    self.shift = shift
    self.option = option
    self.control = control
  }

  var isEmpty: Bool {
    !command && !shift && !option && !control
  }

  var eventModifiers: EventModifiers {
    var value: EventModifiers = []
    if command {
      value.insert(.command)
    }
    if shift {
      value.insert(.shift)
    }
    if option {
      value.insert(.option)
    }
    if control {
      value.insert(.control)
    }
    return value
  }
}

nonisolated struct Keybinding: Codable, Equatable, Sendable {
  var key: String
  var modifiers: KeybindingModifiers

  init(key: String, modifiers: KeybindingModifiers) {
    self.key = Self.normalizeKey(key)
    self.modifiers = modifiers
  }

  var isValid: Bool {
    !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var display: String {
    var symbols: [String] = []
    if modifiers.command {
      symbols.append("⌘")
    }
    if modifiers.shift {
      symbols.append("⇧")
    }
    if modifiers.option {
      symbols.append("⌥")
    }
    if modifiers.control {
      symbols.append("⌃")
    }

    symbols.append(Self.displayKey(for: key))
    return symbols.joined()
  }

  private static func normalizeKey(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func displayKey(for key: String) -> String {
    switch key {
    case "return":
      return "↩"
    case "arrow_up":
      return "↑"
    case "arrow_down":
      return "↓"
    case "arrow_left":
      return "←"
    case "arrow_right":
      return "→"
    default:
      if let digitCharacter = physicalDigitCharacter(for: key) {
        return String(digitCharacter)
      }
      return key.uppercased()
    }
  }

  private static func physicalDigitCharacter(for key: String) -> Character? {
    guard key.hasPrefix("digit_") else { return nil }
    let value = key.dropFirst("digit_".count)
    guard value.count == 1, let character = value.first, character.isNumber else { return nil }
    return character
  }
}

/// Versioned command schema for keybinding definitions.
///
/// `version` only tracks schema structure/versioning of this data model,
/// not the release version of the app.
nonisolated struct KeybindingSchemaDocument: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version: Int
  var commands: [KeybindingCommandSchema]

  init(version: Int = currentVersion, commands: [KeybindingCommandSchema]) {
    self.version = version
    self.commands = commands
  }
}

nonisolated struct KeybindingCommandSchema: Codable, Equatable, Sendable {
  var id: String
  var title: String
  var scope: KeybindingScope
  var platform: KeybindingPlatform
  var allowUserOverride: Bool
  var conflictPolicy: KeybindingConflictPolicy
  var defaultBinding: Keybinding?
}

nonisolated struct KeybindingUserOverrideStore: Codable, Equatable, Sendable {
  static let empty = KeybindingUserOverrideStore(version: KeybindingSchemaDocument.currentVersion, overrides: [:])

  var version: Int
  var overrides: [String: KeybindingUserOverride]

  init(version: Int = KeybindingSchemaDocument.currentVersion, overrides: [String: KeybindingUserOverride]) {
    self.version = version
    self.overrides = overrides
  }
}

nonisolated struct KeybindingUserOverride: Codable, Equatable, Sendable {
  var binding: Keybinding?
  var isEnabled: Bool

  init(binding: Keybinding?, isEnabled: Bool = true) {
    self.binding = binding
    self.isEnabled = isEnabled
  }
}

nonisolated struct ResolvedKeybinding: Equatable, Sendable {
  var command: KeybindingCommandSchema
  var binding: Keybinding?
  var source: KeybindingSource
}

nonisolated struct ResolvedKeybindingMap: Equatable, Sendable {
  var bindingsByCommandID: [String: ResolvedKeybinding]

  func binding(for commandID: String) -> ResolvedKeybinding? {
    bindingsByCommandID[commandID]
  }
}

extension ResolvedKeybindingMap {
  static let appDefaults = KeybindingResolver.resolve(schema: .appResolverSchema())

  func keybinding(for commandID: String) -> Keybinding? {
    binding(for: commandID)?.binding
  }

  func appShortcut(for commandID: String) -> AppShortcut? {
    keybinding(for: commandID)?.appShortcut
  }

  func keyboardShortcut(for commandID: String) -> KeyboardShortcut? {
    keybinding(for: commandID)?.keyboardShortcut
  }

  func display(for commandID: String) -> String? {
    keybinding(for: commandID)?.display
  }
}

nonisolated enum KeybindingResolver {
  static func resolve(
    schema: KeybindingSchemaDocument,
    userOverrides: KeybindingUserOverrideStore = .empty,
    migratedOverrides: [String: KeybindingUserOverride] = [:]
  ) -> ResolvedKeybindingMap {
    var result: [String: ResolvedKeybinding] = [:]

    for command in schema.commands {
      var resolvedBinding = command.defaultBinding
      var source: KeybindingSource = .appDefault

      if command.allowUserOverride {
        if let migrated = migratedOverrides[command.id] {
          let applied = apply(override: migrated, currentBinding: resolvedBinding)
          resolvedBinding = applied.binding
          if applied.didChange {
            source = .migratedLegacy
          }
        }

        if let user = userOverrides.overrides[command.id] {
          let applied = apply(override: user, currentBinding: resolvedBinding)
          resolvedBinding = applied.binding
          if applied.didChange {
            source = .userOverride
          }
        }
      }

      result[command.id] = ResolvedKeybinding(
        command: command,
        binding: resolvedBinding,
        source: source
      )
    }

    return ResolvedKeybindingMap(bindingsByCommandID: result)
  }

  private static func apply(
    override: KeybindingUserOverride,
    currentBinding: Keybinding?
  ) -> (binding: Keybinding?, didChange: Bool) {
    if !override.isEnabled {
      return (nil, currentBinding != nil)
    }

    guard let binding = override.binding else {
      return (currentBinding, false)
    }

    return (binding, currentBinding != binding)
  }
}

nonisolated struct KeybindingMigrationIssue: Equatable, Sendable {
  nonisolated enum Reason: Equatable, Sendable {
    case missingCommandID
    case invalidShortcut
  }

  var commandTitle: String
  var reason: Reason
  var debugDescription: String
}

nonisolated struct KeybindingMigrationResult: Equatable, Sendable {
  var overrides: [String: KeybindingUserOverride]
  var issues: [KeybindingMigrationIssue]

  var migratedCount: Int {
    overrides.count
  }
}

nonisolated enum LegacyCustomCommandShortcutMigration {
  private static let logger = SupaLogger("Shortcuts")

  static func migrate(commands: [UserCustomCommand]) -> KeybindingMigrationResult {
    migrate(commands: commands.map { EffectiveCustomCommand(source: .repository, command: $0) })
  }

  static func migrate(commands: [EffectiveCustomCommand]) -> KeybindingMigrationResult {
    var overrides: [String: KeybindingUserOverride] = [:]
    var issues: [KeybindingMigrationIssue] = []

    for effectiveCommand in commands {
      let command = effectiveCommand.command
      let commandID = command.id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !commandID.isEmpty else {
        let issue = KeybindingMigrationIssue(
          commandTitle: command.resolvedTitle,
          reason: .missingCommandID,
          debugDescription: "Custom command has an empty id."
        )
        issues.append(issue)
        logger.warning(
          "shortcut_migration status=unmapped reason=missingCommandID title=\(command.resolvedTitle)"
        )
        continue
      }

      guard let rawShortcut = command.shortcut else {
        continue
      }

      guard rawShortcut.isValid else {
        let issue = KeybindingMigrationIssue(
          commandTitle: command.resolvedTitle,
          reason: .invalidShortcut,
          debugDescription: "Shortcut key must be exactly one character."
        )
        issues.append(issue)
        logger.warning(
          "shortcut_migration status=unmapped reason=invalidShortcut title=\(command.resolvedTitle)"
        )
        continue
      }

      let shortcut = rawShortcut.normalized()
      let binding = Keybinding(
        key: shortcut.key,
        modifiers: .init(shortcut.modifiers)
      )
      overrides[customCommandBindingID(for: commandID, source: effectiveCommand.source)] = KeybindingUserOverride(
        binding: binding
      )
    }

    return KeybindingMigrationResult(overrides: overrides, issues: issues)
  }

  static func customCommandBindingID(
    for commandID: String,
    source: CustomCommandSource = .repository
  ) -> String {
    switch source {
    case .repository: "custom_command.\(commandID)"
    case .global: "custom_command.global.\(commandID)"
    }
  }
}

extension KeybindingModifiers {
  nonisolated init(_ userModifiers: UserCustomShortcutModifiers) {
    self.init(
      command: userModifiers.command,
      shift: userModifiers.shift,
      option: userModifiers.option,
      control: userModifiers.control
    )
  }

  nonisolated init(_ eventModifiers: EventModifiers) {
    self.init(
      command: eventModifiers.contains(.command),
      shift: eventModifiers.contains(.shift),
      option: eventModifiers.contains(.option),
      control: eventModifiers.contains(.control)
    )
  }
}

extension KeybindingScope {
  init(_ scope: AppShortcuts.Scope) {
    switch scope {
    case .configurableAppAction:
      self = .configurableAppAction
    case .systemFixedAppAction:
      self = .systemFixedAppAction
    case .localInteraction:
      self = .localInteraction
    }
  }
}

extension KeybindingSchemaDocument {
  static var appDefaultsV1: KeybindingSchemaDocument {
    KeybindingSchemaDocument(
      version: currentVersion,
      commands: AppShortcuts.bindings.map { binding in
        KeybindingCommandSchema(
          id: binding.id,
          title: binding.title,
          scope: .init(binding.scope),
          platform: .macOS,
          allowUserOverride: binding.scope != .systemFixedAppAction,
          conflictPolicy: binding.scope.conflictPolicy,
          defaultBinding: binding.shortcut?.keybinding
        )
      }
    )
  }

  static func appResolverSchema(customCommands: [UserCustomCommand] = []) -> KeybindingSchemaDocument {
    appResolverSchema(
      effectiveCustomCommands: customCommands.map { EffectiveCustomCommand(source: .repository, command: $0) }
    )
  }

  static func appResolverSchema(
    effectiveCustomCommands: [EffectiveCustomCommand]
  ) -> KeybindingSchemaDocument {
    KeybindingSchemaDocument(
      version: currentVersion,
      commands: appDefaultsV1.commands + effectiveCustomCommands.map(\.keybindingCommandSchema)
    )
  }
}

extension AppShortcuts.Scope {
  fileprivate var conflictPolicy: KeybindingConflictPolicy {
    switch self {
    case .configurableAppAction:
      return .warnAndPreferUserOverride
    case .systemFixedAppAction:
      return .disallowUserOverride
    case .localInteraction:
      return .localOnly
    }
  }
}

extension AppShortcut {
  fileprivate var keybinding: Keybinding {
    Keybinding(key: keyToken, modifiers: .init(modifiers))
  }
}

extension EffectiveCustomCommand {
  fileprivate var keybindingCommandSchema: KeybindingCommandSchema {
    KeybindingCommandSchema(
      id: keybindingID,
      title: command.resolvedTitle,
      scope: .customCommand,
      platform: .macOS,
      allowUserOverride: true,
      conflictPolicy: .warnAndPreferUserOverride,
      defaultBinding: nil
    )
  }
}

extension Keybinding {
  /// Compares the physical shortcut a user invokes rather than its persisted token spelling.
  /// Recorders keep digits as `digit_N`, while Custom Commands store the same key as `N`.
  func hasSameTrigger(as other: Self) -> Bool {
    modifiers == other.modifiers && normalizedTriggerKey == other.normalizedTriggerKey
  }

  private var normalizedTriggerKey: String {
    physicalDigitCharacter.map(String.init) ?? key
  }

  var keyEquivalent: KeyEquivalent? {
    if let specialKeyEquivalent {
      return specialKeyEquivalent
    }
    if let singleCharacter {
      return KeyEquivalent(singleCharacter)
    }
    if let physicalDigitCharacter {
      return KeyEquivalent(physicalDigitCharacter)
    }
    return nil
  }

  var keyboardShortcut: KeyboardShortcut? {
    guard let keyEquivalent else { return nil }
    return KeyboardShortcut(keyEquivalent, modifiers: modifiers.eventModifiers)
  }

  var appShortcut: AppShortcut? {
    if let specialKeyEquivalent {
      return AppShortcut(
        keyEquivalent: specialKeyEquivalent,
        ghosttyKeyName: key,
        modifiers: modifiers.eventModifiers
      )
    }
    if let singleCharacter {
      return AppShortcut(key: singleCharacter, modifiers: modifiers.eventModifiers)
    }
    if let physicalDigitCharacter {
      return AppShortcut(key: physicalDigitCharacter, modifiers: modifiers.eventModifiers)
    }
    return nil
  }

  var userCustomShortcut: UserCustomShortcut? {
    if key.count == 1 {
      return UserCustomShortcut(key: key, modifiers: .init(modifiers))
    }
    if let physicalDigitCharacter {
      return UserCustomShortcut(key: String(physicalDigitCharacter), modifiers: .init(modifiers))
    }
    return nil
  }

  private var specialKeyEquivalent: KeyEquivalent? {
    switch key {
    case "return":
      return .return
    case "arrow_up":
      return .upArrow
    case "arrow_down":
      return .downArrow
    case "arrow_left":
      return .leftArrow
    case "arrow_right":
      return .rightArrow
    default:
      return nil
    }
  }

  private var singleCharacter: Character? {
    guard key.count == 1 else { return nil }
    return key.first
  }

  private var physicalDigitCharacter: Character? {
    guard key.hasPrefix("digit_") else { return nil }
    let value = key.dropFirst("digit_".count)
    guard value.count == 1, let character = value.first, character.isNumber else { return nil }
    return character
  }
}

extension UserCustomShortcutModifiers {
  nonisolated init(_ modifiers: KeybindingModifiers) {
    self.init(
      command: modifiers.command,
      shift: modifiers.shift,
      option: modifiers.option,
      control: modifiers.control
    )
  }
}
