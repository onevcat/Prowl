import Foundation

struct TelegramBotCommandRequest: Sendable {
  let commandName: String
  let envelope: CommandEnvelope
}

enum TelegramBotParseResult: Sendable, CustomStringConvertible {
  case command(TelegramBotCommandRequest)
  case message(String)

  var description: String {
    switch self {
    case .command(let request):
      return "command(\(request.commandName))"
    case .message(let text):
      return "message(\(text))"
    }
  }
}

struct TelegramBotCommandParser: Sendable {
  let defaultReadLines: Int
  let requireExplicitPaneForWrite: Bool

  init(defaultReadLines: Int, requireExplicitPaneForWrite: Bool) {
    self.defaultReadLines = max(1, min(defaultReadLines, 500))
    self.requireExplicitPaneForWrite = requireExplicitPaneForWrite
  }

  func parse(text: String) -> TelegramBotParseResult {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .message(Self.helpText) }
    guard trimmed.hasPrefix("/") else { return .message(Self.helpText) }

    let (rawCommand, rest) = splitFirst(trimmed)
    let command =
      rawCommand
      .dropFirst()
      .split(separator: "@", maxSplits: 1)
      .first
      .map { String($0).lowercased() } ?? ""

    switch command {
    case "agents":
      return makeCommand("agents", .agents(AgentsInput()))
    case "list":
      return makeCommand("list", .list(ListInput()))
    case "read":
      return parseRead(rest)
    case "focus":
      return parseFocus(rest)
    case "send":
      return parseSend(rest)
    case "key":
      return parseKey(rest)
    case "tab_create":
      return parseTabCreate(rest)
    case "pane_close":
      return parsePaneClose(rest)
    case "tab_close":
      return parseTabClose(rest)
    case "help", "start":
      return .message(Self.helpText)
    default:
      return .message("Unknown command. \(Self.helpText)")
    }
  }

  private func parseRead(_ rest: String) -> TelegramBotParseResult {
    let (paneID, lineText) = splitFirst(rest)
    guard !paneID.isEmpty else {
      return .message("Usage: /read <pane-id> [lines]")
    }

    let lines: Int
    if lineText.isEmpty {
      lines = defaultReadLines
    } else if let parsed = Int(lineText), (1...500).contains(parsed) {
      lines = parsed
    } else {
      return .message("Usage: /read <pane-id> [lines], where lines is 1-500.")
    }

    return makeCommand(
      "read",
      .read(ReadInput(selector: .pane(paneID), last: lines))
    )
  }

  private func parseFocus(_ rest: String) -> TelegramBotParseResult {
    let paneID = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !paneID.isEmpty else {
      return .message("Usage: /focus <pane-id>")
    }
    return makeCommand("focus", .focus(FocusInput(selector: .pane(paneID))))
  }

  private func parseSend(_ rest: String) -> TelegramBotParseResult {
    let (firstToken, remainder) = splitFirst(rest)
    guard !firstToken.isEmpty else {
      return .message("Usage: /send <pane-id> <text>")
    }

    let selector: TargetSelector
    let text: String
    if requireExplicitPaneForWrite || isExplicitPaneToken(firstToken) {
      guard !remainder.isEmpty else {
        return .message("Usage: /send <pane-id> <text>")
      }
      selector = .pane(firstToken)
      text = remainder
    } else {
      selector = .none
      text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    guard !text.isEmpty else {
      return .message("Usage: /send <pane-id> <text>")
    }

    return makeCommand(
      "send",
      .send(
        SendInput(
          selector: selector,
          text: text,
          trailingEnter: true,
          source: .argv,
          wait: false,
          timeoutSeconds: nil,
          captureOutput: false
        )
      )
    )
  }

  private func parseKey(_ rest: String) -> TelegramBotParseResult {
    let (firstToken, remainder) = splitFirst(rest)
    guard !firstToken.isEmpty else {
      return .message("Usage: /key <pane-id> <token>")
    }

    let selector: TargetSelector
    let rawToken: String
    if requireExplicitPaneForWrite || isExplicitPaneToken(firstToken) {
      guard !remainder.isEmpty else {
        return .message("Usage: /key <pane-id> <token>")
      }
      selector = .pane(firstToken)
      rawToken = remainder
    } else {
      selector = .none
      rawToken = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    guard let normalized = KeyTokens.normalize(rawToken) else {
      return .message("The key token '\(rawToken.lowercased())' is unsupported.")
    }
    return makeCommand(
      "key",
      .key(
        KeyInput(
          selector: selector,
          rawToken: rawToken,
          token: normalized
        )
      )
    )
  }

  private func parseTabCreate(_ rest: String) -> TelegramBotParseResult {
    let worktree = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !worktree.isEmpty else {
      return .message("Usage: /tab_create <worktree>")
    }
    return makeCommand("tab", .tab(TabInput(action: .create, selector: .worktree(worktree), force: false)))
  }

  private func parsePaneClose(_ rest: String) -> TelegramBotParseResult {
    let paneID = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !paneID.isEmpty, !paneID.contains(" ") else {
      return .message("Usage: /pane_close <pane-id>")
    }
    return makeCommand("pane", .pane(PaneInput(action: .close, selector: .pane(paneID), force: false)))
  }

  private func parseTabClose(_ rest: String) -> TelegramBotParseResult {
    let tabID = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !tabID.isEmpty, !tabID.contains(" ") else {
      return .message("Usage: /tab_close <tab-id>")
    }
    return makeCommand("tab", .tab(TabInput(action: .close, selector: .tab(tabID), force: false)))
  }

  private func makeCommand(_ commandName: String, _ command: Command) -> TelegramBotParseResult {
    .command(
      TelegramBotCommandRequest(commandName: commandName, envelope: CommandEnvelope(output: .json, command: command)))
  }

  private func splitFirst(_ text: String) -> (String, String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let separator = trimmed.firstIndex(where: \.isWhitespace) else {
      return (trimmed, "")
    }
    let first = String(trimmed[..<separator])
    let rest = String(trimmed[separator...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return (first, rest)
  }

  private func isExplicitPaneToken(_ token: String) -> Bool {
    UUID(uuidString: token) != nil || token.hasPrefix("pane-")
  }

  static let helpText = """
    Commands: /agents, /list, /read <pane-id> [lines], /focus <pane-id>, /send <pane-id> <text>, \
    /key <pane-id> <token>, /tab_create <worktree>, /pane_close <pane-id>, /tab_close <tab-id>.
    """
}

enum TelegramAllowedUserIDsParser {
  static func parse(_ text: String) -> [Int64]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let parts =
      trimmed
      .split { character in
        character == "," || character == "\n" || character == " " || character == "\t"
      }
      .map(String.init)
    var ids: [Int64] = []
    for part in parts {
      guard let id = Int64(part), id > 0 else { return nil }
      ids.append(id)
    }
    return ids
  }

  static func format(_ ids: [Int64]) -> String {
    ids.map(String.init).joined(separator: ", ")
  }
}
