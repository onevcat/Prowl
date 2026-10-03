// ProwlShared/ReadCommandPayload.swift
// Success payload for `prowl read --json` matching read.md contract.

import Foundation

public struct ReadCommandPayload: Codable, Sendable, Equatable {
  public let target: ReadTarget
  public let mode: ReadMode
  public let last: Int?
  public let source: ReadSource
  public let truncated: Bool
  public let lineCount: Int
  public let text: String
  /// Whether `--wait-stable` observed the output settle (true) or hit the timeout (false). Nil when not waiting.
  public let stabilized: Bool?
  /// Total milliseconds spent waiting for stable output. Nil when not waiting.
  public let waitedMs: Int?
  /// Number of samples taken while waiting for stable output. Nil when not waiting.
  public let samples: Int?

  enum CodingKeys: String, CodingKey {
    case target
    case mode
    case last
    case source
    case truncated
    case lineCount = "line_count"
    case text
    case stabilized
    case waitedMs = "waited_ms"
    case samples
  }

  public init(
    target: ReadTarget,
    mode: ReadMode,
    last: Int?,
    source: ReadSource,
    truncated: Bool,
    lineCount: Int,
    text: String,
    stabilized: Bool? = nil,
    waitedMs: Int? = nil,
    samples: Int? = nil
  ) {
    self.target = target
    self.mode = mode
    self.last = last
    self.source = source
    self.truncated = truncated
    self.lineCount = lineCount
    self.text = text
    self.stabilized = stabilized
    self.waitedMs = waitedMs
    self.samples = samples
  }
}

public enum ReadMode: String, Codable, Sendable {
  case snapshot
  case last
}

public enum ReadSource: String, Codable, Sendable {
  case screen
  case scrollback
  case mixed
  case detection
}

public struct ReadTarget: Codable, Sendable, Equatable {
  public let worktree: ReadTargetWorktree
  public let tab: ReadTargetTab
  public let pane: ReadTargetPane

  public init(worktree: ReadTargetWorktree, tab: ReadTargetTab, pane: ReadTargetPane) {
    self.worktree = worktree
    self.tab = tab
    self.pane = pane
  }
}

public struct ReadTargetWorktree: Codable, Sendable, Equatable {
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

public struct ReadTargetTab: Codable, Sendable, Equatable {
  public let id: String
  public let title: String
  public let selected: Bool

  public init(id: String, title: String, selected: Bool) {
    self.id = id
    self.title = title
    self.selected = selected
  }
}

public struct ReadTargetPane: Codable, Sendable, Equatable {
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
