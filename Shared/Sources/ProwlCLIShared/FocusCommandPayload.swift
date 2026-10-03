// ProwlShared/FocusCommandPayload.swift
// Success payload for `prowl focus --json` matching focus.md contract.

import Foundation

public struct FocusCommandPayload: Codable, Sendable, Equatable {
  public let requested: FocusRequestedTarget
  public let resolvedVia: FocusResolvedVia
  public let broughtToFront: Bool
  public let target: FocusTarget

  enum CodingKeys: String, CodingKey {
    case requested
    case resolvedVia = "resolved_via"
    case broughtToFront = "brought_to_front"
    case target
  }

  public init(
    requested: FocusRequestedTarget,
    resolvedVia: FocusResolvedVia,
    broughtToFront: Bool,
    target: FocusTarget
  ) {
    self.requested = requested
    self.resolvedVia = resolvedVia
    self.broughtToFront = broughtToFront
    self.target = target
  }
}

public struct FocusRequestedTarget: Codable, Sendable, Equatable {
  public let selector: FocusRequestedSelector
  public let value: String?

  public init(selector: FocusRequestedSelector, value: String?) {
    self.selector = selector
    self.value = value
  }
}

public enum FocusRequestedSelector: String, Codable, Sendable {
  case worktree
  case tab
  case pane
  case auto
  case current
}

public enum FocusResolvedVia: String, Codable, Sendable {
  case worktree
  case tab
  case pane
}

public struct FocusTarget: Codable, Sendable, Equatable {
  public let worktree: FocusTargetWorktree
  public let tab: FocusTargetTab
  public let pane: FocusTargetPane

  public init(worktree: FocusTargetWorktree, tab: FocusTargetTab, pane: FocusTargetPane) {
    self.worktree = worktree
    self.tab = tab
    self.pane = pane
  }
}

public struct FocusTargetWorktree: Codable, Sendable, Equatable {
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

public struct FocusTargetTab: Codable, Sendable, Equatable {
  public let id: String
  public let title: String
  public let selected: Bool

  public init(id: String, title: String, selected: Bool) {
    self.id = id
    self.title = title
    self.selected = selected
  }
}

public struct FocusTargetPane: Codable, Sendable, Equatable {
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
