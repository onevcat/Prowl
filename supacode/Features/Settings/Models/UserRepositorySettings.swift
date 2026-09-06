import Foundation
import ProwlCLIShared

nonisolated struct UserRepositorySettings: Codable, Equatable, Sendable {
  var customCommands: [UserCustomCommand]
  var disabledGlobalCommandIDs: Set<UserCustomCommand.ID>
  /// Explicit per-repo Default Agent Profile designation (docs-ai 053).
  var defaultAgentProfileID: UUID?
  /// Per-repo launch memory: the last explicitly launched profile. One tier
  /// below the designation in the Recommended resolution. Dangling references
  /// are skipped at resolution time, not scrubbed here: this store cannot see
  /// the global profile list.
  var lastLaunchedAgentProfileID: UUID?

  static let `default` = UserRepositorySettings(customCommands: [])

  private enum CodingKeys: String, CodingKey {
    case customCommands
    case disabledGlobalCommandIDs
    case defaultAgentProfileID
    case lastLaunchedAgentProfileID
  }

  init(
    customCommands: [UserCustomCommand],
    disabledGlobalCommandIDs: Set<UserCustomCommand.ID> = [],
    defaultAgentProfileID: UUID? = nil,
    lastLaunchedAgentProfileID: UUID? = nil
  ) {
    self.customCommands = Self.normalizedCommands(customCommands)
    self.disabledGlobalCommandIDs = disabledGlobalCommandIDs
    self.defaultAgentProfileID = defaultAgentProfileID
    self.lastLaunchedAgentProfileID = lastLaunchedAgentProfileID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let commands = try container.decodeIfPresent([UserCustomCommand].self, forKey: .customCommands) ?? []
    customCommands = Self.normalizedCommands(commands)
    disabledGlobalCommandIDs =
      try container.decodeIfPresent(Set<UserCustomCommand.ID>.self, forKey: .disabledGlobalCommandIDs) ?? []
    defaultAgentProfileID = try container.decodeIfPresent(UUID.self, forKey: .defaultAgentProfileID)
    lastLaunchedAgentProfileID =
      try container.decodeIfPresent(UUID.self, forKey: .lastLaunchedAgentProfileID)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(customCommands, forKey: .customCommands)
    try container.encode(disabledGlobalCommandIDs.sorted(), forKey: .disabledGlobalCommandIDs)
    try container.encodeIfPresent(defaultAgentProfileID, forKey: .defaultAgentProfileID)
    try container.encodeIfPresent(lastLaunchedAgentProfileID, forKey: .lastLaunchedAgentProfileID)
  }

  func normalized() -> UserRepositorySettings {
    UserRepositorySettings(
      customCommands: customCommands,
      disabledGlobalCommandIDs: disabledGlobalCommandIDs,
      defaultAgentProfileID: defaultAgentProfileID,
      lastLaunchedAgentProfileID: lastLaunchedAgentProfileID
    )
  }

  static func normalizedCommands(_ commands: [UserCustomCommand]) -> [UserCustomCommand] {
    UserCustomCommand.normalizedCommands(commands)
  }

  func isGlobalCommandEnabled(_ id: UserCustomCommand.ID) -> Bool {
    !disabledGlobalCommandIDs.contains(id)
  }

  mutating func setGlobalCommandEnabled(_ isEnabled: Bool, id: UserCustomCommand.ID) {
    if isEnabled {
      disabledGlobalCommandIDs.remove(id)
    } else {
      disabledGlobalCommandIDs.insert(id)
    }
  }
}

nonisolated struct UserCustomCommand: Codable, Equatable, Sendable, Identifiable {
  var id: String
  var title: String
  var systemImage: String
  var command: String
  var execution: UserCustomCommandExecution
  var splitDirection: UserCustomSplitDirection
  var closeOnSuccess: Bool
  var shortcut: UserCustomShortcut?
  var isEnabled: Bool

  init(
    id: String = UUID().uuidString,
    title: String,
    systemImage: String,
    command: String,
    execution: UserCustomCommandExecution,
    splitDirection: UserCustomSplitDirection = .right,
    closeOnSuccess: Bool = false,
    shortcut: UserCustomShortcut?,
    isEnabled: Bool = true
  ) {
    self.id = id
    self.title = title
    self.systemImage = systemImage
    self.command = command
    self.execution = execution
    self.splitDirection = splitDirection
    self.closeOnSuccess = closeOnSuccess
    self.shortcut = shortcut?.normalized()
    self.isEnabled = isEnabled
  }
  private enum CodingKeys: String, CodingKey {
    case id, title, systemImage, command, execution, splitDirection, closeOnSuccess, shortcut, isEnabled
  }
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.title = try container.decode(String.self, forKey: .title)
    self.systemImage = try container.decode(String.self, forKey: .systemImage)
    self.command = try container.decode(String.self, forKey: .command)
    self.execution = try container.decode(UserCustomCommandExecution.self, forKey: .execution)
    self.splitDirection =
      try container.decodeIfPresent(UserCustomSplitDirection.self, forKey: .splitDirection) ?? .right
    self.closeOnSuccess = try container.decodeIfPresent(Bool.self, forKey: .closeOnSuccess) ?? false
    // Preserves raw shortcut so downstream migration/validation can inspect the original key.
    self.shortcut = try container.decodeIfPresent(UserCustomShortcut.self, forKey: .shortcut)
    self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
  }

  static func `default`(index: Int) -> UserCustomCommand {
    UserCustomCommand(
      title: "Command \(index + 1)",
      systemImage: "terminal",
      command: "",
      execution: .shellScript,
      shortcut: nil
    )
  }

  func normalized() -> UserCustomCommand {
    UserCustomCommand(
      id: id,
      title: title,
      systemImage: systemImage,
      command: command,
      execution: execution,
      splitDirection: splitDirection,
      closeOnSuccess: closeOnSuccess,
      shortcut: shortcut?.normalized(),
      isEnabled: isEnabled
    )
  }
  static func normalizedCommands(_ commands: [UserCustomCommand]) -> [UserCustomCommand] {
    commands.map { $0.normalized() }
  }

  var resolvedTitle: String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return "Command"
    }
    return trimmed
  }

  var resolvedSystemImage: String {
    let trimmed = systemImage.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return "terminal"
    }
    return trimmed
  }

  var hasRunnableCommand: Bool {
    !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

nonisolated enum CustomCommandSource: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case repository
  case global

  var displayTitle: String {
    switch self {
    case .repository: "Local"
    case .global: "Global"
    }
  }

  /// Extra sentence appended to hover tooltips; global commands are only
  /// distinguished there so toolbar buttons stay visually uniform.
  var tooltipNote: String? {
    switch self {
    case .repository: nil
    case .global: "Defined as a global command"
    }
  }
}

nonisolated struct EffectiveCustomCommand: Equatable, Sendable, Identifiable {
  nonisolated struct Identifier: Hashable, Sendable {
    let source: CustomCommandSource
    let commandID: UserCustomCommand.ID
  }

  let source: CustomCommandSource
  let command: UserCustomCommand

  var id: Identifier { Identifier(source: source, commandID: command.id) }

  var keybindingID: String {
    LegacyCustomCommandShortcutMigration.customCommandBindingID(for: command.id, source: source)
  }

  /// Repository commands keep the pre-global `custom-command.<id>` form so
  /// persisted palette recency survives; globals get their own namespace,
  /// mirroring the keybinding ID scheme.
  var paletteID: String {
    switch source {
    case .repository: "custom-command.\(command.id)"
    case .global: "custom-command.global.\(command.id)"
    }
  }

  static func resolve(
    repositoryCommands: [UserCustomCommand],
    globalCommands: [UserCustomCommand],
    disabledGlobalCommandIDs: Set<UserCustomCommand.ID> = []
  ) -> [EffectiveCustomCommand] {
    UserCustomCommand.normalizedCommands(repositoryCommands)
      .filter(\.isEnabled)
      .map { .init(source: .repository, command: $0) }
      + UserCustomCommand.normalizedCommands(globalCommands)
      .filter { $0.isEnabled && !disabledGlobalCommandIDs.contains($0.id) }
      .map { .init(source: .global, command: $0) }
  }
}

nonisolated enum UserCustomCommandExecution: String, Codable, CaseIterable, Identifiable, Sendable {
  case shellScript
  case terminalInput
  case split

  var id: String { rawValue }

  var title: String {
    switch self {
    case .shellScript:
      return "New Tab"
    case .terminalInput:
      return "In Place"
    case .split:
      return "New Split"
    }
  }

  var supportsCloseOnSuccess: Bool {
    switch self {
    case .shellScript, .split:
      return true
    case .terminalInput:
      return false
    }
  }
}

nonisolated enum UserCustomSplitDirection: String, Codable, CaseIterable, Identifiable, Sendable {
  case right
  case left
  case down
  case top

  var id: String { rawValue }

  var title: String {
    switch self {
    case .right: return "Right"
    case .left: return "Left"
    case .down: return "Down"
    case .top: return "Up"
    }
  }
}

nonisolated struct UserCustomShortcut: Codable, Equatable, Sendable {
  var key: String
  var modifiers: UserCustomShortcutModifiers

  init(key: String, modifiers: UserCustomShortcutModifiers) {
    self.key = key
    self.modifiers = modifiers
  }

  func normalized() -> UserCustomShortcut {
    let scalar = key.trimmingCharacters(in: .whitespacesAndNewlines).first
    return UserCustomShortcut(
      key: scalar.map { String($0).lowercased() } ?? "",
      modifiers: modifiers
    )
  }

  var isValid: Bool {
    let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalizedKey.count == 1
  }

  var display: String {
    var parts: [String] = []
    if modifiers.command { parts.append("⌘") }
    if modifiers.shift { parts.append("⇧") }
    if modifiers.option { parts.append("⌥") }
    if modifiers.control { parts.append("⌃") }
    parts.append(key.uppercased())
    return parts.joined()
  }
}

nonisolated struct UserCustomShortcutModifiers: Codable, Equatable, Sendable {
  var command: Bool
  var shift: Bool
  var option: Bool
  var control: Bool

  init(command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) {
    self.command = command
    self.shift = shift
    self.option = option
    self.control = control
  }

  var isEmpty: Bool {
    !command && !shift && !option && !control
  }
}
