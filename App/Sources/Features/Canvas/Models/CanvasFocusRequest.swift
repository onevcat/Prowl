import Foundation
import ProwlCLIShared

struct CanvasFocusRequest: Equatable, Sendable {
  enum Target: Equatable, Sendable {
    case worktree(Worktree.ID)
    case tab(TerminalTabID)
  }

  let id: Int
  let target: Target
}

struct CanvasFocusCandidate: Equatable, Sendable {
  let worktreeID: Worktree.ID
  let tabID: TerminalTabID
}

/// A reducer-driven request to run one of CanvasView's view-local commands
/// (which live in CanvasView's `@State`, not the reducer) — e.g. triggered from
/// the command palette. CanvasView observes it, runs the command, and reports
/// the id back to clear it (the same one-shot pattern as `CanvasFocusRequest`).
struct CanvasCommandRequest: Equatable, Sendable {
  enum Command: Equatable, Sendable {
    case toggleExpand
    case arrange
    case organize
    case tile
    case selectAll
    case navigate(CanvasNavigationDirection)
  }

  let id: Int
  let command: Command
}

enum CanvasFocusResolver {
  static func resolve(
    request: CanvasFocusRequest,
    candidates: [CanvasFocusCandidate],
    currentPrimaryTabID: TerminalTabID?
  ) -> TerminalTabID? {
    switch request.target {
    case .tab(let tabID):
      return candidates.contains { $0.tabID == tabID } ? tabID : nil

    case .worktree(let worktreeID):
      let matchingTabIDs = candidates.compactMap { candidate in
        candidate.worktreeID == worktreeID ? candidate.tabID : nil
      }
      guard !matchingTabIDs.isEmpty else { return nil }
      guard let currentPrimaryTabID,
        let currentIndex = matchingTabIDs.firstIndex(of: currentPrimaryTabID)
      else {
        return matchingTabIDs[0]
      }
      return matchingTabIDs[(currentIndex + 1) % matchingTabIDs.count]
    }
  }
}
