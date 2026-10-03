// ProwlShared/SendCommandPayload.swift
// Success payload for `prowl send --json` matching send.md contract.

import Foundation

public enum CaptureSource: String, Codable, Sendable {
  case screenDiff = "screen_diff"
}

public struct CapturedOutput: Codable, Sendable {
  public let text: String
  public let lineCount: Int
  public let source: CaptureSource
  public let truncated: Bool

  enum CodingKeys: String, CodingKey {
    case text
    case lineCount = "line_count"
    case source
    case truncated
  }

  public init(text: String, lineCount: Int, source: CaptureSource, truncated: Bool) {
    self.text = text
    self.lineCount = lineCount
    self.source = source
    self.truncated = truncated
  }
}

public struct SendCommandPayload: Codable, Sendable {
  public let target: SendTarget
  public let input: SendInputInfo
  public let createdTab: Bool
  public let wait: SendWaitResult?
  public let capture: CapturedOutput?

  enum CodingKeys: String, CodingKey {
    case target
    case input
    case createdTab = "created_tab"
    case wait
    case capture
  }

  public init(
    target: SendTarget,
    input: SendInputInfo,
    createdTab: Bool,
    wait: SendWaitResult?,
    capture: CapturedOutput? = nil
  ) {
    self.target = target
    self.input = input
    self.createdTab = createdTab
    self.wait = wait
    self.capture = capture
  }
}

public struct SendTarget: Codable, Sendable {
  public let worktree: SendTargetWorktree
  public let tab: SendTargetTab
  public let pane: SendTargetPane

  public init(worktree: SendTargetWorktree, tab: SendTargetTab, pane: SendTargetPane) {
    self.worktree = worktree
    self.tab = tab
    self.pane = pane
  }
}

public struct SendTargetWorktree: Codable, Sendable {
  public let id: String
  public let name: String
  public let path: String
  public let rootPath: String
  public let kind: String

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case path
    case rootPath = "root_path"
    case kind
  }

  public init(id: String, name: String, path: String, rootPath: String, kind: String) {
    self.id = id
    self.name = name
    self.path = path
    self.rootPath = rootPath
    self.kind = kind
  }
}

public struct SendTargetTab: Codable, Sendable {
  public let id: String
  public let title: String
  public let selected: Bool

  public init(id: String, title: String, selected: Bool) {
    self.id = id
    self.title = title
    self.selected = selected
  }
}

public struct SendTargetPane: Codable, Sendable {
  public let id: String
  public let title: String
  public let cwd: String?
  public let focused: Bool

  public init(id: String, title: String, cwd: String?, focused: Bool) {
    self.id = id
    self.title = title
    self.cwd = cwd
    self.focused = focused
  }
}

public struct SendInputInfo: Codable, Sendable {
  public let source: String
  public let characters: Int
  public let bytes: Int
  public let trailingEnterSent: Bool

  enum CodingKeys: String, CodingKey {
    case source
    case characters
    case bytes
    case trailingEnterSent = "trailing_enter_sent"
  }

  public init(source: String, characters: Int, bytes: Int, trailingEnterSent: Bool) {
    self.source = source
    self.characters = characters
    self.bytes = bytes
    self.trailingEnterSent = trailingEnterSent
  }
}

public struct SendWaitResult: Codable, Sendable {
  public let exitCode: Int?
  public let durationMs: Int

  enum CodingKeys: String, CodingKey {
    case exitCode = "exit_code"
    case durationMs = "duration_ms"
  }

  public init(exitCode: Int?, durationMs: Int) {
    self.exitCode = exitCode
    self.durationMs = durationMs
  }
}
