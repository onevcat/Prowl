import Foundation

internal enum TerminalInputContext: Equatable, Sendable {
  case chatAgent
  case commandLike
  case unknown
}

internal enum TerminalInputContextClassifier {
  internal static func context(job: ForegroundJob?, viewportText: String) -> TerminalInputContext {
    guard let job else {
      return .commandLike
    }

    if canUseViewportFallback(job) {
      if identifyAgentOutsideViewportFallbackProcesses(in: job) != nil {
        return .chatAgent
      }
      return viewportLooksLikeChatAgent(viewportText) ? .chatAgent : .commandLike
    }

    if identifyAgentInJob(job) != nil {
      return .chatAgent
    }

    return .commandLike
  }

  private static func canUseViewportFallback(_ job: ForegroundJob) -> Bool {
    job.processes.contains { process in
      [process.argv0, process.name]
        .compactMap(normalizedProcessName)
        .contains { viewportFallbackProcessNames.contains($0) }
    }
  }

  private static func identifyAgentOutsideViewportFallbackProcesses(in job: ForegroundJob) -> (
    agent: DetectedAgent, name: String
  )? {
    let nonFallbackProcesses = job.processes.filter { !isViewportFallbackProcess($0) }
    guard !nonFallbackProcesses.isEmpty else {
      return nil
    }

    return identifyAgentInJob(ForegroundJob(processGroupID: job.processGroupID, processes: nonFallbackProcesses))
  }

  private static func viewportLooksLikeChatAgent(_ text: String) -> Bool {
    let normalized = text.lowercased()
    guard inputPrompts.contains(where: normalized.contains) else { return false }
    return strongSignatures.contains { containsBoundaryAware(normalized, needle: $0) }
      || viewportLooksLikeCodexModelStatus(normalized)
  }

  private static func viewportLooksLikeCodexModelStatus(_ normalizedText: String) -> Bool {
    normalizedText.split(separator: "\n").contains { line in
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let firstToken = trimmedLine.split(separator: " ").first else { return false }
      return firstToken.hasPrefix("gpt-")
    }
  }

  private static func normalizedProcessName(_ raw: String?) -> String? {
    raw.flatMap(ProcessDetection.basename)?.lowercased()
  }

  private static func containsBoundaryAware(_ text: String, needle: String) -> Bool {
    var searchRange = text.startIndex..<text.endIndex
    while let range = text.range(of: needle, range: searchRange) {
      if hasSearchBoundary(in: text, before: range.lowerBound)
        && hasSearchBoundary(in: text, after: range.upperBound)
      {
        return true
      }

      searchRange = range.upperBound..<text.endIndex
    }
    return false
  }

  private static func hasSearchBoundary(in text: String, before index: String.Index) -> Bool {
    guard index > text.startIndex else { return true }
    return isSearchBoundary(text[text.index(before: index)])
  }

  private static func hasSearchBoundary(in text: String, after index: String.Index) -> Bool {
    guard index < text.endIndex else { return true }
    return isSearchBoundary(text[index])
  }

  private static func isSearchBoundary(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy { !CharacterSet.alphanumerics.contains($0) }
  }

  private static func isViewportFallbackProcess(_ process: ForegroundProcess) -> Bool {
    [process.argv0, process.name]
      .compactMap(normalizedProcessName)
      .contains { viewportFallbackProcessNames.contains($0) }
  }

  private static let viewportFallbackProcessNames = [
    "screen",
    "tmux",
  ]

  private static let strongSignatures = [
    "codex",
    "claude code",
    "claude-code",
    "gemini",
    "cursor agent",
    "opencode",
    "open-code",
    "github copilot",
    "kimi",
    "cline",
    "amp",
  ]

  private static let inputPrompts = [
    "ready for input",
    "esc to interrupt",
    "press enter to confirm",
    "approve",
    "permission required",
  ]
}
