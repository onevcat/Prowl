import Foundation

struct ActiveAgentEntry: Identifiable, Equatable, Sendable {
  let id: UUID
  /// The worktree that physically owns the agent's terminal surface (the tab's worktree).
  /// Drives navigation/focus (`focusSurface`/`selectWorktree`), so it must stay the surface's
  /// real owner even when the agent runs in a different directory. Display name/branch come from
  /// `workingDirectory` instead — see `SidebarListView.activeAgentRowDisplay`.
  let worktreeID: Worktree.ID
  let worktreeName: String
  /// The agent's current working directory at detection time, used to resolve the displayed
  /// repository/branch. `nil` when the terminal hasn't reported a directory, in which case the
  /// display falls back to `worktreeID`/`worktreeName`.
  let workingDirectory: URL?
  let tabID: TerminalTabID
  let tabTitle: String
  let conversationTitle: String?
  let surfaceID: UUID
  let paneIndex: Int
  /// Command/process token used for row icon lookup. This can be more specific than
  /// `agent` for aliases that share one semantic agent, e.g. `omp` vs `pi`.
  let iconLookupToken: String
  let agent: DetectedAgent
  let rawState: AgentRawState
  let displayState: AgentDisplayState
  let lastChangedAt: Date

  init(
    id: UUID,
    worktreeID: Worktree.ID,
    worktreeName: String,
    workingDirectory: URL?,
    tabID: TerminalTabID,
    tabTitle: String,
    conversationTitle: String? = nil,
    surfaceID: UUID,
    paneIndex: Int,
    iconLookupToken: String,
    agent: DetectedAgent,
    rawState: AgentRawState,
    displayState: AgentDisplayState,
    lastChangedAt: Date
  ) {
    self.id = id
    self.worktreeID = worktreeID
    self.worktreeName = worktreeName
    self.workingDirectory = workingDirectory
    self.tabID = tabID
    self.tabTitle = tabTitle
    self.conversationTitle = conversationTitle
    self.surfaceID = surfaceID
    self.paneIndex = paneIndex
    self.iconLookupToken = iconLookupToken
    self.agent = agent
    self.rawState = rawState
    self.displayState = displayState
    self.lastChangedAt = lastChangedAt
  }

  var displayName: String {
    let trimmed = iconLookupToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      trimmed != "agent",
      CommandIconMap.iconForFirstToken(trimmed) != nil
    else {
      return agent.displayName
    }
    return trimmed
  }

  var iconSource: TabIconSource? {
    CommandIconMap.iconForFirstToken(iconLookupToken) ?? CommandIconMap.iconForFirstToken(agent.iconLookupToken)
  }
}

enum ActiveAgentConversationTitle {
  private struct SessionCandidate {
    let url: URL
    let modifiedAt: Date
  }

  private static let maximumTitleLength = 120
  private static let sessionLookupWindow: TimeInterval = 48 * 60 * 60
  private static let maximumSessionCandidates = 200

  static func title(
    for agent: DetectedAgent,
    workingDirectory: URL?,
    sessionsRoot: URL = defaultSessionsRoot(),
    now: Date = Date()
  ) -> String? {
    switch agent {
    case .codex:
      guard let workingDirectory else { return nil }
      return codexTitle(
        forWorkingDirectory: workingDirectory.standardizedFileURL.path,
        sessionsRoot: sessionsRoot,
        now: now
      )
    case .pi, .claude, .gemini, .cursor, .cline, .opencode, .copilot, .kimi, .droid, .amp:
      return nil
    }
  }

  private static func defaultSessionsRoot() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".codex/sessions", directoryHint: .isDirectory)
  }

  private static func codexTitle(
    forWorkingDirectory workingDirectory: String,
    sessionsRoot: URL,
    now: Date
  ) -> String? {
    let cutoff = now.addingTimeInterval(-sessionLookupWindow)
    let candidates = recentSessionCandidates(in: sessionsRoot, modifiedAfter: cutoff)
      .sorted { $0.modifiedAt > $1.modifiedAt }
      .prefix(maximumSessionCandidates)

    for candidate in candidates {
      guard sessionMetadataMatches(candidate.url, workingDirectory: workingDirectory) else { continue }
      if let message = firstUserRequest(in: candidate.url) {
        return cleanedTitle(from: message)
      }
    }
    return nil
  }

  private static func recentSessionCandidates(in sessionsRoot: URL, modifiedAfter cutoff: Date) -> [SessionCandidate] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: sessionsRoot,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    return enumerator.compactMap { item -> SessionCandidate? in
      guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
      guard values?.isRegularFile == true,
        let modifiedAt = values?.contentModificationDate,
        modifiedAt >= cutoff
      else {
        return nil
      }
      return SessionCandidate(url: url, modifiedAt: modifiedAt)
    }
  }

  private static func sessionMetadataMatches(_ url: URL, workingDirectory: String) -> Bool {
    guard
      let firstLine = firstLine(in: url),
      let object = jsonObject(from: firstLine),
      object["type"] as? String == "session_meta",
      let payload = object["payload"] as? [String: Any],
      payload["source"] as? String == "cli",
      let cwd = payload["cwd"] as? String
    else { return false }
    return URL(filePath: cwd).standardizedFileURL.path == workingDirectory
  }

  private static func firstUserRequest(in url: URL) -> String? {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
      guard
        line.contains("\"response_item\""),
        line.contains("\"role\":\"user\""),
        let object = jsonObject(from: String(line)),
        object["type"] as? String == "response_item",
        let payload = object["payload"] as? [String: Any],
        payload["type"] as? String == "message",
        payload["role"] as? String == "user",
        let content = payload["content"] as? [[String: Any]]
      else { continue }

      for item in content {
        guard item["type"] as? String == "input_text",
          let text = item["text"] as? String,
          let request = requestText(from: text)
        else {
          continue
        }
        return request
      }
    }
    return nil
  }

  private static func requestText(from text: String) -> String? {
    if let wrapped = unwrappedUserMessage(text) {
      return wrapped
    }
    if let marked = textAfterMarker("## My request for Codex:", in: text) {
      return marked
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isInjectedContext(trimmed) else { return nil }
    return trimmed
  }

  private static func textAfterMarker(_ marker: String, in text: String) -> String? {
    guard let markerRange = text.range(of: marker) else { return nil }
    let marked = text[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    return marked.isEmpty ? nil : marked
  }

  private static func isInjectedContext(_ text: String) -> Bool {
    text.hasPrefix("# AGENTS.md instructions for ")
      || text.hasPrefix("<environment_context>")
      || text.hasPrefix("<developer")
      || text.hasPrefix("<app-context>")
      || text.hasPrefix("<collaboration_mode>")
      || text.hasPrefix("<skills_instructions>")
      || text.hasPrefix("<plugins_instructions>")
      || text.hasPrefix("# Files mentioned by the user:")
  }

  private static func firstLine(in url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    var buffer = Data()
    while let data = try? handle.read(upToCount: 4096), !data.isEmpty {
      if let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
        buffer.append(data.prefix(upTo: newline))
        break
      }
      buffer.append(data)
      guard buffer.count < 512 * 1024 else { break }
    }
    return String(data: buffer, encoding: .utf8)
  }

  private static func jsonObject(from line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return object
  }

  private static func cleanedTitle(from raw: String) -> String? {
    let message = unwrappedUserMessage(raw) ?? raw
    let lines = message
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { stripTerminalDecoration(from: String($0)) }
      .filter { !$0.isEmpty && !isMetadataLine($0) }
    let title = lines
      .joined(separator: " ")
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.hasPrefix("http://") && !$0.hasPrefix("https://") }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return nil }
    guard title.count > maximumTitleLength else { return title }
    return String(title.prefix(maximumTitleLength)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func stripTerminalDecoration(from line: String) -> String {
    var result = line.trimmingCharacters(in: .whitespacesAndNewlines)
    while let first = result.first, "│┃║┆┊".contains(first) {
      result.removeFirst()
      result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !result.allSatisfy({ "╭╮╰╯─━═┄┈┌┐└┘".contains($0) }) else { return "" }
    return result
  }

  private static func isMetadataLine(_ line: String) -> Bool {
    line.hasPrefix("<sender ") || line.hasPrefix("</") || line.hasPrefix("<")
  }

  private static func unwrappedUserMessage(_ raw: String) -> String? {
    guard
      let startRange = raw.range(of: "<user_message>"),
      let endRange = raw.range(of: "</user_message>", range: startRange.upperBound..<raw.endIndex)
    else {
      return nil
    }
    return String(raw[startRange.upperBound..<endRange.lowerBound])
  }
}
