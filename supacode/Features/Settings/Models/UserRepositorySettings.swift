import Foundation

nonisolated struct UserRepositorySettings: Codable, Equatable, Sendable {
  var customCommands: [UserCustomCommand]

  static let `default` = UserRepositorySettings(customCommands: [])

  private enum CodingKeys: String, CodingKey {
    case customCommands
  }

  init(customCommands: [UserCustomCommand]) {
    self.customCommands = Self.normalizedCommands(customCommands)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let commands = try container.decodeIfPresent([UserCustomCommand].self, forKey: .customCommands) ?? []
    customCommands = Self.normalizedCommands(commands)
  }

  func normalized() -> UserRepositorySettings {
    UserRepositorySettings(customCommands: customCommands)
  }

  static func normalizedCommands(_ commands: [UserCustomCommand]) -> [UserCustomCommand] {
    commands.map { $0.normalized() }
  }
}

nonisolated struct UserCustomCommand: Codable, Equatable, Sendable, Identifiable {
  var id: String
  var title: String
  var systemImage: String
  var command: String
  var scriptProfileID: String?
  var execution: UserCustomCommandExecution
  var splitDirection: UserCustomSplitDirection
  var closeOnSuccess: Bool
  var shortcut: UserCustomShortcut?

  init(
    id: String = UUID().uuidString,
    title: String,
    systemImage: String,
    command: String,
    scriptProfileID: String? = nil,
    execution: UserCustomCommandExecution,
    splitDirection: UserCustomSplitDirection = .right,
    closeOnSuccess: Bool = false,
    shortcut: UserCustomShortcut?
  ) {
    self.id = id
    self.title = title
    self.systemImage = systemImage
    self.command = command
    self.scriptProfileID = scriptProfileID?.trimmedNilIfEmpty
    self.execution = execution
    self.splitDirection = splitDirection
    self.closeOnSuccess = closeOnSuccess
    self.shortcut = shortcut?.normalized()
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, systemImage, command, scriptProfileID, execution, splitDirection, closeOnSuccess, shortcut
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.title = try container.decode(String.self, forKey: .title)
    self.systemImage = try container.decode(String.self, forKey: .systemImage)
    self.command = try container.decode(String.self, forKey: .command)
    self.scriptProfileID = try container.decodeIfPresent(String.self, forKey: .scriptProfileID)?.trimmedNilIfEmpty
    self.execution = try container.decode(UserCustomCommandExecution.self, forKey: .execution)
    self.splitDirection =
      try container.decodeIfPresent(UserCustomSplitDirection.self, forKey: .splitDirection) ?? .right
    self.closeOnSuccess = try container.decodeIfPresent(Bool.self, forKey: .closeOnSuccess) ?? false
    // Preserves raw shortcut so downstream migration/validation can inspect the original key.
    self.shortcut = try container.decodeIfPresent(UserCustomShortcut.self, forKey: .shortcut)
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
      scriptProfileID: scriptProfileID,
      execution: execution,
      splitDirection: splitDirection,
      closeOnSuccess: closeOnSuccess,
      shortcut: shortcut?.normalized()
    )
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
    scriptProfileID != nil || !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

private extension String {
  nonisolated var trimmedNilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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
