import Foundation

internal enum TmuxControlModeEvent: Equatable, Sendable {
  case sessionChanged(String, String)
  case windowAdded(TmuxWindowID)
  case windowRenamed(TmuxWindowID)
  case windowClosed(TmuxWindowID)
  case sessionWindowChanged(sessionID: String, windowID: TmuxWindowID)
  case commandOutput(commandNumber: Int, lines: [String])
  case commandError(commandNumber: Int, lines: [String])
  case exit
}

internal final class TmuxControlModeParser {
  private var isParsingBlock = false
  private var blockCommandNumber: Int?
  private var blockLines: [String] = []

  internal init() {}

  internal func parseLines(_ lines: [String]) -> [TmuxControlModeEvent] {
    var events: [TmuxControlModeEvent] = []
    for line in lines {
      if let event = parseLine(line) {
        events.append(event)
      }
    }
    return events
  }

  private func parseLine(_ line: String) -> TmuxControlModeEvent? {
    let parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

    if parts.count >= 4, parts[0] == "%begin" {
      isParsingBlock = true
      blockCommandNumber = Int(parts[2])
      blockLines.removeAll()
      return nil
    }

    if parts.count >= 4, parts[0] == "%end" {
      defer { resetBlock() }
      return .commandOutput(commandNumber: blockCommandNumber ?? commandNumber(from: parts), lines: blockLines)
    }

    if parts.count >= 4, parts[0] == "%error" {
      defer { resetBlock() }
      return .commandError(commandNumber: blockCommandNumber ?? commandNumber(from: parts), lines: blockLines)
    }

    if isParsingBlock {
      blockLines.append(line)
      return nil
    }

    if parts.count >= 3, parts[0] == "%session-changed" {
      return .sessionChanged(parts[1], parts[2])
    }

    if parts.count >= 2, parts[0] == "%window-add", let windowID = TmuxWindowID(rawValue: parts[1]) {
      return .windowAdded(windowID)
    }

    if parts.count >= 2, parts[0] == "%window-renamed", let windowID = TmuxWindowID(rawValue: parts[1]) {
      return .windowRenamed(windowID)
    }

    if parts.count >= 2, parts[0] == "%window-close", let windowID = TmuxWindowID(rawValue: parts[1]) {
      return .windowClosed(windowID)
    }

    if parts.count >= 3,
      parts[0] == "%session-window-changed",
      let windowID = TmuxWindowID(rawValue: parts[2])
    {
      return .sessionWindowChanged(sessionID: parts[1], windowID: windowID)
    }

    if parts.first == "%exit" {
      return .exit
    }

    return nil
  }

  private func resetBlock() {
    isParsingBlock = false
    blockCommandNumber = nil
    blockLines.removeAll()
  }

  private func commandNumber(from parts: [String]) -> Int {
    guard parts.count >= 3 else { return -1 }
    return Int(parts[2]) ?? -1
  }
}
