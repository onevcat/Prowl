// ProwlCLI/Commands/SelectorOptions.swift
// Shared target selector options for commands that support them.

import ArgumentParser
import ProwlCLIShared

struct SelectorOptions: ParsableArguments {
  @Option(name: .shortAndLong, help: "Auto-resolve target by pane/tab UUID or worktree id/name/path.")
  var target: String?

  @Option(name: .long, help: "Target worktree by id, name, or path.")
  var worktree: String?

  @Option(name: .long, help: "Target tab by UUID or short handle (for example, t4).")
  var tab: String?

  @Option(name: .long, help: "Target pane by UUID or short handle (for example, p3).")
  var pane: String?

  /// Validate mutual exclusivity and return typed selector.
  func resolve() throws -> TargetSelector {
    let provided = [target, worktree, tab, pane].compactMap { $0 }
    guard provided.count <= 1 else {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "At most one target selector (--target, --worktree, --tab, --pane) is allowed."
      )
    }
    if let a = target { return .auto(a) }
    if let w = worktree { return .worktree(w) }
    if let t = tab { return .tab(t) }
    if let p = pane { return .pane(p) }
    return .none
  }

  /// Resolve with an additional auto-target value from a positional argument.
  func resolve(positionalTarget: String?) throws -> TargetSelector {
    let flagSelector = try resolve()
    if let positionalTarget {
      guard case .none = flagSelector else {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "Use either a positional target or one selector flag (--target, --worktree, --tab, --pane)."
        )
      }
      return .auto(positionalTarget)
    }
    return flagSelector
  }
}
