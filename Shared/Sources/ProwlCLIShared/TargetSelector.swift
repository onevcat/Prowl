// ProwlShared/TargetSelector.swift
// Shared between CLI and App targets

import Foundation

/// Exactly zero or one selector is allowed per command.
/// Multiple selectors → INVALID_ARGUMENT.
public enum TargetSelector: Codable, Sendable, Equatable {
  case none
  case worktree(String)
  case tab(String)
  case pane(String)
  case auto(String)

  public var isNone: Bool {
    if case .none = self { return true }
    return false
  }
}
