// ProwlCLI/Commands/LifecycleSelectorOptions.swift
// Typed target selectors for action-first lifecycle commands.

import ArgumentParser
import Foundation
import ProwlCLIShared

struct LifecycleSelectorOptions: ParsableArguments {
  @Option(name: .long, help: "Target worktree by id, name, or path.")
  var worktree: String?

  @Option(name: .long, help: "Target tab by UUID or short handle (for example, t4).")
  var tab: String?

  @Option(name: .long, help: "Target pane by UUID or short handle (for example, p3).")
  var pane: String?

  func resolveWorktree(positionalTarget: String?) throws -> TargetSelector {
    try resolve(positionalTarget: positionalTarget, acceptedSelector: .worktree)
  }

  func resolvePane(positionalTarget: String?) throws -> TargetSelector {
    let provided = [worktree, tab, pane].compactMap { $0 }
    guard provided.count <= 1 else {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "At most one target selector (--worktree, --tab, --pane) is allowed."
      )
    }

    if let positionalTarget {
      guard provided.isEmpty else {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "Use either a positional pane or --pane."
        )
      }
      guard isPaneReference(positionalTarget) else {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "create pane requires a pane UUID or prefixed handle (pN)."
        )
      }
      return .pane(positionalTarget)
    }

    if worktree != nil || tab != nil {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "create pane accepts only --pane, not --worktree or --tab."
      )
    }
    guard let pane else {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "create pane requires an explicit pane anchor."
      )
    }
    guard isPaneReference(pane) else {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "create pane requires a pane UUID or prefixed handle (pN)."
      )
    }
    return .pane(pane)
  }

  func resolveTerminalTarget(positionalTarget: String?) throws -> TargetSelector {
    let provided = [worktree, tab, pane].compactMap { $0 }
    guard provided.count <= 1 else {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "At most one target selector (--worktree, --tab, --pane) is allowed."
      )
    }

    if let positionalTarget {
      guard provided.isEmpty else {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "Use either a positional target or one selector flag (--tab, --pane)."
        )
      }
      guard isTerminalReference(positionalTarget) else {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "close requires a pane/tab UUID or prefixed handle (pN or tN)."
        )
      }
      return .auto(positionalTarget)
    }

    if worktree != nil {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "close accepts only --tab or --pane, not --worktree."
      )
    }
    if let tab { return .tab(tab) }
    if let pane { return .pane(pane) }
    throw ExitError(
      code: CLIErrorCode.invalidArgument,
      message: "close requires an explicit pane or tab target."
    )
  }

  private enum AcceptedSelector {
    case worktree
  }

  private func resolve(positionalTarget: String?, acceptedSelector: AcceptedSelector) throws -> TargetSelector {
    let provided = [worktree, tab, pane].compactMap { $0 }
    guard provided.count <= 1 else {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "At most one target selector (--worktree, --tab, --pane) is allowed."
      )
    }

    if let positionalTarget {
      guard provided.isEmpty else {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "Use either a positional target or one selector flag (--worktree)."
        )
      }
      return .worktree(positionalTarget)
    }

    switch acceptedSelector {
    case .worktree:
      if let worktree { return .worktree(worktree) }
      if tab != nil || pane != nil {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "create tab accepts only a worktree target."
        )
      }
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "create tab requires an explicit worktree target."
      )
    }
  }

  private func isTerminalReference(_ value: String) -> Bool {
    isPaneReference(value) || isPrefixedHandle(value, prefix: "t")
  }

  private func isPaneReference(_ value: String) -> Bool {
    UUID(uuidString: value) != nil || isPrefixedHandle(value, prefix: "p")
  }

  private func isPrefixedHandle(_ value: String, prefix: Character) -> Bool {
    let normalized = value.lowercased()
    guard normalized.first == prefix else { return false }
    let digits = normalized.dropFirst()
    guard
      !digits.isEmpty,
      digits.allSatisfy({ $0.isASCII && $0.isNumber }),
      let handle = Int(digits),
      handle > 0
    else {
      return false
    }
    return true
  }
}
